import SwiftUI
import UIKit
import ObjectiveC

/// Whether ⌥ is held on a hardware keyboard (iPad, Mac). SwiftUI's `onModifierKeysChanged` is macOS-only, `onKeyPress`
/// needs focus and never sees a modifier alone, and gesture recognizers get no keyboard presses; so the app's
/// `sendEvent(_:)` is observed (exchanged once, it calls the original first and only reads press events).
@MainActor @Observable
final class ModifierKeys {
    static let shared = ModifierKeys()
    private(set) var option = false
    /// The dot labels pinned open by a long press (shared, so the sidebar's list re-creating its row keeps them open).
    var labelsPinned = false
    #if DEBUG
    /// UI tests: ⌥ reached the app at least once (the simulator cannot hold a modifier for XCUITest).
    private(set) var optionSeen = false
    #endif
    @ObservationIgnored private var installed = false

    fileprivate func observe(_ event: UIPressesEvent) {
        var flags = event.modifierFlags
        // A released ⌥ is still in the event's flags: drop it.
        let alt: Set<UIKeyboardHIDUsage> = [.keyboardLeftAlt, .keyboardRightAlt]
        if event.allPresses.contains(where: { p in p.key.map { alt.contains($0.keyCode) } == true && (p.phase == .ended || p.phase == .cancelled) }) {
            flags.remove(.alternate)
        }
        let held = flags.contains(.alternate)
        #if DEBUG
        if held { optionSeen = true }
        #endif
        if held != option { option = held }
    }

    /// Starts watching (once).
    func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.pier_sendEvent(_:))) else { return }
        method_exchangeImplementations(original, replacement)
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierKeys.shared.option = false }
        }
    }
}

extension UIApplication {
    /// Exchanged with `sendEvent(_:)`: this name now runs the original.
    @objc fileprivate func pier_sendEvent(_ event: UIEvent) {
        pier_sendEvent(event)
        if let presses = event as? UIPressesEvent { MainActor.assumeIsolated { ModifierKeys.shared.observe(presses) } }
    }
}

/// Put in a view that shows dots: starts the ⌥ watcher.
struct ModifierKeysHook: View {
    var body: some View {
        Color.clear.onAppear { ModifierKeys.shared.install() }.accessibilityHidden(true)
    }
}
