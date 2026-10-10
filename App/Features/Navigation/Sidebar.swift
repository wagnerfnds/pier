import SwiftUI
import PierKit

/// The regular-width sidebar (iPad, Mac), top to bottom:
/// - "Nova tarefa" / "Nova conversa" and the app's sections;
/// - **Trabalhando**: every worktree with an agent that needs the person or is working, pinned above the rest
///   (`SidebarRules.working`), so the live work is one tap away whatever section its project sits in;
/// - Conversas (agents tied to no project);
/// - the projects in the person's sections, each expandable to its worktrees and their sessions. Projects are dragged
///   between sections (or onto a section's title), and every row has its menu: new task, new worktree, rename, move, hide;
/// - **Arquivadas**: sessions archived on the device or exited on the box; hidden projects; Ajustes.
/// Sections fold and stay folded (`LocalPrefs.sidebarExpanded`). The highlight is the router's, so a session opened
/// elsewhere moves it too.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LocalPrefs.self) private var prefs
    /// Expanded projects ("box/location") and worktrees ("box/location/worktree").
    @State private var expanded: Set<String> = []
    @State private var seeded = false
    /// Filters projects, worktrees (name or branch) and agent sessions; matches open by themselves.
    @State private var query = ""
    /// The row under the pointer (iPad pointer, Mac): it shows its "+".
    @State private var hovered: String?
    /// The row a dragged project would land before ("box/location"), or a section's title ("section:<id>").
    @State private var dropTarget: String?

    @State private var newSection = false
    /// A project to put in the section being created ("Mover para… → Nova seção…").
    @State private var newSectionProject: String?
    @State private var newSectionName = ""
    @State private var renamingSection: UUID?
    @State private var sectionName = ""
    @State private var renamingProject: ProjectEntry?
    @State private var projectName = ""
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
        let all = ProjectGrouping.groups(entries: entries, prefs: prefs, activity: activity, includeEmptySections: !searching)
        let groups = all
            .filter { if case .hidden = $0.kind { false } else { true } }
            .map { g -> ProjectGroup in var g = g; g.entries = g.entries.filter { visibleWorktrees($0) != nil }; return g }
            .filter { !$0.entries.isEmpty || (!searching && $0.isSection) }
        let hidden = all.first { if case .hidden = $0.kind { true } else { false } }?.entries
            .filter { !searching || hit(prefs.displayName(box: $0.box, location: $0.location.name)) || hit($0.location.name) } ?? []
        let sessions = items
        let working = searching ? [] : SidebarRules.working(sessions, archived: isArchived, background: Set(signals.background.keys))
        let archived = SidebarRules.archived(sessions, archived: isArchived)
            .filter { !searching || hit($0.session.title) || hit($0.session.name) || hit($0.location) }
        let chats = chatSessions
        // Rows are buttons into the router, not a List selection: the split view resets the detail's stack when its
        // selection changes, which drops the project / worktree / session path the router sets.
        List {
            content(entries: entries, groups: groups, hidden: hidden, working: working, archived: archived, chats: chats)
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 26)
        .listSectionSpacing(.compact)
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
        .alert("Nova seção", isPresented: $newSection) {
            TextField("Nome", text: $newSectionName)
            Button("Criar") { createSection() }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Arraste projetos para ela, ou use “Mover para…” no menu de um projeto.") }
        .alert("Renomear seção", isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })) {
            TextField("Nome", text: $sectionName)
            Button("Salvar") {
                if let id = renamingSection, !sectionName.trimmingCharacters(in: .whitespaces).isEmpty { prefs.renameSection(id, to: sectionName) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear projeto", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("Nome", text: $projectName)
            Button("Salvar") { if let e = renamingProject { prefs.rename(box: e.box, location: e.location.name, to: projectName) } }
            Button("Restaurar original", role: .destructive) { if let e = renamingProject { prefs.rename(box: e.box, location: e.location.name, to: nil) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("O nome é só deste aparelho; a box não muda.") }
        .sheet(item: $newWorktree) { e in
            NewWorktreeSheet(box: e.box, location: e.location) { wt in
                expanded.insert(e.key)
                router.select(.worktree(WorktreeRoute(box: e.box, location: e.location.name, worktree: wt.name)))
            }
        }
    }

    @ViewBuilder private func content(entries: [ProjectEntry], groups: [ProjectGroup], hidden: [ProjectEntry],
                                      working: [SidebarRules.ActiveWorktree], archived: [AgentBoard.Item], chats: [BoxSession]) -> some View {
        if !searching {
            Section { quickActions.listRowBackground(Color.clear) }
            Section { sectionRows }
            if !working.isEmpty { workingSection(working) }
        }
        if !chats.isEmpty {
            Section(isExpanded: open("chats")) {
                ForEach(chats) { chat($0) }
            } header: {
                header("Conversas", count: chats.count, id: "sidebar-section-Conversas")
            }
        }
        if searching && groups.isEmpty && chats.isEmpty && archived.isEmpty && hidden.isEmpty {
            Text("Nada encontrado").font(.subheadline).foregroundStyle(Theme.textDim).listRowBackground(Color.clear)
        }
        ForEach(groups) { g in projectSection(g) }
        if entries.isEmpty, model.boxes.contains(where: { $0.state == .connecting }) {
            HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
        }
        if !searching && !entries.isEmpty {
            Button { newSectionProject = nil; newSectionName = ""; newSection = true } label: {
                Label("Nova seção", systemImage: "plus.rectangle.on.folder").font(.subheadline).foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-new-section")
        }
        if !archived.isEmpty { archivedSection(archived) }
        if !hidden.isEmpty { hiddenSection(hidden) }
        if !searching {
            Section { pickable(.tab(.settings), id: "sidebar-settings") { Label("Ajustes", systemImage: "gearshape") } }
        }
    
    }

    // MARK: top

    /// "Nova tarefa" (⌘N) as the sidebar's primary action, a new chat (⇧⌘N) and the rest of what can be created.
    private var quickActions: some View {
        HStack(spacing: 8) {
            Button { newTask() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.subheadline.weight(.bold))
                    Text("Nova tarefa").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12).frame(height: 32)
            }
            .buttonStyle(SidebarButtonStyle(kind: .primary))
            .disabled(defaultBox == nil)
            .help("Nova tarefa (⌘N)")
            .accessibilityIdentifier("sidebar-new-task")

            Button { newChat() } label: {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 32)
            }
            .buttonStyle(SidebarButtonStyle(kind: .secondary))
            .disabled(defaultBox == nil)
            .help("Nova conversa (⇧⌘N)")
            .accessibilityLabel("Nova conversa")
            .accessibilityIdentifier("sidebar-new-chat")

            Menu {
                Button { newTask() } label: { Label("Nova tarefa", systemImage: "plus.bubble") }
                Button { newChat() } label: { Label("Nova conversa", systemImage: "bubble.left.and.text.bubble.right") }
                let projects = ProjectGrouping.entries(in: model.boxes).filter { !prefs.isHidden(box: $0.box, location: $0.location.name) }
                if !projects.isEmpty {
                    Menu {
                        ForEach(projects) { e in
                            Button(prefs.displayName(box: e.box, location: e.location.name)) { newWorktree = e }
                        }
                    } label: { Label("Nova worktree", systemImage: "arrow.triangle.branch") }
                }
                Divider()
                Button { newSectionProject = nil; newSectionName = ""; newSection = true } label: { Label("Nova seção", systemImage: "plus.rectangle.on.folder") }
                Button { router.select(.tab(.projects)) } label: { Label("Organizar projetos", systemImage: "folder.badge.gearshape") }
                Button { PaletteActions.open(HousekeepingRoute(), router) } label: { Label("Faxina", systemImage: "sparkles") }
            } label: {
                Image(systemName: "ellipsis").font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.button).buttonStyle(SidebarButtonStyle(kind: .quiet))
            .accessibilityLabel("Criar")
            .accessibilityIdentifier("sidebar-create-menu")
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    @ViewBuilder private var sectionRows: some View {
        pickable(.tab(.home), id: "sidebar-home") {
            // The count inside the label (not `.badge`), so it sits within the selection highlight.
            HStack {
                Label("Início", systemImage: "square.grid.2x2")
                Spacer(minLength: 4)
                CountBadge(count: model.sessionsStore.needsYouCount, color: Theme.orange)
            }
        }
        pickable(.tab(.inbox), id: "sidebar-inbox") {
            HStack {
                Label("Inbox", systemImage: "tray")
                Spacer(minLength: 4)
                CountBadge(count: InboxStore.shared.unseenCount(model: model), color: Theme.accent)
            }
        }
        pickable(.tab(.board), id: "sidebar-board") { Label("Quadro", systemImage: "rectangle.split.3x1") }
        pickable(.tab(.projects), id: "sidebar-projects") { Label("Projetos", systemImage: "folder") }
    }

    // MARK: Trabalhando

    private func workingSection(_ working: [SidebarRules.ActiveWorktree]) -> some View {
        Section(isExpanded: open("working")) {
            ForEach(working) { activeRow($0) }
        } header: {
            HStack(spacing: 6) {
                LiveDot(color: working.contains(where: \.needsYou) ? Theme.orange : Theme.accent)
                Text("Trabalhando")
                CountCapsule(count: working.count)
                Spacer()
            }
            .accessibilityIdentifier("sidebar-section-Trabalhando")
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
        let id = "sidebar-active-\(a.id)"
        pickable(item, id: id, session: single ? first.session : nil, action: a.isChat ? { router.openSession(box: a.box, session: first.session) } : nil) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    if a.isChat { AgentGlyph(agent: DisplayNames.agent(of: first.session), size: 26) }
                    else { ProjectGlyph(name: project, size: 26) }
                    StateDot(state: a.needsYou ? .needsYou : .working)
                        .padding(2).background(Circle().fill(Theme.bg)).offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        // The main worktree goes by the project's name already: no "sandbox · sandbox".
                        if !a.isChat && title != project { Text(project).foregroundStyle(Theme.textFaint); Text("·").foregroundStyle(Theme.textFaint) }
                        activity(of: a)
                    }
                    .font(.caption).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !single { CountCapsule(count: a.items.count) }
            }
            .padding(.vertical, 1)
        }
        .contextMenu {
            if !a.isChat {
                Button { router.select(.worktree(route)) } label: { Label("Abrir worktree", systemImage: "arrow.triangle.branch") }
                Button { newTask(box: a.box, location: a.location, worktree: a.worktree) } label: { Label("Nova tarefa nesta worktree", systemImage: "plus.bubble") }
            }
        }
        if !single {
            ForEach(a.items) { it in
                pickable(.session(route, name: it.session.name), id: "sidebar-active-session-\(it.session.name)", session: it.session) {
                    HStack(spacing: 8) {
                        AgentGlyph(agent: DisplayNames.agent(of: it.session), size: 18)
                        Text(DisplayNames.sessionName(it.session, among: all)).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        if let st = DashState(it.session) { StateDot(state: st) }
                    }
                    .padding(.leading, 36)
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

    // MARK: projects

    @ViewBuilder private func projectSection(_ g: ProjectGroup) -> some View {
        let section: UUID? = if case .section(let id) = g.kind { id } else { nil }
        let dropID = "section:\(g.id)"
        Section(isExpanded: open(g.id)) {
            ForEach(g.entries) { project($0, section: section) }
            if g.entries.isEmpty {
                Text("Arraste projetos para cá").font(.caption).foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(dropTarget == dropID ? Theme.accent : Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .padding(.horizontal, -8)
                    }
                    .dropDestination(for: String.self) { keys, _ in drop(keys, in: section, before: nil) } isTargeted: { target(dropID, $0) }
            }
        } header: {
            HStack(spacing: 6) {
                Text(g.title)
                if !g.entries.isEmpty { CountCapsule(count: g.entries.count) }
                Spacer(minLength: 4)
                if let section { sectionMenu(section, title: g.title) }
            }
            .padding(.vertical, 2)
            .background {
                if dropTarget == dropID {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(0.15)).padding(.horizontal, -6)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { keys, _ in drop(keys, in: section, before: nil) } isTargeted: { target(dropID, $0) }
            .accessibilityIdentifier("sidebar-section-\(g.title)")
        }
    }

    private func sectionMenu(_ id: UUID, title: String) -> some View {
        let i = prefs.sections.firstIndex { $0.id == id }
        return Menu {
            Button { sectionName = title; renamingSection = id } label: { Label("Renomear", systemImage: "pencil") }
            Button { moveSection(id, by: -1) } label: { Label("Mover para cima", systemImage: "arrow.up") }.disabled(i == 0)
            Button { moveSection(id, by: 1) } label: { Label("Mover para baixo", systemImage: "arrow.down") }.disabled(i == prefs.sections.count - 1)
            Divider()
            Button(role: .destructive) { prefs.removeSection(id) } label: { Label("Excluir seção", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.caption.weight(.bold))
                .frame(width: 24, height: 20)
        }
        .menuStyle(.button).buttonStyle(SidebarButtonStyle(kind: .quiet, radius: 6))
        .accessibilityLabel("Opções da seção \(title)")
    }

    @ViewBuilder private func project(_ e: ProjectEntry, section: UUID?) -> some View {
        let name = prefs.displayName(box: e.box, location: e.location.name)
        let conn = model.connection(for: e.box)
        let worktrees = visibleWorktrees(e) ?? []
        let id = "sidebar-project-\(e.location.name)"
        DisclosureGroup(isExpanded: expansion(e.key)) {
            ForEach(worktrees) { wt in worktree(wt, in: e, conn: conn) }
        } label: {
            pickable(.project(e.route), id: id, accessory: { plus(id, help: "Nova tarefa em \(name)") { newTask(box: e.box, location: e.location.name) } }) {
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
            .overlay(alignment: .top) {
                if dropTarget == e.key {
                    Capsule().fill(Theme.accent).frame(height: 2).offset(y: -6).padding(.horizontal, -6)
                }
            }
            .draggable(e.key) {
                HStack(spacing: 8) { ProjectGlyph(name: name, size: 22); Text(name).font(.subheadline.weight(.medium)) }
                    .padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: String.self) { keys, _ in drop(keys, in: section, before: e.key) } isTargeted: { target(e.key, $0) }
            // A still preview: the row's pulsing dots would keep the menu's preview animating.
            .contextMenu { projectMenu(e, name: name) } preview: {
                HStack(spacing: 10) {
                    ProjectGlyph(name: name, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.headline)
                        Text(e.worktreeCount == 1 ? String(localized: "1 worktree") : String(localized: "\(e.worktreeCount) worktrees"))
                            .font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
                .padding(14).frame(minWidth: 220, alignment: .leading).background(Theme.card)
            }
        }
        .listRowInsets(rowInsets)
    }

    @ViewBuilder private func projectMenu(_ e: ProjectEntry, name: String) -> some View {
        Button { newTask(box: e.box, location: e.location.name) } label: { Label("Nova tarefa aqui", systemImage: "plus.bubble") }
        Button { newWorktree = e } label: { Label("Nova worktree…", systemImage: "arrow.triangle.branch") }
        Divider()
        Button { projectName = name; renamingProject = e } label: { Label("Renomear…", systemImage: "pencil") }
        Menu {
            ForEach(prefs.sections) { s in
                Button { prefs.assign(project: e.key, to: s.id) } label: {
                    if prefs.section(of: e.key) == s.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Button { prefs.assign(project: e.key, to: nil) } label: {
                if prefs.section(of: e.key) == nil { Label("Sem seção", systemImage: "checkmark") } else { Text("Sem seção") }
            }
            Divider()
            Button { newSectionProject = e.key; newSectionName = ""; newSection = true } label: { Label("Nova seção…", systemImage: "plus") }
        } label: { Label("Mover para…", systemImage: "folder") }
        Button { prefs.setHidden(true, box: e.box, location: e.location.name) } label: { Label("Ocultar", systemImage: "eye.slash") }
    }

    @ViewBuilder private func worktree(_ wt: Worktree, in e: ProjectEntry, conn: BoxConnection?) -> some View {
        let route = WorktreeRoute(box: e.box, location: e.location.name, worktree: wt.name)
        let ref = e.location.ref(wt)
        let sessions = (searching && !hit(wt.name) && !hit(wt.branch) && !sessionHits(e, wt).isEmpty ? sessionHits(e, wt)
                        : (conn?.sessions ?? []).filter { $0.location == ref && listed($0, box: e.box) })
            .sorted { $0.created > $1.created }
        let id = "sidebar-worktree-\(e.location.name)/\(wt.name)"
        let label = pickable(.worktree(route), id: id, accessory: {
            plus(id, help: "Iniciar agente em \(wt.name)") { newTask(box: e.box, location: e.location.name, worktree: wt.main == true ? nil : wt.name) }
        }) {
            HStack(spacing: 8) {
                Image(systemName: wt.main == true ? "arrow.triangle.branch" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).foregroundStyle(Theme.textDim).frame(width: 18)
                Text(wt.name).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                StateDots(counts: conn?.agentCounts(ref: ref) ?? [:])
            }
        }
        .contextMenu {
            Button { newTask(box: e.box, location: e.location.name, worktree: wt.main == true ? nil : wt.name) } label: {
                Label("Iniciar agente aqui", systemImage: "sparkles")
            }
            Button { router.select(.worktree(route)) } label: { Label("Abrir worktree", systemImage: "arrow.right.circle") }
        }
        if sessions.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: expansion("\(e.key)/\(wt.name)")) {
                ForEach(sessions) { s in session(s, box: e.box, in: route, all: conn?.sessions ?? []) }
            } label: { label }
            .listRowInsets(rowInsets)
        }
    }

    private func session(_ s: Session, box: String, in route: WorktreeRoute, all: [Session]) -> some View {
        pickable(.session(route, name: s.name), id: "sidebar-session-\(s.name)", session: s) {
            HStack(spacing: 8) {
                AgentGlyph(agent: DisplayNames.agent(of: s), size: 20)
                Text(DisplayNames.sessionName(s, among: all)).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                if let st = DashState(s) { StateDot(state: st) }
            }
        }
        .contextMenu {
            if s.agentState != .running && s.agentState != .waiting {
                Button { prefs.setClosed(true, box: box, session: s.name) } label: { Label("Arquivar (terminei aqui)", systemImage: "archivebox") }
            }
        }
    }

    // MARK: Conversas

    /// Live chats (agents tied to no project), newest first; while searching, those whose title or name matches.
    private var chatSessions: [BoxSession] {
        model.boxes.flatMap { b in b.sessions.filter { $0.chat && listed($0, box: b.name) }.map { BoxSession(box: b.name, session: $0) } }
            .filter { !searching || hit($0.session.title) || hit($0.session.name) }
            .sorted { $0.session.created > $1.session.created }
    }

    /// A chat has no project or worktree to sit under: it opens on Início's stack, like a session picked there.
    private func chat(_ bs: BoxSession) -> some View {
        let s = bs.session
        let all = model.connection(for: bs.box)?.sessions ?? []
        return pickable(nil, id: "sidebar-chat-\(s.name)", selected: router.visibleSession == bs.id,
                        action: { router.openSession(box: bs.box, session: s) }) {
            HStack(spacing: 8) {
                AgentGlyph(agent: DisplayNames.agent(of: s), size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DisplayNames.sessionName(s, among: all)).font(.subheadline).lineLimit(1)
                    if multiBox { Text(bs.box).font(.caption2).foregroundStyle(Theme.textFaint) }
                }
                Spacer(minLength: 4)
                if let st = DashState(s) { StateDot(state: st) }
            }
        }
        .contextMenu {
            if s.agentState != .running && s.agentState != .waiting {
                Button { prefs.setClosed(true, box: bs.box, session: s.name) } label: { Label("Arquivar", systemImage: "archivebox") }
            }
        }
    }

    // MARK: Arquivadas, ocultos

    private func archivedSection(_ archived: [AgentBoard.Item]) -> some View {
        Section(isExpanded: open("archived", default: false)) {
            ForEach(archived.prefix(archivedLimit)) { archivedRow($0) }
            if archived.count > archivedLimit {
                Button { router.select(.tab(.board)) } label: {
                    Label("Ver todas no Quadro (\(archived.count))", systemImage: "rectangle.split.3x1").font(.caption).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                Text("Arquivadas")
                CountCapsule(count: archived.count)
                Spacer()
            }
            .accessibilityIdentifier("sidebar-section-Arquivadas")
        }
    }

    private func archivedRow(_ it: AgentBoard.Item) -> some View {
        let s = it.session
        let all = model.connection(for: it.box)?.sessions ?? []
        let chat = it.location.isEmpty
        let route = worktreeRoute(box: it.box, location: it.location, worktree: it.worktree)
        let place = chat ? String(localized: "Conversa")
            : [prefs.displayName(box: it.box, location: it.location), it.worktree].compactMap { $0 }.joined(separator: " › ")
        return pickable(chat ? nil : .session(route, name: s.name), id: "sidebar-archived-\(s.name)", session: s,
                        action: chat ? { router.openSession(box: it.box, session: s) } : nil) {
            HStack(spacing: 8) {
                AgentGlyph(agent: DisplayNames.agent(of: s), size: 20).saturation(0).opacity(0.7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DisplayNames.sessionName(s, among: all)).font(.subheadline).foregroundStyle(Theme.textDim).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(place).lineLimit(1)
                        Text("·")
                        Text(s.stateSince ?? s.created, format: .relative(presentation: .named))
                        if s.exited { Text("·"); Text("encerrada") }
                    }
                    .font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            if !s.exited {
                Button { prefs.setClosed(false, box: it.box, session: s.name) } label: { Label("Desarquivar", systemImage: "tray.and.arrow.up") }
            }
        }
    }

    private func hiddenSection(_ hidden: [ProjectEntry]) -> some View {
        Section(isExpanded: open("hidden", default: false)) {
            ForEach(hidden) { e in
                let name = prefs.displayName(box: e.box, location: e.location.name)
                pickable(.project(e.route), id: "sidebar-hidden-\(e.location.name)") {
                    HStack(spacing: 10) {
                        ProjectGlyph(name: name, size: 22).saturation(0).opacity(0.7)
                        Text(name).font(.subheadline).foregroundStyle(Theme.textDim).lineLimit(1)
                        Spacer(minLength: 4)
                    }
                }
                .contextMenu {
                    Button { prefs.setHidden(false, box: e.box, location: e.location.name) } label: { Label("Mostrar", systemImage: "eye") }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                Text("Projetos ocultos")
                CountCapsule(count: hidden.count)
                Spacer()
            }
            .accessibilityIdentifier("sidebar-section-Ocultos")
        }
    }

    // MARK: building blocks

    private func header(_ title: LocalizedStringKey, count: Int, id: String) -> some View {
        HStack(spacing: 6) { Text(title); CountCapsule(count: count); Spacer() }.accessibilityIdentifier(id)
    }

    /// Rows sit close together; the label carries the vertical room (see `pickable`).
    private var rowInsets: EdgeInsets { EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 12) }

    /// A pickable row: a button into the router (or `action`), highlighted while the detail shows that item.
    /// `accessory` sits beside it, outside the button (the "+" that shows under the pointer).
    private func pickable(_ item: SidebarItem?, id: String, session: Session? = nil, selected: Bool? = nil,
                          action: (() -> Void)? = nil, accessory: () -> some View = { EmptyView() },
                          @ViewBuilder label: () -> some View) -> some View {
        let isSelected = selected ?? (item.map { router.sidebarSelection == $0 } ?? false)
        return HStack(spacing: 4) {
            Button {
                if let action { action() } else if let item { router.select(item, session: session) }
            } label: {
                // The vertical room is the label's, not the row's: the whole row is the target, with no gap between rows.
                label().padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(id)
            accessory()
        }
        // Drawn behind the label, reaching into the row's insets: a row background is ignored by DisclosureGroup labels and
        // by the Mac sidebar.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.22))
                    .padding(.horizontal, -8)
            } else if hovered == id {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.washStrong)
                    .padding(.horizontal, -8)
            }
        }
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .listRowInsets(rowInsets)
    }

    /// The "+" of a project or worktree row, shown while the pointer is over the row.
    @ViewBuilder private func plus(_ rowID: String, help: String, action: @escaping () -> Void) -> some View {
        if hovered == rowID {
            Button(action: action) {
                Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
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

    private func createSection() {
        let name = newSectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        prefs.addSection(name)
        if let key = newSectionProject, let id = prefs.sections.last?.id { prefs.assign(project: key, to: id) }
        newSectionProject = nil
    }

    private func moveSection(_ id: UUID, by d: Int) {
        guard let i = prefs.sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard prefs.sections.indices.contains(j) else { return }
        withAnimation { prefs.moveSections(from: IndexSet(integer: i), to: d > 0 ? j + 1 : j) }
    }

    /// A project dropped on a section's title (`before` nil: at its end) or on another project (right before it).
    private func drop(_ keys: [String], in section: UUID?, before: String?) -> Bool {
        let known = Set(ProjectGrouping.entries(in: model.boxes).map(\.key))
        let moving = keys.filter { known.contains($0) }
        guard !moving.isEmpty else { return false }
        withAnimation {
            for k in moving { prefs.place(project: k, in: section, before: before) }
        }
        dropTarget = nil
        return true
    }

    private func target(_ id: String, _ on: Bool) {
        if on { dropTarget = id } else if dropTarget == id { dropTarget = nil }
    }

    // MARK: expansion

    /// A section's fold, kept across launches; while searching everything is open.
    private func open(_ id: String, default value: Bool = true) -> Binding<Bool> {
        Binding(get: { searching || prefs.isSidebarExpanded(id, default: value) }, set: { prefs.setSidebarExpanded(id, $0) })
    }

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

/// The sidebar's buttons: a fill that answers the pointer (brighter on hover) and the press (darker, a touch smaller).
/// `primary` is the accent "Nova tarefa", `secondary` a tinted square, `quiet` an icon that gets a fill on hover.
private struct SidebarButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind
    var radius: CGFloat = 9

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
                .overlay {
                    if kind == .primary && hovering {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.25))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

private extension ProjectGroup {
    var isSection: Bool { if case .section = kind { true } else { false } }
}

/// A section title's count, small and quiet ("Produto  3").
private struct CountCapsule: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.washStrong, in: Capsule())
    }
}

/// A row's count in its color (needs-you on Início, unseen on the Inbox); nothing at zero.
private struct CountBadge: View {
    let count: Int
    let color: Color
    var body: some View {
        if count > 0 {
            Text("\(count)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 2)
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
