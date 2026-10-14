import SwiftUI
import PierKit

/// Bringing projects onto a box: the GitHub account's repositories (`GET /v1/github/repos`) to download with a tap, and
/// any repository by its link. The box clones it in the background and makes it ready (setup, services); `ClonesStore`
/// follows each clone until it is ready, then reloads the box's projects so the new one appears.

/// The spaces of a box's projects folder, to clone into (empty without a folder or spaces).
@MainActor @Observable
final class SpacesStore {
    static let shared = SpacesStore()
    private(set) var spaces: [String: [ProjectSpace]] = [:]
    private(set) var roots: [String: String] = [:]

    func load(box: String, model: AppModel) async {
        guard let conn = model.connection(for: box), conn.info?.has("environments") == true,
              let s = try? await BoxAPI(transport: conn.raw).settings() else { return }
        spaces[box] = s.spaces
        roots[box] = s.projectsRoot
    }
}

/// Picks the space of the projects folder a clone goes to ("" for the folder itself).
struct SpacePicker: View {
    let box: String
    @Binding var space: String
    @Environment(AppModel.self) private var model
    private let store = SpacesStore.shared

    var body: some View {
        Group {
            if let root = store.roots[box], !(store.spaces[box] ?? []).isEmpty {
                Picker("Espaço", selection: $space) {
                    Text("Nenhum (\((root as NSString).lastPathComponent))").tag("")
                    ForEach(store.spaces[box] ?? []) { Text($0.name).tag($0.name) }
                }
                .accessibilityIdentifier("clone-space")
            }
        }
        .task(id: box) { await store.load(box: box, model: model) }
    }
}

/// The boxes that can clone and remove projects (capability `projects`).
@MainActor func projectBoxes(_ model: AppModel) -> [BoxConnection] {
    model.boxes.filter { $0.info?.has("projects") == true }
}

@MainActor @Observable
final class ClonesStore {
    static let shared = ClonesStore()

    struct Entry: Identifiable, Hashable {
        let box: String
        var clone: ProjectClone
        var id: String { "\(box)/\(clone.id)" }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored weak var model: AppModel?

    var running: [Entry] { entries.filter { $0.clone.isRunning } }

    /// The latest clone of a repository on a box (by owner/name), for the GitHub list's rows.
    func entry(box: String, slug: String) -> Entry? {
        entries.last { $0.box == box && $0.clone.slug?.lowercased() == slug.lowercased() }
    }

    func start(box: String, _ req: CloneRequest, model: AppModel) async throws -> ProjectClone {
        self.model = model
        guard let conn = model.connection(for: box) else { throw PierError.storage("no box") }
        let c = try await BoxAPI(transport: conn.raw).clone(req)
        entries.removeAll { $0.box == box && $0.clone.location == c.location }
        entries.append(Entry(box: box, clone: c))
        poll()
        return c
    }

    /// A clone failed or finished and was looked at: gone from the lists (and from the box's).
    func dismiss(_ e: Entry) {
        entries.removeAll { $0.id == e.id }
        guard let conn = model?.connection(for: e.box) else { return }
        Task { try? await BoxAPI(transport: conn.raw).forgetClone(id: e.clone.id) }
    }

    private func poll() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while let self, !Task.isCancelled, !self.running.isEmpty {
                try? await Task.sleep(for: .seconds(1.2))
                await self.refresh()
            }
            self?.polling = nil
        }
    }

    private func refresh() async {
        guard let model else { return }
        for box in Set(running.map(\.box)) {
            guard let conn = model.connection(for: box), let list = try? await BoxAPI(transport: conn.raw).clones() else { continue }
            var finished = false
            for i in entries.indices where entries[i].box == box {
                guard let now = list.first(where: { $0.id == entries[i].clone.id }) else {
                    // The box no longer knows it (pierd restarted, or an hour went by): it stops here, as failed,
                    // so it can be dismissed or tried again, and the projects are read again in case it finished.
                    if entries[i].clone.isRunning {
                        let c = entries[i].clone
                        entries[i].clone = ProjectClone(id: c.id, repo: c.repo, slug: c.slug, location: c.location, path: c.path, state: .failed,
                                                        error: String(localized: "A box perdeu o andamento deste clone (o pierd reiniciou?). Veja em Projetos se ele chegou."))
                        finished = true
                    }
                    continue
                }
                if entries[i].clone.isRunning && !now.isRunning { finished = true }
                entries[i].clone = now
            }
            if finished { await conn.refreshLocations() }
        }
    }
}

