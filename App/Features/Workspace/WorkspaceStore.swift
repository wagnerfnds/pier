import SwiftUI
import PierKit

/// The tabs of a project's workspace; the first, Agentes, starts an agent there (StartPane.swift).
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case start, files, changes, history, pullRequests, overview, details
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .start: "Agentes"
        case .files: "Arquivos"
        case .changes: "Alterações"
        case .history: "Histórico"
        case .pullRequests: "Pull requests"
        case .overview: "Visão geral"
        case .details: "Detalhes"
        }
    }
    var symbol: String {
        switch self {
        case .start: "sparkles"
        case .files: "doc.text"
        case .changes: "plusminus"
        case .history: "clock.arrow.circlepath"
        case .pullRequests: "arrow.triangle.pull"
        case .overview: "info.circle"
        case .details: "server.rack"
        }
    }
}

/// One worktree as the workspace knows it: which box, project and worktree, and where `exec` runs there.
struct WorkspaceRef: Hashable {
    let box: String
    let location: String
    /// The worktree's name (the main checkout's is its folder's).
    let worktree: String
    /// `exec`'s location: the bare project for the main checkout.
    let execLocation: String

    var key: String { "\(box)/\(location)/\(worktree)" }
    var reviewRoute: ReviewRoute { ReviewRoute(box: box, location: location, worktree: worktree) }
}

/// Everything a worktree's workspace holds while the app runs: the open folders, the open files (with what was typed
/// and not saved), the history read so far, the tab. Kept per worktree, so leaving the project for a session or another
/// project and coming back finds it as it was, unsaved edits included.
@MainActor @Observable
final class WorkspaceState {
    let ref: WorkspaceRef
    /// The project opens on Agentes, a box to start an agent there.
    var tab: WorkspaceTab = .start
    /// Agentes' box: what was typed stays while the app runs. From the main checkout an agent gets a worktree of its
    /// own (the composer's default); from a worktree it runs there.
    @ObservationIgnored private(set) lazy var compose: ComposeModel = {
        let m = ComposeModel(route: ComposeRoute(box: ref.box, location: ref.location,
                                                 worktree: ref.execLocation == ref.location ? nil : ref.worktree))
        m.sendsComposerDraft = false
        return m
    }()
    let tree: FileTreeStore
    let editor: EditorStore
    let history: HistoryStore
    /// The editor's views (a text view per open file), kept with the rest.
    @ObservationIgnored private(set) lazy var editorView = EditorContainer()
    /// Requests from the menu bar (⇧⌘O, ⌘F) for the views of this workspace, taken by the view that serves them: a flag,
    /// not a counter, so a view that only appears with the request (Arquivos opened by ⇧⌘O) still sees it.
    var quickOpenRequested = false
    var findRequested = false

    init(ref: WorkspaceRef) {
        self.ref = ref
        tree = FileTreeStore(ref: ref)
        editor = EditorStore(ref: ref)
        history = HistoryStore(ref: ref)
    }

    func bind(_ model: AppModel) {
        tree.bind(model)
        editor.bind(model)
        history.bind(model)
    }

    static func of(_ ref: WorkspaceRef) -> WorkspaceState { WorkspaceRegistry.shared.state(ref) }
}

/// Every worktree's workspace state for the app's run, observable so the sidebar can mark the projects with files typed
/// in and not saved.
@MainActor @Observable
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()
    /// Not observed itself: it grows while views are being made (a workspace's init), and a state starts with nothing
    /// unsaved; what the sidebar follows is each state's `dirtyPaths`.
    @ObservationIgnored private(set) var states: [String: WorkspaceState] = [:]

    func state(_ ref: WorkspaceRef) -> WorkspaceState {
        if let s = states[ref.key] { return s }
        let s = WorkspaceState(ref: ref)
        states[ref.key] = s
        return s
    }

    /// A worktree of the project has unsaved files (cheap: the editors' dirty sets change only when a file turns dirty or
    /// clean, not on every keystroke).
    func hasUnsaved(box: String, location: String) -> Bool {
        states.values.contains { $0.ref.box == box && $0.ref.location == location && $0.editor.hasUnsaved }
    }

    /// The files typed in and not saved in one worktree.
    func unsaved(box: String, location: String, worktree: String) -> Int {
        states["\(box)/\(location)/\(worktree)"]?.editor.dirtyPaths.count ?? 0
    }

    /// A worktree removed: its workspace goes with it (a new one by the same name starts empty), and with it the mark of
    /// its unsaved files.
    func forget(box: String, location: String, worktree: String) {
        guard let s = states.removeValue(forKey: "\(box)/\(location)/\(worktree)") else { return }
        // The sidebar follows the dirty sets, not this dictionary: empty the one going away so its mark goes too.
        s.editor.discardAll()
    }
}

