import SwiftUI
import PierKit

/// A box's projects folder and its spaces (`GET`/`PUT /v1/settings`, `/v1/spaces`): the folder every project lives under,
/// the way a root holds everything pierd does (clones go there, nothing outside it is added or deleted), and the spaces
/// in it, folders that keep groups of projects apart on the disk. Removing a space removes its projects with it; they
/// never move out of it. Docker's state is shown here too: the projects' isolated environments need it.
struct BoxProjectsSettingsScreen: View {
    let box: String

    @Environment(AppModel.self) private var model
    @State private var settings: BoxSettings?
    @State private var root = ""
    @State private var error: String?
    @State private var saving = false
    @State private var newSpace = false
    @State private var spaceName = ""
    @State private var removing: ProjectSpace?

    private var conn: BoxConnection? { model.connection(for: box) }
    private var api: BoxAPI? { conn.map { BoxAPI(transport: $0.raw) } }
    private var rootChanged: Bool { root.trimmingCharacters(in: .whitespaces) != (settings?.projectsRoot ?? "") }

    var body: some View {
        Form {
            Section {
                TextField("~/projetos", text: $root)
                    .font(.mono(15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await saveRoot() } }
                    .accessibilityIdentifier("projects-root-field")
                if rootChanged {
                    Button { Task { await saveRoot() } } label: {
                        HStack { Text("Salvar pasta"); if saving { Spacer(); ProgressView() } }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("projects-root-save")
                }
                if settings?.projectsRoot != nil && !rootChanged {
                    Button("Deixar de usar uma pasta", role: .destructive) { root = ""; Task { await saveRoot() } }
                }
            } header: { Text("Pasta dos projetos") } footer: {
                Text("Todos os projetos desta box ficam dentro dela: os clonados vão para lá, um projeto fora dela não pode ser adicionado e nada fora dela é apagado. Projetos que já estão fora continuam funcionando.")
            }
            .listRowBackground(Theme.card)

            if settings?.projectsRoot != nil {
                Section {
                    if settings?.spaces.isEmpty == true {
                        Text("Nenhum espaço ainda.").font(.subheadline).foregroundStyle(Theme.textDim)
                    }
                    ForEach(settings?.spaces ?? []) { s in
                        HStack {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).foregroundStyle(Theme.text)
                                Text(s.projects == 1 ? String(localized: "1 projeto") : String(localized: "\(s.projects) projetos"))
                                    .font(.caption).foregroundStyle(Theme.textDim)
                            }
                        }
                        .swipeActions { Button("Apagar", role: .destructive) { removing = s } }
                        .contextMenu { Button("Apagar espaço…", role: .destructive) { removing = s } }
                        .accessibilityIdentifier("space-\(s.name)")
                    }
                    Button { spaceName = ""; newSpace = true } label: { Label("Novo espaço", systemImage: "plus.circle") }
                        .accessibilityIdentifier("space-add")
                } header: { Text("Espaços") } footer: {
                    Text("Cada espaço é uma pasta dentro da pasta dos projetos, para manter grupos de projetos separados (um por cliente, por exemplo). Ao clonar, escolha o espaço.")
                }
                .listRowBackground(Theme.card)
            }

            if let d = settings?.docker {
                Section {
                    if d.available {
                        Label("Docker \(d.version ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    } else {
                        Label("Docker indisponível", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                        if let e = d.error { Text(e).font(.caption).foregroundStyle(Theme.textDim).textSelection(.enabled) }
                    }
                } header: { Text("Ambientes isolados") } footer: {
                    Text("Cada projeto pode ter a própria versão de PHP, Node, Python… e os próprios bancos (MySQL, Postgres, Redis) em containers, sem nada disso dentro do projeto. Configure em cada projeto › Ambiente.")
                }
                .listRowBackground(Theme.card)
            }
            if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
        }
        .pierBackground()
        .navigationTitle("Projetos em \(box)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .alert("Novo espaço", isPresented: $newSpace) {
            TextField("nome", text: $spaceName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Criar") { Task { await addSpace() } }.keyboardShortcut(.defaultAction)
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Letras, números, ponto, hífen e sublinhado.") }
        .sheet(item: $removing) { s in RemoveSpaceSheet(box: box, space: s) { Task { await load() } }.environment(model) }
    }

    private func load() async {
        guard let api else { return }
        do {
            let s = try await api.settings()
            settings = s; root = s.projectsRoot ?? ""; error = nil
        } catch { self.error = ComposeErrorText.message(error) }
    }

    private func saveRoot() async {
        guard let api, rootChanged || root.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let s = try await api.setProjectsRoot(root.trimmingCharacters(in: .whitespaces))
            settings = s; root = s.projectsRoot ?? ""; error = nil
            await conn?.refreshLocations()
        } catch { self.error = ComposeErrorText.message(error) }
    }

    private func addSpace() async {
        let n = spaceName.trimmingCharacters(in: .whitespaces)
        guard let api else { return }
        guard Environments.isValidSpace(n) else { error = String(localized: "“\(n)” não serve de nome: use letras, números, ponto, hífen e sublinhado."); return }
        do { _ = try await api.addSpace(name: n); await load() } catch { self.error = ComposeErrorText.message(error) }
    }
}

/// Remove a space: empty, it just goes; with projects, they are removed from the disk with it (after the same checks as
/// removing one project), never moved out.
struct RemoveSpaceSheet: View {
    let box: String
    let space: ProjectSpace
    var onRemoved: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var force = false
    @State private var deleteFiles = false
    @State private var working = false
    @State private var error: String?
    @State private var needsForce = false
    @State private var hasFiles = false

    private var projects: [Location] { model.connection(for: box)?.locations.filter { $0.space == space.name } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(space.name, systemImage: "square.stack.3d.up").font(.headline)
                    MonoText(space.path, size: 11, color: Theme.textFaint)
                    if projects.isEmpty {
                        Text("Nenhum projeto da box neste espaço.").font(.subheadline).foregroundStyle(Theme.textDim)
                    } else {
                        Text("Os projetos dele são apagados da box junto com ele:").font(.subheadline).foregroundStyle(Theme.orange)
                        ForEach(projects) { p in Label(p.name, systemImage: "folder").font(.subheadline) }
                    }
                } footer: {
                    if !projects.isEmpty { Text("Os que estão no GitHub podem ser baixados de volta depois.") }
                }
                .listRowBackground(Theme.card)
                if needsForce || hasFiles {
                    Section {
                        if needsForce { Toggle("Descartar o trabalho não enviado", isOn: $force).tint(Theme.red) }
                        if hasFiles { Toggle("Apagar também o que não é projeto", isOn: $deleteFiles).tint(Theme.red) }
                    }.listRowBackground(Theme.card)
                }
                if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
                Section {
                    Button(role: .destructive) { Task { await remove() } } label: {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Apagar espaço").fontWeight(.semibold) }; Spacer() }
                    }
                    .disabled(working || (needsForce && !force) || (hasFiles && !deleteFiles))
                    .accessibilityIdentifier("space-remove-run")
                }.listRowBackground(Theme.card)
            }
            .pierBackground()
            .navigationTitle("Apagar espaço")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working) } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
    }

    private func remove() async {
        guard let conn = model.connection(for: box) else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let r = try await BoxAPI(transport: conn.raw).removeSpace(name: space.name, purge: !projects.isEmpty, force: force, deleteFiles: deleteFiles)
            await conn.refreshLocations(); await conn.refreshSessions()
            let freed = ByteCountFormatter.string(fromByteCount: r.freed, countStyle: .file)
            model.toast = AppToast(text: String(localized: "Espaço “\(space.name)” apagado (\(freed) liberados)."), symbol: "trash")
            onRemoved()
            dismiss()
        } catch {
            if let e = error as? BoxError {
                if e.code == "unsaved_work" { needsForce = true }
                if e.code == "space_has_files" { hasFiles = true }
            }
            self.error = ComposeErrorText.message(error)
        }
    }
}
