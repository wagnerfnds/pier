import SwiftUI
import UIKit
import PierKit

// The session screen's terminal tabs: beside the conversation, the plain terminals of the session's worktree, each a
// shell of its own on the box (`POST /v1/sessions` with the worktree's ref, no agent), the way an editor keeps its
// terminals next to the code. Nothing shows until the worktree has one: a session without a terminal is just its chat.

// MARK: - model

/// A session's terminal tabs for the app's run: the plain terminals of its worktree (the box's list, whoever opened
/// them), the tab picked (nil: Conversa) and a feed per terminal, so its lines stay while another tab shows (only the one
/// on screen reads the box). Opening, closing and renaming go to the box.
@MainActor @Observable
final class SessionTerminals {
    let box: String
    let session: String
    /// The worktree's ref ("loc/wt", "loc" for the main checkout); nil for a chat or a session in no worktree: no terminals.
    let ref: String?
    /// The session's folder: its worktree's, when the box's locations are not loaded yet.
    private let dir: String
    /// The terminal on screen, by session name; nil, or one that is gone: Conversa.
    var selected: String?
    /// A terminal is being opened: the buttons that open one wait for it.
    private(set) var opening = false
    /// The terminal whose command line takes the keyboard when it shows (one just opened; on the Mac, one picked).
    var focusTarget: String?
    /// Why opening, closing or renaming failed, or a line or key did not go.
    var banner: BannerMessage?
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
    }

    private static var registry: [String: SessionTerminals] = [:]
    private static var recent: [String] = []

    /// The tabs of the session `vm` shows, kept for the sessions opened last while the app runs (older ones are let go:
    /// their terminals stay on the box and come back as tabs when the session is opened again).
    static func of(_ vm: SessionViewModel) -> SessionTerminals {
        let key = "\(vm.box)/\(vm.name)"
        if recent.last != key {
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > 24 { registry[recent.removeFirst()] = nil }
        }
        if let t = registry[key] {
            if t.model == nil { t.model = vm.model }
            return t
        }
        let t = SessionTerminals(vm: vm)
        registry[key] = t
        return t
    }

    #if DEBUG
    /// `-sessionNewTerminal 1` opened its terminal already (once per launch).
    static var debugOpened = false
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

    /// The terminal on screen; nil: Conversa.
    func current(in list: [Session]) -> Session? { list.first { $0.name == selected } }

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
        guard !s.exited, let vm = feeds[s.name]?.vm, vm.screenLoaded else { return nil }
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
    }

    /// A new shell in the worktree, on screen with its command line ready (the toolbar, the ⋯ menu, ⌃⇧`, the tabs' +).
    func open() async {
        guard !opening, let ref, let conn else { return }
        opening = true
        defer { opening = false }
        do {
            let s = try await TerminalOpener.open(on: conn, ref: ref, terminals: all)
            selected = s.name
            focusTarget = s.name
        } catch {
            banner = BannerMessage(text: String(localized: "Não foi possível abrir um terminal: \(WorkspaceError.message(error))"), kind: .error)
        }
    }

    /// Ends a terminal on the box (whatever runs in it stops); the one beside it shows, or Conversa after the last.
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
        if selected == s.name, let i = list.firstIndex(where: { $0.name == s.name }) {
            let rest = list.filter { $0.name != s.name }
            selected = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].name
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
/// included): Conversa and the worktree's terminals, + for another. The strip shows only while the worktree has a
/// terminal. A terminal tab fills the screen with its lines, a command line (Return types it with Enter) and the keys
/// bar; the conversation stays underneath, as it was, for when Conversa is picked again.
struct SessionTerminalTabs<Conversation: View>: View {
    let vm: SessionViewModel
    let conversation: Conversation
    @State private var terminals: SessionTerminals
    @State private var closing: Session?
    @State private var renaming: Session?
    @State private var renameText = ""

    init(vm: SessionViewModel, @ViewBuilder conversation: () -> Conversation) {
        self.vm = vm
        self.conversation = conversation()
        _terminals = State(initialValue: SessionTerminals.of(vm))
    }

    var body: some View {
        let list = terminals.all
        dialogs(content(list), list: list)
            .banner(Binding(get: { terminals.banner }, set: { terminals.banner = $0 }))
            .onChange(of: list.map(\.name)) { _, names in terminals.prune(keeping: names) }
            .focusedSceneValue(\.newTerminal, terminals.available ? NewTerminalAction(terminals: terminals) : nil)
            #if DEBUG
            .task {
                // `-sessionNewTerminal 1`: a terminal opens beside the first session shown in a worktree (screenshots, tests).
                guard UserDefaults.standard.bool(forKey: "sessionNewTerminal"), !SessionTerminals.debugOpened, terminals.available else { return }
                SessionTerminals.debugOpened = true
                try? await Task.sleep(for: .seconds(1.5))
                await terminals.open()
            }
            #endif
    }

