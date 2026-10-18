package integrations

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func readConfig(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	root, err := decodeObject(raw)
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func project(t *testing.T, root map[string]any, dir string) map[string]any {
	t.Helper()
	p, _ := root["projects"].(map[string]any)[dir].(map[string]any)
	if p == nil {
		t.Fatalf("no project entry for %s in %v", dir, root["projects"])
	}
	return p
}

func TestTrustClaudeProjectInAFreshConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "account", ".claude.json")
	changed, err := TrustClaudeProject(path, "/home/octocat/code/shop", "/home/octocat/code/shop-fix")
	if err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("a new config must be private: %v %v", st.Mode(), err)
	}
	root := readConfig(t, path)
	for _, dir := range []string{"/home/octocat/code/shop", "/home/octocat/code/shop-fix"} {
		p := project(t, root, dir)
		if p["hasTrustDialogAccepted"] != true {
			t.Errorf("%s not trusted: %v", dir, p)
		}
		// The fields Claude Code's own entry has, so its readers find them.
		if _, ok := p["allowedTools"].([]any); !ok {
			t.Errorf("%s has no allowedTools: %v", dir, p)
		}
	}
	if _, err := os.Stat(path + ".lock"); !os.IsNotExist(err) {
		t.Fatal("the lock was left behind")
	}
	if changed, _ := TrustClaudeProject(path, "/home/octocat/code/shop"); changed {
		t.Fatal("a trusted folder was written again")
	}
}

// A new worktree takes the answer its person gave Claude Code about the
// repository's MCP servers in the project's main checkout; a folder that
// answered keeps its own, and nothing is made up where nobody answered.
func TestCarryClaudeMcpChoiceToANewWorktree(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude.json")
	main, wt, other := "/home/octocat/code/shop", "/home/octocat/code/shop-fix", "/home/octocat/code/shop-old"
	if _, err := TrustClaudeProject(path, main, wt, other); err != nil {
		t.Fatal(err)
	}
	if changed, err := CarryClaudeMcpChoice(path, []string{wt}, []string{main, other}); err != nil || changed {
		t.Fatalf("with no answer anywhere: changed %v, err %v", changed, err)
	}
	if _, err := EditClaudeConfig(path, func(root map[string]any) bool {
		projects := root["projects"].(map[string]any)
		projects[main].(map[string]any)["enabledMcpjsonServers"] = []any{"laravel-boost", "herd"}
		projects[main].(map[string]any)["disabledMcpjsonServers"] = []any{"chrome-devtools"}
		projects[other].(map[string]any)["disabledMcpjsonServers"] = []any{"herd"}
		return true
	}); err != nil {
		t.Fatal(err)
	}
	if changed, err := CarryClaudeMcpChoice(path, []string{wt, other}, []string{main, other}); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	root := readConfig(t, path)
	got := project(t, root, wt)
	if fmt.Sprint(got["enabledMcpjsonServers"]) != "[laravel-boost herd]" || fmt.Sprint(got["disabledMcpjsonServers"]) != "[chrome-devtools]" {
		t.Errorf("the worktree's answer = %v / %v", got["enabledMcpjsonServers"], got["disabledMcpjsonServers"])
	}
	if mine := project(t, root, other); fmt.Sprint(mine["disabledMcpjsonServers"]) != "[herd]" || len(mine["enabledMcpjsonServers"].([]any)) != 0 {
		t.Errorf("a folder's own answer was replaced: %v", mine)
	}
	if got["hasTrustDialogAccepted"] != true {
		t.Errorf("the trust was lost: %v", got)
	}
}

