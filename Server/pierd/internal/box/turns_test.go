package box

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/integrations"
)

// ledger is a turn ledger following a sequenced bus, with sessions tracked
// as pierd would have started them.
func ledger(t *testing.T, sessions ...Session) (*Turns, *events.Bus) {
	t.Helper()
	tr := &Turns{}
	bus := &events.Bus{Sequence: true}
	tr.Attach(bus)
	for _, s := range sessions {
		bus.Publish(events.Event{Type: "session.started", Data: map[string]any{"name": s.Name, "path": s.Dir, "agent": s.Agent}})
	}
	return tr, bus
}

func hook(bus *events.Bus, typ, session, path, agent string, extra ...string) events.Event {
	d := map[string]any{"path": path, "agent": agent}
	if session != "" {
		d["session"] = session
	}
	for i := 0; i+1 < len(extra); i += 2 {
		d[extra[i]] = extra[i+1]
	}
	return bus.Publish(events.Event{Type: typ, Origin: agent, Data: d})
}

func turnState(t *testing.T, tr *Turns, id string) string {
	t.Helper()
	got, ok := tr.Get(id)
	if !ok {
		t.Fatalf("no turn %s", id)
	}
	return got.State
}

// E3: a prompt sent while the agent is mid-turn is queued by the agent.
// The current turn's Stop ends that turn, not the new one, which starts at
// the next UserPromptSubmit and ends at the Stop after it.
func TestASendDuringATurnWaitsForItsOwnTurn(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "shop-feat-a-claude", Dir: "/srv/shop/feat-a", Agent: "claude"})
	s := "shop-feat-a-claude"
	hook(bus, "agent.ready", s, "/srv/shop/feat-a", "claude")
	hook(bus, "agent.started", s, "/srv/shop/feat-a", "claude", "signal", "prompt") // typed by a person
	sent := bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": s, "from": "client:devl"}})
	mine, ok := tr.ForSent(s, sent.Seq)
	if !ok || mine.State != "pending" || mine.ID != s+"#2" || mine.Origin != "client:devl" {
		t.Fatalf("sent turn = %+v %v", mine, ok)
	}
	done := make(chan Turn, 1)
	go func() {
		got, _, _ := tr.WaitTurn(context.Background(), mine.ID, true)
		done <- got
	}()
	hook(bus, "agent.finished", s, "/srv/shop/feat-a", "claude") // the person's turn
	if st := turnState(t, tr, s+"#1"); st != "finished" {
		t.Fatalf("the running turn is %s", st)
	}
	select {
	case got := <-done:
		t.Fatalf("the previous turn's Stop ended the wait: %+v", got)
	case <-time.After(100 * time.Millisecond):
	}
	hook(bus, "agent.started", s, "/srv/shop/feat-a", "claude", "signal", "prompt") // ours, dequeued
	hook(bus, "agent.started", s, "/srv/shop/feat-a", "claude", "signal", "tool")
	if st := turnState(t, tr, mine.ID); st != "running" {
		t.Fatalf("our turn is %s after its prompt started", st)
	}
	hook(bus, "agent.finished", s, "/srv/shop/feat-a", "claude")
	select {
	case got := <-done:
		if got.ID != mine.ID || got.State != "finished" || got.Fidelity != "hooks" {
			t.Fatalf("wait = %+v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the wait never ended")
	}
}

// E4: an approval clears waiting when the tool it allowed runs.
func TestApprovalClosesTheWaitSpan(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "s", Dir: "/w", Agent: "claude"})
	hook(bus, "agent.ready", "s", "/w", "claude")
	hook(bus, "agent.started", "s", "/w", "claude", "signal", "prompt")
	hook(bus, "agent.waiting", "s", "/w", "claude", "reason", "permission")
	if st, _ := tr.State("s"); st.State != "waiting" {
		t.Fatalf("state = %+v", st)
	}
	hook(bus, "agent.started", "s", "/w", "claude", "signal", "tool")
	got, _ := tr.Get("s#1")
	if st, _ := tr.State("s"); st.State != "running" || got.State != "running" || len(got.Waits) != 1 || got.Waits[0].End.IsZero() || got.Waits[0].Reason != "permission" {
		t.Fatalf("after approval: %+v %+v", st, got)
	}
	// A tool use while working changes nothing, so the box does not
	// publish it.
	if !tr.Redundant("agent.started", map[string]any{"session": "s", "signal": "tool"}) {
		t.Fatal("a tool use while running was not redundant")
	}
}

