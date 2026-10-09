// Codable models of pierd's JSON (docs/API.md §13.3), checked against the Go structs in Server/pierd.
import Foundation

extension TranscriptItem {
    public struct Call: Codable, Sendable, Hashable {
        public let verb: String
        public let target: String
        public let file: Bool?
        public let id: String?
        public let at: Int64?

        public init(verb: String = "", target: String = "", file: Bool? = nil, id: String? = nil, at: Int64? = nil) {
            self.verb = verb
            self.target = target
            self.file = file
            self.id = id
            self.at = at
        }

        enum CodingKeys: String, CodingKey {
            case verb
            case target
            case file
            case id
            case at
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.verb = try c.decodeIfPresent(String.self, forKey: .verb) ?? ""
            self.target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
            self.file = try c.decodeIfPresent(Bool.self, forKey: .file)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.at = try c.decodeIfPresent(Int64.self, forKey: .at)
        }
    }
}

extension TranscriptItem {
    public struct Report: Codable, Sendable, Hashable {
        public let kind: String
        public let session: String?
        public let run: String?
        public let template: String?
        public let title: String?
        public let worktree: String?
        public let branch: String?
        public let status: String
        public let duration: String?
        public let files: Int?
        public let added: Int?
        public let removed: Int?
        public let summary: String?
        public let answer: String?
        public let needs: String?

        public init(kind: String = "", session: String? = nil, run: String? = nil, template: String? = nil, title: String? = nil, worktree: String? = nil, branch: String? = nil, status: String = "", duration: String? = nil, files: Int? = nil, added: Int? = nil, removed: Int? = nil, summary: String? = nil, answer: String? = nil, needs: String? = nil) {
            self.kind = kind
            self.session = session
            self.run = run
            self.template = template
            self.title = title
            self.worktree = worktree
            self.branch = branch
            self.status = status
            self.duration = duration
            self.files = files
            self.added = added
            self.removed = removed
            self.summary = summary
            self.answer = answer
            self.needs = needs
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case session
            case run
            case template
            case title
            case worktree
            case branch
            case status
            case duration
            case files
            case added
            case removed
            case summary
            case answer
            case needs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            self.session = try c.decodeIfPresent(String.self, forKey: .session)
            self.run = try c.decodeIfPresent(String.self, forKey: .run)
            self.template = try c.decodeIfPresent(String.self, forKey: .template)
            self.title = try c.decodeIfPresent(String.self, forKey: .title)
            self.worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
            self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
            self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            self.duration = try c.decodeIfPresent(String.self, forKey: .duration)
            self.files = try c.decodeIfPresent(Int.self, forKey: .files)
            self.added = try c.decodeIfPresent(Int.self, forKey: .added)
            self.removed = try c.decodeIfPresent(Int.self, forKey: .removed)
            self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
            self.answer = try c.decodeIfPresent(String.self, forKey: .answer)
            self.needs = try c.decodeIfPresent(String.self, forKey: .needs)
        }
    }
}

/// One transcript entry. `kind` stays a raw string (unknown kinds decode fine); use `type` for the tolerant enum.
public struct TranscriptItem: Codable, Sendable, Identifiable, Hashable {
    public let kind: String
    public let id: String
    public let off: Int64?
    public let text: String?
    public let verb: String?
    public let items: [TranscriptItem.Call]?
    public let done: Bool?
    public let file: String?
    public let added: Int?
    public let removed: Int?
    public let names: [String]?
    public let tool: String?
    public let notice: String?
    public let level: String?
    public let resets: Int64?
    public let command: String?
    public let args: String?
    public let markdown: Bool?
    public let error: Bool?
    public let url: String?
    public let description: String?
    public let updated: Bool?
    public let questions: [Question]?
    public let answers: [String]?
    public let report: TranscriptItem.Report?
    public let uuid: String?
    public let parent: String?
    public let pending: Bool?

