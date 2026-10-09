import Foundation
import Testing

@testable import PierKit

/// Every captured fixture decodes into its model; the dictionary below must cover every `.json` in Fixtures/.
@Suite struct FixtureDecodingTests {
    static let decoders: [String: @Sendable (Data) throws -> Void] = {
        func d<T: Decodable>(_ t: T.Type) -> @Sendable (Data) throws -> Void { { _ = try JSONDecoder.pier.decode(T.self, from: $0) } }
        struct Obj: Decodable {}
        return [
            "info.json": d(BoxInfo.self), "stats.json": d(BoxStats.self), "stats_running.json": d(BoxStats.self),
            "doctor.json": d([DoctorCheck].self), "agents.json": d([AgentCLI].self),
            "locations.json": d([Location].self), "branches_sandbox.json": d(BranchList.self),
            "worktrees_sandbox.json": d([WorktreeStatus].self), "worktrees_sandbox2.json": d([WorktreeStatus].self),
            "worktree_created.json": d(Worktree.self), "worktree_removed.json": d(Obj.self), "worktree_log.json": d(Obj.self),
            "services.json": d([JSONValue].self), "services_wt.json": d([JSONValue].self),
            "task_create.json": d(TaskResult.self), "task_create_codex.json": d(TaskResult.self),
            "session_shell.json": d(Session.self), "session_killed.json": d(Obj.self), "session_renamed.json": d(Session.self),
            "sessions_empty.json": d([Session].self), "sessions_running.json": d([Session].self),
            "sessions_finished.json": d([Session].self), "sessions_waiting.json": d([Session].self),
            "sessions_queued.json": d([Session].self), "sessions_question.json": d([Session].self),
            "sessions_codex.json": d([Session].self), "sessions_mixed.json": d([Session].self),
            "screen_claude_trust.json": d(Obj.self), "screen_claude_working.json": d(Obj.self), "screen_codex_trust.json": d(Obj.self),
            "screen_finished.json": d(Obj.self), "screen_permission.json": d(Obj.self), "screen_mcp_dialog.json": d(Obj.self), "screen_question.json": d(Obj.self),
            "screen_shell.json": d(Obj.self),
            "draft.json": d(Draft.self), "send_now_result.json": d(SendResult.self), "send_idle_queued.json": d(SendResult.self),
            "send_key_result.json": d(SendResult.self), "queue_send_now.json": d(SendResult.self),
            "queue_empty.json": d([HeldPrompt].self), "queue_held.json": d([HeldPrompt].self),
            "interrupt_result.json": d(InterruptResult.self), "mode_set.json": d(Obj.self),
            "controls_auto.json": d(SessionControls.self), "controls_default.json": d(SessionControls.self), "controls_codex.json": d(SessionControls.self),
            "turns.json": d([Turn].self), "turns_after.json": d([Turn].self),
            "wait_finished.json": d(WaitResult.self), "wait_waiting.json": d(WaitResult.self), "wait_question.json": d(WaitResult.self),
            "attachment_result.json": d(Attachment.self),
            "transcript.json": d(TranscriptPage.self), "transcript_poll_empty.json": d(TranscriptPage.self),
            "transcript_before.json": d(TranscriptPage.self), "transcript_reset.json": d(TranscriptPage.self),
            "transcript_question.json": d(TranscriptPage.self), "transcript_answered.json": d(TranscriptPage.self),
            "transcript_codex.json": d(TranscriptPage.self),
            "tool_detail_edit.json": d(ToolDetail.self), "tool_detail_run.json": d(ToolDetail.self), "tool_detail_write.json": d(ToolDetail.self),
            "review.json": d([ReviewItem].self), "review_committed.json": d([ReviewItem].self),
            "touched.json": d(Obj.self), "file_diff.json": d(FileDiff.self), "file_diff_untracked.json": d(FileDiff.self),
            "exec_diff.json": d(ExecResult.self), "exec_diff_untracked.json": d(ExecResult.self), "exec_pr_view.json": d(ExecResult.self),
            "exec_status.json": d(ExecResult.self), "exec_fail.json": d(ExecResult.self), "exec_commit.json": d(ExecResult.self),
            "exec_gh_pr_view_merged.json": d(ExecResult.self), "exec_gh_pr_view_fork.json": d(ExecResult.self),
            "exec_gh_pr_view_approved.json": d(ExecResult.self), "exec_gh_pr_view_changes.json": d(ExecResult.self),
            "exec_gh_pr_diff.json": d(ExecResult.self),
        ]
    }()