// E6: two agents in one worktree. Each one's hooks name its session, and
// old hooks that only give a folder end no wait unless one agent fits.
func TestAgentsSharingAWorktreeKeepTheirOwnTurns(t *testing.T) {
	dir := "/srv/shop/feat-a"
	tr, bus := ledger(t,
		Session{Name: "claude-1", Dir: dir, Agent: "claude"},
		Session{Name: "codex-1", Dir: dir, Agent: "codex"},
		Session{Name: "claude-2", Dir: dir, Agent: "claude"})
	for _, s := range []string{"claude-1", "claude-2"} {
		hook(bus, "agent.ready", s, dir, "claude")
	}
	hook(bus, "agent.started", "claude-1", dir, "claude", "signal", "prompt")
	// A second agent starting does not make the first one idle.
	hook(bus, "agent.ready", "claude-2", dir, "claude")
	if st, _ := tr.State("claude-1"); st.State != "running" {
		t.Fatalf("claude-1 = %+v", st)
	}
	// The reviewer finishing ends its own turn, not Claude's.
	bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "codex-1"}})
	hook(bus, "agent.finished", "codex-1", dir, "codex")
	if st := turnState(t, tr, "claude-1#1"); st != "running" {
		t.Fatalf("claude-1's turn = %s after the reviewer finished", st)
	}
	if st := turnState(t, tr, "codex-1#1"); st != "finished" {
		t.Fatalf("codex-1's turn = %s", st)
	}
	// An old hook with only the folder: one codex there, so it is that one.
	bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "codex-1"}})
	hook(bus, "agent.finished", "", dir, "codex")
	if st := turnState(t, tr, "codex-1#2"); st != "finished" {
		t.Fatalf("a folder-only codex hook did not reach the one codex: %s", st)
	}
	// Two Claudes there: ambiguous, recorded, and no turn ends.
	hook(bus, "agent.finished", "", dir, "claude")
	if st := turnState(t, tr, "claude-1#1"); st != "running" {
		t.Fatalf("an ambiguous hook ended claude-1's turn: %s", st)
	}
	if tr.Ambiguous.Load() != 1 {
		t.Fatalf("ambiguous = %d", tr.Ambiguous.Load())
	}
	hook(bus, "agent.finished", "claude-1", dir, "claude")
	if st := turnState(t, tr, "claude-1#1"); st != "finished" {
		t.Fatalf("claude-1 = %s", st)
	}
}

// E8: agents that cannot say they started (Codex's notify, Cursor without
// its newer hooks) start their turn at the send, so they read as working
// and their next finished ends it.
func TestAFinishedOnlyAgentWorksFromTheSend(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "cx", Dir: "/w", Agent: "codex"})
	hook(bus, "agent.finished", "cx", "/w", "codex", "via", "notify") // an earlier turn
	sent := bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "cx"}})
	mine, _ := tr.ForSent("cx", sent.Seq)
	if st, _ := tr.State("cx"); mine.State != "running" || mine.Fidelity != "partial" || st.State != "running" {
		t.Fatalf("after send: turn %+v, session %+v", mine, st)
	}
	hook(bus, "agent.finished", "cx", "/w", "codex", "via", "notify")
	if st := turnState(t, tr, mine.ID); st != "finished" {
		t.Fatalf("turn = %s", st)
	}
	// Once its hooks say a prompt started, sends wait for that instead.
	hook(bus, "agent.started", "cx", "/w", "codex", "signal", "prompt")
	hook(bus, "agent.finished", "cx", "/w", "codex")
	sent = bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "cx"}})
	if next, _ := tr.ForSent("cx", sent.Seq); next.State != "pending" {
		t.Fatalf("with prompt hooks, a send is %s", next.State)
	}
}

