import SwiftUI
import PierKit

struct SessionScreen: View {
    let route: SessionRoute
    @State private var vm: SessionViewModel
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmStop = false
    /// The details as a sheet (iPhone)…
    @State private var showDetails = false
    /// …or as the inspector column at the window's right (iPad, Mac), open or closed for every session alike, as an
    /// inspector is in Xcode or Finder.
    @AppStorage("session.inspector") private var inspectorOpen = false
    @State private var toast: String?

    init(route: SessionRoute, client: any PierBoxClient, model: AppModel) {
        self.route = route
        _vm = State(initialValue: SessionViewModel(box: route.box, session: route.session, client: client, model: model))
    }

    private var session: Session { vm.session }
    private var boxSession: BoxSession { BoxSession(box: route.box, session: session) }
    private var title: String {
        if let o = vm.titleOverride, !o.isEmpty { return o }
        return session.displayTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = linkNotice {
                LinkNoticeBar(text: notice.text, symbol: notice.symbol, busy: notice.busy)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Conversa, and the terminals of the session's worktree in tabs beside it (SessionTerminals.swift).
            SessionTerminalTabs(vm: vm) {
                Group {
                    switch vm.mode {
                    case .terminal: TerminalPane(vm: vm)
                    case .conversation:
                        if vm.transcriptUnavailable || (!session.isAgent && vm.loaded) { ConversationFallback(vm: vm) } else { ConversationView(vm: vm) }
                    }
                }
                .frame(maxHeight: .infinity)
                let background = vm.background
                if !background.isEmpty && !vm.showsCard {
                    BackgroundStrip(items: background)
                        .padding(.horizontal, 10).padding(.top, 6)
                        .frame(maxWidth: readableColumn + 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if vm.showsCard {
                    NeedsYouCard(vm: vm)
                        .padding(.horizontal, 10).padding(.top, 6)
                        .frame(maxWidth: readableColumn + 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if vm.mode == .terminal, !vm.isClosed { KeysBar(vm: vm) }
                ComposerBar(vm: vm)
            }
        }
        .animation(.snappy(duration: 0.3), value: vm.showsCard)
        .animation(.snappy(duration: 0.3), value: vm.background.isEmpty)
        .animation(.snappy(duration: 0.25), value: vm.mode)
        .animation(.snappy(duration: 0.25), value: linkNotice?.text)
        .pierBackground()
        .navigationBarTitleDisplayMode(.inline)
        .modifier(MacSessionTitle(title: title))
        .toolbar { toolbar }
        .overlay(alignment: .top) { toastView }
        .onAppear { router.visibleSession = boxSession.id }
        .onDisappear { if router.visibleSession == boxSession.id { router.visibleSession = nil } }
        // Looking at a finished turn here is seeing it: the Inbox badge stops counting it (the card stays until archived).
        .onChange(of: session.agentState == .finished ? session.stateSince : nil, initial: true) { _, since in
            if since != nil { model.prefs.markSeen(box: route.box, session: route.session.name) }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await vm.run()
        }
        #if DEBUG
        .task {
            // Screenshot hooks: `-sessionExpandAll 1` opens every fold/tool row, `-sessionDetails 1` shows the sheet, `-sessionTerminal 1`.
            try? await Task.sleep(for: .seconds(5))
            let d = UserDefaults.standard
            if d.bool(forKey: "sessionExpandAll") {
                for b in ConversationFold.blocks(vm.store.displayItems, live: false) {
                    if case .fold(let id, let steps, _) = b {
                        vm.expanded.insert(id)
                        for st in steps { vm.expanded.insert(st.id); if let c = st.items, c.count == 1, let cid = c[0].id { vm.loadDetail(cid) } }
                    }
                    if case .item(let it) = b, it.type == .edit { vm.expanded.insert(it.id); if let t = it.tool { vm.loadDetail(t) } }
                }
            }
            if d.bool(forKey: "sessionDetails") { openDetails() }
            if d.bool(forKey: "sessionTerminal") { vm.setMode(.terminal) }
            if d.bool(forKey: "sessionConversation") { vm.setMode(.conversation) }
        }
        // `-chatPerfProbe 1 -sessionSend <text>`: the probe sends a message when its streaming phase starts.
        .onReceive(NotificationCenter.default.publisher(for: .pierPerfProbeSend)) { _ in
            if let text = UserDefaults.standard.string(forKey: "sessionSend") { _ = vm.scheduleSend(text) }
        }
        #endif
        .onChange(of: vm.actionError) { _, new in
            guard let new else { return }
            withAnimation { toast = new }
            vm.actionError = nil
            Task { try? await Task.sleep(for: .seconds(4)); withAnimation { if toast == new { toast = nil } } }
        }
        .alert("Renomear sessão", isPresented: $showRename) {
            TextField("Título", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { Task { await vm.rename(renameText) } }
                .keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: $confirmStop) {
            EndSessionSheet(vm: vm, title: title) { note in
                dismiss()
                if let note { model.showToast(note, symbol: "sparkles") }
            }
            .environment(model)
        }
        .sheet(isPresented: $showDetails) {
            SessionDetailsSheet(vm: vm, title: title, reviewTarget: reviewTarget)
                .environment(model).environment(router).environment(model.prefs)
        }
        .inspector(isPresented: sidePanel ? $inspectorOpen : .constant(false)) {
            SessionDetailsList(vm: vm, title: title, reviewTarget: reviewTarget)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                .environment(router).environment(model.prefs)
        }
        .sensoryFeedback(.warning, trigger: vm.isWaiting) { old, new in !old && new }
    }

    // MARK: details

    /// Regular width (iPad, Mac): the details live in the inspector column; the iPhone shows them as a sheet.
    private var sidePanel: Bool { sizeClass == .regular }

    private func openDetails() {
        if sidePanel { withAnimation(.snappy(duration: 0.25)) { inspectorOpen = true } } else { showDetails = true }
    }

    private func toggleDetails() {
        if sidePanel { withAnimation(.snappy(duration: 0.25)) { inspectorOpen.toggle() } } else { showDetails = true }
    }

    // MARK: toolbar

    /// What stands between this screen and the box, said at the top while it lasts (the conversation would otherwise just
    /// stop changing): offline and retrying, a connection being dialed again, or a pairing that no longer holds.
    private var linkNotice: (text: String, symbol: String, busy: Bool)? {
        guard let conn = vm.conn else { return nil }
        switch conn.state {
        case .revoked: return (S("Este aparelho não está mais pareado com a box."), "lock.slash", false)
        case .pinMismatch: return (S("A box apresentou outra chave. Nada é enviado até você parear de novo."), "exclamationmark.shield", false)
        case .offline: return (S("Sem conexão com a box. Tentando de novo…"), "wifi.slash", true)
        case .connecting, .online:
            return vm.linkTrouble ? (S("A box não está respondendo. Reconectando…"), "arrow.triangle.2.circlepath", true) : nil
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The Mac's window shows the title and the state line as its own title and subtitle (`MacSessionTitle`).
        if !Platform.isMac {
        ToolbarItem(placement: .principal) {
            Button { toggleDetails() } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        if vm.titling { Image(systemName: "sparkles").font(.caption).foregroundStyle(Theme.accent).symbolEffect(.pulse) }
                        Text(title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .animation(.snappy, value: title)
                    HStack(spacing: 5) {
                        Circle().fill(stateColor).frame(width: 6, height: 6)
                        Text(stateLine).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                }
                .frame(maxWidth: 240)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(stateLine)")
            .accessibilityHint("Mostra os detalhes da sessão")
        }
        }
        if Platform.isMac {
            // The state line beside the window's title (which is the session's): the agent, the state, the time.
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleDetails() } label: {
                    // Words only: the Mac's toolbar draws an item's symbol alone when it has one, and its own colors.
                    Text(stateLine).font(.callout).lineLimit(1)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(stateLine)
                .accessibilityHint("Mostra os detalhes da sessão")
            }
        }
        ToolbarItem(placement: .topBarTrailing) { SessionTerminalButton(vm: vm) }
        if sidePanel {
            ToolbarItem(placement: .topBarTrailing) {
                Button { toggleDetails() } label: {
                    Label(inspectorOpen ? "Ocultar detalhes" : "Mostrar detalhes", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .accessibilityIdentifier("session-inspector-toggle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { openDetails() } label: { Label("Detalhes", systemImage: "info.circle") }
                Button { renameText = title; showRename = true } label: { Label("Renomear", systemImage: "pencil") }
                if session.isAgent {
                    Button { Task { await vm.generateTitle() } } label: { Label("Gerar título com IA", systemImage: "sparkles") }
                        .disabled(vm.titling)
                }
                if let (loc, wt) = reviewTarget {
                    Button { router.push(ReviewRoute(box: route.box, location: loc, worktree: wt, session: session.name)) }
                    label: { Label("Revisar mudanças", systemImage: "doc.text.magnifyingglass") }
                }
                Divider()
                Button { vm.setMode(vm.mode == .terminal ? .conversation : .terminal) } label: {
                    vm.mode == .terminal
                        ? Label("Ver como conversa", systemImage: "bubble.left.and.text.bubble.right")
                        : Label("Ver terminal", systemImage: "terminal")
                }
                SessionTerminalMenuItem(vm: vm)
                if session.isAgent && !vm.isClosed && model.liveActivities.areEnabled {
                    let tracking = model.liveActivities.isTracking(box: route.box, session: session.name)
                    Button { model.liveActivities.toggle(box: route.box, session: session.name) } label: {
                        Label(tracking ? "Parar de acompanhar" : "Acompanhar na tela bloqueada", systemImage: tracking ? "lock.slash" : "lock.iphone")
                    }
                }
                Divider()
                if session.isAgent && !vm.isClosed && session.agentState == .finished {
                    let archived = model.prefs.isClosed(box: route.box, session: session)
                    Button { model.prefs.setClosed(!archived, box: route.box, session: session.name) } label: {
                        archived ? Label("Voltar para “Sua vez”", systemImage: "tray.and.arrow.up")
                                 : Label("Arquivar (terminei aqui)", systemImage: "archivebox")
                    }
                }
                if vm.isRunning {
                    Button { Task { await vm.interrupt() } } label: { Label("Interromper", systemImage: "stop.circle") }
                }
                Button(role: .destructive) { confirmStop = true } label: { Label("Encerrar sessão", systemImage: "xmark.octagon") }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("Mais ações")
            }
        }
    }

    private var stateColor: Color {
        if vm.isClosed { return Theme.gray }
        if session.agentState == .finished && !vm.background.isEmpty { return Theme.accent }
        return DashState(session)?.color ?? Theme.gray
    }

    private var stateLine: String {
        var parts = [session.agentLabel, session.stateWord]
        if !vm.isClosed, session.isAgent, session.agentState == .running || session.agentState == .waiting {
            parts.append(Fmt.elapsed(since: session.stateSince ?? session.created))
        }
        let bg = vm.background.count
        if bg > 0, session.agentState != .running { parts.append(bg == 1 ? S("1 em segundo plano") : S("\(bg) em segundo plano")) }
        return parts.joined(separator: " · ")
    }

    private var reviewTarget: (String, String)? { vm.reviewTarget }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.red.opacity(0.95), in: Capsule())
                .shadow(radius: 8)
                .padding(.top, 6).padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// The Mac's title bar draws no principal item (the iPhone's two-line title button showed as "Pier"): the session's
/// title becomes the window's title, and the state line sits beside it in the toolbar.
private struct MacSessionTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        if Platform.isMac { content.navigationTitle(title) } else { content }
    }
}

/// A slim line at the top of the conversation while the box cannot be reached.
private struct LinkNoticeBar: View {
    let text: String
    let symbol: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.mini).tint(Theme.orange) } else { Image(systemName: symbol).font(.caption) }
            Text(text).font(.footnote.weight(.medium)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.orange)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-link-notice")
    }
}

// MARK: details

/// The details on the iPhone: the list in a sheet with its title and OK.
struct SessionDetailsSheet: View {
    let vm: SessionViewModel
    let title: String
    let reviewTarget: (String, String)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionDetailsList(vm: vm, title: title, reviewTarget: reviewTarget) { dismiss() }
                .navigationTitle("Detalhes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }
}

/// Everything the old header crammed in: where the session runs, the agent's model/mode/context, its to-do list and
/// helpers. The inspector column at the right on the iPad and the Mac, a sheet on the iPhone. `leaving` runs before the
/// review opens (the sheet closes; the column stays: it is beside the review too).
struct SessionDetailsList: View {
    let vm: SessionViewModel
    let title: String
    let reviewTarget: (String, String)?
    var leaving: () -> Void = {}
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs

    private var session: Session { vm.session }
    private var bs: BoxSession { BoxSession(box: vm.box, session: session) }
    private var signals: Signals? { vm.store.signals }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AgentGlyph(agent: session.agent, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                        HStack(spacing: 6) {
                            if let d = DashState(session), !vm.isClosed { StateBadge(state: d) }
                            else { Text(session.stateWord).font(.caption).foregroundStyle(Theme.textDim) }
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(Fmt.elapsed(since: session.stateSince ?? session.created, now: ctx.date))
                                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.card)
            }
            Section("Onde") {
                if session.chat { row("bubble.left.and.text.bubble.right", "Projeto", String(localized: "Nenhum (conversa livre)")) }
                if !bs.location.isEmpty {
                    row("folder", "Projeto", prefs.displayName(box: vm.box, location: bs.location))
                    if let wt = bs.worktree { row("arrow.triangle.branch", "Worktree", wt) }
                }
                row("shippingbox", "Box", vm.box)
                row("terminal", "Sessão", session.name, mono: true)
                if !session.dir.isEmpty { row("folder.fill", "Pasta", session.dir, mono: true) }
            }
            .listRowBackground(Theme.card)
            Section("Agente") {
                row("sparkles", "Agente", session.agentLabel)
                if let m = signals?.shortModel { row("cpu", "Modelo", m) }
                if let mode = signals?.mode { row("shield.lefthalf.filled", "Modo", mode) }
                if let e = signals?.effort { row("gauge.with.dots.needle.67percent", "Esforço", e) }
                if let c = signals?.context {
                    row("gauge.with.dots.needle.33percent", "Contexto", signals?.contextPercent.map { "\(Signals.compactTokens(c.tokens)) tokens · \($0)%" } ?? "\(Signals.compactTokens(c.tokens)) tokens")
                }
                if session.fidelity == "screen" { row("eye", "Estado", S("inferido da tela")) }
                if (session.queued ?? 0) > 0 { row("clock", "Na fila", "\(session.queued ?? 0)") }
            }
            .listRowBackground(Theme.card)
            if let todos = signals?.todos, !todos.isEmpty {
                Section {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: t.status == "completed" ? "checkmark.circle.fill" : t.status == "in_progress" ? "circle.dotted" : "circle")
                                .foregroundStyle(t.status == "completed" ? Theme.green : t.status == "in_progress" ? Theme.accent : Theme.textFaint)
                            Text(t.status == "in_progress" ? (t.active ?? t.text) : t.text)
                                .font(.subheadline).foregroundStyle(t.status == "completed" ? Theme.textDim : Theme.text)
                                .strikethrough(t.status == "completed", color: Theme.textFaint)
                        }
                    }
                } header: {
                    let done = todos.filter { $0.status == "completed" }.count
                    Text("Tarefas · \(done)/\(todos.count)")
                }
                .listRowBackground(Theme.card)
            }
            if !vm.store.crew.isEmpty {
                Section("Subagentes") {
                    ForEach(vm.store.crew) { c in
                        HStack(spacing: 10) {
                            Image(systemName: c.state == "running" ? "circle.dotted" : "checkmark.circle").foregroundStyle(c.state == "running" ? Theme.accent : Theme.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.subheadline).foregroundStyle(Theme.text)
                                if !c.doing.isEmpty { Text(c.doing).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2) }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }
            if !vm.store.artifacts.isEmpty {
                Section("Páginas publicadas") {
                    ForEach(vm.store.artifacts) { a in
                        if let u = URL(string: a.url) {
                            Link(destination: u) {
                                HStack { Text(a.title).foregroundStyle(Theme.text); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.textFaint) }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }
            if let (loc, wt) = reviewTarget {
                Section {
                    Button {
                        leaving()
                        router.push(ReviewRoute(box: vm.box, location: loc, worktree: wt, session: session.name))
                    } label: { Label("Revisar mudanças", systemImage: "doc.text.magnifyingglass") }
                }
                .listRowBackground(Theme.card)
            }
        }
        .listStyle(.insetGrouped)
        .pierBackground()
    }

    /// A label and its value on one line; a long name or path (`mono`) goes under its label, whole width, so it reads in
    /// the narrow column at the window's side as well as in the sheet.
    @ViewBuilder private func row(_ symbol: String, _ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        if mono {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).font(.caption).foregroundStyle(Theme.textFaint).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.subheadline).foregroundStyle(Theme.textDim)
                    Text(value).font(.mono(12)).foregroundStyle(Theme.text).lineLimit(3).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).font(.caption).foregroundStyle(Theme.textFaint).frame(width: 18)
                Text(label).font(.subheadline).foregroundStyle(Theme.textDim).lineLimit(1).fixedSize()
                Spacer(minLength: 12)
                // The value takes the width before the gap does: "Claude Code" on one line in the narrow column.
                Text(value).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle)
                    .layoutPriority(1)
                    .textSelection(.enabled)
            }
        }
    }
}
