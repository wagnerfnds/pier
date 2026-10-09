import AppKit

/// The Inbox screen of the side panel: one agent at a time (a page indicator and ← → for the others), its question and
/// the answers as full-width rows with keycaps (1 2 3 answer, the chosen row turns green), a reply field with dictation,
/// and under it a hint pill that becomes "Enviando… Esc desfaz" during the undo window and "✓ Enviado para …" once the
/// answer went out. Finished turns show the reply and the suggested next steps the same way.
@MainActor final class InboxCardController {
    struct Option {
        let number: Int
        let title: String
        let detail: String?
        let recommended: Bool
        /// "allow" | "always" | "deny" | "plain" (the Inbox's roles; colors the title).
        let role: String
    }
    struct Card: Equatable {
        static func == (a: Card, b: Card) -> Bool { a.signature == b.signature }
        let id: String
        let kind: String   // needsYou | finished
        let title: String
        let agent: String?
        let agentLabel: String
        let word: String
        let place: String
        let question: String?
        /// What the agent wants to run (monospace), or the file / page it wants (plain), and its own reason.
        let command: String?
        let detail: String?
        let why: String?
        let options: [Option]
        let reply: String?
        let nextSteps: [String]
        let nextStepsLoading: Bool
        let change: String?
        let canReview: Bool
        let replyPlaceholder: String
        let signature: String
    }
    struct Pending: Equatable {
        let cardID: String
        /// The row chosen (1-based), 0 for a typed reply.
        let option: Int
        let label: String
        let start: Date
        let deadline: Date
    }

    let send: (String) -> Void
    var strings: [String: String] = [:] { didSet { if strings != oldValue { render() } } }
    let view = CardView()
    private var cards: [Card] = []
    private var current: String?
    private var pending: Pending?
    private var receipt: String?
    private var dictation: (active: Bool, text: String)?
    private var ticker: Timer?
    /// The host re-lays the panel out when the content changed.
    var onContentChanged: (() -> Void)?

    init(send: @escaping (String) -> Void) {
        self.send = send
        view.embedded = true
        view.onAction = { [weak self] a in self?.act(a) }
    }

    // MARK: input from the app

    func update(cards: [Card], current: String?, pending: Pending?, receipt: String?, dictation: (active: Bool, text: String)?) {
        let changed = cards != self.cards || current != self.current || pending != self.pending || receipt != self.receipt
            || dictation?.active != self.dictation?.active || dictation?.text != self.dictation?.text
        self.cards = cards
        self.current = current
        self.pending = pending
        self.receipt = receipt
        self.dictation = dictation
        if changed { render() }
        if pending != nil, ticker == nil {
            // The hint's ring counts the undo window down.
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.view.tick() }
            }
        } else if pending == nil {
            ticker?.invalidate(); ticker = nil
        }
    }

    private var card: Card? {
        if let current, let c = cards.first(where: { $0.id == current }) { return c }
        return cards.first
    }

    private func render() {
        let index = card.flatMap { c in cards.firstIndex(where: { $0.id == c.id }) } ?? 0
        view.render(card: card, count: cards.count, index: index, pending: pending, receipt: receipt, dictation: dictation, strings: strings)
        onContentChanged?()
    }

    // MARK: keys and actions

    /// The Inbox's keys: 1–9 answer, → / ← (J K) page, E archives or dismisses, R the reply field, Return opens the
    /// agent in the panel; Esc while an answer waits undoes it (otherwise the panel's own Esc).
    func key(_ e: NSEvent) -> Bool {
        guard let chars = e.charactersIgnoringModifiers, !e.modifierFlags.contains(.command) else { return false }
        if e.keyCode == 53, pending != nil { send("card:undo"); return true }
        if chars == "k" { send("card:page:-1"); return true }
        if e.keyCode == 124 || chars == "j" { send("card:page:1"); return true }
        if e.keyCode == 36, let c = card { send("panel:show:agent:\(c.id)"); return true }
        if let n = Int(chars), (1...9).contains(n), let c = card { send("card:pick:\(c.id)|\(n)"); return true }
        if chars == "e", let c = card { send("card:clear:\(c.id)"); return true }
        if chars == "r" { send("panel:focus"); return true }
        return false
    }

    private func act(_ a: String) {
        switch a {
        case "undo": send("card:undo")
        default: send(a)
        }
    }

    var debugState: String {
        "cards=\(cards.count) current=\(card?.id ?? "-") pending=\(pending?.option ?? -1) receipt=\(receipt ?? "-")"
    }

    /// A card from the app's payload.
    static func card(_ d: [String: Any]) -> Card {
        let options = (d["options"] as? [[String: Any]] ?? []).map { o in
            Option(number: (o["number"] as? NSNumber)?.intValue ?? 0, title: o["title"] as? String ?? "", detail: o["detail"] as? String,
                   recommended: o["recommended"] as? Bool ?? false, role: o["role"] as? String ?? "plain")
        }
        return Card(id: d["id"] as? String ?? "", kind: d["kind"] as? String ?? "needsYou", title: d["title"] as? String ?? "",
                    agent: d["agent"] as? String, agentLabel: d["agentLabel"] as? String ?? "", word: d["word"] as? String ?? "",
                    place: d["place"] as? String ?? "", question: d["question"] as? String, command: d["command"] as? String,
                    detail: d["detail"] as? String, why: d["why"] as? String, options: options,
                    reply: d["reply"] as? String, nextSteps: d["nextSteps"] as? [String] ?? [],
                    nextStepsLoading: d["nextStepsLoading"] as? Bool ?? false, change: d["change"] as? String,
                    canReview: d["canReview"] as? Bool ?? false, replyPlaceholder: d["replyPlaceholder"] as? String ?? "",
                    signature: d["signature"] as? String ?? "")
    }
}