// E13: an agent finishes while pierd is down. Its hook is spooled, and
// published when pierd is back, so the turn ends; with no spooled hook,
// the open turn is left for the screen to settle.
func TestATurnThatEndedWhilePierdWasDownIsSettled(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "turns.json")
	spool := filepath.Join(dir, "spool")
	first := &Turns{Path: path}
	bus := &events.Bus{Sequence: true}
	first.Attach(bus)
	bus.Publish(events.Event{Type: "session.started", Data: map[string]any{"name": "a", "path": "/w/a", "agent": "claude"}})
	bus.Publish(events.Event{Type: "session.started", Data: map[string]any{"name": "b", "path": "/w/b", "agent": "claude"}})
	for _, s := range []string{"a", "b"} {
		hook(bus, "agent.ready", s, "/w/"+s, "claude")
		hook(bus, "agent.started", s, "/w/"+s, "claude", "signal", "prompt")
	}
	first.save()

	// pierd is down: a's Stop goes to the spool.
	integrations.Spool(spool, events.Event{Type: "agent.finished", Origin: "claude", Data: map[string]any{"session": "a", "path": "/w/a", "agent": "claude"}})

	second := &Turns{Path: path}
	bus2 := &events.Bus{Sequence: true}
	second.Attach(bus2)
	if open := second.openForScreen(); len(open) != 2 {
		t.Fatalf("open after restart = %v", open)
	}
	integrations.DrainSpool(spool, func(e events.Event) { bus2.Publish(e) })
	if st := turnState(t, second, "a#1"); st != "finished" {
		t.Fatalf("a#1 = %s after the spool drained", st)
	}
	if open := second.openForScreen(); len(open) != 1 || open[0] != "b" {
		t.Fatalf("left for the screen: %v", open)
	}
}

// Memory stays bounded: turns per session, the inbox, and sessions that
// ended are dropped.
func TestTheLedgerStaysBounded(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "s", Dir: "/w", Agent: "codex"})
	tr.ArchivePath = filepath.Join(t.TempDir(), "archive.jsonl")
	for range 120 {
		bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "s"}})
		hook(bus, "agent.finished", "s", "/w", "codex")
	}
	tr.mu.Lock()
	kept := len(tr.sess["s"].Turns)
	tr.mu.Unlock()
	if kept != maxTurnsKept {
		t.Fatalf("kept %d turns in memory", kept)
	}
	tr.save()
	if all := tr.List("s", 200); len(all) != 120 || all[0].ID != "s#1" || all[119].ID != "s#120" {
		t.Fatalf("listed %d turns from memory and the archive", len(all))
	}
	for i := range maxInbox + 1 {
		bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "s"}}) // busy
		_, err := tr.Queue("s", fmt.Sprint("prompt ", i), true, "client:devl", "")
		if i == maxInbox && err != ErrInboxFull {
			t.Fatalf("queued past the cap: %v", err)
		}
	}
	tr.mu.Lock()
	last := fmt.Sprintf("s#%d", tr.sess["s"].N)
	tr.mu.Unlock()
	tr.Prune(nil)
	if _, ok := tr.State("s"); ok {
		t.Fatal("an ended session was kept")
	}
	// Its last turn stays for a waiter, ended with the session.
	if got, ok := tr.Get(last); !ok || got.State != "exited" {
		t.Fatalf("the last turn of an ended session = %+v", got)
	}
}

// A person answering a question (forced, or from the phone) does not start
// a turn: the turn that asked goes on.
func TestAnAnswerIsPartOfTheTurnThatAsked(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "s", Dir: "/w", Agent: "claude"})
	hook(bus, "agent.ready", "s", "/w", "claude")
	hook(bus, "agent.started", "s", "/w", "claude", "signal", "prompt")
	hook(bus, "agent.waiting", "s", "/w", "claude")
	bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "s", "answer": true, "turn": "s#1"}})
	if all := tr.List("s", 10); len(all) != 1 {
		t.Fatalf("an answer made a turn: %+v", all)
	}
}

