import SwiftUI
import PierKit

/// Arquivos: the worktree's tree on the left (folders open in place, git's status beside each file, "Abrir rápido" on
/// top), the open files on the right in tabs, each in the code editor.
struct FilesPane: View {
    let state: WorkspaceState

    var body: some View {
        if state.tree.unsupported {
            UnsupportedBox()
        } else {
            SplitPane(key: "workspace.tree", initial: 260, minLeading: 190, minTrailing: 360) {
                FileTreePane(state: state)
            } trailing: {
                EditorPane(state: state)
            }
        }
    }
}

/// A box whose pierd predates the file routes.
private struct UnsupportedBox: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward").font(.system(size: 34)).foregroundStyle(Theme.textFaint)
            Text("Esta box precisa de um pierd mais novo").font(.headline).foregroundStyle(Theme.text)
            Text("O pierd desta box ainda não tem as rotas de arquivos. Atualize-o com o build deste repositório (Server/pierd) para navegar e editar os arquivos daqui. Alterações e Histórico já funcionam.")
                .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - tree

private struct FileTreePane: View {
    let state: WorkspaceState
    @State private var query = ""
    @State private var picked = 0
    @FocusState private var searchFocused: Bool
    /// The folder a new file is being named in ("" for the root), in place at the top of the tree.
    @State private var creatingIn: String?
    @State private var newName = ""
    @State private var createError: String?
    @FocusState private var newFocused: Bool

