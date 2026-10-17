package box

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/agentpath"
)

// fakeAgentCLIs puts stand-ins for claude and codex first on PATH, as the
// box finds agents, and gives the test a scratch home for their configs.
// The claude one says its version, and lists the bypass flag in its --help
// when bypass says it knows it.
func fakeAgentCLIs(t *testing.T, claudeVersion string, bypass bool) string {
	t.Helper()
	bin := t.TempDir()
	help := "Usage: claude [options] [command] [prompt]"
	if bypass {
		help += "\n  " + claudeBypassFlag + "  Enable bypassing all permission checks as an option"
	}
	for name, version := range map[string]string{"claude": claudeVersion + " (Claude Code)", "codex": "codex-cli 0.160.1"} {
		script := "#!/bin/sh\n[ \"$1\" = --version ] && echo '" + version + "' && exit 0\n[ \"$1\" = --help ] && printf '%s\\n' '" + help + "' && exit 0\nexec sleep 60\n"
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	home := t.TempDir()
	saved := agentHome
	agentHome = func() (string, error) { return home, nil }
	t.Cleanup(func() { agentHome = saved })
	return home
}

func claudeTrusts(t *testing.T, config, dir string) bool {
	t.Helper()
	raw, err := os.ReadFile(config)
	if err != nil {
		return false
	}
	var root struct {
		Projects map[string]map[string]any `json:"projects"`
	}
	if err := json.Unmarshal(raw, &root); err != nil {
		t.Fatal(err)
	}
	return root.Projects[dir]["hasTrustDialogAccepted"] == true
}

func codexTrusts(t *testing.T, config, dir string) bool {
	t.Helper()
	raw, _ := os.ReadFile(config)
	return strings.Contains(string(raw), "[projects."+tomlQuote(dir)+"]\ntrust_level = \"trusted\"")
}

func tomlQuote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestTrustPaths(t *testing.T) {
	repo := gitRepo(t)
	if got := trustPaths(repo); len(got) != 1 || got[0] != repo {
		t.Fatalf("main checkout: %v", got)
	}
	sub := filepath.Join(repo, "web")
	os.MkdirAll(sub, 0o755)
	if got := trustPaths(sub); len(got) != 1 || got[0] != repo {
		t.Fatalf("a folder inside: %v", got)
	}
	wt := filepath.Join(filepath.Dir(repo), "cal-fix")
	if out, err := exec.Command("git", "-C", repo, "worktree", "add", "-q", "-b", "fix", wt).CombinedOutput(); err != nil {
		t.Fatalf("worktree: %s", out)
	}
	if got := trustPaths(wt); len(got) != 2 || got[0] != wt || got[1] != repo {
		t.Fatalf("a linked worktree: %v, want [%s %s]", got, wt, repo)
	}
	plain := t.TempDir()
	if real, _ := filepath.EvalSymlinks(plain); trustPaths(plain)[0] != real {
		t.Fatalf("a folder in no repository: %v", trustPaths(plain))
	}
}

// A project the person registers, and every worktree pierd makes in it, is
// trusted in the agents' own configs before any agent starts there.
func TestProjectsAndWorktreesAreTrustedUpFront(t *testing.T) {
	home := fakeAgentCLIs(t, "2.1.302", true)
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })
	repo := gitRepo(t)
	if st := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil); st != 200 {
		t.Fatalf("add = %d", st)
	}
	claude, codex := filepath.Join(home, ".claude.json"), filepath.Join(home, ".codex", "config.toml")
	if !claudeTrusts(t, claude, repo) || !codexTrusts(t, codex, repo) {
		t.Fatal("the project is not trusted")
	}
	var wt Worktree
	if st := call(t, c, "POST", "/v1/locations/cal/worktrees", "", WorktreeRequest{Name: "fix", Prepare: new(bool)}, &wt); st != 200 {
		t.Fatalf("worktree = %d", st)
	}
	if !claudeTrusts(t, claude, wt.Path) || !codexTrusts(t, codex, wt.Path) {
		t.Fatalf("the worktree %s is not trusted", wt.Path)
	}
	raw, _ := os.ReadFile(codex)
	if n := strings.Count(string(raw), "[projects."+tomlQuote(repo)+"]"); n != 1 {
		t.Fatalf("the project is in Codex's config %d times:\n%s", n, raw)
	}
	// The person's own Claude Code settings are not touched: accepting the
	// bypass warning is theirs (only accounts pierd made get it).
	if _, err := os.Stat(filepath.Join(home, ".claude", "settings.json")); !os.IsNotExist(err) {
		t.Fatalf("the built-in account's settings were written: %v", err)
	}
}

