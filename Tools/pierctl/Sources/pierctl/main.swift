import PierKit
import Foundation

// pierctl: tiny macOS CLI proving PierKit against a real box. State: ~/.config/pierctl, or $PIERCTL_HOME
// (a separate identity and set of paired boxes, e.g. for testing another server side by side).
// `get` is read-only; post/put/patch/delete/send/task mutate the box, use with care.

let stateDir = ProcessInfo.processInfo.environment["PIERCTL_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pierctl")
let store = FileStore(directory: stateDir)
let boxes = BoxStore(store: store)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func selectBox(_ name: String?) throws -> BoxRecord {
    let all = try boxes.list()
    if let name {
        guard let b = all.first(where: { $0.name == name || $0.fingerprint.short == name }) else { fail("no paired box \(name)") }
        return b
    }
    guard let b = all.first else { fail("not paired; run: pierctl pair '<link>' --name <client-name>") }
    return b
}

func loadIdentity() -> PierIdentity {
    guard let id = try? IdentityStore.load(from: store) else { fail("no identity yet; run pair first") }
    return id
}

func prettyPrint(_ data: Data) {
    if let obj = try? JSONSerialization.jsonObject(with: data),
        let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    {
        print(String(decoding: out, as: UTF8.self))
    } else {
        print(String(decoding: data, as: UTF8.self))
    }
}

func readBody(_ arg: String?) throws -> Data? {
    guard let arg else { return nil }
    if arg == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
    if arg.hasPrefix("@") { return try Data(contentsOf: URL(fileURLWithPath: String(arg.dropFirst()))) }
    return Data(arg.utf8)
}

/// Issues one request, prints (and optionally saves) the pretty JSON; an API error prints `HTTP <status> <code>: <msg>` and exits 2.
/// The HTTP status is printed to stderr (200 vs 202 matters for worktree removal).
func run(_ client: BoxClient, _ method: BoxClient.Method, _ path: String, _ body: Data?, out: String?) async throws {
    do {
        let (status, data) = try await client.requestStatus(method, path: path, jsonBody: body)
        FileHandle.standardError.write(Data("HTTP \(status)\n".utf8))
        if let out {
            if let obj = try? JSONSerialization.jsonObject(with: data),
                let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            {
                try pretty.write(to: URL(fileURLWithPath: out))
            } else { try data.write(to: URL(fileURLWithPath: out)) }
        }
        prettyPrint(data)
    } catch PierError.api(let status, let message, let code) {
        FileHandle.standardError.write(Data("HTTP \(status) \(code ?? "-"): \(message)\n".utf8))
        exit(2)
    }
}

