import AppKit

// The side panel's screens besides the Inbox: the agents, one agent, a new task or chat, the project picker, Falar.
// Each reads the app's payload (`PanelDataSink.apply`) and sends plain actions back; every layout is a vertical stack
// measured for the panel's width (`layoutContent`), so the panel sizes itself to the content.

/// A vertical stack laid out by hand: `place` positions a view at the running y and advances it.
struct Stacker {
    var y: CGFloat = 0
    let width: CGFloat
    let apply: Bool
    init(width: CGFloat, apply: Bool) { self.width = width; self.apply = apply }
    mutating func place(_ v: NSView, height: CGFloat, x: CGFloat = 0, width w: CGFloat? = nil, gap: CGFloat = 10) {
        if apply { v.frame = NSRect(x: x, y: y, width: w ?? width - x, height: height); v.isHidden = false }
        y += height + gap
    }
    mutating func skip(_ v: NSView) { if apply { v.isHidden = true } }
    mutating func gap(_ g: CGFloat) { y += g }
}

/// A small uppercase heading over a group of rows.
func panelHeading(_ text: String) -> NSTextField {
    SurfaceStyle.label(text.uppercased(), font: PanelStyle.font(11, .semibold), color: PanelStyle.textFaint)
}

/// The agent's letter and its state dot, with the title and where it runs.
final class AgentRow: ClickableView {
    private let avatar = AgentAvatarView()
    private let title = SurfaceStyle.label("", font: PanelStyle.font(14, .semibold), color: PanelStyle.text)
    private let sub = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.textDim)
    private let side = SurfaceStyle.label("", font: PanelStyle.font(12).withMonospacedDigits, color: PanelStyle.textFaint, alignment: .right)
    static let height: CGFloat = 58

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [avatar, title, sub, side] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { nil }

    func set(_ a: [String: Any], strings: [String: String]) {
        let state = a["state"] as? String ?? "ready"
        avatar.set(agent: a["agent"] as? String, label: a["agentLabel"] as? String ?? "", state: state)
        title.stringValue = a["title"] as? String ?? ""
        let word = a["word"] as? String ?? ""
        let project = a["project"] as? String ?? ""
        var detail = project.isEmpty ? word : "\(word) · \(project)"
        if let step = a["step"] as? String, !step.isEmpty, state == "working" { detail = "\(step) · \(project)" }
        sub.stringValue = detail
        sub.textColor = state == "needsYou" ? PanelStyle.orange : PanelStyle.textDim
        if let since = (a["since"] as? NSNumber)?.doubleValue { side.stringValue = Elapsed.short(since: Date(timeIntervalSince1970: since)) }
        accessibilityTitle = "\(title.stringValue), \(detail)"
    }

    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 12, y: (bounds.height - 36) / 2, width: 36, height: 36)
        side.frame = NSRect(x: bounds.width - 12 - 54, y: 12, width: 54, height: 16)
        title.frame = NSRect(x: 60, y: 11, width: bounds.width - 60 - 72, height: 18)
        sub.frame = NSRect(x: 60, y: 31, width: bounds.width - 60 - 72, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        PanelStyle.card.setFill(); p.fill()
        if hovered || pressed { PanelStyle.wash.setFill(); p.fill() }
        PanelStyle.hairline.setStroke(); p.lineWidth = 1; p.stroke()
    }
}

enum Elapsed {
    /// "12s", "3min", "2h 05min", "3d".
    static func short(since date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)min" }
        if s < 86400 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))min" }
        return "\(s / 86400)d"
    }
}

extension NSFont {
    var withMonospacedDigits: NSFont {
        let d = fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                       NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

// MARK: - agents

/// Every live agent: a row each (state, title, project, step or how long), a click opens it in the panel.
final class AgentsScreen: NSView, PanelScreenView, PanelDataSink {
    var onAction: ((String) -> Void)?
    var title: String { strings["agents"] ?? "Agentes" }
    private var strings: [String: String] = [:]
    private var rows: [AgentRow] = []
    private var ids: [String] = []
    private let empty = SurfaceStyle.label("", font: PanelStyle.font(14), color: PanelStyle.textDim, lines: 3, alignment: .center)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) { super.init(frame: frame); addSubview(empty) }
    required init?(coder: NSCoder) { nil }

    func apply(_ data: [String: Any], strings: [String: String]) {
        self.strings = strings
        let agents = data["agents"] as? [[String: Any]] ?? []
        while rows.count < agents.count { let r = AgentRow(); addSubview(r); rows.append(r) }
        while rows.count > agents.count { rows.removeLast().removeFromSuperview() }
        ids = agents.map { $0["id"] as? String ?? "" }
        for (r, a) in zip(rows, agents) {
            r.set(a, strings: strings)
            let id = a["id"] as? String ?? ""
            r.onClick = { [weak self] in self?.onAction?("panel:show:agent:\(id)") }
        }
        empty.stringValue = agents.isEmpty ? (strings["noAgents"] ?? "") : ""
        needsLayout = true
    }

    func layoutContent(width: CGFloat) -> CGFloat {
        var st = Stacker(width: width, apply: true)
        for r in rows { st.place(r, height: AgentRow.height, gap: 8) }
        if rows.isEmpty { st.place(empty, height: 60, gap: 0) } else { st.skip(empty) }
        return max(st.y, 20)
    }
}

// MARK: - one agent

/// One agent, in the panel: its state and step, the question with its answers while it waits, the last reply, the
/// suggested next steps when its turn ended, a reply field with dictation, and the actions (Interromper, Arquivar,
/// Revisar; "Abrir no Pier" small, the secondary way out).
final class AgentScreen: NSView, PanelScreenView, PanelDataSink {
    let id: String
    var onAction: ((String) -> Void)?
    private(set) var title = ""
    private var strings: [String: String] = [:]
    private var detail: [String: Any] = [:]
    private var pending: [String: Any]?
    private var receipt: String?
    private var dictationBase = ""

