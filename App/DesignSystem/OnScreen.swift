import SwiftUI

/// Whether the screen a view belongs to is the one in front. A screen covered by another one pushed over it (a session
/// opened from the Home or the Board) keeps its views alive, and their one-second clocks would go on redrawing what
/// nobody sees: on the Mac that is a layout of the covered screen every second.
private struct OnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isOnScreen: Bool {
        get { self[OnScreenKey.self] }
        set { self[OnScreenKey.self] = newValue }
    }
}

/// Marks a screen's root: what it holds reads `isOnScreen` false while another screen covers it.
private struct TracksOnScreen: ViewModifier {
    @State private var onScreen = true

    func body(content: Content) -> some View {
        content
            .environment(\.isOnScreen, onScreen)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
    }
}

extension View {
    func tracksOnScreen() -> some View { modifier(TracksOnScreen()) }
}
