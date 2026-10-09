// Codable models of pierd's JSON (docs/API.md §13.3), checked against the Go structs in Server/pierd.
import Foundation

/// What a waiting agent asks for (from its hooks; never file contents).
public struct Ask: Codable, Sendable, Hashable {
    public let tool: String?
    public let input: String?
    public let why: String?
    public let message: String?

    public init(tool: String? = nil, input: String? = nil, why: String? = nil, message: String? = nil) {
        self.tool = tool
        self.input = input
        self.why = why
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case tool
        case input
        case why
        case message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tool = try c.decodeIfPresent(String.self, forKey: .tool)
        self.input = try c.decodeIfPresent(String.self, forKey: .input)
        self.why = try c.decodeIfPresent(String.self, forKey: .why)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct Session: Codable, Sendable, Identifiable, Hashable {
    public let name: String
    public let location: String?
    public let dir: String
    public let command: String?
    public let created: Date
    public let attached: Int
    public let exited: Bool
    public let agent: String?
    public let agentState: AgentState?
    public let stateSince: Date?
    public let preset: String?
    public let turn: String?
    public let stateSeq: Int64?
    public let fidelity: String?
    public let title: String?
    public let queued: Int?
    public let ask: Ask?
    public let service: String?
    /// A conversation that belongs to no project (capability `session.chat`): an agent with no location, in a folder
    /// of its own under `~/pier/chats` on the box. No worktree, so no review, services or worktree cleanup.
    public let chat: Bool

    public init(name: String, location: String? = nil, dir: String = "", command: String? = nil, created: Date = Date(timeIntervalSince1970: 0), attached: Int = 0, exited: Bool = false, agent: String? = nil, agentState: AgentState? = nil, stateSince: Date? = nil, preset: String? = nil, turn: String? = nil, stateSeq: Int64? = nil, fidelity: String? = nil, title: String? = nil, queued: Int? = nil, ask: Ask? = nil, service: String? = nil, chat: Bool = false) {
        self.name = name
        self.location = location
        self.dir = dir
        self.command = command
        self.created = created
        self.attached = attached
        self.exited = exited
        self.agent = agent
        self.agentState = agentState
        self.stateSince = stateSince
        self.preset = preset
        self.turn = turn
        self.stateSeq = stateSeq
        self.fidelity = fidelity
        self.title = title
        self.queued = queued
        self.ask = ask
        self.service = service
        self.chat = chat
    }

    enum CodingKeys: String, CodingKey {
        case name
        case location
        case dir
        case command
        case created
        case attached
        case exited
        case agent
        case agentState = "agent_state"
        case stateSince = "state_since"
        case preset
        case turn
        case stateSeq = "state_seq"
        case fidelity
        case title
        case queued
        case ask
        case service
        case chat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.location = try c.decodeIfPresent(String.self, forKey: .location)
        self.dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
        self.attached = try c.decodeIfPresent(Int.self, forKey: .attached) ?? 0
        self.exited = try c.decodeIfPresent(Bool.self, forKey: .exited) ?? false
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent)
        self.agentState = try c.decodeIfPresent(AgentState.self, forKey: .agentState)
        self.stateSince = try c.decodeIfPresent(Date.self, forKey: .stateSince)
        self.preset = try c.decodeIfPresent(String.self, forKey: .preset)
        self.turn = try c.decodeIfPresent(String.self, forKey: .turn)
        self.stateSeq = try c.decodeIfPresent(Int64.self, forKey: .stateSeq)
        self.fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.queued = try c.decodeIfPresent(Int.self, forKey: .queued)
        self.ask = try c.decodeIfPresent(Ask.self, forKey: .ask)
        self.service = try c.decodeIfPresent(String.self, forKey: .service)
        self.chat = try c.decodeIfPresent(Bool.self, forKey: .chat) ?? false
    }

    public var id: String { name }
    public var isAgent: Bool { agent != nil && service == nil }
    public var needsYou: Bool { agentState == .waiting && !exited }
}

/// `POST /v1/tasks`. Never set `open` from iOS (not modelled).
public struct TaskRequest: Codable, Sendable, Hashable {
    public var location: String
    public var name: String
    public var branch: String?
    public var base: String?
    public var pr: Int?
    public var ref: String?
    public var agent: String?
    public var command: String?
    public var prompt: String?
    public var model: String?
    public var effort: String?
    public var title: String?
    public var fromSession: String?

    public init(location: String, name: String, branch: String? = nil, base: String? = nil, pr: Int? = nil, ref: String? = nil, agent: String? = nil, command: String? = nil, prompt: String? = nil, model: String? = nil, effort: String? = nil, title: String? = nil, fromSession: String? = nil) {
        self.location = location
        self.name = name
        self.branch = branch
        self.base = base
        self.pr = pr
        self.ref = ref
        self.agent = agent
        self.command = command
        self.prompt = prompt
        self.model = model
        self.effort = effort
        self.title = title
        self.fromSession = fromSession
    }