    private var tree: FileTreeStore { state.tree }
    private var editor: EditorStore { state.editor }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var results: [String] { searching ? FileSearch.search(query, in: tree.searchable) : [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if searching {
                    searchResults
                } else {
                    treeList
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.card)
        .onChange(of: state.quickOpenRequested, initial: true) { _, requested in
            guard requested else { return }
            state.quickOpenRequested = false
            // The editor is a UIKit text view SwiftUI's focus does not take the keyboard from: let it go first.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            Task { @MainActor in searchFocused = true }
        }
        .task(id: query) {
            // A repository too large to list whole: git looks for what is typed.
            if searching { await tree.match(query) }
        }
    }

    /// "Abrir rápido", and beside it what the tree does: a new file, and a menu with the ignored files, collapse and
    /// reload. On top, not in a bar at the bottom: the workspace's status bar is the window's only bottom bar.
    private var header: some View {
        HStack(spacing: 2) {
            searchField
            toolButton("doc.badge.plus", help: "Novo arquivo", label: "Novo arquivo") {
                startNewFile(in: editor.active.map(FileTree.parent(of:)) ?? "")
            }
            .accessibilityIdentifier("tree-new-file")
            Menu {
                Toggle(isOn: Binding(get: { !tree.hideIgnored }, set: { tree.hideIgnored = !$0 })) {
                    Label("Mostrar arquivos ignorados pelo git", systemImage: "eye")
                }
                Button { withAnimation(.snappy(duration: 0.15)) { tree.open.removeAll() } } label: {
                    Label("Recolher tudo", systemImage: "rectangle.compress.vertical")
                }
                Divider()
                Button { Task { await tree.refresh() } } label: { Label("Recarregar", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: Density.small + 1))
                    .frame(width: 26, height: Density.row + 2)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
            .tint(Theme.textDim)
            .help("Mais")
            .accessibilityLabel("Mais")
            .accessibilityIdentifier("tree-menu")
        }
        .padding(8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint)
            TextField("Abrir rápido…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Density.text - 1))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .onSubmit { openPicked() }
                .onKeyPress(.downArrow) { picked = min(picked + 1, max(0, results.count - 1)); return .handled }
                .onKeyPress(.upArrow) { picked = max(picked - 1, 0); return .handled }
                .onKeyPress(.escape) { query = ""; searchFocused = false; return .handled }
                .onChange(of: query) { picked = 0; if searching { Task { await tree.loadAllFiles() } } }
                .accessibilityIdentifier("workspace-quick-open")
            if searching {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }
                    .buttonStyle(.plain)
                    // Esc clears the search on the Mac too, where the field takes Esc to give up its focus.
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Limpar")
            } else if Platform.isMac {
                Text(verbatim: "⇧⌘O").font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 8).frame(height: Density.row + 2)
        .background(Theme.washStrong, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private var treeList: some View {
        switch tree.state {
        case .failed(let m) where tree.listings[""] == nil:
            EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível ler os arquivos", message: LocalizedStringKey(m))
        case .loading where tree.listings[""] == nil, .idle where tree.listings[""] == nil:
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let folder = creatingIn { newFileRow(in: folder) }
                    ForEach(tree.rows) { row in
                        FileTreeRow(row: row, open: tree.open.contains(row.path), loading: tree.loading.contains(row.path),
                                    selected: editor.active == row.path) {
                            if row.entry.isFolder { withAnimation(.snappy(duration: 0.15)) { tree.toggle(row.path) } }
                            else if row.entry.isFile { editor.open(row.path) }
                        }
                        .contextMenu { menu(row) }
                    }
                    if tree.truncated.contains("") {
                        Text("Pasta com arquivos demais: nem todos aparecem.").font(.system(size: Density.small)).foregroundStyle(Theme.orange).padding(10)
                    }
                    if tree.rows.isEmpty {
                        Text("Pasta vazia").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint).padding(12)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 12)
            }
            .scrollIndicators(Platform.isMac ? .automatic : .hidden)
            .refreshable { await tree.refresh() }
        }
    }

    @ViewBuilder private func menu(_ row: FileTree.Row) -> some View {
        if row.entry.isFile {
            Button { editor.open(row.path) } label: { Label("Abrir", systemImage: "doc.text") }
        }
        let folder = row.entry.isFolder ? row.path : FileTree.parent(of: row.path)
        Button { startNewFile(in: folder) } label: { Label("Novo arquivo aqui…", systemImage: "doc.badge.plus") }
        if row.entry.isFolder {
            Button { Task { await tree.load(row.path) } } label: { Label("Recarregar pasta", systemImage: "arrow.clockwise") }
        }
        Button { UIPasteboard.general.string = row.path } label: { Label("Copiar caminho", systemImage: "doc.on.doc") }
    }

    /// The name of a new file, typed in place: Return makes it (folders in the name too) and opens it, Esc drops it.
    private func newFileRow(in folder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus").font(.system(size: Density.small)).foregroundStyle(Theme.accent).frame(width: 16)
                if !folder.isEmpty { Text(folder + "/").font(.system(size: Density.text - 1)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.head) }
                TextField("nome-do-arquivo", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: Density.text - 0.5))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($newFocused)
                    .onSubmit { createFile(in: folder) }
                    .onKeyPress(.escape) { creatingIn = nil; return .handled }
                    .accessibilityIdentifier("tree-new-file-field")
                Button { creatingIn = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Esc as a key command too: without one, the text field on the Mac takes Esc to give up its focus
                // and onKeyPress never sees it.
                .keyboardShortcut(.cancelAction)
                .help("Cancelar (Esc)")
                .accessibilityLabel("Cancelar")
            }
            .padding(.horizontal, 6).frame(height: Density.row - 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
            if let createError {
                Text(createError).font(.system(size: Density.small - 1)).foregroundStyle(Theme.red).padding(.leading, 4)
            }
        }
        .padding(.vertical, 3)
        .task { newFocused = true }
    }

    private func startNewFile(in folder: String) {
        newName = ""
        createError = nil
        creatingIn = folder
    }

    private func createFile(in folder: String) {
        let name = newName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { creatingIn = nil; return }
        let path = FileTree.join(folder, name)
        Task {
            if let error = await editor.create(path) {
                createError = error
            } else {
                creatingIn = nil
                await tree.load(folder)
                await tree.reveal(path)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if tree.allFiles == nil {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 8) {
                if tree.matching {
                    ProgressView().controlSize(.small)
                    Text("Buscando na box…").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint)
                } else if let e = tree.allFilesError {
                    Text("Não foi possível listar os arquivos").font(.system(size: Density.small)).foregroundStyle(Theme.textDim)
                    Text(e).font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint).multilineTextAlignment(.center)
                } else {
                    Text("Nenhum arquivo encontrado").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint)
                }
                largeRepositoryHint
            }
            .frame(maxWidth: .infinity).padding(.top, 20).padding(.horizontal, 10)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element) { i, path in
                            Button { open(path) } label: {
                                HStack(spacing: 7) {
                                    FileIcon(name: FileTree.name(of: path), folder: false, open: false)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(FileTree.name(of: path)).font(.system(size: Density.text)).foregroundStyle(Theme.text).lineLimit(1)
                                        let dir = FileTree.parent(of: path)
                                        if !dir.isEmpty {
                                            Text(dir).font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.head)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(i == picked ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(i)
                        }
                        largeRepositoryHint.padding(8)
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: picked) { _, i in withAnimation { proxy.scrollTo(i) } }
            }
        }
    }

    /// A repository too large to list whole: say so while git is still looking, or when what it found was cut too.
    @ViewBuilder private var largeRepositoryHint: some View {
        if tree.allFilesTruncated && (tree.matching || tree.matchedTruncated) {
            Text("Repositório grande: a busca cobre parte dos arquivos.").font(.system(size: Density.small - 1)).foregroundStyle(Theme.textFaint)
        }
    }

    private func toolButton(_ symbol: String, help: LocalizedStringKey, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: Density.small + 1))
                .frame(width: 26, height: Density.row + 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textDim)
        .help(help)
        .accessibilityLabel(label)
    }

    private func openPicked() {
        if let p = results[safe: picked] { open(p) }
    }

    private func open(_ path: String) {
        editor.open(path)
        query = ""
        searchFocused = false
        Task { await tree.reveal(path) }
    }
}

