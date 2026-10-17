// Codable models of the tools the box can install and of its sign-ins (docs/API.md §2.10.1, §2.13). Checked against
// Server/pierd/internal/box/toolsapi.go and logins.go.
import Foundation

/// `GET /v1/tools`: a command-line tool pierd installs (Claude Code, Codex, the GitHub CLI) and whether the box has it.
public struct BoxTool: Codable, Sendable, Hashable, Identifiable {
    /// `claude`, `codex` or `gh`.
    public let id: String
    public let name: String
    public let command: String
    public let installed: Bool
    public let path: String?
    public let version: String?
    /// An install runs now (`POST /v1/tools/install`); `error` is why the last one failed, until the tool is there.
    public let installing: Bool
    public let error: String?
    public let log: String?

    public init(id: String, name: String = "", command: String = "", installed: Bool = false, path: String? = nil, version: String? = nil,
                installing: Bool = false, error: String? = nil, log: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.installed = installed; self.path = path
        self.version = version; self.installing = installing; self.error = error; self.log = log
    }
    enum CodingKeys: String, CodingKey { case id, name, command, installed, path, version, installing, error, log }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? id
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        installing = try c.decodeIfPresent(Bool.self, forKey: .installing) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        log = try c.decodeIfPresent(String.self, forKey: .log)
    }
}

/// `POST /v1/logins`, `GET /v1/logins/{id}`: a sign-in to Claude Code, Codex or GitHub that the box runs for the app,
/// reading the link and the one-time code off the CLI's own screen.
public struct Login: Codable, Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// The CLI is starting; nothing to show yet.
        case starting
        /// The link (and, for a device sign-in, its code) is ready: the person opens it.
        case openLink
        /// Claude Code waits for the code its page shows, pasted back (`POST …/code`).
        case enterCode
        /// The code went in; the CLI finishes.
        case waiting
        case done
        case failed
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "starting": self = .starting
            case "open_link": self = .openLink
            case "enter_code": self = .enterCode
            case "waiting": self = .waiting
            case "done": self = .done
            case "failed": self = .failed
            default: self = .unknown(raw)
            }
        }

        public var raw: String {
            switch self {
            case .starting: "starting"
            case .openLink: "open_link"
            case .enterCode: "enter_code"
            case .waiting: "waiting"
            case .done: "done"
            case .failed: "failed"
            case .unknown(let s): s
            }
        }

        /// Done or failed: the box follows it no more.
        public var isFinal: Bool { self == .done || self == .failed }
    }

    public let id: String
    /// `claude`, `codex` or `gh`.
    public let tool: String
    /// The account it signs in (claude and codex): an id of `GET /v1/accounts`.
    public let account: String?
    public let state: State
    public let url: URL?
    /// The one-time code a device sign-in (Codex, GitHub) asks for on its page.
    public let userCode: String?
    /// The page shows a code to bring back to the box (Claude Code).
    public let needsCode: Bool
    /// The tmux session it runs in: "Abrir no terminal".
    public let session: String
    public let error: String?
    public let started: Date?
    public let finished: Date?

    public init(id: String, tool: String, account: String? = nil, state: State = .starting, url: URL? = nil, userCode: String? = nil,
                needsCode: Bool = false, session: String = "", error: String? = nil, started: Date? = nil, finished: Date? = nil) {
        self.id = id; self.tool = tool; self.account = account; self.state = state; self.url = url; self.userCode = userCode
        self.needsCode = needsCode; self.session = session; self.error = error; self.started = started; self.finished = finished
    }

    enum CodingKeys: String, CodingKey {
        case id, tool, account, state, url, session, error, started, finished
        case userCode = "user_code", needsCode = "needs_code"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account)
        state = State(raw: try c.decodeIfPresent(String.self, forKey: .state) ?? "starting")
        url = (try c.decodeIfPresent(String.self, forKey: .url)).flatMap { URL(string: $0) }
        userCode = try c.decodeIfPresent(String.self, forKey: .userCode)
        needsCode = try c.decodeIfPresent(Bool.self, forKey: .needsCode) ?? false
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error)
        started = try? c.decodeIfPresent(Date.self, forKey: .started)
        finished = try? c.decodeIfPresent(Date.self, forKey: .finished)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tool, forKey: .tool)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(state.raw, forKey: .state)
        try c.encodeIfPresent(url?.absoluteString, forKey: .url)
        try c.encodeIfPresent(userCode, forKey: .userCode)
        try c.encode(needsCode, forKey: .needsCode)
        try c.encode(session, forKey: .session)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(started, forKey: .started)
        try c.encodeIfPresent(finished, forKey: .finished)
    }
}
