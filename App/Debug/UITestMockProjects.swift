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
    private var limitsEnabled = false
    private var variables: (env: [String: String], notes: [String: String]) = (["STAGING_URL": "https://staging.example.com", "SENTRY_TOKEN": "sntrys_example"], ["STAGING_URL": "the staging API"])
    private var skills: Set<String> = ["pier-box"]
    private var links: [JSON] = []
    /// Environments by location, and when each was applied (it reads "building" for 2 s).
    private var environments: [String: (env: JSON, at: Date)] = [:]

    private var clones: [CloneJob] = []
    private var removed: Set<String> = []
    /// Services stopped from the app, by "location/worktree/service".
    private var stopped: Set<String> = []
    /// Worktrees' preparation by "location/worktree": skipped (made with prepare: false; sandbox/subtract starts so),
    /// or prepared at a time (it reads "running" for 2 s).
    private var prepared: [String: Date?] = ["sandbox/subtract": nil]

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
            let r = ((req["projects_root"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            root = r.isEmpty ? nil : r.replacingOccurrences(of: "~", with: "/home/ubuntu")
            return (200, settingsJSON(fixture))
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
            accounts.append(["id": id, "agent": agent, "name": (req["name"] as? String) ?? "Conta", "dir": "/home/ubuntu/.pier/box/accounts/\(id)", "signed_in": false, "signed_in_known": true, "projects": [] as [Any], "limits_ready": true])
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
            if prepareState("\(p[2])/\(p[4])").state == "running" { return (409, Self.json(["error": "this worktree is already being prepared", "code": "conflict"])) }
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
            let def = defaults[agent]
            all[i]["default"] = def == id || def == nil && (all[i]["builtin"] as? Bool) == true
            all[i]["projects"] = projectAccounts.filter { ($0.value[agent] ?? def ?? agent) == id }.map(\.key).sorted()
        }
        return all
    }

    private func skillsJSON() -> Data {
        Self.json([["id": "pier-box", "name": "Pier box", "description": "The box's variables (what each is for), the worktree's ports and its project's environment.", "installed": skills.contains("pier-box"),
                    "paths": skills.contains("pier-box") ? ["/home/ubuntu/.claude/skills/pier-box/SKILL.md", "/home/ubuntu/.agents/skills/pier-box/SKILL.md"] : []],
                   ["id": "pier-preview", "name": "Pier preview", "description": "Run the worktree's dev server on its own port so the person sees it in the Pier app.", "installed": skills.contains("pier-preview"),
                    "paths": [] as [String]]])
    }

    private func settingsJSON(_ fixture: String) -> Data {
        var out: JSON = ["home": "/home/ubuntu", "docker": ["available": true, "version": "27.3.1"]]
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

    private func prepareJSON(_ location: String, _ worktree: String) -> Data {
        let (state, at) = prepareState("\(location)/\(worktree)")
        var out: JSON = ["state": state, "setup": "npm ci && cp ../.env.local .env", "services": ["dev"]]
        if let at { out["since"] = ISO8601DateFormatter().string(from: at) }
        return Self.json(out)
    }

    private func worktreeServices(_ location: String, _ worktree: String) -> Data {
        Self.json([serviceJSON(location, worktree, name: "dev"), serviceJSON(location, worktree, name: "worker")])
    }

    private func serviceJSON(_ location: String, _ worktree: String, name: String) -> JSON {
        let running = name == "dev" && !stopped.contains("\(location)/\(worktree)/\(name)")
        return ["name": name, "run": name == "dev" ? "HOST=0.0.0.0 npm run dev" : "npm run worker", "autostart": name == "dev",
                "state": running ? "running" : "stopped", "unit": "svc-\(location)-\(worktree)-\(name)", "port": 41000]
    }

    private static var notFound: (Int, Data) { (404, json(["error": "not found", "code": "not_found"])) }
    private static func json(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data("{}".utf8) }
}
