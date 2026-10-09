import SwiftUI
import PierKit

/// Root of the "Projetos" tab: projects of every box grouped by the user's own sections.
struct ProjectsRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalPrefs.self) private var prefs
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

    private func activity(_ e: ProjectEntry) -> Int {
        model.connection(for: e.box)?.agentCounts(location: e.location.name).values.reduce(0, +) ?? 0
    }

    var body: some View {
        let entries = ProjectGrouping.entries(in: model.boxes)
        let groups = ProjectGrouping.groups(entries: entries, prefs: prefs, activity: activity, includeEmptySections: editing)
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
                                .onMove { from, to in if case .section(let id) = g.kind { prefs.moveProjects(in: id, from: from, to: to) } }
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
        .searchable(text: $query, prompt: "Buscar projeto")
        .refreshable { await model.refreshAll() }
        .pierBackground()
        .navigationTitle("Projetos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "OK" : "Organizar") { withAnimation { editMode = editing ? .inactive : .active } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !editing {
                    NavigationLink(value: HousekeepingRoute()) { Image(systemName: "sparkles") }
                        .accessibilityLabel("Faxina")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if !editing {
                    Button { newSectionName = ""; newSection = true } label: { Image(systemName: "rectangle.stack.badge.plus") }
                        .accessibilityLabel("Nova seção")
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
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear seção", isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })) {
            TextField("Nome", text: $sectionName)
            Button("Salvar") {
                if case .section(let id)? = renamingSection?.kind, !sectionName.trimmingCharacters(in: .whitespaces).isEmpty { prefs.renameSection(id, to: sectionName) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear projeto", isPresented: Binding(get: { renamingProject != nil }, set: { if !$0 { renamingProject = nil } })) {
            TextField("Nome", text: $projectName)
            Button("Salvar") { if let e = renamingProject { prefs.rename(box: e.box, location: e.location.name, to: projectName) } }
            Button("Restaurar original", role: .destructive) { if let e = renamingProject { prefs.rename(box: e.box, location: e.location.name, to: nil) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("O nome é só deste aparelho; a box não muda.") }
    }

    #if DEBUG
    /// Test hook: `-seedSections 1` puts the projects in two sections (once the projects are loaded; sections an earlier run
    /// left on the simulator are replaced).
    static func seedSectionsIfRequested(prefs: LocalPrefs, boxes: [BoxConnection]) {
        let entries = ProjectGrouping.entries(in: boxes)
        guard UserDefaults.standard.bool(forKey: "seedSections"), prefs.sections.map(\.name) != ["Acme", "Atlas"], !entries.isEmpty else { return }
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
                    Button("Mover para cima") { move(id, by: -1) }
                    Button("Mover para baixo") { move(id, by: 1) }
                    Button("Excluir seção", role: .destructive) { prefs.removeSection(id) }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .textCase(nil).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim)
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