/// The Inbox screen: the card's content hosted by the side panel.
final class InboxScreen: NSView, PanelScreenView, PanelDataSink {
    var onAction: ((String) -> Void)? { didSet { controller.onContentChanged = { [weak self] in self?.onAction?("panel:relayout") } } }
    var title: String { strings["menuInbox"] ?? "Inbox" }
    private var strings: [String: String] = [:]
    private lazy var controller = InboxCardController { [weak self] a in self?.onAction?(a) }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(controller.view)
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ data: [String: Any], strings: [String: String]) {
        self.strings = strings
        controller.strings = strings
        let cards = (data["cards"] as? [[String: Any]] ?? []).map(InboxCardController.card)
        var pending: InboxCardController.Pending?
        if let p = data["pending"] as? [String: Any], let id = p["card"] as? String {
            pending = .init(cardID: id, option: (p["option"] as? NSNumber)?.intValue ?? 0, label: p["label"] as? String ?? "",
                            start: Date(timeIntervalSince1970: (p["start"] as? NSNumber)?.doubleValue ?? 0),
                            deadline: Date(timeIntervalSince1970: (p["deadline"] as? NSNumber)?.doubleValue ?? 0))
        }
        var dictation: (active: Bool, text: String)?
        if let d = data["dictation"] as? [String: Any], (d["target"] as? String) == "inbox" { dictation = (d["active"] as? Bool ?? false, d["text"] as? String ?? "") }
        controller.update(cards: cards, current: data["current"] as? String, pending: pending, receipt: data["receipt"] as? String, dictation: dictation)
    }

    func layoutContent(width: CGFloat) -> CGFloat {
        let h = controller.view.measure(width: width)
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: h)
        return h
    }

    func handleKey(_ event: NSEvent) -> Bool { controller.key(event) }
    func focusField() { controller.view.focusReply() }
    func dictation(target: String, active: Bool, text: String) {}
}

// MARK: - the card

