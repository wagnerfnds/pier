#if DEBUG
import Foundation
import PierKit

/// `-uiTestMock 1`: the app runs against an in-memory box (no network, no keychain, no pairing) so XCUITests are
/// deterministic. The data comes from the PierKit test fixtures (see `MockFixtures`); a few endpoints are stateful
/// (send, answer, create task) so the conversation really changes while a test types.
enum UITestMock {
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "uiTestMock") || ProcessInfo.processInfo.arguments.contains("-uiTestMock")
    }

    /// The mock box's client, for the headless paths (notification actions, intents) that otherwise read the keychain.
    nonisolated(unsafe) static var headless: (name: String, client: any PierBoxClient)?

    @MainActor static func makeConnection() -> BoxConnection {
        let box = MockBox()
        let record = BoxRecord(name: "devbox", address: "mock.invalid:1", fingerprint: Fingerprint(bytes: [UInt8](repeating: 7, count: 32))!)
        let client = BoxAPI(transport: box)
        headless = (record.name, client)
        return BoxConnection(record: record, client: client, raw: box)
    }
}

/// The scripted box. Thread-safe; answers like pierd for the endpoints the app uses.
final class MockBox: PierTransport, @unchecked Sendable {
    typealias JSON = [String: Any]
    private let lock = NSLock()
    private var sessions: [JSON] = []
    private var transcripts: [String: [JSON]] = [:]
    private var seq = 300
    private var off = 1000

    static let finishedSession = "sandbox-subtract-claude-6s1"
    static let waitingSession = "sandbox-claude-w9q"
    static let runningSession = "acme-web-claude-a1b"
    /// `-uiTestChats 1` adds a chat: an agent tied to no project, in its own folder under ~/pier/chats (no location).
    /// Kept out of the default set, like the extras, so the older tests see the same Home and Inbox.
    static let chatSession = "chat-claude-c4t"
    // `-uiTestExtras 1` adds these (kept out of the default set so the older tests see the same Home).
    static let mcpSession = "sandbox-mcp-claude-m1"
    static let backgroundSession = "sandbox-verify-claude-b2"
    static let exitedSession = "sandbox-old-claude-x3"
    static let mcpScreen = """
    ╭──────────────────────────────────────────────────────────────────────────────╮
    │ New MCP server found in .mcp.json: notes                                     │
    │                                                                              │
    │ MCP servers may execute code or access system resources. All tool calls      │
    │ require approval. Learn more in the MCP documentation.                       │
    │                                                                              │
    │ ❯ 1. Use this and all future MCP servers in this project                      │
    │   2. Use this MCP server                                                     │
    │   3. Continue without using this MCP server                                  │
    │                                                                              │
    ╰──────────────────────────────────────────────────────────────────────────────╯
       Enter to confirm · Esc to reject
    """
    // --- Answer from the notification: `-uiTestAsk 1` adds an agent asking a question with three choices, drawn on its
    // screen as Claude Code draws AskUserQuestion while it waits (the transcript gets the item once answered). ---
    static let askSession = "sandbox-ask-claude-q1"
    static let askChoices = ["Three tiers", "One plan", "A table"]
    static let askScreen = """
    ● Which layout for the pricing page?

     ❯ 1. Three tiers
          Starter, Pro and Team side by side
       2. One plan
          One price, the features listed below
       3. A table
          Every feature against every plan
       4. Type something.
       5. Chat about this

      Enter to select · ↑↓ to move
    """
    // --- end answer from the notification ---
    private var mcpAnswered = false
    private var removedWorktrees: Set<String> = []
    /// `-uiTestPRs 1`: pull requests (see the block at the end of the file).
    fileprivate var prs = MockPRs()