// An agent started in a chat's folder is trusted there, in the account it
// runs on.
func TestAnAgentIsTrustedWhereItStarts(t *testing.T) {
	home := fakeAgentCLIs(t, "2.1.302", true)
	bx := &Box{}
	dir := t.TempDir()
	real, _ := filepath.EvalSymlinks(dir)
	account := t.TempDir()
	bx.pretrust(dir, []string{"CLAUDE_CONFIG_DIR=" + account}, "claude")
	if !claudeTrusts(t, filepath.Join(account, ".claude.json"), real) {
		t.Fatal("not trusted in the session's account")
	}
	if _, err := os.Stat(filepath.Join(home, ".claude.json")); !os.IsNotExist(err) {
		t.Fatal("the default account was written for a session on another")
	}
}

// A new Claude Code account skips its first-run screens and trusts the
// projects already on the box; signing it in is a terminal (no agent) in a
// folder Claude Code trusts, opening on /login.
func TestANewAccountIsReadyAndSignsInInATerminal(t *testing.T) {
	fakeAgentCLIs(t, "2.1.302", true)
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.Exe = "/opt/pier/pierd"; bx = b })
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	var a AccountView
	if st := call(t, c, "POST", "/v1/accounts", "", map[string]string{"agent": "claude", "name": "Trabalho"}, &a); st != 200 {
		t.Fatalf("add = %d", st)
	}
	config := filepath.Join(a.Dir, ".claude.json")
	raw, _ := os.ReadFile(config)
	if !strings.Contains(string(raw), `"hasCompletedOnboarding": true`) || !claudeTrusts(t, config, repo) {
		t.Fatalf("account config = %s", raw)
	}
	settings, _ := os.ReadFile(filepath.Join(a.Dir, "settings.json"))
	if !strings.Contains(string(settings), `"theme": "dark"`) || !strings.Contains(string(settings), `"skipDangerousModePermissionPrompt": true`) {
		t.Fatalf("account settings = %s", settings)
	}

	var sess Session
	if st := call(t, c, "POST", "/v1/accounts/"+a.ID+"/login", "", nil, &sess); st != 200 {
		t.Fatalf("login = %d", st)
	}
	defer bx.Sessions.Kill(t.Context(), sess.Name)
	// The CLI's own sign-in (no screen of Claude Code's, so no folder to trust), on the account's folder.
	if !strings.HasSuffix(sess.Command, " auth login") || sess.Dir != a.Dir {
		t.Fatalf("sign-in session = %+v", sess)
	}
	var list []Session
	call(t, c, "GET", "/v1/sessions", "", nil, &list)
	for _, s := range list {
		if s.Name == sess.Name && (s.Agent != "" || s.AgentState != "") {
			t.Fatalf("the sign-in terminal is listed as an agent: %+v", s)
		}
	}
}

func TestSignInSessionsAreNoAgents(t *testing.T) {
	for _, c := range []struct {
		s    Session
		want string
	}{
		{Session{Name: "login-claude-1a2b", Command: "claude /login"}, ""},
		{Session{Name: "login-codex", Command: "codex login --device-auth"}, ""},
		{Session{Name: "login-fix", Location: "shop", Command: "claude"}, "claude"}, // a project's session
		{Session{Name: "login-fix", Preset: "claude", Command: "claude"}, "claude"}, // started as an agent
		{Session{Name: "shop-claude", Command: "claude"}, "claude"},
	} {
		if got := agentFor(c.s); got != c.want {
			t.Errorf("agentFor(%+v) = %q, want %q", c.s, got, c.want)
		}
	}
}