func TestTrustClaudeProjectKeepsEverythingElse(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude.json")
	// Large integers must keep their digits (a float64 would round them).
	before := `{"numStartups": 42, "userID": "abc", "big": 123456789012345678901,
 "oauthAccount": {"accountUuid": "u-1", "organizationUuid": "o-1"},
 "projects": {
  "/home/octocat/code/other": {"allowedTools": ["Bash(ls)"], "hasTrustDialogAccepted": true, "lastCost": 0.25},
  "/home/octocat/code/shop": {"allowedTools": [], "hasTrustDialogAccepted": false, "lastSessionId": "s-1", "lastStartTime": 1792196805058}
 }}`
	if err := os.WriteFile(path, []byte(before), 0o644); err != nil {
		t.Fatal(err)
	}
	if changed, err := TrustClaudeProject(path, "/home/octocat/code/shop"); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "123456789012345678901") || !strings.Contains(string(raw), "1792196805058") {
		t.Fatalf("a large number lost its digits:\n%s", raw)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v, want the file's own 0644", st.Mode().Perm())
	}
	root := readConfig(t, path)
	if root["userID"] != "abc" || root["numStartups"].(json.Number) != "42" {
		t.Fatalf("top-level keys changed: %v", root)
	}
	if acct := root["oauthAccount"].(map[string]any); acct["accountUuid"] != "u-1" {
		t.Fatalf("the account was changed: %v", acct)
	}
	shop := project(t, root, "/home/octocat/code/shop")
	if shop["hasTrustDialogAccepted"] != true || shop["lastSessionId"] != "s-1" {
		t.Fatalf("shop = %v", shop)
	}
	if _, ok := shop["mcpServers"]; ok {
		t.Fatal("an existing entry got fields it did not have")
	}
	other := project(t, root, "/home/octocat/code/other")
	if tools := other["allowedTools"].([]any); len(tools) != 1 || other["lastCost"].(json.Number) != "0.25" {
		t.Fatalf("another project changed: %v", other)
	}
}

func TestTrustClaudeProjectLeavesBrokenConfigAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude.json")
	os.WriteFile(path, []byte(`{"projects": `), 0o600)
	if _, err := TrustClaudeProject(path, "/x"); err == nil {
		t.Fatal("a broken config was not reported")
	}
	if raw, _ := os.ReadFile(path); string(raw) != `{"projects": ` {
		t.Fatalf("a broken config was rewritten: %q", raw)
	}
}

func TestTrustClaudeProjectWritesThroughALink(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "dotfiles", "claude.json")
	os.MkdirAll(filepath.Dir(real), 0o700)
	os.WriteFile(real, []byte(`{"theme":"dark"}`), 0o600)
	link := filepath.Join(dir, ".claude.json")
	if err := os.Symlink(real, link); err != nil {
		t.Skip(err)
	}
	if _, err := TrustClaudeProject(link, "/x"); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Lstat(link); err != nil || st.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the link was replaced by a file")
	}
	if p := project(t, readConfig(t, real), "/x"); p["hasTrustDialogAccepted"] != true {
		t.Fatalf("the linked file was not written: %v", p)
	}
}

// Claude Code's lock is a folder next to the config, touched while held.
func TestTrustClaudeProjectWaitsForClaudesLock(t *testing.T) {
	wait, stale := claudeLockWait, claudeLockStale
	defer func() { claudeLockWait, claudeLockStale = wait, stale }()
	claudeLockWait, claudeLockStale = 300*time.Millisecond, 10*time.Second

	path := filepath.Join(t.TempDir(), ".claude.json")
	os.WriteFile(path, []byte(`{}`), 0o600)
	if err := os.Mkdir(path+".lock", 0o755); err != nil {
		t.Fatal(err)
	}
	// Held for longer than pierd waits: left alone.
	if _, err := TrustClaudeProject(path, "/x"); !errors.Is(err, ErrConfigBusy) {
		t.Fatalf("err = %v, want ErrConfigBusy", err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != `{}` {
		t.Fatalf("written under someone else's lock: %s", raw)
	}
	// Released while pierd waits: written then.
	claudeLockWait = 2 * time.Second
	go func() {
		time.Sleep(150 * time.Millisecond)
		os.Remove(path + ".lock")
	}()
	if changed, err := TrustClaudeProject(path, "/x"); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
}

func TestTrustClaudeProjectTakesOverAStaleLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".claude.json")
	os.WriteFile(path, []byte(`{}`), 0o600)
	lock := path + ".lock"
	os.Mkdir(lock, 0o755)
	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(lock, old, old); err != nil {
		t.Fatal(err)
	}
	if changed, err := TrustClaudeProject(path, "/x"); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	if _, err := os.Stat(lock); !os.IsNotExist(err) {
		t.Fatal("the lock was left behind")
	}
}

