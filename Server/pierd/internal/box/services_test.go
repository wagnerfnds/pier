package box

import (
	"os"
	"path/filepath"
	"testing"
)

func TestServicesBelongToTheDeepestWorktreeContainingTheProcess(t *testing.T) {
	locations := []Location{
		{Name: "cal", Path: "/w/cal", Repo: true, Worktrees: []Worktree{
			{Name: "cal", Path: "/w/cal", Main: true},
			{Name: "billing", Path: "/w/cal-billing"},
			{Name: "fix", Path: "/w/orca/cal/fix"},
		}},
		{Name: "scratch", Path: "/w/scratch"},
	}
	ports := []Port{
		{Port: 3000, Dir: "/w/cal/apps/web", Command: "next dev"},
		{Port: 3100, Dir: "/w/cal-billing/apps/web"},
		{Port: 3200, Dir: "/w/orca/cal/fix"},
		{Port: 4000, Dir: "/w/scratch/tool"},
		{Port: 5432, Dir: "/var/lib/postgresql"},
		{Port: 6000},
	}
	got := Services(ports, locations)
	want := []Service{
		{Location: "cal", Worktree: "cal", Path: "/w/cal", Port: 3000, Process: "next dev", Main: true},
		{Location: "cal", Worktree: "billing", Path: "/w/cal-billing", Port: 3100},
		{Location: "cal", Worktree: "fix", Path: "/w/orca/cal/fix", Port: 3200},
		{Location: "scratch", Worktree: "scratch", Path: "/w/scratch", Port: 4000, Main: true},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("service %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestAPrefixThatIsNotAPathBoundaryDoesNotMatch(t *testing.T) {
	// /w/cal must not claim /w/cal-billing just because the string matches.
	got := Services([]Port{{Port: 3100, Dir: "/w/cal-billing"}}, []Location{{Name: "cal", Path: "/w/cal", Repo: true, Worktrees: []Worktree{{Name: "cal", Path: "/w/cal", Main: true}}}})
	if len(got) != 0 {
		t.Fatalf("a sibling directory was claimed: %+v", got)
	}
}

func TestAPortInAWorktreesBlockIsThatWorktreesWhereverItRuns(t *testing.T) {
	locs := []Location{{Name: "cal", Repo: true, Worktrees: []Worktree{{Name: "billing", Path: "/w/cal-billing", Port: 41010}}}}
	got := Services([]Port{{Port: 41012, Dir: "/var/lib/docker"}, {Port: 41020}}, locs)
	if len(got) != 1 || got[0].Worktree != "billing" || got[0].Port != 41012 {
		t.Fatalf("services = %+v", got)
	}
}

// macOS gives pierd a port's program but not its command line: the server
// is still named, so the app can tell a dev server from a helper.
func TestAServerWithoutACommandLineIsNamedByItsProgram(t *testing.T) {
	locs := []Location{{Name: "demo", Repo: true, Worktrees: []Worktree{{Name: "fix", Path: "/w/demo-fix", Port: 41020}}}}
	got := Services([]Port{{Port: 41020, Process: "Python"}, {Port: 41021, Process: "node", Command: "node server.js"}}, locs)
	if len(got) != 2 || got[0].Process != "Python" || got[1].Process != "node server.js" {
		t.Fatalf("services = %+v", got)
	}
}

// macOS reports a process's folder with symlinks resolved (/private/tmp for
// /tmp), so a worktree under a symlink still owns the server running in it.
func TestAServerInAWorktreeReachedThroughASymlinkIsThatWorktrees(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "hello-health"), 0o755)
	link := filepath.Join(t.TempDir(), "work")
	if err := os.Symlink(dir, link); err != nil {
		t.Skip(err)
	}
	resolved, _ := filepath.EvalSymlinks(filepath.Join(dir, "hello-health"))
	locs := []Location{{Name: "hello", Repo: true, Worktrees: []Worktree{{Name: "health", Path: filepath.Join(link, "hello-health"), Port: 41010}}}}
	got := Services([]Port{{Port: 3000, Dir: resolved}}, locs)
	if len(got) != 1 || got[0].Worktree != "health" || got[0].Path != filepath.Join(link, "hello-health") {
		t.Fatalf("services = %+v", got)
	}
}
