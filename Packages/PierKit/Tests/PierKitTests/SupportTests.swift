import Foundation
import Testing

@testable import PierKit

@Suite struct QuestionTests {
    private let q1 = Question(question: "Colour?", header: "Colour", options: [QuestionOption(label: "Red"), QuestionOption(label: "Blue")])
    private let q2 = Question(question: "Toppings?", multi: true, options: [QuestionOption(label: "Ham"), QuestionOption(label: "Egg")])

    @Test func classification() {
        #expect(Ask.classify(nil) == .question)
        #expect(Ask.classify(Ask()) == .question)
        #expect(Ask.classify(Ask(tool: "AskUserQuestion")) == .question)
        #expect(Ask.classify(Ask(tool: "request_user_input")) == .question)
        #expect(Ask.classify(Ask(tool: "ExitPlanMode")) == .question)
        #expect(Ask(tool: "ExitPlanMode").isPlanApproval)
        #expect(Ask.classify(Ask(tool: "Bash", input: "rm -rf build")) == .permission)
        #expect(Ask.classify(Ask(tool: "AskUserQuestionX")) == .permission)
        #expect(Ask(tool: "Bash", input: "rm -rf build").summary == "Bash  rm -rf build")
        #expect(Ask(tool: nil, input: "x").summary == "x")
    }

    @Test func sessionRouting() {
        var s = Session(name: "s", dir: "/w", agent: "claude", agentState: .waiting, ask: Ask(tool: "AskUserQuestion"))
        #expect(s.needsYouKind == .question && s.canUseAnswerEndpoint)
        s = Session(name: "s", dir: "/w", agent: "codex", agentState: .waiting, ask: Ask(tool: "request_user_input"))
        #expect(!s.canUseAnswerEndpoint)
        s = Session(name: "s", dir: "/w", agent: "claude", agentState: .running)
        #expect(s.needsYouKind == nil)
        s = Session(name: "s", dir: "/w", exited: true, agent: "claude", agentState: .waiting)
        #expect(s.needsYouKind == nil)
    }

    @Test func validation() {
        let qs = [q1, q2]
        #expect(QuestionHelpers.validate([.pick("Red"), .picks(["Ham", "Egg"])], for: qs) == nil)
        #expect(QuestionHelpers.validate([.other("purple")], for: qs) == .countMismatch(expected: 2, got: 1))
        #expect(QuestionHelpers.validate([.pick("Red"), QuestionAnswer()], for: qs) == .empty(question: 1))
        #expect(QuestionHelpers.validate([.picks(["Red", "Blue"]), .pick("Ham")], for: qs) == .tooManyPicks(question: 0))
        #expect(QuestionHelpers.validate([QuestionAnswer(picks: ["Red"], other: "x"), .pick("Ham")], for: qs) == .tooManyPicks(question: 0))
        #expect(QuestionHelpers.validate([.pick("Green"), .pick("Ham")], for: qs) == .unknownOption(question: 0, label: "Green"))
        #expect(QuestionHelpers.validate([.other("a\nb"), .pick("Ham")], for: qs) == .otherNotSingleLine(question: 0))
        // free text alone is fine, and counts as the pick for a single-choice question
        #expect(QuestionHelpers.validate([.other("purple"), .picks(["Ham"])], for: qs) == nil)
        #expect(QuestionHelpers.summary(QuestionAnswer(picks: ["Ham", "Egg"], other: "salt")) == "Ham, Egg, salt")
    }

    @Test func menuKeys() {
        #expect(QuestionHelpers.menuKey(forPick: "Blue", in: q1) == "2")
        #expect(QuestionHelpers.menuKey(forPick: "Nope", in: q1) == nil)
    }
}

@Suite struct NotificationTests {
    private let locs = [Location(name: "shop", path: "/code/shop", repo: true, worktrees: [
        Worktree(name: "shop", path: "/code/shop", main: true), Worktree(name: "fix-login", path: "/code/shop-fix-login"),
    ])]
    private func sess(_ name: String, dir: String, agent: String? = "claude", title: String? = nil, ask: Ask? = nil, state: AgentState? = .waiting) -> Session {
        Session(name: name, dir: dir, agent: agent, agentState: state, title: title, ask: ask)
    }
    private func event(_ type: String, _ data: JSON, origin: String = "claude", time: Date = Date()) -> PierEvent {
        PierEvent(seq: 10, type: type, time: time, box: "devbox", origin: origin, data: data)
    }

    @Test func waitingForAPermission() throws {
        let s = sess("shop-fix-claude-1", dir: "/code/shop-fix-login", title: "Fix the login", ask: Ask(tool: "Bash", input: "rm -rf build"))
        let e = event("agent.waiting", ["agent": .string("claude"), "path": .string("/code/shop-fix-login"), "reason": .string("permission"), "session": .string(s.name)])
        let n = try #require(NotificationText.make(for: e, box: "devbox", sessions: [s], locations: locs))
        #expect(n.kind == .waiting && n.title == "✋ Needs you · Fix the login")
        #expect(n.body == "Claude Code · shop / fix-login · devbox\nBash  rm -rf build")
        #expect(n.key == "waiting|devbox|shop-fix-claude-1" && n.session == s.name && n.offersActions)
    }

