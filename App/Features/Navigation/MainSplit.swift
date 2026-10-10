import SwiftUI
import PierKit

/// Regular width (iPad, Mac): a sidebar (sections, projects grouped by the person's sections with their
/// worktrees and sessions, live state) and a detail column with the same screens and stacks as the iPhone's tabs.
struct MainSplit: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            // One stack per section, the same paths the tabs use: notifications and deep links land here unchanged.
            switch router.tab {
            case .home:
                NavigationStack(path: $router.homePath) { DashboardView().pierDestinations() }
            case .inbox:
                NavigationStack(path: $router.inboxPath) { InboxScreen().pierDestinations() }
            case .board:
                NavigationStack(path: $router.boardPath) { BoardScreen().pierDestinations() }
            case .projects:
                NavigationStack(path: $router.projectsPath) { ProjectsRoot().pierDestinations() }
            case .settings:
                NavigationStack(path: $router.settingsPath) { SettingsView().pierDestinations() }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: router.projectsPath.count) { router.projectsPathChanged() }
    }
}
