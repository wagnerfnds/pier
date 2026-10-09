import Foundation
import PierKit

/// Suggested next steps per finished turn (`NextSteps`, PierKit): generated once per turn on the box (`claude -p --model
/// haiku` through `exec` in the session's worktree), kept in memory and in a small file so a relaunch does not ask again.
/// Asked lazily, by whichever shows the turn first (an Inbox card or the end of the session's chat); never sent by itself.
@MainActor @Observable
final class NextStepsStore {
    static let shared = NextStepsStore()

    enum Phase: Equatable {
        case loading
        case ready([String])
        /// No suggestions this time (no CLI on the box, a failure, an unreadable answer): nothing is shown.
        case failed(Date)
    }

    private(set) var phases: [String: Phase] = [:]
    @ObservationIgnored private let url = Shared.supportDirectory.appendingPathComponent("next-steps.json")
    @ObservationIgnored private var saved: [String: Saved] = [:]

    private struct Saved: Codable { var replies: [String]; var at: Date }

    init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: Saved].self, from: d) {
            saved = v
            for (k, s) in v { phases[k] = .ready(s.replies) }
        }
    }

    func phase(_ key: NextSteps.Key) -> Phase? { phases[key.id] }

    /// The turn's suggestions, asked once (a failure is tried again after two minutes, when the turn is shown again).
    /// `place` is the session's own (`Session.execPlace`): the model runs in its worktree, or in a chat's folder.
    func request(_ key: NextSteps.Key, place: ExecPlace?, reply: String?, task: String?, client: (any PierBoxClient)?) {
        guard let client, let place,
              let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return }
        switch phases[key.id] {
        case .loading?, .ready?: return
        case .failed(let at)? where Date().timeIntervalSince(at) < 120: return
        default: break
        }
        phases[key.id] = .loading
        let command = NextSteps.command(reply: reply, task: task)
        Task {
            let r = try? await client.exec(at: place, command: command, timeout: "90s")
            if let r, r.exitCode == 0, let replies = NextSteps.parse(r.output) {
                phases[key.id] = .ready(replies)
                remember(key.id, replies)
            } else {
                phases[key.id] = .failed(Date())
            }
        }
    }

    private func remember(_ id: String, _ replies: [String]) {
        saved[id] = Saved(replies: replies, at: Date())
        // Keep the file small: the newest 150 turns.
        if saved.count > 150 {
            for (k, _) in saved.sorted(by: { $0.value.at < $1.value.at }).prefix(saved.count - 150) { saved[k] = nil }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: url, options: .atomic) }
    }
}
