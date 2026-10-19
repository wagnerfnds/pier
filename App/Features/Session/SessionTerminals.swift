import SwiftUI
import UIKit
import PierKit

// The session screen's terminal tabs: beside the conversation, the plain terminals of the session's worktree, each a
// shell of its own on the box (`POST /v1/sessions` with the worktree's ref, no agent), the way an editor keeps its
// terminals next to the code, and the worktree's page in the app's browser (PreviewBrowser.swift). Nothing shows until
// the worktree has one of them: a session without a terminal is just its chat. On the iPad and the Mac they can show
// beside the conversation instead of over it ("Lado a lado"), in a split whose divider is dragged.

// MARK: - model

/// A session's terminal tabs for the app's run: the plain terminals of its worktree (the box's list, whoever opened
/// them), the worktree's browser once opened, the tab picked (nil: Conversa), whether they show beside the conversation,
/// and a feed per terminal, so its lines stay while another tab shows (only the one on screen reads the box). Opening,
/// closing and renaming go to the box.
@MainActor @Observable
final class SessionTerminals {
    /// A tab beside Conversa: one of the worktree's terminals (by session name), or its browser.
    enum SideTab: Hashable {
        case terminal(String)
        case browser
    }

    let box: String
    let session: String
    /// The worktree's ref ("loc/wt", "loc" for the main checkout); nil for a chat or a session in no worktree: no terminals.
    let ref: String?
    /// The session's folder: its worktree's, when the box's locations are not loaded yet.
    private let dir: String
    /// The tab picked; nil, or one that is gone: Conversa (side by side, the right pane shows `side(in:)`).
    private(set) var selected: SideTab?
    /// The tab beside Conversa picked last: what the right pane shows when side by side is turned on from Conversa.
    @ObservationIgnored private var lastSide: SideTab?
    /// The tabs show beside the conversation instead of over it (iPad, Mac, where the screen has room for both): the
    /// person's choice for this session, kept with its other view choices (`SessionViewPrefs`).
    private(set) var sideBySide: Bool
    /// A terminal is being opened: the buttons that open one wait for it.
    private(set) var opening = false
    /// The terminal whose command line takes the keyboard when it shows (one just opened; on the Mac, one picked).
    var focusTarget: String?
    /// Why opening, closing or renaming failed, or a line or key did not go.
    var banner: BannerMessage?
    /// The live terminals shown last (the latest at the end): they stay mounted (hidden) when another tab is picked, so
    /// picking one again shows it at once, still streaming. A few only: each holds one of the box's terminals.
    private(set) var shown: [String] = []
    /// Fewer on the Mac, where a window stays open all day and every terminal kept streams into its own surface.
    private static let kept = Platform.isMac ? 3 : 4
    /// Every live terminal shown here, for letting go of those the box no longer has.
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var feeds: [String: TerminalFeed] = [:]
    /// What each terminal's last screen shows running, read once per screen (the tabs ask on every redraw).
    @ObservationIgnored private var runningCache: [String: (screen: String, command: String?)] = [:]
    @ObservationIgnored private weak var model: AppModel?

    private init(vm: SessionViewModel) {
        box = vm.box
        session = vm.name
        let s = vm.session
        ref = s.isAgent && !s.chat ? s.location.flatMap { $0.isEmpty ? nil : $0 } : nil
        dir = s.dir
        model = vm.model
        sideBySide = ref != nil && SessionViewPrefs.sideBySide(box: vm.box, name: vm.name)
    }

    /// Side by side needs room for both panes: the conversation and a terminal at a width each still reads at.
    nonisolated static let minConversation: CGFloat = 360
    nonisolated static let minSide: CGFloat = 340

    /// A screen `width` points wide holds both panes (and the divider). Asked during layout, off the main actor.
    nonisolated static func fits(width: CGFloat) -> Bool { width >= minConversation + minSide + 1 }

    private static var registry: [String: SessionTerminals] = [:]
    private static var recent: [String] = []

    /// The tabs of the session `vm` shows, kept for the sessions opened last while the app runs (older ones are let go:
    /// their terminals stay on the box and come back as tabs when the session is opened again).
    static func of(_ vm: SessionViewModel) -> SessionTerminals {
        let key = "\(vm.box)/\(vm.name)"
        if recent.last != key {
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > 24 { evict(recent.removeFirst()) }
        }
        if let t = registry[key] {
            if t.model == nil { t.model = vm.model }
            return t
        }
        let t = SessionTerminals(vm: vm)
        registry[key] = t
        return t
    }

    /// A session's tabs let go, and with them the live terminals no other session's tabs show: each kept its surface and
    /// its scrollback for the rest of the app's run.
    private static func evict(_ key: String) {
        guard let gone = registry.removeValue(forKey: key) else { return }
        let still = registry.values.filter { $0.box == gone.box }.reduce(into: Set<String>()) { $0.formUnion($1.seen) }
        LiveTerminal.forget(box: gone.box, keeping: still, among: Array(gone.seen))
    }

    #if DEBUG
    /// `-sessionNewTerminal 1` opened its terminal already (once per launch).
    static var debugOpened = false
    /// `-sessionSplit 1` / `-sessionBrowser 1` did their part already (once per launch).
    static var debugSplit = false
    static var debugBrowser = false
    #endif

    private var conn: BoxConnection? { model?.connection(for: box) }

    /// Terminals can open beside this session: it works in a worktree.
    var available: Bool { ref != nil }

    /// The worktree's terminals on the box, oldest first.
    var all: [Session] {
        guard let ref, let conn else { return [] }
        let paths = conn.locations.flatMap { ($0.worktrees ?? []).map(\.path) }
        let name = ref.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ref
        let path = conn.location(named: name).flatMap { l in l.worktrees?.first { l.ref($0) == ref }?.path } ?? dir
        return WorktreeTerminals.sessions(conn.sessions, ref: ref, path: path, paths: paths)
    }

