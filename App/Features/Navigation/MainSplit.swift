import SwiftUI
import PierKit

/// Regular width (iPad, Mac): a sidebar (sections, projects grouped by the person's sections with their
/// worktrees and sessions, live state) and a detail column with the same screens and stacks as the iPhone's tabs.
struct MainSplit: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The window's width, for the screens that lay out columns of their own (`\.windowWidth`).
    @State private var width: CGFloat = 0

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            // One stack per section, the same paths the tabs use: notifications and deep links land here unchanged.
            switch router.tab {
            case .home:
                NavigationStack(path: $router.homePath) { DashboardView().pierDestinations() }.macInstantPush(router.homePath)
            case .inbox:
                NavigationStack(path: $router.inboxPath) { InboxScreen().pierDestinations() }.macInstantPush(router.inboxPath)
            case .board:
                NavigationStack(path: $router.boardPath) { BoardScreen().pierDestinations() }.macInstantPush(router.boardPath)
            case .projects:
                NavigationStack(path: $router.projectsPath) { ProjectsRoot().pierDestinations() }.macInstantPush(router.projectsPath)
            case .settings:
                NavigationStack(path: $router.settingsPath) { SettingsView().pierDestinations() }.macInstantPush(router.settingsPath)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: router.projectsPath.count) { router.projectsPathChanged() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.windowWidth, width)
        // A Mac window tiled narrow (a tiling window manager gives it a third of the screen): the sidebar folds away so the
        // screen keeps its width, and comes back once the window is wide again. Only on crossing, so the person's own
        // toggle wins in between.
        .onChange(of: Platform.isMac && width > 0 && width < WindowWidth.foldSidebar) { _, narrow in
            withAnimation(.snappy) { columns = narrow ? .detailOnly : .all }
        }
    }
}

extension View {
    /// On the Mac a pushed screen replaces the current one at once, as in Finder or Mail: UIKit's sliding push laid out
    /// both screens and animated them for a third of a second on every navigation (measured at ~100 ms of main thread
    /// to set up, plus the animated frames). The iPad keeps the slide.
    @ViewBuilder func macInstantPush(_ path: NavigationPath) -> some View {
        if Platform.isMac {
            transaction(value: path) { $0.disablesAnimations = true }
        } else {
            self
        }
    }
}

/// Window widths the layout goes by (points).
enum WindowWidth {
    /// Below it, the Mac's sidebar folds away by itself.
    static let foldSidebar: CGFloat = 760
    /// Below it, a screen's details open as a sheet on the Mac instead of an inspector column (the sidebar, the screen
    /// and the inspector would not fit, and the screen's content was clipped).
    static let inspectorColumn: CGFloat = 1080
    /// The same for a session shown side by side, whose conversation and terminal are two columns already: the sidebar,
    /// both of them at their narrowest and the inspector.
    static let inspectorBesideSplit: CGFloat = 1400
}

extension EnvironmentValues {
    /// The window's width (0 before it is laid out, and outside the split: iPhone).
    @Entry var windowWidth: CGFloat = 0
}
