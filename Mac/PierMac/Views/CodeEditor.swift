// Spike (Track 7): a stand-in for the workspace's editor (App/Features/Workspace/CodeEditor.swift, a TextKit 1
// UITextView per open file with a gutter and syntax colors). Here: an NSTextView per open file, monospaced, plain text,
// the system's find bar, edits and the caret reported the same way. No gutter, highlighting or smart indentation yet:
// porting the real editor to NSTextView is part of the migration estimate, not of this measurement.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import PierKit
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    let doc: EditorDoc
    var open: Set<String>
    let container: EditorContainer
    var onChange: (String) -> Void
    var onSelection: (NSRange, String) -> Void
    var onReady: ((CodeEditorHandle) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorHost {
        onReady?(CodeEditorHandle(container: container))
        return EditorHost(container: container)
    }

    func updateNSView(_ host: EditorHost, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        c.onSelection = onSelection
        if host.window != nil { host.adopt() }
        container.keep(open)
        container.show(doc: doc, coordinator: c)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void = { _ in }
        var onSelection: (NSRange, String) -> Void = { _, _ in }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            onChange(tv.string)
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            onSelection(tv.selectedRange(), tv.string)
        }
    }
}

@MainActor struct CodeEditorHandle {
    weak var container: EditorContainer?

    func find() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        container?.current?.performFindPanelAction(item)
    }

    func focus() {
        guard let tv = container?.current else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

final class EditorHost: NSView {
    let container: EditorContainer

    init(container: EditorContainer) {
        self.container = container
        super.init(frame: .zero)
        if container.superview == nil { adopt() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func adopt() {
        guard container.superview !== self else { return }
        container.removeFromSuperview()
        addSubview(container)
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { adopt() }
    }
}

/// The scroll view of the file on screen; the other open files keep theirs (undo, caret, scroll).
final class EditorContainer: NSView {
    private(set) var current: NSTextView?
    private var scrolls: [String: NSScrollView] = [:]
    private var revisions: [String: Int] = [:]

    func show(doc: EditorDoc, coordinator: CodeEditor.Coordinator) {
        let scroll = scrolls[doc.path] ?? Self.makeScroll()
        scrolls[doc.path] = scroll
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.delegate !== coordinator { tv.delegate = coordinator }
        if revisions[doc.path] != doc.revision {
            revisions[doc.path] = doc.revision
            tv.string = doc.text
            let n = (doc.text as NSString).length
            let sel = doc.selection
            tv.setSelectedRange(NSRange(location: min(sel.location, n), length: min(sel.length, max(0, n - sel.location))))
        }
        tv.isEditable = doc.editable
        if current !== tv {
            subviews.forEach { $0.removeFromSuperview() }
            scroll.frame = bounds
            scroll.autoresizingMask = [.width, .height]
            addSubview(scroll)
            current = tv
        }
    }

    func keep(_ paths: Set<String>) {
        for path in scrolls.keys where !paths.contains(path) && scrolls[path]?.documentView !== current {
            scrolls[path] = nil
            revisions[path] = nil
        }
    }

    private static func makeScroll() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.card)
        if let tv = scroll.documentView as? NSTextView {
            tv.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            tv.textColor = NSColor(Theme.text)
            tv.backgroundColor = NSColor(Theme.card)
            tv.isRichText = false
            tv.allowsUndo = true
            tv.usesFindBar = true
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.textContainerInset = NSSize(width: 6, height: 8)
        }
        return scroll
    }
}
#endif
