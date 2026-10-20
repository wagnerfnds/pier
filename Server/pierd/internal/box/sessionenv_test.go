package box

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// A session's secret variables reach its program through a file pierd
// reads and deletes, never tmux's command line, where every user of the box
// could read them; pierd's own variables and the account folders stay in
// tmux, which pierd reads them back from.
func TestASessionsSecretsNeverGoOnTmuxsCommandLine(t *testing.T) {
	s := testSessions(t)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	s.Exe = self
	var mu sync.Mutex
	var lines []string
	s.trace = func(args []string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, strings.Join(args, " "))
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "seen")
	ctx := context.Background()
	sess, err := s.Create(ctx, "secret-env", "cal", dir, `printf '%s|%s' "$STRIPE_SECRET" "$PIER_MCP_SHOP_TOKEN" > `+out+`; sleep 30`,
		[]string{"STRIPE_SECRET=sk_test_hunter2", "PIER_MCP_SHOP_TOKEN=mcp-token-xyz", "CODEX_HOME=/w/codex", "PIER_WORKTREE_NAME=cal"})
	if err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the session's program saw its variables", 10*time.Second, func() bool {
		b, _ := os.ReadFile(out)
		return string(b) == "sk_test_hunter2|mcp-token-xyz"
	})
	mu.Lock()
	all := strings.Join(lines, "\n")
	mu.Unlock()
	if strings.Contains(all, "hunter2") || strings.Contains(all, "mcp-token-xyz") {
		t.Fatalf("a secret went on tmux's command line:\n%s", all)
	}
	if !strings.Contains(all, "PIER_WORKTREE_NAME=cal") || !strings.Contains(all, "env-exec") {
		t.Fatalf("pierd's own variables or the env-exec wrapper are missing:\n%s", all)
	}
	if v := s.EnvVar(ctx, sess, "CODEX_HOME"); v != "/w/codex" {
		t.Fatalf("the account folder read back as %q", v)
	}
	entries, _ := os.ReadDir(s.Commands)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".env-") {
			t.Fatalf("the variables' file stayed: %s", e.Name())
		}
	}
}

func TestOnlyPierdsOwnVariablesAndAccountFoldersArePublic(t *testing.T) {
	public, secret := splitSessionEnv([]string{"PIER_PORT=41000", "PIER_MCP_X_TOKEN=t", "CLAUDE_CONFIG_DIR=/a", "DB_PASSWORD=p", "API_KEY=k", "PATH=/bin"})
	if strings.Join(public, " ") != "PIER_PORT=41000 CLAUDE_CONFIG_DIR=/a PATH=/bin" {
		t.Fatalf("public = %v", public)
	}
	if strings.Join(secret, " ") != "PIER_MCP_X_TOKEN=t DB_PASSWORD=p API_KEY=k" {
		t.Fatalf("secret = %v", secret)
	}
}
