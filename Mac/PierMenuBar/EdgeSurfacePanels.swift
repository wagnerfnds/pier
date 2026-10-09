import AppKit

/// The surface at the screen's edge, always on top of every app and Space: one narrow black tab hanging from the edge
/// like a drop (each end an S-curve out of the edge, `EdgeOutline`), with one indicator per agent (a blue ring turning
/// while it works, an amber dot when it needs the person, green when its turn ended), that grows — same silhouette,
/// same window, still glued — to hold the Inbox button with its count, the agents, Nova tarefa, Falar, Apontar and a
/// menu. Under the pointer its items magnify like the Dock's. It opens while the pointer is on it or ⌥ is held, while
/// an agent needs the person, while the side panel or the menu is open and for a moment after a turn finished; it folds
/// only once the pointer has been away for a while (`EdgeHover`, PierKit), never while the pointer is inside. Beside it,
/// the side panel (`SidePanelController`): the Inbox, the agents, a new task, Falar — the app's work without the app's
/// window. A non-activating panel: nothing here ever takes the keyboard away from the app the person is typing in.
@MainActor final class EdgeSurfaceController {
    struct Config: Equatable {
        var enabled = true
        var edge = EdgeSide.right
        var fraction = 0.55
        var fullScreen = false
        var appearance = "system"
        /// "main" (the menu bar's screen), "pointer" (the screen the pointer is on) or a display id.
        var display = "main"
        var size = EdgeSizeClass.medium
        var optionLabels = true
    }

    struct Dot: Equatable {
        let id: String
        let state: String
        let title: String
        let project: String
        let word: String
        /// The agent the Inbox shows (its dot is full amber, the other waiting ones are dimmed).
        let focused: Bool
    }

    let send: (String) -> Void
    let panelController: SidePanelController
    private(set) var config = Config()
    private var dots: [Dot] = []
    private var unseen = 0
    private var strings: [String: String] = [:]
    private var toast: String?
    private var toastTask: DispatchWorkItem?
    private var hover = EdgeHover()
    private var foldTask: DispatchWorkItem?
    private var menuOpen = false
    private var started = false
    private var hidden = false
    private var pointerScreenTask: DispatchWorkItem?
    private var lastScreenID: Int?
    var optionHeld = false { didSet { if optionHeld != oldValue { repin(); layout() } } }

    private let panel = EdgePanel(keyable: false)
    private let view: EdgeTabView

    var expanded: Bool { hover.expanded }

