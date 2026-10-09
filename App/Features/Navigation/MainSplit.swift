import SwiftUI
import PierKit

/// Regular width (iPad, Mac): a sidebar (sections, projects grouped by the person's sections with their
/// worktrees and sessions, live state) and a detail column with the same screens and stacks as the iPhone's tabs.
struct MainSplit: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        } detail: {
            // One stack per section, the same paths the tabs use: notifications and deep links land here unchanged.
            switch router.tab {
            case .home:
                NavigationStack(path: $router.homePath) { DashboardView().pierDestinations() }
            case .inbox:
                NavigationStack(path: $router.inboxPath) { InboxScreen().pierDestinations() }
            case .board:
                NavigationStack(path: $router.boardPath) { BoardScreen().pierDestinations() }
            case .projects:
                NavigationStack(path: $router.projectsPath) { ProjectsRoot().pierDestinations() }
            case .settings:
                NavigationStack(path: $router.settingsPath) { SettingsView().pierDestinations() }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: router.projectsPath.count) { router.projectsPathChanged() }
    }
}

/// The sidebar: app sections, then every project (in the person's sections), each expandable to its worktrees and,
/// under a worktree, its agent sessions. The highlight is the router's, so a session opened elsewhere moves it too.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    /// Expanded projects ("box/location") and worktrees ("box/location/worktree").
    @State private var expanded: Set<String> = []
    @State private var seeded = false
    /// Filters projects, worktrees (name or branch) and agent sessions; matches open by themselves.
    @State private var query = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private func hit(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
    }
    private func sessionHits(_ e: ProjectEntry, _ wt: Worktree) -> [Session] {
        let ref = e.location.ref(wt)
        return (model.connection(for: e.box)?.sessions ?? []).filter { $0.location == ref && DashState($0) != nil && (hit($0.title) || hit($0.name)) }
    }
    /// While searching: the worktrees of a project to show (all of them when the project itself matches), nil to hide it.
    private func visibleWorktrees(_ e: ProjectEntry) -> [Worktree]? {
        let all = e.location.worktrees ?? []
        guard searching else { return all }
        if hit(prefs.displayName(box: e.box, location: e.location.name)) || hit(e.location.name) { return all }
        let some = all.filter { hit($0.name) || hit($0.branch) || !sessionHits(e, $0).isEmpty }
        return some.isEmpty ? nil : some
    }

    private var multiBox: Bool { model.boxes.count > 1 }

    var body: some View {
        let entries = ProjectGrouping.entries(in: model.boxes)
        let groups = ProjectGrouping.groups(entries: entries, prefs: prefs, activity: activity, includeEmptySections: false)
            .filter { if case .hidden = $0.kind { false } else { true } }
            .map { g -> ProjectGroup in var g = g; g.entries = g.entries.filter { visibleWorktrees($0) != nil }; return g }
            .filter { !$0.entries.isEmpty }
        // Rows are buttons into the router, not a List selection: the split view resets the detail's stack when its
        // selection changes, which drops the project / worktree / session path the router sets.
        List {
            if !searching {
            // A dot per live agent, needs-you first (App/Features/Dots); hidden while there are none.
            if !AgentDots.make(model).isEmpty {
                Section { AgentDotStrip(style: .sidebar).listRowBackground(Color.clear) }
            }
            Section {
                row(.tab(.home), id: "sidebar-home") {
                    // The count inside the label (not `.badge`), so it sits within the selection highlight.
                    HStack {
                        Label("Início", systemImage: "square.grid.2x2")
                        Spacer(minLength: 4)
                        let n = model.sessionsStore.needsYouCount
                        if n > 0 { Text("\(n)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.orange) }
                    }
                }
                row(.tab(.inbox), id: "sidebar-inbox") {
                    HStack {
                        Label("Inbox", systemImage: "tray")
                        Spacer(minLength: 4)
                        let n = InboxStore.shared.unseenCount(model: model)
                        if n > 0 { Text("\(n)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.accent) }
                    }
                }
                row(.tab(.board), id: "sidebar-board") { Label("Quadro", systemImage: "rectangle.split.3x1") }
                row(.tab(.projects), id: "sidebar-projects") { Label("Projetos", systemImage: "folder") }
                row(.tab(.settings), id: "sidebar-settings") { Label("Ajustes", systemImage: "gearshape") }
            }
            }
            let chats = chatSessions
            if !chats.isEmpty {
                Section {
                    ForEach(chats) { chat($0) }
                } header: {
                    Text("Conversas").accessibilityIdentifier("sidebar-section-Conversas")
                }
            }
            if searching && groups.isEmpty && chats.isEmpty {
                Text("Nada encontrado").font(.subheadline).foregroundStyle(Theme.textDim).listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.entries) { project($0) }
                } header: {
                    Text(g.title).accessibilityIdentifier("sidebar-section-\(g.title)")
                }
            }
            if entries.isEmpty, model.boxes.contains(where: { $0.state == .connecting }) {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.never)   // the Mac would otherwise keep a bar visible whenever a mouse is connected
        .scrollContentBackground(.hidden)
        .searchable(text: $query, placement: .sidebar, prompt: Text("Buscar projeto, worktree ou sessão"))
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Pier")
        .refreshable { await model.refreshAll() }
        .onChange(of: router.sidebarSelection, initial: true) { _, item in reveal(item) }
        .onChange(of: entries.count, initial: true) {
            #if DEBUG
            ProjectsRoot.seedSectionsIfRequested(prefs: prefs, boxes: model.boxes)
            #endif
            expandActive(entries)
        }
    }

    // MARK: rows

    @ViewBuilder private func project(_ e: ProjectEntry) -> some View {
        let name = prefs.displayName(box: e.box, location: e.location.name)
        let conn = model.connection(for: e.box)
        let worktrees = visibleWorktrees(e) ?? []
        DisclosureGroup(isExpanded: expansion(e.key)) {
            ForEach(worktrees) { wt in worktree(wt, in: e, conn: conn) }
        } label: {
            row(.project(e.route), id: "sidebar-project-\(e.location.name)") {
                HStack(spacing: 10) {
                    ProjectGlyph(name: name, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1)
                        if multiBox { Text(e.box).font(.caption2).foregroundStyle(Theme.textFaint) }
                    }
                    Spacer(minLength: 4)
                    StateDots(counts: conn?.agentCounts(location: e.location.name) ?? [:])
                }
            }
        }
        .contextMenu {
            Button { router.select(.tab(.home)); router.push(ComposeRoute(box: e.box, location: e.location.name)) } label: {
                Label("Nova tarefa aqui", systemImage: "plus.bubble")
            }
        }
    }

    @ViewBuilder private func worktree(_ wt: Worktree, in e: ProjectEntry, conn: BoxConnection?) -> some View {
        let route = WorktreeRoute(box: e.box, location: e.location.name, worktree: wt.name)
        let ref = e.location.ref(wt)
        let sessions = (searching && !hit(wt.name) && !hit(wt.branch) && !sessionHits(e, wt).isEmpty ? sessionHits(e, wt)
                        : (conn?.sessions ?? []).filter { $0.location == ref && DashState($0) != nil })
            .sorted { $0.created > $1.created }
        let label = row(.worktree(route), id: "sidebar-worktree-\(e.location.name)/\(wt.name)") {
            HStack(spacing: 8) {
                Image(systemName: wt.main == true ? "arrow.triangle.branch" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).foregroundStyle(Theme.textDim).frame(width: 18)
                Text(wt.name).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                StateDots(counts: conn?.agentCounts(ref: ref) ?? [:])
            }
        }
        if sessions.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: expansion("\(e.key)/\(wt.name)")) {
                ForEach(sessions) { s in session(s, in: route, all: conn?.sessions ?? []) }
            } label: { label }
        }
    }

    private func session(_ s: Session, in route: WorktreeRoute, all: [Session]) -> some View {
        row(.session(route, name: s.name), id: "sidebar-session-\(s.name)", session: s) {
            HStack(spacing: 8) {
                AgentGlyph(agent: DisplayNames.agent(of: s), size: 20)
                Text(DisplayNames.sessionName(s, among: all)).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                if let st = DashState(s) { StateDot(state: st) }
            }
        }
    }

    /// Live chats (agents tied to no project), newest first; while searching, those whose title or name matches.
    private var chatSessions: [BoxSession] {
        model.boxes.flatMap { b in b.sessions.filter { $0.chat && DashState($0) != nil }.map { BoxSession(box: b.name, session: $0) } }
            .filter { !searching || hit($0.session.title) || hit($0.session.name) }
            .sorted { $0.session.created > $1.session.created }
    }

    /// A chat has no project or worktree to sit under: it opens on Início's stack, like a session picked there.
    private func chat(_ bs: BoxSession) -> some View {
        let s = bs.session
        let all = model.connection(for: bs.box)?.sessions ?? []
        let selected = router.visibleSession == bs.id
        return Button { router.openSession(box: bs.box, session: s) } label: {
            HStack(spacing: 8) {
                AgentGlyph(agent: DisplayNames.agent(of: s), size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DisplayNames.sessionName(s, among: all)).font(.subheadline).lineLimit(1)
                    if multiBox { Text(bs.box).font(.caption2).foregroundStyle(Theme.textFaint) }
                }
                Spacer(minLength: 4)
                if let st = DashState(s) { StateDot(state: st) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.24))
                    .padding(.horizontal, -10).padding(.vertical, -6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sidebar-chat-\(s.name)")
    }

    /// A pickable row: a button into the router, highlighted while the detail shows that item.
    private func row(_ item: SidebarItem, id: String, session: Session? = nil, @ViewBuilder label: () -> some View) -> some View {
        let selected = router.sidebarSelection == item
        return Button { router.select(item, session: session) } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        // Drawn behind the label, reaching into the row's insets: a row background is ignored by DisclosureGroup labels and
        // by the Mac sidebar.
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.24))
                    .padding(.horizontal, -10).padding(.vertical, -6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }

    // MARK: expansion

    private func expansion(_ key: String) -> Binding<Bool> {
        // While searching everything that matched stays open, so the hit is visible without tapping.
        Binding(get: { searching || expanded.contains(key) }, set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    /// Keep the selected item visible: open the project above it; a picked worktree also shows its sessions.
    private func reveal(_ item: SidebarItem) {
        switch item {
        case .tab, .project: break
        case .worktree(let w), .session(let w, _):
            let p = LocalPrefs.key(box: w.box, location: w.location)
            expanded.formUnion([p, "\(p)/\(w.worktree)"])
        }
    }

    /// First load: open the projects where an agent needs the person or is working.
    private func expandActive(_ entries: [ProjectEntry]) {
        guard !seeded, !entries.isEmpty else { return }
        seeded = true
        for e in entries {
            let c = model.connection(for: e.box)?.agentCounts(location: e.location.name) ?? [:]
            if (c[.needsYou] ?? 0) + (c[.working] ?? 0) > 0 { expanded.insert(e.key) }
        }
    }

    private func activity(_ e: ProjectEntry) -> Int {
        model.connection(for: e.box)?.agentCounts(location: e.location.name).values.reduce(0, +) ?? 0
    }
}

/// A sidebar-sized CountPills: a dot per state with its count ("● 2 ● 1").
struct StateDots: View {
    let counts: [DashState: Int]
    var body: some View {
        HStack(spacing: 7) {
            ForEach([DashState.needsYou, .working, .done], id: \.self) { s in
                if let n = counts[s], n > 0 {
                    HStack(spacing: 3) {
                        StateDot(state: s)
                        Text("\(n)").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(s.color)
                    }
                }
            }
        }
    }
}

/// One session's state as a dot; working pulses.
struct StateDot: View {
    let state: DashState
    @State private var dim = false
    var body: some View {
        Circle().fill(state.color).frame(width: 7, height: 7)
            .opacity(state == .working && dim ? 0.35 : 1)
            .animation(state == .working ? .easeInOut(duration: 0.9).repeatForever() : .default, value: dim)
            .onAppear { if state == .working { dim = true } }
            .accessibilityLabel(Text(state.title))
    }
}