    /// The tab on screen, among the worktree's terminals `list` and its browser; nil: Conversa.
    func current(in list: [Session]) -> SideTab? { selected.flatMap { has($0, in: list) ? $0 : nil } }

    /// What the right pane shows side by side: the tab picked, else the one picked last, else the first terminal, else
    /// the browser; nil while the worktree has none of them open.
    func side(in list: [Session]) -> SideTab? {
        if let t = current(in: list) { return t }
        if let t = lastSide, has(t, in: list) { return t }
        if let s = list.first { return .terminal(s.name) }
        return browserOpen ? .browser : nil
    }

    private func has(_ tab: SideTab, in list: [Session]) -> Bool {
        switch tab {
        case .terminal(let name): list.contains { $0.name == name }
        case .browser: browserOpen
        }
    }

    /// Picks a tab (nil: Conversa).
    func pick(_ tab: SideTab?) {
        selected = tab
        if let tab { lastSide = tab }
    }

    /// Beside the conversation, or over it in tabs (the strip's button, the ⋯ menu, ⌥⌘T). Back in tabs the conversation
    /// shows, the session's first view; the right pane's tab is kept for the next time. `persist: false` for a Debug
    /// launch's, which is not the person's choice.
    func setSideBySide(_ on: Bool, persist: Bool = true) {
        guard available, on != sideBySide else { return }
        sideBySide = on
        if !on { selected = nil }
        if persist { SessionViewPrefs.setSideBySide(on, box: box, name: session) }
    }

    // MARK: browser

    /// The worktree by project and name, as Detalhes names it (the main checkout's name from the box's list).
    private var place: (location: String, worktree: String)? {
        guard let ref else { return nil }
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        let main = conn?.location(named: parts[0])?.worktrees?.first { $0.main == true }?.name
        return (parts[0], main ?? parts[0])
    }

    /// The worktree's browser (PreviewBrowser.swift), once opened from one of its sessions or from Detalhes.
    var browser: PreviewBrowserModel? {
        place.flatMap { PreviewBrowsers.shared.existing(box: box, location: $0.location, worktree: $0.worktree) }
    }

    /// The browser's tab shows beside the worktree's sessions.
    var browserOpen: Bool { browser?.tabOpen == true }

    /// The worktree's page in a tab, picked (the strip's globe, the ⋯ menu, an empty side).
    func openBrowser() {
        guard let place else { return }
        PreviewBrowsers.shared.model(box: box, location: place.location, worktree: place.worktree).tabOpen = true
        pick(.browser)
    }

    /// Its tab closes and its web view goes; the page shown last stays, for when it opens again.
    func closeBrowser() {
        guard let b = browser else { return }
        b.tabOpen = false
        b.releaseWebView()
        if selected == .browser { pick(nil) }
    }

    /// The box streams its terminals (capability `tty`): each is a live terminal (LiveTerminal.swift); else its screen
    /// is read every second and lines are sent (TerminalFeed).
    var live: Bool { LiveTerminal.supported(box: box, model: model) }

    /// A terminal's live terminal, made the first time it shows.
    func liveTerminal(for s: Session) -> LiveTerminal { LiveTerminal.of(box: box, name: s.name, model: model) }

    /// `name` was picked: it joins the terminals kept mounted, the oldest of them leaving past `kept`.
    func show(_ name: String) {
        seen.insert(name)
        shown.removeAll { $0 == name }
        shown.append(name)
        if shown.count > Self.kept { shown.removeFirst(shown.count - Self.kept) }
    }

    /// A terminal's feed, made the first time it shows and kept for the run.
    func feed(for s: Session) -> TerminalFeed? {
        if let f = feeds[s.name] { return f }
        guard let model, let client = model.client(for: box) else { return nil }
        let vm = SessionViewModel(box: box, session: s, client: client, model: model)
        vm.mode = .terminal
        let f = TerminalFeed(vm: vm)
        feeds[s.name] = f
        return f
    }

    /// What a terminal runs now, read from the last screen its feed has; nil before it first showed.
    func running(_ s: Session) -> String? {
        guard !s.exited else { return nil }
        if let t = LiveTerminal.existing(box: box, name: s.name) { return t.running }
        guard let vm = feeds[s.name]?.vm, vm.screenLoaded else { return nil }
        let screen = vm.screen
        if let c = runningCache[s.name], c.screen == screen { return c.command }
        let command = WorktreeTerminals.runningCommand(in: screen)
        runningCache[s.name] = (screen, command)
        return command
    }

    /// What the tab of `s`, the `position`-th of the worktree's terminals, says.
    func label(_ s: Session, position: Int) -> WorktreeTerminals.Label {
        WorktreeTerminals.label(s, position: position, running: running(s))
    }

    /// The feeds of terminals the box no longer has go.
    func prune(keeping names: [String]) {
        let live = Set(names)
        for name in feeds.keys where !live.contains(name) {
            feeds[name] = nil
            runningCache[name] = nil
        }
        LiveTerminal.forget(box: box, keeping: live, among: Array(seen))
        seen.formIntersection(live)
        shown.removeAll { !live.contains($0) }
    }

    /// A new shell in the worktree, on screen with its command line ready (the toolbar, the ⋯ menu, ⌃⇧`, the tabs' +).
    func open() async {
        guard !opening, let ref, let conn else { return }
        opening = true
        defer { opening = false }
        do {
            let s = try await TerminalOpener.open(on: conn, ref: ref, terminals: all)
            pick(.terminal(s.name))
            focusTarget = s.name
        } catch {
            banner = BannerMessage(text: String(localized: "Não foi possível abrir um terminal: \(WorkspaceError.message(error))"), kind: .error)
        }
    }