    @Test func waitingMatchedByPathAndUntitled() throws {
        let s = sess("a", dir: "/code/shop")
        let e = event("agent.waiting", ["agent": .string("claude"), "path": .string("/code/shop")])
        let n = try #require(NotificationText.make(for: e, box: "devbox", sessions: [s], locations: locs))
        #expect(n.title == "✋ Needs you · Claude Code" && n.session == "a" && n.body == "shop · devbox")
        // two agents in one folder and no session named: no guess
        let t = sess("b", dir: "/code/shop")
        #expect(NotificationText.session(for: e, in: [s, t]) == nil)
        let n2 = try #require(NotificationText.make(for: e, box: "devbox", sessions: [s, t], locations: locs))
        #expect(n2.session == nil && n2.title == "✋ Needs you · Claude Code" && n2.key == "waiting|devbox|/code/shop")
        // a question is not offered permission buttons
        let q = sess("q", dir: "/code/shop", ask: Ask(tool: "AskUserQuestion"))
        let n3 = try #require(NotificationText.make(for: event("agent.waiting", ["path": .string("/code/shop"), "session": .string("q")]), box: "devbox", sessions: [q], locations: locs))
        #expect(!n3.offersActions)
    }

    @Test func aChatIsPlacedAsAChatNotByItsFolder() throws {
        let c = Session(name: "chat-claude-1", dir: "/home/u/pier/chats/chat-claude-1", agent: "claude", agentState: .waiting, title: "Plan the trip", chat: true)
        let e = event("agent.waiting", ["agent": .string("claude"), "path": .string(c.dir), "session": .string(c.name)])
        let n = try #require(NotificationText.make(for: e, box: "devbox", sessions: [c], locations: locs))
        #expect(n.title == "✋ Needs you · Plan the trip" && n.body == "Claude Code · Chat · devbox" && n.session == c.name)
    }

    @Test func finishedDoneFailedAndSkips() throws {
        let s = sess("a", dir: "/code/shop", state: .finished)
        let base: JSON = ["agent": .string("claude"), "path": .string("/code/shop"), "session": .string("a")]
        #expect(try #require(NotificationText.make(for: event("agent.finished", base), box: "b", sessions: [s], locations: locs)).title == "✅ Done · Claude Code")
        var failed = base; failed["status"] = .string("error")
        #expect(try #require(NotificationText.make(for: event("agent.finished", failed), box: "b", sessions: [s], locations: locs)).title == "⚠️ Failed · Claude Code")
        var interrupted = base; interrupted["source"] = .string("interrupt")
        #expect(NotificationText.make(for: event("agent.finished", interrupted), box: "b", sessions: [s], locations: locs) == nil)
        // old spooled events are dropped, fresh ones are kept
        var spooled = base; spooled["spooled"] = .bool(true)
        #expect(NotificationText.make(for: event("agent.finished", spooled, time: Date().addingTimeInterval(-3600)), box: "b", sessions: [s], locations: locs) == nil)
        #expect(NotificationText.make(for: event("agent.finished", spooled, time: Date().addingTimeInterval(-30)), box: "b", sessions: [s], locations: locs) != nil)
        // chatter
        for t in ["transcript.changed", "session.sent", "agent.started", "exec.finished", "agent.ready"] {
            #expect(NotificationText.make(for: event(t, base), box: "b", sessions: [s], locations: locs) == nil)
        }
    }

    @Test func otherCategories() throws {
        var setup = event("worktree.setup.failed", ["name": .string("fix"), "path": .string("/p")])
        setup = PierEvent(seq: 1, type: setup.type, time: setup.time, box: "b", origin: nil, error: "npm ci failed", data: setup.data)
        let n = try #require(NotificationText.make(for: setup, box: "b", sessions: [], locations: []))
        #expect(n.title == "Setup failed for fix" && n.body == "npm ci failed")
        let note = try #require(NotificationText.make(for: event("notify", ["title": .string("Deploy"), "body": .string("done")]), box: "b", sessions: [], locations: []))
        #expect(note.title == "Deploy" && note.body == "done")
        #expect(NotificationText.make(for: event("notify", [:]), box: "b", sessions: [], locations: []) == nil)
    }

    @Test func realEvents() throws {
        let sessions: [Session] = try Fixture.decode("sessions_waiting.json")
        let all = try Fixture.text("events.ndjson").split(separator: "\n").map { try JSONDecoder.pier.decode(PierEvent.self, from: Data($0.utf8)) }
        let waiting = try #require(all.first { $0.type == "agent.waiting" && $0.str("reason") == "permission" })
        let n = try #require(NotificationText.make(for: waiting, box: "devbox", sessions: sessions, locations: [], now: waiting.time))
        #expect(n.session == "sandbox-subtract-claude-6s1" && n.title.hasPrefix("✋ Needs you"))
        #expect(all.contains { NotificationText.make(for: $0, box: "devbox", sessions: sessions, locations: [], now: $0.time)?.kind == .finished })
    }

    @Test func displayNames() {
        #expect(DisplayNames.agentLabel("claude") == "Claude Code")
        #expect(DisplayNames.agentLabel("cursor") == "Cursor Agent")
        #expect(DisplayNames.agentLabel("aider") == "Aider")
        let a = Session(name: "a", dir: "/w", created: Date(timeIntervalSince1970: 1), agent: "claude")
        let b = Session(name: "b", dir: "/w", created: Date(timeIntervalSince1970: 2), agent: "claude")
        #expect(DisplayNames.sessionName(a, among: [a, b]) == "Claude Code")
        #expect(DisplayNames.sessionName(b, among: [a, b]) == "Claude Code 2")
        #expect(DisplayNames.sessionName(Session(name: "x", dir: "/w", command: "/usr/bin/codex 'hi'")) == "Codex")
        #expect(DisplayNames.sessionName(Session(name: "t", dir: "/w", service: "web")) == "web")
        #expect(DisplayNames.sessionName(Session(name: "sh", dir: "/w")) == "Shell")
        #expect(DisplayNames.sessionAgent(Session(name: "x", dir: "/w", agent: "claude", title: "Work")) == "Claude Code")
    }
}