    private let avatar = AgentAvatarView()
    private let name = SurfaceStyle.label("", font: PanelStyle.font(15, .semibold), color: PanelStyle.text)
    private let sub = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim)
    private let elapsed = SurfaceStyle.label("", font: PanelStyle.font(12).withMonospacedDigits, color: PanelStyle.textFaint, alignment: .right)
    private let stepLine = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.accent, lines: 2)
    private let question = SurfaceStyle.label("", font: PanelStyle.font(16, .semibold), color: PanelStyle.text, lines: 4)
    private let command = SurfaceStyle.label("", font: PanelStyle.mono(12), color: PanelStyle.text, lines: 4)
    private let commandBox = CodeBoxView()
    private let why = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim, lines: 3)
    private var optionRows: [OptionRowView] = []
    private let replyHeading = panelHeading("")
    private let reply = MarkdownView()
    private let stepsHeading = panelHeading("")
    private var stepRows: [OptionRowView] = []
    private let loading = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim)
    private let composer = ReplyFieldView()
    private let hint = HintPill()
    private var actions: [PillButton] = []
    private let openLink = ClickableView()
    private let openLabel = SurfaceStyle.label("", font: PanelStyle.font(12, .medium), color: PanelStyle.textDim)
    private var ticker: Timer?
    override var isFlipped: Bool { true }

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        for v in [avatar, name, sub, elapsed, stepLine, question, commandBox, why, replyHeading, reply, stepsHeading, loading, composer, hint, openLink] as [NSView] { addSubview(v) }
        commandBox.addSubview(command)
        openLink.addSubview(openLabel)
        openLink.onClick = { [weak self] in guard let self else { return }; self.onAction?("agent:open:\(self.id)") }
        composer.onSubmit = { [weak self] text in
            guard let self else { return }
            self.onAction?("agent:send:\(self.id)|\(text)")
            self.composer.text = ""
        }
        composer.onMic = { [weak self] in
            guard let self else { return }
            self.dictationBase = self.composer.text
            self.onAction?("dictation:toggle:agent:\(self.id)")
        }
        composer.onEscape = { [weak self] in self?.window?.makeFirstResponder(self?.superview) }
        hint.onUndo = { [weak self] in self?.onAction?("agent:undo") }
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ data: [String: Any], strings: [String: String]) {
        self.strings = strings
        let d = (data["agentDetail"] as? [String: Any]).flatMap { ($0["id"] as? String) == id ? $0 : nil }
        let listed = (data["agents"] as? [[String: Any]])?.first { ($0["id"] as? String) == id }
        detail = d ?? listed ?? ["id": id, "starting": true]
        let p = data["pending"] as? [String: Any]
        pending = (p?["card"] as? String) == id ? p : nil
        receipt = (data["receiptFor"] as? String) == id ? data["receipt"] as? String : nil
        render()
        if pending != nil, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if pending == nil { ticker?.invalidate(); ticker = nil }
    }

    private func tick() {
        guard let p = pending else { return }
        hint.tick(pending: .init(cardID: id, option: (p["option"] as? NSNumber)?.intValue ?? 0, label: "",
                                 start: Date(timeIntervalSince1970: (p["start"] as? NSNumber)?.doubleValue ?? 0),
                                 deadline: Date(timeIntervalSince1970: (p["deadline"] as? NSNumber)?.doubleValue ?? 0)))
        if let since = (detail["since"] as? NSNumber)?.doubleValue { elapsed.stringValue = Elapsed.short(since: Date(timeIntervalSince1970: since)) }
    }

    private func render() {
        let d = detail
        let state = d["state"] as? String ?? "ready"
        let starting = d["starting"] as? Bool ?? false
        title = d["title"] as? String ?? (strings["agent"] ?? "Agente")
        avatar.set(agent: d["agent"] as? String, label: d["agentLabel"] as? String ?? "", state: state)
        name.stringValue = d["agentLabel"] as? String ?? ""
        let word = starting ? (strings["starting"] ?? "Iniciando…") : (d["word"] as? String ?? "")
        let project = d["project"] as? String ?? ""
        sub.stringValue = project.isEmpty ? word : "\(word) · \(project)"
        sub.textColor = state == "needsYou" ? PanelStyle.orange : PanelStyle.textDim
        elapsed.stringValue = (d["since"] as? NSNumber).map { Elapsed.short(since: Date(timeIntervalSince1970: $0.doubleValue)) } ?? ""
        stepLine.stringValue = state == "working" ? (d["step"] as? String ?? (strings["workingStep"] ?? "")) : ""
        let waiting = state == "needsYou"
        question.stringValue = waiting ? (d["question"] as? String ?? "") : ""
        command.stringValue = waiting ? (d["command"] as? String ?? "") : ""
        why.stringValue = waiting ? (d["why"] as? String ?? d["detail"] as? String ?? "") : ""
        for r in optionRows { r.removeFromSuperview() }
        optionRows = []
        let chosen = (pending?["option"] as? NSNumber)?.intValue
        if waiting {
            for o in d["options"] as? [[String: Any]] ?? [] {
                let n = (o["number"] as? NSNumber)?.intValue ?? 0
                let r = OptionRowView(number: n, title: o["title"] as? String ?? "", detail: o["detail"] as? String,
                                      recommended: o["recommended"] as? Bool ?? false, role: o["role"] as? String ?? "plain", strings: strings)
                r.chosen = chosen == n
                r.onClick = { [weak self] in guard let self else { return }; self.onAction?("agent:pick:\(self.id)|\(n)") }
                addSubview(r); optionRows.append(r)
            }
        }
        let replyText = d["reply"] as? String ?? ""
        replyHeading.stringValue = replyText.isEmpty ? "" : (strings["lastReply"] ?? "Última resposta").uppercased()
        reply.set(markdown: replyText)
        for r in stepRows { r.removeFromSuperview() }
        stepRows = []
        let steps = d["nextSteps"] as? [String] ?? []
        stepsHeading.stringValue = steps.isEmpty && !(d["nextStepsLoading"] as? Bool ?? false) ? "" : (strings["nextSteps"] ?? "").uppercased()
        for (i, s) in steps.enumerated() {
            let r = OptionRowView(number: i + 1, title: s, detail: nil, recommended: false, role: "plain", strings: strings)
            r.chosen = chosen == i + 1 && !waiting
            r.onClick = { [weak self] in guard let self else { return }; self.onAction?("agent:pick:\(self.id)|\(i + 1)") }
            addSubview(r); stepRows.append(r)
        }
        loading.stringValue = (d["nextStepsLoading"] as? Bool ?? false) && steps.isEmpty ? (strings["suggesting"] ?? "") : ""
        composer.placeholder = d["replyPlaceholder"] as? String ?? (strings["message"] ?? "")
        composer.isHidden = starting
        for a in actions { a.removeFromSuperview() }
        actions = []
        func pill(_ key: String, _ symbol: String, _ color: NSColor, _ action: String) {
            let b = PillButton(title: strings[key] ?? key, symbol: symbol, color: color)
            b.onClick = { [weak self] in self?.onAction?(action) }
            addSubview(b); actions.append(b)
        }
        if d["canInterrupt"] as? Bool ?? false { pill("interrupt", "stop.fill", PanelStyle.red, "agent:interrupt:\(id)") }
        if d["canArchive"] as? Bool ?? false { pill("archive", "archivebox", PanelStyle.textDim, "agent:archive:\(id)") }
        if d["canReview"] as? Bool ?? false {
            let change = d["change"] as? String
            pill("review", "doc.text.magnifyingglass", PanelStyle.accent, "agent:review:\(id)")
            if let change, let last = actions.last { last.accessibilityTitle = "\(strings["review"] ?? "") \(change)"; last.suffix = change }
        }
        openLabel.stringValue = strings["openInPier"] ?? "Abrir no Pier"
        openLink.accessibilityTitle = openLabel.stringValue
        hint.render(kind: waiting ? "needsYou" : "finished", count: waiting ? optionRows.count : stepRows.count, pending: pending.map {
            .init(cardID: id, option: ($0["option"] as? NSNumber)?.intValue ?? 0, label: "", start: Date(timeIntervalSince1970: ($0["start"] as? NSNumber)?.doubleValue ?? 0),
                  deadline: Date(timeIntervalSince1970: ($0["deadline"] as? NSNumber)?.doubleValue ?? 0))
        }, receipt: receipt, strings: strings)
        hint.isHidden = hint.measure().width == 0
        needsLayout = true
    }

    func layoutContent(width: CGFloat) -> CGFloat {
        var st = Stacker(width: width, apply: true)
        // Header: avatar, name over state · project, elapsed at the right.
        avatar.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        name.frame = NSRect(x: 52, y: 1, width: width - 52 - 60, height: 19)
        sub.frame = NSRect(x: 52, y: 22, width: width - 52 - 60, height: 17)
        elapsed.frame = NSRect(x: width - 60, y: 2, width: 60, height: 16)
        st.y = 40 + 14
        if !stepLine.stringValue.isEmpty { st.place(stepLine, height: SurfaceStyle.height(of: stepLine, width: width), gap: 12) } else { st.skip(stepLine) }
        if !question.stringValue.isEmpty { st.place(question, height: SurfaceStyle.height(of: question, width: width), gap: 8) } else { st.skip(question) }
        if !command.stringValue.isEmpty {
            let h = SurfaceStyle.height(of: command, width: width - 24)
            st.place(commandBox, height: h + 16, gap: 8)
            command.frame = NSRect(x: 12, y: 8, width: width - 24, height: h)
        } else { st.skip(commandBox) }
        if !why.stringValue.isEmpty { st.place(why, height: SurfaceStyle.height(of: why, width: width), gap: 12) } else { st.skip(why) }
        for r in optionRows { st.place(r, height: r.height, gap: 6) }
        if !optionRows.isEmpty { st.gap(8) }
        if !replyHeading.stringValue.isEmpty {
            st.place(replyHeading, height: 14, gap: 6)
            st.place(reply, height: reply.height(for: width), gap: 14)
        } else { st.skip(replyHeading); st.skip(reply) }
        if !stepsHeading.stringValue.isEmpty { st.place(stepsHeading, height: 14, gap: 6) } else { st.skip(stepsHeading) }
        for r in stepRows { st.place(r, height: r.height, gap: 6) }
        if !loading.stringValue.isEmpty { st.place(loading, height: 18, gap: 8) } else { st.skip(loading) }
        if !stepRows.isEmpty { st.gap(6) }
        if !composer.isHidden { st.place(composer, height: 44, gap: 10) }
        if !hint.isHidden {
            let w = hint.measure().width
            st.place(hint, height: 30, x: (width - w) / 2, width: w, gap: 10)
        }
        var x: CGFloat = 0
        let rowY = st.y
        for a in actions {
            let s = a.measure()
            a.frame = NSRect(x: x, y: rowY, width: s.width, height: s.height)
            x += s.width + 8
        }
        let ow = (openLabel.stringValue as NSString).size(withAttributes: [.font: openLabel.font ?? PanelStyle.font(12)]).width + 8
        openLink.frame = NSRect(x: width - ow, y: rowY + 6, width: ow, height: 18)
        openLabel.frame = NSRect(x: 0, y: 0, width: ow, height: 18)
        st.y = rowY + 30
        return st.y
    }

    func handleKey(_ e: NSEvent) -> Bool {
        guard let chars = e.charactersIgnoringModifiers, !e.modifierFlags.contains(.command) else { return false }
        if e.keyCode == 53, pending != nil { onAction?("agent:undo"); return true }
        if let n = Int(chars), (1...9).contains(n) { onAction?("agent:pick:\(id)|\(n)"); return true }
        if chars == "r" { onAction?("panel:focus"); return true }
        if chars == "e", detail["canArchive"] as? Bool ?? false { onAction?("agent:archive:\(id)"); return true }
        return false
    }

    func focusField() { window?.makeFirstResponder(composer.field) }

    func dictation(target: String, active: Bool, text: String) {
        guard target == "agent:\(id)" else { return }
        if active || !text.isEmpty { composer.text = dictationBase.isEmpty ? text : dictationBase + " " + text }
        composer.listening = active
    }
}