    /// Ends a terminal on the box (whatever runs in it stops); the one beside it shows, or the browser or Conversa after
    /// the last.
    func close(_ s: Session) async {
        guard let conn else { return }
        let list = all
        do {
            try await conn.client.kill(session: s.name)
        } catch let e as BoxError where e.kind == .notFound {
            // Ended elsewhere meanwhile: the list below no longer has it.
        } catch {
            banner = BannerMessage(text: WorkspaceError.message(error), kind: .error)
            return
        }
        await conn.refreshSessions()
        if selected == .terminal(s.name), let i = list.firstIndex(where: { $0.name == s.name }) {
            let rest = list.filter { $0.name != s.name }
            pick(rest.isEmpty ? (browserOpen ? .browser : nil) : .terminal(rest[min(i, rest.count - 1)].name))
        }
        prune(keeping: all.map(\.name))
    }

    /// Names a terminal on the box (`PATCH`). An empty name gives it a number back, so the box does not name it after the
    /// next line typed.
    func rename(_ s: Session, to name: String) async {
        guard let conn else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !typed.isEmpty ? typed : WorktreeTerminals.defaultTitle(
            WorktreeTerminals.number(inTitle: s.title) ?? WorktreeTerminals.nextNumber(all.filter { $0.name != s.name }))
        do {
            _ = try await conn.client.rename(session: s.name, title: title)
            await conn.refreshSessions()
        } catch {
            banner = BannerMessage(text: WorkspaceError.message(error), kind: .error)
        }
    }
}

/// One terminal tab: its lines in a `SessionViewModel` (terminal mode: `TerminalPane` and `KeysBar` draw from it) and a
/// loop of its own while the tab shows, which reads only the screen with 300 lines of history: every second, at once
/// after a line or a key. Not the conversation's loop: a shell has no transcript, held prompts or review to read.
@MainActor final class TerminalFeed {
    let vm: SessionViewModel
    private var kicked = false

    init(vm: SessionViewModel) { self.vm = vm }

    /// Until cancelled (the tab hidden); an ended terminal is read once.
    func run() async {
        while !Task.isCancelled {
            await read()
            if vm.session.exited { return }
            var waited = 0
            while waited < 10, !kicked, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            kicked = false
        }
    }

    private func read() async {
        let client = vm.client, name = vm.name
        do {
            let screen = try await SessionViewModel.bounded(.seconds(6)) { try await client.screen(session: name, history: 300) }
            if screen != vm.screen { vm.screen = screen }
            if !vm.screenLoaded { vm.screenLoaded = true }
        } catch {
            // The next turn reads again; a terminal the box no longer has leaves the tabs with the box's list.
        }
    }

    /// A line typed at the prompt, with Enter (an empty one is Enter alone, as in a terminal); false when it did not go.
    func send(_ line: String) async -> Bool {
        let client = vm.client, name = vm.name
        do {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                try await client.keys(session: name, [.enter])
            } else {
                // One key per line: a retry after a lost answer gets the first back instead of typing it twice.
                let request = SendRequest(text: line, enter: true, when: .now, idemKey: "ios-\(UUID().uuidString)")
                _ = try await SessionViewModel.bounded(.seconds(15)) { try await client.send(session: name, request) }
            }
            kickSoon()
            return true
        } catch {
            vm.actionError = WorkspaceError.message(error)
            return false
        }
    }

    func press(_ keys: [ControlKey]) async {
        await vm.press(keys)
        kickSoon()
    }

    /// The output follows a line or a key a moment later: read at once, and twice more soon after. The box's list is read
    /// again too: a line can end the shell (`exit`), and the tab then says so.
    func kickSoon() {
        kicked = true
        vm.conn?.scheduleRefresh(sessions: true)
        Task {
            for ms in [300, 700] {
                try? await Task.sleep(for: .milliseconds(ms))
                kicked = true
            }
        }
    }

}

/// Opens a shell in a worktree for the person: `POST /v1/sessions` with its ref and neither agent nor command (docs/API.md
/// 3.4), titled "Terminal N" so the box does not name it after the first line typed. The box names a shell
/// `<ref>-shell-<time in seconds>`, taken already for a second one opened within the same second: that one is asked for
/// again under a name of its own.
enum TerminalOpener {
    @MainActor static func open(on conn: BoxConnection, ref: String, terminals: [Session]) async throws -> Session {
        var req = SessionRequest(location: ref, title: WorktreeTerminals.defaultTitle(WorktreeTerminals.nextNumber(terminals)))
        let s: Session
        do {
            s = try await conn.client.startSession(req)
        } catch let e as BoxError where e.kind == .sessionExists {
            req.name = WorktreeTerminals.sessionName(location: ref, suffix: String(UInt32.random(in: .min ... .max), radix: 36))
            s = try await conn.client.startSession(req)
        }
        await conn.refreshSessions()
        return s
    }
}

extension WorktreeTerminals.Label {
    /// The words of a terminal's tab, in the person's language.
    var text: String {
        switch self {
        case .named(let t): t
        case .command(let c): c
        case .numbered(let n): String(localized: "Terminal \(n)")
        }
    }
}

// MARK: - the tabs

