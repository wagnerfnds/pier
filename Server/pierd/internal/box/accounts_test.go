package box

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCodexLimitsFromTheNewestSessionLog(t *testing.T) {
	home := t.TempDir()
	old := filepath.Join(home, "sessions", "2026", "09", "30")
	day := filepath.Join(home, "sessions", "2026", "10", "13")
	os.MkdirAll(old, 0o755)
	os.MkdirAll(day, 0o755)
	os.WriteFile(filepath.Join(old, "rollout-a.jsonl"), []byte(`{"timestamp":"2026-09-30T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"window_minutes":300,"resets_at":4102444800}}}}`+"\n"), 0o644)
	log := `{"timestamp":"2026-10-13T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":4102444800}}}}
{"timestamp":"2026-10-13T10:05:00Z","type":"response_item","payload":{"type":"message"}}
{"timestamp":"2026-10-13T10:06:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":12,"window_minutes":10080,"resets_in_seconds":3600}}}}
`
	os.WriteFile(filepath.Join(day, "rollout-b.jsonl"), []byte(log), 0o644)
	l := codexLimits(home)
	if l == nil || len(l.Windows) != 1 || l.Windows[0].UsedPercent != 37.5 || l.Source != "session_log" {
		// the secondary window reset an hour after 10:06 on 2026-10-13: before now, so gone
		t.Fatalf("limits = %+v", l)
	}
	if codexLimits(t.TempDir()) != nil {
		t.Error("limits without any session")
	}
}

// An account added on the box gets its folder ready (hooks, status line),
// reaches a project's worktrees once chosen there, and goes when removed.
func TestAccountsReachTheProjectsThatChooseThem(t *testing.T) {
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.Exe = "/opt/pier/pierd"; bx = b })
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)

	var a AccountView
	if status := call(t, c, "POST", "/v1/accounts", "", map[string]string{"agent": "claude", "name": "Trabalho"}, &a); status != 200 || !strings.HasPrefix(a.ID, "claude-") {
		t.Fatalf("add = %d %+v", status, a)
	}
	settings, _ := os.ReadFile(filepath.Join(a.Dir, "settings.json"))
	if !strings.Contains(string(settings), "/opt/pier/pierd hook claude Stop") || !strings.Contains(string(settings), "/opt/pier/pierd statusline") {
		t.Fatalf("account settings = %s", settings)
	}
	envOf := func() string {
		loc, _ := bx.Locations.Get(context.Background(), "cal")
		env, err := bx.WorktreeEnv(context.Background(), "cal", loc.Worktrees[0])
		if err != nil {
			t.Fatal(err)
		}
		return strings.Join(env, "\n")
	}
	if strings.Contains(envOf(), "CLAUDE_CONFIG_DIR="+a.Dir) {
		t.Fatal("an account nobody chose reached the project")
	}
	var loc Location
	if status := call(t, c, "PUT", "/v1/locations/cal/accounts", "", map[string]string{"claude": a.ID}, &loc); status != 200 || loc.Accounts["claude"] != a.ID {
		t.Fatalf("choose = %d %+v", status, loc)
	}
	if !strings.Contains(envOf(), "CLAUDE_CONFIG_DIR="+a.Dir) {
		t.Fatal("the chosen account does not reach the worktree")
	}
	if status := call(t, c, "PUT", "/v1/locations/cal/accounts", "", map[string]string{"claude": "codex"}, nil); status != 400 {
		t.Fatalf("a codex account for claude = %d", status)
	}

	var list []AccountView
	call(t, c, "GET", "/v1/accounts", "", nil, &list)
	var mine AccountView
	for _, v := range list {
		if v.ID == a.ID {
			mine = v
		}
	}
	if len(list) != 3 || len(mine.Projects) != 1 || mine.Projects[0] != "cal" || !mine.LimitsReady {
		t.Fatalf("accounts = %+v", list)
	}

	if status := call(t, c, "DELETE", "/v1/accounts/"+a.ID, "", nil, nil); status != 200 {
		t.Fatalf("remove = %d", status)
	}
	if _, err := os.Stat(a.Dir); !os.IsNotExist(err) {
		t.Error("the account's folder is still there")
	}
	if strings.Contains(envOf(), "CLAUDE_CONFIG_DIR="+a.Dir) {
		t.Error("a removed account still reaches the project")
	}
	if status := call(t, c, "DELETE", "/v1/accounts/claude", "", nil, nil); status != 400 {
		t.Errorf("removing the built-in account = %d", status)
	}
}