    public init(kind: String, id: String, off: Int64? = nil, text: String? = nil, verb: String? = nil, items: [TranscriptItem.Call]? = nil, done: Bool? = nil, file: String? = nil, added: Int? = nil, removed: Int? = nil, names: [String]? = nil, tool: String? = nil, notice: String? = nil, level: String? = nil, resets: Int64? = nil, command: String? = nil, args: String? = nil, markdown: Bool? = nil, error: Bool? = nil, url: String? = nil, description: String? = nil, updated: Bool? = nil, questions: [Question]? = nil, answers: [String]? = nil, report: TranscriptItem.Report? = nil, uuid: String? = nil, parent: String? = nil, pending: Bool? = nil) {
        self.kind = kind
        self.id = id
        self.off = off
        self.text = text
        self.verb = verb
        self.items = items
        self.done = done
        self.file = file
        self.added = added
        self.removed = removed
        self.names = names
        self.tool = tool
        self.notice = notice
        self.level = level
        self.resets = resets
        self.command = command
        self.args = args
        self.markdown = markdown
        self.error = error
        self.url = url
        self.description = description
        self.updated = updated
        self.questions = questions
        self.answers = answers
        self.report = report
        self.uuid = uuid
        self.parent = parent
        self.pending = pending
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case off
        case text
        case verb
        case items
        case done
        case file
        case added
        case removed
        case names
        case tool
        case notice
        case level
        case resets
        case command
        case args
        case markdown
        case error
        case url
        case description
        case updated
        case questions
        case answers
        case report
        case uuid
        case parent
        case pending
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.id = try c.decode(String.self, forKey: .id)
        self.off = try c.decodeIfPresent(Int64.self, forKey: .off)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.verb = try c.decodeIfPresent(String.self, forKey: .verb)
        self.items = try c.decodeIfPresent([TranscriptItem.Call].self, forKey: .items)
        self.done = try c.decodeIfPresent(Bool.self, forKey: .done)
        self.file = try c.decodeIfPresent(String.self, forKey: .file)
        self.added = try c.decodeIfPresent(Int.self, forKey: .added)
        self.removed = try c.decodeIfPresent(Int.self, forKey: .removed)
        self.names = try c.decodeIfPresent([String].self, forKey: .names)
        self.tool = try c.decodeIfPresent(String.self, forKey: .tool)
        self.notice = try c.decodeIfPresent(String.self, forKey: .notice)
        self.level = try c.decodeIfPresent(String.self, forKey: .level)
        self.resets = try c.decodeIfPresent(Int64.self, forKey: .resets)
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.args = try c.decodeIfPresent(String.self, forKey: .args)
        self.markdown = try c.decodeIfPresent(Bool.self, forKey: .markdown)
        self.error = try c.decodeIfPresent(Bool.self, forKey: .error)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.updated = try c.decodeIfPresent(Bool.self, forKey: .updated)
        self.questions = try c.decodeIfPresent([Question].self, forKey: .questions)
        self.answers = try c.decodeIfPresent([String].self, forKey: .answers)
        self.report = try c.decodeIfPresent(TranscriptItem.Report.self, forKey: .report)
        self.uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        self.parent = try c.decodeIfPresent(String.self, forKey: .parent)
        self.pending = try c.decodeIfPresent(Bool.self, forKey: .pending)
    }
}

public struct CrewMember: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let agent: String
    public let state: String
    public let doing: String
    public let since: Int64
    public let until: Int64?

    public init(id: String, name: String = "", kind: String = "", agent: String = "", state: String = "", doing: String = "", since: Int64 = 0, until: Int64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.agent = agent
        self.state = state
        self.doing = doing
        self.since = since
        self.until = until
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case agent
        case state
        case doing
        case since
        case until
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        self.doing = try c.decodeIfPresent(String.self, forKey: .doing) ?? ""
        self.since = try c.decodeIfPresent(Int64.self, forKey: .since) ?? 0
        self.until = try c.decodeIfPresent(Int64.self, forKey: .until)
    }
}

public struct ArtifactRef: Codable, Sendable, Hashable, Identifiable {
    public let url: String
    public let title: String
    public let description: String?
    public let file: String?
    public let at: Int64
    public let tool: String
    public let updated: Bool?

    public init(url: String, title: String = "", description: String? = nil, file: String? = nil, at: Int64 = 0, tool: String = "", updated: Bool? = nil) {
        self.url = url
        self.title = title
        self.description = description
        self.file = file
        self.at = at
        self.tool = tool
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case description
        case file
        case at
        case tool
        case updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decode(String.self, forKey: .url)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.file = try c.decodeIfPresent(String.self, forKey: .file)
        self.at = try c.decodeIfPresent(Int64.self, forKey: .at) ?? 0
        self.tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        self.updated = try c.decodeIfPresent(Bool.self, forKey: .updated)
    }

    public var id: String { url }
}

extension Signals {
    public struct Context: Codable, Sendable, Hashable {
        public let tokens: Int
        public let window: Int?
        public let at: Int64?