/// The session screen's tabs around `conversation` (the chat as it always was, its composer and needs-you card
/// included): Conversa, the worktree's terminals and its browser, + for another terminal. The strip shows only while
/// the worktree has a terminal or its browser open. A terminal tab fills the screen with its lines, a command line
/// (Return types it with Enter) and the keys bar; the conversation stays underneath, as it was, for when Conversa is
/// picked again. Side by side (iPad, Mac) the conversation keeps the left and the tabs, Conversa left out, take the right.
struct SessionTerminalTabs<Conversation: View>: View {
    let vm: SessionViewModel
    let conversation: Conversation
    @State private var terminals: SessionTerminals
    @State private var closing: Session?
    @State private var renaming: Session?
    @State private var renameText = ""
    /// The screen has room for both panes (only that, not its width: a window being resized draws this again only when
    /// it crosses the line).
    @State private var roomy = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(vm: SessionViewModel, @ViewBuilder conversation: () -> Conversation) {
        self.vm = vm
        self.conversation = conversation()
        _terminals = State(initialValue: SessionTerminals.of(vm))
    }

    /// Side by side can show: the iPad's or the Mac's width (the iPhone keeps its tabs), and room for both panes.
    private var fits: Bool { sideBySideAllowed && roomy }
    /// iPad and Mac: an iPhone keeps its tabs, landscape included.
    private var sideBySideAllowed: Bool { sizeClass == .regular && !Platform.isPhone }

    var body: some View {
        let list = terminals.all
        let split = terminals.sideBySide && fits
        dialogs(content(list, split: split), list: list)
            .onGeometryChange(for: Bool.self) { SessionTerminals.fits(width: $0.size.width) } action: { roomy = $0 }
            .banner(Binding(get: { terminals.banner }, set: { terminals.banner = $0 }))
            .onChange(of: list.map(\.name)) { _, names in terminals.prune(keeping: names) }
            .onChange(of: terminals.sideBySide) { _, on in if on { explainNarrow() } }
            .focusedSceneValue(\.newTerminal, terminals.available ? NewTerminalAction(terminals: terminals) : nil)
            .focusedSceneValue(\.sessionSide, terminals.available && sideBySideAllowed
                               ? SessionSideAction(terminals: terminals, on: terminals.sideBySide) : nil)
            #if DEBUG
            .task {
                // `-sessionSplit 1`: the first session shown in a worktree opens side by side, `-sessionBrowser 1` with
                // its browser open; `-sessionNewTerminal 1`: a terminal opens beside it (screenshots, tests).
                let d = UserDefaults.standard
                guard terminals.available, ["sessionSplit", "sessionBrowser", "sessionNewTerminal"].contains(where: d.bool(forKey:)) else { return }
                try? await Task.sleep(for: .seconds(1.5))
                // Once the window has its size (`-macWindowSize`), as a click would come: too narrow, it says why.
                if d.bool(forKey: "sessionBrowser"), !SessionTerminals.debugBrowser {
                    SessionTerminals.debugBrowser = true
                    terminals.openBrowser()
                }
                if d.bool(forKey: "sessionSplit"), !SessionTerminals.debugSplit {
                    SessionTerminals.debugSplit = true
                    terminals.setSideBySide(true, persist: false)
                }
                guard d.bool(forKey: "sessionNewTerminal"), !SessionTerminals.debugOpened else { return }
                SessionTerminals.debugOpened = true
                let browsing = terminals.selected == .browser
                await terminals.open()
                // With the browser asked for too, it stays the tab on screen beside the new terminal's.
                if browsing { terminals.pick(.browser) }
                // `-sessionTerminalType <line>`: typed into the new terminal with Enter once its stream is up.
                if let line = d.string(forKey: "sessionTerminalType"), let s = terminals.all.last {
                    try? await Task.sleep(for: .seconds(2))
                    terminals.liveTerminal(for: s).typeForDebug(line + "\r")
                }
            }
            #endif
    }

