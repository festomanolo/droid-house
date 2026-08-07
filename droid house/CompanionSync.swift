import Foundation
import Combine
import SwiftUI

/// Where a locally-composed message is in its journey to the network.
enum MessageDeliveryState: Equatable {
    /// Written to the thread, request in flight.
    case sending
    /// The companion confirmed it handed the message to the radio.
    case sent
    /// The send failed; the bubble stays put so it can be retried.
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// The Mac's client for the companion's Ktor bridge on `127.0.0.1:8080`,
/// reachable through `adb forward tcp:8080 tcp:8080`.
///
/// When the companion isn't reachable the object serves a small demo dataset so
/// the UI is explorable without a phone attached — every surface that does this
/// says so plainly rather than passing the samples off as live data.
@MainActor
final class CompanionSync: ObservableObject {
    static let shared = CompanionSync()

    // MARK: Published

    @Published var isConnected: Bool = false
    @Published var statusMessage: String = "Disconnected"
    @Published var conversations: [Contact] = []
    @Published var activeMessages: [SMSMessage] = []
    @Published var screenshots: [ScreenshotItem] = []
    @Published var deviceSummary: String = ""
    @Published var hasSMSAccess: Bool = false
    @Published var hasNotificationAccess: Bool = false
    @Published var lastSyncError: String?

    /// Set when the last message list grew, so the chat view knows to run its
    /// arrival animation for genuinely new traffic only.
    @Published private(set) var latestArrivalID: String?

    /// Per-message delivery state, keyed by message id.
    ///
    /// Only locally-originated messages appear here; anything the device
    /// reported is delivered by definition.
    @Published private(set) var deliveryStates: [String: MessageDeliveryState] = [:]

    var isDemoData: Bool { !isConnected }

    // MARK: Private

    private let baseURL = "http://127.0.0.1:8080"
    private var portForwardedSerial: String?
    private var lastAdbPath: String = ADBLocator.resolve()
    private var pollTask: Task<Void, Never>?
    private var activeThreadID: String?

    /// Messages sent from the Mac that the device hasn't reported back yet.
    ///
    /// `SmsManager.sendTextMessage` transmits over the radio but does **not**
    /// write to the SMS provider unless the sending app is the device's default
    /// SMS app. Without this buffer, the next poll returns a thread that has
    /// never heard of the message and the sent bubble silently disappears.
    private var pendingSends: [String: [SMSMessage]] = [:]

    /// Recipient number per locally-sent message, so a retry can be routed
    /// without the view having to hold onto it.
    private var outboundRecipients: [String: String] = [:]

    /// Set once the companion has ever answered, so a transient drop can never
    /// replace a real thread with sample data.
    private var hasEverConnected = false

    /// How long a pending message is trusted before we assume the device will
    /// never echo it back and keep showing ours permanently for the session.
    private let pendingReconcileWindow: TimeInterval = 90

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {}

    // MARK: - Wire types

    private struct StatusResponse: Decodable {
        let status: String
        let app: String
        let version: String
        let protocolVersion: Int
        let notificationAccess: Bool
        let smsAccess: Bool
        let aeroCastAvailable: Bool
        let aeroCastStreaming: Bool
        let deviceModel: String
        let androidRelease: String
        let sdkInt: Int
    }

    private struct ScreenshotResponse: Decodable {
        let path: String
        let filename: String
        let timestamp: Int64
        let sizeBytes: Int64
    }

    struct RosterResponse: Decodable {
        let name: String
        let columns: [String]
        let rows: [[String]]
        let truncated: Bool
    }

    // MARK: - Connection

    func setupPortForwarding(serial: String, adbPath: String = ADBLocator.resolve()) async {
        // Always make sure the poll loop is alive, even on a repeat call — it
        // is what keeps `isConnected` (and therefore clipboard, roster and
        // messaging) truthful after a transient drop.
        startPolling()

        // Re-running `adb forward` for a serial we already forwarded is a no-op
        // on the adb side, but skipping it saves a process spawn per refresh.
        guard portForwardedSerial != serial else {
            await checkStatus()
            return
        }

        lastAdbPath = adbPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [adbPath, "-s", serial, "forward", "tcp:8080", "tcp:8080"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                portForwardedSerial = serial
                statusMessage = "Port 8080 forwarded"
                await checkStatus()
                startPolling()
            } else {
                statusMessage = "Port forward failed"
                isConnected = false
            }
        } catch {
            statusMessage = "ADB executable error: \(error.localizedDescription)"
            isConnected = false
        }
    }