    init() {
        sessions = [
            Self.session(Self.waitingSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "waiting",
                         title: "Create a probe directory for the build check",
                         ask: ["input": "mkdir probe_dir && touch probe_dir/x.txt", "tool": "Bash", "why": "Create probe_dir and an empty x.txt inside it"]),
            Self.session(Self.finishedSession, location: "sandbox/subtract", dir: "/home/ubuntu/code/sandbox-subtract", state: "finished",
                         title: "Add a subtract function to calc.py and a test"),
            Self.session(Self.runningSession, location: "acme-web", dir: "/home/ubuntu/code/acme-web", state: "running",
                         title: "Migrate the billing page to the new API"),
        ]
        if UserDefaults.standard.bool(forKey: "uiTestChats") {
            sessions.append(Self.chat(Self.chatSession, state: "finished", title: "Plan a home server for the team"))
            transcripts[Self.chatSession] = [
                item("user", text: "Plan a home server for the team"),
                item("text", text: "Here is a first plan: one small machine with Ubuntu, Tailscale for access, and a nightly backup to S3."),
            ]
        }
        transcripts[Self.finishedSession] = longConversation()
        transcripts[Self.waitingSession] = [
            item("user", text: "Create a probe directory for the build check"),
            item("text", text: "I'll create `probe_dir` with an empty `x.txt` so the build step has something to find."),
        ]
        transcripts[Self.runningSession] = [item("user", text: "Migrate the billing page to the new API")]
        if UserDefaults.standard.bool(forKey: "uiTestExtras") {
            sessions.append(Self.session(Self.mcpSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "idle",
                                         title: "Set up the MCP check"))
            sessions.append(Self.session(Self.backgroundSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "finished",
                                         title: "Run the full verification suite"))
            var old = Self.session(Self.exitedSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "finished",
                                   title: "Old finished experiment")
            old["exited"] = true
            sessions.append(old)
            transcripts[Self.mcpSession] = []
            transcripts[Self.backgroundSession] = [
                item("user", text: "Run the full verification suite"),
                item("text", text: "The suite is running in the background; it takes about 11 minutes. I'll open the PR when it ends."),
            ]
            transcripts[Self.exitedSession] = [item("user", text: "Old finished experiment")]
        }
        // `-uiTestEmpty 1`: a box with nothing running (the Mac's edge tab with no agent, empty Home and Inbox).
        if UserDefaults.standard.bool(forKey: "uiTestEmpty") { sessions = []; transcripts = [:] }
        if UserDefaults.standard.bool(forKey: "uiTestAsk") {
            var ask = Self.session(Self.askSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "waiting",
                                   title: "Build the pricing page",
                                   ask: ["tool": "AskUserQuestion", "input": "Which layout for the pricing page?", "message": "Claude has a question"])
            ask["state_since"] = Self.iso(Date().addingTimeInterval(-30))   // asked after the permission: listed after it
            sessions.append(ask)
            transcripts[Self.askSession] = [
                item("user", text: "Build the pricing page"),
                item("text", text: "Before I build it: which layout do you want?"),
            ]
        }
    }

    /// `GET /v1/doctor`: a healthy box, or with `-uiTestHealth 1` three things to fix (a signed-out agent, missing hooks,
    /// pierd stopping at logout), the way pierd words them.
    private func doctorChecks() -> [JSON] {
        var checks: [JSON] = [
            ["area": "pierd", "name": "listening", "status": "ok", "detail": "192.0.2.10:7444"],
            ["area": "pierd", "name": "starts at boot", "status": "ok", "detail": "installed as a user service"],
            ["area": "Worktrees and sessions", "name": "git", "status": "ok", "detail": "/usr/bin/git"],
            ["area": "Worktrees and sessions", "name": "tmux", "status": "ok", "detail": "/usr/bin/tmux"],
            ["area": "Agents", "name": "claude", "status": "ok", "detail": "/home/ubuntu/.local/bin/claude"],
            ["area": "Agents", "name": "Claude Code hooks", "status": "ok", "detail": "pierd's hooks installed"],
            ["area": "Agents", "name": "Claude Code sign-in", "status": "ok", "detail": "signed in"],
        ]
        if UserDefaults.standard.bool(forKey: "uiTestHealth") {
            checks += [
                ["area": "pierd", "name": "survives logout", "status": "warn", "detail": "pierd stops when you log out", "fix": "sudo loginctl enable-linger ubuntu"],
                ["area": "Agents", "name": "codex", "status": "ok", "detail": "/home/ubuntu/.local/bin/codex"],
                ["area": "Agents", "name": "Codex hooks", "status": "warn", "detail": "not installed, so pierd cannot tell when this agent is done or needs you", "fix": "pierd integrations install codex"],
                ["area": "Agents", "name": "Codex sign-in", "status": "warn", "detail": "not signed in on this box: a new session would stop at its login prompt", "fix": "codex login --device-auth"],
            ] as [JSON]
        } else {
            checks.append(["area": "pierd", "name": "survives logout", "status": "ok", "detail": "user lingering is on"])
        }
        return checks
    }

    /// The question's reply once a choice arrives (a structured answer, or the digit of its row on screen).
    private func answerAsk(_ pick: String) -> (Int, Data) {
        scheduleReply(Self.askSession, text: "Going with \(pick). Building the pricing page now.", after: 1.0)
        return (200, Self.json(["answered": [pick]]))
    }

    // MARK: builders

    private static func iso(_ d: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }

    private static func session(_ name: String, location: String, dir: String, state: String, title: String, ask: JSON? = nil) -> JSON {
        var s: JSON = [
            "agent": "claude", "agent_state": state, "attached": 0, "command": "claude --model sonnet",
            "created": iso(Date().addingTimeInterval(-3600)), "dir": dir, "exited": false, "fidelity": "hooks",
            "location": location, "name": name, "preset": "claude", "state_seq": 250,
            "state_since": iso(Date().addingTimeInterval(-95)), "title": title, "turn": "\(name)#3",
        ]
        if let ask { s["ask"] = ask }
        return s
    }

    /// A chat as pierd lists it: no location, its own folder, `chat: true`.
    private static func chat(_ name: String, state: String, title: String) -> JSON {
        var s = session(name, location: "", dir: "/home/ubuntu/pier/chats/\(name)", state: state, title: title)
        s["location"] = nil
        s["chat"] = true
        return s
    }

    private func nextOff() -> Int { off += 1000; return off }

    private func item(_ kind: String, text: String? = nil, extra: JSON = [:]) -> JSON {
        let o = nextOff()
        var it: JSON = ["id": "cl@\(o).1", "kind": kind, "off": o]
        if let text { it["text"] = text }
        for (k, v) in extra { it[k] = v }
        return it
    }

