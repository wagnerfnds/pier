import UserNotifications

/// Every alert push passes through here before it is shown (`mutable-content: 1`, docs/PUSH.md 4.2), pierd's and the
/// alerts a Mac relays through the person's iCloud (CloudAlertPayload, made into the same content first). A waiting agent's
/// choices (`options` in the payload) become the notification's buttons: a category for them is registered
/// (`NotificationChoices`, shared with the app) and named on the content, so the person answers the question from the
/// Lock Screen. Everything else goes through untouched. No network, no keychain: the payload has all it needs.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    /// The content as a message, once made (shown instead of `content`).
    private var message: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // An alert a Mac relayed through the person's iCloud (CloudAlertPayload): the same content a push from pierd has.
        if let alert = CloudAlertPayload.info(in: request.content.userInfo) { CloudAlertPayload.apply(alert, to: c) }
        lock.withLock { handler = contentHandler; content = c }
        let options = NotificationChoices.options(in: c.userInfo)
        #if DEBUG
        let incoming = c.categoryIdentifier
        #endif
        Task {
            if let options {
                let id = await NotificationChoices.register(options: options)
                // The registration lands in the system daemon a moment later: let it, so the banner is drawn with its buttons.
                try? await Task.sleep(for: .milliseconds(200))
                self.lock.withLock { self.content?.categoryIdentifier = id }
            }
            #if DEBUG
            // What happened to this alert, read back on the device by `-runIntent notifDelivered`.
            let ids = await UNUserNotificationCenter.current().notificationCategories().map(\.identifier)
            self.lock.withLock {
                let id = self.content?.categoryIdentifier ?? "-"
                self.content?.userInfo["nseDiag"] = "in=\(incoming) opts=\(options?.count ?? 0) out=\(id) registered=\(ids.contains(id))"
            }
            #endif
            await self.asMessage()
            self.finish()
        }
    }

    /// An agent's alert becomes a message from that agent in the session's conversation (`CommunicationNotification`):
    /// Siri reads it in the car and takes a spoken reply. Alerts without a session (tests, health) stay as they are.
    private func asMessage() async {
        guard let c = lock.withLock({ content }), let box = c.userInfo["box"] as? String, let session = c.userInfo["session"] as? String
        else { return }
        let p = CommunicationNotification.parts(title: c.title, subtitle: c.subtitle)
        let conversation = p.conversation ?? c.title
        let updated = await CommunicationNotification.apply(to: c, box: box, session: session, agent: p.agent ?? "Agent",
                                                            conversation: conversation, state: p.state)
        lock.withLock { if handler != nil { message = updated } }
    }

    /// Out of time: show what we have (with its buttons when the registration made it, without them otherwise).
    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        let (h, c): (((UNNotificationContent) -> Void)?, UNNotificationContent?) = lock.withLock {
            defer { handler = nil }
            return (handler, message ?? content)
        }
        if let h, let c { h(c) }
    }
}