    @Test func everyFixtureIsCovered() {
        let missing = Fixture.allJSON.filter { Self.decoders[$0] == nil }
        #expect(missing.isEmpty, "fixtures without a decoder test: \(missing)")
        let stale = Self.decoders.keys.filter { !Fixture.allJSON.contains($0) }
        #expect(stale.isEmpty, "decoder entries without a fixture: \(stale)")
    }

    @Test(arguments: Fixture.allJSON) func decodes(_ name: String) throws {
        let decode = try #require(Self.decoders[name])
        try decode(try Fixture.data(name))
    }
}

@Suite struct LiveShapeTests {
    @Test func info() throws {
        let i: BoxInfo = try Fixture.decode("info.json")
        #expect(i.name == "devbox")
        #expect(i.build.count == 12)
        #expect(i.has("transcript") && i.has("journal"))
        let claude = try #require(i.agents.first { $0.id == "claude" })
        #expect(claude.canPickModel && claude.canPickEffort)
        #expect(claude.models == ["opus", "sonnet", "haiku"])
        let codex = try #require(i.agents.first { $0.id == "codex" })
        #expect(codex.effortFlag == "-c model_reasoning_effort=")
        #expect(i.adapters?["claude"]?.via == "hooks")
        #expect(i.adapters?["claude"]?.finalMessage == true)
    }

    @Test func stats() throws {
        let s: BoxStats = try Fixture.decode("stats.json")
        #expect(s.cpus > 0)
        #expect(s.memory.total > s.memory.used)
        #expect(!s.disks.isEmpty)
        #expect((s.load?.count ?? 0) == 3)
    }

    @Test func locations() throws {
        let locs: [Location] = try Fixture.decode("locations.json")
        let sandbox = try #require(locs.first { $0.name == "sandbox" })
        #expect(sandbox.repo)
        #expect(sandbox.defaultBranch == "main")
        let wt = try #require(sandbox.worktrees?.first)
        #expect(wt.main == true)
        #expect(sandbox.ref(wt) == "sandbox")
        #expect(sandbox.ref(Worktree(name: "x", path: "/p")) == "sandbox/x")
    }

    @Test func taskAndSessions() throws {
        let t: TaskResult = try Fixture.decode("task_create.json")
        #expect(t.session.agent == "claude")
        #expect(t.session.agentState == .running)
        #expect(t.session.location == "sandbox/subtract")
        #expect(t.worktree.branch == "subtract")
        #expect(t.session.stateSince != nil)

        let waiting: [Session] = try Fixture.decode("sessions_waiting.json")
        let s = try #require(waiting.first)
        #expect(s.needsYou)
        #expect(s.ask?.tool == "Bash")
        #expect(s.ask?.input == "mkdir probe_dir && touch probe_dir/x.txt")
        #expect(s.needsYouKind == .permission)

        let q: [Session] = try Fixture.decode("sessions_question.json")
        #expect(q.first?.ask?.tool == "AskUserQuestion")
        #expect(q.first?.needsYouKind == .question)

        let mixed: [Session] = try Fixture.decode("sessions_mixed.json")
        let shell = try #require(mixed.first { $0.name == "bk-shell" })
        #expect(shell.agent == nil && shell.agentState == nil && !shell.isAgent)
        #expect(shell.needsYouKind == nil)
    }

    @Test func nanosecondDates() throws {
        let s: [Session] = try Fixture.decode("sessions_waiting.json")
        let since = try #require(s.first?.stateSince)
        // 2026-10-07T21:33:57.260855049Z
        #expect(abs(since.timeIntervalSince1970 - 1791408837.260855049) < 1e-5)
        let r: SendResult = try Fixture.decode("send_now_result.json")
        #expect(RFC3339.format(r.at).hasPrefix("2026-10-07T21:33:49.19733"))
    }