/// Loading and error state shared by the stores.
enum LoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

/// Messages for the errors the workspace shows.
enum WorkspaceError {
    static func message(_ error: Error) -> String {
        if let e = error as? BoxError { return e.error.isEmpty ? String(localized: "Não encontrado na box.") : e.error }
        return (error as? PierError)?.localizedDescription ?? error.localizedDescription
    }

    /// A request given up because the view that asked went away: not an error to show.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    /// A box whose pierd predates the file routes answers 404 in plain text for them.
    static func isUnsupported(_ error: Error) -> Bool {
        guard let e = error as? BoxError else { return false }
        return e.status == 404 && e.code == nil
    }
}

// MARK: - file tree

/// A worktree's folders as the tree shows them: loaded one folder at a time as they open (`GET …/files`), refreshed
/// when the box says something changed.
@MainActor @Observable
final class FileTreeStore {
    let ref: WorkspaceRef
    private(set) var listings: [String: [FileEntry]] = [:]
    private(set) var truncated: Set<String> = []
    private(set) var loading: Set<String> = []
    var open: Set<String> = []
    private(set) var state: LoadState = .idle
    /// The box's pierd has no file routes (older than this app).
    private(set) var unsupported = false
    var hideIgnored = false
    /// Every file of the worktree for "Abrir rápido" (`FileSearch`), read when first needed and again, keeping this one
    /// meanwhile, the next time it is needed after the box changed.
    private(set) var allFiles: [String]? { didSet { searchVersion &+= 1 } }
    /// Bumped whenever what quick open searches changes (`allFiles`, `matched`), so a search can be kept until then.
    @ObservationIgnored private(set) var searchVersion = 0
    private(set) var allFilesTruncated = false
    private(set) var allFilesError: String?
    @ObservationIgnored private var allFilesStale = false
    /// The read of the list under way: every caller waits for the same one.
    @ObservationIgnored private var allFilesTask: Task<Void, Never>?
    /// A repository too large to list whole: the files git found for what is being typed (`FileSearch.command(matching:)`).
    private(set) var matched: [String] = [] { didSet { searchVersion &+= 1 } }
    private(set) var matchedTruncated = false
    /// Searches under way (a newer one can start before an older one, given up, has its answer).
    private var matches = 0
    var matching: Bool { matches > 0 }
    @ObservationIgnored private var client: (any PierBoxClient)?

    init(ref: WorkspaceRef) { self.ref = ref }

    /// Takes the box's client every time: pairing the box again (a new address, a new certificate) makes a new one.
    func bind(_ model: AppModel) {
        client = model.client(for: ref.box)
    }

    var rows: [FileTree.Row] { FileTree.rows(listings: listings, open: open, hideIgnored: hideIgnored) }

    func loadRoot() async {
        if listings[""] == nil { state = .loading }
        await load("")
    }

    func load(_ dir: String) async {
        guard let client else { return }
        loading.insert(dir)
        defer { loading.remove(dir) }
        do {
            let l = try await client.files(location: ref.location, worktree: ref.worktree, path: dir)
            listings[dir] = l.entries
            if l.truncated { truncated.insert(dir) } else { truncated.remove(dir) }
            if dir.isEmpty { state = .loaded; unsupported = false }
        } catch {
            if error is CancellationError { return }
            if dir.isEmpty {
                unsupported = WorkspaceError.isUnsupported(error)
                if listings[""] == nil { state = .failed(WorkspaceError.message(error)) }
            } else if (error as? BoxError)?.kind == .notFound {
                // The folder is gone (an agent removed it): close it.
                listings[dir] = nil
                open.remove(dir)
            }
        }
    }