// MARK: the GitHub account's repositories

struct GitHubReposScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var box: String = ""
    @State private var owner: String?
    @State private var result: GitHubRepos?
    @State private var error: Error?
    @State private var loading = false
    @State private var query = ""
    @State private var showArchived = false
    @State private var setup = true
    @State private var space = ""
    @State private var cloneLink = false
    @State private var failure: String?
    /// Repositories whose download was asked for and not answered yet (a second tap does nothing).
    @State private var starting: Set<String> = []
    private let clones = ClonesStore.shared

    private var boxes: [BoxConnection] { projectBoxes(model) }
    private var conn: BoxConnection? { model.connection(for: box) }

    var body: some View {
        NavigationStack {
            List {
                if boxes.count > 1 {
                    Section {
                        Picker("Box", selection: $box) { ForEach(boxes) { Text($0.name).tag($0.name) } }
                    }.listRowBackground(Theme.card)
                }
                if let result, result.owners.count > 1 {
                    Section {
                        Picker("Conta", selection: Binding(get: { owner ?? result.login }, set: { owner = $0 == result.login ? nil : $0 })) {
                            ForEach(result.owners, id: \.self) { Text($0).tag($0) }
                        }
                    }.listRowBackground(Theme.card)
                }
                if let error {
                    Section { problem(error) }.listRowBackground(Theme.card)
                } else if let result {
                    let shown = Projects.filter(result.repos, query: query, showArchived: showArchived)
                    Section {
                        if shown.isEmpty {
                            Text(query.isEmpty ? "Nenhum repositório nesta conta." : "Nada encontrado.")
                                .font(.subheadline).foregroundStyle(Theme.textDim)
                        }
                        ForEach(shown) { repoRow($0) }
                    } header: {
                        SectionHeader(title: "Repositórios", count: shown.count)
                    } footer: {
                        Text(setup ? "Ao baixar, a box instala as dependências e inicia os serviços do projeto." : "Ao baixar, a box só clona o repositório.")
                    }
                    Section {
                        SpacePicker(box: box, space: $space)
                        Toggle("Configurar o ambiente ao baixar", isOn: $setup)
                        Toggle("Mostrar arquivados", isOn: $showArchived)
                    }.listRowBackground(Theme.card)
                } else if loading {
                    HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar repositório")
            .refreshable { await load() }
            .pierBackground()
            .navigationTitle("Repositórios do GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .primaryAction) {
                    Button { cloneLink = true } label: { Label("Clonar por link", systemImage: "link.badge.plus") }
                        .accessibilityIdentifier("clone-by-link")
                }
            }
            .onChange(of: box) { owner = nil; space = ""; result = nil }
            .task(id: "\(box)|\(owner ?? "")") {
                if box.isEmpty { box = boxes.first?.name ?? ""; if box.isEmpty { return } }
                await load()
            }
            .sheet(isPresented: $cloneLink) { CloneLinkSheet(initialBox: box) { dismiss() }.environment(model).environment(router) }
            .alert("Não foi possível baixar", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
        .presentationBackground(Theme.bg)
    }

    private func load() async {
        guard let conn else { return }
        loading = true
        defer { loading = false }
        do {
            result = try await BoxAPI(transport: conn.raw).gitHubRepos(owner: owner)
            error = nil
        } catch {
            self.error = error
        }
    }

    @ViewBuilder private func problem(_ error: Error) -> some View {
        let code = (error as? BoxError)?.code
        VStack(alignment: .leading, spacing: 8) {
            switch code {
            case "gh_missing":
                Label("O GitHub CLI (gh) não está instalado na box", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                Text("Instale o gh na box e entre na sua conta com `gh auth login`. Enquanto isso, dá para clonar pelo link.")
                    .font(.subheadline).foregroundStyle(Theme.textDim)
            case "gh_auth":
                Label("O gh não está conectado a uma conta", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(Theme.orange)
                Text("Rode `gh auth login` na box (em um terminal do app, por exemplo) e puxe para atualizar.")
                    .font(.subheadline).foregroundStyle(Theme.textDim)
            default:
                Label("Não foi possível listar os repositórios", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text(ComposeErrorText.message(error)).font(.subheadline).foregroundStyle(Theme.textDim).textSelection(.enabled)
            }
            Button("Clonar por link") { cloneLink = true }.buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func repoRow(_ r: GitHubRepo) -> some View {
        let here = Projects.location(for: r, in: conn?.locations ?? [])
        let job = clones.entry(box: box, slug: r.slug)
        Button {
            if let here {
                dismiss()
                router.select(.project(ProjectRoute(box: box, location: here.name)))
            } else if job?.clone.isRunning != true, !starting.contains(r.slug) {
                Task { await download(r) }
            }
        } label: {
            HStack(spacing: 12) {
                ProjectGlyph(name: r.name, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(r.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if r.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.textFaint) }
                        if r.fork { Image(systemName: "tuningfork").font(.caption2).foregroundStyle(Theme.textFaint) }
                        if r.archived { Image(systemName: "archivebox").font(.caption2).foregroundStyle(Theme.textFaint) }
                    }
                    if let d = r.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2) }
                    HStack(spacing: 6) {
                        if let l = r.language { Text(l) }
                        if r.language != nil, r.updatedAt != nil { Text("·") }
                        if let u = r.updatedAt { Text(u, format: .relative(presentation: .named)) }
                    }
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                    if let job, job.clone.state == .failed, here == nil {
                        Text(job.clone.error ?? String(localized: "Falhou")).font(.caption2).foregroundStyle(Theme.red).lineLimit(3)
                    }
                }
                Spacer(minLength: 6)
                trailing(here: here, job: job)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.card)
        .accessibilityIdentifier("github-repo-\(r.name)")
    }

    @ViewBuilder private func trailing(here: Location?, job: ClonesStore.Entry?) -> some View {
        if here != nil {
            Text("Na box").font(.caption.weight(.semibold)).foregroundStyle(Theme.green)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.green.opacity(0.12), in: Capsule())
        } else if let job, job.clone.isRunning {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView().controlSize(.small)
                Text(job.clone.state == .cloning ? "Baixando" : "Configurando").font(.caption2).foregroundStyle(Theme.textDim)
            }
        } else {
            Image(systemName: job?.clone.state == .failed ? "arrow.clockwise.circle" : "arrow.down.circle")
                .font(.title2).foregroundStyle(Theme.accent)
                .accessibilityLabel("Baixar")
        }
    }

    private func download(_ r: GitHubRepo) async {
        starting.insert(r.slug)
        defer { starting.remove(r.slug) }
        do { _ = try await clones.start(box: box, CloneRequest(repo: r.slug, space: space.isEmpty ? nil : space, setup: setup), model: model) }
        catch { failure = ComposeErrorText.message(error) }
    }
}

// MARK: clone by link

struct CloneLinkSheet: View {
    var initialBox: String = ""
    /// Called once the clone started and the person chose to leave (the screen under it may close too).
    var onStarted: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var box = ""
    @State private var link = ""
    @State private var name = ""
    @State private var space = ""
    /// Off for a pasted link: setting up runs the repository's own config, so it is the person's choice for a repository
    /// that may not be theirs (the GitHub list, their own account's, sets up by default).
    @State private var setup = false
    @State private var working = false
    @State private var error: String?
    @State private var started: ClonesStore.Entry?
    private let clones = ClonesStore.shared

    private var boxes: [BoxConnection] { projectBoxes(model) }
    /// The clone this sheet started, as it is now.
    private var current: ClonesStore.Entry? { started.flatMap { s in clones.entries.first { $0.id == s.id } } ?? started }

    var body: some View {
        NavigationStack {
            Form {
                if let current {
                    progress(current)
                } else {
                    Section {
                        TextField("https://github.com/dono/repositorio", text: $link)
                            .font(.mono(15)).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onSubmit { if canClone { Task { await clone() } } }
                            .accessibilityIdentifier("clone-link-field")
                        Button { if let s = UIPasteboard.general.string { link = s.trimmingCharacters(in: .whitespacesAndNewlines) } } label: {
                            Label("Colar", systemImage: "doc.on.clipboard")
                        }
                    } header: { Text("Link do repositório") } footer: {
                        Text("dono/repositório, a página no GitHub ou a URL de clone (https ou ssh). Repositórios privados usam o login do gh ou as chaves ssh da box.")
                    }
                    .listRowBackground(Theme.card)
                    Section {
                        TextField("Nome do projeto (opcional)", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if boxes.count > 1 {
                            Picker("Box", selection: $box) { ForEach(boxes) { Text($0.name).tag($0.name) } }
                        }
                        SpacePicker(box: box, space: $space)
                        Toggle("Configurar o ambiente", isOn: $setup)
                    } footer: {
                        Text(setup ? "Depois de clonar, a box roda o setup do projeto (o .pier/config.json dele, ou o que ela reconhecer: npm, pnpm, pip, bundler…) e inicia o servidor de desenvolvimento na porta da worktree. Só ative para repositórios em que você confia."
                                   : "A box só clona; nada do repositório roda.")
                    }
                    .listRowBackground(Theme.card)
                    if let error { Section { Text(error).foregroundStyle(Theme.red).font(.subheadline) }.listRowBackground(Theme.card) }
                }
            }
            .pierBackground()
            .navigationTitle("Clonar repositório")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(current == nil ? "Cancelar" : "Fechar") { if current != nil { onStarted() }; dismiss() }.keyboardShortcut(.cancelAction)
                }
                if current == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if working { ProgressView() } else {
                            Button("Clonar") { Task { await clone() } }.disabled(!canClone).keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("clone-start")
                        }
                    }
                }
            }
            .task { if box.isEmpty { box = boxes.contains(where: { $0.name == initialBox }) ? initialBox : boxes.first?.name ?? "" } }
            .onChange(of: box) { space = "" }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
        .interactiveDismissDisabled(working)
    }

    private var canClone: Bool { !working && !box.isEmpty && Projects.isRepoLink(link) }

    private func clone() async {
        working = true; error = nil
        defer { working = false }
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            let c = try await clones.start(box: box, CloneRequest(repo: link.trimmingCharacters(in: .whitespacesAndNewlines), name: n.isEmpty ? nil : n, space: space.isEmpty ? nil : space, setup: setup), model: model)
            started = ClonesStore.Entry(box: box, clone: c)
        } catch { self.error = ComposeErrorText.message(error) }
    }

    @ViewBuilder private func progress(_ e: ClonesStore.Entry) -> some View {
        Section {
            CloneStatusRow(entry: e)
        }.listRowBackground(Theme.card)
        if e.clone.state == .ready {
            Section {
                Button {
                    dismiss(); onStarted()
                    router.select(.project(ProjectRoute(box: e.box, location: e.clone.location)))
                } label: { Label("Abrir projeto", systemImage: "folder").font(.body.weight(.semibold)) }
                .accessibilityIdentifier("clone-open")
            }.listRowBackground(Theme.card)
        } else if e.clone.state == .failed {
            Section {
                Button { started = nil } label: { Label("Tentar de novo", systemImage: "arrow.clockwise") }
            }.listRowBackground(Theme.card)
        } else {
            Section {
                Text("Pode fechar: a box continua e o projeto aparece em Projetos quando ficar pronto.").font(.footnote).foregroundStyle(Theme.textDim)
            }.listRowBackground(Color.clear)
        }
    }
}