    private func edit(_ file: String, added: Int, removed: Int = 0) -> JSON {
        item("edit", extra: ["file": file, "added": added, "removed": removed, "tool": "toolu_\(nextOff())"])
    }

    private func tools(_ verb: String, _ target: String) -> JSON {
        item("tools", extra: ["verb": verb, "done": true, "items": [["id": "toolu_\(nextOff())", "verb": verb, "target": target, "at": 1_791_408_804_607]]])
    }

    /// A long chat, so there is something to scroll: the captured fixture turn plus replies with code in several languages.
    private func longConversation() -> [JSON] {
        var out: [JSON] = []
        if let d = MockFixtures.transcript.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? JSON, let items = o["items"] as? [JSON] {
            for var it in items {
                let n = nextOff(); it["id"] = "cl@\(n).1"; it["off"] = n
                if it["kind"] as? String == "tools", var calls = it["items"] as? [JSON] { for i in calls.indices { calls[i]["id"] = "toolu_\(n)_\(i)" }; it["items"] = calls }
                out.append(it)
            }
        }
        out.append(item("user", text: "Show me how you would type this in TypeScript, and the shell command to run the tests."))
        out.append(tools("Read", "calc.ts"))
        out.append(edit("calc.ts", added: 12, removed: 1))
        out.append(item("text", text: """
        Here is the TypeScript version. It keeps the same two functions and adds a typed `Result`:

        ```ts
        // calc.ts
        export type Result = { ok: true; value: number } | { ok: false; error: string };

        export function subtract(a: number, b: number): Result {
          if (Number.isNaN(a) || Number.isNaN(b)) return { ok: false, error: "NaN" };
          return { ok: true, value: a - b };
        }
        ```

        Run the tests with:

        ```bash
        npm test -- --watch=false && echo "all green"
        ```
        """))
        out.append(item("user", text: "And in Swift, plus the config and the migration."))
        out.append(item("text", text: """
        Swift:

        ```swift
        struct Calc {
            func subtract(_ a: Int, _ b: Int) -> Int { a - b }
        }
        // 3 - 2 == 1
        ```

        Config (`ci.yml`):

        ```yaml
        name: ci
        on: [push]
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - run: npm test
        ```

        Migration:

        ```sql
        ALTER TABLE ledger ADD COLUMN delta INTEGER NOT NULL DEFAULT 0; -- subtract support
        ```

        Anything else you want me to change?
        """))
        out.append(item("user", text: "Looks good. Summarize the three things you changed."))
        out.append(item("text", text: "1. `calc.py` got `subtract`.\n2. `test_calc.py` covers it.\n3. `calc.ts` mirrors the API with a typed result.\n\nNothing was committed yet."))
        out.append(edit("calc.py", added: 5, removed: 2))
        out.append(edit("test_calc.py", added: 3))
        return out
    }

    // MARK: PierTransport