/// One line of the tree: indentation, the folder's chevron, the icon, the name (faint when git ignores it) and the
/// file's status letter (or a dot on a folder with changes inside).
private struct FileTreeRow: View {
    let row: FileTree.Row
    let open: Bool
    let loading: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let e = row.entry
        let badge = FileTree.badge(e.status)
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if e.isFolder {
                        Image(systemName: "chevron.right").font(.system(size: Density.small - 2, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
                FileIcon(name: e.name, folder: e.isFolder, open: open, link: e.type == .link)
                Text(e.name).font(.system(size: Density.text - 0.5))
                    .foregroundStyle(e.ignored ? Theme.textFaint : badge.map { $0.color } ?? Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if loading {
                    ProgressView().controlSize(.mini)
                } else if let badge {
                    Text(badge.rawValue).font(.system(size: Density.small - 1, weight: .bold, design: .monospaced)).foregroundStyle(badge.color)
                } else if e.changed && !open {
                    Circle().fill(Theme.orange.opacity(0.8)).frame(width: 5, height: 5)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 12 + 4).padding(.trailing, 8)
            .frame(height: Density.row - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.22) : hovering ? Theme.washStrong : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(e.type == .link ? "\(row.path) → \(e.target ?? "")" : row.path)
        .accessibilityLabel(e.name)
        .accessibilityValue(badge.map { Text($0.label) } ?? Text(""))
        .accessibilityIdentifier("file-\(row.path)")
    }
}

extension FileTree.Badge {
    var color: Color {
        switch self {
        case .modified: Theme.orange
        case .added, .untracked: Theme.green
        case .deleted, .conflict: Theme.red
        case .renamed: Theme.accent
        }
    }
    var label: LocalizedStringKey {
        switch self {
        case .modified: "modificado"
        case .added: "adicionado"
        case .untracked: "novo"
        case .deleted: "apagado"
        case .renamed: "renomeado"
        case .conflict: "em conflito"
        }
    }
}

/// A file's icon by its kind (folders open and closed).
struct FileIcon: View {
    let name: String
    let folder: Bool
    var open = false
    var link = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Density.small))
            .foregroundStyle(folder ? Theme.accent.opacity(0.85) : tint)
            .frame(width: 16)
    }

    private var ext: String { (name as NSString).pathExtension.lowercased() }

    private var symbol: String {
        if folder { return link ? "folder.badge.questionmark" : open ? "folder" : "folder.fill" }
        if link { return "arrow.turn.down.right" }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "bmp", "tiff": return "photo"
        case "md", "markdown", "txt", "rst": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml", "ini", "env", "lock": return "curlybraces"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "tar", "bz2", "xz", "7z": return "doc.zipper"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "": return name.hasPrefix(".") ? "gearshape" : "doc"
        default: return SyntaxLanguage.forFile(name) != nil ? "chevron.left.forwardslash.chevron.right" : "doc"
        }
    }

    private var tint: Color {
        switch ext {
        case "swift": Color(tone: 0xF05138)
        case "ts", "tsx": Color(tone: 0x3178C6)
        case "js", "jsx", "mjs", "cjs": Color(tone: 0xE0C050)
        case "py": Color(tone: 0x4B8BBE)
        case "go": Color(tone: 0x00ADD8)
        case "rs": Color(tone: 0xDEA584)
        case "md", "markdown": Theme.textDim
        case "json", "yml", "yaml", "toml": Color(tone: 0xB07CE8)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": Theme.green
        default: Theme.textDim
        }
    }
}

