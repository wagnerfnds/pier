package box

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/doctor"
	"pier/pierd/internal/wire"
)

// The app installs what the box lacks: GET /v1/tools says which of the three it has, POST /v1/tools/install installs the
// missing ones in the background (a stand-in for the installers here), finds them at once, puts a new agent's hooks in
// and says how each went; a failure stays readable until the tool is there.
func TestToolsInstallFromTheApp(t *testing.T) {
	fakeCLIs(t, "codex")
	home := os.Getenv("HOME")
	ran := make(chan string, 8)
	logs := t.TempDir()
	c, bus := servedBox(t, func(b *Box) {
		b.Exe, b.LogDir = "/opt/pier/pierd", logs
		b.ToolInstaller = func(ctx context.Context, id string, out io.Writer) error {
			ran <- id
			fmt.Fprintln(out, "installing", id)
			if id == "gh" {
				return errors.New("checksum mismatch for gh_9.9.9_linux_amd64.tar.gz, so it was not installed")
			}
			bin := filepath.Join(home, ".local", "bin")
			os.MkdirAll(bin, 0o755)
			return os.WriteFile(filepath.Join(bin, id), []byte("#!/bin/sh\necho 1.0\n"), 0o755)
		}
	})
	seen, stop := bus.Subscribe()
	defer stop()

	byID := func(list []ToolStatus) map[string]ToolStatus {
		m := map[string]ToolStatus{}
		for _, s := range list {
			m[s.ID] = s
		}
		return m
	}
	var list []ToolStatus
	call(t, c, "GET", "/v1/tools", "", nil, &list)
	if m := byID(list); len(list) != 3 || !m["codex"].Installed || m["claude"].Installed || m["gh"].Installed || m["gh"].Name != "GitHub CLI" {
		t.Fatalf("tools = %+v", list)
	}
	if status := call(t, c, "POST", "/v1/tools/install", "", map[string]any{"tools": []string{"node"}}, nil); status != 400 {
		t.Fatalf("an unknown tool = %d", status)
	}
	list = nil
	if status := call(t, c, "POST", "/v1/tools/install", "", map[string]any{"tools": []string{"claude", "gh", "codex"}}, &list); status != 202 {
		t.Fatalf("install = %d", status)
	}
	if m := byID(list); !m["claude"].Installing || !m["gh"].Installing || m["codex"].Installing {
		t.Fatalf("installing = %+v", list)
	}
	results := map[string]string{}
	for len(results) < 2 {
		select {
		case e := <-seen:
			switch e.Type {
			case "tool.installed":
				results[e.Data["tool"].(string)] = "installed " + fmt.Sprint(e.Data["path"])
			case "tool.failed":
				results[e.Data["tool"].(string)] = "failed " + e.Error
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("results = %v", results)
		}
	}
	if results["claude"] != "installed "+filepath.Join(home, ".local", "bin", "claude") || !strings.Contains(results["gh"], "checksum mismatch") {
		t.Fatalf("results = %v", results)
	}
	close(ran)
	var installers []string
	for id := range ran {
		installers = append(installers, id)
	}
	if len(installers) != 2 || strings.Contains(strings.Join(installers, " "), "codex") {
		t.Fatalf("installers ran for %v (codex was there already)", installers)
	}
	list = nil // a decode into the old list would keep what the new one leaves out
	call(t, c, "GET", "/v1/tools", "", nil, &list)
	m := byID(list)
	if !m["claude"].Installed || m["claude"].Error != "" || m["gh"].Installed || !strings.Contains(m["gh"].Error, "checksum mismatch") || m["gh"].Installing {
		t.Fatalf("after = %+v", list)
	}
	if b, _ := os.ReadFile(m["gh"].Log); !strings.Contains(string(b), "installing gh") {
		t.Fatalf("gh's log %s = %q", m["gh"].Log, b)
	}
	if b, _ := os.ReadFile(filepath.Join(home, ".claude", "settings.json")); !strings.Contains(string(b), "/opt/pier/pierd hook claude Stop") {
		t.Fatalf("the new agent has no hooks: %s", b)
	}
}

func findCheck(checks []doctor.Check, name string) (doctor.Check, bool) {
	for _, c := range checks {
		if c.Name == name {
			return c, true
		}
	}
	return doctor.Check{}, false
}

// githubProject adds a project whose origin is on github.com: with one, doctor warns about the GitHub CLI.
func githubProject(t *testing.T, c *wire.Client) {
	t.Helper()
	repo := gitRepo(t)
	if out, err := exec.Command("git", "-C", repo, "remote", "add", "origin", "https://github.com/octocat/cal.git").CombinedOutput(); err != nil {
		t.Fatalf("git remote add: %s", out)
	}
	if status := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil); status != 200 {
		t.Fatalf("add location = %d", status)
	}
}

