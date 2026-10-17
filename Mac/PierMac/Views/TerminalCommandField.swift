// Spike (Track 7): the command line of a terminal on an older box (no `tty`), SessionTerminals.swift's
// `TerminalCommandField`, as an NSTextField. AppKit hands ⌃C, the arrows and Esc to the field's delegate as commands
// (`doCommandBy`), so the UIKit version's key command and press filtering are not needed.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import PierKit
import SwiftUI

struct TerminalCommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Take the keyboard when this shows (a terminal just opened); `onFocused` then.
    let focus: Bool
    let onFocused: () -> Void
    let onSubmit: () -> Void
    let onKey: (ControlKey) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        f.font = font
        f.textColor = NSColor(Theme.terminalText)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor(Theme.textFaint), .font: font])
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if focus, !coordinator.focusing {
            coordinator.focusing = true
            Task { @MainActor in
                if f.window == nil { try? await Task.sleep(for: .milliseconds(150)) }
                f.window?.makeFirstResponder(f)
                coordinator.focusing = false
                coordinator.parent.onFocused()
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalCommandField
        var focusing = false

        init(_ parent: TerminalCommandField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        /// Return runs the line; ⌃C goes to the shell; ↑, ↓ and Esc too while nothing is typed (the shell's history).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let empty = textView.string.isEmpty
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.moveUp(_:)) where empty: parent.onKey(.up); return true
            case #selector(NSResponder.moveDown(_:)) where empty: parent.onKey(.down); return true
            case #selector(NSResponder.cancelOperation(_:)) where empty: parent.onKey(.escape); return true
            default:
                // ⌃C arrives as no command of its own: the current event says it.
                if let e = NSApp.currentEvent, e.modifierFlags.contains(.control), e.charactersIgnoringModifiers == "c" {
                    parent.onKey(.interrupt)
                    return true
                }
                return false
            }
        }
    }
}
#endif
