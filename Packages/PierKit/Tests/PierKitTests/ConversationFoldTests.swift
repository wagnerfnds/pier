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

    @Test func editsInARowAreOneGroup() {
        // Three edits in a row read as one line ("Editou 3 arquivos"); an edit alone stays itself.
        let items = [
            it("user", 1, text: "do it"),
            it("edit", 2), it("edit", 3), it("edit", 4),
            it("text", 5, text: "Done."),
            it("user", 6, text: "one more"),
            it("edit", 7),
            it("text", 8, text: "Done again."),
        ]
        let b = ConversationFold.blocks(items, live: false)
        #expect(b.map(\.id) == ["cl@1.1", "edits-cl@2.1", "cl@5.1", "cl@6.1", "cl@7.1", "cl@8.1"])
        guard case .edits(_, let edits) = b[1] else { Issue.record("expected an edit group"); return }
        #expect(edits.map(\.id) == ["cl@2.1", "cl@3.1", "cl@4.1"])
    }

    @Test func anEditGroupCountsFilesNotEdits() {
        let files = ["a/marca.js", "a/roteiro.js", "a/marca.js", "", "b/cena.js", "a/roteiro.js"]
        #expect(ConversationFold.distinctFiles(files) == ["a/marca.js", "a/roteiro.js", "b/cena.js"])
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

    @Test func capturesAreOneGalleryAtTheTurnsEnd() {
        // Captured while working, before the answer: one gallery after it, each capture once; another turn has its own.
        func cap(_ n: Int, _ ids: [String]) -> TranscriptItem {
            TranscriptItem(kind: "capture", id: "cl@\(n).1", off: Int64(n), captures: ids.map { CaptureRef(id: $0) })
        }
        let items = [
            it("user", 1, text: "fix it and show me"),
            it("tools", 2, calls: 1), cap(3, ["aaaaaaaaaaaa"]),
            it("edit", 4),
            it("tools", 5, calls: 1), cap(6, ["bbbbbbbbbbbb", "aaaaaaaaaaaa"]),
            it("text", 7, text: "Fixed; before and after below."),
            it("user", 8, text: "and on a phone?"),
            it("tools", 9, calls: 1), cap(10, ["cccccccccccc"]),
        ]
        let b = ConversationFold.blocks(items, live: true)
        #expect(b.map(\.id) == ["cl@1.1", "fold-after-cl@1.1", "cl@4.1", "cl@7.1", "captures-cl@1.1", "cl@8.1", "fold-after-cl@8.1", "captures-cl@8.1"])
        guard case .captures(_, let first) = b[4], case .captures(_, let second) = b[7] else { Issue.record("expected galleries"); return }
        #expect(first.map(\.id) == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        #expect(second.map(\.id) == ["cccccccccccc"])
        // The captures' items never fall into the fold.
        guard case .fold(_, let steps, _) = b[1] else { return }
        #expect(!steps.contains { $0.type == .capture })
    }

    @Test func theLastTurnsCapturesForTheInbox() {
        func cap(_ n: Int, _ ids: [String]) -> TranscriptItem {
            TranscriptItem(kind: "capture", id: "cl@\(n).1", off: Int64(n), captures: ids.map { CaptureRef(id: $0) })
        }
        let items = [
            it("user", 1, text: "first"), cap(2, ["aaaaaaaaaaaa"]), it("text", 3, text: "done"),
            it("user", 4, text: "second"), cap(5, ["bbbbbbbbbbbb"]), it("edit", 6), cap(7, ["cccccccccccc", "bbbbbbbbbbbb"]), it("text", 8, text: "done again"),
        ]
        #expect(ConversationFold.lastTurnCaptures(items).map(\.id) == ["bbbbbbbbbbbb", "cccccccccccc"])
        #expect(ConversationFold.lastTurnCaptures(Array(items.prefix(4))).isEmpty, "a turn with none has none, whatever came before")
        #expect(ConversationFold.lastTurnCaptures([cap(1, ["dddddddddddd"])]).map(\.id) == ["dddddddddddd"], "a page that starts mid-turn")
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
