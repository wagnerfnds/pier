import SwiftUI
import UIKit
import PierKit

/// The workspace's editor: one UITextView per open file (so each keeps its own undo, caret and scroll), line numbers
/// beside it, syntax colors from `SyntaxHighlighter`, Return and Tab in the file's own indentation (`EditorText`),
/// Shift-Tab to outdent, the system's find and replace (⌘F) and no smart quotes or autocorrection. Long lines wrap: a
/// UITextView does not scroll sideways reliably.
struct CodeEditor: UIViewRepresentable {
    let doc: EditorDoc
    /// The files open, so the text views of the others go.
    var open: Set<String>
    /// The container to show: kept by the workspace, so undo, carets and scrolls outlive this view (a tab switch, a
    /// session opened and closed).
    let container: EditorContainer
    var onChange: (String) -> Void
    /// The caret, with the text it is in (the store may not have that text yet: UIKit tells of the caret first).
    var onSelection: (NSRange, String) -> Void
    /// Hands the screen a way to drive the text view of the file on screen (find, go to line).
    var onReady: ((CodeEditorHandle) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EditorHost {
        onReady?(CodeEditorHandle(container: container))
        return EditorHost(container: container)
    }

    func updateUIView(_ host: EditorHost, context: Context) {
        let c = context.coordinator
        c.onChange = onChange
        c.onSelection = onSelection
        // Only a host on screen takes the container: one covered on the navigation stack must not take it away.
        if host.window != nil { host.adopt() }
        container.keep(open)
        container.show(doc: doc, coordinator: c)
    }

    /// Text view delegate for every file's text view; reports edits and the caret to the store.
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void = { _ in }
        var onSelection: (NSRange, String) -> Void = { _, _ in }

        func textViewDidChange(_ textView: UITextView) {
            guard let tv = textView as? CodeTextView else { return }
            onChange(tv.text)
            tv.textChanged()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onSelection(textView.selectedRange, textView.text ?? "")
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? CodeTextView)?.gutter?.setNeedsDisplay()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard let tv = textView as? CodeTextView else { return true }
            if text == "\n" {
                let ns = tv.text as NSString
                let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
                let before = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
                var insert = EditorText.newline(after: before, unit: tv.indentUnit, language: tv.language)
                if tv.lineEnding == "\r\n" { insert = "\r" + insert }
                tv.replace(range, with: insert)
                return false
            }
            if text == "\t", tv.indentUnit != "\t" {
                tv.replace(range, with: tv.indentUnit)
                return false
            }
            return true
        }
    }
}

/// What the workspace can ask of the editor on screen.
@MainActor struct CodeEditorHandle {
    weak var container: EditorContainer?

    func find() { container?.current?.showFind() }
    func focus() { _ = container?.current?.becomeFirstResponder() }
}

/// Where an editor shows: it takes the workspace's one container whenever it is on screen, so two screens of the same
/// worktree on a navigation stack (a project and its main worktree) each get it back when they show again.
final class EditorHost: UIView {
    let container: EditorContainer

