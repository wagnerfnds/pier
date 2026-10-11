import SwiftUI
import PierKit

/// Root of the "Projetos" tab: projects of every box grouped by the user's own sections. On the iPhone a list to
/// organise them; where there is room (iPad, Mac), where the sidebar already organises them, a grid of cards that open
/// each project's workspace.
struct ProjectsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var editMode: EditMode = .inactive
    @State private var showHidden = false
    @State private var newSection = false
    @State private var newSectionName = ""
    @State private var renamingSection: ProjectGroup?
    @State private var sectionName = ""
    @State private var renamingProject: ProjectEntry?
    @State private var projectName = ""

    private var editing: Bool { editMode == .active }
    private var multiBox: Bool { model.boxes.count > 1 }

    private func activity(_ e: ProjectEntry) -> Date? { ProjectGrouping.lastActivity(e, in: model.boxes) }

    var body: some View {
        let entries = ProjectGrouping.entries(in: model.boxes)
        let groups = ProjectGrouping.groups(entries: entries, prefs: prefs, activity: activity, includeEmptySections: editing)
        Group {
            if sizeClass == .regular { grid(entries: entries, groups: groups) } else { list(entries: entries, groups: groups) }
        }
        .searchable(text: $query, prompt: "Buscar projeto")
        .refreshable { await model.refreshAll() }
        .pierBackground()
        .navigationTitle("Projetos")
        .toolbar {
            if sizeClass != .regular {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "OK" : "Organizar") { withAnimation { editMode = editing ? .inactive : .active } }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !editing {
                    NavigationLink(value: HousekeepingRoute()) { Image(systemName: "sparkles") }
                        .accessibilityLabel("Faxina")
                }
            }
            if sizeClass != .regular {
                ToolbarItem(placement: .topBarLeading) {
                    if !editing {
                        Button { newSectionName = ""; newSection = true } label: { Image(systemName: "rectangle.stack.badge.plus") }
                            .accessibilityLabel("Nova seção")
                    }
                }
            }
        }
        #if DEBUG
        .task {
            Self.seedSectionsIfRequested(prefs: prefs, boxes: model.boxes)
            if UserDefaults.standard.bool(forKey: "projectsEdit") { editMode = .active }
        }
        #endif
        .alert("Nova seção", isPresented: $newSection) {
            TextField("Nome", text: $newSectionName)
            Button("Criar") { let n = newSectionName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { prefs.addSection(n) } }
                .keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear seção", isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })) {
            TextField("Nome", text: $sectionName)
            Button("Salvar") {
                if case .section(let id)? = renamingSection?.kind, !sectionName.trimmingCharacters(in: .whitespaces).isEmpty { prefs.renameSection(id, to: sectionName) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear projeto", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("Nome", text: $projectName)
            Button("Salvar") { if let e = renamingProject { prefs.rename(box: e.box, location: e.location.name, to: projectName) } }
                .keyboardShortcut(.defaultAction)
            Button("Restaurar original", role: .destructive) { if let e = renamingProject { prefs.rename(box: e.box, location: e.location.name, to: nil) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("O nome é só deste aparelho; a box não muda.") }
    }

    // MARK: grid (iPad, Mac)

    @ViewBuilder private func grid(entries: [ProjectEntry], groups: [ProjectGroup]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 12, alignment: .top)]
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if !query.isEmpty {
                    let hits = entries.filter { ProjectGrouping.matches($0, query, display: prefs.displayName(box: $0.box, location: $0.location.name)) }
                    if hits.isEmpty { EmptyState(symbol: "magnifyingglass", title: "Nada encontrado") }
                    LazyVGrid(columns: columns, spacing: 12) { ForEach(hits) { card($0) } }
                } else if entries.isEmpty {
                    if model.boxes.allSatisfy({ $0.state != .connecting }) {
                        EmptyState(symbol: "folder", title: "Nenhum projeto", message: "Adicione repositórios na box (pierd) para vê-los aqui.")
                    } else {
                        HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    }
                } else {
                    ForEach(groups) { g in
                        let hidden: Bool = if case .hidden = g.kind { true } else { false }
                        VStack(alignment: .leading, spacing: 10) {
                            Button { if hidden { withAnimation { showHidden.toggle() } } } label: {
                                HStack(spacing: 6) {
                                    if hidden { Image(systemName: showHidden ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)) }
                                    Text(g.title)
                                    Text("\(g.entries.count)").foregroundStyle(Theme.textFaint)
                                }
                                .font(.system(size: Density.small + 1, weight: .semibold)).foregroundStyle(Theme.textDim)
                            }
                            .buttonStyle(.plain).disabled(!hidden)
                            if !hidden || showHidden {
                                LazyVGrid(columns: columns, spacing: 12) { ForEach(g.entries) { card($0) } }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func card(_ e: ProjectEntry) -> some View {
        ProjectCard(entry: e, showBox: multiBox, lastActivity: activity(e)) { router.select(.project(e.route)) }
            .contextMenu { fullMenu(e) }
    }

    // MARK: list (iPhone)

    private func list(entries: [ProjectEntry], groups: [ProjectGroup]) -> some View {
        List {
            if !query.isEmpty {
                let hits = entries.filter { ProjectGrouping.matches($0, query, display: prefs.displayName(box: $0.box, location: $0.location.name)) }
                Section { ForEach(hits) { row($0) } }
                if hits.isEmpty { EmptyState(symbol: "magnifyingglass", title: "Nada encontrado").listRowBackground(Color.clear) }
            } else if entries.isEmpty {
                if model.boxes.allSatisfy({ $0.state != .connecting }) {
                    EmptyState(symbol: "folder", title: "Nenhum projeto", message: "Adicione repositórios na box (pierd) para vê-los aqui.")
                        .listRowBackground(Color.clear)
                } else {
                    HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
                }
            } else {
                ForEach(groups) { g in
                    if case .hidden = g.kind {
                        hiddenSection(g)
                    } else {
                        Section {
                            ForEach(g.entries) { row($0, in: g) }
                                .onMove { from, to in prefs.moveProjects(in: g.section, shown: g.entries.map(\.key), from: from, to: to) }
                            if g.entries.isEmpty && editing {
                                Text("Seção vazia. Use “Mover para…” em um projeto.").font(.footnote).foregroundStyle(Theme.textFaint)
                                    .listRowBackground(Theme.card)
                            }
                        } header: { sectionHeader(g) }
                    }
                }
                if editing {
                    Section {
                        Button { newSectionName = ""; newSection = true } label: { Label("Nova seção", systemImage: "plus.circle.fill") }
                            .listRowBackground(Theme.card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
    }

    #if DEBUG
    /// Test hook: `-seedSections 1` puts the projects in two sections, once a launch (when the projects are loaded): what
    /// an earlier run left on the simulator is replaced, what this run does to them is kept.
    private static var seeded = false
    static func seedSectionsIfRequested(prefs: LocalPrefs, boxes: [BoxConnection]) {
        let entries = ProjectGrouping.entries(in: boxes)
        guard UserDefaults.standard.bool(forKey: "seedSections"), !seeded, !entries.isEmpty else { return }
        seeded = true
        if UITestShowcase.enabled {
            // The showcase's four projects in two sections (screenshots of the sidebar and the Projects tab).
            let names = [UITestShowcase.t("Product", "Produto"), UITestShowcase.t("Platform", "Plataforma")]
            for s in prefs.sections { prefs.removeSection(s.id) }
            prefs.addSection(names[0]); prefs.addSection(names[1])
            for e in entries {
                let n = e.location.name
                prefs.assign(project: e.key, to: n == "storefront" || n == "mobile-app" ? prefs.sections[0].id : prefs.sections[1].id)
            }
            return
        }
        for s in prefs.sections { prefs.removeSection(s.id) }
        prefs.addSection("Acme"); prefs.addSection("Atlas")
        for e in entries {
            let n = e.location.name
            if n.hasPrefix("acme") || n == "acme-api" || n == "admin-mobile" { prefs.assign(project: e.key, to: prefs.sections[0].id) }
            else if n.hasPrefix("atlas") { prefs.assign(project: e.key, to: prefs.sections[1].id) }
        }
        prefs.setHidden(true, box: boxes.first?.name ?? "", location: "leads-app")
        prefs.rename(box: boxes.first?.name ?? "", location: "acme", to: "Acme (plataforma)")
    }
    #endif

    // MARK: pieces

    @ViewBuilder private func sectionHeader(_ g: ProjectGroup) -> some View {
        HStack {
            Text(g.title)
            if !g.entries.isEmpty { Text("\(g.entries.count)").foregroundStyle(Theme.textFaint) }
            Spacer()
            if editing, case .section(let id) = g.kind {
                Button { sectionName = g.title; renamingSection = g } label: { Image(systemName: "pencil") }
                Menu {
                    sortPicker(g)
                    Button("Mover para cima") { move(id, by: -1) }
                    Button("Mover para baixo") { move(id, by: 1) }
                    Button("Excluir seção", role: .destructive) { prefs.removeSection(id) }
                } label: { Image(systemName: "ellipsis.circle") }
            } else if editing, case .unsorted = g.kind {
                Menu { sortPicker(g) } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                    .accessibilityLabel("Ordenar projetos")
            }
        }
        .textCase(nil).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim)
    }

    /// By hand (dragging in "Organizar"), by name or by recent activity.
    private func sortPicker(_ g: ProjectGroup) -> some View {
        Picker(selection: Binding(get: { g.sort }, set: { prefs.setSort($0, of: g.section, shown: g.entries.map(\.key)) })) {
            Label("Manualmente", systemImage: "hand.draw").tag(ProjectSort.manual)
            Label("Por nome", systemImage: "textformat").tag(ProjectSort.name)
            Label("Por atividade recente", systemImage: "clock").tag(ProjectSort.activity)
        } label: { Label("Ordenar projetos", systemImage: "arrow.up.arrow.down") }
        .pickerStyle(.menu)
    }

    private func move(_ id: UUID, by d: Int) {
        guard let i = prefs.sections.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard prefs.sections.indices.contains(j) else { return }
        prefs.moveSections(from: IndexSet(integer: i), to: d > 0 ? j + 1 : j)
    }

    @ViewBuilder private func hiddenSection(_ g: ProjectGroup) -> some View {
        Section {
            if showHidden || !query.isEmpty { ForEach(g.entries) { row($0, in: g) } }
        } header: {
            Button { withAnimation { showHidden.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showHidden ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold))
                    Text(g.title); Text("\(g.entries.count)").foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .textCase(nil).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim)
            }
        }
    }

    @ViewBuilder private func row(_ e: ProjectEntry, in group: ProjectGroup? = nil) -> some View {
        let rowView = ProjectRow(entry: e, showBox: multiBox)
        Group {
            if editing {
                HStack { rowView; projectMenu(e) }
            } else {
                NavigationLink(value: e.route) { rowView }
            }
        }
        .listRowBackground(Theme.card)
        .swipeActions(edge: .trailing) {
            if prefs.isHidden(box: e.box, location: e.location.name) {
                Button { prefs.setHidden(false, box: e.box, location: e.location.name) } label: { Label("Mostrar", systemImage: "eye") }.tint(Theme.accent)
            } else {
                Button { prefs.setHidden(true, box: e.box, location: e.location.name) } label: { Label("Ocultar", systemImage: "eye.slash") }.tint(Theme.gray)
            }
        }
        .swipeActions(edge: .leading) {
            Button { projectName = prefs.displayName(box: e.box, location: e.location.name); renamingProject = e } label: { Label("Renomear", systemImage: "pencil") }.tint(Theme.orange)
        }
        .contextMenu { fullMenu(e) }
    }

    @ViewBuilder private func fullMenu(_ e: ProjectEntry) -> some View {
        Button { projectName = prefs.displayName(box: e.box, location: e.location.name); renamingProject = e } label: { Label("Renomear", systemImage: "pencil") }
        moveMenu(e)
        if prefs.isHidden(box: e.box, location: e.location.name) {
            Button { prefs.setHidden(false, box: e.box, location: e.location.name) } label: { Label("Mostrar", systemImage: "eye") }
        } else {
            Button { prefs.setHidden(true, box: e.box, location: e.location.name) } label: { Label("Ocultar", systemImage: "eye.slash") }
        }
    }

    private func moveMenu(_ e: ProjectEntry) -> some View {
        Menu {
            ForEach(prefs.sections) { s in
                Button { prefs.assign(project: e.key, to: s.id) } label: {
                    if prefs.section(of: e.key) == s.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Button { prefs.assign(project: e.key, to: nil) } label: {
                if prefs.section(of: e.key) == nil { Label("Sem seção", systemImage: "checkmark") } else { Text("Sem seção") }
            }
        } label: { Label("Mover para…", systemImage: "folder.badge.gearshape") }
    }

    private func projectMenu(_ e: ProjectEntry) -> some View {
        Menu { fullMenu(e) } label: { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.accent) }
            .buttonStyle(.plain)
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    let entry: ProjectEntry
    var showBox = false

    var body: some View {
        let name = prefs.displayName(box: entry.box, location: entry.location.name)
        let counts = model.connection(for: entry.box)?.agentCounts(location: entry.location.name) ?? [:]
        HStack(spacing: 12) {
            ProjectGlyph(name: name)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    if showBox { Text(entry.box).foregroundStyle(Theme.textDim); Text("·").foregroundStyle(Theme.textFaint) }
                    Text(entry.worktreeCount == 1 ? String(localized: "1 worktree") : String(localized: "\(entry.worktreeCount) worktrees"))
                        .foregroundStyle(Theme.textDim)
                    if name != entry.location.name {
                        Text("·").foregroundStyle(Theme.textFaint)
                        Text(entry.location.name).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 4)
            CountPills(counts: counts)
        }
        .padding(.vertical, 3)
    }
}

/// A project as a card of the grid (iPad, Mac): its glyph and name, worktrees, agents at work and last activity.
struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
    let entry: ProjectEntry
    var showBox = false
    var lastActivity: Date?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let name = prefs.displayName(box: entry.box, location: entry.location.name)
        let counts = model.connection(for: entry.box)?.agentCounts(location: entry.location.name) ?? [:]
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ProjectGlyph(name: name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: Density.text + 1, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(entry.location.slug ?? entry.location.name).font(.system(size: Density.small)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if WorkspaceRegistry.shared.hasUnsaved(box: entry.box, location: entry.location.name) {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.textDim).help("Arquivos não salvos")
                    }
                }
                // Always the same room, so the cards of a row line up.
                Group {
                    if counts.values.contains(where: { $0 > 0 }) { CountPills(counts: counts) }
                    else { Text("Nenhum agente agora").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint) }
                }
                .frame(height: 22, alignment: .leading)
                HStack(spacing: 6) {
                    Label(entry.worktreeCount == 1 ? String(localized: "1 worktree") : String(localized: "\(entry.worktreeCount) worktrees"),
                          systemImage: "arrow.triangle.branch")
                    if let lastActivity { Text("·"); Text(lastActivity, format: .relative(presentation: .named)) }
                    if showBox { Text("·"); Text(entry.box) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: Density.small)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Theme.accent.opacity(0.6) : Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityIdentifier("project-card-\(entry.location.name)")
    }
}

struct ProjectGlyph: View {
    let name: String
    var size: CGFloat = 38
    private var color: Color {
        let palette: [UInt32] = [0x4A99FA, 0x4CC38A, 0xF5A35C, 0xB07CE8, 0xE5675F, 0x5CC8D6, 0xE0C050]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(tone: palette[h % palette.count])
    }
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}
