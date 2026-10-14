import AppKit
import QuartzCore

// The agent's conversation in the side panel: the person's messages, the agent's replies, a quiet line for the work in
// between, and the reply being written, in a scroll view of their own above the panel's answers and reply field. The
// app sends the rows (`conversation` in the agent's payload); rows are kept by id and redrawn only when they change.

/// A flipped, transparent document for the conversation's scroll view.
final class ConversationDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Text in a non-editable, selectable text view that measures itself for a width (and remembers the last measure).
final class ChatText: NSView {
    private let text = NSTextView()
    private var attributed = NSAttributedString()
    private var measured: (width: CGFloat, size: NSSize)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.linkTextAttributes = [.foregroundColor: PanelStyle.accent, .cursor: NSCursor.pointingHand]
        addSubview(text)
    }
    required init?(coder: NSCoder) { nil }

    func set(_ a: NSAttributedString) {
        guard !a.isEqual(to: attributed) else { return }
        attributed = a
        text.textStorage?.setAttributedString(a)
        measured = nil
        needsLayout = true
    }

    /// The text's size laid out at most `width` wide: its height, and its widest line (a bubble hugs its words).
    func size(for width: CGFloat) -> NSSize {
        if let m = measured, m.width == width { return m.size }
        guard attributed.length > 0, let container = text.textContainer, let layout = text.layoutManager else { return .zero }
        container.containerSize = NSSize(width: width, height: 1_000_000)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let s = NSSize(width: min(width, ceil(used.width) + 1), height: ceil(used.height) + 1)
        measured = (width, s)
        return s
    }

    override func layout() {
        super.layout()
        text.frame = bounds
        text.textContainer?.containerSize = NSSize(width: bounds.width, height: 1_000_000)
    }
}