    /// Turned on in a window too narrow for both panes: the tabs stay, and the person is told why. A moment later,
    /// once the window has laid out again (the details column folds away for it on the Mac).
    private func explainNarrow() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard terminals.sideBySide, !fits, sideBySideAllowed else { return }
            terminals.banner = BannerMessage(text: S("Lado a lado precisa de uma janela mais larga: as abas ficam lado a lado sozinhas quando houver espaço."))
        }
    }

    /// The strip (once there is a terminal or the browser), and Conversa or the tab picked, or side by side the two.
    /// Live terminals shown once stay mounted under the one on screen, still streaming, so going back to one is instant.
    /// The conversation and the tabs are the same two panes either way (`SplitPane` lays one over the other in tabs), so
    /// turning side by side on or off moves them: no terminal starts its stream again, the conversation keeps its place.
    /// What the panes show is made here, in this view's body, and `SplitPane`'s closures only place it: a value read in
    /// there would draw only them again. A tab says what runs in its terminal once the terminal's live view (or feed) is
    /// made, so those come before the strip, and the terminals kept mounted are read here (`shown` grows right after one
    /// first shows), so the strip is drawn again with the new one and follows what runs in it from then on.
    private func content(_ list: [Session], split: Bool) -> some View {
        let current = terminals.current(in: list)
        let side = split ? terminals.side(in: list) : current
        let sideTerminal: String? = if case .terminal(let name)? = side { name } else { nil }
        let live = terminals.live
        let hidden = !split && side != nil
        let focused = terminals.focusTarget
        let mounted = live ? list.filter { terminals.shown.contains($0.name) || $0.name == sideTerminal }
            .map { MountedTerminal(session: $0, terminal: terminals.liveTerminal(for: $0)) } : []
        let fed = live ? nil : sideTerminal.flatMap { name in list.first { $0.name == name } }
            .flatMap { s in terminals.feed(for: s).map { (session: s, feed: $0) } }
        let browser = side == .browser ? terminals.browser : nil
        let opening = terminals.opening
        let tabs = strip(list, current: split ? side : current, conversation: !split)
        let showsTabs = !list.isEmpty || terminals.browserOpen
        return VStack(spacing: 0) {
            if !split && showsTabs { tabs }
            SplitPane(key: "session.side", initialFraction: 0.5,
                      minLeading: SessionTerminals.minConversation, minTrailing: SessionTerminals.minSide, split: split) {
                VStack(spacing: 0) { conversation }
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(!hidden)
                    .disabled(hidden)
                    .accessibilityHidden(hidden)
            } trailing: {
                VStack(spacing: 0) {
                    if split { tabs }
                    ZStack {
                        ForEach(mounted) { m in
                            let visible = m.session.name == sideTerminal
                            liveSurface(m, visible: visible, focus: visible && focused == m.session.name)
                        }
                        if let fed { surface(fed.session, feed: fed.feed, focus: focused == fed.session.name) }
                        if let browser { PreviewBrowser(browser: browser).zIndex(2) }
                        if split && side == nil {
                            SideEmpty(opening: opening, openTerminal: openTerminal, openBrowser: { terminals.openBrowser() })
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .onChange(of: sideTerminal, initial: true) { _, name in
            if let name, live { terminals.show(name) }
        }
    }

    private func liveSurface(_ m: MountedTerminal, visible: Bool, focus: Bool) -> some View {
        let s = m.session
        return VStack(spacing: 0) {
            TerminalHeader(dir: s.dir, running: s.exited ? nil : terminals.running(s), exited: s.exited)
            LiveTerminalSurface(terminal: m.terminal, exited: s.exited, visible: visible, focus: focus,
                                onFocused: { if terminals.focusTarget == s.name { terminals.focusTarget = nil } },
                                onClose: { ask(close: s) })
        }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }

    private func surface(_ s: Session, feed: TerminalFeed, focus: Bool) -> some View {
        TerminalSurface(feed: feed, focus: focus,
                        onFocused: { if terminals.focusTarget == s.name { terminals.focusTarget = nil } },
                        onError: { terminals.banner = BannerMessage(text: $0, kind: .error) },
                        onClose: { ask(close: s) })
            .id(s.name)
    }

    /// Closing one that runs is asked first; renaming takes a name.
    private func dialogs<V: View>(_ v: V, list: [Session]) -> some View {
        let closingName = closing.map { name(of: $0, in: list) } ?? ""
        // What runs is named when the tab does not already say it.
        let running = closing.flatMap { s in terminals.running(s) ?? s.command.flatMap { $0.isEmpty ? nil : $0 } }
        let named = running.flatMap { $0 == closingName ? nil : $0 }
        return v
            .alert(Text("Fechar “\(closingName)”?"), isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                Button("Fechar terminal", role: .destructive) {
                    guard let s = closing else { return }
                    Task { await terminals.close(s) }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancelar", role: .cancel) {}
            } message: {
                if let named {
                    Text("Ele está rodando “\(named)”, que para junto. A sessão termina na box.")
                } else {
                    Text("A sessão termina na box, e o que estiver rodando nela para.")
                }
            }
            .alert("Renomear terminal", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nome", text: $renameText)
                Button("Cancelar", role: .cancel) {}
                Button("Salvar") {
                    guard let s = renaming else { return }
                    let typed = renameText
                    Task { await terminals.rename(s, to: typed) }
                }
                .keyboardShortcut(.defaultAction)
            } message: { Text("Sem nome, ele volta a ter um número.") }
    }

    private func name(of s: Session, in list: [Session]) -> String {
        terminals.label(s, position: (list.firstIndex { $0.name == s.name } ?? 0) + 1).text
    }

    /// The tabs' +.
    private func openTerminal() { Task { await terminals.open() } }

    /// A terminal whose program ended goes at once; one that runs asks first.
    private func ask(close s: Session) {
        if s.exited { Task { await terminals.close(s) } } else { closing = s }
    }

    /// The tabs: Conversa (not side by side, where it shows anyway), the terminals, the browser once open; + for a
    /// terminal, the globe for the browser while it is closed, and at the end, on the iPad and the Mac, side by side.
    private func strip(_ list: [Session], current: SessionTerminals.SideTab?, conversation: Bool) -> some View {
        // Read here, in the body, not in the rows' closures: a tab is named after what runs in its terminal.
        let rows = list.enumerated().map { i, s in
            (session: s, title: terminals.label(s, position: i + 1).text,
             running: !s.exited && (terminals.running(s) != nil || !(s.command ?? "").isEmpty))
        }
        let needsYou = current != nil && vm.session.needsYou
        let browserOpen = terminals.browserOpen
        let page = terminals.browser?.url
        let pageTitle = terminals.browser?.title
        let opening = terminals.opening
        return HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    if conversation {
                        ConversationTab(active: current == nil, needsYou: needsYou) {
                            terminals.pick(nil)
                        }
                    }
                    ForEach(rows, id: \.session.name) { row in
                        let s = row.session
                        TerminalTab(title: row.title, running: row.running,
                                    exited: s.exited, active: current == .terminal(s.name), session: s.name,
                                    select: {
                                        terminals.pick(.terminal(s.name))
                                        if Platform.isMac { terminals.focusTarget = s.name }
                                    },
                                    close: { ask(close: s) })
                            .contextMenu {
                                Button {
                                    renameText = WorktreeTerminals.number(inTitle: s.title) == nil ? (s.title ?? "") : ""
                                    renaming = s
                                } label: { Label("Renomear…", systemImage: "pencil") }
                                Button { UIPasteboard.general.string = s.name } label: { Label("Copiar nome da sessão", systemImage: "doc.on.doc") }
                                Divider()
                                Button(role: .destructive) { ask(close: s) } label: { Label("Fechar terminal", systemImage: "xmark") }
                            }
                    }
                    if browserOpen {
                        BrowserTab(active: current == .browser, page: page, title: pageTitle,
                                   select: { terminals.pick(.browser) }, close: { terminals.closeBrowser() })
                    }
                    stripButton(help: "Novo terminal (⌃⇧`)", label: "Novo terminal", id: "terminal-new", action: openTerminal) {
                        if opening { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "plus").font(.system(size: Density.small + 1, weight: .semibold)) }
                    }
                    .disabled(opening)
                    if !browserOpen {
                        stripButton(help: "Navegador: a página da worktree", label: "Navegador", id: "browser-open",
                                    action: { terminals.openBrowser() }) {
                            Image(systemName: "globe").font(.system(size: Density.small + 1))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 6, for: .scrollContent)
            if sideBySideAllowed { sideBySideButton }
        }
        .padding(.vertical, 4)
        .frame(height: Platform.isMac ? 36 : 42)
        // A quiet strip on the window's own color, a hairline under it; the tab picked is a raised pill.
        .background { ZStack(alignment: .bottom) { Theme.bg; Rectangle().fill(Theme.stroke).frame(height: 1) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-tabs")
    }

    private func stripButton<Glyph: View>(help: LocalizedStringKey, label: LocalizedStringKey, id: String, action: @escaping () -> Void,
                                          @ViewBuilder content: () -> Glyph) -> some View {
        Button(action: action) {
            ZStack { content() }
                .foregroundStyle(Theme.textDim)
                .frame(width: Platform.isMac ? 30 : 40)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Side by side or in tabs (also the ⋯ menu and ⌥⌘T), pinned at the strip's end.
    private var sideBySideButton: some View {
        let on = terminals.sideBySide
        return Button { terminals.setSideBySide(!on) } label: {
            Image(systemName: on ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                .font(.system(size: Density.small + 1))
                .foregroundStyle(on ? Theme.accent : Theme.textDim)
                .frame(width: Platform.isMac ? 34 : 44)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Mostrar em abas (⌥⌘T)" : "Lado a lado (⌥⌘T)")
        .accessibilityLabel("Lado a lado")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("session-side-by-side")
    }
}

/// A tab of the session's strip: the one picked a raised pill on the card's color, the others plain, washed under the
/// pointer (as Safari's and Xcode's tabs of today, no rule or divider around them).
private struct SessionTabChrome: ViewModifier {
    let active: Bool
    var hovering = false
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.card : (hovering || over) ? Theme.wash : .clear)
                    .shadow(color: active ? Theme.cardShadow : .clear, radius: 2, y: 1)
                    .overlay {
                        if active { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke) }
                    }
            }
            .onHover { over = $0 }
    }
}

/// Over a terminal, as a terminal app's title bar: where it runs ("~/code/shop-checkout") and what runs in it now,
/// on the terminal's own color.
private struct TerminalHeader: View {
    let dir: String
    let running: String?
    let exited: Bool

    /// The folder with the home folder as "~".
    private var place: String {
        let parts = dir.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "home" || parts[0] == "Users" { return "~/" + parts.dropFirst(2).joined(separator: "/") }
        if parts.first == "root" { return "~/" + parts.dropFirst().joined(separator: "/") }
        return dir
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textFaint)
            Text(verbatim: place).font(.mono(11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if let running, !running.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(Theme.green).frame(width: 6, height: 6)
                    Text(verbatim: running).font(.mono(11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: 320, alignment: .trailing)
            } else if exited {
                Text("o programa terminou").font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.terminalBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal-header")
    }
}

/// A terminal kept mounted beside or under the conversation, with its live terminal, made in the tabs' body.
private struct MountedTerminal: Identifiable {
    let session: Session
    let terminal: LiveTerminal
    var id: String { session.name }
}

/// Side by side with nothing open beside the conversation: a terminal or the browser, a click away.
private struct SideEmpty: View {
    let opening: Bool
    let openTerminal: () -> Void
    let openBrowser: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.textFaint)
            Text("Abra um terminal ou o navegador ao lado da conversa.")
                .font(.callout).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button(action: openTerminal) { Label("Novo terminal", systemImage: "apple.terminal.on.rectangle") }
                    .disabled(opening)
                Button(action: openBrowser) { Label("Navegador", systemImage: "globe") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-side-empty")
    }
}

/// The conversation's tab: the chat as it always was; a dot while the agent waits for the person and a terminal shows.
private struct ConversationTab: View {
    let active: Bool
    let needsYou: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: Density.small))
                    .foregroundStyle(active ? Theme.accent : Theme.textDim)
                Text("Conversa").font(.system(size: Density.small + 0.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textDim).lineLimit(1)
                if needsYou { Circle().fill(Theme.orange).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SessionTabChrome(active: active))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("session-tab-conversation")
    }
}

/// One terminal's tab: its name or what runs in it (the glyph green while something does), × on the one picked and
/// under the pointer.
private struct TerminalTab: View {
    let title: String
    let running: Bool
    let exited: Bool
    let active: Bool
    let session: String
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    /// A long command is cut in the tab (the whole one shows on hover).
    private var shown: String { title.count > 34 ? String(title.prefix(32)) + "…" : title }

    var body: some View {
        HStack(spacing: 0) {
            // A button of its own (not a tap on the tab), so VoiceOver and the keyboard can pick it too.
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: Density.small))
                        .foregroundStyle(exited ? Theme.textFaint : running ? Theme.green : Theme.textDim)
                    Text(verbatim: shown).font(.system(size: Density.small + 0.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(exited ? Theme.textFaint : active ? Theme.text : Theme.textDim).lineLimit(1)
                }
                .padding(.leading, 9).padding(.trailing, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(active ? .isSelected : [])
            // The × of a tab not picked is hidden on the Mac (and so out of VoiceOver's reach): closing is an action here.
            .accessibilityAction(named: Text("Fechar terminal"), close)
            .accessibilityIdentifier("terminal-tab-\(session)")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: Density.small - 2, weight: .bold)).foregroundStyle(Theme.textDim)
                    .frame(width: 16, height: 16)
                    .background(hovering ? Theme.washStrong : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .opacity(active || hovering || !Platform.isMac ? 1 : 0)
            .padding(.trailing, 6)
            .accessibilityLabel("Fechar \(title)")
            .accessibilityIdentifier("terminal-close-\(session)")
        }
        .frame(maxHeight: .infinity)
        .modifier(SessionTabChrome(active: active, hovering: hovering))
        .onHover { hovering = $0 }
        .help(exited ? "\(title) · \(String(localized: "o programa terminou"))" : "\(title) · \(session)")
    }
}

/// The browser's tab: the worktree's page (its address on hover), × on the one picked and under the pointer, as a
/// terminal's.
private struct BrowserTab: View {
    let active: Bool
    let page: URL?
    /// The page's own title, which names the tab once it loaded (as a browser's tab does).
    var title: String? = nil
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: Density.small))
                        .foregroundStyle(active ? Theme.accent : Theme.textDim)
                    Group {
                        if let title, !title.isEmpty { Text(verbatim: title) } else { Text("Navegador") }
                    }
                    .font(.system(size: Density.small + 0.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textDim).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 9).padding(.trailing, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityAction(named: Text("Fechar navegador"), close)
            .accessibilityIdentifier("browser-tab")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: Density.small - 2, weight: .bold)).foregroundStyle(Theme.textDim)
                    .frame(width: 16, height: 16)
                    .background(hovering ? Theme.washStrong : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .opacity(active || hovering || !Platform.isMac ? 1 : 0)
            .padding(.trailing, 6)
            .accessibilityLabel("Fechar navegador")
            .accessibilityIdentifier("browser-close")
        }
        .frame(maxHeight: .infinity)
        .modifier(SessionTabChrome(active: active, hovering: hovering))
        .onHover { hovering = $0 }
        .help(page.map { Text(verbatim: $0.absoluteString) } ?? Text("Navegador"))
    }
}

