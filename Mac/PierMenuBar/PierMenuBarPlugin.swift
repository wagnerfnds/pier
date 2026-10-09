import AppKit
import Carbon.HIToolbox

/// The Mac's always-present surfaces, an AppKit plugin bundle the Mac Catalyst app loads at runtime (Catalyst cannot use
/// AppKit directly): the edge tab with its side panel (`EdgeSurfaceController`, `SidePanelController`), the optional menu
/// bar item, the ⌥ double tap (`OptionTapMonitor`) and "point at it" (`RegionPicker`). The app talks to it through
/// Objective-C methods with plain Foundation values only, mirrored by `PierMenuBarPluginAPI` in
/// App/Features/MenuBar/MenuBarBridge.swift:
///
/// * `start:` hands over the action handler: `"open:<box>/<session>"`, `"app"`, `"talk"`, `"new"`, `"inbox"`, `"settings"`,
///   `"optiontap"`, `"shot:<png path>"`, `"surface:…"` (position, edge, screen, size, full screen, hide, toggle),
///   `"card:…"` (the Inbox), `"agent:…"`, `"compose:…"`, `"talk:…"`, `"dictation:…"`, `"panel:screen:…"` (the side panel).
/// * `update:strings:` gives the agents (`id`, `state` = needsYou | working | done | ready, `title`, `project`, `word`,
///   `focused`, already in order) and the localized texts, so this bundle holds no strings of its own.
/// * `configureSurface:` the settings; `updateSurface:` the Inbox, the agents, the form, Falar; `permissions`,
///   `requestPermission:`, `pointAt:`, `screens`, `debugSurface:` for the rest.
///
/// ⌃⌥Space in any app is "talk" and ⌃⌥P shows or hides the tab (Carbon hot keys: no Accessibility permission, nothing
/// read from other apps).
@MainActor @objc(PierMenuBarPlugin)
public final class PierMenuBarPlugin: NSObject {
    private var item: NSStatusItem?
    private var handler: ((String) -> Void)?
    private var agents: [[String: String]] = []
    private var strings: [String: String] = [:]
    private var hotKeys: [EventHotKeyRef?] = []
    private var hotKeyHandler: EventHandlerRef?
    private var surface: EdgeSurfaceController?
    private var optionTap: OptionTapMonitor?
    private var picker: RegionPicker?
    private var tabEnabled = true
    /// Where a captured picture goes: Falar (the default) or the new task's form.
    private var shotTarget = "talk"

    /// Same values as the app's Theme tokens (DashState colors).
    private static let colors: [String: NSColor] = [
        "needsYou": NSColor(srgbRed: 0xF5 / 255, green: 0xA3 / 255, blue: 0x5C / 255, alpha: 1),
        "working": NSColor(srgbRed: 0x4A / 255, green: 0x99 / 255, blue: 0xFA / 255, alpha: 1),
        "done": NSColor(srgbRed: 0x4C / 255, green: 0xC3 / 255, blue: 0x8A / 255, alpha: 1),
        "ready": NSColor(srgbRed: 0x7A / 255, green: 0x81 / 255, blue: 0x8B / 255, alpha: 1),
    ]
    private static let order = ["needsYou", "working", "done", "ready"]
    /// More dots than this and the button shows a count per state instead.
    private static let maxDots = 6

    @objc public override init() { super.init() }

