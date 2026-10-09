import Testing

@testable import PierKit

@Suite struct ActivityReconcileTests {
    @Test func newActivityWithUnknownSessionIsKept() {
        #expect(ActivityReconcile.decide(sessionKnown: false, sessionExited: false, listLoaded: true, age: 1) == .keep)
        #expect(ActivityReconcile.decide(sessionKnown: false, sessionExited: false, listLoaded: false, age: 9999) == .keep)
    }
    @Test func oldActivityNeedsAFreshFetchBeforeEnding() {
        #expect(ActivityReconcile.decide(sessionKnown: false, sessionExited: false, listLoaded: true, age: 300) == .verifyWithFreshFetch)
        #expect(ActivityReconcile.decide(sessionKnown: false, sessionExited: false, listLoaded: true, age: 300, freshFetchLacksSession: true) == .end)
        #expect(ActivityReconcile.decide(sessionKnown: false, sessionExited: false, listLoaded: true, age: 300, freshFetchLacksSession: false) == .keep)
    }
    @Test func knownSessionsFollowAndExitedEnd() {
        #expect(ActivityReconcile.decide(sessionKnown: true, sessionExited: false, listLoaded: true, age: 0) == .follow)
        #expect(ActivityReconcile.decide(sessionKnown: true, sessionExited: true, listLoaded: true, age: 0) == .end)
    }
}

@Suite struct TurnChangesTests {
    private func item(_ kind: String, _ id: String, file: String? = nil, added: Int? = nil, removed: Int? = nil) -> TranscriptItem {
        TranscriptItem(kind: kind, id: id, file: file, added: added, removed: removed)
    }
    @Test func onlyTheLastTurnCountsAndFilesAreUnique() {
        let items = [
            item("user", "1"), item("edit", "2", file: "old.py", added: 9, removed: 9),
            item("user", "3"), item("edit", "4", file: "a.py", added: 5, removed: 2), item("edit", "5", file: "a.py", added: 1),
            item("edit", "6", file: "b.py", added: 3), item("text", "7"),
        ]
        #expect(TurnChanges.lastTurn(items) == TurnChanges(files: 2, added: 9, removed: 2))
    }
    @Test func noEditsIsNil() {
        #expect(TurnChanges.lastTurn([item("user", "1"), item("text", "2")]) == nil)
        #expect(TurnChanges.lastTurn([item("edit", "1", file: "x"), item("user", "2")]) == nil)
        #expect(TurnChanges.lastTurn([]) == nil)
    }
}

@Suite struct SessionLookupTests {
    @Test func longestWorktreePrefixWins() {
        let withWt = Location(name: "sandbox", path: "/h/code/sandbox", repo: true, worktrees: [
            Worktree(name: "sandbox", path: "/h/code/sandbox", main: true),
            Worktree(name: "subtract", path: "/h/code/sandbox-subtract"),
        ])
        let r = SessionLookup.worktree(forSessionName: "sandbox-subtract-claude-6s1", in: [withWt])
        #expect(r?.location == "sandbox"); #expect(r?.worktree == "subtract")
        let main = SessionLookup.worktree(forSessionName: "sandbox-claude-1", in: [withWt])
        #expect(main?.worktree == "sandbox")
        #expect(SessionLookup.worktree(forSessionName: "other-claude-1", in: [withWt]) == nil)
        #expect(SessionLookup.worktree(forSessionName: "sandbox", in: [withWt]) == nil)
    }
}