    /// Re-runs `adb forward` without touching the poll loop.
    @discardableResult
    private func reestablishForward(serial: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [lastAdbPath, "-s", serial, "forward", "tcp:8080", "tcp:8080"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func checkStatus() async {
        guard let url = URL(string: "\(baseURL)/api/status") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                markDisconnected("Companion offline")
                return
            }

            let status = try decoder.decode(StatusResponse.self, from: data)
            isConnected = true
            hasEverConnected = true
            hasSMSAccess = status.smsAccess
            hasNotificationAccess = status.notificationAccess
            deviceSummary = "\(status.deviceModel) · Android \(status.androidRelease)"
            statusMessage = "Companion \(status.version) connected"
            lastSyncError = nil
        } catch {
            markDisconnected("Companion unreachable")
        }
    }

    private func markDisconnected(_ message: String) {
        isConnected = false
        statusMessage = message
        hasSMSAccess = false
        hasNotificationAccess = false
        deviceSummary = ""
    }

    // MARK: - Polling

    /// Keeps conversations and the open thread fresh without the UI having to
    /// ask. Cheap: two small JSON GETs every few seconds over loopback.
    func startPolling() {
        // Idempotent on purpose: the poll loop itself triggers reconnection, and
        // a restart here would cancel the very task doing the calling.
        if let pollTask, !pollTask.isCancelled { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { return }

                await self.checkStatus()

                if !self.isConnected, let serial = self.portForwardedSerial {
                    // `adb forward` entries die with the adb server and on
                    // unplug/replug. Re-establishing here is what makes the
                    // bridge come back on its own instead of needing a restart.
                    await self.reestablishForward(serial: serial)
                    await self.checkStatus()
                }

                guard self.isConnected else { continue }

                try? await self.fetchConversations()
                if let threadID = self.activeThreadID {
                    try? await self.fetchMessages(for: threadID)
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Conversations

    func fetchConversations() async throws {
        guard isConnected else {
            if conversations.isEmpty { conversations = Self.demoConversations }
            return
        }

        guard let url = URL(string: "\(baseURL)/api/messages") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 403 {
            lastSyncError = "The companion has not been granted READ_SMS."
            hasSMSAccess = false
            return
        }

        let decoded = try decoder.decode([Contact].self, from: data)
        // Only publish on an actual change — otherwise every poll invalidates
        // the list view and cancels in-flight row animations.
        if decoded != conversations {
            conversations = decoded
        }
        lastSyncError = nil
    }

    // MARK: - Messages

    func fetchMessages(for threadID: String) async throws {
        let isThreadSwitch = activeThreadID != threadID
        activeThreadID = threadID

        guard isConnected else {
            // Never overwrite a real conversation with sample data because the
            // bridge blipped — that would erase messages the user just sent.
            if !hasEverConnected {
                activeMessages = Self.demoMessages(for: threadID)
            } else if isThreadSwitch {
                activeMessages = pendingSends[threadID] ?? []
            }
            return
        }

        guard let encoded = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/messages/\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try decoder.decode([SMSMessage].self, from: data)

        let merged = mergePendingSends(into: decoded, threadID: threadID)

        guard merged != activeMessages else { return }

        // Flag genuine new arrivals so the bubble entrance animation fires for
        // incoming traffic but not for a plain thread switch.
        let previousIDs = Set(activeMessages.map(\.id))
        let arrival = merged.last.flatMap { previousIDs.contains($0.id) ? nil : $0 }

        activeMessages = merged
        latestArrivalID = (previousIDs.isEmpty ? nil : arrival?.id)
    }

    /// Folds locally-sent messages into a server thread, dropping any the
    /// device has since reported itself so nothing shows twice.
    private func mergePendingSends(into serverMessages: [SMSMessage], threadID: String) -> [SMSMessage] {
        guard var pending = pendingSends[threadID], !pending.isEmpty else { return serverMessages }

        // A server message matches a pending one when it's outgoing, carries
        // the same body, and lands near the same time. Matching on body alone
        // would collapse a legitimately repeated message.
        //
        // A failed message is never reconciled away: it never reached the
        // network, so anything on the device that looks like it is a different
        // message, and dropping ours would lose the retry affordance.
        pending.removeAll { local in
            guard deliveryStates[local.id]?.isFailed != true else { return false }
            let matched = serverMessages.contains { remote in
                remote.isOutgoing
                    && remote.body == local.body
                    && abs(remote.timestamp.timeIntervalSince(local.timestamp)) < pendingReconcileWindow
            }
            if matched {
                deliveryStates[local.id] = nil
                outboundRecipients[local.id] = nil
            }
            return matched
        }

        pendingSends[threadID] = pending.isEmpty ? nil : pending
        guard !pending.isEmpty else { return serverMessages }

        return (serverMessages + pending).sorted { $0.timestamp < $1.timestamp }
    }

    /// Writes the message into the thread immediately, then transmits.
    ///
    /// The bubble is added synchronously — before any `await` — so it is on
    /// screen in the same frame the user pressed Return. Whether the network
    /// call then succeeds only changes the bubble's *state*, never its
    /// presence: a failed send stays visible, marked, and retryable.
    @discardableResult
    func sendMessage(to recipient: String, body: String, threadID: String?) -> String {
        let key = threadID ?? recipient
        let messageID = "local-\(UUID().uuidString)"

        let optimistic = SMSMessage(
            id: messageID,
            conversationId: key,
            sender: "Me",
            body: body,
            timestamp: Date(),
            isOutgoing: true
        )

        activeMessages.append(optimistic)
        pendingSends[key, default: []].append(optimistic)
        deliveryStates[messageID] = .sending
        outboundRecipients[messageID] = recipient

        Task { await transmit(messageID: messageID, recipient: recipient, body: body, threadID: threadID) }

        return messageID
    }

    /// Re-attempts a message that previously failed, in place.
    func retrySend(messageID: String) {
        guard let message = activeMessages.first(where: { $0.id == messageID }) else { return }
        let recipient = outboundRecipients[messageID] ?? message.conversationId

        deliveryStates[messageID] = .sending
        lastSyncError = nil

        Task {
            await transmit(
                messageID: messageID,
                recipient: recipient,
                body: message.body,
                threadID: activeThreadID
            )
        }
    }

    /// Discards a failed message the user has given up on.
    func discardFailed(messageID: String) {
        activeMessages.removeAll { $0.id == messageID }
        for key in pendingSends.keys {
            pendingSends[key]?.removeAll { $0.id == messageID }
            if pendingSends[key]?.isEmpty == true { pendingSends[key] = nil }
        }
        deliveryStates[messageID] = nil
        outboundRecipients[messageID] = nil
    }

    private func transmit(messageID: String, recipient: String, body: String, threadID: String?) async {
        guard isConnected else {
            deliveryStates[messageID] = .failed("Companion not connected")
            return
        }

        guard let url = URL(string: "\(baseURL)/api/messages/send") else {
            deliveryStates[messageID] = .failed("Bad bridge URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // The bridge accepts either a thread id or a bare number; the thread id
        // is more reliable because it survives number formatting differences.
        guard let payload = try? JSONSerialization.data(withJSONObject: [
            "recipient": threadID ?? recipient,
            "body": body
        ]) else {
            deliveryStates[messageID] = .failed("Could not encode the message")
            return
        }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                let reason = detail ?? "The phone rejected the send (HTTP \(http.statusCode))"
                deliveryStates[messageID] = .failed(reason)
                lastSyncError = reason
                return
            }

            deliveryStates[messageID] = .sent
            lastSyncError = nil

            if let threadID {
                // The device needs a beat to register the send before its
                // thread reflects it; the pending buffer covers the gap.
                try? await Task.sleep(for: .milliseconds(700))
                try? await fetchMessages(for: threadID)
            }
        } catch {
            let reason = error.localizedDescription
            deliveryStates[messageID] = .failed(reason)
            lastSyncError = reason
        }
    }

    // MARK: - Clipboard

    struct ClipboardSnapshot {
        let text: String
        /// Device-clock milliseconds; used to tell a genuinely new clip from a
        /// re-read of the same one.
        let timestamp: Int64
        /// Which route captured it: listener, share, tile, capture-activity, mac.
        let source: String
    }

    /// Full clipboard state from the phone, including provenance.
    func androidClipboardSnapshot() async -> ClipboardSnapshot? {
        guard isConnected, let url = URL(string: "\(baseURL)/api/clipboard") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return ClipboardSnapshot(
            text: json["text"] as? String ?? "",
            timestamp: (json["timestamp"] as? NSNumber)?.int64Value ?? 0,
            source: json["source"] as? String ?? "unknown"
        )
    }

    func getAndroidClipboard() async throws -> String? {
        guard isConnected, let url = URL(string: "\(baseURL)/api/clipboard") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        return nil
    }

    func setAndroidClipboard(text: String) async throws {
        guard isConnected, let url = URL(string: "\(baseURL)/api/clipboard") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Screenshots

    func fetchScreenshots() async throws {
        guard isConnected, let url = URL(string: "\(baseURL)/api/screenshots") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try decoder.decode([ScreenshotResponse].self, from: data)

        screenshots = decoded.map { item in
            ScreenshotItem(
                id: item.path,
                remotePath: item.path,
                localCacheURL: nil,
                timestamp: Date(timeIntervalSince1970: TimeInterval(item.timestamp) / 1000.0)
            )
        }
    }

    /// Raw bytes for an indexed screenshot.
    ///
    /// Preferred over `adb exec-out cat`, which has to interpolate the path
    /// into a shell command — a filename containing a quote would break it, and
    /// screenshot names are OEM-generated.
    func screenshotData(remotePath: String) async -> Data? {
        guard isConnected,
              var components = URLComponents(string: "\(baseURL)/api/screenshots/file") else { return nil }

        components.queryItems = [URLQueryItem(name: "path", value: remotePath)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty else { return nil }

        return data
    }

    // MARK: - Roster

    /// Pulls a raw provider table. Rows come back exactly as the cursor
    /// produced them — no grouping, no de-duplication.
    func fetchRoster(table: String) async throws -> RosterResponse? {
        guard isConnected,
              let url = URL(string: "\(baseURL)/api/roster/\(table)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try decoder.decode(RosterResponse.self, from: data)
    }

    // MARK: - AeroCast

    func aeroCastStatus() async -> Bool {
        guard isConnected, let url = URL(string: "\(baseURL)/api/aerocast/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["streaming"] as? Bool ?? false
    }

    // MARK: - Demo data

    private static let demoConversations: [Contact] = [
        Contact(id: "demo-1", name: "Alex Rivers", phoneNumber: "+1 (555) 019-2834", avatarUrl: nil,
                lastMessageSnippet: "Hey, did you get the screenshot?",
                lastMessageTimestamp: Date(), unreadCount: 1),
        Contact(id: "demo-2", name: "Sarah Chen", phoneNumber: "+1 (555) 012-9843", avatarUrl: nil,
                lastMessageSnippet: "Awesome, let's catch up later!",
                lastMessageTimestamp: Date().addingTimeInterval(-3600), unreadCount: 0),
        Contact(id: "demo-3", name: "David Miller", phoneNumber: "+1 (555) 017-4492", avatarUrl: nil,
                lastMessageSnippet: "Sent you the project update",
                lastMessageTimestamp: Date().addingTimeInterval(-86400), unreadCount: 0)
    ]

    private static func demoMessages(for threadID: String) -> [SMSMessage] {
        [
            SMSMessage(id: "\(threadID)-m1", conversationId: threadID, sender: "Alex Rivers",
                       body: "Hey! How's the DroidHouse Mac build coming along?",
                       timestamp: Date().addingTimeInterval(-1800), isOutgoing: false),
            SMSMessage(id: "\(threadID)-m2", conversationId: threadID, sender: "Me",
                       body: "Going great — just finished the 3-pane layout and the companion bridge.",
                       timestamp: Date().addingTimeInterval(-1200), isOutgoing: true),
            SMSMessage(id: "\(threadID)-m3", conversationId: threadID, sender: "Alex Rivers",
                       body: "Hey, did you get the screenshot?",
                       timestamp: Date().addingTimeInterval(-300), isOutgoing: false)
        ]
    }
}