func TestClaudeConfigFile(t *testing.T) {
	home := t.TempDir()
	if got := ClaudeConfigFile("", home); got != filepath.Join(home, ".claude.json") {
		t.Errorf("built-in: %s", got)
	}
	acct := filepath.Join(home, "accounts", "claude-1")
	if got := ClaudeConfigFile(acct, home); got != filepath.Join(acct, ".claude.json") {
		t.Errorf("an account: %s", got)
	}
	// An old install's config, read instead when it holds anything.
	os.MkdirAll(filepath.Join(home, ".claude"), 0o700)
	os.WriteFile(filepath.Join(home, ".claude", ".config.json"), []byte(`{"projects":{}}`), 0o600)
	if got := ClaudeConfigFile("", home); got != filepath.Join(home, ".claude", ".config.json") {
		t.Errorf("legacy: %s", got)
	}
}

func TestMarkClaudeOnboardedAndSettings(t *testing.T) {
	dir := t.TempDir()
	config := filepath.Join(dir, ".claude.json")
	if changed, err := MarkClaudeOnboarded(config); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	if readConfig(t, config)["hasCompletedOnboarding"] != true {
		t.Fatal("not marked")
	}
	if changed, _ := MarkClaudeOnboarded(config); changed {
		t.Fatal("marked twice")
	}

	settings := filepath.Join(dir, "settings.json")
	os.WriteFile(settings, []byte(`{"theme":"light","model":"opus"}`), 0o600)
	if changed, err := PrepareClaudeSettings(settings, "dark"); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	s := readJSON(t, settings)
	if s["skipDangerousModePermissionPrompt"] != true || s["theme"] != "light" || s["model"] != "opus" {
		t.Fatalf("settings = %v", s)
	}
	if changed, _ := PrepareClaudeSettings(settings, "dark"); changed {
		t.Fatal("settings written twice")
	}
	// The person turned the warning back on: kept.
	os.WriteFile(settings, []byte(`{"skipDangerousModePermissionPrompt":false}`), 0o600)
	PrepareClaudeSettings(settings, "")
	if s := readJSON(t, settings); s["skipDangerousModePermissionPrompt"] != false {
		t.Fatalf("the person's own choice was overwritten: %v", s)
	}
}

// --- Codex --------------------------------------------------------------

func countTables(text, header string) int { return strings.Count(text, header) }

func TestTrustCodexProjectFreshConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "codex", "config.toml")
	changed, err := TrustCodexProject(path, "/home/octocat/code/shop-fix", "/home/octocat/code/shop")
	if err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	raw, _ := os.ReadFile(path)
	want := "[projects.\"/home/octocat/code/shop-fix\"]\ntrust_level = \"trusted\"\n\n[projects.\"/home/octocat/code/shop\"]\ntrust_level = \"trusted\"\n"
	if string(raw) != want {
		t.Fatalf("config =\n%s\nwant\n%s", raw, want)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode().Perm())
	}
	if changed, _ := TrustCodexProject(path, "/home/octocat/code/shop"); changed {
		t.Fatal("a trusted folder was added again")
	}
	raw, _ = os.ReadFile(path)
	if n := countTables(string(raw), `[projects."/home/octocat/code/shop"]`); n != 1 {
		t.Fatalf("%d tables for one folder: Codex refuses to start on that", n)
	}
}

func TestTrustCodexProjectKnowsEveryWayOfWritingAFolder(t *testing.T) {
	for name, existing := range map[string]string{
		"quoted":          "[projects.\"/srv/shop\"]\ntrust_level = \"untrusted\"\n",
		"spaced":          "[ projects . \"/srv/shop\" ]\ntrust_level = \"trusted\"\n",
		"single-quoted":   "[projects.'/srv/shop']\ntrust_level = \"trusted\"\n",
		"escaped":         "[projects.\"/srv/\\u0073hop\"]\ntrust_level = \"trusted\"\n",
		"dotted in table": "[projects]\n\"/srv/shop\".trust_level = \"trusted\"\n",
		"inline in table": "[projects]\n\"/srv/shop\" = { trust_level = \"trusted\" }\n",
		"dotted at top":   "projects.\"/srv/shop\".trust_level = \"trusted\"\n",
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.toml")
			os.WriteFile(path, []byte(existing), 0o600)
			if changed, err := TrustCodexProject(path, "/srv/shop"); err != nil || changed {
				t.Fatalf("changed %v, err %v", changed, err)
			}
			if raw, _ := os.ReadFile(path); string(raw) != existing {
				t.Fatalf("rewritten:\n%s", raw)
			}
		})
	}
	// A bare key (a folder's name could be one) is found too.
	path := filepath.Join(t.TempDir(), "config.toml")
	os.WriteFile(path, []byte("[projects.shop]\ntrust_level = \"trusted\"\n"), 0o600)
	if changed, _ := TrustCodexProject(path, "shop"); changed {
		t.Fatal("a bare key was not found")
	}
}