// MARK: - editor area

private struct EditorPane: View {
    let state: WorkspaceState
    @State private var handle: CodeEditorHandle?
    @State private var closing: String?
    @State private var saveError: String?

    private var editor: EditorStore { state.editor }

    var body: some View {
        VStack(spacing: 0) {
            if !editor.docs.isEmpty { tabs }
            if let doc = editor.activeDoc {
                header(doc)
                if doc.changedOnBox { changedBanner(doc) }
                if doc.deleted { deletedBanner(doc) }
                content(doc)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)).foregroundStyle(Theme.textFaint)
                    Text("Escolha um arquivo na árvore").font(.headline).foregroundStyle(Theme.textDim)
                    if Platform.isMac { Text("⇧⌘O abre um arquivo pelo nome").font(.subheadline).foregroundStyle(Theme.textFaint) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.card)
        .onChange(of: state.findRequested, initial: true) { _, requested in
            guard requested else { return }
            state.findRequested = false
            handle?.find()
        }
        .alert("Salvar as alterações em “\(closing.map(FileTree.name(of:)) ?? "")”?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Salvar") {
                guard let p = closing else { return }
                Task {
                    switch await editor.save(p) {
                    case .saved:
                        editor.close(p)
                        await state.tree.refresh()
                    case .conflict:
                        editor.active = p
                        editor.conflict = p
                    case .failed(let m): if !m.isEmpty { saveError = m }
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Não salvar", role: .destructive) { if let p = closing { editor.close(p) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Se não salvar, o que você digitou se perde.") }
        .alert("O arquivo mudou na box", isPresented: Binding(get: { editor.conflict != nil }, set: { if !$0 { editor.conflict = nil } })) {
            Button("Salvar por cima") {
                guard let p = editor.conflict else { return }
                Task {
                    if case .failed(let m) = await editor.save(p, force: true), !m.isEmpty { saveError = m }
                }
            }
            Button("Recarregar da box", role: .destructive) {
                guard let p = editor.conflict else { return }
                Task { await editor.revert(p) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Alguém (talvez um agente) mudou este arquivo depois que você o abriu. Salvar por cima descarta a versão da box; recarregar descarta o que você digitou.") }
        .alert("Não foi possível salvar", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
    }

    // MARK: tabs

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(editor.docs) { d in
                    EditorTab(doc: d, active: d.path == editor.active, select: { editor.active = d.path }, close: { close(d.path) })
                        .contextMenu {
                            Button { close(d.path) } label: { Label("Fechar", systemImage: "xmark") }
                            Button { editor.closeOthers(d.path) } label: { Label("Fechar as outras", systemImage: "xmark.square") }
                            Divider()
                            Button { UIPasteboard.general.string = d.path } label: { Label("Copiar caminho", systemImage: "doc.on.doc") }
                        }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: Platform.isMac ? 30 : 38)
        // A gray strip with its line under the tabs: the open file's tab, the editor's white, covers it and runs into
        // the editor.
        .background { ZStack(alignment: .bottom) { Theme.bg; Rectangle().fill(Theme.stroke).frame(height: 1) } }
    }

    private func close(_ path: String) {
        if editor.doc(path)?.dirty == true { closing = path } else { editor.close(path) }
    }

    // MARK: header

    private func header(_ doc: EditorDoc) -> some View {
        HStack(spacing: 8) {
            Text(doc.path.split(separator: "/").joined(separator: "  ›  "))
                .font(.system(size: Density.small)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            saveState(doc)
            if doc.dirty {
                Button { Task { await editor.revert(doc.path) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Descartar alterações").accessibilityLabel("Descartar alterações")
            }
            if doc.editable {
                Button { handle?.find() } label: { Image(systemName: "magnifyingglass") }
                    .help("Buscar no arquivo (⌘F)").accessibilityLabel("Buscar no arquivo")
                Button { save(doc) } label: {
                    Text("Salvar").font(.system(size: Density.small, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(doc.dirty ? Theme.accent : Theme.washStrong, in: Capsule())
                        .foregroundStyle(doc.dirty ? .white : Theme.textDim)
                }
                .disabled(!doc.dirty || doc.saving)
                .help("Salvar na box (⌘S)")
                .accessibilityIdentifier("editor-save")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: Density.small))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 12).frame(height: Platform.isMac ? 30 : 38)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    @ViewBuilder private func saveState(_ doc: EditorDoc) -> some View {
        if doc.saving {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Salvando…") }.foregroundStyle(Theme.textDim)
        } else if doc.dirty {
            Text("Não salvo").foregroundStyle(Theme.orange)
        } else if let at = doc.lastSaved, Date().timeIntervalSince(at) < 4 {
            Label("Salvo", systemImage: "checkmark").foregroundStyle(Theme.green)
        }
    }

    private func save(_ doc: EditorDoc) {
        Task {
            switch await editor.save(doc.path) {
            case .saved: await state.tree.refresh()
            case .conflict: editor.conflict = doc.path
            case .failed(let m): if !m.isEmpty { saveError = m }
            }
        }
    }

    // MARK: banners

    private func changedBanner(_ doc: EditorDoc) -> some View {
        EditorBanner(symbol: "exclamationmark.triangle.fill", color: Theme.orange,
                     text: "Este arquivo mudou na box depois que você o abriu (um agente pode tê-lo editado).") {
            Button("Recarregar") { Task { await editor.revert(doc.path) } }
            Button("Manter o meu") { editor.conflict = doc.path }
        }
    }

    private func deletedBanner(_ doc: EditorDoc) -> some View {
        EditorBanner(symbol: "trash", color: Theme.red, text: "Este arquivo foi apagado na box.") {
            if doc.dirty { Button("Salvar de novo") { save(doc) }.disabled(doc.saving) }
            // As the tab's ×: with edits, it asks first (the box no longer has them anywhere).
            Button("Fechar") { close(doc.path) }
        }
    }

    // MARK: content

    @ViewBuilder private func content(_ doc: EditorDoc) -> some View {
        switch doc.state {
        case .loading, .idle:
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível abrir o arquivo", message: LocalizedStringKey(m))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if doc.tooLarge {
                EmptyState(symbol: "doc.badge.ellipsis", title: "Arquivo grande demais para abrir aqui",
                           message: "\(ByteCountFormatter.string(fromByteCount: Int64(doc.size), countStyle: .file))")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if doc.binary {
                BinaryPreview(doc: doc)
            } else {
                CodeEditor(doc: doc, open: Set(editor.docs.map(\.path)), container: state.editorView,
                           onChange: { editor.setText($0, for: doc.path) },
                           onSelection: { editor.setSelection($0, text: $1, for: doc.path) },
                           onReady: { handle = $0 })
            }
        }
    }
}

private struct EditorTab: View {
    let doc: EditorDoc
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: doc.name, folder: false)
            Text(doc.name).font(.system(size: Density.small + 0.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.text : Theme.textDim).lineLimit(1)
            ZStack {
                if doc.dirty && !hovering {
                    Circle().fill(Theme.text.opacity(0.7)).frame(width: 7, height: 7)
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: Density.small - 2, weight: .bold)).foregroundStyle(Theme.textDim)
                            .frame(width: 16, height: 16)
                            .background(hovering ? Theme.washStrong : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .opacity(active || hovering ? 1 : 0)
                    .accessibilityLabel("Fechar \(doc.name)")
                }
            }
            .frame(width: 16)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(active ? Theme.card : .clear)
        .overlay(alignment: .top) { if active { Rectangle().fill(Theme.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(doc.path)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("editor-tab-\(doc.path)")
    }
}

private struct EditorBanner<Actions: View>: View {
    let symbol: String
    let color: Color
    let text: LocalizedStringKey
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: Density.small + 0.5)).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            actions().buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

/// A binary file: the picture when it is one, else its size.
private struct BinaryPreview: View {
    let doc: EditorDoc

    var body: some View {
        VStack(spacing: 12) {
            if let data = doc.data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(image.size.width < 64 ? .none : .high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width * 2, 640), maxHeight: min(image.size.height * 2, 480))
                    .background(Theme.washStrong)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(doc.size), countStyle: .file))")
                    .font(.system(size: Density.small)).foregroundStyle(Theme.textDim)
            } else {
                Image(systemName: "doc.zipper").font(.system(size: 30)).foregroundStyle(Theme.textFaint)
                Text("Arquivo binário").font(.headline).foregroundStyle(Theme.textDim)
                Text(ByteCountFormatter.string(fromByteCount: Int64(doc.size), countStyle: .file)).font(.subheadline).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
