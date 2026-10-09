import Foundation
import Testing

@testable import PierKit

@Suite struct TolerantDecodingTests {
    @Test func unknownAgentStateAndExtraFields() throws {
        let s: [Session] = try Fixture.decode("synthetic/sessions_unknown_state.json")
        #expect(s[0].agentState == .unknown("meditating"))
        #expect(s[0].agentState?.rawValue == "meditating")
        #expect(s[0].needsYou == false)
        #expect(s[1].agentState == nil && s[1].exited)
        // numeric offset + fractional seconds
        #expect(abs(s[0].created.timeIntervalSince1970 - 1791407400.5 - 3600 * 0) < 1e6)
        #expect(s[1].created == RFC3339.parse("2026-10-07T19:00:00Z"))
    }

    @Test func unknownTranscriptKindsAndNulls() throws {
        let n: TranscriptPage = try Fixture.decode("synthetic/transcript_kinds.json")
        #expect(n.items.isEmpty && n.crew == nil)
        #expect(n.signals?.todos?.count == 2 && n.signals?.todos?[0].active == "Writing tests")
        #expect(n.signals?.background?.first?.state == "running")
        #expect(n.signals?.retrying?.attempt == 2)
        #expect(n.artifacts?.first?.updated == true)

        let p: TranscriptPage = try Fixture.decode("synthetic/transcript_items.json")
        #expect(p.items.map(\.type) == [.user, .tools, .notice, .command, .crew, .artifact, .report, .unknown("hologram")])
        #expect(p.items[7].kind == "hologram" && p.items[7].text == "from the future")
        #expect(p.items[2].resets == 1760003600000 && p.items[2].level == "warning")
        #expect(p.items[6].report?.files == 3 && p.items[6].report?.status == "finished")
        #expect(p.items[1].done == false)
    }

    @Test func eventsWithJunk() throws {
        var events: [PierEvent] = []
        for l in try Fixture.text("synthetic/events_unknown.ndjson").split(separator: "\n") {
            if let e = try? JSONDecoder.pier.decode(PierEvent.self, from: Data(l.utf8)) { events.append(e) }
        }
        #expect(events.map(\.type) == ["future.event", "agent.waiting", "seqless"])
        #expect(events[0].data?["nested"]?["a"] != nil)
        #expect(events[1].str("reason") == "permission")
        #expect(events[2].seq == nil && events[2].id == 0)
    }

