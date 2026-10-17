package box

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/wire"
)

// testdata/logins holds the sign-ins' screens as tmux shows them (capture-pane -p -J): claude.txt (Claude Code
// 2.1 `claude auth login`), codex.txt (Codex 0.160 `codex login --device-auth`), gh-question.txt and gh-code-mac.txt
// (gh 2.102 `gh auth login --web --git-protocol https`, before and after its first question, on a Mac where it copies
// the code) were captured from the real CLIs in throwaway config folders; gh-code-linux.txt is the same screen where
// gh has no clipboard, and gh-reauth.txt an older gh's question when it is signed in already, as gh's source prints
// them.
func loginFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "logins", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestReadLoginScreens(t *testing.T) {
	claude := readLoginScreen("claude", loginFixture(t, "claude.txt"))
	if !strings.HasPrefix(claude.URL, "https://claude.com/cai/oauth/authorize?code=true&client_id=") || !strings.HasSuffix(claude.URL, "&state=vFvlZ30w-0zrCLgkPFdUe_44vPeY923UV2QCfmXU0ac") {
		t.Errorf("claude URL = %q", claude.URL)
	}
	if claude.Code != "" || claude.Prompts != 1 || claude.PressEnter || claude.GitQuestion {
		t.Errorf("claude = %+v", claude)
	}

	codex := readLoginScreen("codex", loginFixture(t, "codex.txt"))
	if codex.URL != "https://auth.openai.com/codex/device" || codex.Code != "0Z7Z-OCWM5" || codex.Prompts != 0 {
		t.Errorf("codex = %+v", codex)
	}

	q := readLoginScreen("gh", loginFixture(t, "gh-question.txt"))
	if !q.GitQuestion || q.PressEnter || q.URL != "" || q.Code != "" {
		t.Errorf("gh's question = %+v", q)
	}
	for file, code := range map[string]string{"gh-code-mac.txt": "948B-8C30", "gh-code-linux.txt": "1F2E-3D4C"} {
		sc := readLoginScreen("gh", loginFixture(t, file))
		if sc.GitQuestion || !sc.PressEnter || sc.URL != "https://github.com/login/device" || sc.Code != code {
			t.Errorf("%s = %+v", file, sc)
		}
	}
}