// A prompt the agent never started (two pastes read as one) ends "lost"
// after a while, so waits return and the inbox moves on.
func TestPendingTurnsThatNeverStartExpire(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "agent", Dir: "/w", Agent: "claude"})
	hook(bus, "agent.ready", "agent", "/w", "claude")
	sent := func() events.Event {
		return bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "agent"}})
	}
	sent()
	sent()
	hook(bus, "agent.started", "agent", "/w", "claude", "signal", "prompt")
	hook(bus, "agent.finished", "agent", "/w", "claude")
	if got := turnState(t, tr, "agent#2"); got != "pending" {
		t.Fatalf("second turn %s", got)
	}
	if n := tr.Expire(time.Now()); n != 0 {
		t.Fatal("expired too soon")
	}
	if n := tr.Expire(time.Now().Add(PendingExpiry + time.Second)); n != 1 || turnState(t, tr, "agent#2") != "lost" {
		t.Fatalf("expired %d, state %s", n, turnState(t, tr, "agent#2"))
	}
	if !tr.Ready("agent") {
		t.Fatal("the agent is still not ready for a prompt")
	}
}

// A new agent in a folder where another agent last waited starts without
// that state: the folder's "waiting" from before it began is not its own.
func TestANewSessionDoesNotInheritAnOlderFolderState(t *testing.T) {
	turns := &Turns{}
	bus := &events.Bus{Sequence: true}
	turns.Attach(bus)
	old := time.Now().Add(-time.Hour)
	// An agent pierd didn't start reported from /w an hour ago.
	bus.Publish(events.Event{Type: "agent.waiting", Time: old, Data: map[string]any{"path": "/w", "agent": "claude"}})
	bus.Publish(events.Event{Type: "session.started", Time: time.Now(), Data: map[string]any{"name": "fresh", "path": "/w", "agent": "claude"}})
	if st, _ := turns.State("fresh"); st.State != "" {
		t.Fatalf("a new session took the folder's old state: %+v", st)
	}
}

