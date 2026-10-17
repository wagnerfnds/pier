import UIKit
import UserNotifications
import PierKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import Intents
#endif

/// Remote notification plumbing (SwiftUI has no hook for the APNs token).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // MetricKit and the main thread's watchdog before anything else, so a launch that hangs is already watched.
        Diagnostics.start()
        // A push action can launch the app in the background: the categories have to exist before the UI does. Merged with
        // the categories a question's choices registered (NotificationChoices), never replacing them.
        Task { await Notifications.registerCategories() }
        #if DEBUG
        // The extension's copy of the conversation ids must say what PierKit's says (`CommunicationNotification`).
        for (b, n) in [("devbox", "shop-claude-1x2"), ("home/lab", "a b/c"), ("ção", "x%2Fy")] {
            assert(CommunicationNotification.conversationID(box: b, session: n) == CarDigest.conversationID(box: b, session: n))
        }
        #endif
        return true
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Siri's messages to and from the agents (CarPlay, notifications' "Responder", "lê minhas mensagens do Pier"),
    /// handled here so Siri can start the app in the background for them (App/Intents/MessageIntents.swift).
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        MessageIntentHandler.handles(intent) ? MessageIntentHandler() : nil
    }
    #endif

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = pushTokenHex(deviceToken)
        // Persist right away: the app model may not exist yet (cold launch in the background).
        PushStateStore.update { $0.deviceToken = hex }
        NotificationCenter.default.post(name: .pierDeviceTokenChanged, object: nil, userInfo: ["token": hex])
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: %@", String(describing: error))
        NotificationCenter.default.post(name: .pierDeviceTokenChanged, object: nil, userInfo: ["error": error.localizedDescription])
    }

    /// `content-available` pushes: refresh widgets and Live Activities, then tell iOS.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await BackgroundRefresh.run()
        return .newData
    }
}