/// Draws the card and the hint pill under it, with a pointer on the toolbar's side.
final class CardView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 640
    static let margin: CGFloat = 16
    static let radius: CGFloat = 28
    static let pointer = NSSize(width: 9, height: 18)
    static let hintGap: CGFloat = 10
    /// Inside the side panel: no shape, pointer or margins of its own, the panel's width.
    var embedded = false
    private var contentWidth: CGFloat = CardView.width
    var onKey: ((NSEvent) -> Bool)?
    var onAction: ((String) -> Void)?
    /// The pointer's distance from the top of the panel (the header row's centre).
    var pointerY: CGFloat = CardView.margin + 36
    var pointerCenterY: CGFloat = 0 { didSet { needsDisplay = true } }

    private var edge = EdgeSide.right
    private var card: InboxCardController.Card?
    private var pending: InboxCardController.Pending?
    private var receipt: String?
    private var strings: [String: String] = [:]
    private var cardHeight: CGFloat = 200
    private var hintHeight: CGFloat = 30
    private var dictationActive = false
    private var dictationBase = ""

    // Subviews are rebuilt on every render (the card changes rarely); the reply field survives so typing is kept.
    private var built: [NSView] = []
    private let title = SurfaceStyle.label("", font: PanelStyle.font(16, .bold), color: PanelStyle.text, lines: 2)
    private let pager = PagerView()
    private let close = IconButton(symbol: "xmark", size: 28, symbolSize: 11, title: "Fechar")
    private let avatar = AgentAvatarView()
    private let name = SurfaceStyle.label("", font: PanelStyle.font(15, .semibold), color: PanelStyle.text)
    private let sub = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim)
    private let question = SurfaceStyle.label("", font: PanelStyle.font(16, .semibold), color: PanelStyle.text, lines: 4)
    private let command = SurfaceStyle.label("", font: PanelStyle.mono(13, .regular), color: PanelStyle.text, lines: 4)
    private let commandBox = CodeBoxView()
    private let detail = SurfaceStyle.label("", font: PanelStyle.font(14), color: PanelStyle.text, lines: 4)
    private let why = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim, lines: 3)
    private let reply = SurfaceStyle.label("", font: PanelStyle.font(14), color: PanelStyle.text, lines: 8)
    private let heading = SurfaceStyle.label("", font: PanelStyle.font(11, .semibold), color: PanelStyle.textFaint)
    private var rows: [OptionRowView] = []
    private let replyBox = ReplyFieldView()
    private var bottomButtons: [PillButton] = []
    private let hint = HintPill()
    private var loading: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v in [title, pager, close, avatar, name, sub, question, commandBox, detail, why, reply, heading, replyBox, hint] as [NSView] { addSubview(v) }
        commandBox.addSubview(command)
        close.onClick = { [weak self] in self?.onAction?("close") }
        pager.onPick = { [weak self] i in self?.onAction?("card:page:to:\(i)") }
        replyBox.onSubmit = { [weak self] text in
            guard let self, let c = self.card else { return }
            self.onAction?("card:reply:\(c.id)|\(text)")
            self.replyBox.text = ""
        }
        replyBox.onMic = { [weak self] in
            guard let self, let c = self.card else { return }
            self.dictationBase = self.replyBox.text
            self.onAction?("card:mic:\(c.id)")
        }
        replyBox.onEscape = { [weak self] in self?.window?.makeFirstResponder(self) }
        hint.onUndo = { [weak self] in self?.onAction?("undo") }
    }
    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    func endEditing() { window?.makeFirstResponder(nil) }
    func focusReply() { window?.makeFirstResponder(replyBox.field) }
    func tick() { hint.tick(pending: pending) }

    func render(card: InboxCardController.Card?, count: Int, index: Int, pending: InboxCardController.Pending?, receipt: String?,
                dictation: (active: Bool, text: String)?, strings: [String: String]) {
        let switched = card?.id != self.card?.id
        self.card = card
        self.pending = pending
        self.receipt = receipt
        self.strings = strings
        if switched { replyBox.text = ""; dictationBase = "" }
        if let dictation {
            if dictation.active || !dictation.text.isEmpty {
                replyBox.text = dictationBase.isEmpty ? dictation.text : dictationBase + " " + dictation.text
            }
            replyBox.listening = dictation.active
        } else {
            replyBox.listening = false
        }
        for v in built { v.removeFromSuperview() }
        built = []
        rows = []
        bottomButtons = []
        loading?.removeFromSuperview(); loading = nil
        guard let card else {
            title.stringValue = strings["emptyTitle"] ?? ""
            sub.stringValue = strings["emptyBody"] ?? ""
            name.stringValue = ""
            question.stringValue = ""
            command.stringValue = ""; detail.stringValue = ""; why.stringValue = ""
            reply.stringValue = ""
            heading.stringValue = ""
            pager.set(count: 0, index: 0)
            hint.render(kind: "", count: 0, pending: nil, receipt: nil, strings: strings)
            needsLayout = true
            return
        }
        title.stringValue = card.title
        pager.set(count: count, index: index)
        avatar.set(agent: card.agent, label: card.agentLabel, state: card.kind == "needsYou" ? "needsYou" : "done")
        name.stringValue = card.agentLabel
        sub.stringValue = card.place.isEmpty ? card.word : "\(card.word) · \(card.place)"
        question.stringValue = card.kind == "needsYou" ? (card.question ?? "") : ""
        command.stringValue = card.kind == "needsYou" ? (card.command ?? "") : ""
        detail.stringValue = card.kind == "needsYou" ? (card.detail ?? "") : ""
        why.stringValue = card.kind == "needsYou" ? (card.why ?? "") : ""
        reply.stringValue = card.kind == "finished" ? (card.reply ?? strings["noReply"] ?? "") : ""
        heading.stringValue = card.kind == "finished" && (!card.nextSteps.isEmpty || card.nextStepsLoading) ? (strings["nextSteps"] ?? "").uppercased() : ""
        let picked = pending?.cardID == card.id ? pending?.option : nil
        if card.kind == "needsYou" {
            for o in card.options {
                let r = OptionRowView(number: o.number, title: o.title, detail: o.detail, recommended: o.recommended, role: o.role, strings: strings)
                r.chosen = picked == o.number
                r.onClick = { [weak self] in self?.onAction?("card:pick:\(card.id)|\(o.number)") }
                addSubview(r); rows.append(r); built.append(r)
            }
            if card.options.isEmpty {
                let f = SurfaceStyle.label(strings["readingOptions"] ?? "", font: PanelStyle.font(13), color: PanelStyle.textDim)
                addSubview(f); loading = f; built.append(f)
            }
        } else {
            for (i, s) in card.nextSteps.enumerated() {
                let r = OptionRowView(number: i + 1, title: s, detail: nil, recommended: false, role: "plain", strings: strings)
                r.chosen = picked == i + 1
                r.onClick = { [weak self] in self?.onAction?("card:pick:\(card.id)|\(i + 1)") }
                addSubview(r); rows.append(r); built.append(r)
            }
            if card.nextSteps.isEmpty, card.nextStepsLoading {
                let f = SurfaceStyle.label(strings["suggesting"] ?? "", font: PanelStyle.font(13), color: PanelStyle.textDim)
                addSubview(f); loading = f; built.append(f)
            }
        }
        replyBox.placeholder = card.replyPlaceholder
        // Bottom row: open the session; Revisar / Arquivar for a finished turn, Dispensar for a question.
        func pill(_ key: String, _ symbol: String, _ color: NSColor, _ action: String) {
            let b = PillButton(title: strings[key] ?? key, symbol: symbol, color: color)
            b.onClick = { [weak self] in self?.onAction?(action) }
            addSubview(b); bottomButtons.append(b); built.append(b)
        }
        pill("cardOpen", "arrow.up.forward.app", PanelStyle.accent, "card:open:\(card.id)")
        if card.kind == "finished" {
            if card.canReview { pill("review", "doc.text.magnifyingglass", PanelStyle.accent, "card:review:\(card.id)") }
            pill("archive", "archivebox", PanelStyle.textDim, "card:clear:\(card.id)")
        } else {
            pill("dismiss", "eye.slash", PanelStyle.textDim, "card:clear:\(card.id)")
        }
        hint.render(kind: card.kind, count: card.kind == "needsYou" ? card.options.count : card.nextSteps.count, pending: pending, receipt: receipt, strings: strings)
        needsLayout = true
    }

    /// Lays the card out for `Self.width` and returns the panel's size (card + hint + margins).
    func measure(edge: EdgeSide) -> NSSize {
        self.edge = edge
        contentWidth = Self.width
        cardHeight = layoutContent(apply: false)
        hintHeight = hint.measure().height
        let w = Self.width + Self.margin * 2 + Self.pointer.width
        return NSSize(width: w, height: Self.margin + cardHeight + Self.hintGap + hintHeight + Self.margin)
    }

    /// Embedded: the content height for `width` (hint pill included).
    func measure(width: CGFloat) -> CGFloat {
        contentWidth = width
        cardHeight = layoutContent(apply: false)
        hintHeight = hint.measure().height
        return cardHeight + (hintHeight > 0 ? Self.hintGap + hintHeight : 0)
    }

    private var cardX: CGFloat { embedded ? 0 : Self.margin + (edge == .left ? Self.pointer.width : 0) }
    private var topY: CGFloat { embedded ? 0 : Self.margin }
    private var pad: CGFloat { embedded ? 0 : 22 }

    /// Stacks the content; returns the card's height. `apply` writes the frames.
    @discardableResult private func layoutContent(apply: Bool) -> CGFloat {
        let x0 = cardX, pad = self.pad
        let inner = contentWidth - pad * 2
        var y = topY + (embedded ? 4 : pad)
        let x = x0 + pad
        // Header: title, pager, ×.
        let pagerW = pager.measure().width
        let titleW = inner - (embedded ? 0 : 36) - (pagerW > 0 ? pagerW + 12 : 0)
        let titleH = max(22, SurfaceStyle.height(of: title, width: titleW))
        if apply {
            title.frame = NSRect(x: x, y: y, width: titleW, height: titleH)
            close.frame = NSRect(x: x + inner - 28, y: y - 3, width: 28, height: 28)
            close.isHidden = embedded   // the panel has its own ×
            pager.frame = NSRect(x: x + inner - (embedded ? 0 : 40) - pagerW, y: y + 8, width: pagerW, height: 8)
        }
        pointerY = y + 11
        y += titleH + 14
        if card != nil {
            // Agent row.
            let nameH: CGFloat = 19, subH: CGFloat = 17
            if apply {
                avatar.frame = NSRect(x: x, y: y, width: 40, height: 40)
                name.frame = NSRect(x: x + 52, y: y + 1, width: inner - 52, height: nameH)
                sub.frame = NSRect(x: x + 52, y: y + 1 + nameH + 2, width: inner - 52, height: subH)
            }
            y += 40 + 16
        } else {
            // Empty: the title and a line under it, centred. Measured the same way it is applied, so nothing is cut.
            let subH = max(18, SurfaceStyle.height(of: sub, width: inner))
            if apply {
                avatar.frame = .zero; name.frame = .zero
                sub.frame = NSRect(x: x, y: y, width: inner, height: subH)
            }
            y += subH + 12
        }
        let empty = card == nil
        title.alignment = empty ? .center : .left
        sub.alignment = empty ? .center : .left
        if !question.stringValue.isEmpty {
            let h = SurfaceStyle.height(of: question, width: inner)
            if apply { question.frame = NSRect(x: x, y: y, width: inner, height: h) }
            y += h + (command.stringValue.isEmpty && detail.stringValue.isEmpty ? 14 : 8)
        } else if apply { question.frame = .zero }
        if !command.stringValue.isEmpty {
            let h = SurfaceStyle.height(of: command, width: inner - 24)
            if apply {
                commandBox.frame = NSRect(x: x, y: y, width: inner, height: h + 16)
                command.frame = NSRect(x: 12, y: 8, width: inner - 24, height: h)
            }
            y += h + 16 + 10
        } else if apply { commandBox.frame = .zero }
        if !detail.stringValue.isEmpty {
            let h = SurfaceStyle.height(of: detail, width: inner)
            if apply { detail.frame = NSRect(x: x, y: y, width: inner, height: h) }
            y += h + 10
        } else if apply { detail.frame = .zero }
        if !why.stringValue.isEmpty {
            let h = SurfaceStyle.height(of: why, width: inner)
            if apply { why.frame = NSRect(x: x, y: y, width: inner, height: h) }
            y += h + 12
        } else if apply { why.frame = .zero }
        if !reply.stringValue.isEmpty {
            let h = SurfaceStyle.height(of: reply, width: inner)
            if apply { reply.frame = NSRect(x: x, y: y, width: inner, height: h) }
            y += h + 14
        } else if apply { reply.frame = .zero }
        if !heading.stringValue.isEmpty {
            if apply { heading.frame = NSRect(x: x + 2, y: y, width: inner, height: 14) }
            y += 14 + 6
        } else if apply { heading.frame = .zero }
        for r in rows {
            let h = r.height
            if apply { r.frame = NSRect(x: x, y: y, width: inner, height: h) }
            y += h + 6
        }
        if let loading {
            if apply { loading.frame = NSRect(x: x + 4, y: y, width: inner, height: 18) }
            y += 18 + 6
        }
        if !rows.isEmpty || loading != nil { y += 8 }
        if card != nil {
            if apply { replyBox.frame = NSRect(x: x, y: y, width: inner, height: 44) }
            y += 44 + 12
            var bx = x
            for b in bottomButtons {
                let s = b.measure()
                if apply { b.frame = NSRect(x: bx, y: y, width: s.width, height: s.height) }
                bx += s.width + 8
            }
            if let c = card, let change = c.change, apply {
                // "+12 −3" at the right of the bottom row.
                let f = SurfaceStyle.label(change, font: PanelStyle.mono(12, .semibold), color: PanelStyle.textDim, alignment: .right)
                f.frame = NSRect(x: x + inner - 120, y: y + 6, width: 120, height: 16)
                addSubview(f); built.append(f)
            }
            y += 30
        } else if apply { replyBox.frame = .zero }
        replyBox.isHidden = card == nil
        y += pad
        return y - topY
    }

    override func layout() {
        super.layout()
        cardHeight = layoutContent(apply: true)
        let hw = hint.measure().width
        hint.frame = NSRect(x: cardX + (contentWidth - hw) / 2, y: topY + cardHeight + Self.hintGap, width: hw, height: hintHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !embedded else { return }
        let r = NSRect(x: cardX, y: Self.margin, width: Self.width, height: cardHeight)
        let shape = NSBezierPath(roundedRect: r, xRadius: Self.radius, yRadius: Self.radius)
        // The pointer towards the Inbox button.
        let cy = bounds.height - pointerCenterY   // flipped
        let p = NSBezierPath()
        if edge == .right {
            p.move(to: NSPoint(x: r.maxX - 1, y: cy - Self.pointer.height / 2))
            p.line(to: NSPoint(x: r.maxX + Self.pointer.width, y: cy))
            p.line(to: NSPoint(x: r.maxX - 1, y: cy + Self.pointer.height / 2))
        } else {
            p.move(to: NSPoint(x: r.minX + 1, y: cy - Self.pointer.height / 2))
            p.line(to: NSPoint(x: r.minX - Self.pointer.width, y: cy))
            p.line(to: NSPoint(x: r.minX + 1, y: cy + Self.pointer.height / 2))
        }
        p.close()
        shape.append(p)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        PanelStyle.card.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        PanelStyle.hairline.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// A recessed box for a command ("Bash  mkdir probe_dir"), like the app's code blocks.
final class CodeBoxView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.raised.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// The card's page indicator: a short blue capsule for the card shown, a gray dot for each other one.
final class PagerView: NSView {
    private var count = 0
    private var index = 0
    var onPick: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    func set(count: Int, index: Int) { self.count = count; self.index = index; needsDisplay = true }

    func measure() -> NSSize {
        guard count > 1 else { return .zero }
        return NSSize(width: 18 + CGFloat(count - 1) * (6 + 5), height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 1 else { return }
        var x: CGFloat = 0
        for i in 0..<count {
            if i == index {
                PanelStyle.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: 18, height: 6), xRadius: 3, yRadius: 3).fill()
                x += 18 + 5
            } else {
                PanelStyle.textFaint.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: 1, width: 6, height: 6)).fill()
                x += 6 + 5
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var x: CGFloat = 0
        for i in 0..<count {
            let w: CGFloat = i == index ? 18 : 6
            if p.x >= x - 3 && p.x <= x + w + 3 { onPick?(i); return }
            x += w + 5
        }
    }
}

/// The agent's letter in its brand color, with the state's dot at its corner.
final class AgentAvatarView: NSView {
    private var letter = "?"
    private var color = SurfaceStyle.gray
    private var state = "needsYou"
    private var label = ""

    func set(agent: String?, label: String, state: String) {
        self.label = label
        self.state = state
        let a = (agent ?? "").lowercased()
        letter = switch a {
        case "claude": "C"
        case "codex": "X"
        case "gemini": "G"
        case "opencode": "O"
        case "aider": "A"
        case "": "?"
        default: String(a.prefix(1)).uppercased()
        }
        color = SurfaceStyle.agentColor(agent)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width * 0.3, yRadius: r.width * 0.3).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r.width * 0.46, weight: .bold), .foregroundColor: color]
        let s = (letter as NSString).size(withAttributes: attrs)
        (letter as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        // The state dot at the corner, ringed by the card so it reads over the avatar.
        let d: CGFloat = 11
        let dot = NSRect(x: r.maxX - d - 1, y: r.minY + 1, width: d, height: d)
        PanelStyle.card.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2)).fill()
        PanelStyle.color(forState: state).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    override func accessibilityLabel() -> String? { label }
}