/// One row: the person's message (a bubble at the right, "Enviando…" or "Enviado" under it while it is on its way),
/// the agent's words (Markdown, the whole width) or a quiet line with a symbol (work, an edit, a notice, a page).
final class ChatRowView: NSView {
    private(set) var kind = "agent"
    private var signature = ""
    private let body = ChatText()
    private let caption = SurfaceStyle.label("", font: PanelStyle.font(11), color: PanelStyle.textFaint, alignment: .right)
    private let icon = NSImageView()
    private let line = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.textDim, lines: 3)
    private var url: URL?
    private var bubble = NSRect.zero
    private var cache: (width: CGFloat, height: CGFloat)?
    override var isFlipped: Bool { true }

    private static let pad = NSSize(width: 12, height: 8)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [body, caption, icon, line] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { nil }

    /// The gap under this row: messages breathe, the quiet lines of one stretch of work sit closer.
    var gapAfter: CGFloat { kind == "meta" ? 8 : 14 }

    func set(_ row: [String: Any], strings: [String: String]) {
        let kind = row["kind"] as? String ?? "agent"
        let text = row["text"] as? String ?? ""
        let state = row["state"] as? String ?? ""
        let tone = row["tone"] as? String ?? "dim"
        let sig = "\(kind)|\(state)|\(tone)|\(row["symbol"] as? String ?? "")|\(text)"
        guard sig != signature else { return }
        signature = sig
        self.kind = kind
        cache = nil
        url = (row["url"] as? String).flatMap(URL.init(string:))
        body.isHidden = kind == "meta"
        icon.isHidden = kind != "meta"
        line.isHidden = kind != "meta"
        caption.isHidden = kind != "user" || state.isEmpty
        switch kind {
        case "user":
            body.set(NSAttributedString(string: text, attributes: [.font: PanelStyle.font(13), .foregroundColor: PanelStyle.text,
                                                                   .paragraphStyle: Self.lineSpacing]))
            caption.stringValue = switch state {
            case "sending": strings["sending"] ?? "Enviando…"
            case "queued": strings["queued"] ?? "Na fila"
            default: strings["sent"] ?? "Enviado"
            }
            alphaValue = state == "sending" || state == "queued" ? 0.75 : 1
        case "meta":
            let color: NSColor = switch tone {
            case "warning": PanelStyle.orange
            case "error": PanelStyle.red
            case "accent": PanelStyle.accent
            default: PanelStyle.textDim
            }
            line.stringValue = text
            line.textColor = color
            icon.image = SurfaceStyle.symbol(row["symbol"] as? String ?? "circle", size: 10, weight: .semibold)?.tinted(color.withAlphaComponent(0.8))
            alphaValue = 1
        default:
            body.set(MarkdownText.render(text, size: 13))
            alphaValue = 1
        }
        needsLayout = true
        needsDisplay = true
    }

    private static let lineSpacing: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 1.5
        return p
    }()

    func height(for width: CGFloat) -> CGFloat {
        if let c = cache, c.width == width { return c.height }
        let h: CGFloat
        switch kind {
        case "user":
            let s = body.size(for: Self.bubbleTextWidth(width))
            h = s.height + Self.pad.height * 2 + (caption.isHidden ? 0 : 16)
        case "meta":
            h = max(16, SurfaceStyle.height(of: line, width: width - 20))
        default:
            h = body.size(for: width).height
        }
        cache = (width, h)
        return h
    }

    /// A bubble is at most four fifths of the conversation's width, as in Messages.
    private static func bubbleTextWidth(_ width: CGFloat) -> CGFloat { floor(width * 0.8) - pad.width * 2 }

    override func layout() {
        super.layout()
        let w = bounds.width
        switch kind {
        case "user":
            let s = body.size(for: Self.bubbleTextWidth(w))
            bubble = NSRect(x: w - s.width - Self.pad.width * 2, y: 0, width: s.width + Self.pad.width * 2, height: s.height + Self.pad.height * 2)
            body.frame = NSRect(x: bubble.minX + Self.pad.width, y: Self.pad.height, width: s.width, height: s.height)
            caption.frame = NSRect(x: 0, y: bubble.maxY + 2, width: w - 4, height: 14)
        case "meta":
            icon.frame = NSRect(x: 2, y: 3, width: 12, height: 12)
            line.frame = NSRect(x: 20, y: 0, width: w - 20, height: bounds.height)
        default:
            body.frame = bounds
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard kind == "user" else { return }
        PanelStyle.raised.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 16, yRadius: 16).fill()
    }

    override func resetCursorRects() {
        if url != nil, kind == "meta" { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if url == nil || kind != "meta" { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if let url, kind == "meta" { NSWorkspace.shared.open(url) } else { super.mouseUp(with: event) }
    }
}

/// The working dot: fades and shrinks a little, back and forth (Core Animation, so it costs nothing per frame); still
/// with Reduce Motion.
final class PulseDotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.accent.cgColor
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !SurfaceStyle.reduceMotion, layer?.animation(forKey: "pulse") == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.35
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.8
        let pulse = CAAnimationGroup()
        pulse.animations = [fade, shrink]
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "pulse")
    }
}

/// The reply being written and the working line under it: the agent's status word, what it is doing, the time on this turn.
final class LiveRowView: NSView {
    private let draft = ChatText()
    private let dot = PulseDotView()
    private let word = SurfaceStyle.label("", font: PanelStyle.font(12.5, .semibold), color: PanelStyle.accent)
    private let step = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.textFaint)
    private let elapsed = SurfaceStyle.label("", font: PanelStyle.font(12).withMonospacedDigits, color: PanelStyle.textFaint, alignment: .right)
    private var hasDraft = false
    private var since: Date?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [draft, dot, word, step, elapsed] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { nil }

    func set(_ live: [String: Any]) {
        let text = live["draft"] as? String ?? ""
        hasDraft = !text.isEmpty
        draft.isHidden = !hasDraft
        if hasDraft { draft.set(MarkdownText.render(text, size: 13, color: PanelStyle.text.withAlphaComponent(0.85))) }
        word.stringValue = live["word"] as? String ?? ""
        let s = live["step"] as? String ?? ""
        step.stringValue = s.isEmpty ? "" : "· \(s)"
        since = (live["since"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        tick()
        needsLayout = true
    }

    func tick() { elapsed.stringValue = since.map { Elapsed.short(since: $0) } ?? "" }

    func height(for width: CGFloat) -> CGFloat { (hasDraft ? draft.size(for: width).height + 10 : 0) + 18 }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 0
        if hasDraft {
            let h = draft.size(for: w).height
            draft.frame = NSRect(x: 0, y: 0, width: w, height: h)
            y = h + 10
        }
        dot.frame = NSRect(x: 2, y: y + 5, width: 8, height: 8)
        let ww = min(w * 0.5, ceil((word.stringValue as NSString).size(withAttributes: [.font: word.font!]).width) + 6)
        word.frame = NSRect(x: 16, y: y, width: ww, height: 18)
        step.frame = NSRect(x: 16 + ww + 2, y: y + 0.5, width: max(0, w - 16 - ww - 2 - 60), height: 17)
        elapsed.frame = NSRect(x: w - 58, y: y + 0.5, width: 58, height: 17)
    }
}