// Doctor names what the app can fix with a tap: the GitHub CLI missing or signed out, an added account signed out, an
// agent the box lacks; each with the tool (and account) the card's button is for. gh's own status is kept a while (it
// asks GitHub), until a sign-in to GitHub forgets it.
func TestDoctorSaysWhatTheAppCanInstallOrSignIn(t *testing.T) {
	state := fakeCLIs(t, "gh", "codex")
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.Exe = "/opt/pier/pierd"; bx = b })
	githubProject(t, c)
	var a AccountView
	call(t, c, "POST", "/v1/accounts", "", map[string]string{"agent": "codex", "name": "Trabalho"}, &a)

	var checks []doctor.Check
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	if gh, _ := findCheck(checks, "gh"); gh.Status != doctor.OK || gh.Tool != "gh" {
		t.Fatalf("gh = %+v", gh)
	}
	signIn, _ := findCheck(checks, "GitHub sign-in")
	if signIn.Status != doctor.Warn || signIn.Area != "Agents" || signIn.Tool != "gh" || !strings.HasPrefix(signIn.Fix, "gh auth login") {
		t.Fatalf("GitHub sign-in = %+v", signIn)
	}
	acct, _ := findCheck(checks, "Codex (Trabalho) sign-in")
	if acct.Status != doctor.Warn || acct.Tool != "codex" || acct.Account != a.ID || acct.Fix != "CODEX_HOME='"+a.Dir+"' codex login --device-auth" {
		t.Fatalf("the added account = %+v", acct)
	}
	if claude, _ := findCheck(checks, "Claude Code"); claude.Status != doctor.Info || claude.Tool != "claude" || claude.Fix != "pierd tools install claude" {
		t.Fatalf("Claude Code missing = %+v", claude)
	}
	var tools []ToolStatus
	call(t, c, "GET", "/v1/tools", "", nil, &tools)
	for _, tool := range tools {
		if tool.ID == "gh" && (tool.SignedIn == nil || *tool.SignedIn) {
			t.Fatalf("gh's sign-in in /v1/tools = %v", tool.SignedIn)
		}
	}

	touch(t, filepath.Join(state, "gh-ok"))
	os.WriteFile(filepath.Join(a.Dir, "auth.json"), []byte(`{"tokens":{}}`), 0o600)
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	if signIn, _ := findCheck(checks, "GitHub sign-in"); signIn.Status != doctor.Warn {
		t.Fatalf("gh's status was asked again at once: %+v", signIn)
	}
	if acct, _ := findCheck(checks, "Codex (Trabalho) sign-in"); acct.Status != doctor.OK {
		t.Fatalf("the account signed in = %+v", acct)
	}
	bx.ghAuth.forget() // as a sign-in to GitHub, or gh installed from the app, does
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	if signIn, _ := findCheck(checks, "GitHub sign-in"); signIn.Status != doctor.OK {
		t.Fatalf("GitHub signed in = %+v", signIn)
	}
}

// With no project on GitHub, a missing GitHub CLI is information, not a card; one project on github.com makes it a
// warning.
func TestDoctorOffersTheGitHubCLI(t *testing.T) {
	fakeCLIs(t)
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })
	var checks []doctor.Check
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	gh, _ := findCheck(checks, "gh")
	if gh.Status != doctor.Info || gh.Area != "Worktrees and sessions" || gh.Fix != "pierd tools install gh" || gh.Tool != "gh" {
		t.Fatalf("gh, no GitHub project = %+v", gh)
	}
	if _, ok := findCheck(checks, "GitHub sign-in"); ok {
		t.Fatal("a GitHub sign-in check without gh")
	}
	if none, _ := findCheck(checks, "agent CLIs"); none.Fix != "pierd tools install claude codex" {
		t.Fatalf("no agents = %+v", none)
	}
	githubProject(t, c)
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	if gh, _ := findCheck(checks, "gh"); gh.Status != doctor.Warn {
		t.Fatalf("gh, a GitHub project = %+v", gh)
	}
}

// The GitHub list runs the gh pierd finds, one it installed in ~/.local/bin included, where the login shell's PATH
// may not reach.
func TestGitHubListRunsTheGhPierdFinds(t *testing.T) {
	fakeCLIs(t)
	bin := filepath.Join(os.Getenv("HOME"), ".local", "bin")
	os.MkdirAll(bin, 0o755)
	fake := `#!/bin/sh
case "$1 $2" in
"api user") echo octocat ;;
"api user/orgs") ;;
"repo list") echo '[{"nameWithOwner":"octocat/cal","name":"cal","url":"https://github.com/octocat/cal","updatedAt":"2026-10-12T18:04:11Z"}]' ;;
*) exit 2 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "gh"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	c, _ := servedBox(t)
	var repos GitHubRepos
	if status := call(t, c, "GET", "/v1/github/repos", "", nil, &repos); status != 200 || repos.Login != "octocat" || len(repos.Repos) != 1 {
		t.Fatalf("repos = %d %+v", status, repos)
	}
}

// An install a previous pierd started and never finished says so.
func TestAnInstallCutShortByARestartSaysSo(t *testing.T) {
	fakeCLIs(t)
	logs := t.TempDir()
	c, _ := servedBox(t, func(b *Box) { b.LogDir = logs })
	os.MkdirAll(filepath.Join(logs, "tools"), 0o700)
	touch(t, filepath.Join(logs, "tools", "gh.log.running"))
	var tools []ToolStatus
	call(t, c, "GET", "/v1/tools", "", nil, &tools)
	for _, tool := range tools {
		if tool.ID == "gh" && (tool.Installing || !strings.Contains(tool.Error, "cut short")) {
			t.Fatalf("gh = %+v", tool)
		}
	}
}
