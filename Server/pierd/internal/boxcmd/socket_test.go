package boxcmd

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/events"
	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/wire"
)

// socketBox serves a box on a Unix socket, as pierd serve does for the box's
// own user, with a location "cal" (a git repository), and returns a client
// for it.
func socketBox(t *testing.T) *box.Client {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	// The agents' settings that pierd trusts a new folder in are a scratch
	// home's, never those of the machine running the test.
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("CODEX_HOME", "")
	dir := t.TempDir()
	id, err := identity.LoadOrCreate(filepath.Join(dir, "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	srv := &wire.Server{Identity: id, Clients: trust.NewStore(filepath.Join(dir, "clients.json")), Pending: pairing.NewPending(filepath.Join(dir, "pairing.json")), Name: "devbox"}
	bx := &box.Box{Name: "devbox", Locations: box.NewLocations(filepath.Join(dir, "locations.json")), Events: &events.Bus{Sequence: true}, StateDir: dir}
	bx.Mount(srv)
	// A socket's path is short on every system: not under the test's folder.
	sockDir, err := os.MkdirTemp("/tmp", "pbc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(sockDir) })
	sock := filepath.Join(sockDir, "pierd.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ServeLocal(ctx, ln)

	root, _ := filepath.EvalSymlinks(t.TempDir())
	repo := filepath.Join(root, "cal")
	os.MkdirAll(repo, 0o755)
	for _, args := range [][]string{{"init", "-q", "-b", "main"}, {"commit", "-q", "--allow-empty", "-m", "init"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
	}
	c := box.NewClient(box.NewLocal(sock))
	runOK(t, c, "location", "add", "cal", repo)
	return c
}

func runOK(t *testing.T, c *box.Client, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run(context.Background(), c, args, &out); err != nil {
		t.Fatalf("%v: %v (%s)", args, err, out.String())
	}
	return out.String()
}

// What an agent runs from inside a worktree, through the box's own socket:
// its preview set a key at a time and read back, its preparation's state and
// wait, a report no setup agent asked for refused, and a recipe merged into
// the location's config from stdin.
func TestPreviewAndPrepareThroughTheLocalSocket(t *testing.T) {
	c := socketBox(t)
	// Made with its code only: nothing here may start a setup agent.
	var wt box.Worktree
	json.Unmarshal([]byte(runOK(t, c, "worktree", "new", "cal/login", "--prepare-with", "none", "--json")), &wt)
	if wt.Port == 0 {
		t.Skip("no port block on this machine")
	}
	// In the worktree's own session: no LOC/WORKTREE needed.
	t.Setenv("PIER_LOCATION", "cal")
	t.Setenv("PIER_WORKTREE_NAME", "login")

	runOK(t, c, "preview", "set", "--port", strconv.Itoa(wt.Port), "--path", "/login", "--user", "demo@example.com", "--password", "demo-pw")
	runOK(t, c, "preview", "set", "--note", "seeded by the setup agent")
	var p box.Preview
	if err := json.Unmarshal([]byte(runOK(t, c, "preview", "get", "--json")), &p); err != nil {
		t.Fatal(err)
	}
	if p.Port != wt.Port || p.Path != "/login" || p.Login == nil || p.Login.User != "demo@example.com" || p.Login.Password != "demo-pw" || p.Note != "seeded by the setup agent" {
		t.Fatalf("preview = %+v", p)
	}
	if out := runOK(t, c, "preview", "get", "cal/login"); !strings.Contains(out, "demo@example.com / demo-pw") || !strings.Contains(out, "/login") {
		t.Fatalf("preview get = %s", out)
	}

	if out := runOK(t, c, "prepare", "status"); !strings.HasPrefix(out, "skipped") {
		t.Fatalf("prepare status = %s", out)
	}
	// Nothing runs: wait answers at once.
	start := time.Now()
	runOK(t, c, "prepare", "wait", "--timeout", "5s")
	if time.Since(start) > 3*time.Second {
		t.Fatal("wait waited for a worktree nothing prepares")
	}
	if err := Run(context.Background(), c, []string{"prepare", "done"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "not being prepared by a setup agent") {
		t.Fatalf("done without a setup agent = %v", err)
	}
	// Prepared now by its (empty) script, then waited for.
	runOK(t, c, "prepare", "start", "--with", "script")
	if out := runOK(t, c, "prepare", "wait", "cal/login", "--timeout", "20s"); !strings.HasPrefix(out, "ready") {
		t.Fatalf("prepare wait = %s", out)
	}

	// A recipe merged in from stdin, then more of it: both kept.
	stdin = strings.NewReader(`{"setup": "composer install", "preview": {"path": "/admin", "login": {"user": "admin@example.com", "password": "admin-pw"}}}`)
	t.Cleanup(func() { stdin = os.Stdin })
	runOK(t, c, "location", "config", "cal", "--merge", "-")
	stdin = strings.NewReader(`{"services": [{"name": "web", "run": "php artisan serve --host=0.0.0.0 --port=$PIER_PORT", "autostart": true}]}`)
	var cfg box.Config
	json.Unmarshal([]byte(runOK(t, c, "location", "config", "cal", "--merge", "-", "--json")), &cfg)
	if cfg.Local.Setup != "composer install" || len(cfg.Local.Services) != 1 || cfg.Local.Preview == nil || cfg.Local.Preview.Login.User != "admin@example.com" {
		t.Fatalf("merged config = %+v", cfg.Local)
	}
	if out := runOK(t, c, "location", "config", "cal"); !strings.Contains(out, "preview   /admin (test login admin@example.com)") {
		t.Fatalf("location config = %s", out)
	}
	if cfg.Local.By != "" {
		t.Fatalf("a person's recipe is marked %q", cfg.Local.By)
	}

	// In a setup agent's session (PIER_SETUP): the recipe it saves is marked
	// as a setup agent's, and saving one never gives the consent to setup
	// agents; it is the preparation, so it never waits for one or starts
	// another.
	t.Setenv("PIER_SETUP", "1")
	stdin = strings.NewReader(`{"setup": "composer install && php artisan migrate", "prepare_with": "agent"}`)
	cfg = box.Config{}
	json.Unmarshal([]byte(runOK(t, c, "location", "config", "cal", "--merge", "-", "--json")), &cfg)
	if cfg.Local.By != "setup" || cfg.Local.PrepareWith != "" {
		t.Fatalf("a setup agent's recipe = %+v", cfg.Local)
	}
	if out := runOK(t, c, "prepare", "wait"); !strings.Contains(out, "nothing to wait for") {
		t.Fatalf("a setup agent waiting for itself = %s", out)
	}
	if err := Run(context.Background(), c, []string{"prepare", "start", "--with", "script"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "replace you") {
		t.Fatalf("a setup agent starting another preparation = %v", err)
	}
	// Anywhere else, "by" is not the sender's to claim.
	t.Setenv("PIER_SETUP", "")
	stdin = strings.NewReader(`{"setup": "make setup", "by": "setup"}`)
	cfg = box.Config{}
	json.Unmarshal([]byte(runOK(t, c, "location", "config", "cal", "--merge", "-", "--json")), &cfg)
	if cfg.Local.By != "" || cfg.Local.Setup != "make setup" {
		t.Fatalf("a recipe claimed for a setup agent = %+v", cfg.Local)
	}

	// Outside a worktree, a command needs to be told which.
	t.Setenv("PIER_LOCATION", "")
	if err := Run(context.Background(), c, []string{"prepare", "status"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "LOC/WORKTREE") {
		t.Fatalf("status outside a worktree = %v", err)
	}
	runOK(t, c, "preview", "set", "cal/login", "--clear")
	var cleared box.Preview
	json.Unmarshal([]byte(runOK(t, c, "preview", "get", "cal/login", "--json")), &cleared)
	if cleared.Port != 0 || cleared.Login != nil || cleared.Note != "" {
		t.Fatalf("after --clear = %+v", cleared)
	}
}
