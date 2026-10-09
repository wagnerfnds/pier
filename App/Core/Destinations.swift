import SwiftUI

/// The single `.navigationDestination` registry. Later features replace the placeholder views
/// (each lives in its own feature folder) without touching this mapping.
extension View {
    func pierDestinations() -> some View {
        self
            .navigationDestination(for: SessionRoute.self) { SessionScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ComposeRoute.self) { ComposeScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ProjectRoute.self) { ProjectScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: WorktreeRoute.self) { WorktreeScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: ReviewRoute.self) { ReviewScreenPlaceholder(route: $0).toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: HousekeepingRoute.self) { _ in HousekeepingScreen().toolbar(.hidden, for: .tabBar) }
            .navigationDestination(for: PullRequestRoute.self) { PullRequestScreen(route: $0).toolbar(.hidden, for: .tabBar) }
    }
}
