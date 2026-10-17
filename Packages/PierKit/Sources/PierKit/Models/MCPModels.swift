// Codable models of the box's MCP servers (docs/API.md §2.13). Checked against Server/pierd/internal/box/mcp.go.
import Foundation

/// `GET /v1/mcp`: the box's MCP servers.
public struct MCPServerList: Codable, Sendable, Hashable {
    public let servers: [MCPServer]
    public init(servers: [MCPServer] = []) { self.servers = servers }
    enum CodingKeys: String, CodingKey { case servers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([MCPServer].self, forKey: .servers) ?? []
    }
}

/// An MCP server pierd writes into every Claude Code and Codex account of the box, through the agents' own CLIs. The
/// token never comes back: `tokenSet` says whether the box has one.
public struct MCPServer: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    /// "http" (a URL the agents connect to) or "stdio" (a command they start).
    public let transport: String
    public let url: String?
    public let command: String?
    public let args: [String]
    /// Extra headers, sent by Claude Code only (Codex's CLI takes none). The token is never one of them.
    public let headers: [String: String]
    public let tokenSet: Bool
    /// The variable Codex reads the token from (`PIER_MCP_<NAME>_TOKEN`), which every session pierd starts gets.
    public let tokenVar: String?
    public let env: [String: String]
    /// "claude", "codex".
    public let agents: [String]
    public let enabled: Bool
    /// What the box's last sync could not do (an account with a server of the same name that pierd did not add, say).
    public let problems: [String]
    /// How each agent's default account sees it, by agent; only when asked for (`mcpServers(status: true)`).
    public let status: [String: MCPAgentStatus]
    public var id: String { name }

    public init(name: String, transport: String = "http", url: String? = nil, command: String? = nil, args: [String] = [],
                headers: [String: String] = [:], tokenSet: Bool = false, tokenVar: String? = nil, env: [String: String] = [:],
                agents: [String] = ["claude", "codex"], enabled: Bool = true, problems: [String] = [], status: [String: MCPAgentStatus] = [:]) {
        self.name = name; self.transport = transport; self.url = url; self.command = command; self.args = args; self.headers = headers
        self.tokenSet = tokenSet; self.tokenVar = tokenVar; self.env = env; self.agents = agents; self.enabled = enabled
        self.problems = problems; self.status = status
    }
    enum CodingKeys: String, CodingKey {
        case name, transport, url, command, args, headers, env, agents, enabled, problems, status
        case tokenSet = "token_set", tokenVar = "token_var"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? "http"
        url = try c.decodeIfPresent(String.self, forKey: .url)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        tokenSet = try c.decodeIfPresent(Bool.self, forKey: .tokenSet) ?? false
        tokenVar = try c.decodeIfPresent(String.self, forKey: .tokenVar)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        problems = try c.decodeIfPresent([String].self, forKey: .problems) ?? []
        status = try c.decodeIfPresent([String: MCPAgentStatus].self, forKey: .status) ?? [:]
    }
}

/// How one agent's default account sees a server. `state`: connected, failed, needs_auth, configured (Codex with a
/// stdio server: its list cannot tell more), disabled, missing, taken (a server of that name the person added by hand),
/// unavailable (the agent's CLI is not on the box), pending, unknown. `issue` is the agent's (or pierd's) own words.
public struct MCPAgentStatus: Codable, Sendable, Hashable {
    public let state: String
    public let issue: String?
    /// The account that was asked ("Claude Code", "Codex", or an added account's name with its agent).
    public let account: String?
    public init(state: String, issue: String? = nil, account: String? = nil) { self.state = state; self.issue = issue; self.account = account }
    enum CodingKeys: String, CodingKey { case state, issue, account }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}

/// `PUT /v1/mcp/{name}`: a server as the app saves it, replacing the box's. `token` nil keeps the box's token, "" removes
/// it.
public struct MCPServerUpdate: Encodable, Sendable, Hashable {
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]?
    public var headers: [String: String]?
    public var token: String?
    public var env: [String: String]?
    public var agents: [String]
    public var enabled: Bool

    public init(transport: String = "http", url: String? = nil, command: String? = nil, args: [String]? = nil, headers: [String: String]? = nil,
                token: String? = nil, env: [String: String]? = nil, agents: [String] = ["claude", "codex"], enabled: Bool = true) {
        self.transport = transport; self.url = url; self.command = command; self.args = args; self.headers = headers
        self.token = token; self.env = env; self.agents = agents; self.enabled = enabled
    }

    /// The server as the box has it, to save again with a change; its token stays the box's.
    public init(_ s: MCPServer) {
        self.init(transport: s.transport, url: s.url, command: s.command, args: s.args.isEmpty ? nil : s.args,
                  headers: s.headers.isEmpty ? nil : s.headers, env: s.env.isEmpty ? nil : s.env, agents: s.agents, enabled: s.enabled)
    }
}
