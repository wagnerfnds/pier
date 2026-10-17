// Mac only: the menu bar item and the edge surface (the tab at the screen's edge, its toolbar and the Inbox card) live in
// an AppKit plugin bundle (Mac/PierMenuBar, embedded in Contents/PlugIns by the PierMenuBar target in project.yml),
// since a Catalyst app cannot use AppKit itself. The native Mac app (the PierMac spike) compiles the plugin's code in
// and creates it directly: the same calls, no bundle to load.
#if targetEnvironment(macCatalyst) || os(macOS)
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import PierKit

/// The plugin's Objective-C surface (PierMenuBarPlugin in Mac/PierMenuBar). Selectors must match: `start:`,
/// `update:strings:`, `statusFrame`, `configureSurface:`, `updateSurface:`, `permissions`, `requestPermission:`,
/// `pointAt:`, `debugSurface:`.
@objc protocol PierMenuBarPluginAPI: NSObjectProtocol {
    func start(_ handler: @escaping (String) -> Void)
    func update(_ agents: [[String: String]], strings: [String: String])
    var statusFrame: String { get }
    func configureSurface(_ config: [String: Any])
    func updateSurface(_ data: [String: Any])
    var permissions: [String: Any] { get }
    var screens: [[String: Any]] { get }
    func requestPermission(_ which: String) -> Bool
    func pointAt(_ fakePath: String)
    func debugSurface(_ command: String) -> String
}

/// Loads the plugin, keeps its dots, menu and surface in step with the app's sessions, and runs what is picked there.
@MainActor @Observable final class MenuBarBridge {
    static let shared = MenuBarBridge()

