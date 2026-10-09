import Foundation
import Testing

@testable import PierKit

@Suite struct HousekeepingTests {
    private func wt(_ name: String, main: Bool? = nil, branch: String? = nil, base: String? = "main", ahead: Int = 0, behind: Int = 0,
                    changed: Int = 0, untracked: Int = 0, sessions: Int = 0) -> WorktreeStatus {
        WorktreeStatus(location: "rv3", name: name, branch: branch ?? name, main: main, base: base, ahead: ahead, behind: behind,
                       changed: changed, untracked: untracked, sessions: sessions)
    }

    /// The box as it was: two worktrees whose sessions were ended (branches pushed), services still running, main behind.
    @Test func realCaseEndedSessionsLeftWorktreesAndServices() {
        let plan = Housekeeping.plan(
            worktrees: [
                wt("rv3", main: true, branch: "main", base: "origin/main", behind: 5),
                wt("veja-pra-mim-o", branch: "chore/remove-exports", base: "origin/chore/remove-exports"),
                wt("valide", branch: "feat/menu", base: "origin/feat/menu"),
            ],
            sessions: [],
            services: [BoxService(location: "rv3", worktree: "veja-pra-mim-o", port: 41710), BoxService(location: "rv3", worktree: "valide", port: 41720)])
        #expect(plan.map(\.kind) == [.updateMain, .removeWorktree, .removeWorktree])
        #expect(plan.allSatisfy { $0.safe })
        #expect(plan[1].note.contains("enviada"))
    }

    @Test func workNotSentIsNotSafeAndOnlyItsServicesStop() {
        let plan = Housekeeping.plan(
            worktrees: [wt("wip", base: "main", ahead: 2, untracked: 1)],
            sessions: [], services: [BoxService(location: "rv3", worktree: "wip", port: 1)])
        #expect(plan.map(\.kind) == [.removeWorktree, .stopServices])
        #expect(plan[0].safe == false)
        #expect(plan[0].note.contains("2 commit(s) só nesta máquina") && plan[0].note.contains("1 arquivo(s) novo(s)"))
        #expect(plan[1].safe)
    }

    @Test func worktreesInUseAndCleanMainsAreLeftAlone() {
        let session = Session(name: "rv3-busy-claude-1", location: "rv3/busy", agent: "claude", agentState: .finished)
        let plan = Housekeeping.plan(
            worktrees: [wt("rv3", main: true, behind: 0), wt("busy"), wt("counted", sessions: 1)],
            sessions: [session], services: [])
        #expect(plan.map(\.kind) == [.updateMain])   // only the main's pull; busy worktrees are left alone
    }

    @Test func dirtyMainIsNotUpdatedAutomatically() {
        let plan = Housekeeping.plan(worktrees: [wt("rv3", main: true, behind: 3, changed: 2)], sessions: [], services: [])
        #expect(plan.count == 1 && plan[0].kind == .updateMain && !plan[0].safe)
    }

    @Test func aNewBranchNeverPushedIsNotCalledSent() {
        let plan = Housekeeping.plan(worktrees: [wt("fresh", branch: "fresh", base: "origin/main")], sessions: [], services: [])
        #expect(plan.count == 1 && plan[0].safe && plan[0].note == "nada além da base")
    }

    @Test func exitedSessionsAreDropped() {
        let s = Session(name: "old", location: "rv3/x", exited: true, agent: "claude", agentState: .finished)
        let plan = Housekeeping.plan(worktrees: [], sessions: [s], services: [])
        #expect(plan.map(\.kind) == [.dropSession] && plan[0].session == "old" && plan[0].worktree == "x")
    }

    @Test func updateMainOutput() {
        #expect(GitActions.parseUpdateMain(exitCode: 0, output: "PIER_MAIN_OK a1b2c3d") == .updated("a1b2c3d"))
        #expect(GitActions.parseUpdateMain(exitCode: 0, output: "PIER_MAIN_DIRTY") == .dirty)
        #expect(GitActions.parseUpdateMain(exitCode: 1, output: "fatal: Not possible to fast-forward, aborting.") == .failed("fatal: Not possible to fast-forward, aborting."))
    }
}
