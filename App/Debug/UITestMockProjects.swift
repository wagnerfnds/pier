import Foundation
import PierKit

/// The mock box's projects coming and going (`-uiTestMock 1`): the GitHub account's repositories (`GET /v1/github/repos`),
/// clones that go through cloning and setting up in a few seconds (`POST`/`GET /v1/clones`), a project's disk use and its
/// removal (`GET …/disk`, `DELETE /v1/locations/{l}?purge=1`), and a worktree's services with a dev server on its port.
struct MockProjects {
    typealias JSON = [String: Any]

    private struct CloneJob {
        let id: String
        let repo: String
        let slug: String?
        let name: String
        let started: Date
        var space: String? = nil
        var forgotten = false
        var path: String { "\(MockProjects.base)/\(space.map { "\($0)/" } ?? "")\(name)" }
    }

    static let base = "/home/ubuntu/code"
    /// The projects folder (`PUT /v1/settings`): the mock's projects already live in it.
    private var root: String? = nil
    private var spaces: [String] = ["clientes"]
    /// Accounts added in the app (the built-in ones are always there), the defaults, the projects' choices.
    private var accounts: [JSON] = []
    private var defaults: [String: String] = [:]
    private var projectAccounts: [String: [String: String]] = [:]
    /// Accounts signed out (MockSignIns: `-uiTestSignIn 1` starts with Codex's own) and signed in from the app, by id.
    var signedOut: Set<String> = []
    var signedIn: Set<String> = []
    private var limitsEnabled = false
    private var variables: (env: [String: String], notes: [String: String]) = (["STAGING_URL": "https://staging.example.com", "SENTRY_TOKEN": "sntrys_example"], ["STAGING_URL": "the staging API"])
    private var skills: Set<String> = ["pier-box"]
    private var links: [JSON] = []
    /// The box's MCP servers (`/v1/mcp`), as pierd answers them: never a token, only `token_set`.
    private var mcp: [JSON] = [
        ["name": "crm", "transport": "http", "url": "https://mcp.example.com/mcp", "headers": ["X-Team": "app"], "token_set": true,
         "token_var": "PIER_MCP_CRM_TOKEN", "agents": ["claude", "codex"], "enabled": true],
        ["name": "docs", "transport": "http", "url": "https://docs.example.com/mcp", "token_set": false, "token_var": "PIER_MCP_DOCS_TOKEN",
         "agents": ["claude"], "enabled": false],
    ]
    /// Environments by location, and when each was applied (it reads "building" for 2 s).
    private var environments: [String: (env: JSON, at: Date)] = [:]

    private var clones: [CloneJob] = []
    private var removed: Set<String> = []
    /// Services stopped from the app, by "location/worktree/service".
    private var stopped: Set<String> = []
    /// Worktrees' preparation by "location/worktree": skipped (made with prepare: false; sandbox/subtract starts so),
    /// or prepared at a time (it reads "running" for 2 s).
    private var prepared: [String: Date?] = ["sandbox/subtract": nil]
    /// Setup agents' runs by "location/worktree": their session, and when they began (one works for `agentWork`, then
    /// records a preview with a test login). The main checkout of sandbox was prepared by one an hour ago.
    private var agentRuns: [String: (session: String, at: Date)] = ["sandbox/sandbox": ("sandbox-setup", Date().addingTimeInterval(-3600))]
    static let agentWork: TimeInterval = 4
    /// The projects whose person allowed setup agents (`PUT …/setup-agent`): sandbox, where one already ran.
    private var setupAllowed: Set<String> = ["sandbox"]
    /// Previews recorded with PUT (a run that ended records its own).
    private var previews: [String: JSON] = [:]
    /// The box's preparation rules (nil: its defaults) and whether previews get public links by themselves.
    private var prepareRules: String?
    private var autoShare = true
    static let defaultRules = """
    - Never install Docker or LXD, and never change networking or firewall rules (iptables, nftables, ufw, netplan, bridges, routes).
    - Do not stop, remove or downgrade what other projects or people on this box use: install what is missing beside it.
    - Do not print secrets you did not create (tokens, keys, other people's passwords).
    """

    private static let cloning: TimeInterval = 1.2
    private static let settingUp: TimeInterval = 2.8

    private static let account: [(slug: String, description: String, language: String, privateRepo: Bool, days: Double)] = [
        ("octocat/acme-site", "Marketing site", "TypeScript", false, 0.2),
        ("octocat/notes", "Personal notes app", "Swift", true, 1),
        ("octocat/hello-world", "My first repository on GitHub!", "JavaScript", false, 9),
        ("octocat/atlas-ios", "Atlas for iPhone", "Swift", true, 14),
        ("octocat/dotfiles", "", "Shell", false, 40),
    ]

    // MARK: locations