// MARK: - one terminal

/// One live terminal (LiveTerminal.swift) and, once its program ended, the bar that closes its tab.
private struct LiveTerminalSurface: View {
    let terminal: LiveTerminal
    let exited: Bool
    let visible: Bool
    let focus: Bool
    let onFocused: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LiveTerminalView(terminal: terminal, visible: visible, focus: focus, onFocused: onFocused, showsKeys: !Platform.isMac && !exited)
            if exited { TerminalClosedBar(onClose: onClose) }
        }
    }
}

/// The program ended: closing the tab takes the session off the box.
private struct TerminalClosedBar: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "poweroff").foregroundStyle(Theme.gray)
            Text("O programa terminou. Fechar a aba tira a sessão da box.")
                .font(.system(size: Density.small + 1)).foregroundStyle(Theme.textDim)
            Spacer(minLength: 8)
            Button("Fechar", action: onClose).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: Platform.isMac ? 34 : 44)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

/// One terminal: its lines (`TerminalPane`, as the session screen draws an agent's), the command line and the keys bar.
/// Its feed reads the box only while it shows.
private struct TerminalSurface: View {
    let feed: TerminalFeed
    let focus: Bool
    let onFocused: () -> Void
    let onError: (String) -> Void
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var line = ""
    @State private var sending = false

