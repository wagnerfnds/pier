import SwiftUI
import PierKit

// The workspace on the iPhone, one screen at a time on the navigation stack: a folder's files (a folder opens the next
// screen), a file in the editor, the history, a commit and one of its patches. The same stores as the iPad and the
// Mac's workspace (`WorkspaceState`), so what is typed and not saved is the same everywhere.

/// One folder of a worktree.
struct FilesRoute: Hashable {
    let ref: WorkspaceRef
    var folder = ""
}

/// One file in the editor.
struct FileEditorRoute: Hashable {
    let ref: WorkspaceRef
    let path: String
}

/// The worktree's commits.
struct HistoryRoute: Hashable {
    let ref: WorkspaceRef
}

/// One commit: its message and files.
struct CommitRoute: Hashable {
    let ref: WorkspaceRef
    let sha: String
}

/// One file's patch in a commit.
struct CommitFileRoute: Hashable {
    let ref: WorkspaceRef
    let sha: String
    let file: String
    var from: String? = nil
}

struct CompactFolderScreen: View {
    let route: FilesRoute
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var state: WorkspaceState

    init(route: FilesRoute) {
        self.route = route
        _state = State(initialValue: WorkspaceState.of(route.ref))
    }

    private var tree: FileTreeStore { state.tree }

    var body: some View {
        List {
            if tree.unsupported {
                EmptyState(symbol: "shippingbox.and.arrow.backward", title: "Esta box precisa de um pierd mais novo")
                    .listRowBackground(Color.clear)
            } else if let entries = tree.listings[route.folder] {
                ForEach(entries.filter { !(tree.hideIgnored && $0.ignored) }) { e in
                    let path = FileTree.join(route.folder, e.name)
                    if e.isFolder {
                        NavigationLink(value: FilesRoute(ref: route.ref, folder: path)) { row(e) }
                    } else if e.isFile {
                        NavigationLink(value: FileEditorRoute(ref: route.ref, path: path)) { row(e) }
                    } else {
                        row(e)
                    }
                }
                if entries.isEmpty { Text("Pasta vazia").foregroundStyle(Theme.textDim) }
            } else if case .failed(let m) = tree.state, route.folder.isEmpty {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível ler os arquivos", message: LocalizedStringKey(m))
                    .listRowBackground(Color.clear)
            } else {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .refreshable { await tree.load(route.folder) }
        .pierBackground()
        .navigationTitle(route.folder.isEmpty ? route.ref.worktree : FileTree.name(of: route.folder))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { tree.hideIgnored.toggle() } label: { Image(systemName: tree.hideIgnored ? "eye.slash" : "eye") }
                    .accessibilityLabel("Arquivos ignorados")
            }
        }
        .task {
            state.bind(model)
            await tree.load(route.folder)
        }
    }

    private func row(_ e: FileEntry) -> some View {
        let badge = FileTree.badge(e.status)
        return HStack(spacing: 10) {
            FileIcon(name: e.name, folder: e.isFolder, link: e.type == .link)
            Text(e.name).foregroundStyle(e.ignored ? Theme.textFaint : Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge.rawValue).font(.mono(12, weight: .bold)).foregroundStyle(badge.color)
            } else if e.changed {
                Circle().fill(Theme.orange.opacity(0.8)).frame(width: 6, height: 6)
            }
        }
        .accessibilityIdentifier("compact-file-\(e.name)")
    }
}

/// A file in the editor, full screen: Salvar in the toolbar, the same conflict handling as the workspace.
struct CompactFileScreen: View {
    let route: FileEditorRoute
    @Environment(AppModel.self) private var model
    @State private var state: WorkspaceState
    @State private var conflict = false
    @State private var saveError: String?

    init(route: FileEditorRoute) {
        self.route = route
        _state = State(initialValue: WorkspaceState.of(route.ref))
    }

    private var editor: EditorStore { state.editor }
    private var doc: EditorDoc? { editor.doc(route.path) }

