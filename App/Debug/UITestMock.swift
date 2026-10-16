import Foundation
import PierKit

/// `-uiTestMock 1`: the app runs against an in-memory box (no network, no keychain, no pairing) so XCUITests are
/// deterministic. The data comes from the PierKit test fixtures (see `MockFixtures`); a few endpoints are stateful
/// (send, answer, create task) so the conversation really changes while a test types. Release builds have it too: the
/// demo's box is this one with the showcase's data (`DemoMode`).
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
    /// A task or chat just started: Claude Code writes its record only once the prompt is in, so for its first seconds the
    /// box has none to read (`source: "none"`), as on pierd.
    private var recordAt: [String: Date] = [:]
    /// Messages sent with `when: idle` while the agent works, held until its turn ends (pierd's queue, docs/API.md 4.3):
    /// `turn`, `preview`, `length`, `at` as `GET .../queue` answers, plus the whole `text`.
    private var held: [String: [JSON]] = [:]
    /// How long the agent takes to answer a message: 1.4 s, or `-mockReplyDelay <s>` (a run that sends while it works).
    private static var replyDelay: Double {
        let d = UserDefaults.standard.double(forKey: "mockReplyDelay")
        return d > 0 ? d : 1.4
    }
    /// How long that lasts: 3 s, or `-mockRecordDelay <s>` (a UI test that looks at the chat meanwhile).
    private static var recordDelay: Double {
        let d = UserDefaults.standard.double(forKey: "mockRecordDelay")
        return d > 0 ? d : 3
    }
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
    // --- `-uiTestAskForm 1`: an agent asking two questions at once (the second a multiple choice), the way Claude Code
    // asks them: the form only in the session's ask (from its hook), not in the transcript, its tabs on screen. ---
    static let formSession = "sandbox-form-claude-q2"
    static var formQuestions: [JSON] { [
        ["question": "Which colour for the header?", "header": "Colour",
         "options": [["label": "Red", "description": "Warm and loud"], ["label": "Blue", "description": "Calm"]]],
        ["question": "Which sections go on the page?", "header": "Sections", "multi": true,
         "options": [["label": "Pricing"], ["label": "FAQ"], ["label": "Team"]]],
    ] }
    static let formScreen = """
    ❯ Build the landing page
    ────────────────────────────────────────────────────────────────────────
    ←  ☐ Colour  ☐ Sections  ✔ Submit  →

    Which colour for the header?

    ❯ 1. Red
         Warm and loud
      2. Blue
         Calm
      3. Type something.
    ────────────────────────────────────────────────────────────────────────
      4. Chat about this

    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """
    private var mcpAnswered = false
    /// `-uiTestChatLab 1`: the conversation built to strain the chat screen (UITestMockChatLab.swift).
    private var chatLab = MockChatLab()
    private var removedWorktrees: Set<String> = []
    /// `-uiTestPRs 1`: pull requests (see the block at the end of the file).
    fileprivate var prs = MockPRs()
    /// The worktrees' files and history (UITestMockWorkspace.swift).
    private var workspace = MockWorkspace()
    private var projects = MockProjects()
    /// The shells started without an agent (UITestMockTerminals.swift).
    private var terminals = MockTerminals()

    init() {
        // `-uiTestShowcase 1`: the showcase dataset (English, or Portuguese with the app in Portuguese) instead of everything below (UITestShowcase.swift).
        if UITestShowcase.enabled {
            sessions = UITestShowcase.sessions()
            transcripts = UITestShowcase.transcripts()
            // What is said later (a message, the reply after Permitir) lands after the showcase's record, as in the lab.
            off = max(off, transcripts.values.joined().compactMap { $0["off"] as? Int }.max() ?? 0)
            return
        }
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
        if MockChatLab.enabled {
            sessions.append(Self.chat(MockChatLab.name, state: "finished", title: MockChatLab.title))
            let lab = MockChatLab.transcript(firstOffset: 5_000_000)
            transcripts[MockChatLab.name] = lab
            // What is said later lands after the record, as offsets in a real record grow.
            off = max(off, lab.compactMap { $0["off"] as? Int }.max() ?? 0)
        }
        // `-uiTestEmpty 1`: a box with nothing running (the Mac's edge tab with no agent, empty Home and Inbox).
        if UserDefaults.standard.bool(forKey: "uiTestEmpty") { sessions = []; transcripts = [:] }
        if UserDefaults.standard.bool(forKey: "uiTestAskForm") {
            var form = Self.session(Self.formSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "waiting",
                                    title: "Build the landing page",
                                    ask: ["tool": "AskUserQuestion", "input": "Which colour for the header?", "message": "Claude needs your permission",
                                          "questions": Self.formQuestions])
            form["state_since"] = Self.iso(Date().addingTimeInterval(-20))
            sessions.append(form)
            transcripts[Self.formSession] = [item("user", text: "Build the landing page")]
        }
        if UserDefaults.standard.bool(forKey: "uiTestAsk") {
            var ask = Self.session(Self.askSession, location: "sandbox", dir: "/home/ubuntu/code/sandbox", state: "waiting",
                                   title: "Build the pricing page",
                                   ask: ["tool": "AskUserQuestion", "input": "Which layout for the pricing page?", "message": "Claude has a question",
                                         // The form, as pierd sends it with the wait (from the hook).
                                         "questions": [["question": "Which layout for the pricing page?", "header": "Layout",
                                                        "options": Self.askChoices.map { ["label": $0] }]]])
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
    /// The ask session's "Type something." row was picked: the next send is the person's words.
    private var askTyping = false

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

    /// `POST /v1/sessions/{name}/tty`: a shell's terminal (UITestMockTerminals.swift), what is typed echoed and run as a
    /// shell would; a program that ends by itself gives the prompt back a moment later. The program ending leaves the
    /// stream open, as tmux keeps a dead pane on screen; the session going ends it.
    func duplex(_ method: BoxClient.Method, path: String, contentType: String, body: AsyncStream<Data>) -> AsyncThrowingStream<Data, Error> {
        let parts = (path.split(separator: "?").first ?? "").split(separator: "/").map(String.init)
        guard parts.count == 4, parts[1] == "sessions", parts[3] == "tty", let name = parts[2].removingPercentEncoding,
              lock.withLock({ terminals.has(name) }) else {
            return AsyncThrowingStream { $0.finish(throwing: PierError.api(status: 404, message: "no session with that name", code: "not_found")) }
        }
        return AsyncThrowingStream { continuation in
            let start = self.lock.withLock { self.terminals.ttyStart(name) }
            continuation.yield(start)
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    let (out, gone) = self.lock.withLock { (self.terminals.ttyTick(name), !self.terminals.has(name)) }
                    if !out.isEmpty { continuation.yield(out) }
                    if gone { continuation.finish(); return }
                }
            }
            let reader = Task {
                for await chunk in body {
                    for line in chunk.split(separator: UInt8(ascii: "\n")) {
                        guard let f = try? JSONSerialization.jsonObject(with: Data(line)) as? JSON,
                              let b64 = f["data"] as? String, let bytes = Data(base64Encoded: b64) else { continue }
                        let out = self.lock.withLock { () -> Data in
                            let out = self.terminals.ttyInput(name, bytes)
                            if self.terminals.exited(name), let i = self.index(name) { self.sessions[i]["exited"] = true }
                            return out
                        }
                        if !out.isEmpty { continuation.yield(out) }
                    }
                }
                ticker.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                ticker.cancel()
            }
        }
    }

    func send(_ method: BoxClient.Method, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        if Self.isAITitle(path, body) { try? await Task.sleep(for: .seconds(3)) }   // the model takes a moment (see the AI title block)
        let (status, data) = lock.withLock { handle(method, path, body) }
        if status >= 400 {
            // As the real transport reads pierd's errors: the message and the code apart.
            struct Payload: Decodable { let error: String?; let code: String? }
            let p = try? JSONDecoder().decode(Payload.self, from: data)
            throw PierError.api(status: status, message: p?.error ?? String(decoding: data, as: UTF8.self), code: p?.code)
        }
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
        if method == .post, p.count == 2, p[1] == "sessions", let r = startTerminal(body) { return r }   // a shell, before the PR flow's agents
        if UITestShowcase.enabled, let r = showcaseRoute(method, p, query, body) { return r }   // the showcase block at the end of the file
        if MockPRs.enabled, let r = pullRequestRoute(method, p, body) { return r }
        if let r = talkRoute(method, p, body) { return r }   // Falar's router (block at the end of the file)
        if let r = pairInviteRoute(method, p) { return r }   // "Levar para o iPhone" (block at the end of the file)
        if let r = workspace.route(method, p, query, body) { return r }   // a worktree's files (UITestMockWorkspace.swift)
        if method == .post, p.count == 4, p[1] == "accounts", p[3] == "login" {
            // The terminal where the person signs in.
            let s = Self.session("login-\(p[2])", location: "", dir: "/home/ubuntu", state: "ready", title: "Entrar")
            sessions.insert(s, at: 0)
            return (200, Self.json(s))
        }
        if let r = projects.route(method, p, query, body, locations: MockFixtures.locations) { return r }   // clones, GitHub, removal (UITestMockProjects.swift)
        switch (method, p[1]) {
        case (.get, "info"):
            // pierd with the file routes.
            var info = Self.fixtureObject(MockFixtures.info)
            info["capabilities"] = ((info["capabilities"] as? [String]) ?? []) + ["files", "projects", "environments", "accounts", "box.env", "shares", "prepare"]
                // Terminals stream (`-mockTTY 0`: a box before them, its screen read every second).
                + (UserDefaults.standard.string(forKey: "mockTTY") == "0" ? [] : ["tty"])
            return (200, Self.json(info))
        case (.get, "doctor"): return (200, Self.json(doctorChecks()))
        case (.get, "stats"): return (200, Self.fixture(MockFixtures.stats))
        case (.get, "agents"): return (200, Self.fixture(MockFixtures.agents))
        case (.get, "locations") where p.count == 2: return (200, projects.locations(MockFixtures.locations))
        case (.get, "locations") where p.count == 4 && p[3] == "branches": return (200, Self.fixture(MockFixtures.branches))
        case (.get, "locations") where p.count == 7 && p[6] == "touched": return (200, Self.fixture(MockFixtures.touched))
        case (.get, "worktrees"): return (200, worktreeStatuses(location: query["location"]))
        case (.delete, "locations") where p.count == 5 && p[3] == "worktrees":
            // Like pierd: the worktree's sessions are killed with it.
            removedWorktrees.insert("\(p[2])/\(p[4])")
            sessions.removeAll { ($0["location"] as? String) == "\(p[2])/\(p[4])" }
            return (200, Self.json(["removed": p[4]]))
        case (.get, "review"): return (200, Self.fixture(MockFixtures.review))
        case (.get, "services"): return (200, projects.services())
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
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        let cmd = (req["command"] as? String) ?? ""
        if let r = workspace.exec(cmd, location: (req["location"] as? String) ?? "sandbox") { return r }
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
        if req["prepare"] as? Bool == false, let wt = req["name"] as? String { projects.noteUnprepared(location: location, worktree: wt) }
        seq += 1
        let name = "\(location)-claude-n\(seq)"
        let s = Self.session(name, location: location, dir: "/home/ubuntu/code/\(location)", state: "running", title: String(prompt.prefix(40)))
        sessions.insert(s, at: 0)
        transcripts[name] = [item("user", text: prompt)]
        recordAt[name] = Date().addingTimeInterval(Self.recordDelay)
        scheduleReply(name, text: "Started. I'll let you know when it's done.", after: Self.recordDelay + 2)
        var out = Self.fixtureObject(MockFixtures.taskCreate)
        out["session"] = s
        return (201, Self.json(out))
    }

    /// `POST /v1/sessions` with an agent (a shell, with none, is `startTerminal`'s, taken first): a chat (`chat: true`, no
    /// location) or an agent in a worktree that exists (`sandbox`, `sandbox/subtract`: a project's Agentes tab, Nesta
    /// worktree); anything else is refused.
    private func startChat(_ body: Data?) -> (Int, Data) {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        if req["chat"] as? Bool != true, let location = req["location"] as? String { return startAgent(req, in: location) }
        guard req["chat"] as? Bool == true, req["location"] == nil else { return notFound }
        let prompt = (req["prompt"] as? String) ?? ""
        seq += 1
        let name = "chat-\((req["agent"] as? String) ?? "claude")-n\(seq)"
        var s = Self.chat(name, state: "running", title: (req["title"] as? String) ?? String(prompt.prefix(40)))
        s["agent"] = req["agent"] ?? "claude"
        sessions.insert(s, at: 0)
        transcripts[name] = [item("user", text: prompt)]
        recordAt[name] = Date().addingTimeInterval(Self.recordDelay)
        scheduleReply(name, text: "Good question. Let's think it through together.", after: Self.recordDelay + 2)
        return (200, Self.json(s))
    }

    /// An agent started in a worktree that exists ("sandbox" for the main checkout, "sandbox/subtract"), as pierd's
    /// `POST /v1/sessions` starts one: its record comes after the start-up delay, then it answers the prompt.
    private func startAgent(_ req: JSON, in location: String) -> (Int, Data) {
        let parts = location.split(separator: "/", maxSplits: 1).map(String.init)
        let listed = (try? JSONSerialization.jsonObject(with: projects.locations(MockFixtures.locations))) as? [JSON] ?? []
        guard let project = listed.first(where: { $0["name"] as? String == parts.first }), !removedWorktrees.contains(location),
              parts.count == 1 || ((project["worktrees"] as? [JSON]) ?? []).contains(where: { $0["name"] as? String == parts[1] })
        else { return notFound }
        let agent = (req["agent"] as? String) ?? "claude"
        let prompt = (req["prompt"] as? String) ?? ""
        seq += 1
        let flat = location.replacingOccurrences(of: "/", with: "-")
        let name = "\(flat)-\(agent)-n\(seq)"
        var s = Self.session(name, location: location, dir: "/home/ubuntu/code/\(flat)", state: "running",
                             title: (req["title"] as? String) ?? String(prompt.prefix(40)))
        s["agent"] = agent
        s["preset"] = agent
        sessions.insert(s, at: 0)
        transcripts[name] = [item("user", text: prompt)]
        recordAt[name] = Date().addingTimeInterval(Self.recordDelay)
        scheduleReply(name, text: "On it: I'll work in this worktree and tell you when it's done.", after: Self.recordDelay + 2)
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
                self.deliverHeld(name)
            }
        }
    }

    /// The turn ended: the first message held for it goes in, typed as pierd types it, and is answered like any other.
    private func deliverHeld(_ name: String) {
        guard var queue = held[name], !queue.isEmpty, let i = index(name) else { return }
        let h = queue.removeFirst()
        held[name] = queue
        sessions[i]["queued"] = queue.count
        let text = h["text"] as? String ?? ""
        transcripts[name, default: []].append(item("user", text: text))
        seq += 1
        scheduleReply(name, text: "Picked up your queued message (\(text.count) characters).", after: Self.replyDelay)
    }

    /// The chat lab's reply, as Claude Code writes one: running, the words growing on screen (the draft) for about 5 s,
    /// then the record has the block while the screen still shows it for 2 s (the overlap), then the turn ends.
    private func streamLabReply(_ name: String, reply: String) {
        setState(name, "running")
        let words = reply.split(separator: " ", omittingEmptySubsequences: false)
        Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))   // the agent reads before it writes
            var shown = 0
            while shown < words.count {
                shown = min(words.count, shown + 3)
                let partial = words.prefix(shown).joined(separator: " ")
                self?.lock.withLock { self?.chatLab.draft = partial }
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard let self else { return }
            self.lock.withLock { self.transcripts[name, default: []].append(self.item("text", text: reply)) }
            try? await Task.sleep(for: .seconds(2))
            self.lock.withLock {
                self.chatLab.draft = nil
                self.setState(name, "finished")
            }
        }
    }

    private func sessionRoute(_ method: BoxClient.Method, _ p: [String], _ query: [String: String], _ body: Data?) -> (Int, Data) {
        let name = p[2]
        guard let si = index(name) else { return notFound }
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        if let r = terminalRoute(method, name, si, p, req) { return r }   // a terminal's pane, lines and keys
        if UITestShowcase.enabled, let r = showcaseSessionRoute(method, name, p, query, req) { return r }
        if p.count == 3 {
            switch method {
            case .delete: sessions.remove(at: si); return (200, Data("{}".utf8))
            case .patch: sessions[si]["title"] = req["title"] ?? sessions[si]["title"]; return (200, Self.json(sessions[si]))
            default: return (200, Self.json(sessions[si]))
            }
        }
        switch (method, p[3]) {
        case (.get, "transcript") where p.count == 4:
            if let at = recordAt[name], Date() < at {
                return (200, Self.json(["source": "none", "items": [JSON](), "crew": [JSON](),
                                        "reason": "No claude conversation for /home/ubuntu/code/\(name) yet in ~/.claude/projects."]))
            }
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
            if UITestShowcase.enabled, let extra = UITestShowcase.transcriptExtras(name: name) { for (k, v) in extra { page[k] = v } }
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
            // "Type something." (the row after the choices) opens a field; the next words with Enter are the answer.
            if askTyping {
                askTyping = false
                transcripts[name, default: []].append(item("user", text: text))
                return answerAsk(text)
            }
            if Int(text) == Self.askChoices.count + 1, req["enter"] as? Bool == false { askTyping = true; return (200, Self.json(["sent": true])) }
            guard let n = Int(text), (1...Self.askChoices.count).contains(n) else { return (409, Data(#"{"error":"Claude is waiting for a choice"}"#.utf8)) }
            return answerAsk(Self.askChoices[n - 1])
        case (.get, "screen") where name == Self.formSession && (sessions[si]["agent_state"] as? String) == "waiting":
            return (200, Self.json(["screen": Self.formScreen]))
        case (.post, "answer") where name == Self.formSession:
            // pierd answers a form the transcript does not hold yet with the tool's own name, from the session's ask.
            let answers = (req["answers"] as? [JSON]) ?? []
            let picks = answers.map { ($0["picks"] as? [String]) ?? [] }
            guard req["tool"] as? String == "AskUserQuestion", picks.count == 2, picks[0].count == 1, !picks[1].isEmpty,
                  (sessions[si]["agent_state"] as? String) == "waiting" else {
                return (409, Data(#"{"error":"Claude's form has no such answer: finish in Claude's screen"}"#.utf8))
            }
            let shown = picks.map { $0.joined(separator: ", ") }
            var q = item("question")
            q["done"] = true; q["tool"] = "toolu_form1"; q["questions"] = Self.formQuestions; q["answers"] = shown
            transcripts[name, default: []].append(q)
            scheduleReply(name, text: "Header in \(shown[0]), with \(shown[1]). Building it now.", after: 1.0)
            return (200, Self.json(["answered": shown]))
        case (.post, "answer") where name == Self.askSession:
            let picks = ((req["answers"] as? [JSON])?.first?["picks"] as? [String]) ?? []
            // The person's own words, typed into "Type something" as pierd does (box/answer.go).
            if picks.isEmpty, let other = (req["answers"] as? [JSON])?.first?["other"] as? String, !other.isEmpty {
                transcripts[name, default: []].append(item("user", text: other))
                return answerAsk(other)
            }
            guard let pick = picks.first, Self.askChoices.contains(pick) else { return (409, Data(#"{"error":"that option isn't on screen"}"#.utf8)) }
            return answerAsk(pick)
        case (.get, "screen"):
            let screen = (sessions[si]["agent_state"] as? String) == "waiting"
                ? Self.fixtureObject(MockFixtures.screenPermission)["screen"] : Self.fixtureObject(MockFixtures.screenFinished)["screen"]
            return (200, Self.json(["screen": screen ?? ""]))
        case (.get, "draft") where name == MockChatLab.name:
            var d: JSON = ["agent": "claude"]
            if let t = chatLab.draft { d["text"] = t; d["status"] = ["word": "Brewing…"] }
            return (200, Self.json(d))
        case (.post, "send") where name == MockChatLab.name:
            let text = (req["text"] as? String) ?? ""
            transcripts[name, default: []].append(item("user", text: text))
            seq += 1
            chatLab.sent += 1
            streamLabReply(name, reply: MockChatLab.streamedReply(chatLab.sent))
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": "\(name)#\(seq)"]))
        case (.get, "draft"): return (200, Self.json(["agent": "claude"]))
        case (.get, "controls"): return (200, Self.fixture(MockFixtures.controls))
        case (.get, "queue") where p.count == 4: return (200, Self.json(held[name] ?? []))
        case (.delete, "queue") where p.count == 5:
            held[name]?.removeAll { ($0["turn"] as? String) == p[4] }
            sessions[si]["queued"] = held[name]?.count ?? 0
            return (200, Data("{}".utf8))
        case (.post, "queue") where p.count == 6 && p[5] == "send":
            guard let h = held[name]?.first(where: { ($0["turn"] as? String) == p[4] }) else { return notFound }
            held[name]?.removeAll { ($0["turn"] as? String) == p[4] }
            sessions[si]["queued"] = held[name]?.count ?? 0
            let text = h["text"] as? String ?? ""
            transcripts[name, default: []].append(item("user", text: text))
            seq += 1
            scheduleReply(name, text: "Picked up your queued message (\(text.count) characters).", after: Self.replyDelay)
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": p[4]]))
        case (.get, "diff"): return (200, Self.fixture(MockFixtures.fileDiff))
        case (.post, "send") where name == Self.mcpSession && !mcpAnswered:
            mcpAnswered = true
            scheduleReply(name, text: "MCP server enabled. Ready.", after: 0.8)
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": "\(name)#1"]))
        case (.post, "send") where (req["when"] as? String) == "idle" && ["running", "waiting"].contains(sessions[si]["agent_state"] as? String ?? ""):
            // While the agent works the message waits for its turn to end, as on pierd.
            let text = (req["text"] as? String) ?? ""
            seq += 1
            let turn = "\(name)#h\(seq)"
            held[name, default: []].append(["turn": turn, "preview": String(text.prefix(200)), "length": text.count, "origin": "app",
                                             "at": Self.iso(), "text": text])
            sessions[si]["queued"] = held[name]?.count ?? 0
            return (200, Self.json(["sent": false, "queued": true, "at": Self.iso(), "seq": seq, "turn": turn]))
        case (.post, "send"):
            let text = (req["text"] as? String) ?? ""
            transcripts[name, default: []].append(item("user", text: text))
            seq += 1
            scheduleReply(name, text: "Got it. I read your message (\(text.count) characters) and I'm on it.\n\n```bash\ngit status --short\n```",
                          after: Self.replyDelay)
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": "\(name)#\(seq)"]))
        case (.post, "keys"), (.post, "answer"):
            scheduleReply(name, text: "Thanks, continuing.", after: 1.0)
            return (200, Data("{}".utf8))
        case (.post, "interrupt"): setState(name, "finished"); return (200, Self.json(["interrupted": true]))
        default: return notFound
        }
    }

    // MARK: terminals

    /// `POST /v1/sessions` with neither `agent`, `chat` nor `home`: a shell at the location (with `command`, that command),
    /// named and listed as pierd does (UITestMockTerminals.swift); nil for any other request.
    private func startTerminal(_ body: Data?) -> (Int, Data)? {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        guard req["agent"] == nil, req["chat"] as? Bool != true, req["home"] as? Bool != true,
              let location = req["location"] as? String, !location.isEmpty else { return nil }
        guard let dir = folder(of: location) else { return (404, Self.json(["error": "no location named \(location)", "code": "not_found"])) }
        let command = (req["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (req["name"] as? String) ?? MockTerminals.defaultName(location: location, command: command)
        guard index(name) == nil else { return (409, Self.json(["error": "session \(name) already exists", "code": "session_exists"])) }
        terminals.start(name, ref: location, dir: dir, command: command)
        var s: JSON = ["name": name, "location": location, "dir": dir, "created": Self.iso(), "attached": 0, "exited": terminals.exited(name)]
        if let command { s["command"] = command }
        if let title = req["title"] as? String, !title.isEmpty { s["title"] = title }
        sessions.append(s)
        return (200, Self.json(s))
    }

    /// A terminal's pane, its lines and keys, and its end; nil for an agent's session and for what a terminal shares with
    /// one (a rename).
    private func terminalRoute(_ method: BoxClient.Method, _ name: String, _ si: Int, _ p: [String], _ req: JSON) -> (Int, Data)? {
        guard terminals.has(name) else { return nil }
        defer { if index(name) == si, terminals.exited(name) { sessions[si]["exited"] = true } }
        switch (method, p.count > 3 ? p[3] : "") {
        case (.delete, ""):
            sessions.remove(at: si)
            terminals.remove(name)
            return (200, Self.json(["removed": name]))
        case (.get, "screen"):
            return (200, Self.json(["screen": terminals.screen(name)]))
        case (.get, "transcript"):
            return (200, Self.json(["source": "none", "items": [JSON](), "crew": [JSON]()]))
        case (.post, "send"), (.post, "keys"):
            guard !terminals.exited(name) else { return (409, Self.json(["error": "the program in \(name) has ended", "code": "session_exited"])) }
            if p[3] == "send" {
                terminals.type(name, text: (req["text"] as? String) ?? "", enter: (req["enter"] as? Bool) ?? true)
                return (200, Self.json(["sent": true, "at": Self.iso()]))
            }
            terminals.press(name, keys: (req["keys"] as? [String]) ?? [])
            return (200, Self.json(["sent": true]))
        default:
            return nil
        }
    }

    /// Where a ref ("loc", or "loc/wt") is on the box: its worktree's folder in the locations the mock lists.
    private func folder(of ref: String) -> String? {
        let data = UITestShowcase.enabled ? Data(UITestShowcase.locations.utf8) : projects.locations(MockFixtures.locations)
        let locations = (try? JSONSerialization.jsonObject(with: data)) as? [JSON] ?? []
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        guard let l = locations.first(where: { $0["name"] as? String == parts.first }) else { return nil }
        let worktrees = l["worktrees"] as? [JSON] ?? []
        let w = parts.count > 1 ? worktrees.first(where: { $0["name"] as? String == parts[1] })
                                : worktrees.first(where: { $0["main"] as? Bool == true }) ?? worktrees.first
        return w?["path"] as? String ?? (parts.count == 1 ? l["path"] as? String : nil)
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
        if cmd.contains("pier-home:project-prs") { return ok(UITestShowcase.projectPRsOutput(command: cmd)) }
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
// MARK: - Showcase (`-uiTestShowcase 1`) --------------------------------------------------------------------------------
// The English dataset for screenshots (UITestShowcase.swift): its projects, worktrees, review, dev servers, pull requests,
// CI and git activity, the screens the cards read, and the answers the AI touches would give. What it does not name falls
// through to the generic routes above (sessions, transcripts, send, create task, chats).

extension MockBox {
    fileprivate func showcaseRoute(_ method: BoxClient.Method, _ p: [String], _ query: [String: String], _ body: Data?) -> (Int, Data)? {
        let req = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? JSON) ?? [:]
        switch (method, p[1]) {
        case (.get, "locations") where p.count == 2: return (200, Data(UITestShowcase.locations.utf8))
        case (.get, "locations") where p.count == 7 && p[6] == "touched": return (200, Self.json(UITestShowcase.touched(location: p[2], worktree: p[4])))
        case (.get, "worktrees"):
            let all = UITestShowcase.worktrees(location: query["location"])
            return (200, Self.json(all.filter { !removedWorktrees.contains("\($0["location"] ?? "")/\($0["name"] ?? "")") }))
        case (.get, "review"): return (200, Data(UITestShowcase.review.utf8))
        case (.get, "services"): return (200, Data(UITestShowcase.services.utf8))
        case (.post, "exec"): return showcaseExec((req["command"] as? String) ?? "", location: (req["location"] as? String) ?? "")
        default: return nil
        }
    }

    /// The box's `exec`: the markers come first (their commands name the model too), then git / gh.
    private func showcaseExec(_ cmd: String, location: String) -> (Int, Data)? {
        // The workspace's history and quick open are the generic routes' (their commands carry `--no-ext-diff`, which
        // the "diff" below would take).
        if cmd.contains("# pier-log:") || cmd.contains("# pier-files:") { return nil }
        // A worktree the review does not list: git's status, clean, on that worktree's branch (not a diff).
        if cmd == GitActions.statusCommand {
            let parts = location.split(separator: "/", maxSplits: 1).map(String.init)
            let wts = UITestShowcase.worktrees(location: parts.first)
            let w = wts.first { parts.count > 1 ? $0["name"] as? String == parts[1] : ($0["main"] as? Bool) == true }
            let branch = w?["branch"] as? String ?? "main"
            return ok("## \(branch)...origin/\(branch)\0\n--pier-numstat--\n")
        }
        if cmd.contains(NextSteps.marker) { return ok(UITestShowcase.nextSteps(prompt: MockPRs.sentText(cmd))) }
        if cmd.contains(AITitle.marker) { return ok("\"\(UITestShowcase.aiTitle(prompt: MockPRs.sentText(cmd)))\"\n") }
        if cmd.contains(TalkRouter.marker) {
            return ok("```json\n" + String(decoding: Self.json(UITestShowcase.talkDecision(prompt: MockPRs.sentText(cmd))), as: UTF8.self) + "\n```\n")
        }
        if cmd.contains("PIER_MAIN_OK") { return ok("PIER_MAIN_OK 9c2e41a\n") }
        if cmd.contains("--model haiku") { return ok(UITestShowcase.aiDraft) }
        if cmd.contains("pier-home:project-prs") { return ok(UITestShowcase.projectPRsOutput(command: cmd)) }
        if cmd.contains("pier-home:prs") { return ok(String(decoding: Self.json(UITestShowcase.homePRs()), as: UTF8.self) + "\n") }
        if cmd.contains("pier-home:ci") { return ok(UITestShowcase.ciOutput()) }
        if cmd.contains("pier-home:git") { return ok(UITestShowcase.gitActivity(command: cmd)) }
        if cmd.hasPrefix("gh pr view "), let n = Int(cmd.dropFirst("gh pr view ".count).prefix { $0.isNumber }) {
            return ok(String(decoding: Self.json(UITestShowcase.prView(number: n)), as: UTF8.self) + "\n")
        }
        if cmd.contains("pier-pr:diff") { return ok(UITestShowcase.prDiff) }
        if cmd.contains("diff") { return ok(UITestShowcase.diff(for: cmd)) }
        return nil
    }

    /// Per session: the screens (menus, the raw terminal), a tool's detail, diffs, and the answers to the permission and
    /// the question; the rest (transcripts, messages, interrupt) is the generic code.
    fileprivate func showcaseSessionRoute(_ method: BoxClient.Method, _ name: String, _ p: [String], _ query: [String: String], _ req: JSON) -> (Int, Data)? {
        guard p.count >= 4, let si = index(name) else { return nil }
        let waiting = (sessions[si]["agent_state"] as? String) == "waiting"
        switch (method, p[3]) {
        case (.get, "screen"):
            guard let s = UITestShowcase.screen(name: name, waiting: waiting) else { return nil }
            return (200, Self.json(["screen": s]))
        case (.get, "transcript") where p.count == 6:
            return (200, Self.json(UITestShowcase.toolDetail(name: name)))
        case (.get, "diff"):
            let file = query["file"] ?? query["path"] ?? ""
            return (200, Self.json(["diff": UITestShowcase.diff(for: file), "file": file]))
        case (.post, "keys") where name == UITestShowcase.permission && waiting:
            scheduleReply(name, text: UITestShowcase.permissionReply, after: 1.2)
            return (200, Data("{}".utf8))
        case (.post, "send") where name == UITestShowcase.question && waiting:
            let text = (req["text"] as? String) ?? ""
            guard let n = Int(text), (1...UITestShowcase.questionChoices.count).contains(n) else { return (409, Data(#"{"error":"Claude is waiting for a choice"}"#.utf8)) }
            let pick = UITestShowcase.questionChoices[n - 1]
            scheduleReply(name, text: UITestShowcase.questionReply(pick), after: 1.0)
            return (200, Self.json(["answered": [pick]]))
        case (.post, "answer") where name == UITestShowcase.question:
            let picks = ((req["answers"] as? [JSON])?.first?["picks"] as? [String]) ?? []
            guard let pick = picks.first else { return (409, Data(#"{"error":"that option isn't on screen"}"#.utf8)) }
            scheduleReply(name, text: UITestShowcase.questionReply(pick), after: 1.0)
            return (200, Self.json(["answered": [pick]]))
        case (.post, "send") where name == UITestShowcase.permission && waiting && (req["enter"] as? Bool) == false:
            // Permitir and Negar type the menu's digit, as on pierd: a key, not a message (nothing joins the record).
            let allow = ["1", "2"].contains((req["text"] as? String) ?? "")
            scheduleReply(name, text: allow ? UITestShowcase.permissionReply : UITestShowcase.declineReply, after: 1.2)
            return (200, Self.json(["sent": true, "at": Self.iso()]))
        case (.post, "send") where (req["enter"] as? Bool) != false:
            let text = (req["text"] as? String) ?? ""
            transcripts[name, default: []].append(item("user", text: text))
            seq += 1
            scheduleReply(name, text: UITestShowcase.demoReply)
            return (200, Self.json(["sent": true, "at": Self.iso(), "seq": seq, "turn": "\(name)#\(seq)"]))
        default:
            return nil
        }
    }
}
// MARK: - end of showcase ----------------------------------------------------------------------------------------------