    @ObservationIgnored private var plugin: PierMenuBarPluginAPI?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var pending: [Part: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSent: [[String: String]]?
    @ObservationIgnored private var lastParts: [Part: NSDictionary] = [:]
    @ObservationIgnored private var configTask: Task<Void, Never>?
    @ObservationIgnored let surface = MacSurfaceStore()
    /// What macOS lets the app do (Ajustes → Mac reads it): `inputMonitoring`, `accessibility`, `screenRecording`,
    /// `optionTapGlobal`.
    private(set) var permissions: [String: Bool] = [:]
    /// How many of Ajustes → Mac's rows are on screen (they count themselves in and out): coming back to the app reads
    /// the permissions again only then, for one the person may have just granted in System Settings.
    @ObservationIgnored var settingsRowsShown = 0
    /// The displays (id, name) for Ajustes → Mac → Tela.
    var screens: [(id: Int, name: String)] {
        (plugin?.screens ?? []).compactMap { d in
            guard let id = (d["id"] as? NSNumber)?.intValue, let name = d["name"] as? String else { return nil }
            return (id, name)
        }
    }
    var loaded: Bool { plugin != nil }

    func start(model: AppModel) {
        guard plugin == nil else { return }
        self.model = model
        surface.model = model
        #if targetEnvironment(macCatalyst)
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PierMenuBar.bundle"),
              let bundle = Bundle(url: url) else { NSLog("PierMenuBar: bundle missing in PlugIns"); return }
        do { try bundle.loadAndReturnError() } catch { NSLog("PierMenuBar: load failed: %@", String(describing: error)); return }
        guard let cls = bundle.principalClass as? NSObject.Type else { NSLog("PierMenuBar: no principal class"); return }
        let obj = cls.init()
        guard obj.responds(to: NSSelectorFromString("updateSurface:")) else { NSLog("PierMenuBar: unexpected plugin API"); return }
        // Both sides declare the protocol separately, so a cast would not match; the selectors do.
        let p = unsafeBitCast(obj, to: PierMenuBarPluginAPI.self)
        #else
        let p: PierMenuBarPluginAPI = PierMenuBarPlugin()
        #endif
        plugin = p
        p.start { [weak self] action in MainActor.assumeIsolated { self?.handle(action) } }
        // An action changed the surface's own state (not observed): every part is read again, at once.
        surface.onChange = { [weak self] in
            for part in Part.allCases { self?.schedule(part, fast: true) }
        }
        #if DEBUG
        let dups = Self.duplicateStringKeys
        if !dups.isEmpty { NSLog("PierMenuBar: duplicate string keys %@", dups.joined(separator: ", ")) }
        assert(dups.isEmpty, "MenuBarBridge.strings lists a key twice: \(dups)")
        #endif
        configure()
        push()
        refreshPermissions()
        NSLog("PierMenuBar: loaded, status item at %@", p.statusFrame)
        // The settings (Ajustes → Mac, the surface's own menu) reach the plugin through UserDefaults.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleConfigure() }
        }
        // Coming back to the app: the settings, if they changed meanwhile, and — only while Ajustes → Mac is on screen —
        // the permissions, which the person may have just granted in System Settings (the checks are synchronous privacy
        // queries: not on every activation).
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configure()
                if self.settingsRowsShown > 0 { self.refreshPermissions() }
            }
        }
        #if DEBUG
        // `-menuBarAction open:<box>/<session> | talk | new | app`: runs a menu pick after launch (the menu itself cannot be
        // clicked without Accessibility permission). `-macSurfaceDebug "hover,card,pick:1"` drives the surface the same way
        // (one command every 1.5 s): hover, unhover, option, labels, card, optiontap, pointat, pointat:auto, pick:<n>, undo,
        // page:<n>, reply:<text>, state (what is on screen goes to the log).
        if let a = UserDefaults.standard.string(forKey: "menuBarAction") {
            Task { try? await Task.sleep(for: .seconds(4)); NSLog("PierMenuBar: debug action %@", a); handle(a) }
        }
        if let script = UserDefaults.standard.string(forKey: "macSurfaceDebug") {
            Task {
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "macSurfaceDebugDelay") > 0 ? UserDefaults.standard.double(forKey: "macSurfaceDebugDelay") : 4))
                for cmd in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    NSLog("PierMenuBar: debug surface %@ -> %@", cmd, debug(cmd))
                    try? await Task.sleep(for: .milliseconds(1500))
                }
            }
        }
        #endif
    }

    // MARK: updates

    /// What the plugin gets, in three parts that each follow what they read on their own (an observation, a debounce
    /// and a last value sent of their own), so a change re-reads and re-sends only what depends on it: a reply streaming
    /// in the panel's agent re-reads that agent, not every Inbox card and every session's dot.
    /// * `inbox`: the Inbox's count and cards, the answer waiting and its receipt, dictation, the form, Falar;
    /// * `dots`: the tab's indicators (`update:strings:`) and the panel's list of agents (`agents`);
    /// * `agent`: the agent the panel shows (`agentDetail`) and a task just started there (`started`).
    /// The side panel's parts go through `updateSurface:` tagged with `part`; the plugin keeps the last of each.
    private enum Part: String, CaseIterable {
        // The Inbox first: it settles which card is shown, which the dots mark.
        case inbox, dots, agent
    }

    /// Every part, now (launch).
    private func push() {
        for part in Part.allCases { push(part) }
    }

    private func push(_ part: Part) {
        guard let model, let plugin else { return }
        let span = Perf.begin("bridge.push")
        defer { Perf.end(span) }
        switch part {
        case .inbox:
            let shown = surface.current
            send(.inbox, tracking(.inbox) { surface.inboxPart() })
            // The card shown left the Inbox and another took its place: the tab's full amber dot follows it.
            if surface.current != shown { schedule(.dots, fast: true) }
        case .dots:
            let (dots, marked, rows) = tracking(.dots) { () -> ([AgentDot], [[String: String]], [[String: Any]]) in
                let dots = AgentDots.make(model)
                return (dots, surface.mark(dots), surface.agentRows(dots))
            }
            surface.dots = dots
            if marked != lastSent {
                lastSent = marked
                plugin.update(marked, strings: Self.strings)
            }
            send(.dots, ["agents": rows])
        case .agent:
            send(.agent, tracking(.agent) { surface.agentPart() })
        }
    }

    /// Reads `read` and pushes `part` again (after its debounce) once something it read changes.
    private func tracking<T>(_ part: Part, _ read: () -> T) -> T {
        withObservationTracking(read, onChange: { [weak self] in
            Task { @MainActor in self?.schedule(part, fast: false) }
        })
    }

    /// A part of the side panel's payload, unless it is the one this part sent last.
    private func send(_ part: Part, _ data: [String: Any]) {
        if lastParts[part]?.isEqual(to: data) == true { return }
        lastParts[part] = data as NSDictionary
        var tagged = data
        tagged["part"] = part.rawValue
        plugin?.updateSurface(tagged)
    }

    /// At most a few pushes a second per part; `fast` for an action's result.
    private func schedule(_ part: Part, fast: Bool) {
        guard pending[part] == nil else { return }
        pending[part] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(fast ? 30 : 250))
            self?.pending[part] = nil
            self?.push(part)
        }
    }

    @ObservationIgnored private var lastConfig: NSDictionary?

    /// Sends the surface's settings, unless they are the ones it already has: `configureSurface` restarts the ⌥ key
    /// monitors, rebuilds the status menu and re-pins both panels, and UserDefaults changes for many other reasons (the
    /// window's frame, split panes, session snapshots), as does the app's activation. `force` when the monitors must
    /// start again (a permission just granted).
    private func configure(force: Bool = false) {
        let config = MacSurfaceSettings.config
        let dict = config as NSDictionary
        if !force, let lastConfig, lastConfig.isEqual(dict) { return }
        lastConfig = dict
        plugin?.configureSurface(config)
    }

    private func scheduleConfigure() {
        guard configTask == nil else { return }
        configTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.configTask = nil
            self?.configure()
        }
    }

    static func key(_ s: DashState) -> String {
        switch s {
        case .needsYou: "needsYou"
        case .working: "working"
        case .done: "done"
        case .ready: "ready"
        }
    }

    /// Built from pairs, never a dictionary literal: a key listed twice would trap at launch (a literal with duplicate
    /// keys does); here the first wins and, in Debug, `stringsSelfCheck` reports the duplicate at launch.
    private static var strings: [String: String] {
        Dictionary(stringPairs, uniquingKeysWith: { a, _ in a })
    }

    /// Debug launch self-check: the keys listed more than once (none, or the build is wrong).
    static var duplicateStringKeys: [String] {
        var seen: Set<String> = [], dups: [String] = []
        for (k, _) in stringPairs where !seen.insert(k).inserted { dups.append(k) }
        return dups
    }

    private static var stringPairs: [(String, String)] {
        [
            ("needsYou", AgentDots.stateWord(.needsYou)), ("working", AgentDots.stateWord(.working)),
            ("done", AgentDots.stateWord(.done)), ("ready", AgentDots.stateWord(.ready)),
            ("open", S("Abrir Pier")), ("talk", S("Falar")), ("new", S("Nova tarefa")),
            ("empty", S("Nenhum agente rodando")),
            // The edge surface and its menu.
            ("menuOpen", S("Abrir Pier")), ("menuInbox", S("Inbox")), ("menuAgents", S("Agentes")), ("menuTalk", S("Falar…")),
            ("menuNew", S("Nova tarefa")), ("menuNewChat", S("Nova conversa")), ("menuPoint", S("Apontar na tela…")), ("menuShowTab", S("Mostrar a aba na borda")),
            // The side panel.
            ("agents", S("Agentes")), ("agent", S("Agente")), ("noAgents", S("Nenhum agente rodando. Comece uma tarefa ou uma conversa com +.")),
            ("back", S("Voltar")), ("close", S("Fechar")), ("lastReply", S("Última resposta")), ("starting", S("Iniciando…")),
            ("interrupt", S("Interromper")), ("openInPier", S("Abrir no Pier")), ("message", S("Mensagem para o agente")), ("workingStep", S("Trabalhando…")),
            ("newTask", S("Nova tarefa")), ("newChat", S("Nova conversa")), ("project", S("Projeto")), ("chooseProject", S("Escolha um projeto")),
            ("newWorktree", S("Nova worktree")), ("onMain", S("Na principal")), ("model", S("Modelo")), ("effort", S("Esforço")), ("auto", S("Padrão")),
            ("taskPrompt", S("O que o agente deve fazer?")), ("chatPrompt", S("Sobre o que é a conversa?")), ("startTask", S("Iniciar")), ("startChat", S("Começar")),
            ("removePicture", S("Remover imagem")), ("searchProject", S("Buscar projeto")), ("recent", S("recente")),
            ("talkPrompt", S("Diga ou escreva o que você precisa…")), ("yourAnswer", S("Sua resposta…")), ("route", S("Encaminhar")),
            ("routing", S("Procurando o agente certo…")), ("send", S("Enviar")), ("createTask", S("Criar tarefa")), ("adjustInPier", S("Ajustar no Pier")),
            ("menuEdge", S("Borda")), ("menuLeft", S("Esquerda")), ("menuRight", S("Direita")),
            ("menuPosition", S("Posição")), ("menuTop", S("Topo")), ("menuMiddle", S("Meio")), ("menuBottom", S("Base")),
            ("menuSize", S("Tamanho")), ("menuSmall", S("Pequeno")), ("menuMedium", S("Médio")), ("menuLarge", S("Grande")),
            ("menuScreen", S("Tela")), ("menuMainScreen", S("Principal")), ("menuPointerScreen", S("Onde está o ponteiro")),
            ("menuFullScreen", S("Mostrar sobre apps em tela cheia")), ("menuHide", S("Ocultar a aba")), ("menuSettings", S("Ajustes…")),
            ("dictate", S("Ditar")), ("more", S("Mais")),
            // The agent's conversation in the panel.
            ("olderMessages", S("Mensagens anteriores")), ("conversationStart", S("Início da conversa")), ("sent", S("Enviado")),
            ("queued", S("Na fila: vai quando o agente terminar a vez")),
            ("openingConversation", S("Abrindo a conversa…")), ("toBottom", S("Ir para o fim")),
            // The Inbox card.
            ("recommended", S("Recomendado")), ("nextSteps", S("Próximos passos")), ("cardOpen", S("Abrir sessão")), ("cardConversation", S("Ver conversa")),
            ("review", S("Revisar")), ("archive", S("Arquivar")), ("dismiss", S("Dispensar")),
            ("readingOptions", S("Lendo as opções na tela…")), ("suggesting", S("Sugerindo próximos passos…")),
            ("noReply", S("Terminou a vez.")), ("sending", S("Enviando…")), ("undoEsc", S("Esc desfaz")),
            ("hintPress", S("Pressione")), ("hintOr", S("ou")), ("hintAnswer", S("para responder")),
            ("hintNext", S("para mandar um próximo passo")), ("hintKeys", S("R escrever · E arquivar")),
            ("emptyTitle", S("Nenhum agente esperando você")),
            ("emptyBody", S("Perguntas e trabalho terminado de todos os agentes aparecem aqui.")),
        ]
    }

    // MARK: permissions, point at it, debug

    /// Reads what macOS lets the app do (at launch, and while Ajustes → Mac is on screen).
    func refreshPermissions() {
        guard let plugin else { return }
        var out = plugin.permissions.mapValues { ($0 as? Bool) ?? false }
        // Input Monitoring (or Accessibility) granted since the ⌥ monitors started: configuring the surface again
        // starts them again, for every app now.
        if MacSurfaceSettings.optionTap, out["optionTapGlobal"] == false, out["inputMonitoring"] == true || out["accessibility"] == true {
            configure(force: true)
            out = plugin.permissions.mapValues { ($0 as? Bool) ?? false }
        }
        if out != permissions { permissions = out }
    }

    /// Asks macOS for `inputMonitoring` (the ⌥ double tap in any app) or `screenRecording` (point at it): the system's
    /// dialog, only from the person's own tap in Ajustes.
    @discardableResult func requestPermission(_ which: String) -> Bool {
        let ok = plugin?.requestPermission(which) ?? false
        refreshPermissions()
        return ok
    }

    /// "Point at it": the plugin dims the screen for a drag and comes back with `shot:<path>`.
    func pointAt() {
        var fake = ""
        #if DEBUG
        fake = UserDefaults.standard.string(forKey: "macFakeShot") ?? ""
        #endif
        plugin?.pointAt(fake)
    }

    @discardableResult func debug(_ command: String) -> String {
        if command.hasPrefix("pick:"), let n = Int(command.dropFirst(5)), let id = surface.current { surface.pick(id, n); return "pick \(id) \(n)" }
        if command == "undo" { surface.undo(); return "undo" }
        if command.hasPrefix("page:"), let n = Int(command.dropFirst(5)) { surface.page(by: n); return "page" }
        if command.hasPrefix("reply:"), let id = surface.current { surface.reply(id, String(command.dropFirst(6))); return "reply" }
        if command.hasPrefix("agentsend:") { return surface.debugAgentSend(String(command.dropFirst(10))) }
        if command == "pointat" { pointAt(); return "pointat" }
        return plugin?.debugSurface(command) ?? "-"
    }

    // MARK: actions

    private func handle(_ action: String) {
        guard let model else { return }
        let router = model.router
        // The window may have been closed: ask for it again (not for what stays on the surface).
        #if targetEnvironment(macCatalyst)
        if !action.hasPrefix("surface:") && !action.hasPrefix("card:") && !action.hasPrefix("shot:") && action != "optiontap",
           !UIApplication.shared.connectedScenes.contains(where: { $0.activationState != .unattached }) {
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
        }
        #endif
        switch action {
        case "app": break
        case "talk", "optiontap":
            // "Falar" from the menu or the toolbar, ⌃⌥Space from any app (the plugin's hot key), or ⌥ tapped twice: the
            // Talk sheet, ready for the words.
            router.showPalette = false
            TalkCenter.shared.open(listen: false)
        case "mic":
            router.showPalette = false
            TalkCenter.shared.open(listen: true)
        case "new":
            if let b = model.prefs.lastBox ?? model.boxes.first?.name { PaletteActions.newTask(router, box: b) }
        case "inbox":
            router.select(.tab(.inbox))
        case "settings":
            router.select(.tab(.settings))
        case "shot:cancel":
            break
        case "shot:permission":
            model.showToast(S("Permita a gravação de tela em Ajustes do Sistema e abra o Pier de novo."), symbol: "camera.fill")
            router.select(.tab(.settings))
        case "surface:hide", "surface:toggle":
            // ⌃⌥P from anywhere, the menu: the tab goes or comes back; hidden, the menu bar item takes over.
            let show = action == "surface:toggle" && !MacSurfaceSettings.enabled
            UserDefaults.standard.set(show, forKey: MacSurfaceSettings.enabledKey)
            MacSurfaceSettings.enforce()
            if !show { model.showToast(S("Aba oculta · ⌃⌥P mostra de novo"), symbol: "sidebar.right") }
        default:
            if action.hasPrefix("open:") {
                let id = action.dropFirst(5)
                guard let slash = id.firstIndex(of: "/") else { return }
                model.openSession(box: String(id[..<slash]), name: String(id[id.index(after: slash)...]))
            } else if action.hasPrefix("shot:") {
                // A picture of part of the screen, for the panel's form or its Falar (the app's sheet only when asked).
                let rest = String(action.dropFirst(5))
                guard let bar = rest.firstIndex(of: "|") else { return }
                let target = String(rest[..<bar]), path = String(rest[rest.index(after: bar)...])
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = TalkImage.make(from: data) else { return }
                try? FileManager.default.removeItem(atPath: path)
                if target == "compose" { surface.composeImage(image) } else { surface.talkImage(image) }
            } else if action.hasPrefix("surface:") {
                setting(String(action.dropFirst(8)))
            } else if action.hasPrefix("card:") {
                card(String(action.dropFirst(5)))
            } else if action.hasPrefix("panel:screen:") {
                surface.panelScreen(String(action.dropFirst(13)))
            } else if action.hasPrefix("agent:") {
                agent(String(action.dropFirst(6)))
            } else if action.hasPrefix("compose:") {
                compose(String(action.dropFirst(8)))
            } else if action.hasPrefix("talk:") {
                talkAction(String(action.dropFirst(5)))
            } else if action.hasPrefix("dictation:toggle:") {
                surface.toggleDictation(target: String(action.dropFirst(17)))
            }
        }
    }

    /// The surface's own menu and drag: position, edge, display, size, full screen; remembered in UserDefaults (the same
    /// keys Ajustes → Mac edits, so the two stay in step).
    private func setting(_ s: String) {
        let d = UserDefaults.standard
        if s.hasPrefix("fraction:"), let f = Double(s.dropFirst(9)) { d.set(f, forKey: MacSurfaceSettings.fractionKey) }
        else if s.hasPrefix("edge:") { d.set(String(s.dropFirst(5)), forKey: MacSurfaceSettings.edgeKey) }
        else if s.hasPrefix("display:") { d.set(String(s.dropFirst(8)), forKey: MacSurfaceSettings.displayKey) }
        else if s.hasPrefix("size:") { d.set(String(s.dropFirst(5)), forKey: MacSurfaceSettings.sizeKey) }
        else if s.hasPrefix("fullscreen:") { d.set(s.hasSuffix("1"), forKey: MacSurfaceSettings.fullScreenKey) }
    }

    private func split(_ s: Substring) -> (String, String)? {
        guard let bar = s.firstIndex(of: "|") else { return nil }
        return (String(s[..<bar]), String(s[s.index(after: bar)...]))
    }

    /// The agent screen: `pick:<id>|<n>`, `send:<id>|<text>`, `older:<id>`, `interrupt:<id>`, `archive:<id>`, `review:<id>`,
    /// `open:<id>`, `undo`.
    private func agent(_ a: String) {
        if a.hasPrefix("pick:"), let (id, n) = split(a.dropFirst(5)), let n = Int(n) { surface.agentPick(id, n) }
        else if a.hasPrefix("older:") { surface.agentOlder(String(a.dropFirst(6))) }
        else if a.hasPrefix("send:"), let (id, text) = split(a.dropFirst(5)) { surface.agentSend(id, text) }
        else if a.hasPrefix("interrupt:") { surface.agentInterrupt(String(a.dropFirst(10))) }
        else if a.hasPrefix("archive:") { surface.agentArchive(String(a.dropFirst(8))) }
        else if a.hasPrefix("review:") { surface.agentReview(String(a.dropFirst(7))) }
        else if a.hasPrefix("open:") { surface.agentOpen(String(a.dropFirst(5))) }
        else if a == "undo" { surface.undo() }
    }

    /// The form: `kind:task|chat`, `project:<box>/<loc>`, `worktree:new|main`, `agent:<id>`, `model:<m>`, `effort:<e>`,
    /// `start|<prompt>`, `image:clear`.
    private func compose(_ c: String) {
        if c.hasPrefix("start|") { surface.composeStart(String(c.dropFirst(6))) }
        else if c == "image:clear" { surface.composeImage(nil) }
        else if let colon = c.firstIndex(of: ":") { surface.composeSet(String(c[..<colon]), String(c[c.index(after: colon)...])) }
    }

    /// Falar in the panel: `route|<text>`, `confirm`, `open` (the app's sheet), `undo`, `image:clear`.
    private func talkAction(_ t: String) {
        if t.hasPrefix("route|") { surface.talkRoute(String(t.dropFirst(6))) }
        else if t == "confirm" { surface.talkConfirm() }
        else if t == "open" { surface.talkOpen() }
        else if t == "undo" { PendingActions.shared.undoLatest() }
        else if t == "image:clear" { surface.talkImage(nil) }
    }

    /// The Inbox card: `state:1|0`, `page:<delta>`, `page:to:<i>`, `pick:<id>|<n>`, `reply:<id>|<text>`, `clear:<id>`,
    /// `open:<id>`, `review:<id>`, `undo`, `mic:<id>`.
    private func card(_ c: String) {
        if c.hasPrefix("state:") { surface.setOpen(c.hasSuffix("1")) }
        else if c.hasPrefix("page:to:"), let i = Int(c.dropFirst(8)) { surface.page(to: i) }
        else if c.hasPrefix("page:"), let n = Int(c.dropFirst(5)) { surface.page(by: n) }
        else if c.hasPrefix("pick:"), let (id, n) = split(c.dropFirst(5)), let n = Int(n) { surface.pick(id, n) }
        else if c.hasPrefix("reply:"), let (id, text) = split(c.dropFirst(6)) { surface.reply(id, text) }
        else if c.hasPrefix("clear:") { surface.clear(String(c.dropFirst(6))) }
        else if c.hasPrefix("open:") { surface.open(String(c.dropFirst(5))) }
        else if c.hasPrefix("review:") { surface.review(String(c.dropFirst(7))) }
        else if c == "undo" { surface.undo() }
        else if c.hasPrefix("mic:") { surface.toggleDictation(target: "inbox") }
    }
}
#endif