func TestTrustCodexProjectLeavesAnInlineTableAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	existing := "model = \"o3\"\nprojects = { \"/srv/other\" = { trust_level = \"trusted\" } }\n"
	os.WriteFile(path, []byte(existing), 0o600)
	if changed, err := TrustCodexProject(path, "/srv/shop"); err != nil || changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	if raw, _ := os.ReadFile(path); string(raw) != existing {
		t.Fatalf("an inline projects table got a table added: Codex would refuse it\n%s", raw)
	}
}

func TestTrustCodexProjectAppendsAfterTheLastLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	existing := "notify = [\"/usr/bin/pierd\", \"hook\", \"codex\", \"notify\"]\nmodel = \"o3\"\n\n[tui]\ntheme = \"dark\""
	os.WriteFile(path, []byte(existing), 0o644)
	if changed, err := TrustCodexProject(path, `/srv/a "quoted" \ folder`); err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	raw, _ := os.ReadFile(path)
	want := existing + "\n\n[projects.\"/srv/a \\\"quoted\\\" \\\\ folder\"]\ntrust_level = \"trusted\"\n"
	if string(raw) != want {
		t.Fatalf("config =\n%q\nwant\n%q", raw, want)
	}
	if b, err := os.ReadFile(path + ".pier-backup"); err != nil || string(b) != existing {
		t.Fatalf("no backup of the previous config: %v", err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v", st.Mode().Perm())
	}
	// The escaped folder is found again, so it is never written twice.
	if changed, _ := TrustCodexProject(path, `/srv/a "quoted" \ folder`); changed {
		t.Fatal("an escaped folder was added again")
	}
}

func TestTrustCodexProjectSkipsMultilineStrings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	existing := "instructions = \"\"\"\n[projects.\"/srv/shop\"]\n\"\"\"\n"
	os.WriteFile(path, []byte(existing), 0o600)
	if changed, _ := TrustCodexProject(path, "/srv/shop"); !changed {
		t.Fatal("words inside a string were taken for a table")
	}
}

// Codex trusts a hook by a hash of its normalized form; these are the
// hashes Codex 0.160 writes for pierd's hooks at this path (the formula
// reproduces what Codex itself wrote on a real config).
func TestCodexHookHash(t *testing.T) {
	bin := "/home/octocat/.local/bin/pierd"
	for event, want := range map[string]string{
		"session_start":      "sha256:5bac7bef48c72ad49f168f9b05a4c4c02beb5543ee091ac3955de52ce574f585",
		"user_prompt_submit": "sha256:53906f403fe029e82549b07e61632577757880e5983b7ebac162ce1307edfac5",
		"permission_request": "sha256:8d2014679cb2e462117e560dae3c276764fac563b3872441835065da13bfca58",
		"stop":               "sha256:b47630d3dfcfde099c52cd91ccf7200d1738e51d0892772d5dcc21a590caeed8",
	} {
		names := map[string]string{"session_start": "SessionStart", "user_prompt_submit": "UserPromptSubmit", "permission_request": "PermissionRequest", "stop": "Stop"}
		got, ok := CodexHookHash(event, map[string]any{"type": "command", "command": bin + " hook codex " + names[event]})
		if !ok || got != want {
			t.Errorf("%s: %s, want %s", event, got, want)
		}
	}
	got, ok := CodexHookHash("stop", map[string]any{"type": "command", "command": "'/home/o c/pierd' hook codex Stop", "timeout": float64(30), "statusMessage": `Telling Pier "done"`})
	if want := "sha256:26914dc98f3067bf267f688764bef68fb3ea48390156c9760d1c8b9fc1a412ae"; !ok || got != want {
		t.Errorf("custom: %s, want %s", got, want)
	}
	if _, ok := CodexHookHash("session_end", map[string]any{"type": "command", "command": "x"}); ok {
		t.Error("a SessionEnd hook's clamped timeout was guessed")
	}
}

