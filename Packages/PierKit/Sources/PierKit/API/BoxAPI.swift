import Foundation

/// `PierBoxClient` over a `PierTransport` (production: a `BoxClient`).
public final class BoxAPI: PierBoxClient, Sendable {
    public let transport: any PierTransport
    private let streamer: EventStreamer
    private let decoder = JSONDecoder.pier

    public init(transport: any PierTransport, eventPolicy: EventStreamPolicy = .default) {
        self.transport = transport
        self.streamer = EventStreamer(transport: transport, policy: eventPolicy)
    }

    public convenience init(client: BoxClient) { self.init(transport: client) }

    // MARK: plumbing

    /// Run one request. Box errors (`{"error","code"}` or plain text) become `BoxError`;
    /// transport / revoked / rate-limit failures stay `PierError`.
    @discardableResult
    func call(_ method: BoxClient.Method, _ path: String, body: (any Encodable)? = nil) async throws -> (status: Int, data: Data) {
        let payload: Data? = try body.map { try Self.encode($0) }
        do {
            return try await transport.send(method, path: path, body: payload)
        } catch PierError.api(let status, let message, let code) {
            throw BoxError(status: status, error: message, code: code)
        }
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try decode(try await call(.get, path).data)
    }

    func decode<T: Decodable>(_ data: Data, as: T.Type = T.self) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch {
            throw PierError.decoding("\(T.self): \(error)")
        }
    }

    static func encode(_ value: any Encodable) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try enc.encode(AnyEncodable(value))
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        init(_ v: any Encodable) { value = v }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    // MARK: paths

    /// Percent-encode one path segment (`#` in turn ids, `/`, spaces, ...).
    static func seg(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? s
    }
    private static let segmentAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
    private static let queryAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~,")
        return cs
    }()

    /// `path` + `?a=b&c=d` (values percent-encoded, nil values dropped).
    static func url(_ path: String, _ query: [(String, String?)] = []) -> String {
        let items = query.compactMap { k, v in v.map { "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? $0)" } }
        return items.isEmpty ? path : path + "?" + items.joined(separator: "&")
    }

    private func sessionPath(_ s: String, _ tail: String = "") -> String { "/v1/sessions/\(Self.seg(s))\(tail)" }

    // MARK: 1 info & health

    public func info() async throws -> BoxInfo { try await get("/v1/info") }
    public func stats() async throws -> BoxStats { try await get("/v1/stats") }
    public func doctor() async throws -> [DoctorCheck] { try await get("/v1/doctor") }

    // MARK: 2 locations & worktrees

    public func locations() async throws -> [Location] { try await get("/v1/locations") }

    public func worktreeStatuses(location: String?) async throws -> [WorktreeStatus] {
        try await get(Self.url("/v1/worktrees", [("location", location)]))
    }

    public func branches(location: String) async throws -> BranchList {
        try await get("/v1/locations/\(Self.seg(location))/branches")
    }

    public func createWorktree(location: String, _ req: WorktreeRequest) async throws -> Worktree {
        try decode(try await call(.post, "/v1/locations/\(Self.seg(location))/worktrees", body: req).data)
    }

    public func removeWorktree(location: String, worktree: String, force: Bool, deleteBranch: Bool) async throws -> WorktreeRemoval {
        let path = Self.url(
            "/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))",
            [("force", force ? "1" : nil), ("delete_branch", deleteBranch ? "1" : nil)])
        let (status, data) = try await call(.delete, path)
        struct R: Decodable { let removed: String?; let removing: String?; let archive: String? }
        let r: R = try decode(data)
        if status == 202 || r.removing != nil { return .archiving(script: r.archive ?? "") }
        return .removed(r.removed ?? worktree)
    }

    // MARK: 3 agents & tasks

    public func createTask(_ req: TaskRequest) async throws -> TaskResult {
        try decode(try await call(.post, "/v1/tasks", body: req).data)
    }

    public func startSession(_ req: SessionRequest) async throws -> Session {
        try decode(try await call(.post, "/v1/sessions", body: req).data)
    }

    public func installableAgents() async throws -> [AgentCLI] { try await get("/v1/agents") }

    // MARK: 4 sessions

    public func sessions() async throws -> [Session] { try await get("/v1/sessions") }

    public func screen(session: String, history: Int) async throws -> String {
        struct R: Decodable { let screen: String? }
        let r: R = try await get(Self.url(sessionPath(session, "/screen"), [("history", history > 0 ? String(history) : nil)]))
        return r.screen ?? ""
    }

    public func draft(session: String) async throws -> Draft { try await get(sessionPath(session, "/draft")) }

    public func send(session: String, _ req: SendRequest) async throws -> SendResult {
        try decode(try await call(.post, sessionPath(session, "/send"), body: req).data)
    }

    public func keys(session: String, _ keys: [ControlKey]) async throws {
        struct B: Encodable { let keys: [String] }
        try await call(.post, sessionPath(session, "/keys"), body: B(keys: keys.map(\.rawValue)))
    }

    public func interrupt(session: String) async throws -> InterruptResult {
        try decode(try await call(.post, sessionPath(session, "/interrupt")).data)
    }

    public func kill(session: String) async throws {
        try await call(.delete, sessionPath(session))
    }

    public func rename(session: String, title: String) async throws -> Session {
        struct B: Encodable { let title: String }
        return try decode(try await call(.patch, sessionPath(session), body: B(title: title)).data)
    }

    public func controls(session: String) async throws -> SessionControls { try await get(sessionPath(session, "/controls")) }

    public func setMode(session: String, mode: String) async throws -> String {
        struct B: Encodable { let mode: String }
        struct R: Decodable { let mode: String? }
        let r: R = try decode(try await call(.post, sessionPath(session, "/mode"), body: B(mode: mode)).data)
        return r.mode ?? mode
    }

    public func heldPrompts(session: String) async throws -> [HeldPrompt] { try await get(sessionPath(session, "/queue")) }

    public func cancelHeld(session: String, turn: String) async throws {
        try await call(.delete, sessionPath(session, "/queue/\(Self.seg(turn))"))
    }

    public func sendHeldNow(session: String, turn: String, force: Bool) async throws -> SendResult {
        struct B: Encodable { let force: Bool }
        return try decode(try await call(.post, sessionPath(session, "/queue/\(Self.seg(turn))/send"), body: B(force: force)).data)
    }

    public func turns(session: String, limit: Int) async throws -> [Turn] {
        try await get(Self.url(sessionPath(session, "/turns"), [("limit", String(max(1, min(limit, 500))))]))
    }

    /// Long-poll. `after` should be a `SendResult.at` (box clock). `BoxClient` gives a GET 45 s, so the box's wait is
    /// capped at `maxWaitSeconds`: longer waits would time out on the phone (and drop the connection) before the box answers.
    public static let maxWaitSeconds = 40

    public func waitForSession(_ session: String, states: [AgentState], after: Date?, timeout: Duration) async throws -> WaitResult {
        let secs = min(Self.maxWaitSeconds, max(1, Int(timeout.components.seconds)))
        let path = Self.url(
            sessionPath(session, "/wait"),
            [
                ("for", states.isEmpty ? nil : states.map(\.rawValue).joined(separator: ",")),
                ("after", after.map(RFC3339.format)),
                ("timeout", "\(secs)s"),
            ])
        return try await get(path)
    }

    public func uploadAttachment(session: String, name: String, data: Data) async throws -> Attachment {
        struct B: Encodable { let name: String; let data: String }
        return try decode(try await call(.post, sessionPath(session, "/attachments"), body: B(name: name, data: data.base64EncodedString())).data)
    }

    // MARK: 5 needs you

    public func answerQuestions(session: String, tool: String, answers: [QuestionAnswer]) async throws -> [String] {
        struct B: Encodable { let tool: String; let answers: [QuestionAnswer] }
        struct R: Decodable { let answered: [String]? }
        let r: R = try decode(try await call(.post, sessionPath(session, "/answer"), body: B(tool: tool, answers: answers)).data)
        return r.answered ?? []
    }

    // MARK: 6 transcript

    public func transcript(session: String, since: Int, gen: String?) async throws -> TranscriptPage {
        try await get(Self.url(sessionPath(session, "/transcript"), [("since", String(since)), ("gen", gen)]))
    }

    public func transcriptBefore(session: String, before: Int64, limit: Int) async throws -> TranscriptPage {
        try await get(Self.url(sessionPath(session, "/transcript"), [("before", String(before)), ("limit", String(min(max(limit, 1), 300)))]))
    }

    public func toolDetail(session: String, id: String) async throws -> ToolDetail {
        try await get(sessionPath(session, "/transcript/tool/\(Self.seg(id))"))
    }

    // MARK: 7 events

    public func events(since: Int64?) -> AsyncThrowingStream<PierEvent, Error> { streamer.events(since: since) }

    /// Like `events(since:)`, reporting connection state changes.
    public func events(since: Int64?, onState: @escaping @Sendable (EventConnectionState) -> Void) -> AsyncThrowingStream<PierEvent, Error> {
        streamer.events(since: since, onState: onState)
    }

    public func reset() async {
        await transport.reset()
        streamer.reset()
    }

    // MARK: 8 review / git

    public func review(all: Bool) async throws -> [ReviewItem] {
        try await get(Self.url("/v1/review", [("all", all ? "1" : nil)]))
    }

    public func touched(location: String, worktree: String) async throws -> [TouchedFile] {
        struct R: Decodable { let files: [TouchedFile]? }
        let r: R = try await get("/v1/locations/\(Self.seg(location))/worktrees/\(Self.seg(worktree))/touched")
        return r.files ?? []
    }

    public func fileDiff(session: String, file: String) async throws -> FileDiff {
        try await get(Self.url(sessionPath(session, "/diff"), [("file", file)]))
    }

    public func exec(location: String, command: String, timeout: String) async throws -> ExecResult {
        struct B: Encodable { let location: String; let command: String; let timeout: String }
        return try decode(try await call(.post, "/v1/exec", body: B(location: location, command: command, timeout: timeout)).data)
    }

    public func exec(session: String, command: String, timeout: String) async throws -> ExecResult {
        struct B: Encodable { let session: String; let command: String; let timeout: String }
        return try decode(try await call(.post, "/v1/exec", body: B(session: session, command: command, timeout: timeout)).data)
    }

}
