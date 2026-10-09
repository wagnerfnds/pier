import Foundation

/// A worktree's own service (`GET /v1/locations/{l}/worktrees/{w}/services`): a systemd unit pierd runs.
public struct WorktreeService: Codable, Sendable, Hashable {
    public let name: String
    public let state: String?
    public let port: Int?
    public let unit: String?
    public var isRunning: Bool { state == "running" }
    public init(name: String, state: String? = nil, port: Int? = nil, unit: String? = nil) {
        self.name = name; self.state = state; self.port = port; self.unit = unit
    }
}

extension BoxAPI {
    public func worktreeServices(location: String, worktree: String) async throws -> [WorktreeService] {
        try await get("/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/services")
    }

    /// `start`, `stop` or `restart` one service of a worktree.
    public func serviceAction(location: String, worktree: String, service: String, _ action: String) async throws {
        _ = try await call(.post, "/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/services/\(Self.seg(service))/\(Self.seg(action))")
    }
}

/// "Faxina": what can be cleaned on a box and what each step risks. Pure over the box's lists, so it is testable and the
/// same plan feeds the screen (person picks) and the automation (safe steps only).
public enum Housekeeping {
    public enum Kind: String, Sendable, Hashable, Codable {
        case updateMain        // git pull --ff-only in a project's main checkout
        case removeWorktree    // DELETE worktree (stops its services, kills its sessions), branch deleted
        case stopServices      // stop the services of a worktree kept (it has work not sent yet)
        case dropSession       // forget a session that already exited
    }

    public struct Step: Sendable, Hashable, Identifiable {
        public let kind: Kind
        public let location: String
        public let worktree: String
        public let session: String?
        /// Nothing can be lost (pushed or merged, nothing uncommitted, no agent working there). Automation runs only these.
        public let safe: Bool
        /// Why it is (not) safe, for the person: "3 arquivos não commitados", "2 commits sem push", "PR enviado".
        public let note: String
        public var id: String { "\(kind.rawValue)|\(location)|\(worktree)|\(session ?? "")" }
    }

    /// - Parameters:
    ///   - worktrees: `GET /v1/worktrees` (every worktree's git state; `ahead` counts against `base`, which is the branch's
    ///     upstream once pushed, else the main branch).
    ///   - sessions: the box's sessions.
    ///   - services: `GET /v1/services` (listening dev servers by worktree).
    public static func plan(worktrees: [WorktreeStatus], sessions: [Session], services: [BoxService]) -> [Step] {
        var steps: [Step] = []
        let live = sessions.filter { !$0.exited && $0.service == nil }
        let serving = Set(services.map { "\($0.location)/\($0.worktree ?? $0.location)" })

        for w in worktrees where w.error == nil {
            if w.main == true {
                // Every project's main: `behind` is only as fresh as the last fetch, and the pull fetches anyway.
                let dirty = w.changed > 0
                steps.append(Step(kind: .updateMain, location: w.location, worktree: w.name, session: nil, safe: !dirty,
                                  note: dirty ? "main com \(w.changed) arquivo(s) alterado(s): não atualiza sozinha"
                                              : w.behind > 0 ? "\(w.behind) commit(s) atrás: git pull --ff-only" : "git pull --ff-only"))
                continue
            }
            // Someone is on it: an agent working, waiting, or a finished turn the person will carry on.
            let ref = "\(w.location)/\(w.name)"
            if w.sessions > 0 || live.contains(where: { $0.location == ref }) { continue }
            var risks: [String] = []
            if w.changed > 0 { risks.append("\(w.changed) arquivo(s) alterado(s)") }
            if w.untracked > 0 { risks.append("\(w.untracked) arquivo(s) novo(s) fora do git") }
            let pushed = w.branch != nil && w.base == "origin/\(w.branch!)"
            if w.ahead > 0 { risks.append(pushed ? "\(w.ahead) commit(s) sem push" : "\(w.ahead) commit(s) só nesta máquina") }
            let note = risks.isEmpty ? (pushed ? "branch enviada; nada local a perder" : "nada além da base") : risks.joined(separator: " · ")
            steps.append(Step(kind: .removeWorktree, location: w.location, worktree: w.name, session: nil, safe: risks.isEmpty, note: note))
            if !risks.isEmpty, serving.contains(ref) {
                steps.append(Step(kind: .stopServices, location: w.location, worktree: w.name, session: nil, safe: true,
                                  note: "sem sessão; a worktree fica porque tem trabalho não enviado"))
            }
        }
        for s in sessions where s.exited && s.isAgent {
            let (loc, wt) = WorktreeRef.split(s.location)
            steps.append(Step(kind: .dropSession, location: loc, worktree: wt ?? loc, session: s.name, safe: true, note: "sessão já encerrada"))
        }
        return steps
    }
}

/// "loc/wt" -> ("loc", "wt"); a main checkout is just "loc".
enum WorktreeRef {
    static func split(_ ref: String?) -> (String, String?) {
        guard let ref, let i = ref.firstIndex(of: "/") else { return (ref ?? "", nil) }
        return (String(ref[..<i]), String(ref[ref.index(after: i)...]))
    }
}

extension GitActions {
    /// In a project's main checkout: fast-forward to its upstream, only when nothing tracked is modified.
    /// Prints `PIER_MAIN_OK <sha>`, `PIER_MAIN_DIRTY` or git's error.
    public static let updateMain = """
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo PIER_MAIN_DIRTY; exit 0; fi; \
    git pull --ff-only -q 2>&1 && echo "PIER_MAIN_OK $(git rev-parse --short HEAD)"
    """

    public enum MainUpdate: Equatable, Sendable { case updated(String), dirty, failed(String) }

    public static func parseUpdateMain(exitCode: Int, output: String) -> MainUpdate {
        if output.contains("PIER_MAIN_DIRTY") { return .dirty }
        if exitCode == 0, let line = output.split(separator: "\n").last(where: { $0.hasPrefix("PIER_MAIN_OK") }) {
            return .updated(String(line.dropFirst("PIER_MAIN_OK ".count)))
        }
        let msg = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "exit \(exitCode)"
        return .failed(msg)
    }
}
