import SwiftUI
import PierKit

/// What the sidebar opens for a project or one of its worktrees on the iPad and the Mac: the worktree's workspace, one
/// worktree at a time (the picker in the toolbar), in four tabs:
/// - **Arquivos**: the file tree and an editor with tabs (`FilesPane`), saved to the box (`PUT …/file`);
/// - **Alterações**: the review of the worktree, its changed files beside their patches, commit / push / PR;
/// - **Histórico**: the log, a commit's message, files and patches;
/// - **Visão geral**: the project, its worktrees and the sessions running here.
/// A status bar at the bottom tells the branch, what is not pushed and not committed, and the editor's line and column.
/// The state of each worktree (open files, unsaved edits, the tab) lives in `WorkspaceState`, so it outlives this view.
struct ProjectWorkspace: View {
    let box: String
    let location: String
    /// nil: the main checkout.
    var worktree: String? = nil

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs

    private var conn: BoxConnection? { model.connection(for: box) }
    private var project: Location? { conn?.location(named: location) }
    private var wt: Worktree? {
        let all = project?.worktrees ?? []
        if let worktree { return all.first { $0.name == worktree } }
        return all.first { $0.main == true } ?? all.first
    }

    var body: some View {
        Group {
            if let project, let wt {
                WorkspaceContent(project: project, worktree: wt, ref: WorkspaceRef(box: box, location: location, worktree: wt.name, execLocation: project.ref(wt)))
                    .id("\(box)/\(location)/\(wt.name)")
            } else if conn?.locations.isEmpty != false && (conn?.state == .connecting || conn?.state == .online) {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "folder", title: worktree == nil ? "Projeto não encontrado" : "Worktree não encontrada")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .pierBackground()
        .navigationTitle(prefs.displayName(box: box, location: location))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The workspace of one worktree that exists.
private struct WorkspaceContent: View {
    let project: Location
    let worktree: Worktree
    let ref: WorkspaceRef

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    @State private var state: WorkspaceState
    @State private var review: ReviewStore
    @State private var status: WorktreeStatus?
    @State private var newWorktree = false
    @State private var removing = false
    @State private var banner: BannerMessage?

    init(project: Location, worktree: Worktree, ref: WorkspaceRef) {
        self.project = project
        self.worktree = worktree
        self.ref = ref
        _state = State(initialValue: WorkspaceState.of(ref))
        _review = State(initialValue: ReviewStore(route: ref.reviewRoute))
    }

    private var conn: BoxConnection? { model.connection(for: ref.box) }
    private var sessions: [Session] {
        (conn?.sessions ?? []).filter { !$0.exited && $0.location == ref.execLocation }
    }
    /// Files changed and not committed: the review's list once read, git's counts until then.
    private var changes: Int { review.item?.files.count ?? status.map { $0.changed + $0.untracked } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch state.tab {
                case .files: FilesPane(state: state)
                case .changes: ChangesPane(ref: ref, store: review, onOpenFile: openFile)
                case .history: HistoryPane(store: state.history, ref: ref, onOpenFile: openFile)
                case .overview: OverviewPane(project: project, worktree: worktree, ref: ref, status: status, sessions: sessions,
                                             onNewWorktree: { newWorktree = true }, onRemove: { removing = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
        .banner($banner)
        .toolbar { toolbar }
        .focusedSceneValue(\.workspace, WorkspaceCommands(
            save: state.tab == .files && state.editor.activeDoc.map { $0.dirty && !$0.saving } == true ? { save() } : nil,
            refresh: { Task { await refresh() } },
            quickOpen: { state.tab = .files; state.quickOpenRequested = true },
            find: state.tab == .files && state.editor.activeDoc?.editable == true ? { state.findRequested = true } : nil,
            tab: { state.tab = $0 }))
        .task {
            bind()
            await loadStatus()
        }
        .task(id: state.tab) {
            bind()
            await loadTab()
        }
        .task {
            // Live: an agent's turn or a worktree change moves files and commits; a burst of events reads the box once.
            var pending: Task<Void, Never>?
            for await h in model.hub.subscribe() where h.box == ref.box {
                let t = h.event.type
                guard t.hasPrefix("agent.") || t.hasPrefix("worktree.") || t == "file.written" else { continue }
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    await refresh(quiet: true)
                }
            }
            pending?.cancel()
        }
        .task {
            // The open file follows the box while it has no edits (an agent writing it); polled while on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if state.tab == .files { await state.editor.poll() }
            }
        }
        .sheet(isPresented: $newWorktree) {
            NewWorktreeSheet(box: ref.box, location: project) { wt in
                router.select(.worktree(WorktreeRoute(box: ref.box, location: project.name, worktree: wt.name)))
            }
        }
        .sheet(isPresented: $removing) {
            RemoveWorktreeSheet(box: ref.box, location: project.name, worktree: worktree.name, changes: changes, sessions: sessions.count) { msg in
                if case .success = msg.kind { router.select(.project(ProjectRoute(box: ref.box, location: project.name))) } else { banner = msg }
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { newTask() } label: { Image(systemName: "plus") }
                .help("Nova tarefa nesta worktree (⌘N)")
                .accessibilityLabel("Nova tarefa aqui")
            Menu {
                Button { newTask() } label: { Label("Nova tarefa aqui", systemImage: "plus.bubble") }
                Button { newWorktree = true } label: { Label("Nova worktree…", systemImage: "arrow.triangle.branch") }
                Divider()
                Button { Task { await refresh() } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                Button { UIPasteboard.general.string = worktree.path } label: { Label("Copiar caminho na box", systemImage: "doc.on.doc") }
                if worktree.main != true {
                    Divider()
                    Button(role: .destructive) { removing = true } label: { Label("Remover worktree…", systemImage: "archivebox") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Mais")
        }
    }

    /// The tabs, and the worktree on screen with the others to switch to: a bar of its own under the toolbar (the
    /// Mac's toolbar has no room in the middle beside the split view's).
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceTab.allCases) { t in
                WorkspaceTabButton(tab: t, selected: state.tab == t, count: t == .changes ? changes : 0) {
                    withAnimation(.snappy(duration: 0.15)) { state.tab = t }
                }
            }
            Spacer(minLength: 12)
            worktreeMenu
        }
        .padding(.horizontal, 8)
        .frame(height: Platform.isMac ? 34 : 44)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-tabs")
    }

    /// The worktree on screen and the others of the project to switch to.
    private var worktreeMenu: some View {
        Menu {
            ForEach(project.worktrees ?? []) { w in
                Button {
                    if w.main == true { router.select(.project(ProjectRoute(box: ref.box, location: project.name))) }
                    else { router.select(.worktree(WorktreeRoute(box: ref.box, location: project.name, worktree: w.name))) }
                } label: {
                    if w.name == worktree.name { Label(w.name, systemImage: "checkmark") }
                    else { Text(verbatim: w.name) + Text(verbatim: w.branch.map { "  \($0)" } ?? "") }
                }
            }
            Divider()
            Button { newWorktree = true } label: { Label("Nova worktree…", systemImage: "plus") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: worktree.main == true ? "arrow.triangle.branch" : "point.topleft.down.to.point.bottomright.curvepath")
                Text(worktree.name).fontWeight(.medium).lineLimit(1)
                if let b = status?.branch ?? worktree.branch, b != worktree.name {
                    Text(b).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                }
                Image(systemName: "chevron.down").font(.system(size: Density.small - 2, weight: .bold)).foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: Density.small + 1))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.washStrong, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Trocar de worktree")
        .accessibilityLabel("Worktree \(worktree.name)")
        .accessibilityIdentifier("workspace-worktree")
    }

    // MARK: status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(status?.branch ?? worktree.branch ?? worktree.name).lineLimit(1)
            }
            if let e = status?.error, !e.isEmpty {
                // git can't read the worktree (its counts are zeros, not "clean").
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.red).lineLimit(1).truncationMode(.tail).help(e)
            }
            if let s = status {
                if s.ahead > 0 { Label("\(s.ahead)", systemImage: "arrow.up").foregroundStyle(Theme.green).help("Commits a enviar") }
                if s.behind > 0 { Label("\(s.behind)", systemImage: "arrow.down").foregroundStyle(Theme.orange).help("Commits a receber") }
            }
            if changes > 0 {
                Button { state.tab = .changes } label: {
                    Label(changes == 1 ? String(localized: "1 alterado") : String(localized: "\(changes) alterados"), systemImage: "pencil.line")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if !sessions.isEmpty {
                Label(sessions.count == 1 ? String(localized: "1 sessão") : String(localized: "\(sessions.count) sessões"), systemImage: "terminal")
            }
            if let port = status?.port ?? worktree.port, port > 0 { Label(":" + String(port), systemImage: "network") }
            Spacer(minLength: 8)
            if state.tab == .files, let doc = state.editor.activeDoc, doc.editable {
                Text("Ln \(state.editor.caret.line), Col \(state.editor.caret.column)").monospacedDigit()
                if let l = doc.language { Text(l.label) }
                Text(verbatim: EditorText.lineEnding(of: doc.base) == "\r\n" ? "CRLF" : "LF")
            }
            if model.boxes.count > 1 { Label(ref.box, systemImage: "shippingbox") }
        }
        .labelStyle(CompactLabelStyle())
        .font(.system(size: Density.small))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 12)
        .frame(height: Platform.isMac ? 24 : 30)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    // MARK: actions

    private func newTask() {
        router.select(.tab(.home))
        router.push(ComposeRoute(box: ref.box, location: project.name, worktree: worktree.main == true ? nil : worktree.name))
    }

    private func openFile(_ path: String) {
        state.tab = .files
        state.editor.open(path)
        Task { await state.tree.reveal(path) }
    }

    private func save() {
        guard let path = state.editor.active else { return }
        Task {
            switch await state.editor.save(path) {
            case .saved: await state.tree.refresh()
            case .conflict: state.editor.conflict = path
            case .failed(let m): if !m.isEmpty { banner = BannerMessage(text: m, kind: .error) }
            }
        }
    }

    private func bind() {
        state.bind(model)
        review.bind(model)
    }

    private func loadStatus() async {
        guard let client = model.client(for: ref.box) else { return }
        if let all = try? await client.worktreeStatuses(location: project.name) {
            status = all.first { $0.path == worktree.path } ?? all.first { $0.name == worktree.name }
        }
    }

    private func loadTab() async {
        switch state.tab {
        case .files: if state.tree.listings.isEmpty || state.tree.state != .loaded { await state.tree.loadRoot() }
        case .changes: await review.load()
        case .history: if state.history.state != .loaded { await state.history.load() }
        case .overview: await loadStatus()
        }
    }

    /// ⌘R, the menu, the box's events (`quiet`: no spinner).
    private func refresh(quiet: Bool = false) async {
        await loadStatus()
        switch state.tab {
        case .files: await state.tree.refresh()
        case .changes: await review.load()
        case .history: await state.history.load()
        case .overview: await conn?.refreshSessions()
        }
        if !quiet, state.tab != .changes { await review.load() }
    }
}

/// One tab of the workspace's bar: icon, title, a count (the changes), the selection.
private struct WorkspaceTabButton: View {
    let tab: WorkspaceTab
    let selected: Bool
    var count = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol).font(.system(size: Density.small))
                Text(tab.title).font(.system(size: Density.small + 1, weight: selected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)").font(.system(size: Density.small - 1, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((selected ? Theme.accent : Theme.textDim).opacity(0.18), in: Capsule())
                }
            }
            .foregroundStyle(selected ? Theme.accent : hovering ? Theme.text : Theme.textDim)
            .padding(.horizontal, 10).frame(height: Platform.isMac ? 26 : 34)
            .background(selected ? Theme.accent.opacity(0.14) : hovering ? Theme.washStrong : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("workspace-tab-\(tab.rawValue)")
    }
}

/// Icon and title close together, for the status bar.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: Density.small - 1)); configuration.title }
    }
}

extension SyntaxLanguage {
    /// The language's name in the status bar.
    var label: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .go: "Go"
        case .rust: "Rust"
        case .bash: "Shell"
        case .json: "JSON"
        case .yaml: "YAML"
        case .php: "PHP"
        case .sql: "SQL"
        case .html: "HTML"
        case .css: "CSS"
        case .diff: "Diff"
        case .c: "C"
        case .cpp: "C++"
        case .java: "Java"
        case .kotlin: "Kotlin"
        }
    }
}

// MARK: - commands (menu bar, keyboard)

/// What the menu bar's File and View items do on the workspace in front (⌘S, ⌘R, ⇧⌘O, ⌘F).
struct WorkspaceCommands {
    /// nil when there is nothing to save.
    var save: (() -> Void)?
    var refresh: () -> Void
    var quickOpen: () -> Void
    var find: (() -> Void)?
    var tab: (WorkspaceTab) -> Void
}

private struct WorkspaceCommandsKey: FocusedValueKey { typealias Value = WorkspaceCommands }

extension FocusedValues {
    var workspace: WorkspaceCommands? {
        get { self[WorkspaceCommandsKey.self] }
        set { self[WorkspaceCommandsKey.self] = newValue }
    }
}
