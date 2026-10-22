import Foundation
import Combine
import Network
import Security

// MARK: - Companion over Wi-Fi
//
// Everything DroidHouse does over adb, the companion can also do over the
// local network: the Mac finds the phone over Bonjour, pairs once with the
// six-digit code shown in the companion app, and from then on talks to the
// bridge at <phone-ip>:8080 with a bearer token. No adb, no USB debugging.
//
// Over adb the bridge sits behind `adb forward` on 127.0.0.1 and needs no
// token, because adb already authenticated the Mac.

/// Where the bridge is and how to authenticate to it.
nonisolated struct CompanionEndpoint: Equatable, Hashable, Sendable {
    let host: String
    var port: Int = 8080
    /// Nil over adb, where the forwarded loopback socket needs none.
    let token: String?

    static let loopback = CompanionEndpoint(host: "127.0.0.1", token: nil)

    var isLAN: Bool { token != nil }

    var baseURL: String {
        // IPv6 literals must be bracketed inside a URL.
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return "http://\(hostPart):\(port)"
    }

    /// A request to the bridge with authentication already applied.
    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", timeout: TimeInterval = 30) -> URLRequest? {
        guard var components = URLComponents(string: baseURL + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        authorize(&request)
        return request
    }

    func authorize(_ request: inout URLRequest) {
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    /// First bytes a LAN client writes on the AeroCast / Studio sockets.
    var streamPreamble: Data? {
        token.map { Data("DHAUTH \($0)\n".utf8) }
    }
}

/// The route every bridge client (messages, clipboard, AeroCast, Studio…)
/// uses right now. Switched by `CompanionSync.attach(to:)` when the selected
/// device changes.
enum CompanionLink {
    @MainActor static var endpoint: CompanionEndpoint = .loopback

    @MainActor static var baseURL: String { endpoint.baseURL }

    /// `URLSession.shared.data(for:)`, with the current token applied. Callers
    /// keep building URLs from `baseURL`, so this is the only change they need.
    @MainActor static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        endpoint.authorize(&request)
        return try await URLSession.shared.data(for: request)
    }

    /// The Wi-Fi endpoint for a device id, or nil for an adb serial.
    @MainActor static func wifiEndpoint(for deviceID: String) -> CompanionEndpoint? {
        WiFiCompanionStore.shared.endpoint(forDeviceID: deviceID)
    }
}

// MARK: - Paired phones

struct PairedPhone: Codable, Identifiable, Hashable {
    /// The companion's install id (not an adb serial).
    let id: String
    var model: String
    var host: String
    var lastSeen: Date

    /// `ADBDevice.id` for this phone. Prefixed so it can never collide with an
    /// adb serial and every adb-only code path can recognise it.
    var deviceID: String { WiFiCompanionStore.devicePrefix + id }
}

/// A phone advertising `_droidhouse._tcp` on the local network.
struct DiscoveredPhone: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let host: String
}

enum WiFiPairingError: LocalizedError {
    case unreachable(String)
    case wrongCode
    case outdatedCompanion
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host):
            return "Couldn't reach \(host):8080. Check the phone is on the same Wi-Fi and the DroidHouse app shows Wi-Fi mode on."
        case .wrongCode:
            return "That code doesn't match the one shown on the phone. After five wrong tries the phone shows a new code."
        case .outdatedCompanion:
            return "The DroidHouse app on the phone is too old for Wi-Fi pairing. Install the latest companion APK."
        case .server(let message):
            return message
        }
    }
}

@MainActor
final class WiFiCompanionStore: ObservableObject {
    static let shared = WiFiCompanionStore()
    static let devicePrefix = "wifi:"

    @Published private(set) var paired: [PairedPhone] = []
    @Published private(set) var discovered: [DiscoveredPhone] = []
    /// Ids of paired phones that answered the last health check.
    @Published private(set) var reachable: Set<String> = []

    /// Companion ids already attached over adb, so the same phone isn't
    /// listed twice (once per transport). Keyed by adb serial.
    private var adbLinked: [String: String] = [:]

    private var browser: NWBrowser?
    private var monitorTask: Task<Void, Never>?
    private let defaultsKey = "droidhouse.pairedPhones"
    private let keychainService = "manolo.droid-house.companion"

    private init() {
        load()
    }

    // MARK: Devices

    /// Paired phones reachable right now, as devices the rest of the app can
    /// select like any adb device.
    func connectedDevices(excludingSerials adbSerials: [String]) -> [ADBDevice] {
        let attachedOverAdb = Set(adbSerials.compactMap { adbLinked[$0] })
        return paired
            .filter { reachable.contains($0.id) && !attachedOverAdb.contains($0.id) }
            .map {
                ADBDevice(
                    id: $0.deviceID,
                    name: "",
                    model: $0.model,
                    connectionType: .companion,
                    isConnected: true
                )
            }
    }

    func endpoint(forDeviceID deviceID: String) -> CompanionEndpoint? {
        guard deviceID.hasPrefix(Self.devicePrefix) else { return nil }
        let id = String(deviceID.dropFirst(Self.devicePrefix.count))
        guard let phone = paired.first(where: { $0.id == id }),
              let token = token(for: id) else { return nil }
        return CompanionEndpoint(host: phone.host, token: token)
    }