    @Test func transcript() throws {
        let p: TranscriptPage = try Fixture.decode("transcript.json")
        #expect(p.source == "claude")
        #expect(p.items.count == 6)
        #expect(p.next == 6)
        #expect(p.file != nil && p.gen != nil)
        #expect(p.signals?.mode == "auto")
        #expect(p.signals?.context?.tokens == 41576)
        #expect(p.items.map(\.type) == [.user, .tools, .tools, .edit, .edit, .text])
        let tools = p.items[1]
        #expect(tools.items?.first?.verb == "Read" && tools.items?.first?.file == true)
        let edit = p.items[3]
        #expect(edit.file == "calc.py" && edit.added == 5 && edit.removed == 2 && edit.tool != nil)

        let empty: TranscriptPage = try Fixture.decode("transcript_poll_empty.json")
        #expect(empty.items.isEmpty)  // `"items": null`

        let q: TranscriptPage = try Fixture.decode("transcript_question.json")
        let question = try #require(q.items.last)
        #expect(question.type == .question)
        #expect(question.questions?.first?.options.map(\.label) == ["Red", "Blue"])
        #expect(question.done != true)
        let answered: TranscriptPage = try Fixture.decode("transcript_answered.json")
        let a = try #require(answered.items.first { $0.kind == "question" })
        #expect(a.answers == ["Blue"] && a.done == true)
        #expect(QuestionHelpers.openQuestion(in: answered.items) == nil)
        #expect(QuestionHelpers.openQuestion(in: q.items)?.id == question.id)

        let none: TranscriptPage = try Fixture.decode("transcript_codex.json")
        #expect(none.source == "codex")
        #expect(none.signals?.context?.window == 258400)
        #expect(none.signals?.mode == "on-request")
    }

    @Test func toolDetail() throws {
        let e: ToolDetail = try Fixture.decode("tool_detail_edit.json")
        #expect(e.name == "Edit")
        let h = try #require(e.hunks?.first)
        #expect(h.oldStart == 1 && h.newLines == 5)
        #expect(h.lines.first == " def add(a, b):")
        let r: ToolDetail = try Fixture.decode("tool_detail_run.json")
        #expect(r.command?.hasPrefix("ls ") == true && r.output != nil)
    }

    @Test func reviewAndTouched() throws {
        let r: [ReviewItem] = try Fixture.decode("review.json")
        let item = try #require(r.first)
        #expect(item.files.map(\.code) == [" M", "??"])
        #expect(item.execLocation == "sandbox/subtract")
        #expect(item.state == .finished)
        #expect(item.added == 6)
        let c: [ReviewItem] = try Fixture.decode("review_committed.json")
        #expect(c[0].files.isEmpty && c[0].committed.count == 3 && c[0].commits.count == 1 && c[0].baseAhead == 1)

        struct T: Decodable { let files: [TouchedFile] }
        let t: T = try Fixture.decode("touched.json")
        #expect(t.files.count == 2 && t.files.first?.created == true && t.files.first?.base == "turn")
    }

    @Test func turnsHeldAndWait() throws {
        let t: [Turn] = try Fixture.decode("turns_after.json")
        #expect(t.count == 4)
        #expect(t[2].waits?.first?.ask?.tool == "Bash")
        #expect(t[2].waits?.first?.reason == "permission")
        #expect(t[0].sentSeq != nil && t[0].sent != nil)
        let h: [HeldPrompt] = try Fixture.decode("queue_held.json")
        #expect(h.first?.turn.hasSuffix("#5") == true && h.first?.length == 173)
        let w: WaitResult = try Fixture.decode("wait_waiting.json")
        #expect(w.state == "waiting" && !w.timedOut)
        let s: SendResult = try Fixture.decode("send_idle_queued.json")
        #expect(s.queued == true && s.sent == false)
    }

    @Test func events() throws {
        let text = try Fixture.text("events.ndjson")
        var seqs: [Int64] = []
        var types: Set<String> = []
        for l in text.split(separator: "\n") {
            let e = try JSONDecoder.pier.decode(PierEvent.self, from: Data(l.utf8))
            seqs.append(e.seq ?? -1)
            types.insert(e.type)
        }
        #expect(seqs == seqs.sorted() && seqs.count > 40)
        #expect(types.isSuperset(of: ["agent.waiting", "agent.finished", "session.started", "task.created", "transcript.changed"]))
        let first = try JSONDecoder.pier.decode(PierEvent.self, from: Data(text.split(separator: "\n")[0].utf8))
        #expect(first.type == "session.started" && first.str("agent") == "claude")
    }

    @Test func screens() throws {
        // permission menu with the box's side pane drawn next to it
        let perm = try Fixture.screen("screen_permission.json")
        let menu = parseMenu(perm)
        #expect(menu.map(\.key) == ["1", "2", "3", "4"])
        #expect(menu[0].label == "Yes")
        #expect(menu[1].label.hasPrefix("Yes, and don't ask again for mkdir"))
        #expect(menu[3].label == "No")
        let acts = permissionActions(menu)
        #expect(acts.allow?.key == "1" && acts.always?.key == "2" && acts.deny?.key == "4")
        #expect(MenuParser.actions(in: perm) == [.allow(key: "1"), .alwaysAllow(key: "2"), .deny(key: "4")])
    }
}