// What each screen means for the sign-in: Claude Code's link then its paste prompt, the code going in, a code it did
// not take; gh's two questions answered once each; Codex's device code.
func TestLoginStates(t *testing.T) {
	claudeScreen := loginFixture(t, "claude.txt")
	l := &loginRun{Login: Login{Tool: "claude", State: LoginStarting, NeedsCode: true}}
	if l.advance(readLoginScreen("claude", "Opening browser to sign in…\n")); l.State != LoginStarting {
		t.Fatalf("no link yet: %s", l.State)
	}
	linkOnly := strings.Split(claudeScreen, "Paste code here")[0]
	if l.advance(readLoginScreen("claude", linkOnly)); l.State != LoginOpenLink || l.URL == "" {
		t.Fatalf("the link alone: %+v", l.Login)
	}
	if l.advance(readLoginScreen("claude", claudeScreen)); l.State != LoginEnterCode {
		t.Fatalf("the paste prompt: %s", l.State)
	}
	l.codeSent, l.prompts, l.State = true, 1, LoginWaiting
	if l.advance(readLoginScreen("claude", claudeScreen+"code#state\nLogging in…\n")); l.State != LoginWaiting {
		t.Fatalf("the code went in: %s", l.State)
	}
	again := claudeScreen + "code#state\nOAuth error: Invalid code\nPaste code here if prompted >\n"
	if l.advance(readLoginScreen("claude", again)); l.State != LoginEnterCode || l.Error == "" || l.codeSent {
		t.Fatalf("asked again: %+v", l.Login)
	}

	g := &loginRun{Login: Login{Tool: "gh", State: LoginStarting}}
	if keys := g.advance(readLoginScreen("gh", loginFixture(t, "gh-question.txt"))); len(keys) != 1 || keys[0] != "Enter" || g.State != LoginStarting {
		t.Fatalf("gh's git question: keys %v, %s", keys, g.State)
	}
	if keys := g.advance(readLoginScreen("gh", loginFixture(t, "gh-question.txt"))); len(keys) != 0 {
		t.Fatalf("the question was answered twice: %v", keys)
	}
	code := loginFixture(t, "gh-code-linux.txt")
	if keys := g.advance(readLoginScreen("gh", code)); len(keys) != 1 || g.State != LoginOpenLink || g.UserCode != "1F2E-3D4C" || g.URL != "https://github.com/login/device" {
		t.Fatalf("gh's code: keys %v, %+v", keys, g.Login)
	}
	if keys := g.advance(readLoginScreen("gh", code)); len(keys) != 0 || g.State != LoginOpenLink {
		t.Fatalf("Enter was pressed twice: %v", keys)
	}

	c := &loginRun{Login: Login{Tool: "codex", State: LoginStarting}}
	if keys := c.advance(readLoginScreen("codex", loginFixture(t, "codex.txt"))); len(keys) != 0 || c.State != LoginOpenLink || c.UserCode != "0Z7Z-OCWM5" {
		t.Fatalf("codex: keys %v, %+v", keys, c.Login)
	}
	// A code in a shape the screen reading does not know: the link alone goes on, the code is on the page.
	odd := &loginRun{Login: Login{Tool: "codex", State: LoginStarting}}
	if odd.advance(readLoginScreen("codex", strings.Replace(loginFixture(t, "codex.txt"), "0Z7Z-OCWM5", "zz-9", 1))); odd.State != LoginOpenLink || odd.UserCode != "" {
		t.Fatalf("codex without a code read: %+v", odd.Login)
	}

	// An older gh, signed in already, asks whether to sign in again: yes, that is what the person asked for.
	re := &loginRun{Login: Login{Tool: "gh", State: LoginStarting}}
	if keys := re.advance(readLoginScreen("gh", loginFixture(t, "gh-reauth.txt"))); strings.Join(keys, " ") != "y Enter" {
		t.Fatalf("gh's re-authenticate question: keys %v", keys)
	}
	if keys := re.advance(readLoginScreen("gh", loginFixture(t, "gh-reauth.txt"))); len(keys) != 0 {
		t.Fatalf("answered twice: %v", keys)
	}
	// A code that went in before Claude Code showed its prompt is not taken for one it refused.
	early := &loginRun{Login: Login{Tool: "claude", State: LoginWaiting, NeedsCode: true, URL: "https://claude.com/cai/oauth/authorize?x"}, codeSent: true, prompts: 0}
	if early.advance(readLoginScreen("claude", claudeScreen)); early.State != LoginWaiting || early.Error != "" {
		t.Fatalf("a code sent before the prompt: %+v", early.Login)
	}
}