/// Markdown in a non-editable text view, sized to its text.
final class MarkdownView: NSView {
    private let text = NSTextView()
    private var attributed = NSAttributedString()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        // The same 2 pt the panel's labels (text field cells) draw their text in from, so body text, headings and rows
        // line up on one left edge.
        text.textContainerInset = NSSize(width: Self.inset, height: 0)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        addSubview(text)
    }
    required init?(coder: NSCoder) { nil }

    private static let inset: CGFloat = 2

    func set(markdown: String) {
        attributed = MarkdownText.render(markdown)
        text.textStorage?.setAttributedString(attributed)
    }

    func height(for width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        text.textContainer?.containerSize = NSSize(width: width - Self.inset * 2, height: 100_000)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let h = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0
        return min(ceil(h) + 2, 320)
    }

    override func layout() {
        super.layout()
        text.frame = bounds
        text.textContainer?.containerSize = NSSize(width: bounds.width - Self.inset * 2, height: 100_000)
    }
}

// MARK: - new task / chat

/// A new task like the app's (ComposeModel's rules on the app's side): the project, a new worktree or the main one, the
/// agent, model and effort, the prompt (⌘↩ starts, the mic dictates, the camera attaches a part of the screen) — or a chat
/// with no project. The panel shows the new agent once it started.
final class ComposeScreen: NSView, PanelScreenView, PanelDataSink, NSTextViewDelegate {
    private(set) var chat: Bool
    var onAction: ((String) -> Void)?
    var title: String { chat ? (strings["newChat"] ?? "Nova conversa") : (strings["newTask"] ?? "Nova tarefa") }
    private var strings: [String: String] = [:]
    private var data: [String: Any] = [:]
    private var dictationBase = ""

