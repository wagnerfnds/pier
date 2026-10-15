package box

import (
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A worktree made with prepare: false is a bare checkout (no setup, said to
// be skipped) until POST .../prepare runs its setup, which a second POST
// cannot start twice; one made without the field is prepared as before.
func TestWorktreeMadeWithoutPreparingIsPreparedLater(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := gitRepo(t)
	marker := filepath.Join(t.TempDir(), "setup-ran")
	// Slow enough for the second POST to find it still running.
	writeRepoConfig(t, repo, RepoConfig{Setup: "sleep 1; echo \"$PWD\" >> " + marker})
	c, bus := servedBox(t, func(b *Box) { b.LogDir = t.TempDir() })
	ch, stop := bus.Subscribe()
	defer stop()
	if call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil) != 200 {
		t.Fatal("add location")
	}
	var cfg Config
	call(t, c, "GET", "/v1/locations/cal/config", "", nil, &cfg)
	if call(t, c, "POST", "/v1/locations/cal/config/trust", "", map[string]string{"hash": cfg.RepoTrust.Hash}, nil) != 200 {
		t.Fatal("trust")
	}

	var wt Worktree
	if code := call(t, c, "POST", "/v1/locations/cal/worktrees", "", map[string]any{"name": "quick", "prepare": false}, &wt); code != 200 {
		t.Fatalf("create = %d", code)
	}
	var st PrepareStatus
	if code := call(t, c, "GET", "/v1/locations/cal/worktrees/quick/prepare", "", nil, &st); code != 200 || st.State != "skipped" || st.Setup == "" || st.Since == nil {
		t.Fatalf("status after prepare:false = %d %+v", code, st)
	}
	time.Sleep(1500 * time.Millisecond)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("setup ran for a worktree made with prepare: false")
	}

	if code := call(t, c, "POST", "/v1/locations/cal/worktrees/quick/prepare", "", nil, &st); code != http.StatusAccepted || st.State != "running" {
		t.Fatalf("prepare = %d %+v", code, st)
	}
	if code := call(t, c, "POST", "/v1/locations/cal/worktrees/quick/prepare", "", nil, nil); code != http.StatusConflict {
		t.Fatalf("a second prepare while the first runs gave %d", code)
	}
	waitFor(t, ch, "worktree.prepare.finished")
	if call(t, c, "GET", "/v1/locations/cal/worktrees/quick/prepare", "", nil, &st); st.State != "ready" {
		t.Fatalf("status after prepare = %+v", st)
	}
	if got, err := os.ReadFile(marker); err != nil || string(got) != wt.Path+"\n" {
		t.Fatalf("setup ran %q (%v), want once in %s", got, err, wt.Path)
	}

	// Without the field: prepared on creation, as before.
	if code := call(t, c, "POST", "/v1/locations/cal/worktrees", "", map[string]any{"name": "full"}, nil); code != 200 {
		t.Fatalf("create = %d", code)
	}
	waitFor(t, ch, "worktree.prepare.finished")
	if call(t, c, "GET", "/v1/locations/cal/worktrees/full/prepare", "", nil, &st); st.State != "ready" {
		t.Fatalf("a worktree made without prepare:false = %+v", st)
	}
	if code := call(t, c, "GET", "/v1/locations/cal/worktrees/nope/prepare", "", nil, nil); code != http.StatusNotFound {
		t.Fatalf("an unknown worktree gave %d", code)
	}
}

// A failing setup is reported as failed, with what went wrong.
func TestPrepareReportsAFailedSetup(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := gitRepo(t)
	writeRepoConfig(t, repo, RepoConfig{Setup: "echo no node here >&2; exit 4"})
	c, bus := servedBox(t, func(b *Box) { b.LogDir = t.TempDir() })
	ch, stop := bus.Subscribe()
	defer stop()
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	var cfg Config
	call(t, c, "GET", "/v1/locations/cal/config", "", nil, &cfg)
	call(t, c, "POST", "/v1/locations/cal/config/trust", "", map[string]string{"hash": cfg.RepoTrust.Hash}, nil)
	call(t, c, "POST", "/v1/locations/cal/worktrees", "", map[string]any{"name": "broken"}, nil)
	waitFor(t, ch, "worktree.prepare.failed")
	var st PrepareStatus
	call(t, c, "GET", "/v1/locations/cal/worktrees/broken/prepare", "", nil, &st)
	if st.State != "failed" || st.Error == "" {
		t.Fatalf("status = %+v", st)
	}
}
