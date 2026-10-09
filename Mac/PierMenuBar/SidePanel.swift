import AppKit

/// The side panel's look: dark and bold in both appearances (it is a thing of the screen's edge, like the tab, not of
/// the app's window): near-black panels, hairlines, generous radii, white titles over gray detail.
enum PanelStyle {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let bg = rgb(0x141416)
    static let card = rgb(0x1C1C1E)
    static let raised = rgb(0x26262A)
    static let hairline = NSColor.white.withAlphaComponent(0.08)
    static let text = NSColor.white.withAlphaComponent(0.95)
    static let textDim = rgb(0x9A9AA0)
    static let textFaint = rgb(0x6B6B72)
    static let accent = rgb(0x4A99FA)
    static let orange = rgb(0xF5A35C)
    static let green = rgb(0x4CC38A)
    static let red = rgb(0xE5675F)
    static let gray = rgb(0x7A818B)
    static let wash = NSColor.white.withAlphaComponent(0.06)
    static let onFill = rgb(0x141416)
    static let radius: CGFloat = 26
    static let width: CGFloat = 520

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

    static func color(forState state: String) -> NSColor {
        switch state {
        case "needsYou": orange
        case "working": accent
        case "done": green
        default: gray
        }
    }
}

/// What a screen of the panel gets to draw itself and to act: the latest data from the app and a way to send actions.
@MainActor protocol PanelScreenView: NSView {
    var onAction: ((String) -> Void)? { get set }
    /// The screen's title for the header (nil: the screen draws its own).
    var title: String { get }
    /// Lays the content out for `width` and returns its height (the panel sizes itself to it, up to a maximum).
    func layoutContent(width: CGFloat) -> CGFloat
    /// Keys while the panel is key and no field is editing; true when handled.
    func handleKey(_ event: NSEvent) -> Bool
    /// The dictation transcript for the field this screen owns (`target`), while it listens and once it stopped.
    func dictation(target: String, active: Bool, text: String)
    func focusField()
}

extension PanelScreenView {
    func handleKey(_ event: NSEvent) -> Bool { false }
    func dictation(target: String, active: Bool, text: String) {}
    func focusField() {}
}

/// The side app beside the tab: one panel, one stack of screens (`PanelNavigator`, PierKit), a header with the chevron
/// and the title, the screen's content in a scroll view. A non-activating panel: it takes the keys only when the person
/// clicks into a field (or on its background), and Esc hands them back — the app they were typing in never lost its place.
/// Everything in it happens on the box through the app's own stores; "Abrir no Pier" is the secondary way out.
@MainActor final class SidePanelController {
    let panel: EdgePanel
    let send: (String) -> Void
    private(set) var navigator = PanelNavigator()
    var strings: [String: String] = [:]
    var onOpenChanged: (() -> Void)?

    private let root = PanelRootView()
    private var screens: [PanelScreen: any PanelScreenView] = [:]
    private var current: (any PanelScreenView)?
    private var anchorFrame = NSRect.zero
    private var edge = EdgeSide.right
    private weak var screen: NSScreen?
    private var clickAway: Any?
    private var data: [String: Any] = [:]
    /// The screen the app asked for (a task just started): applied on the next render.
    private var pendingStarted: String?

    var isOpen: Bool { navigator.isOpen && panel.isVisible }
    var topScreen: PanelScreen? { navigator.top }