    func toggle(_ dir: String) {
        if open.contains(dir) {
            open.remove(dir)
        } else {
            open.insert(dir)
            if listings[dir] == nil { Task { await load(dir) } }
        }
    }

    /// Open the folders down to `path` (a file opened from search or from the history) and load them.
    func reveal(_ path: String) async {
        for dir in FileTree.ancestors(of: path) {
            open.insert(dir)
            if listings[dir] == nil { await load(dir) }
        }
    }

    /// Read again every folder on screen (after an agent's turn, a save, ⌘R).
    func refresh() async {
        let dirs = [""] + open.sorted().filter { listings[$0] != nil }
        for d in dirs { await load(d) }
        allFilesStale = true
    }

    /// The list "Abrir rápido" searches: read once, read again when the box changed since (the old list stays on
    /// screen meanwhile). The read goes on when the caller goes away (a keystroke replaces the view's task).
    func loadAllFiles() async {
        if let running = allFilesTask { await running.value; return }
        guard allFiles == nil || allFilesStale, client != nil else { return }
        let read = Task { await readAllFiles() }
        allFilesTask = read
        await read.value
        allFilesTask = nil
    }

    private func readAllFiles() async {
        guard let client else { return }
        allFilesStale = false
        do {
            let r = try await client.exec(location: ref.execLocation, command: FileSearch.command, timeout: "30s")
            let (paths, cut) = FileSearch.parse(r.output)
            if r.exitCode != 0 && paths.isEmpty {
                allFilesError = r.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "git"
                if allFiles == nil { allFiles = [] }
                return
            }
            allFiles = paths
            allFilesTruncated = cut
            allFilesError = nil
        } catch {
            if WorkspaceError.isCancellation(error) { allFilesStale = true; return }
            allFilesError = WorkspaceError.message(error)
            if allFiles == nil { allFiles = [] }
        }
    }

    /// When the list was cut, ask git for the files matching `query` (a moment after the last keystroke: the caller's
    /// task is cancelled by the next one).
    func match(_ query: String) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await loadAllFiles()   // whether the list was cut
        guard allFilesTruncated, !Task.isCancelled, let client, let command = FileSearch.command(matching: query) else { return }
        matches += 1
        defer { matches -= 1 }
        guard let r = try? await client.exec(location: ref.execLocation, command: command, timeout: "30s"), !Task.isCancelled else { return }
        let (paths, cut) = FileSearch.parse(r.output)
        matched = paths
        matchedTruncated = cut
    }

    /// What "Abrir rápido" searches in: the list, and what git found for the query when the list was cut.
    var searchable: [String] {
        guard !matched.isEmpty else { return allFiles ?? [] }
        var seen = Set(allFiles ?? [])
        return (allFiles ?? []) + matched.filter { seen.insert($0).inserted }
    }

    /// The entry at `path`, if its folder is loaded.
    func entry(at path: String) -> FileEntry? {
        listings[FileTree.parent(of: path)]?.first { $0.name == FileTree.name(of: path) }
    }
}

// MARK: - editor

/// One open file: what the box has (`base`), what is typed (`text`), and what to do when they differ.
struct EditorDoc: Identifiable, Equatable {
    let path: String
    var id: String { path }
    var state: LoadState = .loading
    /// The text as last read from or saved to the box.
    var base = ""
    /// The text in the editor.
    var text = ""
    /// The box's version `base` is (the sha a save names).
    var sha = ""
    var size = 0
    var binary = false
    var tooLarge = false
    /// A binary file's bytes (an image shows).
    var data: Data?
    /// The file changed on the box while it had unsaved edits here.
    var changedOnBox = false
    /// The file is gone from the box.
    var deleted = false
    var saving = false
    var lastSaved: Date?
    var language: SyntaxLanguage? { SyntaxLanguage.forFile(path) }
    var name: String { FileTree.name(of: path) }
    var dirty: Bool { state == .loaded && !binary && !tooLarge && text != base }
    var editable: Bool { state == .loaded && !binary && !tooLarge }
    /// Where the caret was, to come back to it.
    var selection = NSRange(location: 0, length: 0)
    /// Bumped when the text is replaced from outside the editor (a reload), so the text view takes it.
    var revision = 0
}

