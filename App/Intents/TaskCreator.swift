import Foundation
import PierKit

/// Builds and runs "new worktree task" requests; shared by the Compose form (request building) and App Intents (whole flow).
enum TaskCreator {
    /// The `POST /v1/tasks` body Compose sends when there are no photos.
    static func request(location: String, worktree: String, base: String?, agent: String, prompt: String,
                        model: String?, effort: String?, title: String?) -> TaskRequest {
        TaskRequest(location: location, name: worktree, branch: worktree, base: base, agent: agent,
                    prompt: prompt, model: model, effort: effort, title: title)
    }

    /// Presets usable at `location`: the project's own plus the box's.
    static func agents(info: BoxInfo?, location: Location?) -> [AgentPreset] { mergedAgents(box: info, location: location) }

    struct Created: Sendable {
        let box: String
        let location: String
        let worktree: String
        let session: Session
        let agent: String
    }

    /// Creates a new worktree with an agent running `prompt`, like Compose does. Picks the agent (preferred, else the project's
    /// last pick, the last used one, `claude`, the first available), validates `model` against the preset.
    @MainActor
    static func create(box: HeadlessBox, info: BoxInfo?, location: Location, prompt: String, agent preferred: String?,
                       model: String?, prefs: LocalPrefs, title: String? = nil, attachments: [(name: String, data: Data)] = []) async throws -> Created {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = agents(info: info, location: location)
        let key = LocalPrefs.key(box: box.name, location: location.name)
        let pick = prefs.pick(for: key)
        let ids = presets.map(\.id)
        let agentID = [preferred, pick?.agent, prefs.lastAgent, "claude"].compactMap { $0 }.first { ids.contains($0) } ?? ids.first ?? "claude"
        let preset = presets.first { $0.id == agentID }
        var modelArg = (model?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        if let m = modelArg, !(WorktreeNaming.isValidChoice(m) && (preset?.canPickModel ?? false)) { modelArg = nil }
        if modelArg == nil, model == nil, pick?.agent == agentID, preset?.canPickModel ?? false { modelArg = pick?.model }
        let effortArg = pick?.agent == agentID && (preset?.canPickEffort ?? false) ? pick?.effort : nil
        let taken = Set((location.worktrees ?? []).map(\.name))
        let name = WorktreeNaming.free(WorktreeNaming.slug(text), taken: taken)
        prefs.noteComposed(box: box.name, location: location.name, pick: .init(agent: agentID, model: modelArg, effort: effortArg))
        if !attachments.isEmpty {
            // Pictures (docs/API.md §4.9): the session does not exist yet, so the worktree is made first, the files go into
            // it (`POST .../worktrees/{wt}/attachments`), and the agent starts with their paths under the prompt.
            let wt = try await box.client.createWorktree(location: location.name, WorktreeRequest(name: name, branch: name, base: location.defaultBranch))
            var paths: [String] = []
            for a in attachments { paths.append(try await box.uploadToWorktree(location: location.name, worktree: wt.name, name: a.name, data: a.data).path) }
            let session = try await box.client.startSession(SessionRequest(location: location.ref(wt), agent: agentID, prompt: text + "\n\n" + paths.joined(separator: "\n"),
                                                                           model: modelArg, effort: effortArg, title: title))
            return Created(box: box.name, location: location.name, worktree: wt.name, session: session, agent: agentID)
        }
        let req = request(location: location.name, worktree: name, base: location.defaultBranch, agent: agentID, prompt: text,
                          model: modelArg, effort: effortArg, title: title)
        let r = try await box.client.createTask(req)
        return Created(box: box.name, location: location.name, worktree: r.worktree.name, session: r.session, agent: agentID)
    }
}