// fakeCLIs puts stand-ins for claude, codex and gh on a PATH of their own (with tmux beside them, and nothing else, so
// a test never finds the developer's own CLIs), each signing in the way the real one does and keeping what happened in
// state. HOME is a folder of the test's, so the agents' own settings folders are too.
func fakeCLIs(t *testing.T, which ...string) (state string) {
	t.Helper()
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux not installed")
	}
	bin, state := t.TempDir(), t.TempDir()
	os.Symlink(tmux, filepath.Join(bin, "tmux"))
	if git, err := exec.LookPath("git"); err == nil {
		os.Symlink(git, filepath.Join(bin, "git"))
	}
	scripts := map[string]string{
		"claude": `case "$1 $2" in
"auth login")
  echo "$CLAUDE_CONFIG_DIR" > "$S/config-dir"
  echo "Opening browser to sign in…"
  echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=abc"
  while :; do
    printf 'Paste code here if prompted > '
    read code
    if [ "$code" = "good#state" ]; then echo "Login successful."; touch "$S/claude-ok"; exit 0; fi
    if [ "$code" = "spent#state" ]; then echo "OAuth error: invalid_grant for $code"; exit 1; fi
    echo "OAuth error: Invalid code"
  done ;;
"auth status")
  if [ -f "$S/claude-ok" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai"}'; exit 0; fi
  echo '{"loggedIn": false, "authMethod": "none"}'; exit 1 ;;
esac`,
		"codex": `case "$1 $2" in
"login --device-auth")
  echo "Follow these steps to sign in with ChatGPT using device code authorization:"
  echo "1. Open this link in your browser and sign in to your account"
  echo "   https://auth.openai.com/codex/device"
  echo "2. Enter this one-time code (expires in 15 minutes)"
  echo "   AB12-CD345"
  while [ ! -f "$S/codex-go" ]; do sleep 0.1; done
  if [ -f "$S/codex-fail" ]; then echo "Error logging in with device code: device code expired"; exit 1; fi
  echo "Successfully logged in" ;;
"login status")
  if [ -f "$S/codex-ok" ]; then echo "Logged in using ChatGPT"; exit 0; fi
  echo "Not logged in"; exit 1 ;;
esac`,
		"gh": `case "$1 $2" in
"auth login")
  printf '? Authenticate Git with your GitHub credentials? (Y/n) '
  read a
  echo "? Authenticate Git with your GitHub credentials? Yes"
  echo "! First copy your one-time code: 1F2E-3D4C"
  printf 'Press Enter to open https://github.com/login/device in your browser... '
  read b
  echo "$GH_BROWSER" > "$S/gh-browser"
  while [ ! -f "$S/gh-authorized" ]; do sleep 0.1; done
  echo "✓ Authentication complete."
  touch "$S/gh-ok"
  echo "✓ Logged in as octocat" ;;
"auth status") [ -f "$S/gh-ok" ] ;;
"auth setup-git") touch "$S/gh-setup-git" ;;
*) exit 2 ;;
esac`,
	}
	for _, name := range which {
		script := "#!/bin/sh\nPATH=/usr/bin:/bin; export PATH\nS='" + state + "'\n" + scripts[name] + "\n"
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	t.Setenv("HOME", t.TempDir())
	for _, k := range []string{"CLAUDE_CONFIG_DIR", "CODEX_HOME", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	return state
}

// waitLogin reads a sign-in until ok says it is where the test wants it.
func waitLogin(t *testing.T, c *wire.Client, id string, ok func(Login) bool) Login {
	t.Helper()
	var l Login
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		l = Login{}
		call(t, c, "GET", "/v1/logins/"+id, "", nil, &l)
		if ok(l) {
			return l
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("sign-in %s stayed at %+v", id, l)
	return l
}

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func sessionGone(t *testing.T, bx *Box, name string) bool {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := bx.Sessions.Get(context.Background(), name); err != nil {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

// GitHub's sign-in from the app: the questions answered, the link and code read off the screen, done once gh's own
// status agrees, git set up through gh's credentials, the session gone; and nothing of the link or code in events.
func TestGitHubSignInFromTheApp(t *testing.T) {
	state := fakeCLIs(t, "gh")
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { bx = b })
	seen, stop := bus.Subscribe()
	defer stop()

	var l Login
	if status := call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "gh"}, &l); status != 202 || l.ID == "" || l.Session != "login-gh" || l.NeedsCode {
		t.Fatalf("start = %d %+v", status, l)
	}
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.State == LoginOpenLink })
	if l.URL != "https://github.com/login/device" || l.UserCode != "1F2E-3D4C" {
		t.Fatalf("open_link = %+v", l)
	}
	touch(t, filepath.Join(state, "gh-authorized"))
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.Finished != nil })
	if l.State != LoginDone || l.Error != "" {
		t.Fatalf("finished = %+v", l)
	}
	if _, err := os.Stat(filepath.Join(state, "gh-setup-git")); err != nil {
		t.Error("gh auth setup-git did not run")
	}
	if b, _ := os.ReadFile(filepath.Join(state, "gh-browser")); strings.TrimSpace(string(b)) != "true" {
		t.Errorf("gh would open a browser on the box: GH_BROWSER=%q", b)
	}
	if !sessionGone(t, bx, "login-gh") {
		t.Error("the sign-in's session stayed")
	}
	var states []string
	for done := false; !done; {
		select {
		case e := <-seen:
			if e.Type != "login.changed" {
				continue
			}
			if e.Data["url"] != nil || e.Data["user_code"] != nil || strings.Contains(e.Error, "1F2E") {
				t.Fatalf("an event carries the link or the code: %+v", e)
			}
			states = append(states, e.Data["state"].(string))
			done = e.Data["state"] == LoginDone
		case <-time.After(5 * time.Second):
			t.Fatalf("login.changed events: %v", states)
		}
	}
	if strings.Join(states, " ") != "starting open_link done" {
		t.Errorf("states = %v", states)
	}
}