@MainActor @Observable
final class EditorStore {
    let ref: WorkspaceRef
    private(set) var docs: [EditorDoc] = []
    var active: String?
    /// The caret's line and column in the active file (the status bar).
    var caret = (line: 1, column: 1)
    /// Each file's caret, taken back when its text is replaced. Not observed: it moves on every keystroke, and in `docs`
    /// it redrew the whole workspace (tabs, status bar, editor header) each time.
    @ObservationIgnored private var selections: [String: NSRange] = [:]
    /// A file of this worktree whose save the box refused (it changed there): its editor asks what to do.
    var conflict: String?
    @ObservationIgnored private var client: (any PierBoxClient)?

    init(ref: WorkspaceRef) { self.ref = ref }

    /// Takes the box's client every time: pairing the box again (a new address, a new certificate) makes a new one.
    func bind(_ model: AppModel) {
        client = model.client(for: ref.box)
    }

    /// Text views are kept per path while a file is open and a while after: every text replaced from outside takes a
    /// revision no other has had, so a file closed and opened again never matches the view kept for it.
    private static var revisions = 0
    private static func nextRevision() -> Int {
        revisions += 1
        return revisions
    }

    /// The open files with unsaved edits, kept apart from `docs` so a view can watch it without following every keystroke.
    private(set) var dirtyPaths: Set<String> = []
    var hasUnsaved: Bool { !dirtyPaths.isEmpty }

    /// Re-reads whether one file is dirty, touching `dirtyPaths` only when that changes.
    private func noteDirty(_ path: String) {
        let dirty = doc(path)?.dirty == true
        if dirty != dirtyPaths.contains(path) {
            if dirty { dirtyPaths.insert(path) } else { dirtyPaths.remove(path) }
        }
    }
    var activeDoc: EditorDoc? { active.flatMap { a in docs.first { $0.path == a } } }
    func doc(_ path: String) -> EditorDoc? { docs.first { $0.path == path } }
    private func index(_ path: String) -> Int? { docs.firstIndex { $0.path == path } }

    /// Open a file in a tab (or bring its tab forward) and read it from the box.
    func open(_ path: String) {
        active = path
        if index(path) == nil {
            docs.append(EditorDoc(path: path))
            // Keep a handful of tabs: the oldest one without edits goes.
            if docs.count > 12, let i = docs.firstIndex(where: { !$0.dirty && $0.path != path }) { docs.remove(at: i) }
            Task { await load(path) }
        }
    }

    func close(_ path: String) {
        guard let i = index(path) else { return }
        docs.remove(at: i)
        selections[path] = nil
        noteDirty(path)
        if active == path { active = docs.indices.contains(i) ? docs[i].path : docs.last?.path }
    }

    func closeOthers(_ path: String) {
        docs.removeAll { $0.path != path && !$0.dirty }
        active = path
    }

    /// Everything open goes, edits too (the worktree was removed).
    func discardAll() {
        docs = []
        active = nil
        dirtyPaths = []
        conflict = nil
    }

    func setText(_ text: String, for path: String) {
        guard let i = index(path), docs[i].text != text else { return }
        docs[i].text = text
        noteDirty(path)
    }

    /// The caret moved. `text` is the text view's: UIKit tells of the caret before the edit reaches the store.
    func setSelection(_ range: NSRange, text: String, for path: String) {
        guard index(path) != nil else { return }
        selections[path] = range
        let p = EditorText.lineColumn(in: text, utf16Offset: range.location)
        if caret != (p.line, p.column) { caret = (p.line, p.column) }
    }