func TestTrustCodexHooksTrustsPierdsOwnOnly(t *testing.T) {
	dir := t.TempDir()
	bin := "/home/octocat/.local/bin/pierd"
	hooks := filepath.Join(dir, "hooks.json")
	config := filepath.Join(dir, "config.toml")
	// Another tool's hook first: pierd's Stop group is the second.
	os.WriteFile(hooks, []byte(`{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify-send done"}]}]}}`), 0o644)
	if _, err := InstallCodexHooks(hooks, bin); err != nil {
		t.Fatal(err)
	}
	existing := "model = \"o3\"\n\n[hooks.state]\n\n[hooks.state.\"" + hooks + ":stop:0:0\"]\ntrusted_hash = \"sha256:theirs\"\n\n" +
		"[hooks.state.\"" + hooks + ":session_start:0:0\"]\nenabled = false\ntrusted_hash = \"sha256:old\"\n"
	os.WriteFile(config, []byte(existing), 0o600)

	changed, err := TrustCodexHooks(config, hooks, bin)
	if err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	text, _ := os.ReadFile(config)
	doc := scanTOML(string(text))
	want := map[string]string{
		hooks + ":session_start:0:0":      "sha256:5bac7bef48c72ad49f168f9b05a4c4c02beb5543ee091ac3955de52ce574f585",
		hooks + ":user_prompt_submit:0:0": "sha256:53906f403fe029e82549b07e61632577757880e5983b7ebac162ce1307edfac5",
		hooks + ":permission_request:0:0": "sha256:8d2014679cb2e462117e560dae3c276764fac563b3872441835065da13bfca58",
		hooks + ":stop:1:0":               "sha256:b47630d3dfcfde099c52cd91ccf7200d1738e51d0892772d5dcc21a590caeed8",
		hooks + ":stop:0:0":               "sha256:theirs",
	}
	for key, hash := range want {
		line, ok := doc.table("hooks", "state", key)
		if !ok {
			t.Fatalf("no state for %s in\n%s", key, text)
		}
		if got := tableValue(string(text), line, "trusted_hash"); got != hash {
			t.Errorf("%s: %s, want %s", key, got, hash)
		}
		if n := countTables(string(text), "[hooks.state.\""+key+"\"]"); n != 1 {
			t.Errorf("%d tables for %s", n, key)
		}
	}
	// A hook the person disabled stays disabled.
	line, _ := doc.table("hooks", "state", hooks+":session_start:0:0")
	if !strings.Contains(strings.Join(doc.lines[line:line+3], "\n"), "enabled = false") {
		t.Fatalf("enabled = false was lost:\n%s", text)
	}
	if changed, _ := TrustCodexHooks(config, hooks, bin); changed {
		t.Fatal("trusted twice")
	}
}

func TestTrustCodexHooksWithoutHooks(t *testing.T) {
	dir := t.TempDir()
	if changed, err := TrustCodexHooks(filepath.Join(dir, "config.toml"), filepath.Join(dir, "hooks.json"), "/bin/pierd"); err != nil || changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "config.toml")); !os.IsNotExist(err) {
		t.Fatal("a config was made for no hooks")
	}
}

func TestParseTOMLKey(t *testing.T) {
	for in, want := range map[string]string{
		`projects."/a b"`:          "projects|/a b",
		` hooks . state . 'x:y' `:  "hooks|state|x:y",
		`a.b-c.d_e`:                "a|b-c|d_e",
		`"with \"quote\"".x`:       `with "quote"|x`,
		`"dot.inside".z`:           "dot.inside|z",
		`projects."/esc\u0041ped"`: "projects|/escAped",
	} {
		got, ok := parseTOMLKey(in)
		if !ok || strings.Join(got, "|") != want {
			t.Errorf("%q: %q %v, want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{`a..b`, `"open`, `a b`, `.a`, `a.`} {
		if got, ok := parseTOMLKey(bad); ok {
			t.Errorf("%q read as %q", bad, got)
		}
	}
}
