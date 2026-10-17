import Foundation
import PierKit

/// The mock box's tools and sign-ins (`-uiTestMock 1`, and the demo): Claude Code, Codex and the GitHub CLI installed and
/// signed in (`-uiTestSignIn 1`: the GitHub CLI missing and Codex signed out, for the onboarding's "Contas" step and the
/// Inbox's Instalar / Entrar), installs that take 3 s (`POST /v1/tools/install`), and sign-ins like pierd's (`/v1/logins`):
/// a device sign-in (Codex, GitHub) shows its link and code, then the "person" enters it on the page a few seconds later
/// (open_link, waiting, done); Claude Code shows its link and waits for the code pasted back, then finishes.
struct MockSignIns {
    typealias JSON = [String: Any]

    private struct Run {
        let id: String
        let tool: String
        let account: String?
        let started: Date
        var codeAt: Date?
        var canceled = false
        var settled = false
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "uiTestSignIn") }

    private static let installTime: TimeInterval = 3
    private static let openAfter: TimeInterval = 1
    /// A device sign-in: when the person has typed the code on the page (waiting), and when it is done.
    private static let enteredAfter: TimeInterval = 4
    private static let doneAfter: TimeInterval = 6
    /// Claude Code: how long it takes after the code went in.
    private static let confirmAfter: TimeInterval = 1.5

    private var missing: Set<String> = MockSignIns.enabled ? ["gh"] : []
    private var installing: [String: Date] = [:]
    /// What is signed out: an agent's account by id ("codex"), GitHub as "gh"; and the accounts a sign-in here finished
    /// for (an added one starts signed out).
    private(set) var signedOut: Set<String> = MockSignIns.enabled ? ["codex", "gh"] : []
    private(set) var signedIn: Set<String> = []
    private var runs: [Run] = []

    func installed(_ tool: String) -> Bool { !missing.contains(tool) }

    /// Installs and sign-ins that ended by now take effect.
    private mutating func settle(_ now: Date) {
        for (tool, at) in installing where now.timeIntervalSince(at) >= Self.installTime {
            installing[tool] = nil
            missing.remove(tool)
        }
        for i in runs.indices where !runs[i].settled && state(runs[i], now) == "done" {
            runs[i].settled = true
            let who = runs[i].tool == "gh" ? "gh" : runs[i].account ?? runs[i].tool
            signedOut.remove(who)
            signedIn.insert(who)
        }
    }

    private func state(_ r: Run, _ now: Date) -> String {
        if r.canceled { return "failed" }
        let t = now.timeIntervalSince(r.started)
        if r.tool == "claude" {
            if let c = r.codeAt { return now.timeIntervalSince(c) >= Self.confirmAfter ? "done" : "waiting" }
            return t >= Self.openAfter ? "enter_code" : "starting"
        }
        if t >= Self.openAfter + Self.doneAfter { return "done" }
        if t >= Self.openAfter + Self.enteredAfter { return "waiting" }
        return t >= Self.openAfter ? "open_link" : "starting"
    }

    private func json(_ r: Run, _ now: Date) -> JSON {
        let st = state(r, now)
        var out: JSON = ["id": r.id, "tool": r.tool, "state": st, "needs_code": r.tool == "claude", "session": "login-\(r.account ?? r.tool)",
                         "started": ISO8601DateFormatter().string(from: r.started)]
        if let a = r.account { out["account"] = a }
        if st != "starting" {
            switch r.tool {
            case "claude": out["url"] = "https://claude.ai/login"
            case "codex": out["url"] = "https://auth.openai.com/codex/device"; out["user_code"] = "K7QF-2M9XD"
            default: out["url"] = "https://github.com/login/device"; out["user_code"] = "4F2A-9C1B"
            }
        }
        if r.canceled { out["error"] = "canceled" }
        return out
    }

    private func tools() -> [JSON] {
        [("claude", "Claude Code", "2.1.302 (Claude Code)"), ("codex", "Codex", "codex-cli 0.160.1"), ("gh", "GitHub CLI", "gh version 2.102.0 (2026-09-30)")].map { id, name, version in
            var t: JSON = ["id": id, "name": name, "command": id, "installed": installed(id)]
            if installed(id) { t["path"] = "/home/ubuntu/.local/bin/\(id)"; t["version"] = version }
            if id == "gh", installed(id) { t["signed_in"] = !signedOut.contains("gh") }
            if installing[id] != nil { t["installing"] = true }
            return t
        }
    }

    /// pierd's lines about the GitHub CLI and the sign-ins this mock follows, for `GET /v1/doctor`: a missing GitHub CLI
    /// does not hide Codex's sign-in.
    func doctorChecks() -> [JSON] {
        var out: [JSON] = []
        if !installed("gh") {
            out.append(["area": "Worktrees and sessions", "name": "gh", "status": "warn", "tool": "gh",
                        "detail": "not installed; pull requests and the GitHub list need it, and the Pier app can install it", "fix": "pierd tools install gh"])
        } else if signedOut.contains("gh") {
            out.append(["area": "Worktrees and sessions", "name": "gh", "status": "ok", "detail": "/home/ubuntu/.local/bin/gh", "tool": "gh"])
            out.append(["area": "Agents", "name": "GitHub sign-in", "status": "warn", "tool": "gh", "fix": "gh auth login --web --git-protocol https",
                        "detail": "gh is not signed in on this box: pull requests, the GitHub list and private repositories need it"])
        } else {
            out.append(["area": "Worktrees and sessions", "name": "gh", "status": "ok", "detail": "/home/ubuntu/.local/bin/gh", "tool": "gh"])
            out.append(["area": "Agents", "name": "GitHub sign-in", "status": "ok", "detail": "signed in", "tool": "gh"])
        }
        if MockSignIns.enabled {
            out.append(signedOut.contains("codex")
                ? ["area": "Agents", "name": "Codex sign-in", "status": "warn", "tool": "codex", "account": "codex",
                   "detail": "not signed in on this box: a new session would stop at its login prompt", "fix": "codex login --device-auth"]
                : ["area": "Agents", "name": "Codex sign-in", "status": "ok", "detail": "signed in", "tool": "codex", "account": "codex"])
        }
        return out
    }

    mutating func route(_ method: BoxClient.Method, _ p: [String], _ body: Data?) -> (Int, Data)? {
        let now = Date()
        settle(now)
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        switch (method, p.count, p[1]) {
        case (.get, 3, "github") where p[2] == "repos" && !installed("gh"):
            return (501, Self.data(["error": "gh (GitHub CLI) is not installed on this box; install it and run `gh auth login` there", "code": "gh_missing"]))
        case (.get, 3, "github") where p[2] == "repos" && signedOut.contains("gh"):
            return (428, Self.data(["error": "gh is not signed in on this box; run `gh auth login` there", "code": "gh_auth"]))
        case (.get, 2, "tools"):
            return (200, Self.data(tools()))
        case (.post, 3, "tools") where p[2] == "install":
            let ids = (req["tools"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? ["claude", "codex", "gh"]
            for id in ids where !installed(id) && installing[id] == nil { installing[id] = now }
            return (202, Self.data(tools()))
        case (.get, 2, "logins"):
            return (200, Self.data(runs.reversed().map { json($0, now) }))
        case (.post, 2, "logins"):
            let tool = (req["tool"] as? String) ?? ""
            guard ["claude", "codex", "gh"].contains(tool) else {
                return (400, Self.data(["error": "sign-ins are for claude, codex or gh, not \"\(tool)\"", "code": "bad_request"]))
            }
            guard installed(tool) else {
                return (424, Self.data(["error": "GitHub CLI is not installed on this box; install it first (POST /v1/tools/install)", "code": "tool_missing"]))
            }
            let account = tool == "gh" ? nil : (req["account"] as? String) ?? tool
            for i in runs.indices where runs[i].tool == tool && runs[i].account == account && !["done", "failed"].contains(state(runs[i], now)) {
                runs[i].canceled = true
            }
            let r = Run(id: String(UUID().uuidString.prefix(12)).lowercased(), tool: tool, account: account, started: now)
            runs.append(r)
            return (202, Self.data(json(r, now)))
        case (_, 3, "logins"), (_, 4, "logins"):
            guard let i = runs.firstIndex(where: { $0.id == p[2] }) else {
                return (404, Self.data(["error": "no sign-in with that id", "code": "not_found"]))
            }
            switch method {
            case .post where p.count == 4 && p[3] == "code":
                guard runs[i].tool == "claude", state(runs[i], now) == "enter_code" else {
                    return (409, Self.data(["error": "this sign-in is not waiting for a code", "code": "bad_request"]))
                }
                runs[i].codeAt = now
            case .delete where p.count == 3:
                if !["done", "failed"].contains(state(runs[i], now)) { runs[i].canceled = true }
            case .get where p.count == 3:
                break
            default:
                return nil
            }
            return (200, Self.data(json(runs[i], now)))
        default:
            return nil
        }
    }

    private static func data(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data("{}".utf8) }
}