// Claude Code's sign-in on an added account: the account's folder reaches the CLI, the code typed back goes in, a code
// it does not take asks for another, and the right one ends it.
func TestClaudeSignInTakesTheCodeBack(t *testing.T) {
	state := fakeCLIs(t, "claude")
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); b.Exe = "/opt/pier/pierd"; bx = b })
	seen, stop := bus.Subscribe()
	defer stop()
	var a AccountView
	call(t, c, "POST", "/v1/accounts", "", map[string]string{"agent": "claude", "name": "Trabalho"}, &a)

	var l Login
	if status := call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "claude", "account": a.ID}, &l); status != 202 || !l.NeedsCode || l.Account != a.ID {
		t.Fatalf("start = %d %+v", status, l)
	}
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.State == LoginEnterCode })
	if !strings.Contains(l.URL, "oauth/authorize") {
		t.Fatalf("enter_code = %+v", l)
	}
	if b, _ := os.ReadFile(filepath.Join(state, "config-dir")); strings.TrimSpace(string(b)) != a.Dir {
		t.Fatalf("CLAUDE_CONFIG_DIR = %q, want the account's %q", b, a.Dir)
	}
	if status := call(t, c, "POST", "/v1/logins/"+l.ID+"/code", "", map[string]string{"code": "wrong\nline"}, nil); status != 400 {
		t.Fatalf("a code with a line break = %d", status)
	}
	var sent Login
	if status := call(t, c, "POST", "/v1/logins/"+l.ID+"/code", "", map[string]string{"code": " nope#state "}, &sent); status != 200 || sent.State != LoginWaiting {
		t.Fatalf("code = %d %+v", status, sent)
	}
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.State == LoginEnterCode })
	if l.Error == "" {
		t.Fatalf("a code it did not take: %+v", l)
	}
	call(t, c, "POST", "/v1/logins/"+l.ID+"/code", "", map[string]string{"code": "good#state"}, nil)
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.Finished != nil })
	if l.State != LoginDone {
		t.Fatalf("finished = %+v", l)
	}
	if status := call(t, c, "POST", "/v1/logins/"+l.ID+"/code", "", map[string]string{"code": "good#state"}, nil); status != 409 {
		t.Fatalf("a code for a finished sign-in = %d", status)
	}
	if !sessionGone(t, bx, l.Session) {
		t.Error("the sign-in's session stayed")
	}
	for {
		select {
		case e := <-seen:
			if e.Type == "account.changed" && e.Data["id"] == a.ID {
				return
			}
		case <-time.After(5 * time.Second):
			t.Fatal("no account.changed for the account that signed in")
		}
	}
}

// A sign-in that fails says why in the CLI's words; one whose CLI exits cleanly but whose status disagrees is not done.
func TestSignInsThatFail(t *testing.T) {
	state := fakeCLIs(t, "codex")
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })

	var l Login
	call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "codex"}, &l)
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.State == LoginOpenLink })
	if l.UserCode != "AB12-CD345" || l.Account != "codex" || l.Session != "login-codex" {
		t.Fatalf("open_link = %+v", l)
	}
	touch(t, filepath.Join(state, "codex-fail"))
	touch(t, filepath.Join(state, "codex-go"))
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.Finished != nil })
	if l.State != LoginFailed || !strings.Contains(l.Error, "device code expired") {
		t.Fatalf("failed = %+v", l)
	}

	os.Remove(filepath.Join(state, "codex-fail"))
	os.Remove(filepath.Join(state, "codex-go"))
	call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "codex"}, &l)
	waitLogin(t, c, l.ID, func(l Login) bool { return l.State == LoginOpenLink })
	touch(t, filepath.Join(state, "codex-go"))
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.Finished != nil })
	if l.State != LoginFailed || !strings.Contains(l.Error, "not signed in") {
		t.Fatalf("exited cleanly, status says no: %+v", l)
	}

	var e struct{ Code string }
	if status := call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "gh"}, &e); status != 424 || e.Code != CodeToolMissing {
		t.Fatalf("gh not installed = %d %+v", status, e)
	}
	if status := call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "node"}, nil); status != 400 {
		t.Fatalf("an unknown tool = %d", status)
	}
	if status := call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "codex", "account": "claude"}, nil); status != 400 {
		t.Fatalf("a claude account for codex = %d", status)
	}
}

