// Spike (Track 7): the entry point of the native macOS app (the PierMac target in project.yml). It mirrors
// App/PierApp.swift, which stays the iPhone, iPad and Mac Catalyst entry point; what differs is said where it does.
#if os(macOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import AppKit
import UserNotifications
import PierKit

@main
struct PierMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            MacWindowRoot {
                RootView()
                    // A Mac window has no size classes (nil here): the shared views read `.regular` as Catalyst's Mac
                    // idiom reports it, so the window gets the sidebar and the regular-width screens, not the tabs.
                    .environment(\.horizontalSizeClass, .regular)
                    .environment(\.verticalSizeClass, .regular)
                    .environment(model)
                    .environment(model.router)
                    .environment(model.prefs)
                    .preferredColorScheme(appearance.colorScheme)
                    .onChange(of: appearance, initial: true) { _, a in a.apply() }
                    .tint(Theme.accent)
                    .onOpenURL { model.router.handle(url: $0) }
                    #if DEBUG
                    .overlay { DebugSnippetOverlay() }
                    #endif
                    .task {
                        model.start()
                        // The menu bar item and the edge tab, in process (Surface/PluginInProcess.swift).
                        // `-pierMacNoSurface 1` leaves them out, to measure the window alone.
                        if !UserDefaults.standard.bool(forKey: "pierMacNoSurface") { MenuBarBridge.shared.start(model: model) }
                        #if DEBUG
                        if let l = UserDefaults.standard.string(forKey: "pairLink"), let u = URL(string: l) {
                            UserDefaults.standard.removeObject(forKey: "pairLink")
                            model.router.handle(url: u, trusted: true)
                        }
                        if let l = UserDefaults.standard.string(forKey: "openLink"), let u = URL(string: l) {
                            Task { try? await Task.sleep(for: .seconds(2)); model.router.handle(url: u, trusted: true) }
                        }
                        WindowSnapshot.runIfRequested()
                        ChatPerfProbe.runIfRequested()
                        NavPerfProbe.runIfRequested(model: model)
                        await DebugIntentRunner.runIfRequested(model: model)
                        #endif
                        Task { try? await Task.sleep(for: .seconds(4)); await SpotlightIndexer.reindex() }
                    }
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { PierCommands(model: model) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
            if phase == .active { model.consumeIntentRequests(); appearance.apply() }
        }
    }
}

/// The window's root. SwiftUI on the Mac keeps a window's minimum size in step with its content: after every update
/// that could change it, NSHostingView measures the content's minimum (its size constraints), and with this app's
/// tree that is a layout pass over every screen mounted, the hidden ones under a navigation stack included. A
/// GeometryReader takes whatever size it is given, so the measure stops here, and the frame gives the window its
/// minimum. `-pierMacPlainRoot 1` puts the content in the window as the Catalyst app does, to measure the difference.
struct MacWindowRoot<Content: View>: View {
    @ViewBuilder let content: Content
    private static var plain: Bool { UserDefaults.standard.bool(forKey: "pierMacPlainRoot") }

    var body: some View {
        if Self.plain {
            content
        } else {
            GeometryReader { _ in content }
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

/// What App/AppDelegate.swift does on iOS, through NSApplicationDelegate: diagnostics first, the notification
/// categories, the APNs token (unused while the spike runs on the mock box).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Diagnostics.start()
        Task { await Notifications.registerCategories() }
    }

    /// The Mac app keeps following the boxes with its window closed, as the Catalyst app does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = pushTokenHex(deviceToken)
        PushStateStore.update { $0.deviceToken = hex }
        NotificationCenter.default.post(name: .pierDeviceTokenChanged, object: nil, userInfo: ["token": hex])
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: %@", String(describing: error))
        NotificationCenter.default.post(name: .pierDeviceTokenChanged, object: nil, userInfo: ["error": error.localizedDescription])
    }
}
#endif