    init(send: @escaping (String) -> Void) {
        self.send = send
        panelController = SidePanelController(send: send)
        view = EdgeTabView()
        panel.contentView = view
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        view.onHover = { [weak self] in self?.pointer(inside: $0) }
        view.onDrag = { [weak self] dy in self?.drag(by: dy) }
        view.onDragEnd = { [weak self] in self?.dragEnded() }
        view.onClick = { [weak self] in self?.panelController.toggle(root: .inbox) }
        view.onDotClick = { [weak self] id in self?.panelController.showAgent(id) }
        view.onAction = { [weak self] a in self?.tabAction(a) }
        view.onMenu = { [weak self] e, v in self?.showMenu(e, in: v) }
        view.onRelayout = { [weak self] in self?.layout() }
        panelController.onOpenChanged = { [weak self] in self?.repin() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    /// The tab's buttons: the panel's screens stay beside the tab; only "camera" and the menu reach the app.
    private func tabAction(_ a: String) {
        switch a {
        case "inbox": panelController.toggle(root: .inbox)
        case "plus": panelController.toggle(root: .compose(chat: false))
        case "talk": panelController.toggle(root: .talk)
        case "agents": panelController.toggle(root: .agents)
        default: send(a)
        }
    }

    // MARK: input from the app

    func configure(_ c: Config) {
        let was = config
        config = c
        let appearance: NSAppearance? = switch c.appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        panel.appearance = appearance
        for p in [panel, panelController.panel] {
            var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if c.fullScreen { behavior.insert(.fullScreenAuxiliary) }
            p.collectionBehavior = behavior
        }
        view.metrics = EdgeMetrics.metrics(c.size)
        if !c.enabled {
            panelController.close()
            panel.orderOut(nil)
            started = false
            stopPointerScreen()
            return
        }
        if !started || was != c {
            started = true
            layout()
            if !hidden { panel.orderFrontRegardless() }
        }
        if c.display == "pointer" { watchPointerScreen() } else { stopPointerScreen() }
        repin()
    }

    func update(dots: [Dot], unseen: Int, strings: [String: String]) {
        // A turn that just ended: "Sua vez · title" beside its dot for a moment.
        for d in dots where d.state == "done" {
            if let old = self.dots.first(where: { $0.id == d.id }), old.state == "working" { showToast("\(strings["done"] ?? "Sua vez") · \(d.title)") }
        }
        self.dots = dots
        self.unseen = unseen
        self.strings = strings
        view.set(dots: dots, unseen: unseen, strings: strings)
        panelController.strings = strings
        if started { layout(); repin() }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.toast = nil
                self?.layout()
                self?.repin()
            }
        }
        toastTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    // MARK: open / fold (EdgeHover)

    private var needsYouCount: Int { forceCollapsed ? 0 : dots.filter { $0.state == "needsYou" }.count }
    private var labelsVisible: Bool { optionHeld && config.optionLabels }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// What holds the tab open besides the pointer: an agent needing the person, the panel or the menu, ⌥, the toast.
    private func repin() {
        guard started, config.enabled else { return }
        let pinned = EdgeSurfaceRules.expanded(needsYou: needsYouCount, hovering: false, optionHeld: labelsVisible,
                                               cardOpen: panelController.isOpen || menuOpen, finishedToast: toast != nil)
        if hover.pin(pinned, at: now) { apply() }
        scheduleFold()
    }

    private func pointer(inside: Bool) {
        if inside {
            if hover.entered(at: now) { apply() }
            foldTask?.cancel(); foldTask = nil
        } else {
            hover.exited(at: now)
            scheduleFold()
        }
    }

    /// Runs `tick` when the grace ends; the pointer's real position is checked first, so a missed `mouseEntered` (the
    /// panel grew under a still pointer) can never fold the tab while the pointer is on it.
    private func scheduleFold() {
        foldTask?.cancel(); foldTask = nil
        guard let due = hover.collapseAt else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldTask = nil
                if self.pointerIsOnThePanel {
                    _ = self.hover.entered(at: self.now)
                    return
                }
                if self.hover.tick(at: self.now) { self.apply() }
            }
        }
        foldTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now), execute: w)
    }

    private var pointerIsOnThePanel: Bool {
        panel.isVisible && view.shapeContains(screen: NSEvent.mouseLocation)
    }

    /// The tab grows or folds in place: the same window, the view's own spring morphing the shape (`onRelayout` moves
    /// the frame with it).
    private func apply() {
        guard started, config.enabled else { return }
        NSLog("PierMenuBar: surface %@", hover.expanded ? "opened" : "folded")
        view.expanded = hover.expanded
        layout()
    }

    // MARK: placement

    /// The screen the surface lives on: the one the pointer is on, a chosen one, else the one with the menu bar.
    var screen: NSScreen? {
        switch config.display {
        case "pointer":
            let p = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.screens.first
        case "main", "":
            return NSScreen.screens.first
        default:
            if let id = Int(config.display), let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s }
            return NSScreen.screens.first
        }
    }

    /// The window: one fixed canvas for the state (the grown tab, its magnification and the labels fit in it), flush
    /// with the screen edge at whole points, its middle at the chosen fraction. It moves or resizes only when the state
    /// does — the agents' count, a label, the settings — never while the springs run: the shape morphs inside it.
    func layout() {
        guard let screen else { return }
        lastScreenID = screen.displayID
        let size = view.measure(edge: config.edge, labels: labelsVisible, toast: toast)
        let slop = view.metrics.slop
        let frame = EdgeLayout.frame(size: size, edge: config.edge, fraction: config.fraction, screen: screen.frame, visible: screen.visibleFrame)
            .offsetBy(dx: config.edge == .right ? slop : -slop, dy: 0)   // the slop past the edge
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        afterLayout()
    }

    private func afterLayout() {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        if let screen { panelController.anchor(to: inboxButtonFrame, edge: config.edge, screen: screen) }
    }

    /// The Inbox button's frame on screen (the panel's pointer aims at it); the tab's own frame while folded.
    private var inboxButtonFrame: NSRect {
        let r = view.inboxFrameInWindow
        guard r.width > 0 else { return panel.frame.insetBy(dx: view.metrics.slop, dy: 0) }
        return NSRect(origin: NSPoint(x: panel.frame.minX + r.minX, y: panel.frame.minY + r.minY), size: r.size)
    }

    private var dragging = false
    private func drag(by dy: CGFloat) {
        guard let screen else { return }
        dragging = true
        let centerY = panel.frame.midY + dy
        config.fraction = EdgeLayout.fraction(forCenterY: centerY, height: panel.frame.height, visible: screen.visibleFrame)
        layout()
    }

    private func dragEnded() {
        guard dragging else { return }
        dragging = false
        send("surface:fraction:\(config.fraction)")
    }

    /// "Onde está o ponteiro": the tab follows the pointer across displays (checked a few times a second, cheap).
    private func watchPointerScreen() {
        guard pointerScreenTask == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pointerScreenTask != nil else { return }
                if let s = self.screen, s.displayID != self.lastScreenID { self.layout() }
                self.pointerScreenTask = nil
                self.watchPointerScreen()
            }
        }
        pointerScreenTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func stopPointerScreen() {
        pointerScreenTask?.cancel()
        pointerScreenTask = nil
    }

    /// Off the screen for a moment ("point at it" is capturing it), then back as it was.
    func setHidden(_ hidden: Bool) {
        self.hidden = hidden
        if hidden {
            panel.orderOut(nil)
            panelController.panel.orderOut(nil)
        } else if started, config.enabled {
            panel.orderFrontRegardless()
            if panelController.isOpen { panelController.panel.orderFrontRegardless() }
        }
    }

    // MARK: menu

    /// Everything the menu bar item offered, and the tab's own settings. Open, the menu pins the tab (the pointer leaves
    /// it for the menu).
    private func showMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ key: String, _ action: String, state: Bool? = nil, into m: NSMenu? = nil, key equivalent: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let mi = NSMenuItem(title: strings[key] ?? key, action: #selector(MenuTarget.run(_:)), keyEquivalent: equivalent)
            mi.keyEquivalentModifierMask = modifiers
            mi.target = menuTarget
            mi.representedObject = action
            if let state { mi.state = state ? .on : .off }
            (m ?? menu).addItem(mi)
        }
        item("menuOpen", "app")
        item("menuInbox", "panel:inbox")
        item("menuAgents", "panel:agents")
        item("menuNew", "panel:task", key: "n", modifiers: [.command])
        item("menuNewChat", "panel:chat", key: "n", modifiers: [.command, .shift])
        item("menuTalk", "panel:talk")
        item("menuPoint", "camera")
        menu.addItem(.separator())
        let edge = NSMenu()
        item("menuLeft", "surface:edge:left", state: config.edge == .left, into: edge)
        item("menuRight", "surface:edge:right", state: config.edge == .right, into: edge)
        let position = NSMenu()
        for (key, f) in [("menuTop", 0.12), ("menuMiddle", 0.5), ("menuBottom", 0.88)] {
            item(key, "surface:fraction:\(f)", state: abs(config.fraction - f) < 0.08, into: position)
        }
        let size = NSMenu()
        for (key, s) in [("menuSmall", EdgeSizeClass.small), ("menuMedium", .medium), ("menuLarge", .large)] {
            item(key, "surface:size:\(s.rawValue)", state: config.size == s, into: size)
        }
        let screens = NSMenu()
        item("menuMainScreen", "surface:display:main", state: config.display == "main", into: screens)
        item("menuPointerScreen", "surface:display:pointer", state: config.display == "pointer", into: screens)
        if NSScreen.screens.count > 1 {
            screens.addItem(.separator())
            for s in NSScreen.screens {
                let mi = NSMenuItem(title: s.localizedName, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
                mi.target = menuTarget
                mi.representedObject = "surface:display:\(s.displayID)"
                mi.state = config.display == String(s.displayID) ? .on : .off
                screens.addItem(mi)
            }
        }
        for (key, sub) in [("menuEdge", edge), ("menuPosition", position), ("menuSize", size), ("menuScreen", screens)] {
            let mi = NSMenuItem(title: strings[key] ?? key, action: nil, keyEquivalent: "")
            mi.submenu = sub
            menu.addItem(mi)
        }
        item("menuFullScreen", "surface:fullscreen:\(config.fullScreen ? "0" : "1")", state: config.fullScreen)
        menu.addItem(.separator())
        item("menuHide", "surface:hide", key: "p", modifiers: [.control, .option])   // ⌃⌥P shows it again
        item("menuSettings", "settings")
        menuOpen = true
        repin()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        menuOpen = false
        repin()
    }

    private lazy var menuTarget = MenuTarget { [weak self] in
        guard let self else { return }
        switch $0 {
        case "panel:inbox": self.panelController.show(.inbox)
        case "panel:agents": self.panelController.show(.agents)
        case "panel:task": self.panelController.show(.compose(chat: false))
        case "panel:chat": self.panelController.show(.compose(chat: true))
        case "panel:talk": self.panelController.show(.talk)
        default: self.send($0)
        }
    }

    // MARK: tests and screenshots

    /// Screenshots: the folded tab even while an agent waits.
    private var forceCollapsed = false

    func debugToast(_ text: String) { showToast(text); layout(); repin() }

    /// Screenshots without Screen Recording (`snapshot:<dir>`): the tab's view and the open side panel's drawn into
    /// `tab.png` and `panel.png` at 2×, transparent outside their shapes, so they compose over any background and never
    /// carry what is on the person's screen.
    func snapshot(to dir: String) -> String {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var written: [String] = []
        if let png = Self.png(of: view), (try? png.write(to: url.appendingPathComponent("tab.png"))) != nil { written.append("tab.png") }
        if panelController.isOpen, let root = panelController.panel.contentView, let png = Self.png(of: root),
           (try? png.write(to: url.appendingPathComponent("panel.png"))) != nil { written.append("panel.png") }
        return written.isEmpty ? "snapshot: nothing written" : "snapshot: " + written.joined(separator: " ")
    }

    /// A view drawn into a PNG at `scale` (its own drawing, no window capture), with alpha.
    static func png(of view: NSView, scale: CGFloat = 2) -> Data? {
        let b = view.bounds
        guard b.width > 0, b.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Debug hooks for a run without a pointer: `hover`, `unhover`, `option`, `labels`, `collapse`, `magnify:<y>`
    /// (the pointer at `y` points from the tab's top).
    func debug(_ command: String) {
        switch command {
        case "hover": pointer(inside: true)
        case "unhover": pointer(inside: false)
        case "option", "labels": optionHeld.toggle()
        case "collapse": forceCollapsed = true; toast = nil; repin()
        case "offscreen":
            // Screenshots: the tab and the panel keep laying out but leave the screen; `snapshot:` still draws them.
            hidden = true
            panel.orderOut(nil)
            panelController.offscreen = true
            panelController.panel.orderOut(nil)
        case "probe":
            // Which window the system hands a click to: on the shape it must be the tab, on the transparent canvas
            // beside it whatever is behind (evidence for the report).
            let f = panel.frame, m = view.metrics
            let onShape = NSPoint(x: config.edge == .right ? f.maxX - m.slop - 6 : f.minX + m.slop + 6, y: f.midY)
            let beside = NSPoint(x: config.edge == .right ? f.minX + 6 : f.maxX - 6, y: f.midY)
            let a = NSWindow.windowNumber(at: onShape, belowWindowWithWindowNumber: 0), b = NSWindow.windowNumber(at: beside, belowWindowWithWindowNumber: 0)
            NSLog("PierMenuBar: probe tab=%ld onShape=%ld beside=%ld frame=%@", panel.windowNumber, a, b, NSStringFromRect(f))
        default:
            if command.hasPrefix("magnify:"), let y = Double(command.dropFirst(8)) { view.debugMagnify(y: CGFloat(y)) }
        }
    }

    var frames: String {
        let buttons = view.buttonFrames.map { "\($0.key)=\(NSStringFromRect(NSRect(origin: NSPoint(x: panel.frame.minX + $0.value.minX, y: panel.frame.minY + $0.value.minY), size: $0.value.size)))" }
        return "tab=\(NSStringFromRect(panel.frame)) expanded=\(hover.expanded) openness=\(String(format: "%.2f", view.openness)) inside=\(hover.inside) pinned=\(hover.pinned) panel=\(panelController.isOpen) size=\(config.size.rawValue) buttons[\(buttons.sorted().joined(separator: " "))]"
    }
}

