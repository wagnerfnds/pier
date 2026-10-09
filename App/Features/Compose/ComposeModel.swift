import SwiftUI
import PhotosUI
import PierKit

@MainActor @Observable
final class ComposeModel {
    enum Target: Hashable { case newWorktree; case existing(String) }
    enum Stage: Equatable {
        case idle, creatingWorktree, uploading(Int, Int), starting
        var isBusy: Bool { self != .idle }
    }

    static let promptLimit = 128 * 1024

    var box: String
    var location: String?
    var target: Target
    /// A chat (capability `session.chat`): the agent runs on the box tied to no project, in a folder of its own.
    var chat: Bool
    var prompt = ""
    var title = ""
    var worktreeName = ""
    var nameEdited = false
    var base: String?
    var branches: BranchList?
    var agentID: String?
    var model: String?
    var effort: String?
    var photos: [ComposePhoto] = []
    var stage: Stage = .idle
    var error: String?
    var loadingBranches = false

    @ObservationIgnored private(set) var app: AppModel?
    @ObservationIgnored private var bound = false
    @ObservationIgnored private var photoCounter = 0

    init(route: ComposeRoute) {
        box = route.box
        location = route.location
        target = route.worktree.map { .existing($0) } ?? .newWorktree
        chat = route.chat
    }

    // MARK: binding to the app

    func bind(_ app: AppModel) {
        self.app = app
        if app.connection(for: box) == nil, let b = app.boxes.first { box = b.name }
        // A location handed in by the route is kept even while the box's list is still loading; only a missing one is
        // picked (last used, else the first repo). Called again once the box answered, in case nothing could be picked.
        if location == nil, !repos.isEmpty { location = recentLocation(in: box) ?? repos.first?.name }
        // A chat needs no project, only the box's agents.
        guard !bound, !repos.isEmpty || location != nil || (chat && conn?.info != nil) else { return }
        bound = true
        applyProjectDefaults()
    }

    private func recentLocation(in box: String) -> String? {
        guard let app else { return nil }
        let names = Set(app.connection(for: box)?.locations.filter(\.repo).map(\.name) ?? [])
        for k in app.prefs.recentProjects where k.hasPrefix(box + "/") {
            let l = String(k.dropFirst(box.count + 1))
            if names.contains(l) { return l }
        }
        return nil
    }

    /// Agent / model / effort for the current project from the last submit.
    func applyProjectDefaults() {
        guard let app else { return }
        let key = LocalPrefs.key(box: box, location: chat ? "" : location ?? "")
        let pick = app.prefs.pick(for: key)
        let ids = agents.map(\.id)
        agentID = [pick?.agent, app.prefs.lastAgent, "claude"].compactMap { $0 }.first { ids.contains($0) } ?? ids.first
        model = pick?.agent == agentID ? pick?.model : nil
        effort = pick?.agent == agentID ? pick?.effort : nil
        if !(agent?.canPickModel ?? false) { model = nil }
        if !(agent?.canPickEffort ?? false) { effort = nil }
        refreshName()
    }

    // MARK: derived

    var conn: BoxConnection? { app?.connection(for: box) }
    var repos: [Location] { conn?.locations.filter(\.repo) ?? [] }
    var locationObject: Location? { repos.first { $0.name == location } }
    var worktrees: [Worktree] { locationObject?.worktrees ?? [] }
    var agents: [AgentPreset] { mergedAgents(box: conn?.info, location: chat ? nil : locationObject) }
    /// The box can start chats (older pierd cannot).
    var canChat: Bool { conn?.info?.has("session.chat") ?? false }
    var agent: AgentPreset? { agents.first { $0.id == agentID } }
    var defaultBranch: String? { branches?.default ?? locationObject?.defaultBranch }
    var effectiveBase: String { base ?? defaultBranch ?? "" }
    var isNew: Bool { target == .newWorktree }
    var existingWorktree: Worktree? {
        if case .existing(let n) = target { return worktrees.first { $0.name == n } }
        return nil
    }
    var promptBytes: Int { prompt.utf8.count }
    var promptTooLong: Bool { promptBytes > Self.promptLimit }
    var canSubmit: Bool {
        guard !stage.isBusy, chat ? canChat : locationObject != nil, agent != nil, !promptTooLong,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if chat { return true }
        if isNew { return WorktreeNaming.isValid(worktreeName) }
        return existingWorktree != nil
    }
    var takenNames: Set<String> { Set(worktrees.map(\.name)) }

