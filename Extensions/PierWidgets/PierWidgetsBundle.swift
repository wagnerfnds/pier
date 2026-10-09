import WidgetKit
import SwiftUI

/// `pushHandler` (iOS 26) cannot be applied conditionally inside a configuration and `WidgetBundleBuilder` has no
/// if/else, so there are two bundles and the entry point picks one at launch. On the Mac (Mac Catalyst, desktop and
/// Notification Center widgets) there is no ActivityKit: the bundles hold the status widget alone.
@main
enum PierWidgetsMain {
    static func main() {
        if #available(iOS 26.0, *) {
            PierWidgetsBundlePush.main()
        } else {
            PierWidgetsBundle.main()
        }
    }
}

struct PierWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        #if !targetEnvironment(macCatalyst)
        SessionLiveActivity()
        #endif
    }
}

@available(iOS 26.0, *)
struct PierWidgetsBundlePush: WidgetBundle {
    var body: some Widget {
        StatusWidgetPushEnabled()
        #if !targetEnvironment(macCatalyst)
        SessionLiveActivity()
        #endif
    }
}