/// One answer (or a suggested next step): keycap, words, "Recomendado"; green with a check once chosen.
final class OptionRowView: ClickableView {
    private let keycap: KeycapView
    private let titleField: NSTextField
    private let detailField: NSTextField?
    private let recommended: PillLabel?
    var chosen = false {
        didSet { keycap.chosen = chosen; needsDisplay = true }
    }

    init(number: Int, title: String, detail: String?, recommended: Bool, role: String, strings: [String: String]) {
        keycap = KeycapView("\(number)")
        let color: NSColor = switch role {
        case "allow", "always": PanelStyle.green
        case "deny": PanelStyle.red
        default: PanelStyle.text
        }
        keycap.tint = role == "plain" ? PanelStyle.accent : color
        titleField = SurfaceStyle.label(title, font: PanelStyle.font(14, .medium), color: color)
        detailField = (detail?.isEmpty == false && detail != title) ? SurfaceStyle.label(detail ?? "", font: PanelStyle.font(12), color: PanelStyle.textDim) : nil
        self.recommended = recommended ? PillLabel(strings["recommended"] ?? "Recomendado", font: PanelStyle.font(11, .semibold), color: PanelStyle.green,
                                                   fill: PanelStyle.green.withAlphaComponent(0.16)) : nil
        super.init(frame: .zero)
        addSubview(keycap)
        addSubview(titleField)
        if let detailField { addSubview(detailField) }
        if let pill = self.recommended { pill.sizeToFit(); addSubview(pill) }
        accessibilityTitle = recommended ? "\(number). \(title), \(strings["recommended"] ?? "Recomendado")" : "\(number). \(title)"
    }
    required init?(coder: NSCoder) { nil }

