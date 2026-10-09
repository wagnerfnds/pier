import Foundation
import Testing

@testable import PierKit

private func item(_ kind: String, _ off: Int64, seq: Int = 1, text: String? = nil, done: Bool? = nil) -> TranscriptItem {
    TranscriptItem(kind: kind, id: "cl@\(off).\(seq)", off: off, text: text, done: done)
}

private func page(
    _ items: [TranscriptItem], next: Int? = nil, gen: String? = "g1", file: String? = "f1", reset: Bool? = nil, start: Int64? = nil,
    truncated: Bool? = nil, more: Bool? = nil
) -> TranscriptPage {
    TranscriptPage(source: "claude", items: items, next: next ?? items.count, truncated: truncated, more: more, gen: gen, reset: reset, start: start, file: file)
}

@Suite struct TranscriptStoreTests {
    @Test func openThenIncrementalUpsert() {
        var s = TranscriptStore()
        s.apply(page([item("user", 10), item("tools", 20, done: false)], next: 2))
        #expect(s.items.count == 2 && s.next == 2 && s.gen == "g1" && s.file == "f1")
        // the open tool group is re-sent (done now) plus a new item: upsert, never duplicate
        s.apply(page([item("tools", 20, done: true), item("text", 30, text: "hi")], next: 3))
        #expect(s.items.map(\.id) == ["cl@10.1", "cl@20.1", "cl@30.1"])
        #expect(s.items[1].done == true)
        #expect(s.next == 3)
    }

    @Test func emptyPollKeepsCursor() {
        var s = TranscriptStore()
        s.apply(page([item("user", 10)], next: 1))
        s.apply(TranscriptPage(source: "claude", items: [], next: 1, gen: "g1", file: "f1"))
        #expect(s.items.count == 1 && s.next == 1)
    }

    @Test func resetKeepsOlderAndReplacesTheRest() {
        var s = TranscriptStore()
        s.apply(page([item("user", 10), item("text", 20), item("text", 30)], next: 3))
        // older history scrolled in before: offsets 1 and 5
        s.apply(page([], next: 3))
        s.prepend([item("user", 1), item("text", 5)])
        #expect(s.items.map { $0.off } == [1, 5, 10, 20, 30])
        // box re-read the record: whole window from 20, items are named by offset as before
        s.apply(page([item("text", 20, text: "edited"), item("text", 30), item("text", 40)], next: 3, gen: "g2", reset: true, start: 20))
        #expect(s.items.map { $0.off } == [1, 5, 10, 20, 30, 40])
        #expect(s.items[3].text == "edited")
        #expect(s.gen == "g2" && s.next == 3)
        // older items 1,5,10 held: the window leaves a hole to fill before offset 20 (here nothing is missing: ends at first page)
        #expect(s.gapBefore == 20)
    }

    @Test func gapFillWalksBackUntilItMeetsWhatIsHeld() {
        var s = TranscriptStore()
        s.apply(page([item("user", 1), item("text", 5)], next: 2))
        // reset whose window starts far later
        s.apply(page([item("text", 100), item("text", 110)], next: 2, gen: "g2", reset: true, start: 100))
        #expect(s.gapBefore == 100)
        #expect(s.items.map { $0.off } == [1, 5, 100, 110])
        // first page back: 60..90 (more earlier)
        var next = s.absorbHistory(page([item("text", 60), item("text", 90)], more: true))
        #expect(next == 60)
        #expect(s.items.map { $0.off } == [1, 5, 60, 90, 100, 110])
        // second page reaches the held item at 5
        next = s.absorbHistory(page([item("text", 5), item("text", 30)], more: true))
        #expect(next == nil && s.gapBefore == nil)
        #expect(s.items.map { $0.off } == [1, 5, 30, 60, 90, 100, 110])
        #expect(s.items.filter { $0.off == 5 }.count == 1)
    }