private final class MenuTarget: NSObject {
    let run: (String) -> Void
    init(_ run: @escaping (String) -> Void) { self.run = run }
    @objc func run(_ sender: NSMenuItem) {
        if let a = sender.representedObject as? String { run(a) }
    }
}

extension NSScreen {
    var displayID: Int { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }
}

/// A borderless, transparent, non-activating panel on every Space, allowed a little past the screen edge.
final class EdgePanel: NSPanel {
    private let keyable: Bool
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    init(keyable: Bool) {
        self.keyable = keyable
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isMovableByWindowBackground = false
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// The tab's slop reaches past the screen edge on purpose.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - the tab

/// The one view of the tab, drawn inside a fixed canvas: the black drop (`EdgeOutline`) holding the column of items
/// (`EdgeColumn`, both PierKit) — folded, the indicators; grown, Inbox, agents, new task, Falar, Apontar, the menu —
/// the hover, the Dock-like magnification under the pointer, the drag along the edge, the labels and the finished toast
/// beside it. The window around it never moves while the pointer is on it: the canvas is sized for the grown tab, its
/// magnification and the widest label (`EdgeMetrics.canvasSize`), transparent outside the shape, and the shape alone
/// takes the pointer (`hitTest`). One number, `openness`, morphs the tab between folded and grown around the canvas's
/// middle (a spring, like the magnification); the items magnify in place and the body widens with its ends fixed, so
/// the edge side and the tab's centre stay exactly put through everything.
final class EdgeTabView: NSView {
    static let maxDots = 10
    /// How much an item grows right under the pointer, and over how many indicator pitches the growth fades.
    static let peakMagnification: CGFloat = 1.45
    static let magnifyReach: CGFloat = 2.4

    var metrics = EdgeMetrics.metrics(.medium) { didSet { if metrics != oldValue { applyMetrics() } } }
    /// Grown or folded; `openness` follows with a spring (at once with Reduce Motion).
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            opennessTarget = expanded ? 1 : 0
            if SurfaceStyle.reduceMotion { openness = opennessTarget; opennessVelocity = 0 }
            startSpring()
        }
    }
    private(set) var openness: CGFloat = 0
    private var opennessTarget: CGFloat = 0
    private var opennessVelocity: CGFloat = 0
    var onHover: ((Bool) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onClick: (() -> Void)?
    var onDotClick: ((String) -> Void)?
    var onAction: ((String) -> Void)?
    /// A spring moved: the panel re-lays out (the window itself does not move; the side panel's anchor may).
    var onRelayout: (() -> Void)?

    private let inbox = IconButton(symbol: "tray.fill", size: 28, symbolSize: 15, title: "Inbox")
    private let plus = IconButton(symbol: "plus", size: 26, symbolSize: 15, title: "Nova tarefa")
    private let talk = IconButton(symbol: "bubble.left.and.text.bubble.right.fill", size: 26, symbolSize: 13, title: "Falar")
    private let camera = IconButton(symbol: "camera.fill", size: 26, symbolSize: 14, title: "Apontar")
    private let more = IconButton(symbol: "ellipsis", size: 26, symbolSize: 12, title: "Mais")
    private var buttons: [IconButton] { [inbox, plus, talk, camera, more] }
    /// The indicators are drawn, not views: their rects (view coordinates) for labels, clicks and tests.
    private var indicatorRects: [NSRect] = []
    private var labels: [PillLabel] = []
    private var dots: [EdgeSurfaceController.Dot] = []
    private var overflow: NSTextField?
    private var toastPill: PillLabel?
    private var hoverLabel: PillLabel?
    /// Room kept beside the shape for the widest hover label, so showing one never resizes the window.
    private var labelReserve: CGFloat = 0
    private var edge = EdgeSide.right
    private var labelsShown = false
    private var sideWidth: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint?
    private var moved = false
    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    // Magnification: the pointer along the tab (base coordinates, nil when off the shape), the current and the target
    // scale per slot, the spring that takes them there.
    private var pointerBase: CGFloat?
    private var insideShape = false
    private var scales: [CGFloat] = []
    private var targets: [CGFloat] = []
    private var velocities: [CGFloat] = []
    private var springTimer: Timer?
    private var hoveredSlot: Int?
    // The last layout: what draw, clicks and the hit test go by.
    private var column = EdgeColumn(slots: [], top: 0)
    private var lay = EdgeColumn.Layout(tops: [], sizes: [])
    private var baseWidth: CGFloat = 23
    private var bodyWidth: CGFloat = 23
    private var shapeHeight: CGFloat = 0
    private var shapeTop: CGFloat = 0
    private var shapePath = NSBezierPath()
    private var hitPath = NSBezierPath()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in buttons {
            b.onBlack = true
            b.glow = true
            b.alphaValue = 0
            b.isHidden = true
            addSubview(b)
        }
        inbox.onClick = { [weak self] in self?.onAction?("inbox") }
        plus.onClick = { [weak self] in self?.onAction?("plus") }
        talk.onClick = { [weak self] in self?.onAction?("talk") }
        camera.onClick = { [weak self] in self?.onAction?("camera") }
        more.onClick = { [weak self] in
            guard let self, let e = NSApp.currentEvent else { return }
            self.onMenu?(e, self.more)
        }
        for b in buttons { b.onRightClick = { [weak self] e in self?.onMenu?(e, b) } }
        applyMetrics()
    }
    required init?(coder: NSCoder) { nil }