    func load(_ path: String) async {
        guard let client, index(path) != nil else { return }
        do {
            let f = try await client.file(location: ref.location, worktree: ref.worktree, path: path, statOnly: false)
            guard let i = index(path) else { return }
            if docs[i].dirty {
                // Typed while the file was being read: what was typed stays, the box's change is flagged.
                if f.sha != docs[i].sha { docs[i].changedOnBox = true }
                docs[i].deleted = false
                return
            }
            var d = docs[i]
            d.state = .loaded
            d.sha = f.sha
            d.size = f.size
            d.binary = f.binary
            d.tooLarge = f.tooLarge
            d.deleted = false
            d.changedOnBox = false
            if f.binary {
                d.data = f.data
            } else if let t = f.text {
                d.base = t
                d.text = t
                d.selection = selections[path] ?? d.selection
                d.revision = Self.nextRevision()
            }
            docs[i] = d
            noteDirty(path)
        } catch {
            guard let i = index(path) else { return }
            // Given up (the screen that asked went away): the next look reads it again.
            if WorkspaceError.isCancellation(error) { return }
            if (error as? BoxError)?.kind == .notFound, docs[i].state == .loaded { docs[i].deleted = true; return }
            docs[i].state = .failed(WorkspaceError.message(error))
        }
    }

    /// A new, empty file at `path` (its folders made as needed), opened in a tab; nil when made, else why not.
    func create(_ path: String) async -> String? {
        guard let client else { return String(localized: "Sem conexão com a box.") }
        do {
            _ = try await client.writeFile(location: ref.location, worktree: ref.worktree, path: path, FileWrite(text: "", sha: nil, create: true))
            open(path)
            return nil
        } catch {
            if let e = error as? BoxError, e.kind == .fileExists { return String(localized: "Já existe um arquivo com esse nome.") }
            return WorkspaceError.message(error)
        }
    }

    enum SaveOutcome { case saved, conflict, failed(String) }

    /// Save the file; `force` overwrites what the box has (after a conflict the person chose to keep theirs).
    @discardableResult
    func save(_ path: String, force: Bool = false) async -> SaveOutcome {
        // One save at a time: a second would name the sha the first is replacing, and read as a conflict.
        guard let client, let i = index(path), docs[i].editable, !docs[i].saving else { return .failed("") }
        let text = docs[i].text
        docs[i].saving = true
        defer { if let j = index(path) { docs[j].saving = false } }
        do {
            let req = FileWrite(text: text, sha: docs[i].deleted ? nil : docs[i].sha, create: docs[i].deleted, force: force)
            let f = try await client.writeFile(location: ref.location, worktree: ref.worktree, path: path, req)
            guard let j = index(path) else { return .saved }
            docs[j].base = text
            docs[j].sha = f.sha
            docs[j].size = f.size
            docs[j].changedOnBox = false
            docs[j].deleted = false
            docs[j].lastSaved = Date()
            noteDirty(path)
            return .saved
        } catch {
            if let e = error as? BoxError, e.kind == .fileChanged || e.kind == .fileExists {
                if let j = index(path) { docs[j].changedOnBox = true }
                return .conflict
            }
            return .failed(WorkspaceError.message(error))
        }
    }

    /// Drop what was typed and read the box's version again.
    func revert(_ path: String) async {
        guard let i = index(path) else { return }
        docs[i].text = docs[i].base
        docs[i].changedOnBox = false
        docs[i].selection = selections[path] ?? docs[i].selection
        docs[i].revision = Self.nextRevision()
        noteDirty(path)
        await load(path)
    }

