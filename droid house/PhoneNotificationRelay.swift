import AppKit
import OSLog
import UserNotifications

private let relayLog = Logger(subsystem: "manolo.droid-house", category: "notifications")

/// Re-posts the phone's message notifications (SMS, WhatsApp, Instagram,
/// Telegram, …) as macOS notifications with an inline Reply field.
///
/// A reply typed into the macOS banner travels back over the bridge and fires
/// the Android notification's own reply action, so it is sent by the original
/// app from the user's own account — DroidHouse never needs to speak each
/// messenger's protocol.
@MainActor
final class PhoneNotificationRelay: NSObject {
    static let shared = PhoneNotificationRelay()

    static let enabledKey = "mirrorPhoneNotifications"

    private static let replyCategoryID = "droidhouse.phone.reply"
    private static let messageCategoryID = "droidhouse.phone.message"
    private static let replyActionID = "droidhouse.phone.reply.action"
    private static let identifierPrefix = "phone:"

    /// Last text seen per phone notification key. A change in text is a new
    /// message in the same conversation; an unchanged one is a silent re-post.
    private var seen: [String: String] = [:]

    /// False until the first snapshot after a (re)connect has been absorbed,
    /// so a connect doesn't dump the whole shade onto the Mac as fresh alerts.
    private var isSeeded = false
    private var isActivated = false

    private var center: UNUserNotificationCenter { .current() }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private override init() {}

    /// Installs the delegate and reply category. Must run at launch, before
    /// the app finishes launching, so a reply that relaunched the app still
    /// reaches the delegate.
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        center.delegate = self
        relayLog.info("delegate installed")

        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.replyCategoryID, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.messageCategoryID, actions: [], intentIdentifiers: [])
        ])

        if isEnabled { requestAuthorization() }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Called from the companion poll loop.
    func sync() async {
        let sync = CompanionSync.shared
        guard isEnabled, sync.isConnected else {
            isSeeded = false
            return
        }

        guard let snapshot = try? await sync.fetchNotifications() else { return }

        let conversations = snapshot.filter { $0.isMessaging || $0.canReply == true }
        let liveIDs = Set(conversations.map(\.id))

        for notification in conversations {
            let previous = seen.updateValue(notification.text, forKey: notification.id)
            guard isSeeded,
                  previous != notification.text,
                  notification.lastFromSelf != true else { continue }
            post(notification)
        }

        // Read or dismissed on the phone: clear it from the Mac as well.
        let vanished = seen.keys.filter { !liveIDs.contains($0) }
        if !vanished.isEmpty {
            vanished.forEach { seen[$0] = nil }
            center.removeDeliveredNotifications(withIdentifiers: vanished.map { Self.identifierPrefix + $0 })
        }

        isSeeded = true
    }

    private func post(_ notification: CompanionSync.PhoneNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? notification.appLabel : notification.title
        if !notification.title.isEmpty { content.subtitle = notification.appLabel }
        content.body = notification.text
        content.sound = .default
        // One stack per conversation in Notification Center.
        content.threadIdentifier = "\(notification.packageName)|\(notification.title)"
        content.categoryIdentifier = notification.canReply == true ? Self.replyCategoryID : Self.messageCategoryID
        content.userInfo = [
            "phoneID": notification.id,
            "appLabel": notification.appLabel,
            "title": notification.title
        ]

        // Reusing the phone's key replaces the previous banner for the same
        // conversation instead of stacking one per message.
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + notification.id,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { print("PhoneNotificationRelay: post failed: \(error.localizedDescription)") }
        }
    }

    private func handleReply(phoneID: String, text: String, title: String, appLabel: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let failure = await CompanionSync.shared.replyToNotification(id: phoneID, text: trimmed) else {
            print("PhoneNotificationRelay: reply sent to \(phoneID)")
            return
        }
        print("PhoneNotificationRelay: reply to \(phoneID) failed: \(failure)")

        let content = UNMutableNotificationContent()
        content.title = "Reply not sent"
        content.subtitle = [title, appLabel].filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = failure
        content.sound = .default
        content.categoryIdentifier = Self.messageCategoryID
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension PhoneNotificationRelay: UNUserNotificationCenterDelegate {
    /// Show phone messages as banners even while DroidHouse is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let phoneID = info["phoneID"] as? String
        let title = info["title"] as? String ?? ""
        let appLabel = info["appLabel"] as? String ?? ""
        print("PhoneNotificationRelay: response \(response.actionIdentifier) for \(phoneID ?? "?")")

        switch response.actionIdentifier {
        case Self.replyActionID:
            guard let phoneID, let text = (response as? UNTextInputNotificationResponse)?.userText else { return }
            await handleReply(phoneID: phoneID, text: text, title: title, appLabel: appLabel)
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run { NSApp.activate() }
        default:
            break
        }
    }
}