    /// The glyphs follow the size class (the Inbox and + a point bigger, Falar one smaller, "…" two).
    private func applyMetrics() {
        let g = metrics.glyph
        inbox.symbolSize = g + 1
        plus.symbolSize = g + 1
        talk.symbolSize = g - 1
        camera.symbolSize = g
        more.symbolSize = g - 2
        needsLayout = true
        needsDisplay = true
    }

    // MARK: content

    func set(dots: [EdgeSurfaceController.Dot], unseen: Int, strings: [String: String]) {
        self.dots = dots
        inbox.badge = unseen
        inbox.accessibilityTitle = strings["menuInbox"] ?? "Inbox"; inbox.toolTip = nil
        plus.accessibilityTitle = strings["menuNew"] ?? "Nova tarefa"
        talk.accessibilityTitle = strings["menuTalk"] ?? "Falar"
        camera.accessibilityTitle = strings["menuPoint"] ?? "Apontar"
        more.accessibilityTitle = strings["more"] ?? "Mais"
        let shown = Array(dots.prefix(Self.maxDots))
        indicatorRects = Array(repeating: .zero, count: shown.count)
        spin(dots.contains { $0.state == "working" })
        overflow?.removeFromSuperview(); overflow = nil
        if dots.count > shown.count {
            let f = SurfaceStyle.label("+\(dots.count - shown.count)", font: SurfaceStyle.mono(9, .semibold), color: NSColor.white.withAlphaComponent(0.7), alignment: .center)
            addSubview(f)
            overflow = f
        }
        for l in labels { l.removeFromSuperview() }
        labels = shown.map { d in
            let text = d.project.isEmpty ? d.title : "\(d.title) · \(d.project)"
            let pill = PillLabel("\(text)  \(d.word)", font: SurfaceStyle.font(12, .medium), color: SurfaceStyle.text, fill: SurfaceStyle.capsule, border: SurfaceStyle.stroke)
            pill.leading = DotView(color: SurfaceStyle.tabColor(forState: d.state))
            pill.sizeToFit()
            return pill
        }
        resetScalesIfNeeded()
        labelReserve = min(320, (0..<slotCount).compactMap { slotName($0) }.map { Self.hoverPill($0).frame.width }.max() ?? 0)
        needsLayout = true
        needsDisplay = true
    }