    private var vm: SessionViewModel { feed.vm }
    private struct Run: Equatable { let visible: Bool; let exited: Bool }

    var body: some View {
        VStack(spacing: 0) {
            TerminalPane(vm: vm)
            if vm.session.exited {
                TerminalClosedBar(onClose: onClose)
            } else {
                commandLine
                // Its keys go through the view model; the feed reads the screen again right after any of them.
                KeysBar(vm: vm).simultaneousGesture(TapGesture().onEnded { feed.kickSoon() })
            }
        }
        // Not only while active: on the Mac, a window beside the browser showing the app keeps its logs coming.
        .task(id: Run(visible: scenePhase != .background, exited: vm.session.exited)) {
            guard scenePhase != .background else { return }
            await feed.run()
        }
        .onChange(of: vm.actionError) { _, error in
            guard let error else { return }
            vm.actionError = nil
            onError(error)
        }
    }

    private var commandLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: Density.small, weight: .bold)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            TerminalCommandField(text: $line, placeholder: S("Comando"), focus: focus, onFocused: onFocused, onSubmit: submit) { key in
                Task { await feed.press([key]) }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("terminal-field")
            if sending { ProgressView().controlSize(.small) }
            Button(action: submit) {
                Image(systemName: "return").font(.system(size: Density.small + 1, weight: .semibold)).foregroundStyle(Theme.textDim)
                    .frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Enviar (↩)")
            .accessibilityLabel("Enviar comando")
            .accessibilityIdentifier("terminal-send")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: Platform.isMac ? 34 : 44)
        .background { ZStack { Theme.card; Theme.terminalBg } }
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    /// Return: the line goes to the shell with Enter; one that did not go comes back to the field.
    private func submit() {
        let text = line
        line = ""
        sending = true
        Task {
            if !(await feed.send(text)), line.isEmpty { line = text }
            sending = false
        }
    }
}

