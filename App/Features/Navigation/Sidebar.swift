import SwiftUI
import PierKit
import UniformTypeIdentifiers

/// The regular-width sidebar (iPad, Mac), top to bottom:
/// - "Nova tarefa" / "Nova conversa" and the app's sections;
/// - **Trabalhando**: every worktree with an agent that needs the person or is working, pinned above the rest
///   (`SidebarRules.working`), so the live work is one click away whatever section its project sits in;
/// - Conversas (agents tied to no project);
/// - the projects in the person's sections, each expandable to its worktrees and their sessions. Each section orders its
///   projects by hand, by name or by recent activity (its menu); projects are dragged to reorder them or into another
///   section, and sections are dragged by their titles. Sections are created, and sections and projects renamed, in
///   place: Return keeps the name, Esc drops it;
/// - **Arquivadas**: sessions archived on the device or exited on the box; hidden projects;
/// - a footer with "Nova seção" and Ajustes.
/// Rows are custom (not a List): a list's own drag handling swallowed the drops on the Mac. Sections fold and stay folded
/// (`LocalPrefs.sidebarExpanded`). The highlight is the router's, so a session opened elsewhere moves it too.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    /// Expanded projects ("box/location") and worktrees ("box/location/worktree").
    @State private var expanded: Set<String> = []
    @State private var seeded = false
    /// Filters projects, worktrees (name or branch) and agent sessions; matches open by themselves.
    @State private var query = ""
    /// The row under the pointer (iPad pointer, Mac): it shows its "+" and a light fill.
    @State private var hovered: String?
    /// What is being dragged (kept outside the view's state: the drop delegates read it while the drag runs).
    @State private var dragging = SidebarDragging()
    /// Where the dragged item would land, for the insertion line or the section's highlight.
    @State private var dropSpot: SidebarDropSpot?
    /// A section being created, or a section or project being renamed, in place.
    @State private var edit: SidebarEdit?
    @State private var editText = ""
    /// Which edit's field has the focus: tied to the edit, so a field going away (the one before it) can't take the
    /// focus from the field that comes next.
    @FocusState private var editFocus: SidebarEdit?
    /// A row to bring into view (the new section's field).
    @State private var scrollTarget: String?
    @State private var newWorktree: ProjectEntry?

    /// Archived sessions listed before "Ver todas no Quadro".
    private let archivedLimit = 25

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private func hit(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
    }
    private var multiBox: Bool { model.boxes.count > 1 }
    private var defaultBox: String? { prefs.lastBox ?? model.boxes.first?.name }
    private var signals: SessionSignals { .shared }

    // MARK: data

    /// Every agent session of every box, minus hidden projects.
    private var items: [AgentBoard.Item] {
        model.boxes.flatMap { b in b.sessions.map { AgentBoard.Item(box: b.name, session: $0) } }
            .filter { $0.session.isAgent && !prefs.isHidden(box: $0.box, location: $0.location) }
    }
    private func isArchived(_ it: AgentBoard.Item) -> Bool { prefs.isClosed(box: it.box, session: it.session) }
    /// In the projects tree and the chats: an agent, not archived, not exited.
    private func listed(_ s: Session, box: String) -> Bool {
        SidebarRules.isListed(s, archived: prefs.isClosed(box: box, session: s), background: signals.background["\(box)/\(s.name)"] != nil)
    }

    private func sessionHits(_ e: ProjectEntry, _ wt: Worktree) -> [Session] {
        let ref = e.location.ref(wt)
        return (model.connection(for: e.box)?.sessions ?? []).filter { $0.location == ref && listed($0, box: e.box) && (hit($0.title) || hit($0.name)) }
    }
    /// While searching: the worktrees of a project to show (all of them when the project itself matches), nil to hide it.
    private func visibleWorktrees(_ e: ProjectEntry) -> [Worktree]? {
        let all = e.location.worktrees ?? []
        guard searching else { return all }
        if hit(prefs.displayName(box: e.box, location: e.location.name)) || hit(e.location.name) { return all }
        let some = all.filter { hit($0.name) || hit($0.branch) || !sessionHits(e, $0).isEmpty }
        return some.isEmpty ? nil : some
    }

    var body: some View {
        let entries = ProjectGrouping.entries(in: model.boxes)
        let all = ProjectGrouping.groups(entries: entries, prefs: prefs, activity: { ProjectGrouping.lastActivity($0, in: model.boxes) },
                                         includeEmptySections: !searching)
        let groups = all
            .filter { if case .hidden = $0.kind { false } else { true } }
            .map { g -> ProjectGroup in var g = g; g.entries = g.entries.filter { visibleWorktrees($0) != nil }; return g }
            .filter { !$0.entries.isEmpty || (!searching && $0.section != nil) }
        let hidden = all.first { if case .hidden = $0.kind { true } else { false } }?.entries
            .filter { !searching || hit(prefs.displayName(box: $0.box, location: $0.location.name)) || hit($0.location.name) } ?? []
        let sessions = items
        let working = searching ? [] : SidebarRules.working(sessions, archived: isArchived, background: Set(signals.background.keys))
        let archived = SidebarRules.archived(sessions, archived: isArchived)
            .filter { !searching || hit($0.session.title) || hit($0.session.name) || hit($0.location) }
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    content(entries: entries, groups: groups, hidden: hidden, working: working, archived: archived)
                }
                .scrollIndicators(.never)   // the Mac would otherwise keep a bar visible whenever a mouse is connected
                .refreshable { await model.refreshAll() }
                .onChange(of: scrollTarget) { _, id in
                    guard let id else { return }
                    scrollTarget = nil
                    // Once the change that asked for it is laid out (a section the open edit adds pushes the row down).
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            footer(entries: entries)
        }
        .background(Theme.bg.ignoresSafeArea())
        .searchable(text: $query, placement: .sidebar, prompt: Text("Buscar projeto, worktree ou sessão"))
        .navigationTitle("Pier")
        .onChange(of: router.sidebarSelection, initial: true) { _, item in reveal(item) }
        .onChange(of: entries.count, initial: true) {
            #if DEBUG
            ProjectsRoot.seedSectionsIfRequested(prefs: prefs, boxes: model.boxes)
            #endif
            expandActive(entries)
        }
        .onChange(of: editFocus) { was, now in
            // Clicking elsewhere keeps what was typed, like a rename in the Finder. A moment later, and only if it is still
            // the same edit without the focus: × cancels it first, and a field can lose the focus for an instant as it
            // appears.
            guard let e = was, now != e, edit == e else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if edit == e, editFocus != e { commitEdit() }
            }
        }
        .sheet(item: $newWorktree) { e in
            NewWorktreeSheet(box: e.box, location: e.location) { wt in
                expanded.insert(e.key)
                router.select(.worktree(WorktreeRoute(box: e.box, location: e.location.name, worktree: wt.name)))
            }
        }
    }

    private func content(entries: [ProjectEntry], groups: [ProjectGroup], hidden: [ProjectEntry],
                         working: [SidebarRules.ActiveWorktree], archived: [AgentBoard.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !searching {
                quickActions
                navRows
                if !working.isEmpty { workingSection(working) }
            }
            chatsSection
            if searching && groups.isEmpty && chatSessions.isEmpty && archived.isEmpty && hidden.isEmpty {
                Text("Nada encontrado").font(.system(size: Density.small)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 10).padding(.vertical, 12)
            }
            ForEach(groups) { g in projectSection(g, groups: groups) }
            if case .newSection = edit { newSectionRow }
            if entries.isEmpty, model.boxes.contains(where: { $0.state == .connecting }) {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding(.vertical, 12)
            }
            if !archived.isEmpty { archivedSection(archived) }
            if !hidden.isEmpty { hiddenSection(hidden) }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
    }

    // MARK: top

    /// "Nova tarefa" (⌘N) as the sidebar's first action and a new chat (⇧⌘N) beside it.
    private var quickActions: some View {
        HStack(spacing: 6) {
            Button { newTask() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil").font(.system(size: Density.icon, weight: .semibold))
                    Text("Nova tarefa").font(.system(size: Density.text, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if Platform.isMac { Text(verbatim: "⌘N").font(.system(size: Density.small)).foregroundStyle(.white.opacity(0.7)) }
                }
                .padding(.horizontal, 10).frame(height: Density.row + 4)
            }
            .buttonStyle(SidebarButtonStyle(kind: .primary))
            .disabled(defaultBox == nil)
            .help("Nova tarefa (⌘N)")
            .accessibilityIdentifier("sidebar-new-task")

            Button { newChat() } label: {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: Density.icon, weight: .semibold))
                    .frame(width: Density.row + 8, height: Density.row + 4)
            }
            .buttonStyle(SidebarButtonStyle(kind: .secondary))
            .disabled(defaultBox == nil)
            .help("Nova conversa (⇧⌘N)")
            .accessibilityLabel("Nova conversa")
            .accessibilityIdentifier("sidebar-new-chat")
        }
        .padding(.horizontal, 2).padding(.top, 6).padding(.bottom, 8)
    }

    @ViewBuilder private var navRows: some View {
        navRow(.tab(.home), "Início", "square.grid.2x2", id: "sidebar-home") {
            CountBadge(count: model.sessionsStore.needsYouCount, color: Theme.orange)
        }
        navRow(.tab(.inbox), "Inbox", "tray", id: "sidebar-inbox") {
            CountBadge(count: InboxStore.shared.unseenCount(model: model), color: Theme.accent)
        }
        navRow(.tab(.board), "Quadro", "rectangle.split.3x1", id: "sidebar-board") { EmptyView() }
        navRow(.tab(.projects), "Projetos", "folder", id: "sidebar-projects") { EmptyView() }
    }

    private func navRow(_ item: SidebarItem, _ title: LocalizedStringKey, _ symbol: String, id: String,
                        @ViewBuilder trailing: () -> some View) -> some View {
        let badge = trailing()
        return SidebarRow(id: id, selected: router.sidebarSelection == item, hovered: $hovered, action: { router.select(item) }) {
            Image(systemName: symbol).font(.system(size: Density.icon)).foregroundStyle(Theme.accent).frame(width: Density.glyph)
            Text(title).font(.system(size: Density.text)).lineLimit(1)
            Spacer(minLength: 4)
            badge
        }
    }

    // MARK: Trabalhando

    private func workingSection(_ working: [SidebarRules.ActiveWorktree]) -> some View {
        let open = isOpen("working")
        return VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(id: "sidebar-section-Trabalhando", open: open, toggle: { toggle("working") }) {
                LiveDot(color: working.contains(where: \.needsYou) ? Theme.orange : Theme.accent)
                Text("Trabalhando")
                CountCapsule(count: working.count)
            } trailing: { EmptyView() }
            if open { ForEach(working) { activeRow($0) } }
        }
    }

    /// A worktree at work: its project's glyph with the state, the worktree (or the chat), and what is going on there
    /// ("Precisa de você", the agent's current step). One agent opens its session; several open the worktree and are
    /// listed under it.
    @ViewBuilder private func activeRow(_ a: SidebarRules.ActiveWorktree) -> some View {
        let conn = model.connection(for: a.box)
        let all = conn?.sessions ?? []
        let first = a.items[0]
        let project = a.isChat ? String(localized: "Conversa") : prefs.displayName(box: a.box, location: a.location)
        let route = worktreeRoute(box: a.box, location: a.location, worktree: a.worktree)
        let single = a.items.count == 1
        let item: SidebarItem? = a.isChat ? nil : single ? .session(route, name: first.session.name) : .worktree(route)
        let title = a.isChat ? DisplayNames.sessionName(first.session, among: all) : route.worktree
        SidebarRow(id: "sidebar-active-\(a.id)", selected: item.map { router.sidebarSelection == $0 } ?? (router.visibleSession == first.id),
                   hovered: $hovered, height: Density.row + 14, action: {
            if a.isChat { router.openSession(box: a.box, session: first.session) } else if let item { router.select(item, session: single ? first.session : nil) }
        }) {
            ZStack(alignment: .bottomTrailing) {
                if a.isChat { AgentGlyph(agent: DisplayNames.agent(of: first.session), size: Density.glyph + 2) }
                else { ProjectGlyph(name: project, size: Density.glyph + 2) }
                StateDot(state: a.needsYou ? .needsYou : .working)
                    .padding(1.5).background(Circle().fill(Theme.bg)).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: Density.text, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    // The main worktree goes by the project's name already: no "sandbox · sandbox".
                    if !a.isChat && title != project { Text(project).foregroundStyle(Theme.textFaint); Text("·").foregroundStyle(Theme.textFaint) }
                    activity(of: a)
                }
                .font(.system(size: Density.small)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !single { CountCapsule(count: a.items.count) }
        }
        .contextMenu {
            if !a.isChat {
                Button { router.select(.worktree(route)) } label: { Label("Abrir worktree", systemImage: "arrow.triangle.branch") }
                Button { newTask(box: a.box, location: a.location, worktree: a.worktree) } label: { Label("Nova tarefa nesta worktree", systemImage: "plus.bubble") }
            }
        }
        if !single {
            ForEach(a.items) { it in
                SidebarRow(id: "sidebar-active-session-\(it.session.name)", selected: router.sidebarSelection == .session(route, name: it.session.name),
                           hovered: $hovered, indent: 1, action: { router.select(.session(route, name: it.session.name), session: it.session) }) {
                    AgentGlyph(agent: DisplayNames.agent(of: it.session), size: Density.glyph - 2)
                    Text(DisplayNames.sessionName(it.session, among: all)).font(.system(size: Density.small + 1)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let st = DashState(it.session) { StateDot(state: st) }
                }
            }
        }
    }

    /// "Precisa de você" in orange, or the first working agent's current step (from the screen), or "Trabalhando".
    @ViewBuilder private func activity(of a: SidebarRules.ActiveWorktree) -> some View {
        if a.needsYou {
            Text("Precisa de você").foregroundStyle(Theme.orange)
        } else if let step = a.items.lazy.compactMap({ signals.steps[$0.id] }).first, !step.isEmpty {
            Text(step).foregroundStyle(Theme.textDim)
        } else {
            Text("Trabalhando").foregroundStyle(Theme.accent)
        }
    }

    // MARK: Conversas

    /// Live chats (agents tied to no project), newest first; while searching, those whose title or name matches.
    private var chatSessions: [BoxSession] {
        model.boxes.flatMap { b in b.sessions.filter { $0.chat && listed($0, box: b.name) }.map { BoxSession(box: b.name, session: $0) } }
            .filter { !searching || hit($0.session.title) || hit($0.session.name) }
            .sorted { $0.session.created > $1.session.created }
    }

    @ViewBuilder private var chatsSection: some View {
        let chats = chatSessions
        if !chats.isEmpty {
            let open = isOpen("chats")
            SidebarHeader(id: "sidebar-section-Conversas", open: open, toggle: { toggle("chats") }) {
                Text("Conversas"); CountCapsule(count: chats.count)
            } trailing: { EmptyView() }
            if open { ForEach(chats) { chat($0) } }
        }
    }

    /// A chat has no project or worktree to sit under: it opens on Início's stack, like a session picked there.
    private func chat(_ bs: BoxSession) -> some View {
        let s = bs.session
        let all = model.connection(for: bs.box)?.sessions ?? []
        return SidebarRow(id: "sidebar-chat-\(s.name)", selected: router.visibleSession == bs.id, hovered: $hovered,
                          action: { router.openSession(box: bs.box, session: s) }) {
            AgentGlyph(agent: DisplayNames.agent(of: s), size: Density.glyph)
            VStack(alignment: .leading, spacing: 0) {
                Text(DisplayNames.sessionName(s, among: all)).font(.system(size: Density.text)).lineLimit(1)
                if multiBox { Text(bs.box).font(.system(size: Density.small)).foregroundStyle(Theme.textFaint) }
            }
            Spacer(minLength: 4)
            if let st = DashState(s) { StateDot(state: st) }
        }
        .contextMenu {
            if s.agentState != .running && s.agentState != .waiting {
                Button { prefs.setClosed(true, box: bs.box, session: s.name) } label: { Label("Arquivar", systemImage: "archivebox") }
            }
        }
    }

    // MARK: projects

    @ViewBuilder private func projectSection(_ g: ProjectGroup, groups: [ProjectGroup]) -> some View {
        let open = isOpen(g.id)
        let into = SidebarDropSpot.into(group: g.id)
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(g, open: open, groups: groups)
            if open || searching {
                ForEach(g.entries) { project($0, in: g) }
                if g.entries.isEmpty {
                    Text("Arraste projetos para cá")
                        .font(.system(size: Density.small)).foregroundStyle(dropSpot == into ? Theme.accent : Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(height: Density.row + 4)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(dropSpot == into ? Theme.accent : Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .padding(.vertical, 2)
                        .onDrop(of: [SidebarDragging.type], delegate: SidebarDropDelegate(split: (Density.row + 4) / 2, dragging: dragging, spot: $dropSpot,
                            at: { _ in dragging.item?.isProject == true ? into : nil }, perform: { drop($0) }))
                }
            }
        }
    }

    @ViewBuilder private func sectionHeader(_ g: ProjectGroup, open: Bool, groups: [ProjectGroup]) -> some View {
        if let section = g.section, edit == .renameSection(section) {
            // The field on its own (not inside the title's button, which folds the section, and not a drag source).
            inlineField("Nome da seção", for: .renameSection(section))
                .padding(.leading, 8).padding(.trailing, 6)
                .frame(height: Density.row + 2)
                .padding(.top, SidebarHeader<EmptyView, EmptyView>.gap)
        } else {
            sectionTitle(g, open: open, groups: groups)
        }
    }

    private func sectionTitle(_ g: ProjectGroup, open: Bool, groups: [ProjectGroup]) -> some View {
        let section = g.section
        let headerSpot: (Bool) -> SidebarDropSpot? = { after in
            switch dragging.item {
            case .project?: return .into(group: g.id)
            case .section(let id)?:
                // Sections move among sections; "Sem seção" always comes last.
                guard let section, id != section else { return section == nil ? .sectionAtEnd : nil }
                return .section(section, after: after)
            case nil: return nil
            }
        }
        let highlighted = dropSpot == .into(group: g.id)
        let line: VerticalEdge? = switch dropSpot {
        case .section(let id, let after)? where id == section: after ? .bottom : .top
        case .sectionAtEnd? where section == nil: .top
        default: nil
        }
        return SidebarHeader(id: "sidebar-section-\(g.title)", open: open || searching, toggle: { toggle(g.id) }, highlighted: highlighted, line: line) {
            Text(g.title)
            if !g.entries.isEmpty { CountCapsule(count: g.entries.count) }
            if g.sort != .manual {
                Image(systemName: g.sort == .name ? "textformat" : "clock").font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint)
                    .help(g.sort == .name ? Text("Ordem alfabética") : Text("Atividade recente"))
            }
        } trailing: {
            groupMenu(g, groups: groups)
        }
        .modifier(SectionDrag(section: section, title: g.title, dragging: dragging))
        .onDrop(of: [SidebarDragging.type], delegate: SidebarDropDelegate(split: SidebarHeader<EmptyView, EmptyView>.gap + (Density.row + 2) / 2, dragging: dragging, spot: $dropSpot,
            at: { headerSpot($0) }, perform: { drop($0) }))
        .contextMenu { groupMenuItems(g, groups: groups) }
    }

    private func groupMenu(_ g: ProjectGroup, groups: [ProjectGroup]) -> some View {
        Menu { groupMenuItems(g, groups: groups) } label: {
            Image(systemName: "ellipsis").font(.system(size: Density.small, weight: .bold))
                .frame(width: 22, height: 18)
        }
        .menuStyle(.button).buttonStyle(SidebarButtonStyle(kind: .quiet, radius: 5))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Opções da seção \(g.title)")
    }

    @ViewBuilder private func groupMenuItems(_ g: ProjectGroup, groups: [ProjectGroup]) -> some View {
        // The order on screen without a search's filter: switching to manual keeps the whole section where it was.
        Picker(selection: Binding(get: { g.sort }, set: { sort in
            let shown = currentGroups().first { $0.id == g.id }?.entries.map(\.key) ?? g.entries.map(\.key)
            prefs.setSort(sort, of: g.section, shown: shown)
        })) {
            Label("Manualmente", systemImage: "hand.draw").tag(ProjectSort.manual)
            Label("Por nome", systemImage: "textformat").tag(ProjectSort.name)
            Label("Por atividade recente", systemImage: "clock").tag(ProjectSort.activity)
        } label: { Label("Ordenar projetos", systemImage: "arrow.up.arrow.down") }
        .pickerStyle(.menu)
        if let id = g.section {
            Divider()
            Button { startEdit(.renameSection(id), text: g.title) } label: { Label("Renomear seção", systemImage: "pencil") }
            let i = prefs.sections.firstIndex { $0.id == id }
            Button { moveSection(id, by: -1) } label: { Label("Mover para cima", systemImage: "arrow.up") }.disabled(i == 0)
            Button { moveSection(id, by: 1) } label: { Label("Mover para baixo", systemImage: "arrow.down") }.disabled(i == prefs.sections.count - 1)
            Divider()
            Button(role: .destructive) { withAnimation(.snappy) { prefs.removeSection(id) } } label: { Label("Excluir seção", systemImage: "trash") }
        }
        Divider()
        Button { startEdit(.newSection(project: nil), text: "") } label: { Label("Nova seção", systemImage: "folder.badge.plus") }
    }

    @ViewBuilder private func project(_ e: ProjectEntry, in g: ProjectGroup) -> some View {
        let name = prefs.displayName(box: e.box, location: e.location.name)
        let conn = model.connection(for: e.box)
        let worktrees = visibleWorktrees(e) ?? []
        let id = "sidebar-project-\(e.location.name)"
        let open = searching || expanded.contains(e.key)
        let line: VerticalEdge? = if case .project(let k, let after, _)? = dropSpot, k == e.key { after ? .bottom : .top } else { nil }
        if edit == .renameProject(e.key) {
            // The field on its own: not inside the row's button (which opens the project), not a drag source.
            HStack(spacing: 7) {
                ProjectGlyph(name: name, size: Density.glyph)
                inlineField("Nome do projeto", for: .renameProject(e.key))
            }
            .padding(.leading, 2 + 14 + 4).padding(.trailing, 6)
            .frame(height: Density.row)
        } else {
            SidebarRow(id: id, selected: router.sidebarSelection == .project(e.route), hovered: $hovered, line: line,
                       disclosure: worktrees.isEmpty ? nil : open, toggle: { toggleExpanded(e.key) },
                       action: { router.select(.project(e.route)) },
                       accessory: { plus(id, help: "Nova tarefa em \(name)") { newTask(box: e.box, location: e.location.name) } }) {
                ProjectGlyph(name: name, size: Density.glyph)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: Density.text)).lineLimit(1)
                    if multiBox { Text(e.box).font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint) }
                }
                if WorkspaceRegistry.shared.hasUnsaved(box: e.box, location: e.location.name) {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.textDim)
                        .help("Arquivos não salvos")
                        .accessibilityLabel("Arquivos não salvos")
                }
                Spacer(minLength: 4)
                StateDots(counts: conn?.agentCounts(location: e.location.name) ?? [:])
            }
            .onDrag { dragging.begin(.project(e.key)) } preview: { DragChip(glyph: name, title: name) }
            .onDrop(of: [SidebarDragging.type], delegate: SidebarDropDelegate(split: Density.row / 2, dragging: dragging, spot: $dropSpot,
                at: { after in
                    // Over itself: nowhere to go.
                    guard case .project(let k)? = dragging.item, k != e.key else { return nil }
                    return .project(e.key, after: after, group: g.id)
                },
                perform: { drop($0) }))
            .contextMenu { projectMenu(e, name: name) }
        }
        if open {
            ForEach(worktrees) { wt in worktree(wt, in: e, conn: conn) }
        }
    }

    @ViewBuilder private func projectMenu(_ e: ProjectEntry, name: String) -> some View {
        Button { router.select(.project(e.route)) } label: { Label("Abrir", systemImage: "folder") }
        Button { newTask(box: e.box, location: e.location.name) } label: { Label("Nova tarefa aqui", systemImage: "plus.bubble") }
        Button { newWorktree = e } label: { Label("Nova worktree…", systemImage: "arrow.triangle.branch") }
        Divider()
        Button { startEdit(.renameProject(e.key), text: name) } label: { Label("Renomear…", systemImage: "pencil") }
        if name != e.location.name {
            Button { prefs.rename(box: e.box, location: e.location.name, to: nil) } label: { Label("Voltar ao nome “\(e.location.name)”", systemImage: "arrow.uturn.backward") }
        }
        Menu {
            ForEach(prefs.sections) { s in
                Button { moveProject(e.key, to: s.id) } label: {
                    if prefs.section(of: e.key) == s.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Button { moveProject(e.key, to: nil) } label: {
                if prefs.section(of: e.key) == nil { Label("Sem seção", systemImage: "checkmark") } else { Text("Sem seção") }
            }
            Divider()
            Button { startEdit(.newSection(project: e.key), text: "") } label: { Label("Nova seção…", systemImage: "folder.badge.plus") }
        } label: { Label("Mover para", systemImage: "folder") }
        Divider()
        Button { prefs.setHidden(true, box: e.box, location: e.location.name) } label: { Label("Ocultar", systemImage: "eye.slash") }
    }

    @ViewBuilder private func worktree(_ wt: Worktree, in e: ProjectEntry, conn: BoxConnection?) -> some View {
        let route = WorktreeRoute(box: e.box, location: e.location.name, worktree: wt.name)
        let ref = e.location.ref(wt)
        let sessions = (searching && !hit(wt.name) && !hit(wt.branch) && !sessionHits(e, wt).isEmpty ? sessionHits(e, wt)
                        : (conn?.sessions ?? []).filter { $0.location == ref && listed($0, box: e.box) })
            .sorted { $0.created > $1.created }
        let id = "sidebar-worktree-\(e.location.name)/\(wt.name)"
        let key = "\(e.key)/\(wt.name)"
        let open = searching || expanded.contains(key)
        SidebarRow(id: id, selected: router.sidebarSelection == .worktree(route), hovered: $hovered, indent: 1,
                   disclosure: sessions.isEmpty ? nil : open, toggle: { toggleExpanded(key) },
                   action: { router.select(.worktree(route)) },
                   accessory: { plus(id, help: "Iniciar agente em \(wt.name)") { newTask(box: e.box, location: e.location.name, worktree: wt.main == true ? nil : wt.name) } }) {
            Image(systemName: wt.main == true ? "arrow.triangle.branch" : "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: Density.small)).foregroundStyle(Theme.textDim).frame(width: Density.glyph)
            Text(wt.name).font(.system(size: Density.text)).lineLimit(1)
            if let b = wt.branch, b != wt.name {
                Text(b).font(.system(size: Density.small)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            StateDots(counts: conn?.agentCounts(ref: ref) ?? [:])
        }
        .contextMenu {
            Button { router.select(.worktree(route)) } label: { Label("Abrir worktree", systemImage: "arrow.right.circle") }
            Button { newTask(box: e.box, location: e.location.name, worktree: wt.main == true ? nil : wt.name) } label: {
                Label("Iniciar agente aqui", systemImage: "sparkles")
            }
        }
        if open {
            ForEach(sessions) { s in session(s, box: e.box, in: route, all: conn?.sessions ?? []) }
        }
    }

    private func session(_ s: Session, box: String, in route: WorktreeRoute, all: [Session]) -> some View {
        SidebarRow(id: "sidebar-session-\(s.name)", selected: router.sidebarSelection == .session(route, name: s.name), hovered: $hovered,
                   indent: 2, action: { router.select(.session(route, name: s.name), session: s) }) {
            AgentGlyph(agent: DisplayNames.agent(of: s), size: Density.glyph - 2)
            Text(DisplayNames.sessionName(s, among: all)).font(.system(size: Density.text)).lineLimit(1)
            Spacer(minLength: 4)
            if let st = DashState(s) { StateDot(state: st) }
        }
        .contextMenu {
            if s.agentState != .running && s.agentState != .waiting {
                Button { prefs.setClosed(true, box: box, session: s.name) } label: { Label("Arquivar (terminei aqui)", systemImage: "archivebox") }
            }
        }
    }

    // MARK: new section, renames (in place)

    private var newSectionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.plus").font(.system(size: Density.icon)).foregroundStyle(Theme.accent).frame(width: Density.glyph)
            inlineField("Nome da nova seção", for: edit ?? .newSection(project: nil))
        }
        .padding(.horizontal, 8).frame(height: Density.row + 6)
        .padding(.top, 6)
        .id("sidebar-new-section-row")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-new-section-row")
    }

    /// The field of an edit in place: Return keeps it, Esc or × drops it (× for a screen without a keyboard), a click
    /// elsewhere keeps it.
    private func inlineField(_ placeholder: LocalizedStringKey, for e: SidebarEdit) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $editText)
                .textFieldStyle(.plain)
                .font(.system(size: Density.text))
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .focused($editFocus, equals: e)
                .onSubmit { commitEdit() }
                .onKeyPress(.escape) { cancelEdit(); return .handled }
                .accessibilityIdentifier("sidebar-edit-field")
            Button { cancelEdit() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: Density.small + 1)).foregroundStyle(Theme.textFaint)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Esc as a key command too: without one, a text field on the Mac takes Esc to give up its focus, the
            // field's onKeyPress never sees it, and losing the focus keeps the name.
            .keyboardShortcut(.cancelAction)
            .help("Cancelar (Esc)")
            .accessibilityLabel("Cancelar")
            .accessibilityIdentifier("sidebar-edit-cancel")
        }
        .padding(.leading, 6).padding(.trailing, 3).frame(height: Density.row - 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
        // By edit: the new section's row stays on screen when "Mover para → Nova seção…" replaces a new section.
        .task(id: e) { editFocus = e }
    }

    /// The field takes the focus once it is on screen (`inlineField`).
    private func startEdit(_ e: SidebarEdit, text: String) {
        // The same edit again ("Nova seção" with its field open): back in the field, with what is typed.
        if edit == e { editFocus = e; return }
        // Another edit still open keeps what was typed in it, as a click elsewhere would.
        if edit != nil { commitEdit() }
        editText = text
        withAnimation(.snappy(duration: 0.2)) { edit = e }
        if case .newSection = e { scrollTarget = "sidebar-new-section-row" }
    }

    private func cancelEdit() {
        withAnimation(.snappy(duration: 0.2)) { edit = nil }
        editFocus = nil
    }

    private func commitEdit() {
        guard let e = edit else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.snappy(duration: 0.2)) {
            switch e {
            case .newSection(let project):
                if !text.isEmpty {
                    let id = prefs.addSection(named: text, with: project)
                    prefs.setSidebarExpanded(id.uuidString, true)
                }
            case .renameSection(let id):
                if !text.isEmpty { prefs.renameSection(id, to: text) }
            case .renameProject(let key):
                if let p = ProjectGrouping.entries(in: model.boxes).first(where: { $0.key == key }) {
                    // An empty name gives the project back the one it has on the box.
                    prefs.rename(box: p.box, location: p.location.name, to: text.isEmpty || text == p.location.name ? nil : text)
                }
            }
            edit = nil
        }
        editFocus = nil
    }

    // MARK: Arquivadas, ocultos

    private func archivedSection(_ archived: [AgentBoard.Item]) -> some View {
        let open = isOpen("archived", default: false)
        return VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(id: "sidebar-section-Arquivadas", open: open || searching, toggle: { toggle("archived", default: false) }) {
                Image(systemName: "archivebox")
                Text("Arquivadas")
                CountCapsule(count: archived.count)
            } trailing: { EmptyView() }
            if open || searching {
                ForEach(archived.prefix(archivedLimit)) { archivedRow($0) }
                if archived.count > archivedLimit {
                    Button { router.select(.tab(.board)) } label: {
                        Label("Ver todas no Quadro (\(archived.count))", systemImage: "rectangle.split.3x1")
                            .font(.system(size: Density.small)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 10).frame(height: Density.row)
                }
            }
        }
    }

    private func archivedRow(_ it: AgentBoard.Item) -> some View {
        let s = it.session
        let all = model.connection(for: it.box)?.sessions ?? []
        let chat = it.location.isEmpty
        let route = worktreeRoute(box: it.box, location: it.location, worktree: it.worktree)
        let place = chat ? String(localized: "Conversa")
            : [prefs.displayName(box: it.box, location: it.location), it.worktree].compactMap { $0 }.joined(separator: " › ")
        return SidebarRow(id: "sidebar-archived-\(s.name)", selected: chat ? router.visibleSession == it.id : router.sidebarSelection == .session(route, name: s.name),
                          hovered: $hovered, height: Density.row + 12,
                          action: { if chat { router.openSession(box: it.box, session: s) } else { router.select(.session(route, name: s.name), session: s) } }) {
            AgentGlyph(agent: DisplayNames.agent(of: s), size: Density.glyph).saturation(0).opacity(0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(DisplayNames.sessionName(s, among: all)).font(.system(size: Density.text)).foregroundStyle(Theme.textDim).lineLimit(1)
                HStack(spacing: 4) {
                    Text(place).lineLimit(1)
                    Text("·")
                    Text(s.stateSince ?? s.created, format: .relative(presentation: .named))
                    if s.exited { Text("·"); Text("encerrada") }
                }
                .font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            if !s.exited {
                Button { prefs.setClosed(false, box: it.box, session: s.name) } label: { Label("Desarquivar", systemImage: "tray.and.arrow.up") }
            }
        }
    }

    private func hiddenSection(_ hidden: [ProjectEntry]) -> some View {
        let open = isOpen("hidden", default: false)
        return VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(id: "sidebar-section-Ocultos", open: open || searching, toggle: { toggle("hidden", default: false) }) {
                Image(systemName: "eye.slash")
                Text("Projetos ocultos")
                CountCapsule(count: hidden.count)
            } trailing: { EmptyView() }
            if open || searching {
                ForEach(hidden) { e in
                    let name = prefs.displayName(box: e.box, location: e.location.name)
                    SidebarRow(id: "sidebar-hidden-\(e.location.name)", selected: router.sidebarSelection == .project(e.route), hovered: $hovered,
                               action: { router.select(.project(e.route)) }) {
                        ProjectGlyph(name: name, size: Density.glyph).saturation(0).opacity(0.7)
                        Text(name).font(.system(size: Density.text)).foregroundStyle(Theme.textDim).lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .contextMenu {
                        Button { prefs.setHidden(false, box: e.box, location: e.location.name) } label: { Label("Mostrar", systemImage: "eye") }
                    }
                }
            }
        }
    }

    // MARK: footer

    /// "Nova seção" where the Mac keeps "New Folder" (bottom left), and Ajustes. As tall as the workspace's status bar
    /// (`Density.bar`): their top lines meet across the split.
    private func footer(entries: [ProjectEntry]) -> some View {
        HStack(spacing: 2) {
            Button { startEdit(.newSection(project: nil), text: "") } label: {
                Label("Nova seção", systemImage: "plus.circle")
                    .font(.system(size: Density.small + 1))
                    .padding(.horizontal, 6).frame(height: Density.row - 2)
            }
            .buttonStyle(SidebarButtonStyle(kind: .quiet, radius: 6))
            .disabled(entries.isEmpty)
            .help("Criar uma seção para agrupar projetos")
            .accessibilityIdentifier("sidebar-new-section")
            Spacer(minLength: 4)
            Button { PaletteActions.open(HousekeepingRoute(), router) } label: {
                Image(systemName: "sparkles").font(.system(size: Density.icon)).frame(width: Density.row, height: Density.row - 2)
            }
            .buttonStyle(SidebarButtonStyle(kind: .quiet, radius: 6))
            .help("Faxina (⇧⌘L)")
            .accessibilityLabel("Faxina")
            Button { router.select(.tab(.settings)) } label: {
                Image(systemName: "gearshape").font(.system(size: Density.icon)).frame(width: Density.row, height: Density.row - 2)
            }
            .buttonStyle(SidebarButtonStyle(kind: router.sidebarSelection == .tab(.settings) ? .secondary : .quiet, radius: 6))
            .help("Ajustes (⌘,)")
            .accessibilityLabel("Ajustes")
            .accessibilityAddTraits(router.sidebarSelection == .tab(.settings) ? .isSelected : [])
            .accessibilityIdentifier("sidebar-settings")
        }
        .padding(.horizontal, 8).frame(height: Density.bar)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    // MARK: building blocks

    /// The "+" of a project or worktree row, shown while the pointer is over the row.
    @ViewBuilder private func plus(_ rowID: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        if hovered == rowID {
            Button(action: action) {
                Image(systemName: "plus").font(.system(size: Density.small, weight: .bold)).foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
            .transition(.opacity)
        }
    }

    /// A worktree's route; the main worktree goes by its own name (usually the project's).
    private func worktreeRoute(box: String, location: String, worktree: String?) -> WorktreeRoute {
        let name = worktree ?? model.connection(for: box)?.locations.first { $0.name == location }?.worktrees?.first { $0.main == true }?.name ?? location
        return WorktreeRoute(box: box, location: location, worktree: name)
    }

    // MARK: actions

    private func newTask(box: String? = nil, location: String? = nil, worktree: String? = nil) {
        guard let box = box ?? defaultBox else { return }
        router.select(.tab(.home))
        router.push(ComposeRoute(box: box, location: location, worktree: worktree))
    }

    private func newChat() {
        guard let box = defaultBox else { return }
        PaletteActions.newChat(router, box: box)
    }

    private func moveSection(_ id: UUID, by d: Int) {
        guard let i = prefs.sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard prefs.sections.indices.contains(j) else { return }
        withAnimation(.snappy) { prefs.moveSections(from: IndexSet(integer: i), to: d > 0 ? j + 1 : j) }
    }

    private func moveProject(_ key: String, to section: UUID?) {
        // Already there (the checked item): nothing moves.
        guard prefs.section(of: key) != section else { return }
        let groups = currentGroups()
        guard let g = groups.first(where: { $0.section == section && !isHiddenGroup($0) }) ?? (section == nil ? nil : groups.first { $0.section == section }) else {
            withAnimation(.snappy) { prefs.assign(project: key, to: section) }
            return
        }
        withAnimation(.snappy) {
            prefs.place(project: key, in: section, order: ProjectOrder.moving(key, before: nil, in: g.entries.map(\.key)), reorder: false)
        }
    }

    private func isHiddenGroup(_ g: ProjectGroup) -> Bool { if case .hidden = g.kind { true } else { false } }

    /// The groups as the sidebar shows them right now (what a drop is measured against).
    private func currentGroups() -> [ProjectGroup] {
        ProjectGrouping.groups(entries: ProjectGrouping.entries(in: model.boxes), prefs: prefs,
                               activity: { ProjectGrouping.lastActivity($0, in: model.boxes) }, includeEmptySections: true)
            .filter { !isHiddenGroup($0) }
    }

    /// A project dropped next to another (its group's new order) or into a group; a section next to another.
    private func drop(_ spot: SidebarDropSpot) {
        let groups = currentGroups()
        defer { dragging.end(); dropSpot = nil }
        switch (dragging.item, spot) {
        case (.project(let key)?, .project(let target, let after, let gid)):
            guard let g = groups.first(where: { $0.id == gid }) else { return }
            let shown = g.entries.map(\.key)
            let order = after ? ProjectOrder.moving(key, after: target, in: shown) : ProjectOrder.moving(key, before: target, in: shown)
            guard order != shown || !shown.contains(key) else { return }
            withAnimation(.snappy) { prefs.place(project: key, in: g.section, order: order, reorder: shown.contains(key)) }
        case (.project(let key)?, .into(let gid)):
            guard let g = groups.first(where: { $0.id == gid }) else { return }
            let shown = g.entries.map(\.key)
            guard !shown.contains(key) else { return }
            withAnimation(.snappy) { prefs.place(project: key, in: g.section, order: ProjectOrder.moving(key, before: nil, in: shown), reorder: false) }
            prefs.setSidebarExpanded(gid, true)
        case (.section(let id)?, .section(let target, let after)):
            let ids = prefs.sections.map(\.id)
            let order = after ? ProjectOrder.moving(id, after: target, in: ids) : ProjectOrder.moving(id, before: target, in: ids)
            guard order != ids, let i = order.firstIndex(of: id) else { return }
            withAnimation(.snappy) { prefs.moveSection(id, before: order[safe: i + 1]) }
        case (.section(let id)?, .sectionAtEnd):
            withAnimation(.snappy) { prefs.moveSection(id, before: nil) }
        default:
            break
        }
    }

    // MARK: expansion

    private func isOpen(_ id: String, default value: Bool = true) -> Bool { searching || prefs.isSidebarExpanded(id, default: value) }

    private func toggle(_ id: String, default value: Bool = true) {
        withAnimation(.snappy(duration: 0.2)) { prefs.setSidebarExpanded(id, !prefs.isSidebarExpanded(id, default: value)) }
    }

    private func toggleExpanded(_ key: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        }
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
}

// MARK: - editing and dragging

/// What the sidebar is editing in place.
private enum SidebarEdit: Hashable {
    /// A new section; `project` goes in it ("Mover para → Nova seção…").
    case newSection(project: String?)
    case renameSection(UUID)
    case renameProject(String)
}

/// Where a dragged item would land.
private enum SidebarDropSpot: Equatable {
    /// Right before or after a project of a group (its id).
    case project(String, after: Bool, group: String)
    /// Into a group: dropped on its title or its empty slot.
    case into(group: String)
    /// A section before or after another.
    case section(UUID, after: Bool)
    /// A section after all the others (dropped on "Sem seção").
    case sectionAtEnd
}

/// The item a drag carries: a type of the app's own (declared in project.yml), visible to this process only, so a
/// dragged project never drops as text into a field. Kept in a reference the drop delegates read while the drag runs.
@MainActor private final class SidebarDragging {
    enum Item: Equatable {
        case project(String)
        case section(UUID)
        var isProject: Bool { if case .project = self { true } else { false } }
        var payload: String {
            switch self {
            case .project(let k): "project:\(k)"
            case .section(let id): "section:\(id.uuidString)"
            }
        }
    }

    static let type = UTType(exportedAs: Shared.appBundleID + ".sidebar-item")
    private(set) var item: Item?

    func begin(_ item: Item) -> NSItemProvider {
        self.item = item
        let provider = NSItemProvider()
        let data = Data(item.payload.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    func end() { item = nil }
}

/// One row's (or title's) drop target: where the item would land for the pointer's height in it (top or bottom half),
/// the highlight while it hovers, the drop.
private struct SidebarDropDelegate: DropDelegate {
    /// The height in the target where "before" turns into "after".
    let split: CGFloat
    let dragging: SidebarDragging
    @Binding var spot: SidebarDropSpot?
    let at: @MainActor (_ after: Bool) -> SidebarDropSpot?
    let perform: @MainActor (SidebarDropSpot) -> Void

    @MainActor private func place(_ info: DropInfo) -> SidebarDropSpot? { at(info.location.y > split) }

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragging.item != nil } && info.hasItemsConforming(to: [SidebarDragging.type])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { spot = place(info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            let s = place(info)
            if spot != s { withAnimation(.easeOut(duration: 0.12)) { spot = s } }
            return DropProposal(operation: s == nil ? .forbidden : .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { if spot == place(info) { spot = nil } }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let s = place(info) else { dragging.end(); spot = nil; return false }
            perform(s)
            return true
        }
    }
}

/// A user section's title lifts as a drag (to reorder the sections); "Sem seção" stays put.
private struct SectionDrag: ViewModifier {
    let section: UUID?
    let title: String
    let dragging: SidebarDragging

    func body(content: Content) -> some View {
        if let section {
            content.onDrag { dragging.begin(.section(section)) } preview: { DragChip(symbol: "folder", title: title) }
        } else {
            content
        }
    }
}

/// What follows the pointer during a drag.
private struct DragChip: View {
    var symbol: String? = nil
    var glyph: String? = nil
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            if let glyph { ProjectGlyph(name: glyph, size: Density.glyph) }
            if let symbol { Image(systemName: symbol).font(.system(size: Density.icon)).foregroundStyle(Theme.accent) }
            Text(title).font(.system(size: Density.text, weight: .medium)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: - rows

/// A sidebar row: an optional disclosure chevron, the content as one button into the router (the whole row is the
/// target), an accessory beside it (the "+" under the pointer), the selection and hover fills, and the insertion line
/// of a drag.
private struct SidebarRow<Content: View, Accessory: View>: View {
    let id: String
    let selected: Bool
    @Binding var hovered: String?
    var height: CGFloat = Density.row
    var indent: Int = 0
    var line: VerticalEdge? = nil
    /// nil: no chevron (nothing to show under the row); otherwise whether it is open.
    var disclosure: Bool? = nil
    var toggle: () -> Void = {}
    let action: () -> Void
    var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(id: String, selected: Bool, hovered: Binding<String?>, height: CGFloat = Density.row, indent: Int = 0, line: VerticalEdge? = nil,
         disclosure: Bool? = nil, toggle: @escaping () -> Void = {}, action: @escaping () -> Void,
         accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.selected = selected
        self._hovered = hovered
        self.height = height
        self.indent = indent
        self.line = line
        self.disclosure = disclosure
        self.toggle = toggle
        self.action = action
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        HStack(spacing: 4) {
            chevron
            Button(action: action) {
                HStack(spacing: 7) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(id)
            accessory()
        }
        .padding(.leading, CGFloat(indent) * Density.indent + 2)
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.22) : hovered == id ? Theme.washStrong : .clear)
        }
        .overlay(alignment: line == .bottom ? .bottom : .top) {
            if line != nil { InsertionLine().offset(y: line == .bottom ? 1 : -1) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
    }

    /// The disclosure chevron, or its room (so names line up whether a row opens or not).
    @ViewBuilder private var chevron: some View {
        if let open = disclosure {
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: Density.small - 1, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Recolher" : "Expandir")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }
}

/// A group's title: small and quiet, folds the group on a click, its menu beside it, the drop highlight.
private struct SidebarHeader<Title: View, Trailing: View>: View {
    let id: String
    let open: Bool
    let toggle: () -> Void
    var highlighted = false
    var line: VerticalEdge? = nil
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false
    /// The room above a group's title.
    static var gap: CGFloat { 10 }

    var body: some View {
        // Buttons, not a tap gesture: a tap gesture on the title kept the Mac from lifting it as a drag.
        HStack(spacing: 5) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    title()
                    Spacer(minLength: 4)
                }
                .font(.system(size: Density.small, weight: .semibold))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing().opacity(hovering || !Platform.isMac ? 1 : 0)
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: Density.small - 2, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || !open || !Platform.isMac ? 1 : 0)
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(height: Density.row + 2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? Theme.accent.opacity(0.16) : .clear)
        }
        .overlay(alignment: line == .bottom ? .bottom : .top) {
            if line != nil { InsertionLine() }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .padding(.top, Self.gap)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(id)
        .accessibilityAction(named: open ? Text("Recolher") : Text("Expandir"), toggle)
    }
}

/// Where a dragged project or section would go.
private struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Theme.accent, lineWidth: 1.5).frame(width: 6, height: 6)
            Capsule().fill(Theme.accent).frame(height: 2)
        }
        .padding(.horizontal, 2)
        .allowsHitTesting(false)
    }
}

/// The sidebar's buttons: a fill that answers the pointer (brighter on hover) and the press (darker, a touch smaller).
/// `primary` is the accent "Nova tarefa", `secondary` a tinted square, `quiet` an icon that gets a fill on hover.
private struct SidebarButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, kind: kind, radius: radius) }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        private var fill: Color {
            let pressed = configuration.isPressed
            switch kind {
            case .primary: return pressed ? Theme.accent.opacity(0.78) : hovering ? Theme.accent.opacity(0.9) : Theme.accent
            case .secondary: return pressed ? Theme.accent.opacity(0.24) : hovering ? Theme.accent.opacity(0.15) : Theme.washStrong
            case .quiet: return pressed ? Theme.laneTarget.opacity(2) : hovering ? Theme.washStrong : .clear
            }
        }
        private var tint: Color {
            switch kind {
            case .primary: .white
            case .secondary: hovering || configuration.isPressed ? Theme.accent : Theme.text
            case .quiet: hovering || configuration.isPressed ? Theme.text : Theme.textDim
            }
        }

        var body: some View {
            configuration.label
                .foregroundStyle(tint)
                .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A section title's count, small and quiet ("Produto  3").
private struct CountCapsule: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: Density.small - 1, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.washStrong, in: Capsule())
    }
}

/// A row's count in its color (needs-you on Início, unseen on the Inbox); nothing at zero.
private struct CountBadge: View {
    let count: Int
    let color: Color
    var body: some View {
        if count > 0 {
            Text("\(count)").font(.system(size: Density.small, weight: .bold).monospacedDigit()).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(color.opacity(0.15), in: Capsule())
        }
    }
}

/// The "Trabalhando" title's pulsing dot.
private struct LiveDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.35)).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            .onAppear { pulse = true }
    }
}

/// A sidebar-sized CountPills: a dot per state with its count ("● 2 ● 1").
struct StateDots: View {
    let counts: [DashState: Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach([DashState.needsYou, .working, .done], id: \.self) { s in
                if let n = counts[s], n > 0 {
                    HStack(spacing: 3) {
                        StateDot(state: s)
                        Text("\(n)").font(.system(size: Density.small - 1, weight: .semibold).monospacedDigit()).foregroundStyle(s.color)
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
