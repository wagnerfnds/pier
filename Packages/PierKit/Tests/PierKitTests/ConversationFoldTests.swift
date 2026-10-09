import Foundation
import Testing

@testable import PierKit

private func it(_ kind: String, _ n: Int, text: String? = nil, verb: String? = nil, calls: Int = 0, names: [String]? = nil) -> TranscriptItem {
    let items: [TranscriptItem.Call]? = calls > 0 ? (0..<calls).map { TranscriptItem.Call(verb: verb ?? "Run", target: "t\($0)", id: "c\(n)-\($0)") } : nil
    return TranscriptItem(kind: kind, id: "cl@\(n).1", off: Int64(n), text: text, verb: verb, items: items, done: true, names: names)
}

@Suite struct ConversationFoldTests {
    @Test func promptThenStepsThenAnswer() {
        let items = [
            it("user", 1, text: "do it"),
            it("tools", 2, verb: "Read", calls: 3),
            it("text", 3, text: "I'll try python3."),
            it("tools", 4, verb: "Run", calls: 1),
            it("edit", 5),
            it("text", 6, text: "Done: added mul()."),
        ]
        let b = ConversationFold.blocks(items, live: false)
        #expect(b.map(\.id) == ["cl@1.1", "fold-after-cl@1.1", "cl@5.1", "cl@6.1"])
        guard case .fold(_, let steps, let live) = b[1] else { Issue.record("expected a fold"); return }
        #expect(steps.map(\.id) == ["cl@2.1", "cl@3.1", "cl@4.1"])
        #expect(live == false)
        let w = ConversationFold.work(in: steps)
        #expect(w.read == 3 && w.run == 1 && w.notes == 1 && w.search == 0)
    }

    @Test func liveOnlyOnTheLastTurn() {
        let items = [it("user", 1, text: "a"), it("tools", 2, calls: 1), it("text", 3, text: "x"), it("user", 4, text: "b"), it("tools", 5, calls: 1)]
        let b = ConversationFold.blocks(items, live: true)
        var lives: [Bool] = []
        for case .fold(_, _, let l) in b { lives.append(l) }
        #expect(lives == [false, true])
    }

    @Test func longestTrailingTextIsTheAnswer() {
        // "now I'll write it up" before the real answer folds; a short note after a long answer stays visible.
        let items = [it("user", 1, text: "q"), it("text", 2, text: "short"), it("text", 3, text: "a much longer answer with details"), it("text", 4, text: "ps")]
        let b = ConversationFold.blocks(items, live: false)
        #expect(b.map(\.id) == ["cl@1.1", "fold-after-cl@1.1", "cl@3.1", "cl@4.1"])
    }

    @Test func questionsNoticesArtifactsStayVisible() {
        let items = [it("user", 1, text: "q"), it("tools", 2, calls: 2), it("question", 3), it("notice", 4), it("artifact", 5), it("crew", 6, names: ["a", "b"])]
        let b = ConversationFold.blocks(items, live: false)
        #expect(b.map(\.id) == ["cl@1.1", "fold-after-cl@1.1", "cl@3.1", "cl@4.1", "cl@5.1"])
        guard case .fold(_, let steps, _) = b[1] else { return }
        #expect(ConversationFold.work(in: steps).helpers == 2)
    }

    @Test func commandsAndReportsStartTurns() {
        let items = [it("command", 1, text: "/cost"), it("text", 2, text: "x"), it("report", 3), it("tools", 4, calls: 1)]
        let b = ConversationFold.blocks(items, live: false)
        #expect(b.map(\.id) == ["cl@1.1", "cl@2.1", "cl@3.1", "fold-after-cl@3.1"])
    }

    @Test func foldKeepsItsIdWhileTheAgentWorks() {
        // The live answer is demoted into the fold when the next step arrives: the fold must stay the same row.
        let a = ConversationFold.blocks([it("user", 1, text: "q"), it("text", 2, text: "looking"), it("tools", 3, calls: 1)], live: true)
        let b = ConversationFold.blocks([it("user", 1, text: "q"), it("text", 2, text: "looking"), it("tools", 3, calls: 1), it("text", 4, text: "found it")], live: true)
        let foldID = { (bs: [ConversationBlock]) in bs.first { if case .fold = $0 { true } else { false } }?.id }
        #expect(foldID(a) == "fold-after-cl@1.1")
        #expect(foldID(a) == foldID(b))
    }

    @Test func emptyAndStepsOnly() {
        #expect(ConversationFold.blocks([], live: true).isEmpty)
        let b = ConversationFold.blocks([it("tools", 1, calls: 1)], live: true)
        #expect(b.count == 1)
        if case .fold(_, _, let live) = b[0] { #expect(live) } else { Issue.record("expected a fold") }
        #expect(ConversationFold.work(in: []).isEmpty)
    }
}