    enum CodingKeys: String, CodingKey {
        case location
        case name
        case branch
        case base
        case pr
        case ref
        case agent
        case command
        case prompt
        case model
        case effort
        case title
        case fromSession = "from_session"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.location = try c.decode(String.self, forKey: .location)
        self.name = try c.decode(String.self, forKey: .name)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.base = try c.decodeIfPresent(String.self, forKey: .base)
        self.pr = try c.decodeIfPresent(Int.self, forKey: .pr)
        self.ref = try c.decodeIfPresent(String.self, forKey: .ref)
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent)
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(String.self, forKey: .effort)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.fromSession = try c.decodeIfPresent(String.self, forKey: .fromSession)
    }
}

public struct TaskResult: Codable, Sendable, Hashable {
    public let worktree: Worktree
    public let session: Session

    public init(worktree: Worktree, session: Session) {
        self.worktree = worktree
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case worktree
        case session
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.worktree = try c.decode(Worktree.self, forKey: .worktree)
        self.session = try c.decode(Session.self, forKey: .session)
    }
}

public struct SessionRequest: Codable, Sendable, Hashable {
    public var location: String?
    public var name: String?
    public var agent: String?
    public var command: String?
    public var prompt: String?
    public var model: String?
    public var effort: String?
    public var title: String?
    public var home: Bool?
    /// A chat (capability `session.chat`): `agent` with no `location`, in a folder of its own on the box.
    public var chat: Bool?

    public init(location: String? = nil, name: String? = nil, agent: String? = nil, command: String? = nil, prompt: String? = nil, model: String? = nil, effort: String? = nil, title: String? = nil, home: Bool? = nil, chat: Bool? = nil) {
        self.location = location
        self.name = name
        self.agent = agent
        self.command = command
        self.prompt = prompt
        self.model = model
        self.effort = effort
        self.title = title
        self.home = home
        self.chat = chat
    }

    enum CodingKeys: String, CodingKey {
        case location
        case name
        case agent
        case command
        case prompt
        case model
        case effort
        case title
        case home
        case chat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.location = try c.decodeIfPresent(String.self, forKey: .location)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent)
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(String.self, forKey: .effort)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.home = try c.decodeIfPresent(Bool.self, forKey: .home)
        self.chat = try c.decodeIfPresent(Bool.self, forKey: .chat)
    }
}

/// `at` is the box clock: pass it back as `after` to `waitForSession`.
public struct SendResult: Codable, Sendable, Hashable {
    public let sent: Bool
    public let queued: Bool?
    public let duplicate: Bool?
    public let turn: String?
    public let seq: Int64?
    public let at: Date

    public init(sent: Bool = false, queued: Bool? = nil, duplicate: Bool? = nil, turn: String? = nil, seq: Int64? = nil, at: Date = Date()) {
        self.sent = sent
        self.queued = queued
        self.duplicate = duplicate
        self.turn = turn
        self.seq = seq
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case sent
        case queued
        case duplicate
        case turn
        case seq
        case at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sent = try c.decodeIfPresent(Bool.self, forKey: .sent) ?? false
        self.queued = try c.decodeIfPresent(Bool.self, forKey: .queued)
        self.duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate)
        self.turn = try c.decodeIfPresent(String.self, forKey: .turn)
        self.seq = try c.decodeIfPresent(Int64.self, forKey: .seq)
        self.at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }
}

public struct InterruptResult: Codable, Sendable, Hashable {
    public let sent: Bool
    public let stopped: Bool

    public init(sent: Bool = false, stopped: Bool = false) {
        self.sent = sent
        self.stopped = stopped
    }

    enum CodingKeys: String, CodingKey {
        case sent
        case stopped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sent = try c.decodeIfPresent(Bool.self, forKey: .sent) ?? false
        self.stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }
}

public struct SessionControls: Codable, Sendable, Hashable {
    public let agent: String
    public let mode: String?
    public let effort: String?
    public let modes: [String]?
    public let limit: String?

    public init(agent: String = "", mode: String? = nil, effort: String? = nil, modes: [String]? = nil, limit: String? = nil) {
        self.agent = agent
        self.mode = mode
        self.effort = effort
        self.modes = modes
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case agent
        case mode
        case effort
        case modes
        case limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode)
        self.effort = try c.decodeIfPresent(String.self, forKey: .effort)
        self.modes = try c.decodeIfPresent([String].self, forKey: .modes)
        self.limit = try c.decodeIfPresent(String.self, forKey: .limit)
    }
}

public struct HeldPrompt: Codable, Sendable, Hashable, Identifiable {
    public let turn: String
    public let preview: String
    public let length: Int
    public let origin: String?
    public let at: Date

    public init(turn: String, preview: String = "", length: Int = 0, origin: String? = nil, at: Date = Date()) {
        self.turn = turn
        self.preview = preview
        self.length = length
        self.origin = origin
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case turn
        case preview
        case length
        case origin
        case at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.turn = try c.decode(String.self, forKey: .turn)
        self.preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        self.length = try c.decodeIfPresent(Int.self, forKey: .length) ?? 0
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin)
        self.at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }

    public var id: String { turn }
}