    private let kind = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let projectHeading = panelHeading("")
    private let project = ClickableView()
    private let projectName = SurfaceStyle.label("", font: PanelStyle.font(14, .semibold), color: PanelStyle.text)
    private let projectBox = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.textDim)
    private let chevron = NSImageView()
    private let worktreeHeading = panelHeading("")
    private let worktree = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let agentHeading = panelHeading("")
    private let agent = NSSegmentedControl(labels: [""], trackingMode: .selectOne, target: nil, action: nil)
    private let modelHeading = panelHeading("")
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortHeading = panelHeading("")
    private let effort = NSPopUpButton(frame: .zero, pullsDown: false)
    private let promptBox = CodeBoxView()
    private let prompt = NSTextView()
    private let placeholder = SurfaceStyle.label("", font: PanelStyle.font(14), color: PanelStyle.textFaint)
    private let mic = IconButton(symbol: "mic.fill", size: 32, symbolSize: 15, title: "Ditar")
    private let camera = IconButton(symbol: "camera.fill", size: 32, symbolSize: 15, title: "Apontar")
    private let imageChip = PillLabel("", font: PanelStyle.font(12, .medium), color: PanelStyle.text, fill: PanelStyle.raised)
    private let start = PillButton(title: "", symbol: "arrow.up", color: PanelStyle.accent)
    private let summary = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.textFaint, lines: 2)
    private let error = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.red, lines: 3)
    override var isFlipped: Bool { true }

    init(chat: Bool) {
        self.chat = chat
        super.init(frame: .zero)
        for v in [kind, projectHeading, project, worktreeHeading, worktree, agentHeading, agent, modelHeading, model, effortHeading, effort,
                  promptBox, mic, camera, imageChip, start, summary, error] as [NSView] { addSubview(v) }
        project.addSubview(projectName); project.addSubview(projectBox); project.addSubview(chevron)
        chevron.image = SurfaceStyle.symbol("chevron.right", size: 12)
        chevron.contentTintColor = PanelStyle.textFaint
        project.onClick = { [weak self] in self?.onAction?("panel:show:project") }
        kind.target = self; kind.action = #selector(kindChanged)
        worktree.target = self; worktree.action = #selector(worktreeChanged)
        agent.target = self; agent.action = #selector(agentChanged)
        model.target = self; model.action = #selector(modelChanged)
        effort.target = self; effort.action = #selector(effortChanged)
        for c in [kind, worktree, agent] { c.segmentStyle = .rounded; c.controlSize = .regular }
        promptBox.addSubview(prompt); promptBox.addSubview(placeholder)
        prompt.delegate = self
        prompt.drawsBackground = false
        prompt.font = PanelStyle.font(14)
        prompt.textColor = PanelStyle.text
        prompt.insertionPointColor = PanelStyle.text
        prompt.textContainerInset = NSSize(width: 0, height: 0)
        prompt.textContainer?.lineFragmentPadding = 0
        prompt.isRichText = false
        prompt.allowsUndo = true
        mic.onBlack = true; camera.onBlack = true
        mic.onClick = { [weak self] in
            guard let self else { return }
            self.dictationBase = self.prompt.string
            self.onAction?("dictation:toggle:compose")
        }
        camera.onClick = { [weak self] in self?.onAction?("compose:camera") }
        start.onClick = { [weak self] in self?.submit() }
        imageChip.padding = NSSize(width: 10, height: 5)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func kindChanged() { onAction?("compose:kind:\(kind.selectedSegment == 1 ? "chat" : "task")") }
    @objc private func worktreeChanged() { onAction?("compose:worktree:\(worktree.selectedSegment == 1 ? "main" : "new")") }
    @objc private func agentChanged() {
        let agents = data["agents"] as? [[String: Any]] ?? []
        if agents.indices.contains(agent.selectedSegment), let id = agents[agent.selectedSegment]["id"] as? String { onAction?("compose:agent:\(id)") }
    }
    @objc private func modelChanged() { onAction?("compose:model:\(model.indexOfSelectedItem == 0 ? "" : (model.titleOfSelectedItem ?? ""))") }
    @objc private func effortChanged() { onAction?("compose:effort:\(effort.indexOfSelectedItem == 0 ? "" : (effort.titleOfSelectedItem ?? ""))") }

    private func submit() {
        let text = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !(data["busy"] as? Bool ?? false) else { return }
        onAction?("compose:start|\(text)")
    }

    func apply(_ data: [String: Any], strings: [String: String]) {
        self.strings = strings
        guard let c = data["compose"] as? [String: Any] else { return }
        self.data = c
        chat = (c["kind"] as? String) == "chat"
        kind.setLabel(strings["newTask"] ?? "Nova tarefa", forSegment: 0)
        kind.setLabel(strings["newChat"] ?? "Nova conversa", forSegment: 1)
        kind.selectedSegment = chat ? 1 : 0
        kind.setEnabled(c["canChat"] as? Bool ?? true, forSegment: 1)
        projectHeading.stringValue = (strings["project"] ?? "Projeto").uppercased()
        let projects = c["projects"] as? [[String: Any]] ?? []
        let selected = projects.first { ($0["key"] as? String) == (c["project"] as? String) }
        projectName.stringValue = selected?["name"] as? String ?? (strings["chooseProject"] ?? "Escolha um projeto")
        projectBox.stringValue = selected.map { ($0["box"] as? String ?? "") } ?? ""
        worktreeHeading.stringValue = "Worktree".uppercased()
        worktree.setLabel(strings["newWorktree"] ?? "Nova worktree", forSegment: 0)
        worktree.setLabel(strings["onMain"] ?? "Na principal", forSegment: 1)
        worktree.selectedSegment = (c["worktree"] as? String) == "main" ? 1 : 0
        agentHeading.stringValue = (strings["agent"] ?? "Agente").uppercased()
        let agents = c["agents"] as? [[String: Any]] ?? []
        agent.segmentCount = max(agents.count, 1)
        for (i, a) in agents.enumerated() { agent.setLabel(a["name"] as? String ?? a["id"] as? String ?? "", forSegment: i) }
        if let i = agents.firstIndex(where: { ($0["id"] as? String) == (c["agent"] as? String) }) { agent.selectedSegment = i }
        let current = agents.first { ($0["id"] as? String) == (c["agent"] as? String) }
        modelHeading.stringValue = (strings["model"] ?? "Modelo").uppercased()
        effortHeading.stringValue = (strings["effort"] ?? "Esforço").uppercased()
        fill(model, items: current?["models"] as? [String] ?? [], selected: c["model"] as? String, auto: strings["auto"] ?? "Padrão")
        fill(effort, items: current?["efforts"] as? [String] ?? [], selected: c["effort"] as? String, auto: strings["auto"] ?? "Padrão")
        placeholder.stringValue = chat ? (strings["chatPrompt"] ?? "") : (strings["taskPrompt"] ?? "")
        placeholder.isHidden = !prompt.string.isEmpty
        start.title = (c["busy"] as? Bool ?? false) ? (strings["starting"] ?? "Iniciando…") : (chat ? (strings["startChat"] ?? "Começar") : (strings["startTask"] ?? "Iniciar"))
        imageChip.text = (c["image"] as? Bool ?? false) ? (strings["screenPart"] ?? "Parte da tela") + "  ×" : ""
        imageChip.sizeToFit()
        imageChip.isHidden = imageChip.text.isEmpty
        summary.stringValue = c["summary"] as? String ?? ""
        error.stringValue = c["error"] as? String ?? ""
        mic.accessibilityTitle = strings["dictate"] ?? "Ditar"; mic.toolTip = mic.accessibilityTitle
        camera.accessibilityTitle = strings["menuPoint"] ?? "Apontar"; camera.toolTip = camera.accessibilityTitle
        if let d = data["dictation"] as? [String: Any], (d["target"] as? String) == "compose" {
            dictation(target: "compose", active: d["active"] as? Bool ?? false, text: d["text"] as? String ?? "")
        }
        needsLayout = true
    }

    private func fill(_ popup: NSPopUpButton, items: [String], selected: String?, auto: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: auto)
        popup.addItems(withTitles: items)
        if let selected, let i = items.firstIndex(of: selected) { popup.selectItem(at: i + 1) } else { popup.selectItem(at: 0) }
        popup.isEnabled = !items.isEmpty
    }

    func layoutContent(width: CGFloat) -> CGFloat {
        var st = Stacker(width: width, apply: true)
        st.place(kind, height: 28, gap: 16)
        if !chat {
            st.place(projectHeading, height: 14, gap: 6)
            st.place(project, height: 52, gap: 14)
            projectName.frame = NSRect(x: 14, y: 9, width: width - 60, height: 18)
            projectBox.frame = NSRect(x: 14, y: 29, width: width - 60, height: 16)
            chevron.frame = NSRect(x: width - 14 - 14, y: 19, width: 14, height: 14)
            st.place(worktreeHeading, height: 14, gap: 6)
            st.place(worktree, height: 26, gap: 14)
        } else {
            for v in [projectHeading, project, worktreeHeading, worktree] as [NSView] { st.skip(v) }
        }
        st.place(agentHeading, height: 14, gap: 6)
        st.place(agent, height: 26, gap: 14)
        let half = (width - 12) / 2
        if model.isEnabled || effort.isEnabled {
            modelHeading.frame = NSRect(x: 0, y: st.y, width: half, height: 14)
            effortHeading.frame = NSRect(x: half + 12, y: st.y, width: half, height: 14)
            model.frame = NSRect(x: 0, y: st.y + 20, width: half, height: 26)
            effort.frame = NSRect(x: half + 12, y: st.y + 20, width: half, height: 26)
            for v in [modelHeading, effortHeading, model, effort] as [NSView] { v.isHidden = false }
            st.y += 20 + 26 + 14
        } else {
            for v in [modelHeading, effortHeading, model, effort] as [NSView] { st.skip(v) }
        }
        let promptH: CGFloat = max(96, min(220, promptHeight(width - 28) + 24))
        st.place(promptBox, height: promptH, gap: 10)
        prompt.frame = NSRect(x: 14, y: 12, width: width - 28, height: promptH - 24)
        placeholder.frame = NSRect(x: 14, y: 12, width: width - 28, height: 18)
        if !imageChip.isHidden { st.place(imageChip, height: imageChip.frame.height, width: imageChip.frame.width, gap: 10) }
        let rowY = st.y
        mic.frame = NSRect(x: 0, y: rowY, width: 32, height: 32)
        camera.frame = NSRect(x: 36, y: rowY, width: 32, height: 32)
        let s = start.measure()
        start.frame = NSRect(x: width - s.width, y: rowY + 2, width: s.width, height: s.height)
        st.y = rowY + 32 + 10
        if !summary.stringValue.isEmpty { st.place(summary, height: SurfaceStyle.height(of: summary, width: width), gap: 6) } else { st.skip(summary) }
        if !error.stringValue.isEmpty { st.place(error, height: SurfaceStyle.height(of: error, width: width), gap: 6) } else { st.skip(error) }
        return st.y
    }

    private func promptHeight(_ width: CGFloat) -> CGFloat {
        prompt.textContainer?.containerSize = NSSize(width: width, height: 100_000)
        prompt.layoutManager?.ensureLayout(for: prompt.textContainer!)
        return prompt.layoutManager?.usedRect(for: prompt.textContainer!).height ?? 20
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !prompt.string.isEmpty
        onAction?("panel:relayout")
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { window?.makeFirstResponder(superview); return true }
        return false
    }

    func handleKey(_ e: NSEvent) -> Bool { false }
    func focusField() { window?.makeFirstResponder(prompt) }

    func dictation(target: String, active: Bool, text: String) {
        guard target == "compose" else { return }
        if active || !text.isEmpty {
            prompt.string = dictationBase.isEmpty ? text : dictationBase + " " + text
            placeholder.isHidden = !prompt.string.isEmpty
        }
        mic.tint = active ? PanelStyle.red : PanelStyle.text
    }
}

