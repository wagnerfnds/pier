package box

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// fakeScopes stands in for systemd: its "scope" is env setting a variable
// before the program, and it remembers what it was asked.
type fakeScopes struct {
	mu      sync.Mutex
	wrapped []string
	high    map[string]uint64
	stopped []string
	cgroup  string
}

func (f *fakeScopes) Available(context.Context) bool { return true }

func (f *fakeScopes) Wrap(unit, description string, memoryHigh uint64) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrapped = append(f.wrapped, unit)
	if f.high == nil {
		f.high = map[string]uint64{}
	}
	f.high[unit] = memoryHigh
	return []string{"env", "PIER_TEST_SCOPE=" + unit}
}

func (f *fakeScopes) Stop(_ context.Context, unit string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stopped = append(f.stopped, unit)
	return nil
}

func (f *fakeScopes) SetMemoryHigh(_ context.Context, unit string, bytes uint64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.high[unit] = bytes
	return nil
}

func (f *fakeScopes) Cgroup(context.Context, string) string { return f.cgroup }

func TestANewSessionRunsInAScopeThatGoesWithIt(t *testing.T) {
	s := testSessions(t)
	cg := t.TempDir()
	for name, v := range map[string]string{
		"memory.current": strconv.FormatUint(11<<30+800<<20, 10), "memory.high": strconv.FormatUint(12<<30, 10),
		"cpu.stat": "usage_usec 4500000\nuser_usec 4000000\n", "memory.events": "low 0\nhigh 7\nmax 0\n", "cgroup.procs": "10\n11\n12\n",
	} {
		os.WriteFile(filepath.Join(cg, name), []byte(v), 0o644)
	}
	scopes := &fakeScopes{cgroup: cg}
	s.Scopes = scopes
	s.MemoryHigh = func() uint64 { return 12 << 30 }
	ctx := context.Background()
	dir := t.TempDir()
	sess, err := s.Create(ctx, "acme-scoped", "acme/checkout", dir, `echo "$PIER_TEST_SCOPE" > scope.txt; sleep 30`, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(sess.Scope, "pier-acme-scoped-") || !strings.HasSuffix(sess.Scope, ".scope") {
		t.Fatalf("scope = %q", sess.Scope)
	}
	if scopes.high[sess.Scope] != 12<<30 {
		t.Fatalf("the scope's ceiling = %d", scopes.high[sess.Scope])
	}
	// The session's program ran inside what the scope manager wrapped.
	deadline := time.Now().Add(5 * time.Second)
	for {
		b, _ := os.ReadFile(filepath.Join(dir, "scope.txt"))
		if strings.TrimSpace(string(b)) == sess.Scope {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the program did not run in the scope: %q", b)
		}
		time.Sleep(50 * time.Millisecond)
	}
	u, ok := s.scopeUsage(ctx, sess)
	if !ok || !u.Scoped || u.Memory != 11<<30+800<<20 || u.MemoryHigh != 12<<30 || u.CPUSeconds != 4.5 || u.Throttled != 7 || u.Processes != 3 || !u.NearLimit {
		t.Fatalf("usage = %+v", u)
	}
	s.ApplyMemoryHigh(ctx, 0)
	if scopes.high[sess.Scope] != 0 {
		t.Fatal("a changed ceiling did not reach the running scope")
	}
	if err := s.Kill(ctx, sess.Name); err != nil {
		t.Fatal(err)
	}
	s.WaitCleanup()
	if len(scopes.stopped) != 1 || scopes.stopped[0] != sess.Scope {
		t.Fatalf("stopped %v", scopes.stopped)
	}
}

func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	if err := syscall.Kill(pid, 0); err != nil {
		return false
	}
	// A zombie no one reaped yet has ended too.
	if b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil {
		if i := strings.LastIndexByte(string(b), ')'); i > 0 && strings.HasPrefix(strings.TrimSpace(string(b[i+1:])), "Z") {
			return false
		}
	}
	return true
}