    /// The strip (once there is a terminal), and Conversa or the terminal picked.
    private func content(_ list: [Session]) -> some View {
        let current = terminals.current(in: list)
        return VStack(spacing: 0) {
            if !list.isEmpty { strip(list, current: current?.name) }
            ZStack {
                VStack(spacing: 0) { conversation }
                    .opacity(current == nil ? 1 : 0)
                    .allowsHitTesting(current == nil)
                    .disabled(current != nil)
                    .accessibilityHidden(current != nil)
                if let current { surface(current) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func surface(_ s: Session) -> some View {
        if let feed = terminals.feed(for: s) {
            TerminalSurface(feed: feed, focus: terminals.focusTarget == s.name,
                            onFocused: { if terminals.focusTarget == s.name { terminals.focusTarget = nil } },
                            onError: { terminals.banner = BannerMessage(text: $0, kind: .error) },
                            onClose: { ask(close: s) })
                .id(s.name)
        }
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

    private func strip(_ list: [Session], current: String?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ConversationTab(active: current == nil, needsYou: current != nil && vm.session.needsYou) {
                    terminals.selected = nil
                }
                ForEach(Array(list.enumerated()), id: \.element.name) { i, s in
                    TerminalTab(title: terminals.label(s, position: i + 1).text,
                                running: !s.exited && (terminals.running(s) != nil || !(s.command ?? "").isEmpty),
                                exited: s.exited, active: s.name == current, session: s.name,
                                select: {
                                    terminals.selected = s.name
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
                Button(action: openTerminal) {
                    ZStack {
                        if terminals.opening { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "plus").font(.system(size: Density.small + 1, weight: .semibold)) }
                    }
                    .foregroundStyle(Theme.textDim)
                    .frame(width: Platform.isMac ? 30 : 40)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(terminals.opening)
                .help("Novo terminal (⌃⇧`)")
                .accessibilityLabel("Novo terminal")
                .accessibilityIdentifier("terminal-new")
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: Platform.isMac ? 30 : 36)
        // A strip with its line under the tabs: the tab picked, in the color of what it shows, runs into it.
        .background { ZStack(alignment: .bottom) { Theme.card; Rectangle().fill(Theme.stroke).frame(height: 1) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-tabs")
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
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background { if active { Theme.bg } }
            .overlay(alignment: .top) { if active { Rectangle().fill(Theme.accent).frame(height: 2) } }
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .padding(.leading, 10).padding(.trailing, 6)
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
            .padding(.trailing, 10)
            .accessibilityLabel("Fechar \(title)")
            .accessibilityIdentifier("terminal-close-\(session)")
        }
        .frame(maxHeight: .infinity)
        .background { if active { ZStack { Theme.card; Theme.terminalBg } } }
        .overlay(alignment: .top) { if active { Rectangle().fill(Theme.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .onHover { hovering = $0 }
        .help(exited ? "\(title) · \(String(localized: "o programa terminou"))" : "\(title) · \(session)")
    }
}

// MARK: - one terminal

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
                closedBar
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

    private var closedBar: some View {
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

/// The field's text field: hands ⌃C to the shell, and ↑, ↓ and Esc while nothing is typed; every other key types.
final class CommandTextField: UITextField {
    var onKey: ((ControlKey) -> Void)?
    /// Presses taken here, kept from the text field's own handling to their end.
    private var taken: Set<UIPress> = []

    private func control(for key: UIKey) -> ControlKey? {
        let mods = key.modifierFlags.intersection([.control, .command, .alternate, .shift])
        if key.keyCode == .keyboardC, mods == .control { return .interrupt }
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

/// The ⋯ menu's "Novo terminal".
struct SessionTerminalMenuItem: View {
    let vm: SessionViewModel

    var body: some View {
        let terminals = SessionTerminals.of(vm)
        if terminals.available {
            Button { Task { await terminals.open() } } label: { Label("Novo terminal", systemImage: "apple.terminal.on.rectangle") }
                .disabled(terminals.opening)
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

extension FocusedValues {
    /// The session screen in front can open a terminal (its session works in a worktree).
    var newTerminal: NewTerminalAction? {
        get { self[NewTerminalKey.self] }
        set { self[NewTerminalKey.self] = newValue }
    }
}