    /// The fixture's locations without the removed ones, with the clones that finished.
    func locations(_ fixture: String) -> Data {
        var all = ((try? JSONSerialization.jsonObject(with: Data(fixture.utf8))) as? [JSON]) ?? []
        all.removeAll { removed.contains(($0["name"] as? String) ?? "") }
        for c in clones where state(c) == "ready" && !removed.contains(c.name) {
            let path = c.path
            all.append(["name": c.name, "path": path, "repo": true, "remote": "https://github.com/\(c.slug ?? "octocat/\(c.name)").git",
                        "slug": c.slug ?? "octocat/\(c.name)", "default_branch": "main", "repo_trust": "none", "scripts": ["setup": "npm ci", "from": "box"],
                        "worktrees": [["name": c.name, "path": path, "branch": "main", "head": "0a1b2c3d4e", "main": true, "port": 41200]]])
        }
        for i in all.indices {
            let name = (all[i]["name"] as? String) ?? ""
            all[i]["prepare_with"] = prepareWith(name, all[i])
            if setupAllowed.contains(name) { all[i]["setup_agent"] = true }
            if environments[name] != nil { all[i]["isolated"] = true }
            if let a = projectAccounts[name], !a.isEmpty { all[i]["accounts"] = a }
            if let root, let path = all[i]["path"] as? String, path.hasPrefix(root + "/") {
                let parts = path.dropFirst(root.count + 1).split(separator: "/")
                if parts.count >= 2 { all[i]["space"] = String(parts[0]) }
            }
        }
        return Self.json(all)
    }

    /// Dev servers listening (`GET /v1/services`): each clone's and the sandbox's main checkout.
    func services() -> Data {
        var out: [JSON] = [["location": "sandbox", "worktree": "sandbox", "path": "/home/ubuntu/code/sandbox", "port": 41000, "process": "node .bin/vite", "main": true]]
        for c in clones where state(c) == "ready" && !removed.contains(c.name) && !stopped.contains("\(c.name)/\(c.name)/dev") {
            out.append(["location": c.name, "worktree": c.name, "path": "/home/ubuntu/code/\(c.name)", "port": 41200, "process": "node .bin/next dev", "main": true])
        }
        if stopped.contains("sandbox/sandbox/dev") { out.removeFirst() }
        return Self.json(out)
    }

    // MARK: routes