/// The command line's field: one line, monospaced, and what is typed reaches the shell as typed (no autocorrection,
/// capitals, smart quotes or dashes: a `"` must stay a `"`, which a SwiftUI field on the Mac does not promise). Return runs
/// `onSubmit` and keeps the keyboard. With a hardware keyboard ⌃C goes to the shell, and so do ↑, ↓ and Esc on an empty
/// line (the shell's own history).
private struct TerminalCommandField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Take the keyboard when this shows (a terminal just opened); `onFocused` then.
    let focus: Bool
    let onFocused: () -> Void
    let onSubmit: () -> Void
    let onKey: (ControlKey) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CommandTextField {
        let f = CommandTextField()
        let font = UIFont.monospacedSystemFont(ofSize: Platform.isMac ? 12.5 : 15, weight: .regular)
        f.font = font
        f.textColor = UIColor(Theme.terminalText)
        f.tintColor = UIColor(Theme.accent)
        f.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(Theme.textFaint), .font: font])
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.smartInsertDeleteType = .no
        f.returnKeyType = .send
        f.enablesReturnKeyAutomatically = false
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let coordinator = context.coordinator
        f.onKey = { key in coordinator.parent.onKey(key) }
        return f
    }

    func updateUIView(_ f: CommandTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if f.text != text { f.text = text }
        if focus, !coordinator.focusing {
            coordinator.focusing = true
            // After this update: the field may not be in a window yet.
            Task { @MainActor in
                if f.window == nil { try? await Task.sleep(for: .milliseconds(150)) }
                _ = f.becomeFirstResponder()
                coordinator.focusing = false
                coordinator.parent.onFocused()
            }
        }
    }

    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalCommandField
        var focusing = false

        init(_ parent: TerminalCommandField) { self.parent = parent }

        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

/// The field's text field: hands ⌃C to the shell (a key command), and ↑, ↓ and Esc while nothing is typed; every other
/// key types.
final class CommandTextField: UITextField {
    var onKey: ((ControlKey) -> Void)?

    /// ⌃C as a key command, ahead of the system: a text field's input system takes Ctrl+letter for its own (emacs-style)
    /// bindings before `pressesBegan` sees the letter, on the Mac above all, and ⌃C never reached the shell.
    private static let interrupt: UIKeyCommand = {
        let c = UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(interruptCommand))
        c.wantsPriorityOverSystemBehavior = true
        return c
    }()

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + [Self.interrupt] }

    @objc private func interruptCommand() { onKey?(.interrupt) }

    /// Presses taken here, kept from the text field's own handling to their end.
    private var taken: Set<UIPress> = []

    private func control(for key: UIKey) -> ControlKey? {
        let mods = key.modifierFlags.intersection([.control, .command, .alternate, .shift])
        guard mods.isEmpty, (text ?? "").isEmpty else { return nil }
        switch key.keyCode {
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardEscape: return .escape
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses {
            if let key = p.key, let k = control(for: key) {
                taken.insert(p)
                onKey?(k)
            } else {
                rest.insert(p)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(taken)
        taken.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(taken)
        taken.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}

// MARK: - opening the first

/// The toolbar's "Novo terminal" beside a session that works in a worktree (none for a chat): a shell there, in a tab.
struct SessionTerminalButton: View {
    let vm: SessionViewModel

    var body: some View {
        let terminals = SessionTerminals.of(vm)
        if terminals.available {
            Button { Task { await terminals.open() } } label: {
                // A Label, not an image alone: the Mac's toolbar takes its title for the item's name.
                Label("Novo terminal", systemImage: "apple.terminal.on.rectangle")
            }
            .disabled(terminals.opening)
            .help("Novo terminal (⌃⇧`)")
            .accessibilityIdentifier("session-new-terminal")
        }
    }
}

/// The ⋯ menu's "Novo terminal", "Navegador" and, on the iPad and the Mac (`regular`), "Lado a lado".
struct SessionTerminalMenuItem: View {
    let vm: SessionViewModel
    var regular = false

    var body: some View {
        let terminals = SessionTerminals.of(vm)
        if terminals.available {
            Button { Task { await terminals.open() } } label: { Label("Novo terminal", systemImage: "apple.terminal.on.rectangle") }
                .disabled(terminals.opening)
            Button { terminals.openBrowser() } label: { Label("Navegador", systemImage: "globe") }
            if regular {
                Toggle(isOn: Binding(get: { terminals.sideBySide }, set: { terminals.setSideBySide($0) })) {
                    Label("Lado a lado", systemImage: "rectangle.split.2x1")
                }
            }
        }
    }
}

/// The menu bar's ⌃⇧`: a terminal beside the session screen in front. One value per session (equal across redraws), so
/// the conversation updating does not rebuild the menu bar.
struct NewTerminalAction: Equatable {
    let terminals: SessionTerminals

    @MainActor func open() { Task { await terminals.open() } }

    static func == (a: Self, b: Self) -> Bool { a.terminals === b.terminals }
}

private struct NewTerminalKey: FocusedValueKey { typealias Value = NewTerminalAction }

/// The menu bar's "Lado a lado" (⌥⌘T): the session screen in front shows its tabs beside the conversation, or over it.
/// Equal across redraws while it stays the same, so the conversation updating does not rebuild the menu bar.
struct SessionSideAction: Equatable {
    let terminals: SessionTerminals
    let on: Bool

    @MainActor func toggle() { terminals.setSideBySide(!on) }

    static func == (a: Self, b: Self) -> Bool { a.terminals === b.terminals && a.on == b.on }
}

private struct SessionSideKey: FocusedValueKey { typealias Value = SessionSideAction }

extension FocusedValues {
    /// The session screen in front can open a terminal (its session works in a worktree).
    var newTerminal: NewTerminalAction? {
        get { self[NewTerminalKey.self] }
        set { self[NewTerminalKey.self] = newValue }
    }

    /// The session screen in front can show its tabs beside the conversation (a session in a worktree, iPad or Mac).
    var sessionSide: SessionSideAction? {
        get { self[SessionSideKey.self] }
        set { self[SessionSideKey.self] = newValue }
    }
}