        public init(tokens: Int = 0, window: Int? = nil, at: Int64? = nil) {
            self.tokens = tokens
            self.window = window
            self.at = at
        }

        enum CodingKeys: String, CodingKey {
            case tokens
            case window
            case at
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            self.window = try c.decodeIfPresent(Int.self, forKey: .window)
            self.at = try c.decodeIfPresent(Int64.self, forKey: .at)
        }
    }
}

extension Signals {
    public struct Todo: Codable, Sendable, Hashable {
        public let id: String?
        public let text: String
        public let active: String?
        public let status: String

        public init(id: String? = nil, text: String = "", active: String? = nil, status: String = "pending") {
            self.id = id
            self.text = text
            self.active = active
            self.status = status
        }

        enum CodingKeys: String, CodingKey {
            case id
            case text
            case active
            case status
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(String.self, forKey: .id)
            self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            self.active = try c.decodeIfPresent(String.self, forKey: .active)
            self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        }
    }
}

extension Signals {
    public struct Job: Codable, Sendable, Hashable {
        public let tool: String
        public let task: String?
        public let kind: String
        public let command: String
        public let label: String?
        public let state: String
        public let since: Int64
        public let until: Int64?

        public init(tool: String, task: String? = nil, kind: String = "", command: String = "", label: String? = nil, state: String = "", since: Int64 = 0, until: Int64? = nil) {
            self.tool = tool
            self.task = task
            self.kind = kind
            self.command = command
            self.label = label
            self.state = state
            self.since = since
            self.until = until
        }

        enum CodingKeys: String, CodingKey {
            case tool
            case task
            case kind
            case command
            case label
            case state
            case since
            case until
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.tool = try c.decode(String.self, forKey: .tool)
            self.task = try c.decodeIfPresent(String.self, forKey: .task)
            self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
            self.label = try c.decodeIfPresent(String.self, forKey: .label)
            self.state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
            self.since = try c.decodeIfPresent(Int64.self, forKey: .since) ?? 0
            self.until = try c.decodeIfPresent(Int64.self, forKey: .until)
        }
    }
}

extension Signals {
    public struct Retry: Codable, Sendable, Hashable {
        public let message: String
        public let attempt: Int?
        public let max: Int?
        public let at: Int64

        public init(message: String = "", attempt: Int? = nil, max: Int? = nil, at: Int64 = 0) {
            self.message = message
            self.attempt = attempt
            self.max = max
            self.at = at
        }

        enum CodingKeys: String, CodingKey {
            case message
            case attempt
            case max
            case at
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            self.attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
            self.max = try c.decodeIfPresent(Int.self, forKey: .max)
            self.at = try c.decodeIfPresent(Int64.self, forKey: .at) ?? 0
        }
    }
}

public struct Signals: Codable, Sendable, Hashable {
    public let mode: String?
    public let model: String?
    public let effort: String?
    public let context: Signals.Context?
    public let todos: [Signals.Todo]?
    public let background: [Signals.Job]?
    public let retrying: Signals.Retry?

    public init(mode: String? = nil, model: String? = nil, effort: String? = nil, context: Signals.Context? = nil, todos: [Signals.Todo]? = nil, background: [Signals.Job]? = nil, retrying: Signals.Retry? = nil) {
        self.mode = mode
        self.model = model
        self.effort = effort
        self.context = context
        self.todos = todos
        self.background = background
        self.retrying = retrying
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case model
        case effort
        case context
        case todos
        case background
        case retrying
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(String.self, forKey: .effort)
        self.context = try c.decodeIfPresent(Signals.Context.self, forKey: .context)
        self.todos = try c.decodeIfPresent([Signals.Todo].self, forKey: .todos)
        self.background = try c.decodeIfPresent([Signals.Job].self, forKey: .background)
        self.retrying = try c.decodeIfPresent(Signals.Retry.self, forKey: .retrying)
    }
}

/// `items` is `[]` when the box sent `null`.
public struct TranscriptPage: Codable, Sendable, Hashable {
    public let source: String
    public let items: [TranscriptItem]
    public let next: Int?
    public let crew: [CrewMember]?
    public let truncated: Bool?
    public let last: Int64?
    public let more: Bool?
    public let reason: String?
    public let gen: String?
    public let reset: Bool?
    public let start: Int64?
    public let file: String?
    public let signals: Signals?
    public let artifacts: [ArtifactRef]?