    mutating func route(_ method: BoxClient.Method, _ p: [String], _ query: [String: String], _ body: Data?, locations fixture: String) -> (Int, Data)? {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        switch (method, p.count, p[1]) {
        case (.get, 2, "settings"): return (200, settingsJSON(fixture))
        case (.put, 2, "settings"):
            if let r = req["projects_root"] as? String {
                let t = r.trimmingCharacters(in: .whitespaces)
                root = t.isEmpty ? nil : t.replacingOccurrences(of: "~", with: "/home/ubuntu")
            }
            if let r = req["prepare_rules"] as? String {
                let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                prepareRules = t.isEmpty ? nil : t
            }
            // Off: the previews' own links go (previewJSON); on: they come back.
            if let on = req["auto_share"] as? Bool { autoShare = on }
            return (200, settingsJSON(fixture))
        case (.put, 4, "locations") where p[3] == "setup-agent":
            // The person's consent to setup agents for a project, answered with the project as the list has it.
            guard let allowed = req["allowed"] as? Bool else { return (400, Self.json(["error": "say allowed: true or false", "code": "bad_request"])) }
            if allowed { setupAllowed.insert(p[2]) } else { setupAllowed.remove(p[2]) }
            let all = ((try? JSONSerialization.jsonObject(with: locations(fixture))) as? [JSON]) ?? []
            guard let loc = all.first(where: { $0["name"] as? String == p[2] }) else {
                return (404, Self.json(["error": "unknown location", "code": "not_found"]))
            }
            return (200, Self.json(loc))
        case (.get, 6, "locations") where p[3] == "worktrees" && p[5] == "preview": return (200, previewJSON(p[2], p[4]))
        case (.put, 6, "locations") where p[3] == "worktrees" && p[5] == "preview":
            var saved: JSON = [:]
            for k in ["port", "path", "url", "login", "note"] { if let v = req[k] { saved[k] = v } }
            saved["updated"] = ISO8601DateFormatter().string(from: Date())
            previews["\(p[2])/\(p[4])"] = saved
            return (200, previewJSON(p[2], p[4]))
        case (.post, 2, "spaces"):
            guard root != nil else { return (400, Self.json(["error": "set the box's projects folder before using spaces", "code": "bad_request"])) }
            let n = (req["name"] as? String) ?? ""
            guard Environments.isValidSpace(n) else { return (400, Self.json(["error": "invalid space name \"\(n)\"", "code": "bad_request"])) }
            if !spaces.contains(n) { spaces.append(n) }
            return (200, Self.json(["name": n, "path": "\(root ?? "")/\(n)", "projects": 0]))
        case (.delete, 3, "spaces"):
            let inside = clones.filter { $0.space == p[2] && state($0) == "ready" && !removed.contains($0.name) }
            if !inside.isEmpty && query["purge"] != "1" {
                return (409, Self.json(["error": "the space still holds projects: \(inside.map(\.name).joined(separator: ", ")) (remove them with it with purge=1)", "code": "space_not_empty"]))
            }
            for c in inside { removed.insert(c.name) }
            spaces.removeAll { $0 == p[2] }
            return (200, Self.json(["removed": p[2], "freed": inside.count * 182_452_224]))
        case (.get, 2, "accounts"): return (200, Self.json(accountsJSON()))
        case (.post, 2, "accounts"):
            let agent = (req["agent"] as? String) ?? "claude"
            let id = "\(agent)-\(String(UUID().uuidString.prefix(8)).lowercased())"
            accounts.append(["id": id, "agent": agent, "name": (req["name"] as? String) ?? "Conta", "dir": "/home/ubuntu/.config/pier/box/accounts/\(id)", "signed_in": false, "signed_in_known": true, "projects": [] as [Any], "limits_ready": true])
            return (200, Self.json(accounts.last!))
        case (.patch, 3, "accounts"):
            if req["default"] as? Bool == true, let a = accountsJSON().first(where: { $0["id"] as? String == p[2] }) {
                let agent = (a["agent"] as? String) ?? ""
                defaults[agent] = (a["builtin"] as? Bool) == true ? nil : p[2]
            }
            if let n = req["name"] as? String, let i = accounts.firstIndex(where: { $0["id"] as? String == p[2] }) { accounts[i]["name"] = n }
            return (200, Self.json(accountsJSON().first { $0["id"] as? String == p[2] } ?? [:]))
        case (.delete, 3, "accounts"):
            accounts.removeAll { $0["id"] as? String == p[2] }
            for (k, v) in defaults where v == p[2] { defaults[k] = nil }
            return (200, Self.json(["removed": p[2]]))
        case (.post, 3, "limits") where p[2] == "enable": limitsEnabled = true; return (200, Self.json(["enabled": ["claude"]]))
        case (.put, 4, "locations") where p[3] == "accounts":
            var cur = projectAccounts[p[2]] ?? [:]
            for (k, v) in req { cur[k] = (v as? String).flatMap { $0.isEmpty || $0 == k ? nil : $0 } }
            projectAccounts[p[2]] = cur
            return (200, Self.json(["name": p[2], "accounts": cur]))
        case (.get, 2, "env"): return (200, Self.json(["env": variables.env, "notes": variables.notes]))
        case (.put, 2, "env"):
            variables = ((req["env"] as? [String: String]) ?? [:], ((req["notes"] as? [String: String]) ?? [:]).filter { !$0.value.isEmpty })
            return (200, Self.json(["env": variables.env, "notes": variables.notes]))
        case (.get, 2, "skills"): return (200, skillsJSON())
        case (.put, 3, "skills"): skills.insert(p[2]); return (200, skillsJSON())
        case (.delete, 3, "skills"): skills.remove(p[2]); return (200, skillsJSON())
        case (.get, 2, "shares"): return (200, Self.json(links))
        case (.post, 2, "shares"):
            let name = String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
            let l: JSON = ["name": name, "url": "https://p-\(name).docktopier.com", "location": req["location"] ?? "", "worktree": req["worktree"] ?? "",
                           "port": req["port"] ?? 0, "created": ISO8601DateFormatter().string(from: Date()), "expires": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))]
            links.append(l)
            return (200, Self.json(l))
        case (.delete, 3, "shares"): links.removeAll { $0["name"] as? String == p[2] }; return (200, Self.json(["removed": p[2]]))
        case (.get, 2, "mcp"): return (200, Self.json(["servers": mcp.map { mcpView($0, status: query["status"] == "1") }]))
        case (.put, 3, "mcp"): return putMCP(p[2], req)
        case (.delete, 3, "mcp"):
            guard mcp.contains(where: { $0["name"] as? String == p[2] }) else { return (404, Self.json(["error": "no MCP server named \(p[2])", "code": "not_found"])) }
            mcp.removeAll { $0["name"] as? String == p[2] }
            return (200, Self.json(["removed": p[2]]))
        case (.get, 4, "locations") where p[3] == "base": return (200, baseJSON(p[2]))
        case (.get, 4, "locations") where p[3] == "environment": return (200, environmentJSON(p[2]))
        case (.put, 4, "locations") where p[3] == "environment":
            let empty = (req["runtime"] == nil) && ((req["containers"] as? [Any])?.isEmpty ?? true) && (req["compose"] as? Bool) != true
            environments[p[2]] = empty ? nil : (req, Date())
            return (202, environmentJSON(p[2]))
        case (.get, 3, "github") where p[2] == "repos": return (200, repos(owner: query["owner"], fixture: fixture))
        case (.get, 2, "clones"): return (200, Self.json(clones.filter { !$0.forgotten }.reversed().map(cloneJSON)))
        case (.post, 2, "clones"): return clone(body, fixture: fixture)
        case (.delete, 3, "clones"):
            guard let i = clones.firstIndex(where: { $0.id == p[2] }) else { return Self.notFound }
            clones[i].forgotten = true
            return (200, Self.json(["forgotten": p[2]]))
        case (.get, 4, "locations") where p[3] == "disk": return disk(p[2])
        case (.delete, 3, "locations") where query["purge"] == "1": return purge(p[2], force: query["force"] == "1")
        case (.get, 6, "locations") where p[3] == "worktrees" && p[5] == "services": return (200, worktreeServices(p[2], p[4]))
        case (.get, 6, "locations") where p[3] == "worktrees" && p[5] == "prepare": return (200, prepareJSON(p[2], p[4]))
        case (.post, 6, "locations") where p[3] == "worktrees" && p[5] == "prepare":
            // A setup agent's run is MockBox's (it makes the agent's session): here only the script.
            if isPreparing("\(p[2])/\(p[4])") { return (409, Self.json(["error": "this worktree is already being prepared", "code": "conflict"])) }
            agentRuns["\(p[2])/\(p[4])"] = nil
            prepared["\(p[2])/\(p[4])"] = .some(Date())
            return (202, prepareJSON(p[2], p[4]))
        case (.put, 6, "locations") where p[3] == "worktrees" && p[5] == "db":
            // The worktree's database starts over: prepared again by script, a copy of the base again.
            if isPreparing("\(p[2])/\(p[4])") { return (409, Self.json(["error": "this worktree is being prepared", "code": "conflict"])) }
            agentRuns["\(p[2])/\(p[4])"] = nil
            prepared["\(p[2])/\(p[4])"] = .some(Date())
            return (202, prepareJSON(p[2], p[4]))
        case (.post, 8, "locations") where p[3] == "worktrees" && p[5] == "services":
            let key = "\(p[2])/\(p[4])/\(p[6])"
            if p[7] == "stop" { stopped.insert(key) } else { stopped.remove(key) }
            return (200, Self.json(serviceJSON(p[2], p[4], name: p[6])))
        default: return nil
        }
    }

    private func accountsJSON() -> [JSON] {
        let iso = ISO8601DateFormatter()
        func w(_ kind: String, _ minutes: Int, _ used: Double, _ hours: Double) -> JSON {
            ["kind": kind, "minutes": minutes, "used_percent": used, "resets_at": iso.string(from: Date().addingTimeInterval(hours * 3600))]
        }
        var claude: JSON = ["id": "claude", "agent": "claude", "name": "Claude Code", "dir": "/home/ubuntu/.claude", "builtin": true, "signed_in": true, "signed_in_known": true,
                            "limits_ready": limitsEnabled]
        if limitsEnabled {
            claude["limits"] = ["windows": [w("five_hour", 300, 23.5, 3.2), w("seven_day", 10080, 81, 70)], "updated": iso.string(from: Date()), "source": "statusline"]
        }
        let codex: JSON = ["id": "codex", "agent": "codex", "name": "Codex", "dir": "/home/ubuntu/.codex", "builtin": true, "signed_in": true, "signed_in_known": true, "limits_ready": true,
                           "limits": ["windows": [w("primary", 300, 12, 1.5), w("secondary", 10080, 3, 120)], "updated": iso.string(from: Date()), "source": "session_log"]]
        var all = [claude, codex] + accounts
        for i in all.indices {
            let agent = (all[i]["agent"] as? String) ?? ""
            let id = (all[i]["id"] as? String) ?? ""
            if signedOut.contains(id) { all[i]["signed_in"] = false }
            if signedIn.contains(id) { all[i]["signed_in"] = true }
            let def = defaults[agent]
            all[i]["default"] = def == id || def == nil && (all[i]["builtin"] as? Bool) == true
            all[i]["projects"] = projectAccounts.filter { ($0.value[agent] ?? def ?? agent) == id }.map(\.key).sorted()
        }
        return all
    }

    /// A server as `GET /v1/mcp` shows it; with `status`, how each agent sees it: one with a token connects, one without is
    /// refused (like a real server that wants one), a URL with "fail" in it does not answer, Codex only knows a stdio
    /// server is configured.
    private func mcpView(_ s: JSON, status: Bool) -> JSON {
        guard status else { return s }
        var out = s
        let agents = (s["agents"] as? [String]) ?? []
        var st: [String: JSON] = [:]
        for agent in agents {
            let account = agent == "claude" ? "Claude Code" : "Codex"
            if (s["enabled"] as? Bool) != true {
                st[agent] = ["state": "disabled"]
            } else if (s["transport"] as? String) == "stdio" {
                st[agent] = ["state": agent == "claude" ? "connected" : "configured", "account": account]
            } else if ((s["url"] as? String) ?? "").contains("fail") {
                st[agent] = ["state": "failed", "issue": "ECONNREFUSED: Unable to connect. Is the computer able to access the url?", "account": account]
            } else if (s["token_set"] as? Bool) == true {
                st[agent] = ["state": "connected", "account": account]
            } else {
                st[agent] = agent == "claude"
                    ? ["state": "failed", "issue": "Dynamic Client Registration rejected (HTTP 401):", "account": account]
                    : ["state": "needs_auth", "issue": "the server asks for a token (HTTP 401)", "account": account]
            }
        }
        out["status"] = st
        return out
    }

    /// `PUT /v1/mcp/{name}` as pierd takes it: the server replaced, its token kept unless the body has one ("" removes it).
    private mutating func putMCP(_ name: String, _ req: JSON) -> (Int, Data) {
        func refuse(_ msg: String) -> (Int, Data) { (400, Self.json(["error": msg, "code": "bad_request"])) }
        guard MCPServers.isValidName(name) else { return refuse("a server's name is 1 to 40 of a-z, 0-9, - and _") }
        let transport = (req["transport"] as? String) ?? "http"
        let url = (req["url"] as? String) ?? ""
        guard transport == "stdio" || MCPServers.isValidURL(url) else { return refuse("an http server needs its URL (http:// or https://)") }
        let agents = ((req["agents"] as? [String]) ?? ["claude", "codex"]).filter { $0 == "claude" || $0 == "codex" }
        guard !agents.isEmpty else { return refuse("pick at least one agent for \(name)") }
        let old = mcp.first { $0["name"] as? String == name }
        var s: JSON = ["name": name, "transport": transport, "agents": agents, "enabled": (req["enabled"] as? Bool) ?? true]
        if transport == "http" {
            s["url"] = url
            s["token_var"] = MCPServers.tokenVariable(name)
            if let h = req["headers"] as? [String: String], !h.isEmpty { s["headers"] = h }
        } else {
            s["command"] = req["command"] ?? ""
            if let a = req["args"] as? [String], !a.isEmpty { s["args"] = a }
            if let e = req["env"] as? [String: String], !e.isEmpty { s["env"] = e }
        }
        if let t = req["token"] as? String { s["token_set"] = !t.isEmpty } else { s["token_set"] = (old?["token_set"] as? Bool) ?? false }
        if let i = mcp.firstIndex(where: { $0["name"] as? String == name }) { mcp[i] = s } else {
            mcp.append(s)
            mcp.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        }
        return (200, Self.json(s))
    }

    private func skillsJSON() -> Data {
        Self.json([["id": "pier-box", "name": "Pier box", "description": "The box's variables (what each is for), the worktree's ports and its project's environment.", "installed": skills.contains("pier-box"),
                    "paths": skills.contains("pier-box") ? ["/home/ubuntu/.claude/skills/pier-box/SKILL.md", "/home/ubuntu/.agents/skills/pier-box/SKILL.md"] : []],
                   ["id": "pier-preview", "name": "Pier preview", "description": "Run the worktree's dev server on its own port so the person sees it in the Pier app.", "installed": skills.contains("pier-preview"),
                    "paths": [] as [String]]])
    }

    private func settingsJSON(_ fixture: String) -> Data {
        var out: JSON = ["home": "/home/ubuntu", "docker": ["available": true, "version": "27.3.1"],
                         "prepare_rules": prepareRules ?? Self.defaultRules, "prepare_rules_default": prepareRules == nil, "auto_share": autoShare]
        if let root {
            out["projects_root"] = root
            out["spaces"] = spaces.map { s in
                ["name": s, "path": "\(root)/\(s)", "projects": clones.filter { $0.space == s && state($0) == "ready" && !removed.contains($0.name) }.count] as JSON
            }
        } else { out["spaces"] = [] as [Any] }
        return Self.json(out)
    }

    private func environmentJSON(_ location: String) -> Data {
        let saved = environments[location]
        let env = saved?.env ?? [:]
        let building = saved.map { Date().timeIntervalSince($0.at) < 2 } ?? false
        var containers: [JSON] = []
        var vars: [String] = []
        for (i, c) in ((env["containers"] as? [JSON]) ?? []).enumerated() {
            let name = (c["name"] as? String) ?? "db"
            containers.append(["name": name, "image": c["image"] ?? "", "host_port": 41300 + i * 10, "state": building ? "stopped" : "running", "unit": "ctr-\(location)-\(name)"])
            vars += ["PIER_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))_PORT"]
            if ((c["image"] as? String) ?? "").hasPrefix("mysql") || ((c["image"] as? String) ?? "").hasPrefix("postgres") { vars += ["DATABASE_URL", "DB_HOST", "DB_PORT"] }
        }
        var status: JSON = ["state": saved == nil ? "none" : building ? "building" : "ready", "containers": containers]
        if let rt = env["runtime"] as? JSON {
            vars.append("PIER_ENV_BIN")
            if !building, let preset = rt["preset"] as? String {
                status["image"] = preset.hasPrefix("php") ? "pier-env-\(location):latest" : preset
                status["commands"] = Environments.parsePreset(preset)?.language.commands ?? []
            }
        }
        status["variables"] = Array(Set(vars)).sorted()
        return Self.json(["environment": env, "status": status, "project": ["dockerfile": location == "sandbox", "compose": location == "acme-site"],
                          "docker": ["available": true, "version": "27.3.1"]])
    }

    private func repos(owner: String?, fixture: String) -> Data {
        let have = Dictionary(((try? JSONDecoder.pier.decode([Location].self, from: locations(fixture))) ?? []).compactMap { l in l.slug.map { ($0.lowercased(), l.name) } },
                              uniquingKeysWith: { a, _ in a })
        let org = owner == "octo-org"
        let list: [JSON] = (org ? [("octo-org/platform", "Shared platform services", "Go", true, 3.0)] : Self.account).map { r in
            var j: JSON = ["slug": r.slug, "name": String(r.slug.split(separator: "/")[1]), "url": "https://github.com/\(r.slug)",
                           "private": r.privateRepo, "language": r.language,
                           "updated_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-r.days * 86400))]
            if !r.description.isEmpty { j["description"] = r.description }
            if let l = have[r.slug.lowercased()] { j["location"] = l }
            return j
        }
        return Self.json(["login": "octocat", "owner": owner ?? "octocat", "owners": ["octocat", "octo-org"], "repos": list])
    }

    private mutating func clone(_ body: Data?, fixture: String) -> (Int, Data) {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let repo = ((req["repo"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard Projects.isRepoLink(repo) else {
            return (400, Self.json(["error": "\"\(repo)\" is not a repository link: use owner/repo or its https or ssh URL", "code": "bad_request"]))
        }
        var name = (req["name"] as? String) ?? ""
        let slug = PRCommands.slug(fromRemote: repo.contains("://") || repo.contains("@") ? repo : "github.com/\(repo)")
        if name.isEmpty { name = String((slug ?? repo).split(separator: "/").last ?? "project").replacingOccurrences(of: ".git", with: "") }
        let existing = ((try? JSONDecoder.pier.decode([Location].self, from: locations(fixture))) ?? [])
        if let l = existing.first(where: { $0.slug?.lowercased() == slug?.lowercased() && slug != nil }) {
            return (409, Self.json(["error": "\(repo) is already on this box as \(l.name)", "code": "bad_request"]))
        }
        var job = CloneJob(id: String(UUID().uuidString.prefix(12)).lowercased(), repo: repo, slug: slug, name: name, started: Date())
        if let s = req["space"] as? String, !s.isEmpty, root != nil {
            job.space = s
            if !spaces.contains(s) { spaces.append(s) }
        }
        removed.remove(name)
        clones.append(job)
        return (202, Self.json(cloneJSON(job)))
    }

    private func state(_ c: CloneJob) -> String {
        let t = Date().timeIntervalSince(c.started)
        if c.repo.contains("broken") { return t < Self.cloning ? "cloning" : "failed" }
        return t < Self.cloning ? "cloning" : t < Self.settingUp ? "setting_up" : "ready"
    }

    private func cloneJSON(_ c: CloneJob) -> JSON {
        let st = state(c)
        var j: JSON = ["id": c.id, "repo": c.repo, "location": c.name, "path": c.path, "state": st,
                       "started": ISO8601DateFormatter().string(from: c.started)]
        if let s = c.slug { j["slug"] = s }
        if st == "ready" { j["setup"] = "detected"; j["services"] = ["dev"] }
        if st == "failed" { j["error"] = "clone failed: fatal: repository '\(c.repo)' not found" }
        return j
    }

    private func disk(_ location: String) -> (Int, Data) {
        guard !removed.contains(location) else { return Self.notFound }
        let unsaved = location == "sandbox"
        var j: JSON = ["bytes": unsaved ? 734_003_200 : 182_452_224, "paths": ["/home/ubuntu/code/\(location)"], "uncommitted": [], "unpushed": [],
                       "stashes": 0, "sessions": 0, "removable": true, "remote": "https://github.com/octocat/\(location).git"]
        if unsaved {
            j["uncommitted"] = [["worktree": "sandbox", "files": 3]]
            j["unpushed"] = [["branch": "feat/subtract", "commits": 2]]
        }
        return (200, Self.json(j))
    }

    private mutating func purge(_ location: String, force: Bool) -> (Int, Data) {
        guard !removed.contains(location) else { return Self.notFound }
        if location == "sandbox" && !force {
            return (409, Self.json(["error": "the project has work that is not on any remote: sandbox has 3 uncommitted files; feat/subtract has 2 commits no remote has (remove with force=1 to lose them)",
                                    "code": "unsaved_work"]))
        }
        removed.insert(location)
        return (200, Self.json(["removed": location, "freed": location == "sandbox" ? 734_003_200 : 182_452_224]))
    }

    /// A task or worktree made with prepare: false.
    mutating func noteUnprepared(location: String, worktree: String) { prepared["\(location)/\(worktree)"] = .some(nil) }

    private func prepareState(_ key: String) -> (state: String, at: Date?) {
        guard let entry = prepared[key] else { return ("ready", Date().addingTimeInterval(-3600)) }
        guard let at = entry else { return ("skipped", Date().addingTimeInterval(-600)) }
        return (Date().timeIntervalSince(at) < 2 ? "running" : "ready", at)
    }

    /// The project's base: sandbox has the team's (its .env and auth.json, vendor and node_modules carried, the team's
    /// recipe); every other project has none yet.
    func baseJSON(_ location: String) -> Data {
        guard location == "sandbox" else {
            return Self.json(["key": "local-\(location)-1a2b3c", "files": [] as [Any], "carry": [] as [Any], "warnings": [] as [Any]])
        }
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        return Self.json([
            "key": "octocat__sandbox",
            "files": [
                ["path": ".env", "kind": "env", "size": 2310, "sha": "279c46ad", "keys": ["APP_KEY", "DB_HOST", "DB_PASSWORD", "MAIL_MAILER"], "from": "team", "added": at],
                ["path": "auth.json", "kind": "file", "size": 120, "sha": "9f2b11c0", "from": "box", "added": at],
            ] as [Any],
            "carry": [
                ["path": "node_modules", "from": "worktreeinclude", "in_main": true],
                ["path": "vendor", "from": "team", "in_main": true],
            ] as [Any],
            "team": ["dir": "/srv/pier/team/projects/octocat__sandbox", "published": at],
            "recipe": ["setup": "composer install && npm install --prefer-offline && php artisan migrate --force", "services": ["dev"], "from": "team"],
            "copy": "reflink",
            "db": [
                "engine": "mysql", "redis": true, "instances": 2,
                "server": ["program": "/usr/sbin/mysqld", "version": "8.0.46", "apparmor": "ok"],
                "snapshot": ["id": "20261020-100000", "created": at, "version": "8.0.46", "databases": ["shop", "shop_test"],
                             "bytes": 48_318_382_080, "sanitized": true, "layer": "team"],
            ] as JSON,
            "warnings": [] as [Any],
        ])
    }

    /// How sandbox's base went into a worktree it prepared.
    private static var sandboxBaseReport: JSON { [
        "files": [["path": ".env", "action": "written"], ["path": "auth.json", "action": "written"]] as [Any],
        "carried": [["path": "node_modules", "action": "carried", "ms": 1830], ["path": "vendor", "action": "carried", "ms": 412]] as [Any],
    ] }

    func prepareJSON(_ location: String, _ worktree: String) -> Data {
        let key = "\(location)/\(worktree)"
        var out: JSON = ["setup": "npm ci && cp ../.env.local .env", "services": ["dev"], "prepare_with": prepareWith(location, nil)]
        // The base's files go in as a worktree is made; its folders only once it is prepared.
        if location == "sandbox" {
            var report = Self.sandboxBaseReport
            if hasServers(key) {
                let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
                report["servers"] = [["engine": "mysql", "port": 41009, "action": "copied", "snapshot": "20261020-100000", "snapshot_created": at,
                                      "layer": "team", "ms": 1240], ["engine": "redis", "port": 41008, "action": "created", "ms": 80]] as [Any]
            } else {
                report["carried"] = nil
            }
            out["base"] = report
        }
        if let run = agentRuns[key] {
            // A setup agent: at work for a few seconds, then done.
            let working = Date().timeIntervalSince(run.at) < Self.agentWork
            out["state"] = working ? "running" : "ready"
            out["since"] = ISO8601DateFormatter().string(from: working ? run.at : run.at.addingTimeInterval(Self.agentWork))
            out["kind"] = "agent"
            out["session"] = run.session
            return Self.json(out)
        }
        let (state, at) = prepareState(key)
        out["state"] = state
        if state == "running" { out["step"] = "setup" }
        if state != "skipped" { out["kind"] = "script" }
        if let at { out["since"] = ISO8601DateFormatter().string(from: at) }
        return Self.json(out)
    }

    /// How a new worktree of a project is prepared by default: by its script where it has one (sandbox reads as having
    /// one, and the clones do), by a setup agent where the person allowed them, by its script elsewhere.
    private func prepareWith(_ location: String, _ loc: JSON?) -> String {
        if location == "sandbox" || clones.contains(where: { $0.name == location }) { return "script" }
        if let setup = (loc?["scripts"] as? JSON)?["setup"] as? String, !setup.isEmpty { return "script" }
        return setupAllowed.contains(location) ? "agent" : "script"
    }

    private func isPreparing(_ key: String) -> Bool {
        if let run = agentRuns[key], Date().timeIntervalSince(run.at) < Self.agentWork { return true }
        return prepareState(key).state == "running"
    }

    /// Starts a setup agent's run when the request asks for one (or leaves it to a project whose default is one):
    /// the session it works in, or nil when it is the script's to run. Busy: one already runs.
    enum AgentRun { case started(String), busy }
    mutating func beginAgentRun(location: String, worktree: String, main: Bool, body: Data?) -> AgentRun? {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let way = (req["prepare_with"] as? String) ?? prepareWith(location, nil)
        guard way == "agent" else { return nil }
        let key = "\(location)/\(worktree)"
        if isPreparing(key) { return .busy }
        // Every other run gets the other name, as on pierd.
        let base = main ? "\(location)-setup" : "\(location)-\(worktree)-setup"
        let session = agentRuns[key]?.session == base ? base + "-2" : base
        agentRuns[key] = (session, Date())
        previews[key] = nil
        return .started(session)
    }

    /// A worktree's preview: what was recorded, or what a setup agent's run left, with its public link while the box
    /// makes them.
    private func previewJSON(_ location: String, _ worktree: String) -> Data {
        let key = "\(location)/\(worktree)"
        var p = previews[key] ?? [:]
        if p.isEmpty, let run = agentRuns[key], Date().timeIntervalSince(run.at) >= Self.agentWork {
            let port = location == "sandbox" && worktree == "sandbox" ? 41000 : worktreePort(location, worktree)
            p = ["port": port, "path": "/login", "login": ["user": "demo@example.com", "password": "demo-pass-123", "note": "made by the seeder"],
                 "note": "Vite build served by php artisan serve; MySQL database \(location)_\(worktree)",
                 "updated": ISO8601DateFormatter().string(from: run.at.addingTimeInterval(Self.agentWork))]
        }
        if autoShare, let port = p["port"] as? Int, port > 0 {
            let name = "abcd2345" + String(key.unicodeScalars.map { String($0.value % 36, radix: 36) }.joined().prefix(16))
            // A day at a time, renewed in its last twelve hours.
            p["share"] = ["name": name, "url": "https://p-\(name).docktopier.com", "auto": true,
                          "expires": ISO8601DateFormatter().string(from: Date().addingTimeInterval(20 * 3600))]
        }
        return Self.json(p)
    }

    private func worktreePort(_ location: String, _ worktree: String) -> Int {
        let all = ((try? JSONSerialization.jsonObject(with: Data(MockFixtures.locations.utf8))) as? [JSON]) ?? []
        let wts = (all.first { $0["name"] as? String == location }?["worktrees"] as? [JSON]) ?? []
        return (wts.first { $0["name"] as? String == worktree }?["port"] as? Int) ?? 41000
    }

    private func worktreeServices(_ location: String, _ worktree: String) -> Data {
        var all = [serviceJSON(location, worktree, name: "dev"), serviceJSON(location, worktree, name: "worker")]
        // sandbox's prepared worktrees have their own database and Redis (the base's).
        if location == "sandbox", hasServers("\(location)/\(worktree)") {
            all.append(["name": "db", "run": "MySQL 8.0.46 · 20261020-100000", "state": "running", "unit": "db-sandbox-\(worktree)-a1b2c3",
                        "port": 41009, "kind": "mysql"])
            all.append(["name": "redis", "run": "Redis", "state": "running", "unit": "redis-sandbox-\(worktree)-d4e5f6", "port": 41008, "kind": "redis"])
        }
        return Self.json(all)
    }

    /// A worktree prepared since the base had a database (not one made with only its code).
    private func hasServers(_ key: String) -> Bool {
        if case .some(nil) = prepared[key] { return false }
        return true
    }

    private func serviceJSON(_ location: String, _ worktree: String, name: String) -> JSON {
        let running = name == "dev" && !stopped.contains("\(location)/\(worktree)/\(name)")
        return ["name": name, "run": name == "dev" ? "HOST=0.0.0.0 npm run dev" : "npm run worker", "autostart": name == "dev",
                "state": running ? "running" : "stopped", "unit": "svc-\(location)-\(worktree)-\(name)", "port": 41000]
    }

    private static var notFound: (Int, Data) { (404, json(["error": "not found", "code": "not_found"])) }
    private static func json(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data("{}".utf8) }
}