// approvingAgent is a stand-in for an agent stopped at a permission prompt:
// it draws the menu Claude Code draws, keeps whatever is typed into it
// (out/swallowed) and never moves on, as a person who hasn't answered yet.
func approvingAgent(t *testing.T, out string) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "agent")
	script := `#!/bin/sh
out='` + out + `'
stty raw -echo
printf '\033[2J\033[H'
printf ' Bash command\r\n\r\n   npm test\r\n\r\n Do you want to proceed?\r\n ❯ 1. Yes\r\n   2. No\r\n\r\n Esc to cancel\r\n'
while :; do
	c=$(dd bs=1 count=1 2>/dev/null)
	printf '%s' "$c" >> "$out/swallowed"
done
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// An agent's screen holds still while it waits for a permission. That is
// not a turn that ended: not for an agent whose hooks said it waits (its
// first turn opened before its hooks did, and stays theirs to end), nor
// for one followed by its screen alone. Ending it would type the prompts
// held for the agent into its question.
func TestAStillScreenNeverEndsTheTurnOfAnAgentThatWaits(t *testing.T) {
	turns := &Turns{}
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { b.Turns = turns; bx = b })
	turns.Attach(bus)
	var finished []events.Event
	bus.Observe(func(e events.Event) {
		if e.Type == "agent.finished" {
			finished = append(finished, e)
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go turns.Run(ctx, bx)
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "shop", "path": repo}, nil)
	out := t.TempDir()
	fake := approvingAgent(t, out)
	cfg := RepoConfig{Agents: []AgentPreset{{ID: "claude", Name: "Claude Code", Command: fake}, {ID: "gemini", Name: "Gemini CLI", Command: fake}}}
	if st := call(t, c, "PUT", "/v1/locations/shop/config", "", map[string]any{"local": cfg}, nil); st != 200 {
		t.Fatalf("config = %d", st)
	}
	for _, s := range []struct{ name, agent string }{{"hooked", "claude"}, {"watched", "gemini"}} {
		var sess Session
		if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Location: "shop", Name: s.name, Agent: s.agent, Prompt: "run the tests"}, &sess); st != 200 {
			t.Fatalf("start %s = %d %+v", s.name, st, sess)
		}
		if got, _ := turns.Get(s.name + "#1"); got.State != "running" || got.Fidelity != "screen" {
			t.Fatalf("%s's first turn = %+v", s.name, got)
		}
	}
	// The hooked agent's hooks speak: the turn is theirs now, and it waits.
	hook(bus, "agent.ready", "hooked", "", "claude")
	hook(bus, "agent.started", "hooked", "", "claude", "signal", "prompt")
	hook(bus, "agent.waiting", "hooked", "", "claude", "reason", "permission")
	if got, _ := turns.Get("hooked#1"); got.State != "waiting" || got.Fidelity != "hooks" {
		t.Fatalf("after its hooks: %+v", got)
	}
	var held SendResult
	if st := call(t, c, "POST", "/v1/sessions/hooked/send", "", SendRequest{Text: "and add a test", When: "idle"}, &held); st != 200 || !held.Queued {
		t.Fatalf("idle send = %d %+v", st, held)
	}
	// The watched agent's screen says it waits; then both screens hold
	// still for longer than screenQuiet polls.
	for i := 0; i < screenQuiet+3; i++ {
		bx.pollScreens(ctx)
	}
	waitUntil(t, "the watched agent to read as waiting", 5*time.Second, func() bool {
		st, _ := turns.State("watched")
		return st.State == "waiting"
	})
	for i := 0; i < screenQuiet+3; i++ {
		bx.pollScreens(ctx)
	}
	time.Sleep(500 * time.Millisecond) // the inbox had its chance
	if len(finished) > 0 {
		t.Fatalf("the screen ended a waiting agent's turn: %+v", finished[0].Data)
	}
	for _, name := range []string{"hooked", "watched"} {
		if got, _ := turns.Get(name + "#1"); got.State != "waiting" {
			t.Fatalf("%s#1 = %+v", name, got)
		}
	}
	if q := turns.Queued("hooked"); len(q) != 1 {
		t.Fatalf("the held prompt went: %+v", q)
	}
	if b, _ := os.ReadFile(filepath.Join(out, "swallowed")); strings.TrimSpace(string(b)) != "" {
		t.Fatalf("typed into the question: %q", b)
	}
}

// The incident: a task's agent finished its turn, then the app's one-shot
// `claude -p` (next steps) ran in the same worktree. Its hooks named no
// session, only the folder and another conversation ID; taken for the
// task's agent they opened a turn and then "exited" it, and the session
// read as working forever.
func TestAOneShotAgentInTheSameFolderIsNotTheSessions(t *testing.T) {
	dir := "/home/u/code/app-stack"
	tr, bus := ledger(t, Session{Name: "app-stack-claude", Dir: dir, Agent: "claude"})
	bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "app-stack-claude", "startup": true}})
	hook(bus, "agent.ready", "app-stack-claude", dir, "claude", "agent_session_id", "b54f")
	hook(bus, "agent.started", "app-stack-claude", dir, "claude", "agent_session_id", "b54f", "signal", "prompt")
	hook(bus, "agent.finished", "app-stack-claude", dir, "claude", "agent_session_id", "b54f")
	for _, typ := range []string{"agent.ready", "agent.started", "agent.finished", "agent.exited"} {
		extra := []string{"agent_session_id", "a3a4"}
		if typ == "agent.started" {
			extra = append(extra, "signal", "prompt")
		}
		hook(bus, typ, "", dir, "claude", extra...)
	}
	st, _ := tr.State("app-stack-claude")
	if st.State != "finished" {
		t.Fatalf("the one-shot run changed the session: %+v", st)
	}
	if _, ok := tr.Get("app-stack-claude#2"); ok {
		t.Fatal("the one-shot run opened a turn in the session")
	}
	// A folder-only hook with the session's own conversation ID is still its.
	hook(bus, "agent.started", "", dir, "claude", "agent_session_id", "b54f", "signal", "prompt")
	if st, _ := tr.State("app-stack-claude"); st.State != "running" {
		t.Fatalf("the session's own folder-only hook was dropped: %+v", st)
	}
}

// A live terminal whose agent exited is idle, never "running" since never.
func TestALiveSessionWhoseAgentExitedIsIdle(t *testing.T) {
	dir := "/w/exited"
	tr, bus := ledger(t, Session{Name: "ex-claude", Dir: dir, Agent: "claude"})
	hook(bus, "agent.ready", "ex-claude", dir, "claude")
	hook(bus, "agent.exited", "ex-claude", dir, "claude")
	b := &Box{Turns: tr, Sessions: &Sessions{}}
	got := b.enrich(context.Background(), []Session{{Name: "ex-claude", Dir: dir, Command: "claude"}})[0]
	if got.AgentState != "idle" || got.StateSince.IsZero() {
		t.Fatalf("state = %q since %v", got.AgentState, got.StateSince)
	}
}