let usage = """
usage:
  pierctl pair '<pier://link>' [--name <client-name>]
  pierctl info
  pierctl get <path> [--box <name>] [--out FILE]
  pierctl post|put|patch|delete <path> [<json>|@file|-] [--box <name>] [--out FILE]
  pierctl send <session> <text> [--key] [--when now|idle] [--force]   (--key: single keystroke, enter=false)
  pierctl task <location> <name> --agent A [--prompt P] [--model M] [--effort E] [--base B]
  pierctl wait <session> [--for finished,waiting] [--timeout 90]
  pierctl selftest [--sandbox <session>]\n  pierctl events [--seconds N] [--since SEQ] [--raw] [--box <name>]
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail(usage) }
args.removeFirst()

do {
    switch cmd {
    case "pair":
        let name = option("--name", in: &args) ?? "pierctl-dev"
        guard let text = args.first else { fail(usage) }
        guard case .box(let link) = try PairingLink.parse(text) else { fail("join links are not supported by pierctl; pass a single-box link") }
        guard PierName.isValid(name) else { fail("invalid client name") }
        let identity = try IdentityStore.loadOrCreate(in: store)  // persisted before pairing
        print("client fingerprint: \(identity.fingerprint)")
        print("pairing with \(link.address) (box key \(link.fingerprint.short)...)")
        let rec = try await Pairing.pair(link: link, clientName: name, identity: identity, boxes: boxes)
        print("paired: box \"\(rec.name)\" at \(rec.address) fp \(rec.fingerprint)")
    case "info":
        let identity = loadIdentity()
        print("client fingerprint: \(identity.fingerprint)")
        for b in try boxes.list() { print("box \(b.name) \(b.address) \(b.fingerprint) paired \(b.pairedAt)") }
    case "get":
        let box = try selectBox(option("--box", in: &args))
        guard let path = args.first, path.hasPrefix("/") else { fail(usage) }
        let identity = loadIdentity()
        let client = BoxClient(box: box, identity: identity, origin: "pierctl")
        try await run(client, .get, path, nil, out: option("--out", in: &args))
    case "post", "put", "patch", "delete":
        let box = try selectBox(option("--box", in: &args))
        let out = option("--out", in: &args)
        guard let path = args.first, path.hasPrefix("/") else { fail(usage) }
        let body = try readBody(Array(args.dropFirst()).first)
        let m: BoxClient.Method = [ "post": .post, "put": .put, "patch": .patch, "delete": .delete ][cmd]!
        let client = BoxClient(box: box, identity: loadIdentity(), origin: "pierctl")
        try await run(client, m, path, body, out: out)
    case "send":
        let box = try selectBox(option("--box", in: &args))
        let when = option("--when", in: &args) ?? "now"
        let key = args.contains("--key"); args.removeAll { $0 == "--key" }
        let force = args.contains("--force"); args.removeAll { $0 == "--force" }
        guard args.count >= 2 else { fail(usage) }
        var req: [String: Any] = ["text": args[1], "when": when, "idem_key": "pierctl-\(UUID().uuidString.prefix(8))"]
        if key { req["enter"] = false }
        if force || key { req["force"] = true }
        let client = BoxClient(box: box, identity: loadIdentity(), origin: "pierctl")
        try await run(client, .post, "/v1/sessions/\(args[0])/send", try JSONSerialization.data(withJSONObject: req), out: option("--out", in: &args))
    case "task":
        let box = try selectBox(option("--box", in: &args))
        var req: [String: Any] = [:]
        for k in ["agent", "prompt", "model", "effort", "base", "branch", "title"] { if let v = option("--\(k)", in: &args) { req[k] = v } }
        let out = option("--out", in: &args)
        guard args.count >= 2 else { fail(usage) }
        req["location"] = args[0]; req["name"] = args[1]
        let client = BoxClient(box: box, identity: loadIdentity(), origin: "pierctl")
        try await run(client, .post, "/v1/tasks", try JSONSerialization.data(withJSONObject: req), out: out)
    case "wait":
        let box = try selectBox(option("--box", in: &args))
        let forStates = option("--for", in: &args) ?? "finished,waiting"
        let timeout = option("--timeout", in: &args) ?? "90"
        let out = option("--out", in: &args)
        guard let name = args.first else { fail(usage) }
        let client = BoxClient(box: box, identity: loadIdentity(), origin: "pierctl")
        try await run(client, .get, "/v1/sessions/\(name)/wait?for=\(forStates)&timeout=\(timeout)s", nil, out: out)
    case "selftest":
        // Typed-API check against the live box. Read-only unless --sandbox <session>: then mutating calls run
        // against that session and the `sandbox` location only.
        let box = try selectBox(option("--box", in: &args))
        let sandboxSession = option("--sandbox", in: &args)
        let client = BoxClient(box: box, identity: loadIdentity(), origin: "pierctl")
        let api = BoxAPI(client: client)
        var failures = 0
        func check(_ name: String, _ body: () async throws -> String) async {
            do { print("ok   \(name): \(try await body())") } catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        await check("info") { let i = try await api.info(); return "\(i.name) build \(i.build) caps \(i.capabilities.count) agents \(i.agents.map(\.id))" }
        await check("stats") { let s = try await api.stats(); return "\(s.hostname) cpus \(s.cpus) load \(s.load ?? [])" }
        await check("doctor") { "\(try await api.doctor().count) checks" }
        let locs = try await api.locations()
        print("ok   locations: \(locs.count)")
        await check("worktreeStatuses(sandbox)") { "\(try await api.worktreeStatuses(location: "sandbox").count)" }
        await check("branches(sandbox)") { "\(try await api.branches(location: "sandbox").branches?.count ?? 0)" }
        await check("installableAgents") { "\(try await api.installableAgents().map(\.id))" }
        let sessions = try await api.sessions()
        print("ok   sessions: \(sessions.map { "\($0.name)=\($0.agentState?.rawValue ?? "-")" })")
        await check("review") { "\(try await api.review(all: true).count) items" }
        for s in sessions where s.location?.hasPrefix("sandbox") == true {
            await check("screen(\(s.name))") { "\(try await api.screen(session: s.name, history: 50).count) chars" }
            await check("draft") { "\(try await api.draft(session: s.name).agent)" }
            await check("controls") { "\(try await api.controls(session: s.name).mode ?? "-")" }
            await check("turns") { "\(try await api.turns(session: s.name, limit: 20).count)" }
            await check("heldPrompts") { "\(try await api.heldPrompts(session: s.name).count)" }
            if s.isAgent {
                var store = TranscriptStore()
                await check("transcript") {
                    let p = try await api.transcript(session: s.name, since: 0, gen: nil)
                    store.apply(p)
                    let p2 = try await api.transcript(session: s.name, since: store.since, gen: store.gen)
                    store.apply(p2)
                    if let o = store.oldestOffset { let h = try await api.transcriptBefore(session: s.name, before: o, limit: 50); store.absorbHistory(h) }
                    return "\(p.source) \(store.items.count) items next \(store.next) signals \(store.signals?.mode ?? "-")"
                }
                if let tool = store.items.first(where: { $0.kind == "edit" })?.tool {
                    await check("toolDetail") { "\(try await api.toolDetail(session: s.name, id: tool).name)" }
                }
                let parts = (s.location ?? "").split(separator: "/").map(String.init)
                if parts.count == 2 { await check("touched") { "\(try await api.touched(location: parts[0], worktree: parts[1]).count)" } }
                await check("fileDiff") { "\(try await api.fileDiff(session: s.name, file: "calc.py").diff.count) bytes" }
            }
        }
        await check("events(3s)") {
            let n = Task { () -> Int in
                var c = 0
                for try await _ in api.events(since: 270) { c += 1 }
                return c
            }
            try await Task.sleep(for: .seconds(3))
            n.cancel()
            return "\((try? await n.value) ?? -1) events replayed"
        }
        if let ss = sandboxSession {
            await check("rename") { try await api.rename(session: ss, title: "selftest title").title ?? "-" }
            await check("send idle") { let r = try await api.send(session: ss, SendRequest(text: "/cost", when: .idle, idemKey: "selftest-\(UUID().uuidString.prefix(6))")); return "sent \(r.sent) queued \(r.queued ?? false) turn \(r.turn ?? "-")" }
            await check("uploadAttachment") { try await api.uploadAttachment(session: ss, name: "n.txt", data: Data("hello".utf8)).path }
            await check("exec") { let r = try await api.exec(location: "sandbox", command: "echo selftest", timeout: "20s"); return "\(r.exitCode) \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))" }
            await check("worktree create+remove") {
                _ = try await api.createWorktree(location: "sandbox", WorktreeRequest(name: "selftest-wt", base: "main"))
                return "\(try await api.removeWorktree(location: "sandbox", worktree: "selftest-wt", force: true, deleteBranch: true))"
            }
            await check("shell session + kill") {
                let sh = try await api.startSession(SessionRequest(location: "sandbox", name: "bk-selftest"))
                _ = try await api.send(session: sh.name, SendRequest(text: "echo hi"))
                try await api.keys(session: sh.name, [.enter])
                try await api.kill(session: sh.name)
                return sh.name
            }
            await check("error mapping") {
                do { _ = try await api.screen(session: "nope-nope", history: 0); return "no error?" } catch let e as BoxError { return "BoxError \(e.status) \(e.code ?? "-")" }
            }
            await check("interrupt") { "\(try await api.interrupt(session: ss))" }
        }
        print(failures == 0 ? "selftest passed" : "selftest: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    case "events":
        let box = try selectBox(option("--box", in: &args))
        let seconds = option("--seconds", in: &args).flatMap(Double.init) ?? 30
        let since = option("--since", in: &args).flatMap(Int64.init)
        let identity = loadIdentity()
        let client = BoxClient(box: box, identity: identity, origin: "pierctl")
        if args.contains("--raw") {
            // Raw NDJSON lines of one connection (for fixtures), `since` replay then live.
            let task = Task {
                var buf = Data()
                do {
                    for try await chunk in client.chunks(path: "/v1/events" + (since.map { "?since=\($0)" } ?? "")) {
                        buf.append(chunk)
                        while let nl = buf.firstIndex(of: 0x0a) {
                            let line = buf[buf.startIndex..<nl]; buf.removeSubrange(buf.startIndex...nl)
                            if !line.isEmpty { print(String(decoding: line, as: UTF8.self)) }
                        }
                    }
                } catch { FileHandle.standardError.write(Data("stream error: \(error)\n".utf8)) }
            }
            try? await Task.sleep(for: .seconds(seconds))
            task.cancel()
            exit(0)
        }
        let started = Date()
        let task = Task { () -> Int in
            var count = 0
            for try await ev in client.events(since: since) {
                count += 1
                let t = String(format: "%.1f", Date().timeIntervalSince(started))
                print("[+\(t)s] seq=\(ev.seq) type=\(ev.type) origin=\(ev.origin ?? "-") data=\(ev.data?.description.prefix(160) ?? "-")")
            }
            return count
        }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        let count = (try? await task.value) ?? 0
        print("done after \(Int(Date().timeIntervalSince(started)))s, \(count) events")
    default:
        fail(usage)
    }
} catch {
    fail("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
}