    var height: CGFloat { detailField == nil ? 52 : 60 }

    override func layout() {
        super.layout()
        keycap.frame = NSRect(x: 14, y: (bounds.height - 22) / 2, width: 22, height: 22)
        var right = bounds.width - 14
        if let recommended {
            right -= recommended.frame.width + 10
            recommended.frame.origin = NSPoint(x: bounds.width - 14 - recommended.frame.width, y: (bounds.height - recommended.frame.height) / 2)
        }
        let x: CGFloat = 14 + 22 + 12
        if let detailField {
            titleField.frame = NSRect(x: x, y: 11, width: right - x, height: 18)
            detailField.frame = NSRect(x: x, y: 31, width: right - x, height: 16)
        } else {
            titleField.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: right - x, height: 18)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        if chosen {
            PanelStyle.green.withAlphaComponent(0.16).setFill(); p.fill()
            PanelStyle.green.withAlphaComponent(0.45).setStroke(); p.lineWidth = 1; p.stroke()
            return
        }
        (hovered || pressed ? PanelStyle.wash : NSColor.clear).setFill()
        PanelStyle.raised.setFill(); p.fill()
        if hovered || pressed { PanelStyle.wash.setFill(); p.fill() }
        if recommended != nil { PanelStyle.green.withAlphaComponent(0.35).setStroke(); p.lineWidth = 1; p.stroke() }
    }
}

