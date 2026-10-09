package box

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"pier/pierd/internal/events"
)

func fakeProc(t *testing.T) string {
	t.Helper()
	proc := t.TempDir()
	write := func(rel, data string) {
		t.Helper()
		p := filepath.Join(proc, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("uptime", "3600.52 7000.00\n")
	write("loadavg", "0.50 0.75 1.25 2/300 4242\n")
	write("meminfo", "MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    6000000 kB\nSwapTotal:       2000000 kB\nSwapFree:        1500000 kB\n")
	agent := func(pid int, comm, cwd string) {
		dir := filepath.Join(proc, strconv.Itoa(pid))
		write(filepath.Join(strconv.Itoa(pid), "comm"), comm+"\n")
		os.Symlink(cwd, filepath.Join(dir, "cwd"))
	}
	agent(100, "claude", "/home/alex/work/cal-fix-login")
	agent(101, "codex", "/home/alex/work/cal (deleted)")
	agent(102, "zsh", "/home/alex")
	agent(103, "agent", "/home/alex")
	return proc
}

func TestStatsReadMemoryLoadAndAgents(t *testing.T) {
	// No cgroup limit: a container running the test has its own.
	s := collectStatsIn(fakeProc(t), t.TempDir())
	if s.Uptime != 3600 || len(s.Load) != 3 || s.Load[2] != 1.25 {
		t.Fatalf("uptime/load = %d %v", s.Uptime, s.Load)
	}
	if s.Memory.Total != 16000000*1024 || s.Memory.Used != 10000000*1024 {
		t.Fatalf("memory = %+v; used must count caches as free", s.Memory)
	}
	if s.Swap.Used != 500000*1024 {
		t.Fatalf("swap = %+v", s.Swap)
	}
	if len(s.Agents) != 2 || s.Agents[0].Tool != "claude" || s.Agents[1].Tool != "codex" || s.Agents[1].Path != "/home/alex/work/cal" {
		t.Fatalf("agents = %+v", s.Agents)
	}
	if len(s.Disks) == 0 || s.Disks[0].Mount != "/" || s.Disks[0].Total == 0 {
		t.Fatalf("disks = %+v", s.Disks)
	}
}

func TestAgentsPierDidNotStartAreKnownByDirectory(t *testing.T) {
	var a Turns
	a.Observe(events.Event{Type: "agent.waiting", Time: time.Now(), Data: map[string]any{"path": "/w/a/"}})
	a.Observe(events.Event{Type: "agent.finished", Data: map[string]any{"path": "/w/b"}})
	a.Observe(events.Event{Type: "worktree.created", Data: map[string]any{"path": "/w/c"}})
	if st, _, ok := a.DirState("/w/a"); !ok || st != "waiting" {
		t.Fatalf("/w/a = %s %v", st, ok)
	}
	if st, _, _ := a.DirState("/w/b"); st != "finished" {
		t.Fatalf("/w/b = %s", st)
	}
	if _, _, ok := a.DirState("/w/c"); ok {
		t.Fatal("a non-agent event set an agent state")
	}
	a.Observe(events.Event{Type: "agent.started", Data: map[string]any{"path": "/w/a"}})
	if st, _, _ := a.DirState("/w/a"); st != "running" {
		t.Fatalf("a new prompt did not clear waiting: %s", st)
	}
}

func TestWorktreeForPicksTheDeepest(t *testing.T) {
	locs := []Location{{Name: "cal", Worktrees: []Worktree{{Name: "cal", Path: "/w/cal"}, {Name: "fix", Path: "/w/cal/.worktrees/fix"}}}}
	if l, w := worktreeFor(locs, "/w/cal/.worktrees/fix/apps/web"); l != "cal" || w != "fix" {
		t.Fatalf("got %s/%s", l, w)
	}
	if l, w := worktreeFor(locs, "/w/calendar"); l != "" || w != "" {
		t.Fatalf("a sibling directory matched: %s/%s", l, w)
	}
}

func TestStatsUseTheContainersLimits(t *testing.T) {
	proc := fakeProc(t)
	cg := t.TempDir()
	os.WriteFile(filepath.Join(cg, "memory.max"), []byte("8589934592\n"), 0o644)
	os.WriteFile(filepath.Join(cg, "memory.current"), []byte("4294967296\n"), 0o644)
	os.WriteFile(filepath.Join(cg, "cpu.max"), []byte("100000 100000\n"), 0o644)
	s := collectStatsIn(proc, cg)
	if s.Memory.Total != 8<<30 || s.Memory.Used != 4<<30 || s.CPUs != 1 {
		t.Fatalf("memory %+v, cpus %d; want the cgroup's 8 GiB, 4 GiB used, 1 CPU", s.Memory, s.CPUs)
	}
	os.WriteFile(filepath.Join(cg, "memory.max"), []byte("max\n"), 0o644)
	os.WriteFile(filepath.Join(cg, "cpu.max"), []byte("max 100000\n"), 0o644)
	if s := collectStatsIn(proc, cg); s.Memory.Total != 16000000*1024 || s.CPUs == 1 {
		t.Fatalf("an unlimited cgroup changed the totals: %+v, %d CPUs", s.Memory, s.CPUs)
	}
}

// A box with no agent running must still send a list. Go marshals a nil slice
// as null, and every client here reads these fields as lists: a null is what
// crashed the desktop app's overview on a box that happened to have no agent
// running at the time.
func TestStatsSendEmptyListsRatherThanNull(t *testing.T) {
	s := collectStats(t.TempDir()) // an empty proc: no agent processes at all
	if len(s.Agents) != 0 {
		t.Fatalf("agents = %+v; want none from an empty proc", s.Agents)
	}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"agents", "disks"} {
		if _, ok := got[field].([]any); !ok {
			t.Fatalf("%s marshalled as %v, not a list; a client reading it as one fails", field, got[field])
		}
	}
}