    @Test func gapFillIsCapped() {
        var s = TranscriptStore()
        s.apply(page([item("user", 1)], next: 1))
        s.apply(page([item("text", 10_000)], next: 1, gen: "g2", reset: true, start: 10_000))
        var before: Int64? = s.gapBefore
        var off: Int64 = 9_000
        var pages = 0
        while before != nil {
            before = s.absorbHistory(page([item("text", off)], more: true))
            off -= 1000
            pages += 1
            if pages > 20 { break }
        }
        #expect(pages == TranscriptStore.maxGapPages)
    }

    @Test func differentFileDropsEverything() {
        var s = TranscriptStore()
        s.apply(page([item("user", 10), item("text", 20)], next: 2))
        s.apply(page([item("user", 3)], next: 1, gen: "g9", file: "f2"))
        #expect(s.items.map { $0.off } == [3] && s.file == "f2" && s.next == 1)
    }

    @Test func resetWithoutStartMeansFromZero() {
        var s = TranscriptStore()
        s.apply(page([item("user", 10)], next: 1))
        s.apply(page([item("user", 0, seq: 1), item("text", 4)], next: 2, gen: "g2", reset: true))
        #expect(s.items.map { $0.off } == [0, 4] && s.gapBefore == nil)
    }

    @Test func scrollUpPaging() {
        var s = TranscriptStore()
        s.apply(page([item("text", 100), item("text", 200)], next: 2, truncated: true))
        #expect(s.oldestOffset == 100 && s.hasMoreBefore)
        let next = s.absorbHistory(page([item("user", 10), item("text", 50)], more: false))
        #expect(next == nil && !s.hasMoreBefore)
        #expect(s.items.map { $0.off } == [10, 50, 100, 200])
        // duplicates by id never double up
        s.prepend([item("text", 50)])
        #expect(s.items.count == 4)
    }

    @Test func pendingPromptIsSettledByTheEcho() {
        var s = TranscriptStore()
        s.apply(page([item("user", 1, text: "first")], next: 1))
        let p = s.addPendingUser("run the tests")
        #expect(s.displayItems.last?.pending == true && s.displayItems.count == 2 && s.items.count == 1)
        s.apply(page([TranscriptItem(kind: "user", id: "cl@50.1", off: 50, text: " run the tests ")], next: 2))
        #expect(s.pending.isEmpty && s.displayItems.count == 2)
        let q = s.addPendingUser("never echoed")
        s.removePending(id: q.id)
        #expect(s.pending.isEmpty)
        _ = p
    }

    @Test func sourceNoneKeepsReason() {
        var s = TranscriptStore()
        s.apply(TranscriptPage(source: "none", items: [], next: 0, reason: "No codex conversation"))
        #expect(s.source == "none" && s.reason == "No codex conversation" && s.items.isEmpty)
    }

    @Test func realFixtureFlow() throws {
        var s = TranscriptStore()
        let open: TranscriptPage = try Fixture.decode("transcript.json")
        s.apply(open)
        #expect(s.items.count == 6 && s.next == 6)
        // a poll later: nothing new
        s.apply(try Fixture.decode("transcript_poll_empty.json", as: TranscriptPage.self))
        #expect(s.items.count == 6)
        // older page (before the edit): all already held, no duplicates
        s.absorbHistory(try Fixture.decode("transcript_before.json", as: TranscriptPage.self))
        #expect(s.items.count == 6)
        // the box restarted its reading (gen unknown): whole window, still the same file
        let reset: TranscriptPage = try Fixture.decode("transcript_reset.json")
        #expect(reset.reset == true)
        s.apply(reset)
        #expect(s.items.count >= 6 && s.gen == reset.gen)
        #expect(Set(s.items.map(\.id)).count == s.items.count)
        // the open question appears, then is answered
        s.apply(try Fixture.decode("transcript_question.json", as: TranscriptPage.self))
        #expect(s.openQuestion != nil)
        s.apply(try Fixture.decode("transcript_answered.json", as: TranscriptPage.self))
        #expect(s.openQuestion == nil)
        #expect(s.items.contains { $0.kind == "question" && $0.answers == ["Blue"] })
        #expect(Set(s.items.map(\.id)).count == s.items.count)
    }
}
