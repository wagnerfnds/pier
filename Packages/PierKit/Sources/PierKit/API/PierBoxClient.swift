import Foundation

/// The typed surface of one box (docs/API.md §13.2). Errors: `BoxError` for box-level failures
/// (`{"error","code"}` or plain text), `PierError` for transport / revoked / rate limited.
public protocol PierBoxClient: Sendable {
    // 1 Info & health
    func info() async throws -> BoxInfo                                   // GET /v1/info
    func stats() async throws -> BoxStats                                 // GET /v1/stats
    func doctor() async throws -> [DoctorCheck]                           // GET /v1/doctor

    // 2 Locations & worktrees
    func locations() async throws -> [Location]                           // GET /v1/locations
    func worktreeStatuses(location: String?) async throws -> [WorktreeStatus]   // GET /v1/worktrees
    func branches(location: String) async throws -> BranchList            // GET /v1/locations/{l}/branches
    func createWorktree(location: String, _ req: WorktreeRequest) async throws -> Worktree
    func removeWorktree(location: String, worktree: String, force: Bool, deleteBranch: Bool) async throws -> WorktreeRemoval  // 200 or 202

    // 3 Agents & tasks
    func createTask(_ req: TaskRequest) async throws -> TaskResult        // POST /v1/tasks
    func startSession(_ req: SessionRequest) async throws -> Session      // POST /v1/sessions
    func installableAgents() async throws -> [AgentCLI]                   // GET /v1/agents

    // 4 Sessions
    func sessions() async throws -> [Session]
    func screen(session: String, history: Int) async throws -> String
    func draft(session: String) async throws -> Draft
    func send(session: String, _ req: SendRequest) async throws -> SendResult
    func keys(session: String, _ keys: [ControlKey]) async throws
    func interrupt(session: String) async throws -> InterruptResult
    func kill(session: String) async throws
    func rename(session: String, title: String) async throws -> Session
    func controls(session: String) async throws -> SessionControls
    func setMode(session: String, mode: String) async throws -> String
    func heldPrompts(session: String) async throws -> [HeldPrompt]
    func cancelHeld(session: String, turn: String) async throws
    func sendHeldNow(session: String, turn: String, force: Bool) async throws -> SendResult
    func turns(session: String, limit: Int) async throws -> [Turn]
    func waitForSession(_ session: String, states: [AgentState], after: Date?, timeout: Duration) async throws -> WaitResult
    func uploadAttachment(session: String, name: String, data: Data) async throws -> Attachment

    // 5 Needs you
    func answerQuestions(session: String, tool: String, answers: [QuestionAnswer]) async throws -> [String]
    // 6 Transcript
    func transcript(session: String, since: Int, gen: String?) async throws -> TranscriptPage
    func transcriptBefore(session: String, before: Int64, limit: Int) async throws -> TranscriptPage
    func toolDetail(session: String, id: String) async throws -> ToolDetail

    // 7 Events
    /// NDJSON events with automatic reconnect and resume by the highest `seq` seen.
    func events(since: Int64?) -> AsyncThrowingStream<PierEvent, Error>

    // 8 Review / git
    func review(all: Bool) async throws -> [ReviewItem]
    func touched(location: String, worktree: String) async throws -> [TouchedFile]
    func fileDiff(session: String, file: String) async throws -> FileDiff
    func exec(location: String, command: String, timeout: String) async throws -> ExecResult
    /// `exec` in a chat's own folder (a chat has no location; `session.chat`).
    func exec(session: String, command: String, timeout: String) async throws -> ExecResult

    // Connection management (addition to §13.2; defaults to a no-op so mocks need not implement it)
    /// Drop the connection and make running event streams reconnect immediately (call on foreground / network change).
    func reset() async
}

/// Where `exec` runs a command: a location (`"loc/wt"`, or `"loc"` for the main checkout), or a chat's own folder.
public enum ExecPlace: Sendable, Equatable {
    case location(String)
    case chat(session: String)
}

extension Session {
    /// Where commands about this session run: its worktree, or its folder for a chat; nil when it has neither.
    public var execPlace: ExecPlace? {
        if chat { return .chat(session: name) }
        if let location, !location.isEmpty { return .location(location) }
        return nil
    }
}

extension PierBoxClient {
    public func reset() async {}

    public func exec(at place: ExecPlace, command: String, timeout: String) async throws -> ExecResult {
        switch place {
        case .location(let l): try await exec(location: l, command: command, timeout: timeout)
        case .chat(let s): try await exec(session: s, command: command, timeout: timeout)
        }
    }

    public func worktreeStatuses() async throws -> [WorktreeStatus] { try await worktreeStatuses(location: nil) }
    public func screen(session: String) async throws -> String { try await screen(session: session, history: 0) }
    public func events() -> AsyncThrowingStream<PierEvent, Error> { events(since: nil) }
    public func exec(location: String, command: String) async throws -> ExecResult {
        try await exec(location: location, command: command, timeout: "60s")
    }
    public func sendKey(session: String, _ key: String) async throws -> SendResult {
        try await send(session: session, .key(key))
    }
}
