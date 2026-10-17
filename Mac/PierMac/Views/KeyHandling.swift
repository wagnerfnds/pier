// Spike (Track 7): keyboard handling the shared code does through UIKit (key commands with priority, an exchanged
// `sendEvent`, marked text), the AppKit way: local event monitors and the first responder. On Catalyst each of these was
// a workaround for what UIKit does not hand a Mac app; natively they are a few lines.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

// MARK: ↓ / ↑ in the Inbox (InboxScreen.swift's `ArrowKeys`)

/// ↓ / ↑ for the Inbox while it has the keys: a local monitor sees them before the list does, and only while this view
/// is in the key window and no text field is being edited.
struct ArrowKeys: NSViewRepresentable {
    var active: Bool
    let onArrow: (Int) -> Void

    func makeNSView(context: Context) -> ArrowKeyView { ArrowKeyView() }

    func updateNSView(_ v: ArrowKeyView, context: Context) {
        v.onArrow = onArrow
        v.active = active
    }

    static func dismantleNSView(_ v: ArrowKeyView, coordinator: ()) { v.active = false }
}

final class ArrowKeyView: NSView {
    var onArrow: ((Int) -> Void)?
    var active = false { didSet { if active != oldValue { active ? install() : remove() } } }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.active, let window = self.window, window.isKeyWindow, event.window === window,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !(window.firstResponder is NSText) else { return false }
                switch event.keyCode {
                case 125: self.onArrow?(1); return true      // ↓
                case 126: self.onArrow?(-1); return true     // ↑
                default: return false
                }
            }
            return handled ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: ⌥ held (ModifierKeys.swift)

/// Whether ⌥ is held: AppKit tells a Mac app every modifier change (`flagsChanged`), no exchanged `sendEvent` needed.
@MainActor @Observable
final class ModifierKeys {
    static let shared = ModifierKeys()
    private(set) var option = false
    /// The dot labels pinned open by a long press (shared, so the sidebar's list re-creating its row keeps them open).
    var labelsPinned = false
    #if DEBUG
    private(set) var optionSeen = false
    var labelsSeen = false
    #endif
    @ObservationIgnored private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                let held = event.modifierFlags.contains(.option)
                #if DEBUG
                if held { ModifierKeys.shared.optionSeen = true }
                #endif
                if held != ModifierKeys.shared.option { ModifierKeys.shared.option = held }
            }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModifierKeys.shared.option = false }
        }
    }
}

/// Put in a view that shows dots: starts the ⌥ watcher.
struct ModifierKeysHook: View {
    var body: some View {
        Color.clear.onAppear { ModifierKeys.shared.install() }.accessibilityHidden(true)
    }
}

// MARK: marked text (ReturnSends.swift's `TextComposition`)

/// Whether an input method is composing text in the field that has the keyboard (Japanese, Chinese, Korean, a dead key):
/// AppKit says it directly (`hasMarkedText` on the first responder).
@MainActor
enum TextComposition {
    static var isComposing: Bool {
        guard let client = NSApp.keyWindow?.firstResponder as? NSTextInputClient else { return false }
        return client.hasMarkedText()
    }
}
#endif
