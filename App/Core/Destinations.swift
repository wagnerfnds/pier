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
            .navigationDestination(for: PullRequestRoute.self) { PullRequestScreen(route: $0).toolbar(.hidden, for: .tabBar) }
    }
}

/// A project: its workspace (files, changes, history) where there is room for it (iPad, Mac), the list on the iPhone.
private struct ProjectDestination: View {
    let route: ProjectRoute
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        if size == .regular {
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