    init(container: EditorContainer) {
        self.container = container
        super.init(frame: .zero)
        // A container another host shows stays there until this one is on screen.
        if container.superview == nil { adopt() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func adopt() {
        guard container.superview !== self else { return }
        container.removeFromSuperview()
        addSubview(container)
        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { adopt() }
    }
}

/// Holds the gutter and the text view of the file on screen; keeps the other files' text views for their tabs.
final class EditorContainer: UIView {
    private(set) var current: CodeTextView?
    private var views: [String: CodeTextView] = [:]
    private let gutter = GutterView()
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.card)
        gutter.backgroundColor = UIColor(Theme.card)
        separator.backgroundColor = UIColor(Theme.stroke)
        addSubview(gutter)
        addSubview(separator)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(doc: EditorDoc, coordinator: CodeEditor.Coordinator) {
        let tv: CodeTextView
        if let v = views[doc.path] {
            tv = v
        } else {
            tv = CodeTextView(path: doc.path, language: doc.language)
            views[doc.path] = tv
        }
        // A new representable brings a new coordinator: every text view reports to the current one.
        if tv.delegate !== coordinator { tv.delegate = coordinator }
        // Text replaced from outside (first load, a reload, a revert): take it, keep the caret where it can be.
        if tv.revision != doc.revision {
            tv.revision = doc.revision
            tv.load(doc.text, selection: doc.selection)
        }
        tv.isEditable = doc.editable
        if current !== tv {
            current?.removeFromSuperview()
            current = tv
            insertSubview(tv, at: 0)
            gutter.textView = tv
            tv.gutter = gutter
            setNeedsLayout()
            gutter.setNeedsDisplay()
        }
    }

    /// Forget the text views of files no longer open.
    func keep(_ paths: Set<String>) {
        for (path, v) in views where !paths.contains(path) && v !== current { views[path] = nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = gutter.preferredWidth
        gutter.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        separator.frame = CGRect(x: w, y: 0, width: 1 / max(1, traitCollection.displayScale), height: bounds.height)
        current?.frame = CGRect(x: w + 1, y: 0, width: max(0, bounds.width - w - 1), height: bounds.height)
        gutter.setNeedsDisplay()
    }
}

/// A file's text view: TextKit 1 (its layout manager draws the line numbers), monospaced, its colors from the
/// highlighter, a little later than the keystroke.
final class CodeTextView: UITextView {
    let path: String
    let language: SyntaxLanguage?
    var revision = -1
    weak var gutter: GutterView?
    private(set) var indentUnit = "    "
    private(set) var lineEnding = "\n"
    /// UTF-16 offsets where lines start, for the gutter's numbers.
    private(set) var lineStarts: [Int] = [0]
    private var highlightTask: Task<Void, Never>?

    static let fontSize: CGFloat = Platform.isMac ? 12.5 : 14
    static let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let italic: UIFont = {
        let d = font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor
        return UIFont(descriptor: d, size: fontSize)
    }()
    static var baseAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.12
        return [.font: font, .foregroundColor: UIColor(Theme.text), .paragraphStyle: p]
    }

    init(path: String, language: SyntaxLanguage?) {
        self.path = path
        self.language = language
        // TextKit 1, built by hand: its layout manager gives the line fragments the gutter numbers.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = UIColor(Theme.card)
        font = Self.font
        typingAttributes = Self.baseAttributes
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        dataDetectorTypes = []
        alwaysBounceVertical = true
        textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 60, right: 16)
        textContainer.lineFragmentPadding = 0
        layoutManager.allowsNonContiguousLayout = true
        isFindInteractionEnabled = true
        accessibilityIdentifier = "code-editor"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var keyCommands: [UIKeyCommand]? {
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentLines))
        outdent.wantsPriorityOverSystemBehavior = true
        return [outdent]
    }

    func load(_ text: String, selection: NSRange) {
        indentUnit = EditorText.indentUnit(of: text)
        lineEnding = EditorText.lineEnding(of: text)
        attributedText = NSAttributedString(string: text, attributes: Self.baseAttributes)
        let length = (text as NSString).length
        selectedRange = NSRange(location: min(selection.location, length), length: 0)
        undoManager?.removeAllActions()
        textChanged(immediately: true)
    }

    /// After every edit: the line starts now, the colors a moment later.
    func textChanged(immediately: Bool = false) {
        recountLines()
        gutter?.setNeedsLayout()
        gutter?.superview?.setNeedsLayout()
        gutter?.setNeedsDisplay()
        highlightTask?.cancel()
        guard let language else { return }
        let text = self.text ?? ""
        highlightTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let runs = await Task.detached(priority: .userInitiated) { Self.colorRuns(text, language) }.value
            guard !Task.isCancelled, let self, self.text == text else { return }
            self.apply(runs, length: (text as NSString).length)
        }
    }

    private func recountLines() {
        let ns = (text ?? "") as NSString
        var starts = [0]
        starts.reserveCapacity(ns.length / 30 + 1)
        var i = 0
        let n = ns.length
        while i < n {
            if ns.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        lineStarts = starts
    }

    /// 0-based line of a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The highlighter's runs as UTF-16 ranges (its offsets count Unicode scalars).
    nonisolated private static func colorRuns(_ text: String, _ language: SyntaxLanguage) -> [(NSRange, SyntaxKind)] {
        let tokens = SyntaxHighlighter.tokens(text, language: language)
        guard !tokens.isEmpty else { return [] }
        var out: [(NSRange, SyntaxKind)] = []
        out.reserveCapacity(tokens.count)
        var scalar = 0, utf16 = 0
        var k = 0
        var start16 = 0
        for s in text.unicodeScalars {
            guard k < tokens.count else { break }
            if scalar == tokens[k].start { start16 = utf16 }
            utf16 += s.utf16.count
            scalar += 1
            if scalar == tokens[k].end {
                out.append((NSRange(location: start16, length: utf16 - start16), tokens[k].kind))
                k += 1
                if k < tokens.count, tokens[k].start == scalar { start16 = utf16 }
            }
        }
        return out
    }

    /// The highlighter's palette as UIColors (dynamic: they follow light and dark).
    private static let colors: [SyntaxKind: UIColor] = Dictionary(uniqueKeysWithValues: SyntaxKind.allCases.map {
        ($0, UIColor(SyntaxTheme.color($0, fallback: Theme.text)))
    })

    private func apply(_ runs: [(NSRange, SyntaxKind)], length: Int) {
        guard textStorage.length == length else { return }
        let base = Self.baseAttributes
        textStorage.beginEditing()
        textStorage.setAttributes(base, range: NSRange(location: 0, length: length))
        for (r, kind) in runs where kind != .plain && NSMaxRange(r) <= length {
            if let c = Self.colors[kind] { textStorage.addAttribute(.foregroundColor, value: c, range: r) }
            if kind == .comment { textStorage.addAttribute(.font, value: Self.italic, range: r) }
        }
        textStorage.endEditing()
        typingAttributes = base
    }

    /// Replace a range with undo, as typing would.
    func replace(_ range: NSRange, with text: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let r = textRange(from: start, to: end) else { return }
        replace(r, withText: text)
    }

    /// Shift-Tab: one indentation step less on every selected line.
    @objc func outdentLines() {
        guard isEditable else { return }
        let ns = text as NSString
        let lines = ns.lineRange(for: selectedRange)
        var out = ""
        var removedFirst = 0, removed = 0
        var first = true
        // Split on the "\n" code unit (a "\r" before it stays on its line): to Swift "\r\n" is one Character, which a
        // split on "\n" would never find.
        for (i, line) in (ns.substring(with: lines) as NSString).components(separatedBy: "\n").enumerated() {
            var l = Substring(line)
            var cut = 0
            if l.hasPrefix("\t") { l = l.dropFirst(); cut = 1 }
            else {
                let spaces = l.prefix { $0 == " " }.count
                cut = min(spaces, indentUnit == "\t" ? 4 : indentUnit.count)
                l = l.dropFirst(cut)
            }
            if first { removedFirst = cut; first = false }
            removed += cut
            out += (i > 0 ? "\n" : "") + l
        }
        guard removed > 0 else { return }
        let sel = selectedRange
        replace(lines, with: out)
        selectedRange = NSRange(location: max(lines.location, sel.location - removedFirst), length: max(0, sel.length - (removed - removedFirst)))
    }

    func showFind() {
        _ = becomeFirstResponder()
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

}

/// The line numbers beside the text, drawn for the lines on screen.
final class GutterView: UIView {
    weak var textView: CodeTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let font = UIFont.monospacedDigitSystemFont(ofSize: CodeTextView.fontSize - 1.5, weight: .regular)

    var preferredWidth: CGFloat {
        let lines = textView?.lineStarts.count ?? 1
        let digits = max(3, String(lines).count)
        return CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: Self.font]).width + 22
    }

    override func draw(_ rect: CGRect) {
        UIColor(Theme.card).setFill()
        UIRectFill(rect)
        guard let tv = textView else { return }
        let lm = tv.layoutManager
        let inset = tv.textContainerInset
        let visible = CGRect(x: 0, y: tv.contentOffset.y - inset.top, width: tv.textContainer.size.width, height: tv.bounds.height)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tv.textContainer)
        let ns = tv.textStorage.string as NSString
        let selectedLine = tv.line(at: tv.selectedRange.location)
        let dim: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: UIColor(Theme.textFaint)]
        let bright: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: UIColor(Theme.textDim)]
        let right = bounds.width - 10
        func number(_ n: Int, at y: CGFloat, height: CGFloat, current: Bool) {
            let s = "\(n)" as NSString
            let a = current ? bright : dim
            let size = s.size(withAttributes: a)
            s.draw(at: CGPoint(x: right - size.width, y: y + (height - size.height) / 2), withAttributes: a)
        }
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, glyphRange, _ in
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard chars.location == 0 || (chars.location <= ns.length && ns.character(at: chars.location - 1) == 0x0A) else { return }
            let line = tv.line(at: chars.location)
            let y = frag.minY + inset.top - tv.contentOffset.y
            number(line + 1, at: y, height: Self.lineHeight(frag), current: line == selectedLine)
        }
        // The empty line after a final line break.
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 {
            let y = extra.minY + inset.top - tv.contentOffset.y
            let line = tv.lineStarts.count - 1
            number(line + 1, at: y, height: extra.height, current: line == selectedLine)
        }
    }

    private static func lineHeight(_ frag: CGRect) -> CGFloat { frag.height }
}