func readPID(t *testing.T, file string) int {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(file); err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && n > 0 {
				return n
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("no pid in %s", file)
	return 0
}

// Without a scope, ending a session stops what pierd finds for it: its
// pane's descendants and, on Linux, what double-forked away but carries
// its marker. Its neighbour's processes stay.
func TestEndingASessionStopsWhatItStartedWithoutAScope(t *testing.T) {
	s := testSessions(t)
	ctx := context.Background()
	dir := t.TempDir()
	command := `sleep 600 & echo $! > kid.pid; `
	double := runtime.GOOS == "linux"
	if double {
		if _, err := exec.LookPath("setsid"); err != nil {
			double = false
		}
	}
	if double {
		command += `(setsid sh -c 'echo $$ > orphan.pid; exec sleep 601' &); `
	}
	command += `sleep 600`
	if _, err := s.Create(ctx, "acme-tests", "acme/checkout", dir, command, nil); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if _, err := s.Create(ctx, "acme-other", "acme/search", other, `sleep 600 & echo $! > kid.pid; sleep 600`, nil); err != nil {
		t.Fatal(err)
	}
	kid := readPID(t, filepath.Join(dir, "kid.pid"))
	neighbour := readPID(t, filepath.Join(other, "kid.pid"))
	orphan := 0
	if double {
		orphan = readPID(t, filepath.Join(dir, "orphan.pid"))
		if !alive(orphan) {
			t.Fatal("the double-forked child is not running")
		}
	}
	if !alive(kid) {
		t.Fatal("the child is not running")
	}
	t.Cleanup(func() {
		for _, pid := range []int{kid, orphan, neighbour} {
			if alive(pid) {
				syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})
	if err := s.Kill(ctx, "acme-tests"); err != nil {
		t.Fatal(err)
	}
	s.WaitCleanup()
	deadline := time.Now().Add(5 * time.Second)
	for (alive(kid) || alive(orphan)) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if alive(kid) {
		t.Fatal("the session's child outlived it")
	}
	if double && alive(orphan) {
		t.Fatal("the double-forked child outlived the session")
	}
	if !alive(neighbour) {
		t.Fatal("ending one session stopped another's process")
	}
}

// With the box's real systemd user manager (PIER_TEST_SYSTEMD=1): the
// session runs in a scope, its cgroup says what it uses, and ending it
// stops a double-forked child.
func TestASessionsScopeWithRealSystemd(t *testing.T) {
	if os.Getenv("PIER_TEST_SYSTEMD") == "" {
		t.Skip("set PIER_TEST_SYSTEMD=1 on a box with a systemd user manager")
	}
	scopes := NewSystemdScopes()
	if scopes == nil || !scopes.Available(context.Background()) {
		t.Fatal("no systemd user scopes here")
	}
	s := testSessions(t)
	s.Scopes = scopes
	s.MemoryHigh = func() uint64 { return 1 << 30 }
	ctx := context.Background()
	dir := t.TempDir()
	sess, err := s.Create(ctx, "acme-systemd", "acme/checkout", dir, `(setsid sh -c 'echo $$ > orphan.pid; exec sleep 602' &); cat /proc/self/cgroup > cgroup.txt; sleep 600`, nil)
	if err != nil {
		t.Fatal(err)
	}
	orphan := readPID(t, filepath.Join(dir, "orphan.pid"))
	t.Cleanup(func() {
		if alive(orphan) {
			syscall.Kill(orphan, syscall.SIGKILL)
		}
	})
	cg, _ := os.ReadFile(filepath.Join(dir, "cgroup.txt"))
	if !strings.Contains(string(cg), sess.Scope) {
		t.Fatalf("the program's cgroup is %q, not in %s", cg, sess.Scope)
	}
	got, _ := s.Get(ctx, sess.Name)
	u, ok := s.scopeUsage(ctx, got)
	if !ok || u.Memory == 0 || u.MemoryHigh != 1<<30 || u.Processes < 2 {
		t.Fatalf("usage = %+v %v", u, ok)
	}
	t.Logf("scope %s: %+v", sess.Scope, u)
	if err := s.Kill(ctx, sess.Name); err != nil {
		t.Fatal(err)
	}
	s.WaitCleanup()
	if alive(orphan) {
		t.Fatal("the double-forked child outlived the session's scope")
	}
	if out, _ := exec.Command("systemctl", "--user", "is-active", sess.Scope).Output(); strings.TrimSpace(string(out)) == "active" {
		t.Fatal("the scope still runs")
	}
}

func TestSessionProcsFollowsTheTreeAndTheMarker(t *testing.T) {
	socket := "/tmp/tmux-501/pier"
	at := time.Now()
	mk := func(pid, ppid int, env map[string]string, started time.Time) procStat {
		return procStat{PID: pid, PPID: ppid, Env: env, Start: started, StartKey: uint64(pid)}
	}
	marked := map[string]string{"PIER_SESSION": "acme", "TMUX": socket + ",1,0"}
	otherServer := map[string]string{"PIER_SESSION": "acme", "TMUX": "/tmp/tmux-501/default,1,0"}
	ps := []procStat{
		mk(10, 1, marked, at.Add(-time.Hour)),      // pane
		mk(11, 10, marked, at.Add(-time.Hour)),     // its child
		mk(12, 1, marked, at.Add(-time.Hour)),      // double-forked
		mk(13, 12, nil, at.Add(-time.Hour)),        // its child, environment cleared
		mk(14, 1, marked, at.Add(time.Second)),     // a new session of the same name
		mk(15, 1, otherServer, at.Add(-time.Hour)), // the user's own tmux
		mk(16, 1, nil, at.Add(-time.Hour)),
	}
	pids := func(ps []procStat) (out []int) {
		for _, p := range ps {
			out = append(out, p.PID)
		}
		return out
	}
	if got := pids(sessionProcs(ps, "acme", []int{10}, socket, at, false)); len(got) != 2 || got[0] != 10 || got[1] != 11 {
		t.Fatalf("tree only: %v", got)
	}
	got := pids(sessionProcs(ps, "acme", []int{10}, socket, at, true))
	if len(got) != 4 || got[2] != 12 || got[3] != 13 {
		t.Fatalf("tree and marker: %v", got)
	}
}