    func stream(path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }   // no events: the app polls
    }

    func reset() async {}

    func send(_ method: BoxClient.Method, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        if Self.isAITitle(path, body) { try? await Task.sleep(for: .seconds(3)) }   // the model takes a moment (see the AI title block)
        let (status, data) = lock.withLock { handle(method, path, body) }
        if status >= 400 { throw PierError.api(status: status, message: String(decoding: data, as: UTF8.self), code: nil) }
        return (status, data)
    }

    private static func json(_ any: Any) -> Data { (try? JSONSerialization.data(withJSONObject: any)) ?? Data("{}".utf8) }
    private static func fixture(_ s: String) -> Data { Data(s.utf8) }
    private static func fixtureObject(_ s: String) -> JSON { ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? JSON) ?? [:] }

    private func handle(_ method: BoxClient.Method, _ full: String, _ body: Data?) -> (Int, Data) {
        let comps = full.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(comps[0])
        var query: [String: String] = [:]
        if comps.count > 1 {
            for pair in comps[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                query[String(kv[0])] = kv.count > 1 ? String(kv[1]).removingPercentEncoding : ""
            }
        }
        let p = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard p.first == "v1", p.count >= 2 else { return notFound }
        if MockPRs.enabled, let r = pullRequestRoute(method, p, body) { return r }
        if let r = talkRoute(method, p, body) { return r }   // Falar's router (block at the end of the file)
        if let r = pairInviteRoute(method, p) { return r }   // "Levar para o iPhone" (block at the end of the file)
        switch (method, p[1]) {
        case (.get, "info"): return (200, Self.fixture(MockFixtures.info))
        case (.get, "doctor"): return (200, Self.json(doctorChecks()))
        case (.get, "stats"): return (200, Self.fixture(MockFixtures.stats))
        case (.get, "agents"): return (200, Self.fixture(MockFixtures.agents))
        case (.get, "locations") where p.count == 2: return (200, Self.fixture(MockFixtures.locations))
        case (.get, "locations") where p.count == 4 && p[3] == "branches": return (200, Self.fixture(MockFixtures.branches))
        case (.get, "locations") where p.count == 7 && p[6] == "touched": return (200, Self.fixture(MockFixtures.touched))
        case (.get, "worktrees"): return (200, worktreeStatuses(location: query["location"]))
        case (.delete, "locations") where p.count == 5 && p[3] == "worktrees":
            // Like pierd: the worktree's sessions are killed with it.
            removedWorktrees.insert("\(p[2])/\(p[4])")
            sessions.removeAll { ($0["location"] as? String) == "\(p[2])/\(p[4])" }
            return (200, Self.json(["removed": p[4]]))
        case (.get, "review"): return (200, Self.fixture(MockFixtures.review))
        case (.get, "services"): return (200, Data("[]".utf8))
        case (.get, "sessions") where p.count == 2: return (200, Self.json(sessions))
        case (.post, "sessions") where p.count == 2: return startChat(body)
        case (.post, "tasks"): return createTask(body)
        case (.post, "exec"): return exec(body)
        case (_, "sessions") where p.count >= 3: return sessionRoute(method, p, query, body)
        default: return notFound
        }
    }

    private var notFound: (Int, Data) { (404, Data(#"{"error":"not found","code":"not_found"}"#.utf8)) }

    private func worktreeStatuses(location: String?) -> Data {
        var out: [JSON] = []
        let locs = (try? JSONSerialization.jsonObject(with: Data(MockFixtures.locations.utf8))) as? [JSON] ?? []
        for l in locs where location == nil || l["name"] as? String == location {
            for w in l["worktrees"] as? [JSON] ?? [] {
                let pushed = (w["main"] as? Bool) != true
                out.append(["ahead": 0, "behind": (w["main"] as? Bool) == true ? 2 : 0, "branch": w["branch"] ?? "main", "changed": 0,
                            "location": l["name"] ?? "", "main": w["main"] ?? false, "base": pushed ? "origin/\(w["branch"] ?? "")" : "origin/main",
                            "name": w["name"] ?? "", "path": w["path"] ?? "", "port": w["port"] ?? 0, "sessions": 0, "untracked": 0])
            }
        }
        if UserDefaults.standard.bool(forKey: "uiTestExtras"), location == nil || location == "sandbox" {
            // Leftovers for the Faxina: a pushed worktree nobody is on, and one with commits only on the box.
            out.append(["ahead": 0, "behind": 0, "branch": "feat/old-pr", "changed": 0, "location": "sandbox", "main": false, "base": "origin/feat/old-pr",
                        "name": "old-pr", "path": "/home/ubuntu/code/sandbox-old-pr", "port": 41090, "sessions": 0, "untracked": 0])
            out.append(["ahead": 2, "behind": 0, "branch": "wip", "changed": 1, "location": "sandbox", "main": false, "base": "main",
                        "name": "wip", "path": "/home/ubuntu/code/sandbox-wip", "port": 41095, "sessions": 0, "untracked": 0])
        }
        out.removeAll { removedWorktrees.contains("\($0["location"] ?? "")/\($0["name"] ?? "")") }
        return Self.json(out)
    }

    private func exec(_ body: Data?) -> (Int, Data) {
        let cmd = ((body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON)?["command"] as? String) ?? ""
        // --- Inbox: suggested next steps (`NextSteps.command`), answered like the model would (Portuguese, strict JSON). ---
        if cmd.contains(NextSteps.marker) {
            return (200, Self.json(["exit_code": 0, "output": #"{"replies":["Abra o PR","Rode os testes de novo"]}"#]))
        }
        // --- end Inbox ---
        if cmd.contains(AITitle.marker) { return aiTitleExec(cmd) }
        if cmd.contains("PIER_MAIN_OK") { return (200, Self.json(["exit_code": 0, "output": "PIER_MAIN_OK abc1234\n"])) }
        if cmd.contains("--model haiku") {   // AIDraft: answer like the model would
            let out = "<<<COMMIT\nAdd subtract() to calc.py with a test\n\n- subtract(a, b) returns a - b\n>>>\n<<<TITLE\nAdd subtract() to calc.py\n>>>\n<<<BODY\n## Summary\n- New subtract(a, b) with a unit test\n>>>"
            return (200, Self.json(["exit_code": 0, "output": out]))
        }
        if cmd.contains("diff") { return (200, Self.json(["exit_code": 0, "output": Self.fixtureObject(MockFixtures.fileDiff)["diff"] ?? ""])) }
        return (200, Self.json(["exit_code": 1, "output": ""]))
    }

    private func createTask(_ body: Data?) -> (Int, Data) {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let prompt = (req["prompt"] as? String) ?? "New task"
        let location = (req["location"] as? String) ?? "sandbox"
        seq += 1
        let name = "\(location)-claude-n\(seq)"
        let s = Self.session(name, location: location, dir: "/home/ubuntu/code/\(location)", state: "running", title: String(prompt.prefix(40)))
        sessions.insert(s, at: 0)
        transcripts[name] = [item("user", text: prompt)]
        scheduleReply(name, text: "Started. I'll let you know when it's done.")
        var out = Self.fixtureObject(MockFixtures.taskCreate)
        out["session"] = s
        return (201, Self.json(out))
    }

    /// `POST /v1/sessions` with `chat: true` (the only form the app sends outside the PR flow); anything else is refused.
    private func startChat(_ body: Data?) -> (Int, Data) {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        guard req["chat"] as? Bool == true, req["location"] == nil else { return notFound }
        let prompt = (req["prompt"] as? String) ?? ""
        seq += 1
        let name = "chat-\((req["agent"] as? String) ?? "claude")-n\(seq)"
        var s = Self.chat(name, state: "running", title: (req["title"] as? String) ?? String(prompt.prefix(40)))
        s["agent"] = req["agent"] ?? "claude"
        sessions.insert(s, at: 0)
        transcripts[name] = [item("user", text: prompt)]
        scheduleReply(name, text: "Good question. Let's think it through together.")
        return (200, Self.json(s))
    }

    // MARK: sessions

    private func index(_ name: String) -> Int? { sessions.firstIndex { $0["name"] as? String == name } }

    private func setState(_ name: String, _ state: String) {
        guard let i = index(name) else { return }
        sessions[i]["agent_state"] = state
        sessions[i]["state_since"] = Self.iso()
        sessions[i]["state_seq"] = (sessions[i]["state_seq"] as? Int ?? 0) + 1
        if state != "waiting" { sessions[i]["ask"] = nil }
    }

    /// Runs the agent for a moment, then answers and goes back to `finished`.
    private func scheduleReply(_ name: String, text: String, after: Double = 1.4) {
        setState(name, "running")
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            guard let self else { return }
            self.lock.withLock {
                self.transcripts[name, default: []].append(self.item("text", text: text))
                self.setState(name, "finished")
            }
        }
    }

    private func sessionRoute(_ method: BoxClient.Method, _ p: [String], _ query: [String: String], _ body: Data?) -> (Int, Data) {
        let name = p[2]
        guard let si = index(name) else { return notFound }
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        if p.count == 3 {
            switch method {
            case .delete: sessions.remove(at: si); return (200, Data("{}".utf8))
            case .patch: sessions[si]["title"] = req["title"] ?? sessions[si]["title"]; return (200, Self.json(sessions[si]))
            default: return (200, Self.json(sessions[si]))
            }
        }
        switch (method, p[3]) {
        case (.get, "transcript") where p.count == 4:
            let all = transcripts[name] ?? []
            // --- Agents board: `before=0` is "the tail" (the board's last reply of a finished turn), as on pierd. ---
            if query["before"] == "0" { return (200, Self.json(["source": "claude", "items": Array(all.suffix(40)), "more": all.count > 40, "next": 0])) }
            // --- end agents board ---
            if query["before"] != nil { return (200, Self.json(["source": "claude", "items": [JSON](), "more": false])) }
            let since = min(Int(query["since"] ?? "0") ?? 0, all.count)
            var page = Self.fixtureObject(MockFixtures.transcript)
            page["items"] = Array(all[since...]).isEmpty ? NSNull() : Array(all[since...])
            page["next"] = all.count
            page["start"] = 0
            page["file"] = "mock-\(name)"
            page["gen"] = "1.0"
            if name == Self.backgroundSession {
                let since = Int64(Date().addingTimeInterval(-200).timeIntervalSince1970 * 1000)
                page["signals"] = ["mode": "auto", "background": [["tool": "toolu_bg1", "task": "b1", "kind": "shell",
                    "command": "cd /home/ubuntu/code/sandbox; scripts/verificar.sh 41710 > /tmp/v.log 2>&1", "state": "running", "since": since]]]
            }
            return (200, Self.json(page))
        case (.get, "transcript") where p.count == 6: return (200, Self.fixture(MockFixtures.toolDetail))
        case (.get, "screen") where name == Self.mcpSession && !mcpAnswered:
            return (200, Self.json(["screen": Self.mcpScreen]))
        case (.get, "screen") where name == Self.askSession && (sessions[si]["agent_state"] as? String) == "waiting":
            return (200, Self.json(["screen": Self.askScreen]))
        case (.post, "send") where name == Self.askSession && (sessions[si]["agent_state"] as? String) == "waiting":
            // The digit of a row on screen (the fallback when the box cannot drive the form).
            let text = (req["text"] as? String) ?? ""
            guard let n = Int(text), (1...Self.askChoices.count).contains(n) else { return (409, Data(#"{"error":"Claude is waiting for a choice"}"#.utf8)) }
            return answerAsk(Self.askChoices[n - 1])
        case (.post, "answer") where name == Self.askSession:
            let picks = ((req["answers"] as? [JSON])?.first?["picks"] as? [String]) ?? []
            guard let pick = picks.first, Self.askChoices.contains(pick) else { return (409, Data(#"{"error":"that option isn't on screen"}"#.utf8)) }
            return answerAsk(pick)
        case (.get, "screen"):
            let screen = (sessions[si]["agent_state"] as? String) == "waiting"
                ? Self.fixtureObject(MockFixtures.screenPermission)["screen"] : Self.fixtureObject(MockFixtures.screenFinished)["screen"]
            return (200, Self.json(["screen": screen ?? ""]))
        case (.get, "draft"): return (200, Self.json(["agent": "claude"]))
        case (.get, "controls"): return (200, Self.fixture(MockFixtures.controls))
        case (.get, "queue"): return (200, Data("[]".utf8))
        case (.get, "diff"): return (200, Self.fixture(MockFixtures.fileDiff))
        case (.post, "send") where name == Self.mcpSession && !mcpAnswered:
            mcpAnswered = true
            scheduleReply(name, text: "MCP server enabled. Ready.", after: 0.8)
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": "\(name)#1"]))
        case (.post, "send"):
            let text = (req["text"] as? String) ?? ""
            transcripts[name, default: []].append(item("user", text: text))
            seq += 1
            scheduleReply(name, text: "Got it. I read your message (\(text.count) characters) and I'm on it.\n\n```bash\ngit status --short\n```")
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": "\(name)#\(seq)"]))
        case (.post, "keys"), (.post, "answer"):
            scheduleReply(name, text: "Thanks, continuing.", after: 1.0)
            return (200, Data("{}".utf8))
        case (.post, "interrupt"): setState(name, "finished"); return (200, Self.json(["interrupted": true]))
        default: return notFound
        }
    }
}

// MARK: - Pull requests (`-uiTestPRs 1`) ------------------------------------------------------------------------------
// The Home "Pull requests" widget, `gh pr view/diff/merge/comment/review/close/ready`, bringing a PR into a worktree
// (`git fetch`, `POST .../worktrees`, the checkout) and starting an agent there (`POST /v1/sessions`). Stateful: a merge,
// comment or review shows up in the next `gh pr view`. Commands are recognised by distinctive substrings.

struct MockPRs {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "uiTestPRs") }
    static let repo = "octocat/acme-web"
    static let head = "feat/billing-api"

    var state = "OPEN"
    var isDraft = false
    var decision = "CHANGES_REQUESTED"
    var comments: [[String: Any]] = [
        ["id": "IC_1", "author": ["login": "monalisa"], "createdAt": "2026-10-07T18:20:00Z",
         "body": "Pronto para outra olhada: os testes de cobrança agora passam localmente."],
    ]
    var reviews: [[String: Any]] = [
        ["id": "PRR_1", "author": ["login": "octocat"], "state": "CHANGES_REQUESTED", "submittedAt": "2026-10-07T20:05:00Z",
         "body": "O total da fatura arredonda errado quando há desconto. Use `Decimal` em `BillingTotals` e cubra o caso com um teste."],
        ["id": "PRR_2", "author": ["login": "copilot-pull-request-reviewer"], "state": "COMMENTED", "submittedAt": "2026-10-07T17:00:00Z",
         "body": "<!-- ccr -->\n## Copilot review overview\nThe migration looks consistent; one rounding risk in `totals.ts`."],
    ]

    static let body = """
    Migra a página de **cobrança** para a API nova (`/v2/billing`).

    ## O que muda
    - `BillingPage` lê de `useBilling()` em vez do endpoint antigo
    - Faturas paginadas no servidor
    - Remove o cache manual em `localStorage`

    ## Como testar
    1. Abra **Financeiro → Cobrança**
    2. Troque de mês e confira os totais

    ```ts
    const { invoices, totals } = useBilling({ month })
    ```
    """

    func view(number: Int) -> [String: Any] {
        let files: [[String: Any]] = [
            ["path": "app/billing/BillingPage.tsx", "additions": 120, "deletions": 41, "changeType": "MODIFIED"],
            ["path": "app/billing/useBilling.ts", "additions": 88, "deletions": 0, "changeType": "ADDED"],
            ["path": "app/billing/legacyCache.ts", "additions": 0, "deletions": 22, "changeType": "DELETED"],
        ]
        let checks: [[String: Any]] = [
            ["__typename": "CheckRun", "name": "lint", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/\(Self.repo)/actions/runs/1/job/1"],
            ["__typename": "CheckRun", "name": "test (billing)", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://github.com/\(Self.repo)/actions/runs/1/job/2"],
            ["__typename": "CheckRun", "name": "e2e", "workflowName": "CI", "status": "IN_PROGRESS", "conclusion": "", "detailsUrl": "https://github.com/\(Self.repo)/actions/runs/1/job/3"],
            ["__typename": "StatusContext", "context": "vercel", "state": "SUCCESS", "targetUrl": "https://vercel.com/x"],
        ]
        return [
            "number": number, "title": number == 42 ? "Migrar a página de cobrança para a nova API" : "Ajustar o cabeçalho do relatório",
            "body": Self.body, "url": "https://github.com/\(Self.repo)/pull/\(number)", "state": state, "isDraft": isDraft,
            "author": ["login": "monalisa", "name": "Mona Lisa", "is_bot": false], "baseRefName": "main", "headRefName": Self.head,
            "headRepository": ["name": "acme-web", "nameWithOwner": Self.repo], "headRepositoryOwner": ["login": "octocat"],
            "isCrossRepository": false, "maintainerCanModify": false, "createdAt": "2026-10-06T14:00:00Z", "updatedAt": "2026-10-07T20:05:00Z",
            "mergedAt": state == "MERGED" ? "2026-10-08T12:00:00Z" : NSNull(), "closedAt": NSNull(),
            "additions": 208, "deletions": 63, "changedFiles": 3, "files": files, "statusCheckRollup": checks,
            "reviewDecision": decision, "reviews": reviews, "reviewRequests": [["login": "joao-qa"]], "comments": comments,
            "mergeable": "MERGEABLE", "mergeStateStatus": state == "OPEN" ? "BLOCKED" : "UNKNOWN",
            "labels": [["name": "billing", "color": "1D76DB"], ["name": "frontend", "color": "5319E7"]],
        ]
    }

    static func home() -> [String: Any] {
        func pr(_ n: Int, _ title: String, _ author: String, _ decision: String, _ check: String) -> [String: Any] {
            ["number": n, "title": title, "url": "https://github.com/\(repo)/pull/\(n)", "isDraft": false, "updatedAt": "2026-10-07T20:05:00Z",
             "additions": 208, "deletions": 63, "reviewDecision": decision, "repository": ["nameWithOwner": repo], "author": ["login": author],
             "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": check]]]]]]
        }
        return ["viewer": "octocat", "review": [pr(42, "Migrar a página de cobrança para a nova API", "monalisa", "CHANGES_REQUESTED", "FAILURE")],
                "mine": [pr(41, "Ajustar o cabeçalho do relatório", "octocat", "APPROVED", "SUCCESS")], "reviewCount": 1, "mineCount": 1]
    }

    /// The text a command sends as `printf %s '<base64>' | base64 -d`.
    static func sentText(_ cmd: String) -> String {
        guard let r = cmd.range(of: "printf %s '"), let end = cmd[r.upperBound...].firstIndex(of: "'"),
              let d = Data(base64Encoded: String(cmd[r.upperBound..<end])) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

extension MockBox {
    private func ok(_ output: String, exit: Int = 0) -> (Int, Data) { (200, Self.json(["exit_code": exit, "output": output])) }

    fileprivate func pullRequestRoute(_ method: BoxClient.Method, _ p: [String], _ body: Data?) -> (Int, Data)? {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        switch (method, p[1]) {
        case (.post, "exec"):
            return prExec((req["command"] as? String) ?? "")
        case (.post, "locations") where p.count == 4 && p[3] == "worktrees":
            let name = (req["name"] as? String) ?? "pr"
            return (200, Self.json(["name": name, "path": "/home/ubuntu/code/\(p[2])-\(name)", "branch": req["branch"] ?? name, "head": "f50244a204"]))
        case (.post, "sessions") where p.count == 2:
            let location = (req["location"] as? String) ?? "acme-web"
            seq += 1
            let name = "\(location.replacingOccurrences(of: "/", with: "-"))-claude-p\(seq)"
            let s = Self.session(name, location: location, dir: "/home/ubuntu/code/\(location.replacingOccurrences(of: "/", with: "-"))",
                                 state: "running", title: (req["title"] as? String) ?? "PR")
            sessions.insert(s, at: 0)
            transcripts[name] = [item("user", text: (req["prompt"] as? String) ?? "")]
            scheduleReply(name, text: "Li o PR e as mudanças pedidas. Vou trocar o arredondamento por `Decimal` e escrever o teste.")
            return (200, Self.json(s))
        default:
            return nil
        }
    }

    private func prExec(_ cmd: String) -> (Int, Data)? {
        if cmd.contains("pier-home:prs") {
            let line = String(decoding: Self.json(MockPRs.home()), as: UTF8.self)
            return ok(line + "\n")
        }
        if cmd.hasPrefix("gh pr view "), let n = Int(cmd.dropFirst("gh pr view ".count).prefix { $0.isNumber }) {
            return ok(String(decoding: Self.json(prs.view(number: n)), as: UTF8.self) + "\n")
        }
        if cmd.contains("pier-pr:diff") {
            return ok((Self.fixtureObject(MockFixtures.fileDiff)["diff"] as? String) ?? "")
        }
        if cmd.contains("gh pr merge ") {
            prs.state = "MERGED"
            return ok("✓ Squashed and merged pull request \(MockPRs.repo)#42 (Migrar a página de cobrança para a nova API)\n✓ Deleted remote branch \(MockPRs.head)")
        }
        if cmd.contains("gh pr comment ") {
            prs.comments.append(["id": "IC_\(prs.comments.count + 1)", "author": ["login": "octocat"], "createdAt": Self.iso(), "body": MockPRs.sentText(cmd)])
            return ok("https://github.com/\(MockPRs.repo)/pull/42#issuecomment-\(prs.comments.count)")
        }
        if cmd.contains("gh pr review ") {
            let approve = cmd.contains("--approve")
            prs.reviews.append(["id": "PRR_\(prs.reviews.count + 1)", "author": ["login": "octocat"], "submittedAt": Self.iso(),
                                "state": approve ? "APPROVED" : cmd.contains("--request-changes") ? "CHANGES_REQUESTED" : "COMMENTED",
                                "body": MockPRs.sentText(cmd)])
            if approve { prs.decision = "APPROVED" }
            return ok("✓ Reviewed pull request \(MockPRs.repo)#42")
        }
        if cmd.contains("gh pr close ") { prs.state = "CLOSED"; return ok("✓ Closed pull request \(MockPRs.repo)#42") }
        if cmd.contains("gh pr ready ") { prs.isDraft = false; return ok("✓ Pull request \(MockPRs.repo)#42 is marked as \"ready for review\"") }
        if cmd.hasPrefix("git fetch origin ") { return ok("From github.com:\(MockPRs.repo)\n * [new branch] \(MockPRs.head) -> origin/\(MockPRs.head)") }
        if cmd.contains(PRCommands.branchMark) {
            return ok("branch '\(MockPRs.head)' set up to track 'origin/\(MockPRs.head)'.\n\n\(PRCommands.branchMark)\n\(MockPRs.head)\n")
        }
        return nil
    }
}
// MARK: - end of pull requests ------------------------------------------------------------------------------------------

// MARK: - Falar router -------------------------------------------------------------------------------------------------
// `exec` of `TalkRouter.command` (marked `pier-talk`): answers like Haiku would, with a fixed decision keyed on the
// request's words: "subtract" -> send to the finished subtract session, "readme" -> new task in sandbox, "fantasma" ->
// a session that does not exist (the app must refuse it), anything else -> a question.

extension MockBox {
    fileprivate func talkRoute(_ method: BoxClient.Method, _ p: [String], _ body: Data?) -> (Int, Data)? {
        guard method == .post, p[1] == "exec" else { return nil }
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let cmd = (req["command"] as? String) ?? ""
        guard cmd.contains(TalkRouter.marker) else { return nil }
        let prompt = MockPRs.sentText(cmd)
        var request = prompt
        if let a = prompt.range(of: "<<<\n"), let b = prompt.range(of: "\n>>>", range: a.upperBound..<prompt.endIndex) {
            request = String(prompt[a.upperBound..<b.lowerBound])
        }
        let r = request.lowercased()
        let decision: JSON
        if r.contains("subtract") {
            decision = ["action": "send", "box": "devbox", "session": Self.finishedSession, "text": "Add a test for subtracting negative numbers."]
        } else if r.contains("readme") {
            decision = ["action": "new_task", "box": "devbox", "location": "sandbox", "prompt": "Write a README for the sandbox project.",
                        "title": "Escrever o README"]
        } else if r.contains("fantasma") {
            decision = ["action": "send", "box": "devbox", "session": "ghost-claude-0", "text": "boo"]
        } else {
            decision = ["action": "ask", "question": "Em qual projeto: sandbox ou acme-web?"]
        }
        // Like the model sometimes does: a fence around the object.
        let out = "```json\n" + String(decoding: Self.json(decision), as: UTF8.self) + "\n```\n"
        return (200, Self.json(["exit_code": 0, "output": out]))
    }
}
// MARK: - end of Falar router -------------------------------------------------------------------------------------------

// MARK: - AI titles (`AITitle` through exec) -------------------------------------------------------------------------------
// Answers the title prompt like Haiku would, after a moment (`send` waits 3 s for it), so a test sees the prompt-derived
// title first and the AI one replace it. The title depends on the prompt's language, as the real prompt asks.

extension MockBox {
    static let aiTitlePT = "Ajustar arredondamento da fatura"
    static let aiTitleEN = "Fix invoice total rounding"

    fileprivate static func isAITitle(_ path: String, _ body: Data?) -> Bool {
        guard path.hasPrefix("/v1/exec"), let body else { return false }
        return String(decoding: body, as: UTF8.self).contains(AITitle.marker)
    }

    fileprivate func aiTitleExec(_ cmd: String) -> (Int, Data) {
        let prompt = MockPRs.sentText(cmd)
        let pt = prompt.range(of: #"\b(que|com|de|para|não|fatura|arredond)"#, options: [.regularExpression, .caseInsensitive],
                              range: (prompt.range(of: "The task:")?.upperBound ?? prompt.startIndex)..<prompt.endIndex) != nil
        return (200, Self.json(["exit_code": 0, "output": "\"\(pt ? Self.aiTitlePT : Self.aiTitleEN).\"\n"]))
    }
}
// MARK: - end of AI titles ---------------------------------------------------------------------------------------------
// MARK: - Pair invites ("Levar para o iPhone", onboarding) ------------------------------------------------------------
// `POST /v1/pair/invite` answers like the rewritten box server (`{"link","expires"}`, a fresh code each time);
// `-uiTestNoInvite 1` makes it a box without any invite route (404 on both, so the screen shows its fallback).
extension MockBox {
    static var invitesDisabled: Bool { UserDefaults.standard.bool(forKey: "uiTestNoInvite") }

    fileprivate func pairInviteRoute(_ method: BoxClient.Method, _ p: [String]) -> (Int, Data)? {
        guard method == .post, p.count == 3, p[1] == "pair" || p[1] == "pairing", p[2] == "invite" else { return nil }
        if Self.invitesDisabled || p[1] == "pairing" { return (404, Data("404 page not found".utf8)) }
        let code = String((0..<52).map { _ in "abcdefghijklmnopqrstuvwxyz234567".randomElement()! })
        let fp = String(repeating: "a", count: 52)
        let f = ISO8601DateFormatter()
        return (200, Self.json(["link": "pier://mock.invalid:7444?code=\(code)&fp=\(fp)", "expires": f.string(from: Date().addingTimeInterval(600))]))
    }
}
// MARK: - end of pair invites ------------------------------------------------------------------------------------------
#endif