/// The conversation: its rows in a scroll view of their own, the newest at the bottom and followed there while the
/// person is at the bottom; scrolled up, it stays put (older rows coming in above keep the place) and offers "Ir para o
/// fim". Reaching the top, or "Mensagens anteriores", asks the app for more (`agent:older:<id>`).
final class ConversationPane: NSView {
    var onAction: ((String) -> Void)?
    var agentID = ""
    private let scroll = NSScrollView()
    private let clip = FlippedClipView()
    private let doc = ConversationDocument()
    private var rows: [String: ChatRowView] = [:]
    private var order: [String] = []
    private let live = LiveRowView()
    private var showsLive = false
    private let older = ClickableView()
    private let olderLabel = SurfaceStyle.label("", font: PanelStyle.font(12, .medium), color: PanelStyle.textDim, alignment: .center)
    private let startLabel = SurfaceStyle.label("", font: PanelStyle.font(11), color: PanelStyle.textFaint, alignment: .center)
    private let placeholder = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim, alignment: .center)
    private let toBottom = IconButton(symbol: "arrow.down", size: 30, symbolSize: 12, title: "Ir para o fim")
    private var more = false
    private var loadingOlder = false
    /// Following the bottom (new rows scroll into view); false once the person scrolled up.
    private var pinned = true
    /// Older rows came in above the ones shown: the next layout keeps the distance from the bottom, so what the person was
    /// reading stays where it was (rows coming in below need nothing: the top stays put).
    private var prepended = false
    /// The height of rows that left the top as new ones came in below (the window of rows slides): taken off the scroll
    /// position at the next layout, so the text in view stays put while the person reads above the bottom.
    private var droppedTop: CGFloat = 0
    private var programmatic = false
    private var askedOlder: Date?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = doc
        addSubview(scroll)
        older.addSubview(olderLabel)
        older.onClick = { [weak self] in self?.askOlder(force: true) }
        older.drawBlock = { rect, hovered in
            (hovered ? PanelStyle.wash : NSColor.clear).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
        for v in [older, startLabel, placeholder, live] as [NSView] { doc.addSubview(v) }
        toBottom.onBlack = true
        toBottom.standalone = true   // a circle of its own: it floats over the conversation's text
        toBottom.isHidden = true
        toBottom.onClick = { [weak self] in self?.followBottom() }
        addSubview(toBottom)
        // Selector-based, so it goes away with the view (an agent screen is rebuilt every time it comes back).
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: clip)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func clipMoved(_ note: Notification) { scrolled() }

    /// The app's `conversation`: the rows (by id: new ones made, gone ones dropped, changed ones redrawn), whether older
    /// ones exist, the live part. `placeholderText` shows while there is nothing yet (the record being read, the agent starting).
    func apply(_ c: [String: Any], strings: [String: String], placeholderText: String) {
        let list = c["rows"] as? [[String: Any]] ?? []
        var next: [String] = []
        next.reserveCapacity(list.count)
        for r in list {
            guard let id = r["id"] as? String else { continue }
            let v: ChatRowView
            if let existing = rows[id] { v = existing } else { v = ChatRowView(); doc.addSubview(v); rows[id] = v }
            v.set(r, strings: strings)
            next.append(id)
        }
        let keep = Set(next)
        if let first = next.first, let at = order.firstIndex(of: first), at > 0 {
            droppedTop += order[..<at].reduce(0) { sum, id in sum + (rows[id].map { $0.frame.height + $0.gapAfter } ?? 0) }
        }
        for (id, v) in rows where !keep.contains(id) { v.removeFromSuperview(); rows[id] = nil }
        if let first = order.first, let at = next.firstIndex(of: first), at > 0 { prepended = true }
        order = next
        more = c["more"] as? Bool ?? false
        loadingOlder = c["loadingOlder"] as? Bool ?? false
        olderLabel.stringValue = loadingOlder ? (strings["openingConversation"] ?? "…") : (strings["olderMessages"] ?? "Mensagens anteriores")
        older.accessibilityTitle = olderLabel.stringValue
        startLabel.stringValue = strings["conversationStart"] ?? "Início da conversa"
        toBottom.accessibilityTitle = strings["toBottom"] ?? "Ir para o fim"
        toBottom.toolTip = toBottom.accessibilityTitle
        if let l = c["live"] as? [String: Any] { live.set(l); showsLive = true } else { showsLive = false }
        live.isHidden = !showsLive
        placeholder.stringValue = order.isEmpty && !showsLive ? placeholderText : ""
        needsLayout = true
    }

    /// Once a second while the agent works: the time on its turn.
    func tick() { if showsLive { live.tick() } }

    /// The height every row wants at `width`: the panel grows to it, up to its maximum, then this scrolls.
    func naturalHeight(for width: CGFloat) -> CGFloat { layoutDocument(width: width, apply: false) }

    @discardableResult private func layoutDocument(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 2
        if more {
            if apply { older.frame = NSRect(x: 0, y: y, width: width, height: 26); olderLabel.frame = NSRect(x: 0, y: 5, width: width, height: 16) }
            y += 26 + 8
        } else if order.count > 6 {
            if apply { startLabel.frame = NSRect(x: 0, y: y, width: width, height: 14) }
            y += 14 + 12
        }
        if apply { older.isHidden = !more; startLabel.isHidden = more || order.count <= 6 }
        if !placeholder.stringValue.isEmpty {
            if apply { placeholder.frame = NSRect(x: 0, y: y + 12, width: width, height: 20) }
            y += 44
        }
        if apply { placeholder.isHidden = placeholder.stringValue.isEmpty }
        for id in order {
            guard let v = rows[id] else { continue }
            let h = v.height(for: width)
            if apply { v.frame = NSRect(x: 0, y: y, width: width, height: h) }
            y += h + v.gapAfter
        }
        if showsLive {
            let h = live.height(for: width)
            if apply { live.frame = NSRect(x: 0, y: y, width: width, height: h) }
            y += h + 4
        }
        return y
    }

    override func layout() {
        super.layout()
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }   // rows are laid out for the full width
        scroll.frame = bounds
        let width = bounds.width
        let oldHeight = doc.frame.height
        let fromBottom = oldHeight - clip.bounds.minY
        let h = layoutDocument(width: width, apply: true)
        let docHeight = max(h, bounds.height)
        programmatic = true
        doc.frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
        let bottom = max(0, docHeight - clip.bounds.height)
        if pinned {
            clip.scroll(to: NSPoint(x: 0, y: bottom))
        } else if prepended {
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, docHeight - fromBottom), bottom)))
        } else if droppedTop > 0 {
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, clip.bounds.minY - droppedTop), bottom)))
        } else if clip.bounds.minY > bottom {
            clip.scroll(to: NSPoint(x: 0, y: bottom))
        }
        prepended = false
        droppedTop = 0
        scroll.reflectScrolledClipView(clip)
        programmatic = false
        toBottom.frame = NSRect(x: bounds.width - 30 - 6, y: bounds.height - 30 - 6, width: 30, height: 30)
        toBottom.isHidden = pinned
    }

    private func scrolled() {
        guard !programmatic else { return }
        let atBottom = clip.bounds.maxY >= doc.frame.height - 12
        if atBottom != pinned {
            pinned = atBottom
            toBottom.isHidden = pinned
        }
        if clip.bounds.minY < 80 { askOlder(force: false) }
    }

    private func askOlder(force: Bool) {
        guard more, !loadingOlder else { return }
        if !force, let a = askedOlder, Date().timeIntervalSince(a) < 1.5 { return }
        askedOlder = Date()
        if force { pinned = false }
        onAction?("agent:older:\(agentID)")
    }

    /// Debug (`panel:scrolltop`): as if the person scrolled to the start of what is shown.
    func debugScrollToTop() {
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
    }

    func followBottom() {
        pinned = true
        toBottom.isHidden = true
        needsLayout = true
    }
}
