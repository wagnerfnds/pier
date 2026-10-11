import Foundation

/// The demo: with no box paired yet, the onboarding offers to look around on a made-up box — the showcase's projects,
/// agents, pull requests and git history, in the app's language (`UITestShowcase`) — for whoever is curious before
/// installing pierd, and for App Review. The demo box is one more box for the app, answered in memory by `MockBox`: no
/// network, keychain or push. It stays across launches until the person leaves it (Ajustes, the Home's banner) or pairs
/// a box of their own; its sections, names and marks are kept apart from theirs (`LocalPrefs.defaultURL`).
enum DemoMode {
    static let key = "demoMode"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension BoxConnection {
    /// The demo's made-up box. A UI test's mock box (`-uiTestMock 1`) is the same kind of box, but stands in for a real
    /// one: it pairs, unpairs and invites like one.
    var isDemo: Bool { DemoMode.isOn && raw is MockBox }
}
