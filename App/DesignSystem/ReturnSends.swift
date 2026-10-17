import GameController
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension View {
    /// Return sends where a keyboard is at hand: on the Mac, and on an iPad with a hardware keyboard, as Messages does.
    /// Shift- or Option-Return writes a line there, and so does Return on the iPhone's and the iPad's on-screen keyboard
    /// (a growing field's own Return). Never while an input method is composing text (Japanese, Chinese, Korean, an
    /// accent's dead key): Return then confirms what is being composed. ⌘Return stays for a button's own shortcut.
    func returnSends(_ send: @escaping @MainActor () -> Void) -> some View {
        modifier(ReturnSends(send: send))
    }
}

private struct ReturnSends: ViewModifier {
    let send: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.return], phases: .down) { press in
            guard Platform.isMac || HardwareKeyboard.shared.connected,
                  press.modifiers.isDisjoint(with: [.shift, .option, .command, .control]),
                  !TextComposition.isComposing else { return .ignored }
            send()
            return .handled
        }
    }
}

/// Whether a hardware keyboard is connected (GameController's coalesced keyboard): an iPad's Magic Keyboard, a
/// Bluetooth one, the Mac's own. Followed as keyboards come and go.
@MainActor @Observable
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()

    private(set) var connected = GCKeyboard.coalesced != nil

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HardwareKeyboard.shared.connected = GCKeyboard.coalesced != nil }
            }
        }
    }
}

#if os(iOS)   // UIKit; the native Mac app's own is in Mac/PierMac
/// Whether the text being typed is still being composed by an input method: marked text in the field that has the
/// keyboard (UIKit's `markedTextRange`), which SwiftUI does not expose. Where that field cannot be found, a Japanese,
/// Chinese or Korean input mode counts as composing, so their Return keeps confirming.
@MainActor
enum TextComposition {
    static var isComposing: Bool {
        guard let responder = FirstResponder.current else { return composingLanguage(nil) }
        if let input = responder as? UITextInput { return input.markedTextRange != nil }
        return composingLanguage(responder.textInputMode?.primaryLanguage)
    }

    private static func composingLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        return ["ja", "zh", "ko"].contains { language.hasPrefix($0) }
    }
}

/// The responder that has the keyboard now, found the way UIKit finds where an action goes.
@MainActor
enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.pierReportFirstResponder), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found
    }
}

extension UIResponder {
    @objc fileprivate func pierReportFirstResponder() { FirstResponder.found = self }
}
#endif