extension Turn {
    public struct Wait: Codable, Sendable, Hashable {
        public let start: Date
        public let end: Date?
        public let reason: String?
        public let ask: Ask?

        public init(start: Date, end: Date? = nil, reason: String? = nil, ask: Ask? = nil) {
            self.start = start
            self.end = end
            self.reason = reason
            self.ask = ask
        }

        enum CodingKeys: String, CodingKey {
            case start
            case end
            case reason
            case ask
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.start = try c.decode(Date.self, forKey: .start)
            self.end = try c.decodeIfPresent(Date.self, forKey: .end)
            self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
            self.ask = try c.decodeIfPresent(Ask.self, forKey: .ask)
        }
    }
}

public struct Turn: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let session: String
    public let agent: String?
    public let n: Int
    public let origin: String?
    public let state: String
    public let queued: Date?
    public let started: Date?
    public let ended: Date?
    public let waits: [Turn.Wait]?
    public let fidelity: String?
    public let idemKey: String?
    public let status: String?
    public let sent: Date?
    public let sentSeq: Int64?
    public let endSeq: Int64?

    public init(id: String, session: String = "", agent: String? = nil, n: Int = 0, origin: String? = nil, state: String = "", queued: Date? = nil, started: Date? = nil, ended: Date? = nil, waits: [Turn.Wait]? = nil, fidelity: String? = nil, idemKey: String? = nil, status: String? = nil, sent: Date? = nil, sentSeq: Int64? = nil, endSeq: Int64? = nil) {
        self.id = id
        self.session = session
        self.agent = agent
        self.n = n
        self.origin = origin
        self.state = state
        self.queued = queued
        self.started = started
        self.ended = ended
        self.waits = waits
        self.fidelity = fidelity
        self.idemKey = idemKey
        self.status = status
        self.sent = sent
        self.sentSeq = sentSeq
        self.endSeq = endSeq
    }

    enum CodingKeys: String, CodingKey {
        case id
        case session
        case agent
        case n
        case origin
        case state
        case queued
        case started
        case ended
        case waits
        case fidelity
        case idemKey = "idem_key"
        case status
        case sent
        case sentSeq = "sent_seq"
        case endSeq = "end_seq"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent)
        self.n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 0
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        self.queued = try c.decodeIfPresent(Date.self, forKey: .queued)
        self.started = try c.decodeIfPresent(Date.self, forKey: .started)
        self.ended = try c.decodeIfPresent(Date.self, forKey: .ended)
        self.waits = try c.decodeIfPresent([Turn.Wait].self, forKey: .waits)
        self.fidelity = try c.decodeIfPresent(String.self, forKey: .fidelity)
        self.idemKey = try c.decodeIfPresent(String.self, forKey: .idemKey)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.sent = try c.decodeIfPresent(Date.self, forKey: .sent)
        self.sentSeq = try c.decodeIfPresent(Int64.self, forKey: .sentSeq)
        self.endSeq = try c.decodeIfPresent(Int64.self, forKey: .endSeq)
    }
}

public struct WaitResult: Codable, Sendable, Hashable {
    public let state: String
    public let timedOut: Bool
    public let turn: String?

    public init(state: String = "", timedOut: Bool = false, turn: String? = nil) {
        self.state = state
        self.timedOut = timedOut
        self.turn = turn
    }

    enum CodingKeys: String, CodingKey {
        case state
        case timedOut = "timed_out"
        case turn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        self.timedOut = try c.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
        self.turn = try c.decodeIfPresent(String.self, forKey: .turn)
    }
}

extension Draft {
    public struct Status: Codable, Sendable, Hashable {
        public let word: String
        public let elapsed: String?
        public let tokens: String?

        public init(word: String = "", elapsed: String? = nil, tokens: String? = nil) {
            self.word = word
            self.elapsed = elapsed
            self.tokens = tokens
        }

        enum CodingKeys: String, CodingKey {
            case word
            case elapsed
            case tokens
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.word = try c.decodeIfPresent(String.self, forKey: .word) ?? ""
            self.elapsed = try c.decodeIfPresent(String.self, forKey: .elapsed)
            self.tokens = try c.decodeIfPresent(String.self, forKey: .tokens)
        }
    }
}

public struct Draft: Codable, Sendable, Hashable {
    public let agent: String
    public let text: String?
    public let clipped: Bool?
    public let status: Draft.Status?

    public init(agent: String = "", text: String? = nil, clipped: Bool? = nil, status: Draft.Status? = nil) {
        self.agent = agent
        self.text = text
        self.clipped = clipped
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case agent
        case text
        case clipped
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.clipped = try c.decodeIfPresent(Bool.self, forKey: .clipped)
        self.status = try c.decodeIfPresent(Draft.Status.self, forKey: .status)
    }
}

public struct Attachment: Codable, Sendable, Hashable {
    public let path: String
    public let name: String
    public let type: String
    public let size: Int

    public init(path: String, name: String = "", type: String = "", size: Int = 0) {
        self.path = path
        self.name = name
        self.type = type
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case type
        case size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}