/// The project picker: every repository of every box, the recent ones first, filtered as the person types.
final class ProjectScreen: NSView, PanelScreenView, PanelDataSink, NSSearchFieldDelegate {
    var onAction: ((String) -> Void)?
    var title: String { strings["project"] ?? "Projeto" }
    private var strings: [String: String] = [:]
    private var projects: [[String: Any]] = []
    private let search = NSSearchField()
    private var rows: [ClickableView] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.delegate = self
        search.focusRingType = .none
        addSubview(search)
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ data: [String: Any], strings: [String: String]) {
        self.strings = strings
        projects = (data["compose"] as? [String: Any])?["projects"] as? [[String: Any]] ?? []
        search.placeholderString = strings["searchProject"] ?? "Buscar projeto"
        rebuild()
    }

    private func rebuild() {
        for r in rows { r.removeFromSuperview() }
        rows = []
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        for p in projects where q.isEmpty || (p["name"] as? String ?? "").lowercased().contains(q) || (p["location"] as? String ?? "").lowercased().contains(q) {
            let r = ClickableView(frame: .zero)
            let name = SurfaceStyle.label(p["name"] as? String ?? "", font: PanelStyle.font(14, .semibold), color: PanelStyle.text)
            let sub = SurfaceStyle.label([p["box"] as? String, (p["recent"] as? Bool ?? false) ? (strings["recent"] ?? "recente") : nil].compactMap { $0 }.joined(separator: " · "),
                                         font: PanelStyle.font(12), color: PanelStyle.textDim)
            r.addSubview(name); r.addSubview(sub)
            name.frame = NSRect(x: 14, y: 9, width: 400, height: 18)
            sub.frame = NSRect(x: 14, y: 29, width: 400, height: 16)
            let key = p["key"] as? String ?? ""
            r.onClick = { [weak self] in self?.onAction?("compose:project:\(key)"); self?.onAction?("panel:back") }
            r.accessibilityTitle = name.stringValue
            let row = r
            row.drawBlock = { rect, hovered in
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
                PanelStyle.card.setFill(); path.fill()
                if hovered { PanelStyle.wash.setFill(); path.fill() }
                PanelStyle.hairline.setStroke(); path.lineWidth = 1; path.stroke()
            }
            addSubview(r); rows.append(r)
        }
        onAction?("panel:relayout")
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func layoutContent(width: CGFloat) -> CGFloat {
        var st = Stacker(width: width, apply: true)
        st.place(search, height: 28, gap: 12)
        for r in rows { st.place(r, height: 52, gap: 8); r.subviews.forEach { $0.frame.size.width = width - 28 } }
        return st.y
    }

    func focusField() { window?.makeFirstResponder(search) }
}