    init(send: @escaping (String) -> Void) {
        self.send = send
        panel = EdgePanel(keyable: true)
        panel.contentView = root
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.appearance = NSAppearance(named: .darkAqua)   // dark in both appearances
        root.onKey = { [weak self] e in self?.key(e) ?? false }
        root.onBack = { [weak self] in self?.back() }
        root.onClose = { [weak self] in self?.close() }
        root.onBackgroundClick = { [weak self] in self?.panel.makeKey() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.root.endEditing() }
        }
    }

    // MARK: data

    /// The latest payload from the app (`updateSurface:`): every screen reads what it needs from it.
    func update(_ data: [String: Any]) {
        self.data = data
        if let started = data["started"] as? String, started != pendingStarted {
            pendingStarted = started
            navigator.started(agent: started)
            if !panel.isVisible { open() } else { render() }
            return
        }
        if let d = data["dictation"] as? [String: Any], let target = d["target"] as? String {
            current?.dictation(target: target, active: d["active"] as? Bool ?? false, text: d["text"] as? String ?? "")
        }
        // An agent that left the list while shown: back to the list.
        if case .agent(let id)? = navigator.top, let agents = data["agents"] as? [[String: Any]],
           !agents.contains(where: { ($0["id"] as? String) == id }), data["agentDetail"] == nil {
            navigator.agentGone(id)
        }
        if isOpen { render() }
    }

    // MARK: navigation

    func toggle(root screen: PanelScreen) {
        navigator.toggle(root: screen)
        navigator.isOpen ? open() : close()
    }

    func show(_ screen: PanelScreen) {
        navigator.show(screen)
        open()
    }

    func showAgent(_ id: String) {
        navigator.showAgent(id)
        open()
    }

    private func back() {
        root.endEditing()
        if navigator.back() { render() } else { close() }
    }

    func open() {
        guard navigator.isOpen else { return }
        render()
        place()
        if !panel.isVisible {
            panel.alphaValue = SurfaceStyle.reduceMotion ? 1 : 0
            panel.orderFrontRegardless()   // no key status: the person's app keeps the keyboard
            if !SurfaceStyle.reduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; panel.animator().alphaValue = 1 }
            }
            clickAway = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        send("panel:screen:\(screenName(navigator.top))")
        onOpenChanged?()
    }

    func close() {
        guard panel.isVisible else { navigator.close(); return }
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
        root.endEditing()
        if panel.isKeyWindow { panel.resignKey() }
        panel.orderOut(nil)
        navigator.close()
        current = nil
        send("panel:screen:none")
        onOpenChanged?()
    }

    private func screenName(_ s: PanelScreen?) -> String {
        switch s {
        case .inbox?: "inbox"
        case .agents?: "agents"
        case .agent(let id)?: "agent:\(id)"
        case .compose(let chat)?: chat ? "chat" : "task"
        case .project?: "project"
        case .talk?: "talk"
        case nil: "none"
        }
    }

    // MARK: rendering

    private func view(for screen: PanelScreen) -> any PanelScreenView {
        if let v = screens[screen] { return v }
        let v: any PanelScreenView
        switch screen {
        case .inbox: v = InboxScreen()
        case .agents: v = AgentsScreen()
        case .agent(let id): v = AgentScreen(id: id)
        case .compose(let chat): v = ComposeScreen(chat: chat)
        case .project: v = ProjectScreen()
        case .talk: v = TalkScreen()
        }
        v.onAction = { [weak self] a in self?.act(a) }
        screens[screen] = v
        return v
    }

    private func render() {
        guard let top = navigator.top else { return }
        let v = view(for: top)
        if let c = current, c !== v {
            // One screen at a time: the others are dropped (an agent view is rebuilt when it comes back).
            screens = screens.filter { $0.value === v || $0.key.isRoot }
        }
        current = v
        (v as? PanelDataSink)?.apply(data, strings: strings)
        root.set(screen: v, title: v.title, canGoBack: navigator.canGoBack, strings: strings)
        place()
    }

    /// A screen's content changed size (text typed, rows added): the panel follows.
    func relayout() {
        guard isOpen else { return }
        place()
    }

    /// Beside the tab, the pointer aimed at the tab's Inbox button (or the tab itself); kept on the screen.
    func anchor(to frame: NSRect, edge: EdgeSide, screen: NSScreen) {
        anchorFrame = frame
        self.edge = edge
        self.screen = screen
        if panel.isVisible { place() }
    }

    private func place() {
        guard let screen, panel.contentView != nil else { return }
        let visible = screen.visibleFrame
        let maxHeight = min(680, visible.height - 24)
        let size = root.measure(width: PanelStyle.width, maxHeight: maxHeight, edge: edge)
        var x: CGFloat = edge == .right ? anchorFrame.minX - 6 - (size.width - PanelRootView.margin) : anchorFrame.maxX + 6 - PanelRootView.margin
        var y = anchorFrame.midY + root.pointerY - size.height
        y = min(max(y, visible.minY), visible.maxY - size.height)
        x = min(max(x, visible.minX), visible.maxX - size.width)
        root.pointerCenterY = anchorFrame.midY - y
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if panel.isVisible, !SurfaceStyle.reduceMotion, panel.frame.size != frame.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.04)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: keys and actions

    private func key(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 {   // Esc: end editing, else back, else close; the keys go back to the person's app
            if root.isEditing { root.endEditing(); return true }
            back()
            return true
        }
        if e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers?.lowercased() {
            if c == "n" { show(.compose(chat: e.modifierFlags.contains(.shift))); return true }
        }
        if root.isEditing { return false }
        if e.keyCode == 123 || e.charactersIgnoringModifiers == "h" { back(); return true }   // ← / H: back
        return current?.handleKey(e) ?? false
    }

    private func act(_ a: String) {
        switch a {
        case "panel:back": back()
        case "panel:close": close()
        case "panel:focus": panel.makeKey(); current?.focusField()
        default:
            if a.hasPrefix("panel:show:") { route(String(a.dropFirst(11))); return }
            send(a)
        }
    }

    private func route(_ name: String) {
        switch name {
        case "inbox": show(.inbox)
        case "agents": show(.agents)
        case "task": show(.compose(chat: false))
        case "chat": show(.compose(chat: true))
        case "project": show(.project)
        case "talk": show(.talk)
        default: if name.hasPrefix("agent:") { navigator.show(.agent(String(name.dropFirst(6)))); open() }
        }
    }

    var debugState: String {
        "open=\(isOpen) frame=\(NSStringFromRect(panel.frame)) stack=\(navigator.stack) key=\(panel.isKeyWindow)"
    }

    /// Tests: the current screen's content height and title.
    var debugContent: String { "\(current?.title ?? "-") h=\(root.contentHeight)" }
}

