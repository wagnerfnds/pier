import SwiftUI

/// The single `.navigationDestination` registry. Later features replace the placeholder views
/// (each lives in its own feature folder) without touching this mapping.
extension View {
    func pierDestinations() -> some View {
        self
            .navigationDestination(for: SessionRoute.self) { SessionScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ComposeRoute.self) { ComposeScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ProjectRoute.self) { ProjectDestination(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: WorktreeRoute.self) { WorktreeDestination(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ReviewRoute.self) { ReviewScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: HousekeepingRoute.self) { _ in HousekeepingScreen().toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: BoxSettingsRoute.self) { BoxSettingsDestination(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ProjectEnvironmentRoute.self) { ProjectEnvironmentScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: WorktreeDetailsRoute.self) { WorktreeDetailsScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: PullRequestRoute.self) { PullRequestScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ProjectPRsRoute.self) { ProjectPRsScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            // The workspace one screen at a time (the iPhone; CompactWorkspace.swift).
            .navigationDestination(for: FilesRoute.self) { CompactFolderScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: FileEditorRoute.self) { CompactFileScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: HistoryRoute.self) { CompactHistoryScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: CommitRoute.self) { CompactCommitScreen(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: CommitFileRoute.self) { CompactCommitFileScreen(route: $0).toolbar(.hidden, for: .tabBar) }
    }
}

/// A project: its workspace (files, changes, history) where there is room for it (iPad, Mac), the list on the iPhone.
/// A folder that is not a git repository (the palette lists every location) has no worktree to show: its screen.
private struct ProjectDestination: View {
    let route: ProjectRoute
    @Environment(\.horizontalSizeClass) private var size
    @Environment(AppModel.self) private var model

    private var repo: Bool { model.connection(for: route.box)?.location(named: route.location)?.repo != false }

    var body: some View {
        if size == .regular && repo {
            ProjectWorkspace(box: route.box, location: route.location)
        } else {
            ProjectScreenPlaceholder(route: route)
        }
    }
}

/// A worktree: the same workspace on that worktree (iPad, Mac), the list on the iPhone.
private struct WorktreeDestination: View {
    let route: WorktreeRoute
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        if size == .regular {
            ProjectWorkspace(box: route.box, location: route.location, worktree: route.worktree)
        } else {
            WorktreeScreenPlaceholder(route: route)
        }
    }
}
