import SwiftUI

@main
struct PierApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
                    #if targetEnvironment(macCatalyst)
                    MenuBarBridge.shared.start(model: model)   // the menu bar item (App/Features/MenuBar)
                    #endif
                    #if DEBUG
                    // Test hook: launch with `-pairLink pier://...` to skip the system "Open in Pier?" prompt.
                    if let l = UserDefaults.standard.string(forKey: "pairLink"), let u = URL(string: l) {
                        UserDefaults.standard.removeObject(forKey: "pairLink")
                        model.router.handle(url: u, trusted: true)
                    }
                    // `-openLink pier://review?box=…&name=…`: a widget / Live Activity link, as if tapped (UI tests).
                    if let l = UserDefaults.standard.string(forKey: "openLink"), let u = URL(string: l) {
                        Task { try? await Task.sleep(for: .seconds(2)); model.router.handle(url: u, trusted: true) }
                    }
                    WindowSnapshot.runIfRequested()
                    await DebugIntentRunner.runIfRequested(model: model)
                    #endif
                    Task { try? await Task.sleep(for: .seconds(4)); await SpotlightIndexer.reindex() }
                }
        }
        .commands { PierCommands(model: model) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
            if phase == .active { model.consumeIntentRequests(); appearance.apply() }
        }
    }
}