/// "Responder a Claude…" with a microphone and a send button inside.
final class ReplyFieldView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let mic = IconButton(symbol: "mic.fill", size: 28, symbolSize: 13, title: "Ditar")
    private let sendButton = IconButton(symbol: "paperplane.fill", size: 28, symbolSize: 12, title: "Enviar")
    var onSubmit: ((String) -> Void)?
    var onMic: (() -> Void)?
    var onEscape: (() -> Void)?
    var listening = false { didSet { mic.tint = listening ? PanelStyle.red : PanelStyle.textDim; needsDisplay = true } }
    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { field.placeholderString = newValue }
    }
    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; textChanged() }
    }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = PanelStyle.font(14)
        field.textColor = PanelStyle.text
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        addSubview(mic)
        addSubview(sendButton)
        mic.tint = PanelStyle.textDim
        mic.onClick = { [weak self] in self?.onMic?() }
        sendButton.onClick = { [weak self] in self?.submit() }
        textChanged()
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        sendButton.frame = NSRect(x: bounds.width - 8 - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
        mic.frame = NSRect(x: sendButton.frame.minX - 4 - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
        field.frame = NSRect(x: 14, y: (bounds.height - 20) / 2, width: mic.frame.minX - 8 - 14, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        PanelStyle.raised.setFill(); p.fill()
        let focused = window?.firstResponder.map { ($0 as? NSTextView)?.delegate === field } ?? false
        (listening ? PanelStyle.red.withAlphaComponent(0.5) : focused ? PanelStyle.accent.withAlphaComponent(0.45) : PanelStyle.hairline).setStroke()
        p.lineWidth = 1; p.stroke()
        // The send button is a filled circle once there are words.
        let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        (canSend ? PanelStyle.accent : PanelStyle.textFaint.withAlphaComponent(0.5)).setFill()
        NSBezierPath(ovalIn: sendButton.frame.insetBy(dx: 2, dy: 2)).fill()
    }

    private func textChanged() {
        sendButton.tint = PanelStyle.onFill
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) { textChanged() }
    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        return false
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSubmit?(t)
    }
}