    /// The Dock-like label beside the item under the pointer.
    private static func hoverPill(_ name: String) -> PillLabel {
        let pill = PillLabel(name, font: SurfaceStyle.font(12, .semibold), color: NSColor.white, fill: NSColor.black.withAlphaComponent(0.85), border: NSColor.white.withAlphaComponent(0.12))
        pill.padding = NSSize(width: 10, height: 5)
        pill.sizeToFit()
        return pill
    }

    /// The working ring turns (30 steps a second) while an agent works; still with Reduce Motion.
    private func spin(_ on: Bool) {
        if on, !SurfaceStyle.reduceMotion {
            guard spinTimer == nil else { return }
            spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.spinAngle = (self.spinAngle + 8).truncatingRemainder(dividingBy: 360)
                    self.setNeedsDisplay(self.shapePath.bounds)
                }
            }
        } else {
            spinTimer?.invalidate(); spinTimer = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { spin(false); springTimer?.invalidate(); springTimer = nil }
    }

    // MARK: slots and magnification

    private var shownCount: Int { indicatorRects.count }
    /// Slot 0 is the Inbox, 1… the indicators (or the quiet ring), then +, Falar, Apontar, "…" (EdgeMetrics.toolSlot).
    private var slotCount: Int { EdgeMetrics.toolSlot(indicators: shownCount) + 4 }

    private func slotName(_ i: Int) -> String? {
        if i == 0 { return inbox.accessibilityTitle }
        let t = EdgeMetrics.toolSlot(indicators: shownCount)
        if i < t { return dots.indices.contains(i - 1) ? dots[i - 1].title : nil }
        switch i - t {
        case 0: return plus.accessibilityTitle
        case 1: return talk.accessibilityTitle
        case 2: return camera.accessibilityTitle
        default: return more.accessibilityTitle
        }
    }

    private func resetScalesIfNeeded() {
        let n = slotCount
        guard scales.count != n else { return }
        scales = Array(repeating: 1, count: n)
        targets = scales
        velocities = Array(repeating: 0, count: n)
    }

    private var magnifyReach: CGFloat { Self.magnifyReach * (metrics.indicator + metrics.indicatorGap) }

    /// New targets for the pointer's spot (on the current column: it morphs with the openness): the item under it
    /// grows, its neighbours less (a cosine fall-off), the rest stay. With Reduce Motion nothing grows; the item under
    /// the pointer is still known (its label, its glow).
    private func aim() {
        resetScalesIfNeeded()
        let col = metrics.column(openness: openness, indicators: shownCount)
        targets = col.targetScales(pointer: SurfaceStyle.reduceMotion ? nil : pointerBase, peak: Self.peakMagnification, reach: magnifyReach)
        if let p = pointerBase { hoveredSlot = col.index(at: p) } else { hoveredSlot = nil }
    }

    private func retarget() {
        aim()
        startSpring()
    }

    private func startSpring() {
        guard springTimer == nil else { return }
        springTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.springStep() }
        }
    }

    /// Critically damped springs (stiff, no overshoot): one for the openness, one per slot for the magnification.
    /// Stops once everything settled.
    private func springStep() {
        let dt: CGFloat = 1.0 / 60
        var settled = true
        if abs(openness - opennessTarget) > 0.001 || abs(opennessVelocity) > 0.01 {
            let k: CGFloat = 400, c = 2 * k.squareRoot()
            opennessVelocity += (-k * (openness - opennessTarget) - c * opennessVelocity) * dt
            openness = min(max(openness + opennessVelocity * dt, 0), 1)
            settled = false
        } else if openness != opennessTarget {
            openness = opennessTarget
            opennessVelocity = 0
        }
        // A still pointer while the shape morphs under it: its spot is read again, and the targets follow the column.
        if insideShape || pointerBase != nil { readPointer() }
        for i in scales.indices where targets.indices.contains(i) {
            let k: CGFloat = 320, c = 2 * k.squareRoot()
            velocities[i] += (-k * (scales[i] - targets[i]) - c * velocities[i]) * dt
            scales[i] += velocities[i] * dt
            if abs(scales[i] - targets[i]) > 0.002 || abs(velocities[i]) > 0.01 { settled = false }
        }
        if settled {
            scales = targets
            velocities = Array(repeating: 0, count: scales.count)
            springTimer?.invalidate(); springTimer = nil
        }
        needsLayout = true
        needsDisplay = true
        onRelayout?()
    }

    /// The pointer's spot from where it is on screen now.
    private func readPointer() {
        guard let window else { pointer(at: nil); return }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        pointer(at: hitPath.contains(p) ? p : nil)
    }

    /// The pointer at `p` (view coordinates) on the shape, or off it: the hover and the magnification follow.
    private func pointer(at p: NSPoint?) {
        pointerBase = p.map { $0.y - shapeTop }
        let inside = p != nil
        if inside != insideShape {
            insideShape = inside
            onHover?(inside)
        }
        aim()
        if inside || scales != targets { startSpring() }
    }

    /// The window's size for the state: the canvas (`EdgeMetrics.canvasSize`) plus what the labels beside the shape
    /// need — the widest hover label always, the ⌥ labels and the finished `toast` when shown.
    func measure(edge: EdgeSide, labels: Bool, toast: String?) -> NSSize {
        self.edge = edge
        labelsShown = labels
        resetScalesIfNeeded()
        sideWidth = labelReserve
        if labels, !self.labels.isEmpty { sideWidth = max(sideWidth, min(320, self.labels.map(\.frame.width).max() ?? 0)) }
        if let toast {
            toastPill?.removeFromSuperview()
            let pill = PillLabel(toast, font: SurfaceStyle.font(12, .semibold), color: SurfaceStyle.text, fill: SurfaceStyle.capsule, border: SurfaceStyle.stroke)
            pill.leading = DotView(color: SurfaceStyle.tabColor(forState: "done"))
            pill.padding = NSSize(width: 12, height: 7)
            pill.sizeToFit()
            if pill.frame.width > 360 { pill.frame.size.width = 360 }
            toastPill = pill
            sideWidth = max(sideWidth, pill.frame.width)
        } else {
            toastPill?.removeFromSuperview(); toastPill = nil
        }
        if sideWidth > 0 { sideWidth += 10 }
        return metrics.canvasSize(indicators: shownCount, peak: Self.peakMagnification, side: sideWidth)
    }

    /// The screen edge and the body's face, in the view's x.
    private var edgeX: CGFloat { edge == .right ? bounds.width - metrics.slop : metrics.slop }
    private var faceX: CGFloat { edge == .right ? edgeX - bodyWidth : edgeX + bodyWidth }

    /// The Inbox button, in the window's coordinates (AppKit, bottom-left origin); empty while folded.
    var inboxFrameInWindow: NSRect { openness > 0.5 ? convert(inbox.frame, to: nil) : .zero }

    /// Every button's frame in the window (tests sweep the pointer across them).
    var buttonFrames: [String: NSRect] {
        guard openness > 0.5 else { return [:] }
        var out: [String: NSRect] = ["inbox": convert(inbox.frame, to: nil), "plus": convert(plus.frame, to: nil), "talk": convert(talk.frame, to: nil),
                                     "camera": convert(camera.frame, to: nil), "more": convert(more.frame, to: nil)]
        for (i, r) in indicatorRects.enumerated() { out["dot\(i)"] = convert(r, to: nil) }
        return out
    }

    /// Whether a screen point is on the shape (the controller never folds the tab while the pointer is).
    func shapeContains(screen point: NSPoint) -> Bool {
        guard let window else { return false }
        return hitPath.contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    /// The outline as a path in the view: local x runs from the edge into the screen (x' = edgeX − x on the right
    /// edge, edgeX + x on the left), y from `top`.
    private func path(for outline: EdgeOutline, top: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for el in outline.elements {
            switch el {
            case .move(let p): path.move(to: p)
            case .line(let p): path.line(to: p)
            case .curve(let c): path.curve(to: c.p3, controlPoint1: c.c1, controlPoint2: c.c2)
            case .close: path.close()
            }
        }
        var place = AffineTransform(translationByX: edgeX, byY: top)
        if edge == .right { place.scale(x: -1, y: 1) }
        path.transform(using: place)
        return path
    }

    override func layout() {
        super.layout()
        resetScalesIfNeeded()
        let m = metrics, n = shownCount
        column = m.column(openness: openness, indicators: n)
        guard column.slots.count == scales.count, slotCount >= 5 else { return }
        lay = column.magnified(scales: scales)
        // The body widens by half the growth of the most magnified item (the glyph takes the rest from its margins),
        // its ends staying exactly where they are; the shape sits in the middle of the canvas.
        baseWidth = m.bodyWidth(openness: openness)
        let extra = zip(column.slots, scales).map { ($1 - 1) * $0.size * 0.5 }.max() ?? 0
        bodyWidth = baseWidth + max(0, extra)
        shapeHeight = m.height(openness: openness, indicators: n)
        shapeTop = m.shapeTop(openness: openness, indicators: n, canvasHeight: bounds.height)
        shapePath = path(for: EdgeOutline(width: bodyWidth, height: shapeHeight, profileWidth: baseWidth), top: shapeTop)
        hitPath = path(for: EdgeOutline(width: bodyWidth + 3, height: shapeHeight + 6, profileWidth: baseWidth + 3), top: shapeTop - 3)
        let edgeX = self.edgeX, faceX = self.faceX
        let cx = (edgeX + faceX) / 2
        func rect(_ i: Int) -> NSRect {
            let s = lay.sizes[i]
            return NSRect(x: cx - s / 2, y: lay.tops[i] + shapeTop, width: s, height: s)
        }
        let t = EdgeMetrics.toolSlot(indicators: n)
        let grow = 0.6 + 0.4 * openness   // the glyphs pop in with their boxes
        inbox.frame = rect(0)
        inbox.scale = scales[0] * grow
        for i in indicatorRects.indices { indicatorRects[i] = rect(1 + i) }
        for (k, b) in [plus, talk, camera, more].enumerated() {
            b.frame = rect(t + k)
            b.scale = scales[t + k] * grow
        }
        for b in buttons {
            b.isHidden = openness < 0.02
            b.alphaValue = openness * openness
        }
        if let overflow, let last = indicatorRects.last {
            overflow.frame = NSRect(x: min(edgeX, faceX), y: last.maxY + 1, width: bodyWidth, height: 12)
        }
        removeAllToolTips()
        // Labels, the toast and the hover label beside the shape, towards the middle of the screen.
        let sideX = edge == .right ? faceX - 10 : faceX + 10
        for (i, l) in labels.enumerated() {
            l.isHidden = !labelsShown
            guard labelsShown, indicatorRects.indices.contains(i) else { continue }
            let w = min(l.frame.width, 320)
            let cy = indicatorRects[i].midY
            l.frame = NSRect(x: edge == .right ? sideX - w : sideX, y: cy - l.frame.height / 2, width: w, height: l.frame.height)
            if l.superview == nil { addSubview(l) }
        }
        if let toastPill {
            if toastPill.superview == nil { addSubview(toastPill) }
            let w = toastPill.frame.width
            let cy = indicatorRects.first?.midY ?? bounds.midY
            toastPill.frame = NSRect(x: edge == .right ? sideX - w : sideX, y: cy - toastPill.frame.height / 2, width: w, height: toastPill.frame.height)
            toastPill.isHidden = labelsShown && !labels.isEmpty
        }
        if let slot = hoveredSlot, let name = slotName(slot), pointerBase != nil, !labelsShown, toastPill == nil, lay.tops.indices.contains(slot) {
            if hoverLabel?.text != name {
                hoverLabel?.removeFromSuperview()
                hoverLabel = Self.hoverPill(name)
            }
            guard let hoverLabel else { return }
            if hoverLabel.superview == nil { addSubview(hoverLabel) }
            let w = hoverLabel.frame.width
            let cy = lay.tops[slot] + lay.sizes[slot] / 2 + shapeTop
            hoverLabel.frame = NSRect(x: edge == .right ? sideX - w : sideX, y: cy - hoverLabel.frame.height / 2, width: w, height: hoverLabel.frame.height)
        } else {
            hoverLabel?.removeFromSuperview(); hoverLabel = nil
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !shapePath.isEmpty, lay.tops.count == slotCount, slotCount >= 5 else { return }
        let m = metrics
        let edgeX = self.edgeX, faceX = self.faceX
        SurfaceStyle.tab.setFill()
        shapePath.fill()
        // The slop past the edge (off screen), along the shape only.
        (edge == .right ? NSRect(x: edgeX, y: shapeTop, width: m.slop, height: shapeHeight) : NSRect(x: edgeX - m.slop, y: shapeTop, width: m.slop, height: shapeHeight)).fill()
        // A faint light just inside the outline, so the shape reads on dark wallpapers too.
        NSGraphicsContext.saveGraphicsState()
        shapePath.addClip()
        shapePath.lineWidth = 2
        NSColor.white.withAlphaComponent(0.14).setStroke()
        shapePath.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let t = EdgeMetrics.toolSlot(indicators: shownCount)
        let cx = (edgeX + faceX) / 2
        if indicatorRects.isEmpty, lay.sizes[1] > 0.5 {
            // No agent anywhere: a quiet ring, so the tab is still there to reach the Inbox and Falar; gone once grown.
            let s = lay.sizes[1], d = s * 0.65
            let cy = lay.tops[1] + shapeTop + s / 2
            let ring = NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            ring.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.55 * (1 - openness)).setStroke()
            ring.stroke()
        }
        for (i, rect) in indicatorRects.enumerated() where dots.indices.contains(i) {
            let d = dots[i]
            if hoveredSlot == 1 + i {
                let g = NSGradient(colors: [SurfaceStyle.tabColor(forState: d.state).withAlphaComponent(0.35), NSColor.clear])
                g?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: -rect.width * 0.45, dy: -rect.height * 0.45)), relativeCenterPosition: .zero)
            }
            IndicatorDrawing.draw(state: d.state, dimmed: d.state == "needsYou" && !d.focused, in: rect, angle: spinAngle)
        }
        if openness > 0.05 {
            // Hairlines between the grown tab's sections, in the middle of each section gap.
            NSColor.white.withAlphaComponent(0.12 * openness).setFill()
            let x0 = min(edgeX, faceX) + 6, w = bodyWidth - 12
            func mid(_ a: Int, _ b: Int) -> CGFloat { ((lay.tops[a] + lay.sizes[a]) + lay.tops[b]) / 2 + shapeTop }
            var ys: [CGFloat] = []
            if shownCount > 0 { ys.append(mid(0, 1)); ys.append(mid(t - 1, t)) } else { ys.append(mid(0, t)) }
            ys.append(mid(t + 2, t + 3))
            for y in ys { NSRect(x: x0, y: y - 0.5, width: w, height: 1).fill() }
        }
    }

    // MARK: hover, drag, clicks

    /// Only the shape takes the pointer (the buttons sit inside it): the transparent canvas and the labels beside the
    /// shape let clicks through to whatever is behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        return hitPath.contains(p) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // One area for the whole canvas; what counts is whether the pointer is on the shape (`pointer(at:)`).
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { pointer(at: nil) }
    override func mouseMoved(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pointer(at: hitPath.contains(p) ? p : nil)
    }

    /// Tests: the pointer at `y` from the shape's top (no real pointer).
    func debugMagnify(y: CGFloat) {
        pointer(at: NSPoint(x: (edgeX + faceX) / 2, y: shapeTop + y))
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        if !moved, abs(now.y - start.y) < 3 { return }
        moved = true
        onDrag?(now.y - start.y)
        dragStart = now
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if moved { onDragEnd?(); return }
        // A click on an indicator (its whole slot, gaps split) opens that agent; elsewhere on the shape, the Inbox.
        let p = convert(event.locationInWindow, from: nil)
        guard hitPath.contains(p) else { return }
        let t = EdgeMetrics.toolSlot(indicators: shownCount)
        if let i = column.index(at: p.y - shapeTop), i >= 1, i < t, dots.indices.contains(i - 1) {
            onDotClick?(dots[i - 1].id)
        } else {
            onClick?()
        }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event, self) }
}
