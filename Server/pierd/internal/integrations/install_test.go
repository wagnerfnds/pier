package integrations

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// commands lists every hook command under event, in Claude's nested shape.
func commands(t *testing.T, hooks map[string]any, event string) []string {
	t.Helper()
	var out []string
	list, _ := hooks[event].([]any)
	for _, item := range list {
		inner, _ := item.(map[string]any)["hooks"].([]any)
		for _, h := range inner {
			out = append(out, h.(map[string]any)["command"].(string))
		}
	}
	return out
}

func TestClaudeHooksKeepExistingSettings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	os.WriteFile(path, []byte(`{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`), 0o644)
	if _, err := InstallClaudeHooks(path, "/home/alex/.local/bin/pierd"); err != nil {
		t.Fatal(err)
	}
	root := readJSON(t, path)
	if root["model"] != "opus" {
		t.Fatal("an existing setting was lost")
	}
	hooks := root["hooks"].(map[string]any)
	if stop := commands(t, hooks, "Stop"); len(stop) != 2 || stop[0] != "say done" || stop[1] != "/home/alex/.local/bin/pierd hook claude Stop" {
		t.Fatalf("Stop hooks = %v", stop)
	}
	for _, event := range ClaudeHookEvents {
		if len(commands(t, hooks, event)) == 0 {
			t.Errorf("%s hook missing", event)
		}
	}
	if changed, _ := InstallClaudeHooks(path, "/home/alex/.local/bin/pierd"); changed {
		t.Fatal("a second install changed the file again")
	}
	if backup, err := os.ReadFile(path + ".pier-backup"); err != nil || !strings.Contains(string(backup), "say done") {
		t.Fatalf("backup = %q, %v", backup, err)
	}
}

// pierd's notify from another path is moved to this one; anyone else's is
// left alone.
func TestCodexNotifyIsAddedOrTakesOverPierdsOnly(t *testing.T) {
	dir := t.TempDir()
	config := filepath.Join(dir, "config.toml")
	moved := "notify = [\"/home/alex/.local/bin/pierd\", \"hook\", \"codex\", \"notify\"]\n\n[tui]\ntheme = \"dark\"\n"
	os.WriteFile(config, []byte(moved), 0o600)
	if changed, err := InstallCodexNotify(config, "/usr/local/bin/pierd"); !changed || err != nil {
		t.Fatalf("replace: %v %v", changed, err)
	}
	b, _ := os.ReadFile(config)
	got := string(b)
	if !strings.HasPrefix(got, `notify = ["/usr/local/bin/pierd", "hook", "codex", "notify"]`) || strings.Contains(got, ".local/bin/pierd") ||
		!strings.Contains(got, "[tui]\ntheme = \"dark\"") {
		t.Fatalf("config.toml = %q", got)
	}
	if st, _ := os.Stat(config); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode changed to %v", st.Mode().Perm())
	}
	if changed, _ := InstallCodexNotify(config, "/usr/local/bin/pierd"); changed {
		t.Fatal("a second install changed the file again")
	}

	other := filepath.Join(dir, "other.toml")
	os.WriteFile(other, []byte("notify = [\"terminal-notifier\"]\n"), 0o600)
	if _, err := InstallCodexNotify(other, "/usr/local/bin/pierd"); !errors.Is(err, ErrNotifyTaken) {
		t.Fatalf("someone else's notify: %v", err)
	}

	fresh := filepath.Join(dir, "fresh", "config.toml")
	if changed, err := InstallCodexNotify(fresh, "pierd"); !changed || err != nil {
		t.Fatalf("missing config: %v %v", changed, err)
	}
}

func TestInstallCreatesMissingFilesAndRefusesBrokenOnes(t *testing.T) {
	dir := t.TempDir()
	if _, err := InstallClaudeHooks(filepath.Join(dir, "new", "settings.json"), "pierd"); err != nil {
		t.Fatalf("missing settings file: %v", err)
	}
	broken := filepath.Join(dir, "broken.json")
	os.WriteFile(broken, []byte("{ not json"), 0o644)
	if _, err := InstallCodexHooks(broken, "pierd"); err == nil {
		t.Fatal("rewrote a file that is not JSON")
	}
	if b, _ := os.ReadFile(broken); string(b) != "{ not json" {
		t.Fatal("a broken file was modified")
	}
}

func TestQuotedBinaryPaths(t *testing.T) {
	if got := hookCommand("/Users/alex/Application Support/pierd", "claude", "Stop"); got != "'/Users/alex/Application Support/pierd' hook claude Stop" {
		t.Fatalf("hookCommand = %q", got)
	}
}

func TestHookedFindsPierdsHooks(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	claude, _ := toolByID("claude")
	if claude.Hooked(home) {
		t.Fatal("hooks found in an empty home")
	}
	settings := filepath.Join(home, ".claude", "settings.json")
	os.MkdirAll(filepath.Dir(settings), 0o755)
	os.WriteFile(settings, []byte(`{"hooks":{"Stop":[{"hooks":[{"command":"say done"}]}]}}`), 0o644)
	if claude.Hooked(home) {
		t.Fatal("another program's hook counted as pierd's")
	}
	if _, err := InstallClaudeHooks(settings, "/x/pierd"); err != nil {
		t.Fatal(err)
	}
	if !claude.Hooked(home) {
		t.Fatal("pierd's hooks not found after install")
	}
}

func TestHookSessionReadsPierSession(t *testing.T) {
	t.Setenv("TMUX", "")
	t.Setenv(SessionEnv, "")
	if got := hookSession(); got != "" {
		t.Fatalf("without PIER_SESSION: %q", got)
	}
	t.Setenv(SessionEnv, "new-name")
	if got := hookSession(); got != "new-name" {
		t.Fatalf("with PIER_SESSION: %q", got)
	}
	t.Setenv(SessionEnv, "bad name!")
	if got := hookSession(); got != "" {
		t.Fatalf("an invalid name was used: %q", got)
	}
}