    /// Records which companion sits behind an adb serial (learned over the
    /// forwarded bridge), so that phone is shown once, over adb.
    func noteAdbAttached(serial: String, companionID: String) {
        adbLinked[serial] = companionID
    }

    // MARK: Lifecycle

    /// Starts Bonjour browsing and a reachability loop. Idempotent.
    func start() {
        startBrowsing()
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshReachability()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Health-checks every paired phone at its best-known address.
    func refreshReachability() async {
        var alive: Set<String> = []
        for index in paired.indices {
            let phone = paired[index]
            // A fresh Bonjour sighting beats the address we paired on: phones
            // change IP whenever the router hands out a new lease.
            var candidates = [phone.host]
            if let seen = discovered.first(where: { $0.id == phone.id })?.host, seen != phone.host {
                candidates.insert(seen, at: 0)
            }

            for host in candidates {
                guard let token = token(for: phone.id) else { break }
                let endpoint = CompanionEndpoint(host: host, token: token)
                if await Self.isAuthorized(endpoint) {
                    alive.insert(phone.id)
                    if paired[index].host != host { paired[index].host = host }
                    paired[index].lastSeen = Date()
                    break
                }
            }
        }
        if alive != reachable { reachable = alive }
        save()
    }

    // MARK: Pairing

    /// Exchanges the code shown on the phone for a token and remembers the phone.
    @discardableResult
    func pair(host: String, code: String) async throws -> PairedPhone {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = CompanionEndpoint(host: host, token: nil)
        guard let hello = await Self.hello(probe) else {
            throw WiFiPairingError.unreachable(host)
        }
        guard hello.protocolVersion >= 2 else { throw WiFiPairingError.outdatedCompanion }

        guard var request = probe.request("/api/pair", method: "POST", timeout: 8) else {
            throw WiFiPairingError.unreachable(host)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code.filter(\.isNumber),
            "clientName": Host.current().localizedName ?? "Mac"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw WiFiPairingError.wrongCode }
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw WiFiPairingError.server(message ?? "Pairing failed (HTTP \(status)).")
        }

        let reply = try JSONDecoder().decode(PairReply.self, from: data)
        storeToken(reply.token, for: reply.deviceId)

        let phone = PairedPhone(id: reply.deviceId, model: reply.deviceModel, host: host, lastSeen: Date())
        paired.removeAll { $0.id == phone.id }
        paired.append(phone)
        reachable.insert(phone.id)
        save()
        return phone
    }

    func forget(_ phone: PairedPhone) {
        paired.removeAll { $0.id == phone.id }
        reachable.remove(phone.id)
        deleteToken(for: phone.id)
        save()
    }

    // MARK: Probes

    struct Hello: Decodable {
        let app: String
        let version: String
        let protocolVersion: Int
        let deviceId: String
        let deviceModel: String
        let androidRelease: String
        let pairingRequired: Bool
    }

    private struct PairReply: Decodable {
        let token: String
        let deviceId: String
        let deviceModel: String
    }

    /// Unauthenticated identity check; nil when nothing answers.
    static func hello(_ endpoint: CompanionEndpoint, timeout: TimeInterval = 3) async -> Hello? {
        guard let request = endpoint.request("/api/hello", timeout: timeout),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Hello.self, from: data)
    }

    /// True when the endpoint answers *and* accepts its token.
    static func isAuthorized(_ endpoint: CompanionEndpoint) async -> Bool {
        guard let request = endpoint.request("/api/health", timeout: 2.5),
              let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Bonjour

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_droidhouse._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in await self?.absorb(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            // Bonjour can fail (local-network permission denied, mDNS blocked
            // by the router); manual IP pairing still works, so just retry later.
            if case .failed = state {
                Task { @MainActor in
                    self?.browser?.cancel()
                    self?.browser = nil
                    try? await Task.sleep(for: .seconds(10))
                    self?.startBrowsing()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func absorb(_ results: Set<NWBrowser.Result>) async {
        var phones: [DiscoveredPhone] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            let host: String?
            if let ip = txt["ip"], !ip.isEmpty {
                host = ip
            } else {
                host = await Self.resolve(result.endpoint)
            }
            guard let host else { continue }
            phones.append(DiscoveredPhone(
                id: txt["id"] ?? name,
                name: name,
                model: txt["model"] ?? name,
                host: host
            ))
        }
        phones.sort { $0.name < $1.name }
        if phones != discovered { discovered = phones }
    }

    /// Resolves a Bonjour service to an IP by briefly connecting to it.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        finish(text)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let phones = try? JSONDecoder().decode([PairedPhone].self, from: data) else { return }
        paired = phones
    }

    private func save() {
        if let data = try? JSONEncoder().encode(paired) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Tokens unlock SMS, files and remote input on the phone, so they live in
    /// the Keychain rather than in defaults. Read once, then served from memory.
    private var tokenCache: [String: String] = [:]

    private func token(for id: String) -> String? {
        if let cached = tokenCache[id] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        tokenCache[id] = token
        return token
    }

    private func storeToken(_ token: String, for id: String) {
        deleteToken(for: id)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id,
            kSecAttrLabel as String: "DroidHouse companion pairing",
            kSecValueData as String: Data(token.utf8)
        ]
        SecItemAdd(attributes as CFDictionary, nil)
        tokenCache[id] = token
    }

    private func deleteToken(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(query as CFDictionary)
        tokenCache[id] = nil
    }
}