// Claude Code starts able to reach bypass mode where it knows the flag.
func TestClaudeStartsWithBypassAmongItsModes(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("Claude Code refuses the flag as root")
	}
	saved := agentFinder
	t.Cleanup(func() { agentFinder = saved })
	claude := AgentPreset{ID: "claude", Command: "claude", ModelFlag: "--model"}
	// Listed in its --help or not: a Claude Code without the flag would not
	// start with it.
	for version, want := range map[string]bool{"2.1.302": true, "3.0.1": true, "2.1.40": false, "2.0.77": false} {
		fakeAgentCLIs(t, version, want)
		finder := &agentpath.Finder{NoCache: true, NoNPM: true, SystemDirs: []string{}}
		agentFinder = func() *agentpath.Finder { return finder }
		got, err := AgentCommandWith(claude, "fix it", "opus", "")
		if err != nil {
			t.Fatal(err)
		}
		if has := strings.Contains(got, claudeBypassFlag); has != want {
			t.Errorf("%s: %q", version, got)
		}
		// The warning the flag brings up at start is skipped for that
		// process: Claude Code would otherwise wait there for a person.
		if skips := strings.Contains(got, "--settings "+shellQuote(skipBypassWarning)); skips != want {
			t.Errorf("%s: bypass warning not skipped: %q", version, got)
		}
	}
	// A setup agent's command, which skips the warning itself, gets the
	// flag and keeps its one --settings; a preset with settings of its own
	// gets no flag (a second --settings would replace them).
	fakeAgentCLIs(t, "2.1.302", true)
	finder := &agentpath.Finder{NoCache: true, NoNPM: true, SystemDirs: []string{}}
	agentFinder = func() *agentpath.Finder { return finder }
	setup := AgentPreset{ID: "claude", Command: "claude --settings " + shellQuote(skipBypassWarning) + " --permission-mode bypassPermissions"}
	if got, _ := AgentCommandWith(setup, "", "", ""); strings.Count(got, claudeBypassFlag) != 1 || strings.Count(got, "--settings") != 1 {
		t.Errorf("setup agent: %q", got)
	}
	own := AgentPreset{ID: "claude", Command: "claude --settings /home/me/strict.json"}
	if got, _ := AgentCommandWith(own, "", "", ""); strings.Contains(got, claudeBypassFlag) || strings.Count(got, "--settings") != 1 {
		t.Errorf("own settings: %q", got)
	}
	// A preset that already starts in bypass is left alone.
	got, _ := AgentCommandWith(AgentPreset{ID: "claude", Command: "claude --dangerously-skip-permissions"}, "", "", "")
	if strings.Count(got, "skip-permissions") != 1 {
		t.Errorf("%q", got)
	}
}

// Where an account has not accepted bypass yet, Claude Code asks before it
// first goes into it: the app's mode switch stops there, pressing nothing.
func TestTheModeSwitchStopsAtClaudesBypassWarning(t *testing.T) {
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { bx = b })
	dir := t.TempDir()
	keys := filepath.Join(dir, "keys")
	agent := filepath.Join(dir, "claude")
	script := "#!/bin/sh\nprintf ' WARNING: Claude Code running in Bypass Permissions mode\\n\\n ❯ 1. No, exit\\n   2. Yes, I accept\\n'\n" +
		"stty raw -echo\nwhile :; do c=$(dd bs=1 count=1 2>/dev/null); printf '%s' \"$c\" >> '" + keys + "'; done\n"
	if err := os.WriteFile(agent, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := bx.Sessions.Create(t.Context(), "bypass", "", dir, agent, nil); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the warning", 5*time.Second, func() bool {
		s, _ := bx.Sessions.Screen(t.Context(), "bypass", 0)
		return strings.Contains(s, bypassWarning)
	})
	var refused map[string]string
	if st := call(t, c, "POST", "/v1/sessions/bypass/mode", "", map[string]string{"mode": "bypassPermissions"}, &refused); st != 409 || !strings.Contains(refused["error"], "confirm bypass") {
		t.Fatalf("mode = %d %v", st, refused)
	}
	time.Sleep(200 * time.Millisecond)
	if got, _ := os.ReadFile(keys); len(got) != 0 {
		t.Fatalf("keys pressed into the warning: %q", got)
	}
}