    /// One line saying what Start will do: "Nova worktree a partir de main · Claude Code · modelo opus".
    var summary: String {
        var parts: [String] = []
        if chat {
            parts.append(String(localized: "Conversa livre, sem projeto"))
        } else if locationObject == nil {
            parts.append(String(localized: "Escolha um projeto"))
        } else if isNew {
            let base = effectiveBase.isEmpty ? String(localized: "Nova worktree") : String(localized: "Nova worktree a partir de \(effectiveBase)")
            parts.append(WorktreeNaming.isValid(worktreeName) ? "\(base) (\(worktreeName))" : base)
        } else if let wt = existingWorktree {
            parts.append(String(localized: "Na worktree \(wt.name)"))
        }
        if let a = agent {
            parts.append(a.name.isEmpty ? DisplayNames.agentLabel(a.id) : a.name)
            if let m = model, !m.isEmpty { parts.append(String(localized: "modelo \(m)")) }
            if let e = effort, !e.isEmpty { parts.append(String(localized: "esforço \(e)")) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: editing

    func promptChanged() { if !nameEdited { refreshName() } }

    func refreshName() {
        guard isNew, !nameEdited else { return }
        let src = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        worktreeName = src.isEmpty ? "" : WorktreeNaming.free(WorktreeNaming.slug(src), taken: takenNames)
    }

    func randomizeName() {
        worktreeName = WorktreeNaming.free(WorktreeNaming.random(), taken: takenNames)
        nameEdited = true
    }

    func resetName() { nameEdited = false; refreshName() }

    func selectBox(_ name: String) {
        guard name != box else { return }
        box = name
        branches = nil; base = nil; target = .newWorktree; nameEdited = false
        location = recentLocation(in: name) ?? repos.first?.name
        applyProjectDefaults()
    }

    func selectLocation(_ name: String) {
        guard name != location else { return }
        location = name; branches = nil; base = nil; target = .newWorktree; nameEdited = false
        applyProjectDefaults()
    }

    /// Task (in a project) or chat (in none); each keeps its own agent / model / effort.
    func selectChat(_ on: Bool) {
        guard on != chat else { return }
        chat = on
        applyProjectDefaults()
    }

    func selectTarget(_ t: Target) {
        target = t
        if t == .newWorktree { refreshName() }
    }

    func selectAgent(_ id: String) {
        agentID = id
        if !(agent?.canPickModel ?? false) { model = nil }
        if !(agent?.canPickEffort ?? false) { effort = nil }
        if let m = model, let list = agent?.models, !list.isEmpty, !list.contains(m) { model = nil }
        if let e = effort, let list = agent?.efforts, !list.isEmpty, !list.contains(e) { effort = nil }
    }

    func loadBranches() async {
        guard let conn, let location else { return }
        loadingBranches = true
        defer { loadingBranches = false }
        if let b = try? await conn.client.branches(location: location), self.location == location { branches = b }
    }

    func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { continue }
            photoCounter += 1
            let n = photoCounter
            let photo = await Task.detached { ComposePhoto.make(from: raw, index: n) }.value
            if let photo { photos.append(photo) }
        }
    }

    // MARK: submit

    /// Creates the task / session. Returns the new session on success.
    ///
    /// Photos (docs/API.md §4.9): the session does not exist yet when the prompt is written, so with photos we create the
    /// worktree first, upload the images into it (`POST .../worktrees/{wt}/attachments`), then start the agent with the
    /// image paths appended to the prompt, one per line. Without photos a new worktree uses the one-shot `POST /v1/tasks`.
    func submit() async -> Session? {
        if chat { return await submitChat() }
        guard canSubmit, let conn, let loc = locationObject, let agent else { return nil }
        error = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelArg = agent.canPickModel ? model.flatMap { $0.isEmpty ? nil : $0 } : nil
        let effortArg = agent.canPickEffort ? effort.flatMap { $0.isEmpty ? nil : $0 } : nil
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleArg = t.isEmpty ? nil : t
        let baseArg = effectiveBase.isEmpty ? nil : effectiveBase
        var session: Session?
        do {
            if isNew && photos.isEmpty {
                stage = .starting
                let r = try await conn.client.createTask(TaskCreator.request(
                    location: loc.name, worktree: worktreeName, base: baseArg,
                    agent: agent.id, prompt: text, model: modelArg, effort: effortArg, title: titleArg))
                session = r.session
            } else {
                let wtName: String
                let ref: String
                if isNew {
                    stage = .creatingWorktree
                    let wt = try await conn.client.createWorktree(location: loc.name, WorktreeRequest(name: worktreeName, branch: worktreeName, base: baseArg))
                    wtName = wt.name; ref = loc.ref(wt)
                    // From here on a retry must reuse the worktree we just made.
                    await conn.refreshLocations()
                    target = .existing(wt.name)
                } else if let wt = existingWorktree {
                    wtName = wt.name; ref = loc.ref(wt)
                } else { stage = .idle; return nil }
                var paths: [String] = []
                for (i, p) in photos.enumerated() {
                    stage = .uploading(i + 1, photos.count)
                    paths.append(try await conn.uploadToWorktree(location: loc.name, worktree: wtName, name: p.name, data: p.data).path)
                }
                stage = .starting
                let full = paths.isEmpty ? text : text + "\n\n" + paths.joined(separator: "\n")
                session = try await conn.client.startSession(SessionRequest(
                    location: ref, agent: agent.id, prompt: full, model: modelArg, effort: effortArg, title: titleArg))
            }
        } catch {
            stage = .idle
            self.error = ComposeErrorText.message(error)
            return nil
        }
        stage = .idle
        Haptic.success()
        app?.prefs.setComposeDraft("")
        app?.prefs.noteComposed(box: box, location: loc.name, pick: .init(agent: agent.id, model: modelArg, effort: effortArg))
        conn.scheduleRefresh(sessions: true, locations: true)
        if let session {   // the Live Activity manager follows new tasks
            NotificationCenter.default.post(name: .pierTaskCreated, object: nil, userInfo: ["box": box, "session": session.name])
            // No title typed: Haiku on the box writes one from the prompt (in the background; failures keep the box's).
            if titleArg == nil { AITitler.titleNewTask(box: box, session: session, prompt: text, model: app) }
        }
        return session
    }

    /// A chat: `POST /v1/sessions` with `chat: true`. The box makes the agent's folder; the first message is its prompt
    /// (photos need a folder before the agent starts, so a chat takes them once it runs, from its composer).
    private func submitChat() async -> Session? {
        guard canSubmit, let conn, let agent else { return nil }
        error = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelArg = agent.canPickModel ? model.flatMap { $0.isEmpty ? nil : $0 } : nil
        let effortArg = agent.canPickEffort ? effort.flatMap { $0.isEmpty ? nil : $0 } : nil
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        stage = .starting
        let session: Session
        do {
            session = try await conn.client.startSession(SessionRequest(
                agent: agent.id, prompt: text, model: modelArg, effort: effortArg, title: t.isEmpty ? nil : t, chat: true))
        } catch {
            stage = .idle
            self.error = ComposeErrorText.message(error)
            return nil
        }
        stage = .idle
        Haptic.success()
        app?.prefs.setComposeDraft("")
        app?.prefs.noteChatted(box: box, pick: .init(agent: agent.id, model: modelArg, effort: effortArg))
        conn.scheduleRefresh(sessions: true)
        NotificationCenter.default.post(name: .pierTaskCreated, object: nil, userInfo: ["box": box, "session": session.name])
        return session
    }
}