/// A small pill button with a symbol and words ("Abrir sessão", "Revisar", "Arquivar"), and an optional suffix ("+12 −3").
final class PillButton: ClickableView {
    private let image = NSImageView()
    private let label: NSTextField
    private let color: NSColor
    private var base: String
    var title: String {
        get { base }
        set { base = newValue; label.stringValue = suffix.map { "\(newValue)  \($0)" } ?? newValue; accessibilityTitle = newValue; needsLayout = true }
    }
    var suffix: String? { didSet { title = base } }

    init(title: String, symbol: String, color: NSColor) {
        self.color = color
        self.base = title
        label = SurfaceStyle.label(title, font: PanelStyle.font(12, .semibold), color: color)
        super.init(frame: .zero)
        image.image = SurfaceStyle.symbol(symbol, size: 11)
        image.contentTintColor = color
        addSubview(image)
        addSubview(label)
        accessibilityTitle = title
    }
    required init?(coder: NSCoder) { nil }

    func measure() -> NSSize {
        let w = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? PanelStyle.font(12, .semibold)]).width
        return NSSize(width: ceil(w) + 11 + 16 + 5 + 12, height: 28)
    }

    override func layout() {
        super.layout()
        image.frame = NSRect(x: 11, y: (bounds.height - 14) / 2, width: 16, height: 14)
        label.frame = NSRect(x: 11 + 16 + 5, y: (bounds.height - 16) / 2, width: bounds.width - 32 - 10, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(hovered || pressed ? 0.22 : 0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Under the card: "Pressione 1, 2 ou 3 para responder", "Enviando… Esc desfaz" (with the window's ring), "✓ Enviado para …".
final class HintPill: NSView {
    private var segments: [NSView] = []
    private var pending: InboxCardController.Pending?
    private var progress: CGFloat = 0
    private var undoButton: ClickableView?
    var onUndo: (() -> Void)?
    override var isFlipped: Bool { true }

    private func text(_ s: String, color: NSColor = PanelStyle.textDim, weight: NSFont.Weight = .medium) -> NSTextField {
        let f = SurfaceStyle.label(s, font: PanelStyle.font(12, weight), color: color)
        f.frame.size = f.sizeThatFits(NSSize(width: 500, height: 20))
        return f
    }
    private func key(_ n: Int) -> KeycapView {
        let k = KeycapView("\(n)")
        k.small = true
        k.frame.size = NSSize(width: 18, height: 18)
        return k
    }
    private func icon(_ name: String, color: NSColor) -> NSImageView {
        let v = NSImageView()
        v.image = SurfaceStyle.symbol(name, size: 11, weight: .bold)
        v.contentTintColor = color
        v.frame.size = NSSize(width: 14, height: 14)
        return v
    }

    func render(kind: String, count: Int, pending: InboxCardController.Pending?, receipt: String?, strings: [String: String]) {
        for s in segments { s.removeFromSuperview() }
        segments = []
        undoButton = nil
        self.pending = pending
        if let receipt {
            segments = [icon("checkmark", color: PanelStyle.green), text(receipt, color: PanelStyle.text, weight: .semibold)]
        } else if pending != nil {
            let ring = RingView()
            ring.frame.size = NSSize(width: 14, height: 14)
            segments = [ring, text(strings["sending"] ?? "Enviando…", color: PanelStyle.text, weight: .semibold)]
            let undo = text(strings["undoEsc"] ?? "Esc desfaz", color: PanelStyle.accent, weight: .semibold)
            let button = ClickableView(frame: NSRect(origin: .zero, size: undo.frame.size))
            button.addSubview(undo)
            button.onClick = { [weak self] in self?.onUndo?() }
            button.accessibilityTitle = undo.stringValue
            undoButton = button
            segments.append(button)
        } else if count > 0 {
            segments = [text(strings["hintPress"] ?? "Pressione")]
            let n = min(count, 9)
            for i in 1...n {
                segments.append(key(i))
                if i < n - 1 { segments.append(text(",")) } else if i == n - 1 { segments.append(text(strings["hintOr"] ?? "ou")) }
            }
            segments.append(text(kind == "needsYou" ? (strings["hintAnswer"] ?? "para responder") : (strings["hintNext"] ?? "para mandar um próximo passo")))
        } else if !kind.isEmpty {
            segments = [key(0), text(strings["hintKeys"] ?? "")]
            segments.removeFirst()
        }
        for s in segments { addSubview(s) }
        needsLayout = true
        needsDisplay = true
    }

    func measure() -> NSSize {
        guard !segments.isEmpty else { return .zero }
        let w = segments.reduce(0) { $0 + $1.frame.width } + CGFloat(segments.count - 1) * 5 + 14 * 2
        return NSSize(width: ceil(w), height: 30)
    }

    func tick(pending: InboxCardController.Pending?) {
        guard let pending else { return }
        let total = pending.deadline.timeIntervalSince(pending.start)
        progress = total > 0 ? CGFloat(min(1, max(0, Date().timeIntervalSince(pending.start) / total))) : 1
        (segments.first as? RingView)?.progress = progress
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 14
        for s in segments {
            s.frame.origin = NSPoint(x: x, y: (bounds.height - s.frame.height) / 2)
            x += s.frame.width + 5
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else { return }
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        PanelStyle.card.setFill(); p.fill()
        PanelStyle.hairline.setStroke(); p.lineWidth = 1; p.stroke()
    }
}

/// The undo window's ring, shrinking as the seconds pass.
final class RingView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = 2
        PanelStyle.hairline.setStroke(); track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: 90, endAngle: 90 - 360 * (1 - progress), clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        PanelStyle.accent.setStroke(); arc.stroke()
    }
}
