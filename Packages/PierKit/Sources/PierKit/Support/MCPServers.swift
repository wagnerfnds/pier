import Foundation

/// The rules behind the MCP servers screen (docs/API.md §2.13): what pierd takes, and what a row says about a server.
public enum MCPServers {
    /// A name pierd takes: 1 to 40 of a-z, 0-9, - and _. It names the server in each agent's configuration and in its
    /// tools (`mcp__<name>__…`).
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
    }

    /// A name for a server from its URL, for the person to keep or change: the host's most telling label
    /// ("https://mcp.acme.com/mcp" → "acme"); "" when the host says nothing (an address).
    public static func suggestedName(for url: String) -> String {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(), !host.isEmpty else { return "" }
        var labels = host.split(separator: ".").map(String.init)
        if labels.allSatisfy({ Int($0) != nil }) || host.contains(":") { return "" }
        if labels.count > 1 { labels.removeLast() }
        let generic: Set<String> = ["mcp", "api", "www", "app", "apps", "server", "servers", "gateway", "co", "com", "net", "org"]
        let pick = labels.first { !generic.contains($0) } ?? labels.first ?? ""
        let cleaned = String(pick.map { c in c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") ? c : "-" }.prefix(40))
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A URL pierd takes for an http server: http or https, with a host.
    public static func isValidURL(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { return false }
        return s.count <= 2048
    }

    /// A header pierd sends as written: a valid name that is not Authorization (that is the token, sent as a bearer),
    /// and a value on one line.
    public static func isValidHeader(name: String, value: String) -> Bool {
        guard name.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}$"#, options: .regularExpression) != nil,
              name.lowercased() != "authorization" else { return false }
        return !value.contains(where: { $0 == "\n" || $0 == "\r" }) && value.utf8.count <= 8192
    }

    /// A token pierd takes: one line without spaces.
    public static func isValidToken(_ token: String) -> Bool {
        !token.contains(where: \.isWhitespace) && token.utf8.count <= 8192
    }

    /// The variable Codex reads a server's token from (pierd gives it to every session it starts).
    public static func tokenVariable(_ name: String) -> String {
        "PIER_MCP_" + name.uppercased().replacingOccurrences(of: "-", with: "_") + "_TOKEN"
    }

    /// One agent's state, from what the box answered.
    public enum AgentKind: Sendable, Equatable {
        case connected
        /// Written into the agent's configuration; the agent cannot tell more (Codex with a stdio server).
        case configured
        case failed
        case off
        /// Not in the account's configuration (the box could not write it there yet).
        case missing
        /// The account has a server of that name the person added by hand; pierd leaves it alone.
        case taken
        /// The agent's CLI is not on the box.
        case unavailable
        case unknown
    }

    public static func kind(_ s: MCPAgentStatus) -> AgentKind {
        switch s.state {
        case "connected": .connected
        case "configured": .configured
        case "failed", "needs_auth": .failed
        case "disabled": .off
        case "missing": .missing
        case "taken": .taken
        case "unavailable": .unavailable
        default: .unknown
        }
    }

    /// What a row says about a server.
    public enum Health: Sendable, Equatable {
        case off
        /// Nothing known yet (no status asked for, or an agent's list did not answer).
        case unknown
        case connected
        case configured
        /// The first agent it fails for (nil: a problem of the box's last sync) and why.
        case failing(agent: String?, issue: String?)
    }

    /// A server's health over its agents: failing wins, then not known, then configured, then connected. An agent whose
    /// CLI the box lacks says nothing about the server.
    public static func health(_ s: MCPServer) -> Health {
        guard s.enabled else { return .off }
        guard !s.status.isEmpty else {
            if let p = s.problems.first { return .failing(agent: nil, issue: p) }
            return .unknown
        }
        var unknown = false, configured = false, connected = false
        for agent in s.agents {
            guard let st = s.status[agent] else { continue }
            switch kind(st) {
            case .failed, .missing, .taken: return .failing(agent: agent, issue: st.issue)
            case .unknown: unknown = true
            case .configured: configured = true
            case .connected: connected = true
            case .off, .unavailable: break
            }
        }
        if unknown { return .unknown }
        if configured { return .configured }
        return connected ? .connected : .unknown
    }
}