func TestBoxVariablesAndSkills(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	os.MkdirAll(filepath.Join(home, ".claude"), 0o755)
	// The person's own skill of the same name is never touched.
	own := filepath.Join(home, ".agents", "skills", "pier-preview", "SKILL.md")
	os.MkdirAll(filepath.Dir(own), 0o755)
	os.WriteFile(own, []byte("mine"), 0o644)

	envFile := filepath.Join(t.TempDir(), "env.json")
	os.WriteFile(envFile, []byte(`{"env":{"OLD":"1"},"other":true}`), 0o600)
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.EnvFile = envFile })

	var got BoxEnvView
	call(t, c, "GET", "/v1/env", "", nil, &got)
	if got.Env["OLD"] != "1" {
		t.Fatalf("env = %+v", got)
	}
	body := BoxEnvView{Env: map[string]string{"STAGING_URL": "https://staging.example.com", "STRIPE_KEY": "sk_test_secret"},
		Notes: map[string]string{"STAGING_URL": "the staging API", "STRIPE_KEY": "Stripe test key", "GONE": "x"}}
	got = BoxEnvView{}
	if status := call(t, c, "PUT", "/v1/env", "", body, &got); status != 200 || len(got.Env) != 2 || got.Notes["GONE"] != "" {
		t.Fatalf("put env = %d %+v", status, got)
	}
	raw, _ := os.ReadFile(envFile)
	if !strings.Contains(string(raw), `"other": true`) {
		t.Errorf("other settings in env.json were lost: %s", raw)
	}
	for _, bad := range []string{"PATH", "PIER_PORT", "1X", "A-B"} {
		if status := call(t, c, "PUT", "/v1/env", "", BoxEnvView{Env: map[string]string{bad: "x"}}, nil); status != 400 {
			t.Errorf("%s accepted: %d", bad, status)
		}
	}

	var skills []Skill
	for _, id := range []string{"pier-box", "pier-preview", "pier-prove"} {
		if status := call(t, c, "PUT", "/v1/skills/"+id, "", nil, &skills); status != 200 {
			t.Fatalf("install %s = %d", id, status)
		}
	}
	prove, err := os.ReadFile(filepath.Join(home, ".agents", "skills", "pier-prove", "SKILL.md"))
	if err != nil || !strings.Contains(string(prove), "name: pier-prove") || !strings.Contains(string(prove), "pierd capture add") || !strings.Contains(string(prove), "--before") {
		t.Errorf("pier-prove = %s %v", prove, err)
	}
	claudeSkill, err := os.ReadFile(filepath.Join(home, ".claude", "skills", "pier-box", "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(claudeSkill)
	if !strings.Contains(text, "`STAGING_URL`: the staging API") || !strings.Contains(text, "name: pier-box") || strings.Contains(text, "sk_test_secret") {
		t.Fatalf("skill = %s", text)
	}
	if _, err := os.Stat(filepath.Join(home, ".agents", "skills", "pier-box", "SKILL.md")); err != nil {
		t.Error("no Codex copy of the skill")
	}
	if data, _ := os.ReadFile(own); string(data) != "mine" {
		t.Error("the person's own skill was overwritten")
	}
	// A note changed: the skill follows.
	body.Notes["STAGING_URL"] = "staging, read-only"
	call(t, c, "PUT", "/v1/env", "", body, nil)
	claudeSkill, _ = os.ReadFile(filepath.Join(home, ".claude", "skills", "pier-box", "SKILL.md"))
	if !strings.Contains(string(claudeSkill), "staging, read-only") {
		t.Error("the skill did not follow the variables")
	}
	call(t, c, "DELETE", "/v1/skills/pier-box", "", nil, &skills)
	if _, err := os.Stat(filepath.Join(home, ".claude", "skills", "pier-box")); !os.IsNotExist(err) {
		t.Error("an uninstalled skill is still there")
	}
}

type fakePublisher struct{ published map[string]int }

func (f *fakePublisher) Publish(_ context.Context, name string, port int) (string, error) {
	f.published[name] = port
	return "https://p-" + name + ".example.test", nil
}
func (f *fakePublisher) Unpublish(name string) { delete(f.published, name) }
func (f *fakePublisher) SharePrefix() string   { return "abcd2345" }

func TestSharesPublishOnlyTheWorktreesPorts(t *testing.T) {
	pub := &fakePublisher{published: map[string]int{}}
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.Publisher = pub })
	repo := gitRepo(t)
	var loc Location
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, &loc)
	wt := loc.Worktrees[0]
	if wt.Port == 0 {
		t.Skip("no port block on this machine")
	}
	var sh Share
	if status := call(t, c, "POST", "/v1/shares", "", map[string]any{"location": "cal", "worktree": wt.Name, "port": wt.Port}, &sh); status != 200 || pub.published[sh.Name] != wt.Port || !strings.HasPrefix(sh.URL, "https://p-abcd2345") || len(sh.Name) != 24 {
		t.Fatalf("share = %d %+v", status, sh)
	}
	if time.Until(sh.Expires) < 23*time.Hour {
		t.Errorf("expires = %v", sh.Expires)
	}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	other := ln.Addr().(*net.TCPAddr).Port
	if status := call(t, c, "POST", "/v1/shares", "", map[string]any{"location": "cal", "worktree": wt.Name, "port": other}, nil); status != 400 {
		t.Errorf("a port that is not the worktree's = %d", status)
	}
	if status := call(t, c, "POST", "/v1/shares", "", map[string]any{"location": "cal", "worktree": wt.Name, "port": wt.Port, "hours": 1000}, nil); status != 400 {
		t.Errorf("a link for 1000 hours = %d", status)
	}
	var list []Share
	call(t, c, "GET", "/v1/shares", "", nil, &list)
	if len(list) != 1 {
		t.Fatalf("shares = %+v", list)
	}
	if status := call(t, c, "DELETE", "/v1/shares/"+sh.Name, "", nil, nil); status != 200 || len(pub.published) != 0 {
		t.Fatalf("remove = %d %v", status, pub.published)
	}
}