/// One clone and where it is: downloading, setting up, ready (with what made it ready) or failed (with why).
struct CloneStatusRow: View {
    let entry: ClonesStore.Entry

    var body: some View {
        let c = entry.clone
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                switch c.state {
                case .cloning, .settingUp: ProgressView().controlSize(.small)
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.location).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                Text(stateText(c)).font(.caption).foregroundStyle(c.state == .failed ? Theme.red : Theme.textDim)
                    .textSelection(.enabled).lineLimit(c.state == .failed ? 8 : 2)
                MonoText(c.path, size: 11, color: Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("clone-\(c.location)")
    }

    private func stateText(_ c: ProjectClone) -> String {
        switch c.state {
        case .cloning: return String(localized: "Baixando o repositório…")
        case .settingUp: return String(localized: "Configurando o ambiente…")
        case .failed: return c.error ?? String(localized: "Falhou")
        case .ready:
            let services = c.services.joined(separator: ", ")
            switch c.setup {
            case "repo": return services.isEmpty ? String(localized: "Pronto, com o setup do próprio repositório.")
                                                 : String(localized: "Pronto, com o setup do repositório. Serviços: \(services).")
            case "detected": return services.isEmpty ? String(localized: "Pronto: dependências instaladas.")
                                                     : String(localized: "Pronto: dependências instaladas e \(services) rodando.")
            default: return String(localized: "Pronto.")
            }
        }
    }
}
