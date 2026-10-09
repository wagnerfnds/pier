import UIKit
import UserNotifications
import PierKit

/// Remote notification plumbing (SwiftUI has no hook for the APNs token).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A push action can launch the app in the background: the categories have to exist before the UI does. Merged with
        // the categories a question's choices registered (NotificationChoices), never replacing them.
        Task { await Notifications.registerCategories() }
        return true
    }

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