    /// The editor's check for changes on the box (an agent writing the open file): a file without edits follows the
    /// box; one with edits is flagged, never overwritten. Only a text file the editor holds is followed: a binary or a
    /// file too large to open would make the box read it whole every time.
    func poll() async {
        guard let client, let path = active, let d = doc(path), d.editable, !d.saving else { return }
        do {
            let f = try await client.file(location: ref.location, worktree: ref.worktree, path: path, statOnly: true)
            guard let i = index(path), !docs[i].saving else { return }
            // Back again (a stash popped, a branch checked out and back): not deleted any more.
            if docs[i].deleted { docs[i].deleted = false }
            guard f.sha != docs[i].sha else { return }
            if docs[i].dirty { docs[i].changedOnBox = true } else { await load(path) }
        } catch {
            if let i = index(path), (error as? BoxError)?.kind == .notFound { docs[i].deleted = true }
        }
    }
}

// MARK: - history

/// A worktree's commits, a page at a time (`GitLog` through `exec`), and the one picked with its files and patches.
@MainActor @Observable
final class HistoryStore {
    let ref: WorkspaceRef
    private(set) var entries: [GitLog.Entry] = []
    private(set) var hasMore = false
    private(set) var empty = false
    private(set) var state: LoadState = .idle
    private(set) var loadingMore = false
    var selected: String?
    private(set) var details: [String: GitLog.Detail] = [:]
    /// Why a commit could not be read, per commit (the iPhone's commit screen asks for one that isn't selected).
    private(set) var detailErrors: [String: String] = [:]
    var selectedFile: String?
    @ObservationIgnored private var client: (any PierBoxClient)?
    /// Bumped by every first-page read: a "load more" that started before it appends nothing.
    @ObservationIgnored private var generation = 0

    init(ref: WorkspaceRef) { self.ref = ref }

    /// Takes the box's client every time: pairing the box again (a new address, a new certificate) makes a new one.
    func bind(_ model: AppModel) {
        client = model.client(for: ref.box)
    }

    var detail: GitLog.Detail? { selected.flatMap { details[$0] } }
    var detailError: String? { selected.flatMap { detailErrors[$0] } }

    /// The first page (again): the older pages already read stay, and so does the commit picked.
    func load() async {
        guard let client else { return }
        if entries.isEmpty { state = .loading }
        do {
            let r = try await client.exec(location: ref.execLocation, command: GitLog.command(), timeout: "30s")
            let page = GitLog.parse(r.output)
            if page.entries.isEmpty && !page.empty && r.exitCode != 0 {
                state = .failed(r.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "git")
                return
            }
            generation += 1
            (entries, hasMore) = GitLog.refreshed(entries, hasMore: hasMore, with: page)
            empty = page.empty
            state = .loaded
            if selected == nil || !entries.contains(where: { $0.sha == selected }) { select(entries.first?.sha) }
        } catch {
            if !WorkspaceError.isCancellation(error) { state = .failed(WorkspaceError.message(error)) }
        }
    }

    func loadMore() async {
        guard let client, hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let started = generation
        guard let r = try? await client.exec(location: ref.execLocation, command: GitLog.command(skip: entries.count), timeout: "30s"),
              generation == started else { return }
        let page = GitLog.parse(r.output)
        let known = Set(entries.map(\.sha))
        entries += page.entries.filter { !known.contains($0.sha) }
        hasMore = page.hasMore
    }

    func select(_ sha: String?) {
        selected = sha
        selectedFile = nil
        guard let sha, details[sha] == nil else {
            if let sha { selectedFile = details[sha]?.files.first?.path }
            return
        }
        Task { await loadDetail(sha) }
    }

    func loadDetail(_ sha: String) async {
        guard let client else { return }
        detailErrors[sha] = nil
        do {
            let r = try await client.exec(location: ref.execLocation, command: GitLog.showCommand(sha: sha), timeout: "30s")
            if var d = GitLog.parseShow(r.output) {
                // `git show` doesn't know what is pushed: the log does.
                d.entry.unpushed = entries.first { $0.sha == d.entry.sha }?.unpushed ?? false
                details[sha] = d
                if selected == sha, selectedFile == nil { selectedFile = d.files.first?.path }
            } else {
                detailErrors[sha] = r.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
                    ?? String(localized: "Não foi possível ler este commit.")
            }
        } catch {
            if !WorkspaceError.isCancellation(error) { detailErrors[sha] = WorkspaceError.message(error) }
        }
    }
}