    @Test func missingOptionalsAndNullLists() throws {
        let json = #"{"name":"x","os":"linux","tools":null,"agents":null,"capabilities":["a"]}"#
        let info = try JSONDecoder.pier.decode(BoxInfo.self, from: Data(json.utf8))
        #expect(info.tools.isEmpty && info.agents.isEmpty && info.adapters == nil && info.has("a"))
        let b = try JSONDecoder.pier.decode(BranchList.self, from: Data(#"{"default":"main","branches":null}"#.utf8))
        #expect(b.default == "main" && b.branches == nil)
        let item = try JSONDecoder.pier.decode(
            ReviewItem.self, from: Data(#"{"location":"l","worktree":"w","path":"/p","files":null,"commits":null,"committed":null}"#.utf8))
        #expect(item.files.isEmpty && item.commits.isEmpty && item.committed.isEmpty && item.ahead == 0)
    }

    @Test func zeroTimeFromGoStaysDecodable() throws {
        let json = #"{"hostname":"h","agents":[{"tool":"codex","pid":1,"state":"finished","since":"0001-01-01T00:00:00Z"}]}"#
        let s = try JSONDecoder.pier.decode(BoxStats.self, from: Data(json.utf8))
        #expect(s.agents.first?.since != nil)
    }

    @Test func requestBodiesUseWireNames() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var t = TaskRequest(location: "shop", name: "fix", agent: "claude", prompt: "hi")
        t.fromSession = "s1"
        t.effort = "high"
        #expect(String(decoding: try enc.encode(t), as: UTF8.self) == #"{"agent":"claude","effort":"high","from_session":"s1","location":"shop","name":"fix","prompt":"hi"}"#)
        let s = SendRequest(text: "go", when: .idle, idemKey: "k")
        #expect(String(decoding: try enc.encode(s), as: UTF8.self) == #"{"enter":true,"idem_key":"k","text":"go","when":"idle"}"#)
        #expect(String(decoding: try enc.encode(SendRequest.key("1")), as: UTF8.self) == #"{"enter":false,"force":true,"text":"1","when":"now"}"#)
        #expect(String(decoding: try enc.encode([QuestionAnswer.pick("A"), .other("mine")]), as: UTF8.self) == #"[{"picks":["A"]},{"other":"mine"}]"#)
    }

    /// A chat (POST /v1/sessions with chat: true) names no location; the box lists it with `chat` and none either.
    @Test func chatsGoOutWithNoLocationAndComeBackFlagged() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let req = SessionRequest(agent: "codex", prompt: "plan a trip", effort: "high", chat: true)
        #expect(String(decoding: try enc.encode(req), as: UTF8.self) == #"{"agent":"codex","chat":true,"effort":"high","prompt":"plan a trip"}"#)
        let json = #"{"name":"chat-codex-1x2y","dir":"/home/u/pier/chats/chat-codex-1x2y","created":"2026-10-09T10:00:00Z","agent":"codex","agent_state":"running","chat":true}"#
        let s = try JSONDecoder.pier.decode(Session.self, from: Data(json.utf8))
        #expect(s.chat && s.location == nil && s.isAgent)
        let old = try JSONDecoder.pier.decode(Session.self, from: Data(#"{"name":"a","location":"shop"}"#.utf8))
        #expect(!old.chat)
    }
}

@Suite struct RFC3339Tests {
    @Test func parsesGoShapes() {
        let base = 1791408837.0  // 2026-10-07T21:33:57Z
        #expect(RFC3339.parse("2026-10-07T21:33:57Z")?.timeIntervalSince1970 == base)
        #expect(RFC3339.parse("2026-10-07T21:33:57.5Z")?.timeIntervalSince1970 == base + 0.5)
        let nano = RFC3339.parse("2026-10-07T21:33:57.260855049Z")!.timeIntervalSince1970
        #expect(abs(nano - (base + 0.260855049)) < 1e-6)
        #expect(RFC3339.parse("2026-10-07T21:33:57.53987405Z") != nil)
        #expect(RFC3339.parse("2026-10-07T18:33:57-03:00")?.timeIntervalSince1970 == base)
        #expect(RFC3339.parse("2026-10-07T23:33:57+02:00")?.timeIntervalSince1970 == base)
        #expect(RFC3339.parse("0001-01-01T00:00:00Z") != nil)
        #expect(RFC3339.parse("2024-02-29T12:00:00Z")?.timeIntervalSince1970 == 1709208000)
    }

    @Test func rejectsGarbage() {
        for s in ["", "yesterday", "2026-13-01T00:00:00Z", "2026-10-07 21:33:57", "2026-10-07T21:33:57", "2026-10-07T21:33:57.Z", "2026-10-07T21:33:57+0200"] {
            #expect(RFC3339.parse(s) == nil, "\(s)")
        }
    }

    @Test func formatRoundTrips() {
        let s = "2026-10-07T21:33:49.197336491Z"
        let d = RFC3339.parse(s)!
        let back = RFC3339.format(d)
        // a Double holds ~240 ns at this magnitude; the first 6 digits are exact
        #expect(back.hasPrefix("2026-10-07T21:33:49.1973"))
        #expect(abs(RFC3339.parse(back)!.timeIntervalSince(d)) < 1e-6)
        #expect(RFC3339.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000000000Z")
        #expect(RFC3339.format(Date(timeIntervalSince1970: 1709208000.5)) == "2024-02-29T12:00:00.500000000Z")
    }
}