    var body: some View {
        Group {
            if let doc {
                switch doc.state {
                case .loaded where doc.editable:
                    CodeEditor(doc: doc, open: Set(editor.docs.map(\.path)), container: state.editorView,
                               onChange: { editor.setText($0, for: doc.path) },
                               onSelection: { editor.setSelection($0, text: $1, for: doc.path) })
                case .failed(let m):
                    EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível abrir o arquivo", message: LocalizedStringKey(m))
                case .loaded:
                    EmptyState(symbol: doc.tooLarge ? "doc.badge.ellipsis" : "doc.zipper",
                               title: doc.tooLarge ? "Arquivo grande demais para abrir aqui" : "Arquivo binário")
                default:
                    ProgressView().tint(Theme.accent)
                }
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pierBackground()
        .navigationTitle(FileTree.name(of: route.path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if doc?.dirty == true {
                    Button { Task { await editor.revert(route.path) } } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Descartar alterações")
                }
                Button {
                    Task {
                        switch await editor.save(route.path) {
                        case .saved: break
                        case .conflict: conflict = true
                        case .failed(let m): if !m.isEmpty { saveError = m }
                        }
                    }
                } label: {
                    if doc?.saving == true { ProgressView() } else { Text("Salvar").fontWeight(.semibold) }
                }
                .disabled(doc?.dirty != true || doc?.saving == true)
                .accessibilityIdentifier("editor-save")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if doc?.deleted == true {
                Label(doc?.dirty == true ? String(localized: "Este arquivo foi apagado na box. Salvar o cria de novo com o que você digitou.")
                                         : String(localized: "Este arquivo foi apagado na box."), systemImage: "trash")
                    .font(.footnote).foregroundStyle(Theme.text)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.red.opacity(0.14))
            } else if doc?.changedOnBox == true {
                Label("Este arquivo mudou na box depois que você o abriu (um agente pode tê-lo editado).", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.text)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.orange.opacity(0.14))
            }
        }
        .alert("O arquivo mudou na box", isPresented: $conflict) {
            Button("Salvar por cima") { Task { await editor.save(route.path, force: true) } }
            Button("Recarregar da box", role: .destructive) { Task { await editor.revert(route.path) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Alguém (talvez um agente) mudou este arquivo depois que você o abriu. Salvar por cima descarta a versão da box; recarregar descarta o que você digitou.") }
        .alert("Não foi possível salvar", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
        .task {
            state.bind(model)
            editor.open(route.path)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await editor.poll()
            }
        }
    }
}

/// The worktree's commits, newest first.
struct CompactHistoryScreen: View {
    let route: HistoryRoute
    @Environment(AppModel.self) private var model
    @State private var state: WorkspaceState

    init(route: HistoryRoute) {
        self.route = route
        _state = State(initialValue: WorkspaceState.of(route.ref))
    }

    private var history: HistoryStore { state.history }

    var body: some View {
        List {
            if case .failed(let m) = history.state, history.entries.isEmpty {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível ler o histórico", message: LocalizedStringKey(m))
                    .listRowBackground(Color.clear)
            } else if history.state == .loaded && history.entries.isEmpty {
                EmptyState(symbol: "clock", title: "Nenhum commit ainda", message: "Esta branch ainda não tem commits.")
                    .listRowBackground(Color.clear)
            }
            ForEach(history.entries) { e in
                NavigationLink(value: CommitRoute(ref: route.ref, sha: e.sha)) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if e.unpushed { Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.green).font(.caption) }
                            Text(e.subject).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(2)
                        }
                        HStack(spacing: 5) {
                            Text(e.short).font(.mono(11)).foregroundStyle(Theme.accent)
                            Text(e.author).lineLimit(1)
                            if let d = e.date { Text("·"); Text(d, format: .relative(presentation: .named)) }
                        }
                        .font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
                .onAppear { if e.sha == history.entries.last?.sha { Task { await history.loadMore() } } }
            }
            if history.loadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
        }
        .listStyle(.plain)
        .overlay { if history.state == .loading && history.entries.isEmpty { ProgressView().tint(Theme.accent) } }
        .refreshable { await history.load() }
        .pierBackground()
        .navigationTitle("Histórico")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            state.bind(model)
            if history.state != .loaded { await history.load() }
        }
    }
}

/// One commit: message, who and when, its files.
struct CompactCommitScreen: View {
    let route: CommitRoute
    @Environment(AppModel.self) private var model
    @State private var state: WorkspaceState

    init(route: CommitRoute) {
        self.route = route
        _state = State(initialValue: WorkspaceState.of(route.ref))
    }

    var body: some View {
        let detail = state.history.details[route.sha]
        List {
            if let d = detail {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.entry.subject).font(.headline).foregroundStyle(Theme.text)
                        if !d.body.isEmpty { Text(d.body).font(.subheadline).foregroundStyle(Theme.textDim) }
                        HStack(spacing: 5) {
                            Text(d.entry.short).font(.mono(12)).foregroundStyle(Theme.accent)
                            Text(d.entry.author)
                            if let date = d.entry.date { Text("·"); Text(date, format: .dateTime.day().month().hour().minute()) }
                        }
                        .font(.caption).foregroundStyle(Theme.textDim)
                    }
                    .textSelection(.enabled)
                }
                Section {
                    ForEach(d.files) { f in
                        NavigationLink(value: CommitFileRoute(ref: route.ref, sha: route.sha, file: f.path, from: f.from)) {
                            HStack {
                                Text(f.status).font(.mono(12, weight: .bold)).foregroundStyle(f.status == "A" ? Theme.green : f.status == "D" ? Theme.red : Theme.orange)
                                    .frame(width: 18)
                                Text(f.from.map { "\($0) → \(f.path)" } ?? f.path).font(.subheadline).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 4)
                                if let a = f.added, let r = f.removed { PlusMinus(added: a, removed: r, size: 11) }
                            }
                        }
                    }
                } header: { Text(d.files.count == 1 ? String(localized: "1 arquivo") : String(localized: "\(d.files.count) arquivos")) }
            } else if let e = state.history.detailErrors[route.sha] {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível ler este commit", message: LocalizedStringKey(e))
                    .listRowBackground(Color.clear)
                HStack {
                    Spacer()
                    Button("Tentar de novo") { Task { await state.history.loadDetail(route.sha) } }.buttonStyle(.bordered)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await state.history.loadDetail(route.sha) }
        .pierBackground()
        .navigationTitle(String(route.sha.prefix(7)))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            state.bind(model)
            if detail == nil { await state.history.loadDetail(route.sha) }
        }
    }
}

/// One file's patch in a commit.
struct CompactCommitFileScreen: View {
    let route: CommitFileRoute
    @State private var wrap = true

    var body: some View {
        PatchView(box: route.ref.box, execLocation: route.ref.execLocation,
                  command: GitLog.fileDiffCommand(sha: route.sha, path: route.file, from: route.from), path: route.file, wrap: wrap) {
            EmptyView()
        }
        .pierBackground()
        .navigationTitle(FileTree.name(of: route.file))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
                    .accessibilityLabel("Quebrar linhas")
            }
        }
    }
}
