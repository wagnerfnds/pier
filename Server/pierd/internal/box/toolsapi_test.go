package box

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/doctor"
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

// Doctor names what the app can fix with a tap: the GitHub CLI missing or signed out, an added account signed out, an
// agent the box lacks; each with the tool (and account) the card's button is for.
func TestDoctorSaysWhatTheAppCanInstallOrSignIn(t *testing.T) {
	state := fakeCLIs(t, "gh", "codex")
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.Exe = "/opt/pier/pierd" })
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

	touch(t, filepath.Join(state, "gh-ok"))
	os.WriteFile(filepath.Join(a.Dir, "auth.json"), []byte(`{"tokens":{}}`), 0o600)
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	if signIn, _ := findCheck(checks, "GitHub sign-in"); signIn.Status != doctor.OK {
		t.Fatalf("GitHub signed in = %+v", signIn)
	}
	if acct, _ := findCheck(checks, "Codex (Trabalho) sign-in"); acct.Status != doctor.OK {
		t.Fatalf("the account signed in = %+v", acct)
	}
}

func TestDoctorOffersTheGitHubCLI(t *testing.T) {
	fakeCLIs(t)
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })
	var checks []doctor.Check
	call(t, c, "GET", "/v1/doctor", "", nil, &checks)
	gh, _ := findCheck(checks, "gh")
	if gh.Status != doctor.Warn || gh.Area != "Worktrees and sessions" || gh.Fix != "pierd tools install gh" || gh.Tool != "gh" {
		t.Fatalf("gh = %+v", gh)
	}
	if _, ok := findCheck(checks, "GitHub sign-in"); ok {
		t.Fatal("a GitHub sign-in check without gh")
	}
	if none, _ := findCheck(checks, "agent CLIs"); none.Fix != "pierd tools install claude codex" {
		t.Fatalf("no agents = %+v", none)
	}
}
