import Foundation
import Testing

@testable import PierKit

private func json(_ s: String) -> Data { Data(s.utf8) }

private func api(_ handler: @escaping @Sendable (BoxClient.Method, String, Data?) throws -> (Int, Data)) -> (BoxAPI, MockTransport) {
    let t = MockTransport(handler: handler)
    return (BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0)), t)
}

@Suite struct BoxAPITests {
    @Test func pathsQueriesAndEscaping() async throws {
        let (a, t) = api { _, path, _ in
            if path.contains("/screen") { return (200, json(#"{"screen":"hi\n"}"#)) }
            if path.hasPrefix("/v1/review") { return (200, json("[]")) }
            if path.hasSuffix("/branches") { return (200, json("{}")) }
            if path.hasSuffix("/touched") { return (200, json(#"{"files":[]}"#)) }
            if path.contains("/transcript") { return (200, json(#"{"source":"none","items":null,"next":0}"#)) }
            if path.contains("/queue/") { return (200, json(#"{"sent":true,"at":"2026-10-07T21:00:00Z"}"#)) }
            return (200, json("[]"))
        }
        _ = try await a.worktreeStatuses(location: "my repo&x")
        _ = try await a.worktreeStatuses(location: nil)
        #expect(try await a.screen(session: "s-1", history: 0) == "hi\n")
        _ = try await a.screen(session: "s-1", history: 200)
        _ = try await a.review(all: false)
        _ = try await a.review(all: true)
        _ = try await a.touched(location: "shop", worktree: "fix/login")
        _ = try await a.transcript(session: "s", since: 12, gen: "1760.0")
        _ = try await a.transcript(session: "s", since: 0, gen: nil)
        _ = try await a.transcriptBefore(session: "s", before: 221799, limit: 1000)
        _ = try await a.sendHeldNow(session: "s", turn: "s#5", force: false)
        _ = try await a.turns(session: "s", limit: 9999)
        _ = try await a.branches(location: "a/b")
        #expect(t.requests.map(\.path) == [
            "/v1/worktrees?location=my%20repo%26x",
            "/v1/worktrees",
            "/v1/sessions/s-1/screen",
            "/v1/sessions/s-1/screen?history=200",
            "/v1/review",
            "/v1/review?all=1",
            "/v1/locations/shop/worktrees/fix%2Flogin/touched",
            "/v1/sessions/s/transcript?since=12&gen=1760.0",
            "/v1/sessions/s/transcript?since=0",
            "/v1/sessions/s/transcript?before=221799&limit=300",
            "/v1/sessions/s/queue/s%235/send",
            "/v1/sessions/s/turns?limit=500",
            "/v1/locations/a%2Fb/branches",
        ])
    }

    @Test func requestBodies() async throws {
        let (a, t) = api { _, path, _ in
            if path.hasSuffix("/answer") { return (200, json(#"{"answered":["Blue"]}"#)) }
            if path.hasSuffix("/mode") { return (200, json(#"{"mode":"plan"}"#)) }
            if path.hasSuffix("/attachments") { return (200, json(#"{"path":"/p/x.txt","name":"x.txt","type":"text/plain","size":5}"#)) }
            if path.hasSuffix("/interrupt") { return (200, json(#"{"sent":true,"stopped":true}"#)) }
            if path.hasSuffix("/send") { return (200, json(#"{"sent":true,"at":"2026-10-07T21:00:00.5Z","turn":"s#2"}"#)) }
            return (200, json("{}"))
        }
        let r = try await a.send(session: "s", SendRequest(text: "go", when: .idle, idemKey: "k1"))
        #expect(r.turn == "s#2" && r.at == RFC3339.parse("2026-10-07T21:00:00.5Z"))
        try await a.keys(session: "s", [.escape, .k1, .btab])
        #expect(try await a.answerQuestions(session: "s", tool: "toolu_1", answers: [.pick("Blue"), .other("x")]) == ["Blue"])
        #expect(try await a.setMode(session: "s", mode: "plan") == "plan")
        let att = try await a.uploadAttachment(session: "s", name: "x.txt", data: Data("hello".utf8))
        #expect(att.size == 5)
        #expect(try await a.interrupt(session: "s").stopped)
        try await a.kill(session: "s")
        try await a.cancelHeld(session: "s", turn: "s#3")
        _ = try await a.exec(location: "shop/fix", command: "git status", timeout: "30s")
        let reqs = t.requests
        #expect(reqs[0] == .init(method: "POST", path: "/v1/sessions/s/send", body: #"{"enter":true,"idem_key":"k1","text":"go","when":"idle"}"#))
        #expect(reqs[1].body == #"{"keys":["escape","1","btab"]}"#)
        #expect(reqs[2].path == "/v1/sessions/s/answer" && reqs[2].body == #"{"answers":[{"picks":["Blue"]},{"other":"x"}],"tool":"toolu_1"}"#)
        #expect(reqs[3].body == #"{"mode":"plan"}"#)
        #expect(reqs[4].body == #"{"data":"aGVsbG8=","name":"x.txt"}"#)
        #expect(reqs[5] == .init(method: "POST", path: "/v1/sessions/s/interrupt", body: nil))
        #expect(reqs[6] == .init(method: "DELETE", path: "/v1/sessions/s", body: nil))
        #expect(reqs[7] == .init(method: "DELETE", path: "/v1/sessions/s/queue/s%233", body: nil))
        #expect(reqs[8].body == #"{"command":"git status","location":"shop/fix","timeout":"30s"}"#)
    }

    @Test func removeWorktreeHandles200And202() async throws {
        let (a, t) = api { _, path, _ in
            path.contains("/archive-me") ? (202, json(#"{"removing":"archive-me","archive":"./archive.sh"}"#)) : (200, json(#"{"removed":"plain"}"#))
        }
        #expect(try await a.removeWorktree(location: "shop", worktree: "plain", force: true, deleteBranch: true) == .removed("plain"))
        #expect(try await a.removeWorktree(location: "shop", worktree: "archive-me", force: false, deleteBranch: false) == .archiving(script: "./archive.sh"))
        #expect(t.requests.map(\.path) == ["/v1/locations/shop/worktrees/plain?force=1&delete_branch=1", "/v1/locations/shop/worktrees/archive-me"])
        #expect(t.requests.allSatisfy { $0.method == "DELETE" })
    }

    @Test func waitForSessionBuildsTheLongPoll() async throws {
        let (a, t) = api { _, _, _ in (200, json(#"{"state":"finished","timed_out":false,"turn":"s#1"}"#)) }
        let at = RFC3339.parse("2026-10-07T21:33:49.197336491Z")!
        let r = try await a.waitForSession("s", states: [.finished, .waiting], after: at, timeout: .seconds(30))
        #expect(r.state == "finished" && r.turn == "s#1")
        let path = t.requests[0].path
        #expect(path.hasPrefix("/v1/sessions/s/wait?for=finished,waiting".replacingOccurrences(of: ",", with: "%2C").replacingOccurrences(of: "%2C", with: ",")))
        #expect(path.contains("&after=2026-10-07T21%3A33%3A49.1973"))
        #expect(path.hasSuffix("Z&timeout=30s") || path.hasSuffix("&timeout=30s"))
        // The box's wait stays under the transport's 45 s GET limit.
        _ = try await a.waitForSession("s", states: [], after: nil, timeout: .seconds(150))
        #expect(t.requests[1].path == "/v1/sessions/s/wait?timeout=\(BoxAPI.maxWaitSeconds)s")
    }

    @Test func boxErrorsFromJSONAndPlainText() async throws {
        let (a, _) = api { _, path, _ in
            switch path {
            case "/v1/sessions": throw PierError.api(status: 403, message: "a \"before:worktree.create\" hook stopped worktree.create: work on a branch, not main", code: "refused")
            case "/v1/info": throw PierError.api(status: 400, message: "invalid request body", code: nil)
            case "/v1/stats": throw PierError.unauthorized
            default: throw PierError.transport("down")
            }
        }
        do { _ = try await a.sessions(); Issue.record("no throw") } catch let e as BoxError {
            #expect(e.status == 403 && e.kind == .refused && e.error.contains("work on a branch"))
            #expect(e.errorDescription == e.error)
        }
        do { _ = try await a.info(); Issue.record("no throw") } catch let e as BoxError { #expect(e.status == 400 && e.kind == nil) }
        // revoked / transport stay PierError
        do { _ = try await a.stats(); Issue.record("no throw") } catch PierError.unauthorized {}
        do { _ = try await a.doctor(); Issue.record("no throw") } catch PierError.transport {}
    }

    @Test func boxErrorParsing() {
        let json = BoxError.parse(status: 409, body: Data(#"{"error":"agent is waiting","code":"agent_waiting"}"#.utf8))
        #expect(json.status == 409 && json.kind == .agentWaiting && json.error == "agent is waiting")
        let plain = BoxError.parse(status: 502, body: Data("bad gateway\n".utf8))
        #expect(plain.error == "bad gateway" && plain.code == nil)
        let empty = BoxError.parse(status: 500, body: Data())
        #expect(empty.error == "HTTP 500")
        let unknown = BoxError.parse(status: 400, body: Data(#"{"error":"x","code":"new_code"}"#.utf8))
        #expect(unknown.kind == nil && unknown.code == "new_code")
    }

    @Test func decodeFailureIsADecodingError() async {
        let (a, _) = api { _, _, _ in (200, json(#"{"not":"a list"}"#)) }
        do { _ = try await a.sessions(); Issue.record("no throw") } catch PierError.decoding {} catch { Issue.record("wrong error \(error)") }
    }

    @Test func resetResetsTransportAndStreams() async throws {
        let (a, t) = api { _, _, _ in (200, json("{}")) }
        await a.reset()
        #expect(t.resets == 1)
    }

    @Test func eventsThroughTheClient() async throws {
        let t = MockTransport(connections: [.init(chunks: [line(1), line(2)], end: .hang)])
        let a = BoxAPI(transport: t)
        var seen: [Int64] = []
        for try await e in a.events(since: 0) {
            seen.append(e.seq ?? 0)
            if seen.count == 2 { break }
        }
        #expect(seen == [1, 2] && t.streamPaths == ["/v1/events?since=0"])
    }

    @Test func defaultsOnTheProtocol() async throws {
        let (a, t) = api { _, _, _ in (200, json(#"{"sent":true,"at":"2026-10-07T21:00:00Z"}"#)) }
        let client: any PierBoxClient = a
        _ = try await client.sendKey(session: "s", "2")
        #expect(t.requests[0].body == #"{"enter":false,"force":true,"text":"2","when":"now"}"#)
    }
}