    public init(source: String = "none", items: [TranscriptItem] = [], next: Int? = nil, crew: [CrewMember]? = nil, truncated: Bool? = nil, last: Int64? = nil, more: Bool? = nil, reason: String? = nil, gen: String? = nil, reset: Bool? = nil, start: Int64? = nil, file: String? = nil, signals: Signals? = nil, artifacts: [ArtifactRef]? = nil) {
        self.source = source
        self.items = items
        self.next = next
        self.crew = crew
        self.truncated = truncated
        self.last = last
        self.more = more
        self.reason = reason
        self.gen = gen
        self.reset = reset
        self.start = start
        self.file = file
        self.signals = signals
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case source
        case items
        case next
        case crew
        case truncated
        case last
        case more
        case reason
        case gen
        case reset
        case start
        case file
        case signals
        case artifacts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? "none"
        self.items = try c.decodeIfPresent([TranscriptItem].self, forKey: .items) ?? []
        self.next = try c.decodeIfPresent(Int.self, forKey: .next)
        self.crew = try c.decodeIfPresent([CrewMember].self, forKey: .crew)
        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
        self.last = try c.decodeIfPresent(Int64.self, forKey: .last)
        self.more = try c.decodeIfPresent(Bool.self, forKey: .more)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.gen = try c.decodeIfPresent(String.self, forKey: .gen)
        self.reset = try c.decodeIfPresent(Bool.self, forKey: .reset)
        self.start = try c.decodeIfPresent(Int64.self, forKey: .start)
        self.file = try c.decodeIfPresent(String.self, forKey: .file)
        self.signals = try c.decodeIfPresent(Signals.self, forKey: .signals)
        self.artifacts = try c.decodeIfPresent([ArtifactRef].self, forKey: .artifacts)
    }
}

extension ToolDetail {
    public struct Hunk: Codable, Sendable, Hashable {
        public let oldStart: Int
        public let oldLines: Int
        public let newStart: Int
        public let newLines: Int
        public let lines: [String]

        public init(oldStart: Int = 0, oldLines: Int = 0, newStart: Int = 0, newLines: Int = 0, lines: [String] = []) {
            self.oldStart = oldStart
            self.oldLines = oldLines
            self.newStart = newStart
            self.newLines = newLines
            self.lines = lines
        }

        enum CodingKeys: String, CodingKey {
            case oldStart
            case oldLines
            case newStart
            case newLines
            case lines
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.oldStart = try c.decodeIfPresent(Int.self, forKey: .oldStart) ?? 0
            self.oldLines = try c.decodeIfPresent(Int.self, forKey: .oldLines) ?? 0
            self.newStart = try c.decodeIfPresent(Int.self, forKey: .newStart) ?? 0
            self.newLines = try c.decodeIfPresent(Int.self, forKey: .newLines) ?? 0
            self.lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        }
    }
}

public struct ToolDetail: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let command: String?
    public let file: String?
    public let pattern: String?
    public let old: String?
    public let new: String?
    public let output: String?
    public let hunks: [ToolDetail.Hunk]?
    public let truncated: Bool?
    public let error: Bool?
    public let pending: Bool?
    public let live: Bool?

    public init(id: String, name: String = "", command: String? = nil, file: String? = nil, pattern: String? = nil, old: String? = nil, new: String? = nil, output: String? = nil, hunks: [ToolDetail.Hunk]? = nil, truncated: Bool? = nil, error: Bool? = nil, pending: Bool? = nil, live: Bool? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.file = file
        self.pattern = pattern
        self.old = old
        self.new = new
        self.output = output
        self.hunks = hunks
        self.truncated = truncated
        self.error = error
        self.pending = pending
        self.live = live
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case file
        case pattern
        case old
        case new
        case output
        case hunks
        case truncated
        case error
        case pending
        case live
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.command = try c.decodeIfPresent(String.self, forKey: .command)
        self.file = try c.decodeIfPresent(String.self, forKey: .file)
        self.pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        self.old = try c.decodeIfPresent(String.self, forKey: .old)
        self.new = try c.decodeIfPresent(String.self, forKey: .new)
        self.output = try c.decodeIfPresent(String.self, forKey: .output)
        self.hunks = try c.decodeIfPresent([ToolDetail.Hunk].self, forKey: .hunks)
        self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
        self.error = try c.decodeIfPresent(Bool.self, forKey: .error)
        self.pending = try c.decodeIfPresent(Bool.self, forKey: .pending)
        self.live = try c.decodeIfPresent(Bool.self, forKey: .live)
    }
}