// Closing the sign-in in the app cancels it and ends its session; a second sign-in to the same account replaces the
// first; the old accounts route starts one too and still answers its session.
func TestSignInsCanceledReplacedAndFromTheAccountsRoute(t *testing.T) {
	fakeCLIs(t, "codex")
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); bx = b })
	seen, stop := bus.Subscribe()
	defer stop()

	var first, second Login
	call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "codex"}, &first)
	waitLogin(t, c, first.ID, func(l Login) bool { return l.State == LoginOpenLink })
	var sess struct {
		Session
		Login string `json:"login"`
	}
	if status := call(t, c, "POST", "/v1/accounts/codex/login", "", nil, &sess); status != 200 || sess.Name != "login-codex" || sess.Login == "" {
		t.Fatalf("accounts route = %d %+v", status, sess)
	}
	first = waitLogin(t, c, first.ID, func(l Login) bool { return l.Finished != nil })
	if first.State != LoginFailed {
		t.Fatalf("the replaced sign-in = %+v", first)
	}
	second = waitLogin(t, c, sess.Login, func(l Login) bool { return l.State == LoginOpenLink })
	var list []Login
	if call(t, c, "GET", "/v1/logins", "", nil, &list); len(list) != 2 || list[0].ID != second.ID {
		t.Fatalf("list = %+v", list)
	}
	if status := call(t, c, "DELETE", "/v1/logins/"+second.ID, "", nil, &second); status != 200 || second.State != LoginFailed || second.Error != "canceled" {
		t.Fatalf("delete = %d %+v", status, second)
	}
	if !sessionGone(t, bx, "login-codex") {
		t.Error("the canceled sign-in's session stayed")
	}
	// Its end is said as any session's is: the app's lists and the turn ledger let go of it.
	for stopped := 0; stopped < 2; {
		select {
		case e := <-seen:
			if e.Type == "session.stopped" && e.Data["name"] == "login-codex" {
				stopped++ // the replaced sign-in's session, then the canceled one's
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("session.stopped for login-codex: %d of 2", stopped)
		}
	}
	if status := call(t, c, "GET", "/v1/logins/nope", "", nil, nil); status != 404 {
		t.Fatalf("an unknown sign-in = %d", status)
	}
}

// A sign-in nobody finishes ends on its own (15 minutes, as long as the device codes last) and takes its session with it.
func TestSignInTimesOut(t *testing.T) {
	fakeCLIs(t, "codex")
	defer func(d time.Duration) { loginTimeout = d }(loginTimeout)
	loginTimeout = 1500 * time.Millisecond
	var bx *Box
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir(); bx = b })
	var l Login
	call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "codex"}, &l)
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.Finished != nil })
	if l.State != LoginFailed || !strings.Contains(l.Error, "took more than") {
		t.Fatalf("timed out = %+v", l)
	}
	if !sessionGone(t, bx, l.Session) {
		t.Error("the session of a sign-in that timed out stayed")
	}
}

// A sign-in that fails quotes the CLI's last lines, but not the code that was typed into it.
func TestFailedSignInKeepsTheCodeOutOfItsError(t *testing.T) {
	fakeCLIs(t, "claude")
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })
	var l Login
	call(t, c, "POST", "/v1/logins", "", map[string]string{"tool": "claude"}, &l)
	waitLogin(t, c, l.ID, func(l Login) bool { return l.State == LoginEnterCode })
	call(t, c, "POST", "/v1/logins/"+l.ID+"/code", "", map[string]string{"code": "spent#state"}, nil)
	l = waitLogin(t, c, l.ID, func(l Login) bool { return l.Finished != nil })
	if l.State != LoginFailed || !strings.Contains(l.Error, "invalid_grant") || strings.Contains(l.Error, "spent#state") || strings.Contains(l.Error, "oauth/authorize") {
		t.Fatalf("failed = %+v", l)
	}
}

// A restarted pierd ends the sign-ins a previous one left waiting, and nothing else.
func TestStaleSignInsEndAtStart(t *testing.T) {
	fakeCLIs(t, "codex")
	var bx *Box
	servedBox(t, func(b *Box) { bx = b })
	ctx := context.Background()
	codex, _ := exec.LookPath("codex")
	for name, command := range map[string]string{"login-codex": shellQuote(codex) + " login --device-auth", "login-notes": "sleep 30", "work": "sleep 30"} {
		if _, err := bx.Sessions.Create(ctx, name, "", t.TempDir(), command, nil); err != nil {
			t.Fatal(err)
		}
	}
	bx.EndStaleSignIns(ctx)
	if !sessionGone(t, bx, "login-codex") {
		t.Error("a sign-in left from before stayed")
	}
	for _, name := range []string{"login-notes", "work"} {
		if _, err := bx.Sessions.Get(ctx, name); err != nil {
			t.Errorf("%s went too: %v", name, err)
		}
	}
}