/// A screen that takes the app's payload.
@MainActor protocol PanelDataSink: AnyObject {
    func apply(_ data: [String: Any], strings: [String: String])
}

/// The panel's chrome: the dark rounded shape with the pointer, the header (chevron, title, ×) and the screen below it,
/// in a scroll view when it is taller than the panel.
final class PanelRootView: NSView {
    static let margin: CGFloat = 16
    static let pointer = NSSize(width: 9, height: 18)
    var onKey: ((NSEvent) -> Bool)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    var pointerY: CGFloat = margin + 30
    var pointerCenterY: CGFloat = 0 { didSet { needsDisplay = true } }
    private(set) var contentHeight: CGFloat = 0

    private var edge = EdgeSide.right
    private let back = IconButton(symbol: "chevron.left", size: 28, symbolSize: 13, title: "Voltar")
    private let close = IconButton(symbol: "xmark", size: 28, symbolSize: 11, title: "Fechar")
    private let title = SurfaceStyle.label("", font: PanelStyle.font(17, .bold), color: PanelStyle.text)
    private let scroll = NSScrollView()
    private let clip = FlippedClipView()
    private var screenView: (any PanelScreenView)?
    private var panelWidth: CGFloat = PanelStyle.width
    private var panelHeight: CGFloat = 200
    private var headerHeight: CGFloat { 60 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        back.onBlack = true; close.onBlack = true
        back.onClick = { [weak self] in self?.onBack?() }
        close.onClick = { [weak self] in self?.onClose?() }
        // The clip view draws a (square, gray) background of its own unless told not to; setting the scroll view's after
        // the clip is in place covers both.
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed
        for v in [back, close, title, scroll] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { nil }

    var isEditing: Bool {
        guard let r = window?.firstResponder as? NSTextView else { return false }
        return r.isDescendant(of: self)
    }

    func endEditing() {
        if isEditing { window?.makeFirstResponder(self) }
    }

    func set(screen: any PanelScreenView, title: String, canGoBack: Bool, strings: [String: String]) {
        if screenView !== screen {
            screenView?.removeFromSuperview()
            screenView = screen
            scroll.documentView = screen
        }
        self.title.stringValue = title
        back.isHidden = !canGoBack
        back.accessibilityTitle = strings["back"] ?? "Voltar"; back.toolTip = back.accessibilityTitle
        close.accessibilityTitle = strings["close"] ?? "Fechar"; close.toolTip = close.accessibilityTitle
        needsLayout = true
        needsDisplay = true
    }

    /// Lays the screen out for the panel's width; the panel's size (chrome and pointer included), capped at `maxHeight`.
    func measure(width: CGFloat, maxHeight: CGFloat, edge: EdgeSide) -> NSSize {
        self.edge = edge
        panelWidth = width
        let inner = width - 44
        contentHeight = screenView?.layoutContent(width: inner) ?? 0
        let wanted = headerHeight + contentHeight + 22
        panelHeight = min(wanted, maxHeight)
        needsLayout = true
        return NSSize(width: width + Self.margin * 2 + Self.pointer.width, height: panelHeight + Self.margin * 2)
    }

    private var shapeX: CGFloat { Self.margin + (edge == .left ? Self.pointer.width : 0) }

    override func layout() {
        super.layout()
        let x0 = shapeX
        let y0 = Self.margin
        let pad: CGFloat = 22
        back.frame = NSRect(x: x0 + 14, y: y0 + 16, width: 28, height: 28)
        let titleX = back.isHidden ? x0 + pad : x0 + 14 + 28 + 6
        title.frame = NSRect(x: titleX, y: y0 + 19, width: panelWidth - (titleX - x0) - 28 - pad, height: 22)
        close.frame = NSRect(x: x0 + panelWidth - 14 - 28, y: y0 + 16, width: 28, height: 28)
        pointerY = y0 + 30
        scroll.frame = NSRect(x: x0 + pad, y: y0 + headerHeight, width: panelWidth - pad * 2, height: panelHeight - headerHeight - 12)
        if let s = screenView { s.frame = NSRect(x: 0, y: 0, width: panelWidth - pad * 2, height: max(contentHeight, scroll.frame.height)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: shapeX, y: Self.margin, width: panelWidth, height: panelHeight)
        let shape = NSBezierPath(roundedRect: r, xRadius: PanelStyle.radius, yRadius: PanelStyle.radius)
        let cy = bounds.height - pointerCenterY
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
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        PanelStyle.bg.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        PanelStyle.hairline.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // A hairline under the header.
        PanelStyle.hairline.setFill()
        NSRect(x: r.minX + 22, y: r.minY + headerHeight - 1, width: r.width - 44, height: 1).fill()
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the panel's own background takes the keys (1–9, Esc), the person's explicit choice.
        onBackgroundClick?()
    }
}

/// A clip view with its origin at the top, so a short screen sits at the top of the scroll area.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