// MARK: - Falar

/// Falar in the panel: say or type what is needed; the box's router picks the agent (or a new task), the decision
/// shows with Enviar, and the receipt follows. The app's TalkModel does the routing; this is its face.
final class TalkScreen: NSView, PanelScreenView, PanelDataSink, NSTextViewDelegate {
    var onAction: ((String) -> Void)?
    var title: String { strings["talk"] ?? "Falar" }
    private var strings: [String: String] = [:]
    private var state: [String: Any] = [:]
    private var dictationBase = ""
    private let box = CodeBoxView()
    private let field = NSTextView()
    private let placeholder = SurfaceStyle.label("", font: PanelStyle.font(14), color: PanelStyle.textFaint)
    private let mic = IconButton(symbol: "mic.fill", size: 32, symbolSize: 15, title: "Ditar")
    private let route = PillButton(title: "", symbol: "arrow.up", color: PanelStyle.accent)
    private let spinner = NSProgressIndicator()
    private let status = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.textDim, lines: 3)
    private let decision = ClickableView(frame: .zero)
    private let kicker = SurfaceStyle.label("", font: PanelStyle.font(11, .semibold), color: PanelStyle.textFaint)
    private let dTitle = SurfaceStyle.label("", font: PanelStyle.font(15, .bold), color: PanelStyle.text, lines: 2)
    private let dSub = SurfaceStyle.label("", font: PanelStyle.font(12), color: PanelStyle.textDim)
    private let dText = SurfaceStyle.label("", font: PanelStyle.font(13), color: PanelStyle.text, lines: 6)
    private let confirm = PillButton(title: "", symbol: "paperplane.fill", color: PanelStyle.accent)
    private let adjust = PillButton(title: "", symbol: "arrow.up.forward.app", color: PanelStyle.textDim)
    private let hint = HintPill()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [box, mic, route, spinner, status, decision, hint] as [NSView] { addSubview(v) }
        box.addSubview(field); box.addSubview(placeholder)
        for v in [kicker, dTitle, dSub, dText, confirm, adjust] as [NSView] { decision.addSubview(v) }
        field.delegate = self
        field.drawsBackground = false
        field.font = PanelStyle.font(14)
        field.textColor = PanelStyle.text
        field.insertionPointColor = PanelStyle.text
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.isRichText = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        mic.onBlack = true
        mic.onClick = { [weak self] in
            guard let self else { return }
            self.dictationBase = self.field.string
            self.onAction?("dictation:toggle:talk")
        }
        route.onClick = { [weak self] in self?.send() }
        confirm.onClick = { [weak self] in self?.onAction?("talk:confirm") }
        adjust.onClick = { [weak self] in self?.onAction?("talk:open") }
        decision.drawBlock = { rect, _ in
            let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
            PanelStyle.card.setFill(); p.fill()
            PanelStyle.accent.withAlphaComponent(0.35).setStroke(); p.lineWidth = 1; p.stroke()
        }
        hint.onUndo = { [weak self] in self?.onAction?("talk:undo") }
    }
    required init?(coder: NSCoder) { nil }

    private func send() {
        let t = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onAction?("talk:route|\(t)")
    }

    func apply(_ data: [String: Any], strings: [String: String]) {
        self.strings = strings
        state = data["talk"] as? [String: Any] ?? [:]
        placeholder.stringValue = (state["phase"] as? String) == "asking" ? (strings["yourAnswer"] ?? "") : (strings["talkPrompt"] ?? "")
        placeholder.isHidden = !field.string.isEmpty
        route.title = strings["route"] ?? "Encaminhar"
        let phase = state["phase"] as? String ?? "input"
        spinner.isHidden = phase != "routing"
        if phase == "routing" { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        switch phase {
        case "routing": status.stringValue = strings["routing"] ?? ""
        case "asking": status.stringValue = state["question"] as? String ?? ""
        case "failed": status.stringValue = state["error"] as? String ?? ""
        default: status.stringValue = ""
        }
        status.textColor = phase == "failed" ? PanelStyle.red : phase == "asking" ? PanelStyle.orange : PanelStyle.textDim
        if let d = state["decision"] as? [String: Any], phase == "decided" {
            decision.isHidden = false
            kicker.stringValue = (d["kicker"] as? String ?? "").uppercased()
            dTitle.stringValue = d["title"] as? String ?? ""
            dSub.stringValue = d["subtitle"] as? String ?? ""
            dText.stringValue = d["text"] as? String ?? ""
            confirm.title = (d["isNew"] as? Bool ?? false) ? (strings["createTask"] ?? "Criar tarefa") : (strings["send"] ?? "Enviar")
            adjust.title = strings["adjustInPier"] ?? "Ajustar no Pier"
        } else {
            decision.isHidden = true
        }
        hint.render(kind: "", count: 0, pending: nil, receipt: state["receipt"] as? String, strings: strings)
        hint.isHidden = hint.measure().width == 0
        if (state["clear"] as? Bool ?? false) { field.string = ""; placeholder.isHidden = false }
        mic.accessibilityTitle = strings["dictate"] ?? "Ditar"; mic.toolTip = mic.accessibilityTitle
        if let d = data["dictation"] as? [String: Any], (d["target"] as? String) == "talk" {
            dictation(target: "talk", active: d["active"] as? Bool ?? false, text: d["text"] as? String ?? "")
        }
        needsLayout = true
    }

    func layoutContent(width: CGFloat) -> CGFloat {
        var st = Stacker(width: width, apply: true)
        field.textContainer?.containerSize = NSSize(width: width - 28, height: 100_000)
        field.layoutManager?.ensureLayout(for: field.textContainer!)
        let th = max(44, min(160, (field.layoutManager?.usedRect(for: field.textContainer!).height ?? 20) + 24))
        st.place(box, height: th, gap: 10)
        field.frame = NSRect(x: 14, y: 12, width: width - 28, height: th - 24)
        placeholder.frame = NSRect(x: 14, y: 12, width: width - 28, height: 18)
        let rowY = st.y
        mic.frame = NSRect(x: 0, y: rowY, width: 32, height: 32)
        spinner.frame = NSRect(x: 40, y: rowY + 8, width: 16, height: 16)
        let s = route.measure()
        route.frame = NSRect(x: width - s.width, y: rowY + 2, width: s.width, height: s.height)
        st.y = rowY + 32 + 12
        if !status.stringValue.isEmpty { st.place(status, height: SurfaceStyle.height(of: status, width: width), gap: 12) } else { st.skip(status) }
        if !decision.isHidden {
            let pad: CGFloat = 16
            var y: CGFloat = pad
            kicker.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 14); y += 18
            let tH = SurfaceStyle.height(of: dTitle, width: width - pad * 2)
            dTitle.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: tH); y += tH + 2
            dSub.isHidden = dSub.stringValue.isEmpty
            if !dSub.isHidden { dSub.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 16); y += 20 } else { y += 6 }
            let xH = SurfaceStyle.height(of: dText, width: width - pad * 2)
            dText.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: xH); y += xH + 14
            let c = confirm.measure(), a = adjust.measure()
            confirm.frame = NSRect(x: pad, y: y, width: c.width, height: c.height)
            adjust.frame = NSRect(x: pad + c.width + 8, y: y, width: a.width, height: a.height)
            y += 28 + pad
            st.place(decision, height: y, gap: 12)
        }
        if !hint.isHidden {
            let w = hint.measure().width
            st.place(hint, height: 30, x: (width - w) / 2, width: w, gap: 10)
        }
        return st.y
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !field.string.isEmpty
        onAction?("panel:relayout")
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            send(); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { window?.makeFirstResponder(superview); return true }
        return false
    }

    func focusField() { window?.makeFirstResponder(field) }

    func dictation(target: String, active: Bool, text: String) {
        guard target == "talk" else { return }
        if active || !text.isEmpty {
            field.string = dictationBase.isEmpty ? text : dictationBase + " " + text
            placeholder.isHidden = !field.string.isEmpty
        }
        mic.tint = active ? PanelStyle.red : PanelStyle.text
    }
}