    @objc public func start(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        registerHotKeys()
        // Once laid out: where things are, and (for checking without screen recording) `PIER_MENUBAR_DUMP=<dir>` writes
        // the button image and the menu's titles there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.logState() }
        }
    }

    /// The menu bar item exists only while the setting asks for it (off by default now that the edge tab is there; on by
    /// itself when the tab is hidden, so there is always a way in).
    private func setMenuBar(visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.toolTip = "Pier"
            item.button?.setAccessibilityIdentifier("pier-menubar")
            self.item = item
            render()
            NSLog("PierMenuBar: status item created, visible=%d frame=%@", item.isVisible ? 1 : 0, NSStringFromRect(item.button?.window?.frame ?? .zero))
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func logState() {
        if let item { NSLog("PierMenuBar: frame=%@ agents=%d menu=%d items", statusFrame, agents.count, item.menu?.items.count ?? 0) }
        if let surface { NSLog("PierMenuBar: surface %@ %@", surface.frames, surface.panelController.debugState) }
        guard let dir = ProcessInfo.processInfo.environment["PIER_MENUBAR_DUMP"], let item else { return }
        let url = URL(fileURLWithPath: dir)
        if let img = item.button?.image, let tiff = img.tiffRepresentation(using: .none, factor: 4),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url.appendingPathComponent("menubar-button.png"))
        }
        let titles = (item.menu?.items ?? []).map { $0.isSeparatorItem ? "---" : ($0.attributedTitle?.string ?? $0.title) }
        try? titles.joined(separator: "\n").write(to: url.appendingPathComponent("menubar-menu.txt"), atomically: true, encoding: .utf8)
    }

    @objc public func update(_ agents: [[String: String]], strings: [String: String]) {
        self.agents = agents
        self.strings = strings
        render()
        surface?.update(dots: dots, unseen: unseen, strings: strings)
    }

    private var dots: [EdgeSurfaceController.Dot] {
        agents.map { a in
            EdgeSurfaceController.Dot(id: a["id"] ?? "", state: a["state"] ?? "ready", title: a["title"] ?? "", project: a["project"] ?? "",
                                      word: a["word"] ?? strings[a["state"] ?? ""] ?? "", focused: a["focused"] == "1")
        }
    }

    // MARK: the edge surface and the side panel

    private var unseen = 0

    /// The settings: `enabled`, `edge` (left | right), `fraction`, `fullScreen`, `appearance` (system | light | dark),
    /// `display` (main | pointer | a display id), `size` (small | medium | large), `menuBar` (the status item),
    /// `optionTap` (the ⌥ double tap, global when permitted), `optionLabels`.
    @objc public func configureSurface(_ config: [String: Any]) {
        tabEnabled = config["enabled"] as? Bool ?? true
        setMenuBar(visible: config["menuBar"] as? Bool ?? false)
        render()
        if surface == nil {
            let s = EdgeSurfaceController { [weak self] action in self?.handle(action) }
            surface = s
            update(agents, strings: strings)
        }
        var c = EdgeSurfaceController.Config()
        c.enabled = tabEnabled
        c.edge = EdgeSide(rawValue: config["edge"] as? String ?? "right") ?? .right
        c.fraction = config["fraction"] as? Double ?? 0.55
        c.fullScreen = config["fullScreen"] as? Bool ?? false
        c.appearance = config["appearance"] as? String ?? "system"
        c.display = config["display"] as? String ?? "main"
        c.size = EdgeSizeClass(rawValue: config["size"] as? String ?? "medium") ?? .medium
        c.optionLabels = config["optionLabels"] as? Bool ?? true
        surface?.configure(c)
        let wantTap = config["optionTap"] as? Bool ?? true
        if optionTap == nil {
            let m = OptionTapMonitor()
            m.onDoubleTap = { [weak self] in self?.send("optiontap") }
            m.onOptionHeld = { [weak self] held in self?.surface?.optionHeld = held }
            optionTap = m
        }
        optionTap?.start(global: wantTap)
    }

    /// The Inbox count and everything the side panel shows: `unseen`, `cards`, `current`, `pending`, `receipt`, `receiptFor`,
    /// `agents`, `agentDetail`, `compose`, `talk`, `dictation`, `started`.
    @objc public func updateSurface(_ data: [String: Any]) {
        unseen = (data["unseen"] as? NSNumber)?.intValue ?? 0
        guard let surface else { return }
        surface.panelController.update(data)
        surface.update(dots: dots, unseen: unseen, strings: strings)
    }

    /// The displays, for Ajustes → Mac → Tela: `id` and `name`, the main one first.
    @objc public var screens: [[String: Any]] {
        NSScreen.screens.map { ["id": $0.displayID, "name": $0.localizedName] }
    }

    /// What macOS lets this process do: `inputMonitoring`, `accessibility`, `screenRecording`, `optionTapGlobal` (whether
    /// the ⌥ double tap reaches other apps right now).
    @objc public var permissions: [String: Any] {
        ["inputMonitoring": OptionTapMonitor.inputMonitoringGranted, "accessibility": OptionTapMonitor.accessibilityTrusted,
         "screenRecording": RegionPicker.screenRecordingGranted, "optionTapGlobal": optionTap?.isGlobal ?? false]
    }

    /// `inputMonitoring` or `screenRecording`: the system's dialog, once. Returns whether it is granted now.
    @objc public func requestPermission(_ which: String) -> Bool {
        switch which {
        case "inputMonitoring":
            let ok = OptionTapMonitor.requestInputMonitoring()
            if let optionTap { optionTap.start(global: optionTap.wantsGlobal) }
            return ok || OptionTapMonitor.canListenGlobally
        case "screenRecording": return RegionPicker.requestScreenRecording()
        default: return false
        }
    }

    /// "Point at it": dims the screen for a drag; the picture goes back as `shot:<target>|<png path>` (or `shot:cancel`).
    /// `fakePath` (tests) stands in for the screen; `""` for the real capture. The target is whatever asked last (the
    /// new task's form, else Falar).
    @objc public func pointAt(_ fakePath: String) {
        guard picker == nil else { return }
        let fake = fakePath.isEmpty ? nil : NSImage(contentsOfFile: fakePath)
        if fakePath.isEmpty, !RegionPicker.screenRecordingGranted {
            // Asked only now, when the person reached for the feature. macOS needs a relaunch after granting.
            RegionPicker.requestScreenRecording()
            send("shot:permission")
            return
        }
        // The surface leaves the screen meanwhile: the picture is of what the person points at, never of the tab.
        surface?.setHidden(true)
        let target = shotTarget
        let p = RegionPicker(fake: fake) { [weak self] image in
            MainActor.assumeIsolated {
                self?.picker = nil
                self?.surface?.setHidden(false)
                guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    self?.handler?("shot:cancel"); return
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("pier-point-\(Int(Date().timeIntervalSince1970)).png")
                do { try png.write(to: url); self?.handler?("shot:\(target)|\(url.path)") } catch { self?.handler?("shot:cancel") }
                if target == "talk" { self?.surface?.panelController.show(.talk) }
            }
        }
        picker = p
        p.start()
    }

    /// Tests and screenshots: `hover`, `unhover`, `option`, `labels`, `collapse`, `toast`, `magnify:<y>`, `panel:<screen>`
    /// (inbox, agents, agent:<id>, task, chat, project, talk, close), `optiontap`, `pointat:auto`, `state`.
    @objc public func debugSurface(_ command: String) -> String {
        switch command {
        case "optiontap": optionTap?.simulateDoubleTap()
        case "toast": surface?.debugToast("\(strings["done"] ?? "Sua vez") · \(agents.first { $0["state"] == "working" }?["title"] ?? "Migrate the billing page")")
        case "pointat:auto":
            guard let picker, let screen = surface?.screen ?? NSScreen.main else { return "no picker" }
            let r = NSRect(x: screen.frame.midX - 360, y: screen.frame.midY - 160, width: 720, height: 320)
            picker.demo(rect: r, on: screen)
        case "state": break
        case "menu": return "menu[" + makeMenu().items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") + "]"
        default:
            if command.hasPrefix("panel:") {
                let name = String(command.dropFirst(6))
                if name == "close" { surface?.panelController.close() } else { surface?.panelController.show(screen(named: name)) }
            } else {
                surface?.debug(command)
            }
        }
        return "\(surface?.frames ?? "-") | \(surface?.panelController.debugState ?? "-") | \(surface?.panelController.debugContent ?? "-") | permissions=\(permissions)"
    }

    private func screen(named name: String) -> PanelScreen {
        switch name {
        case "inbox": .inbox
        case "agents": .agents
        case "task": .compose(chat: false)
        case "chat": .compose(chat: true)
        case "project": .project
        case "talk": .talk
        default: name.hasPrefix("agent:") ? .agent(String(name.dropFirst(6))) : .inbox
        }
    }

    // MARK: hot keys

    /// ⌃⌥Space anywhere: "talk"; ⌃⌥P: show / hide the tab. Carbon hot keys are delivered to this process whichever app is
    /// in front, with no permission to ask for; the handler runs on the main thread.
    private func registerHotKeys() {
        guard hotKeyHandler == nil else { return }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let plugin = Unmanaged<PierMenuBarPlugin>.fromOpaque(userData).takeUnretainedValue()
            let which = id.id
            MainActor.assumeIsolated { plugin.hotKey(which) }
            return noErr
        }, 1, &kind, me, &hotKeyHandler)
        guard status == noErr else { NSLog("PierMenuBar: hot key handler failed (%d)", status); return }
        for (n, key) in [(1, UInt32(kVK_Space)), (2, UInt32(kVK_ANSI_P))] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x50494552 /* PIER */, id: UInt32(n))
            let registered = RegisterEventHotKey(key, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            if registered != noErr { NSLog("PierMenuBar: hot key %d registration failed (%d)", n, registered) }
            hotKeys.append(ref)
        }
    }

    private func hotKey(_ id: UInt32) {
        switch id {
        case 1: send("talk")
        case 2: handler?("surface:toggle")   // stays where the person is: no activation
        default: break
        }
    }

    /// For logs and tests: the status button's frame on screen.
    @objc public var statusFrame: String { NSStringFromRect(item?.button?.window?.frame ?? .zero) }

    // MARK: button

    private func render() {
        guard let item, let button = item.button else { return }
        button.image = Self.image(for: agents.map { $0["state"] ?? "ready" })
        button.imagePosition = .imageOnly
        let waiting = agents.filter { $0["state"] == "needsYou" }.count
        button.setAccessibilityLabel(waiting > 0 ? "Pier, \(waiting) \(strings["needsYou"] ?? "")" : "Pier")
        item.menu = makeMenu()
    }

    static func image(for states: [String]) -> NSImage {
        let d: CGFloat = 8, gap: CGFloat = 4, h: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        // Each run: a dot and, when collapsed, its count.
        var runs: [(color: NSColor, count: String?)] = []
        if states.isEmpty {
            runs = []
        } else if states.count <= maxDots {
            runs = states.map { (colors[$0] ?? .gray, nil) }
        } else {
            for s in order {
                let n = states.filter { $0 == s }.count
                if n > 0 { runs.append((colors[s] ?? .gray, "\(n)")) }
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        var width: CGFloat = 0
        for r in runs {
            width += d
            if let c = r.count { width += 3 + (c as NSString).size(withAttributes: attrs).width }
            width += gap
        }
        width = max(d + 4, width - gap + 4)
        let image = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            var x: CGFloat = 2
            if runs.isEmpty {
                // Nobody running: a quiet ring.
                let ring = NSBezierPath(ovalIn: NSRect(x: x + 0.75, y: (h - d) / 2 + 0.75, width: d - 1.5, height: d - 1.5))
                ring.lineWidth = 1.5
                NSColor.secondaryLabelColor.setStroke()
                ring.stroke()
                return true
            }
            for r in runs {
                r.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (h - d) / 2, width: d, height: d)).fill()
                x += d
                if let c = r.count {
                    let size = (c as NSString).size(withAttributes: attrs)
                    (c as NSString).draw(at: NSPoint(x: x + 3, y: (h - size.height) / 2), withAttributes: attrs)
                    x += 3 + size.width
                }
                x += gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !tabEnabled {
            // The tab is hidden: the way back comes first (⌃⌥P does the same from anywhere).
            let show = action(strings["menuShowTab"] ?? "", "surface:toggle", key: "p")
            show.keyEquivalentModifierMask = [.control, .option]
            menu.addItem(show)
            menu.addItem(.separator())
        }
        if agents.isEmpty {
            let none = NSMenuItem(title: strings["empty"] ?? "", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for s in Self.order {
            let group = agents.filter { $0["state"] == s }
            guard !group.isEmpty else { continue }
            if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: "\(strings[s] ?? s) · \(group.count)"))
            for a in group {
                let mi = NSMenuItem(title: a["title"] ?? "", action: #selector(openAgent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = a["id"]
                mi.image = Self.dot(Self.colors[s] ?? .gray)
                let title = NSMutableAttributedString(string: a["title"] ?? "", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                if let p = a["project"], !p.isEmpty {
                    title.append(NSAttributedString(string: "   \(p)", attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                mi.attributedTitle = title
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action(strings["open"] ?? "Pier", "app", key: "o"))
        menu.addItem(action(strings["menuInbox"] ?? "Inbox", "inbox", key: "i"))
        // Shown with its global shortcut (⌃⌥Space), the same key that works from any app.
        let talk = action(strings["talk"] ?? "", "talk", key: " ")
        talk.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(talk)
        menu.addItem(action(strings["menuPoint"] ?? "", "camera", key: ""))
        menu.addItem(action(strings["new"] ?? "", "new", key: "n"))
        return menu
    }

    private func action(_ title: String, _ id: String, key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
        mi.target = self
        mi.representedObject = id
        return mi
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc private func openAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        send("open:\(id)")
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "surface:toggle" { handler?(id) } else if id == "camera" { shotTarget = "talk"; pointAt(ProcessInfo.processInfo.environment["PIER_FAKE_SHOT"] ?? "") } else { send(id) }
    }

    /// Bring the app and its window to the front, then let the app act.
    private func send(_ action: String) {
        activate()
        handler?(action)
    }

    private func activate() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    /// What the tab and the side panel send: nearly everything stays on the surface (no switch to Pier); only
    /// "app", "settings", a session opened in the app, a review, "Ajustar no Pier" bring the app to the front.
    private func handle(_ action: String) {
        switch action {
        case "camera":
            shotTarget = surface?.panelController.topScreen.map { if case .compose = $0 { "compose" } else { "talk" } } ?? "talk"
            pointAt(ProcessInfo.processInfo.environment["PIER_FAKE_SHOT"] ?? "")
        case "compose:camera":
            shotTarget = "compose"
            pointAt(ProcessInfo.processInfo.environment["PIER_FAKE_SHOT"] ?? "")
        case "app", "settings", "new":
            send(action)
        case "panel:relayout":
            surface?.panelController.relayout()
        default:
            if action.hasPrefix("open:") || action.hasPrefix("card:open:") || action.hasPrefix("card:review:") || action.hasPrefix("agent:open:")
                || action.hasPrefix("agent:review:") || action == "talk:open" { activate() }
            handler?(action)
        }
    }
}
