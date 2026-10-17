package box

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"pier/pierd/internal/events"
	"pier/pierd/internal/installer"
)

// Signing in to Claude Code, Codex and GitHub from the app, with no terminal: pierd runs the CLI's own sign-in in a
// tmux session wide enough that a link stays on one line (claude auth login, codex login --device-auth, gh auth login
// --web), reads the link and the one-time code off its screen for the app, types back the code Claude Code's page
// shows (POST …/code), and calls the sign-in done only when the CLI exited cleanly and its own status command agrees.
// The session is an ordinary one meanwhile: the app's "Abrir no terminal" shows it, for whatever the screen reading
// does not cover. The links and codes stay out of events, which the journal keeps.

// Login is one sign-in (POST /v1/logins).
type Login struct {
	ID      string `json:"id"`
	Tool    string `json:"tool"`
	Account string `json:"account,omitempty"`
	// State is starting; open_link (the link, and for a device sign-in its one-time code, are ready: the person opens
	// the link); enter_code (Claude Code waits for the code its page shows, pasted back); waiting (the code went in,
	// the CLI finishes); done; or failed (Error says why).
	State    string `json:"state"`
	URL      string `json:"url,omitempty"`
	UserCode string `json:"user_code,omitempty"`
	// NeedsCode says the page shows a code to bring back to the box (Claude Code): POST …/code types it in.
	NeedsCode bool       `json:"needs_code"`
	Session   string     `json:"session"`
	Error     string     `json:"error,omitempty"`
	Started   time.Time  `json:"started"`
	Finished  *time.Time `json:"finished,omitempty"`
}

const (
	LoginStarting  = "starting"
	LoginOpenLink  = "open_link"
	LoginEnterCode = "enter_code"
	LoginWaiting   = "waiting"
	LoginDone      = "done"
	LoginFailed    = "failed"
)

// loginTimeout is how long a sign-in may take: the device codes expire after 15 minutes too.
var loginTimeout = 15 * time.Minute

// loginCols × loginRows is a sign-in session's window until a terminal attaches: Claude Code's link is over 600
// characters, and a link cut across lines would not be found whole.
const loginCols, loginRows = 1000, 50

// loginCommand is each CLI's sign-in, after its path: the subscription sign-in of Claude Code (no TUI), Codex's
// device code, and GitHub's browser one with git over HTTPS through gh's credentials.
var loginCommand = map[string]string{
	"claude": "auth login",
	"codex":  "login --device-auth",
	"gh":     "auth login --web --git-protocol https --hostname github.com",
}

// loginStatus is each CLI's own answer to "signed in?": exit 0 when it is.
var loginStatus = map[string][]string{
	"claude": {"auth", "status", "--json"},
	"codex":  {"login", "status"},
	"gh":     {"auth", "status", "--hostname", "github.com"},
}

// loginRun is a sign-in with what its runner keeps.
type loginRun struct {
	Login
	// bin is the CLI, env what its session got on top of the box's (the account's folder), path the PATH it was
	// found with: its status command runs with the same.
	bin, path string
	env       []string
	cancel    context.CancelFunc
	// gh's questions are answered once each: signing in again (yes), git through gh's credentials (yes), and Enter to
	// go on.
	reauthAnswered, gitAnswered, enterPressed bool
	// codeSent and prompts: a code went in while Claude Code showed that many paste prompts. code is the last one
	// typed, kept only to take it out of the error a failure quotes from the screen.
	codeSent bool
	prompts  int
	code     string
}

type loginStore struct {
	mu  sync.Mutex
	all []*loginRun
}

func (s *loginStore) add(l *loginRun) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Finished ones are kept an hour, for a client that comes back to read how it went.
	keep := s.all[:0]
	for _, x := range s.all {
		if x.Finished == nil || time.Since(*x.Finished) < time.Hour {
			keep = append(keep, x)
		}
	}
	s.all = append(keep, l)
}

// with runs f on the sign-in id under the lock, and says what it was before and is after.
func (s *loginStore) with(id string, f func(*loginRun)) (before, after Login, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, l := range s.all {
		if l.ID == id {
			before = l.Login
			f(l)
			return before, l.Login, true
		}
	}
	return Login{}, Login{}, false
}

func (s *loginStore) get(id string) (loginRun, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, l := range s.all {
		if l.ID == id {
			return *l, true
		}
	}
	return loginRun{}, false
}

func (s *loginStore) list() []Login {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []Login{}
	for _, l := range s.all {
		out = append(out, l.Login)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Started.After(out[j].Started) })
	return out
}

// running are the unfinished sign-ins in session name.
func (s *loginStore) running(session string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ids []string
	for _, l := range s.all {
		if l.Session == session && l.Finished == nil {
			ids = append(ids, l.ID)
		}
	}
	return ids
}

func finished(l *loginRun, state, why string) {
	if l.Finished != nil {
		return
	}
	// The screen a failure quotes can show the code typed into it, the one-time code or the sign-in's link: none of
	// them stays in the error.
	for _, secret := range []string{l.code, l.UserCode, l.URL} {
		if len(secret) >= 4 {
			why = strings.ReplaceAll(why, secret, "…")
		}
	}
	why = loginURL.ReplaceAllStringFunc(why, func(u string) string {
		if strings.Contains(u, loginURLHint[l.Tool]) {
			return "…"
		}
		return u
	})
	now := time.Now().UTC()
	l.State, l.Error, l.Finished = state, why, &now
	if l.cancel != nil {
		l.cancel()
	}
}

// --- reading the screen ---

// loginScreen is what a sign-in's screen says.
type loginScreen struct {
	URL, Code string
	// Prompts counts Claude Code's "Paste code here" prompts: one more after a code went in means it asks again.
	Prompts int
	// GitQuestion: gh asks whether git should use its credentials. PressEnter: gh waits for Enter before it opens a
	// browser (on the box, none: GH_BROWSER) and starts asking GitHub whether the code was entered. Reauth: an older gh
	// already signed in asks whether to sign in again.
	GitQuestion, PressEnter, Reauth bool
}

var (
	loginURL    = regexp.MustCompile("https://[^\\s\"'<>`]+")
	loginCode   = regexp.MustCompile(`\b[A-Z0-9]{4,5}-[A-Z0-9]{4,6}\b`)
	pastePrompt = regexp.MustCompile(`(?i)paste code here`)
	gitQuestion = regexp.MustCompile(`(?i)authenticate git with your github credentials\?\s*\(y/n\)`)
	pressEnter  = regexp.MustCompile(`(?i)press enter to open`)
	reauth      = regexp.MustCompile(`(?i)do you want to re-?authenticate\?\s*\(y/n\)`)
)

// loginURLHint is in the link each CLI shows, to tell it from any other.
var loginURLHint = map[string]string{"claude": "oauth/authorize", "codex": "/device", "gh": "/login/device"}

// readLoginScreen reads a sign-in's screen, as tool prints it (fixtures in testdata/logins).
func readLoginScreen(tool, screen string) loginScreen {
	var sc loginScreen
	var urls []string
	for _, u := range loginURL.FindAllString(screen, -1) {
		urls = append(urls, strings.TrimRight(u, ".,;:)]}>"))
	}
	for _, u := range urls {
		if strings.Contains(u, loginURLHint[tool]) {
			sc.URL = u
			break
		}
	}
	if sc.URL == "" && len(urls) > 0 {
		sc.URL = urls[0]
	}
	if tool != "claude" {
		// The code is never inside a link: Claude Code's carries look-alikes.
		sc.Code = loginCode.FindString(loginURL.ReplaceAllString(screen, " "))
	}
	sc.Prompts = len(pastePrompt.FindAllStringIndex(screen, -1))
	sc.GitQuestion = gitQuestion.MatchString(screen)
	sc.PressEnter = pressEnter.MatchString(screen)
	sc.Reauth = reauth.MatchString(screen)
	return sc
}

// advance moves the sign-in on with what its screen shows now, and says which keys to press: gh's questions are
// answered once each, the rest is read.
func (l *loginRun) advance(sc loginScreen) (keys []string) {
	if sc.URL != "" {
		l.URL = sc.URL
	}
	if sc.Code != "" {
		l.UserCode = sc.Code
	}
	if l.Tool == "gh" {
		// Signing in again is what the person asked for.
		if sc.Reauth && !l.reauthAnswered {
			l.reauthAnswered = true
			keys = append(keys, "y", "Enter")
		}
		if sc.GitQuestion && !l.gitAnswered {
			l.gitAnswered = true
			keys = append(keys, "Enter")
		}
		if sc.PressEnter && !l.enterPressed {
			l.enterPressed = true
			keys = append(keys, "Enter")
		}
	}
	if l.Tool != "claude" {
		// The link is enough to go on: a code that was not read is on the page or in "Abrir no terminal".
		if l.URL != "" {
			l.State = LoginOpenLink
		}
		return keys
	}
	switch {
	case l.codeSent && l.prompts > 0 && sc.Prompts > l.prompts:
		// It asks again: the code did not take.
		l.codeSent = false
		l.State, l.Error = LoginEnterCode, "Claude Code did not take that code; copy it again from the page"
	case l.codeSent:
		l.State = LoginWaiting
	case l.URL != "" && sc.Prompts > 0:
		l.State = LoginEnterCode
	case l.URL != "":
		l.State = LoginOpenLink
	}
	return keys
}

// lastWordyLines are the screen's last n lines with words on them, for a failure to quote.
func lastWordyLines(screen string, n int) string {
	var out []string
	for _, l := range strings.Split(screen, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	if len(out) > n {
		out = out[len(out)-n:]
	}
	return strings.Join(out, "\n")
}

// --- running it ---

// paneExit says whether the program in session name ended, and with which status (-1 when tmux does not say).
func (s *Sessions) paneExit(ctx context.Context, name string) (bool, int, error) {
	out, err := s.tmux(ctx, "display-message", "-p", "-t", "="+name+":", "#{pane_dead} #{pane_dead_status}")
	if err != nil {
		if strings.Contains(string(out), "can't find") {
			return false, 0, ErrUnknownSession
		}
		return false, 0, tmuxError("display-message", out, err)
	}
	f := strings.Fields(string(out))
	status := -1
	if len(f) > 1 {
		if n, err := strconv.Atoi(f[1]); err == nil {
			status = n
		}
	}
	return len(f) > 0 && f[0] == "1", status, nil
}

// pressKeys presses keys (tmux key names) in session name, or types text when literal.
func (s *Sessions) pressKeys(ctx context.Context, name string, literal bool, keys ...string) error {
	for _, k := range keys {
		args := []string{"send-keys", "-t", "=" + name + ":", k}
		if literal {
			args = []string{"send-keys", "-t", "=" + name + ":", "-l", "--", tmuxArg(k)}
		}
		if out, err := s.tmux(ctx, args...); err != nil {
			return tmuxSendError("send-keys", out, err)
		}
	}
	return nil
}

// loginScreenText is the end of a sign-in's screen, its lines joined back where the window wrapped them.
func (s *Sessions) loginScreenText(ctx context.Context, name string) string {
	out, _ := s.tmux(ctx, "capture-pane", "-p", "-J", "-t", "="+name+":", "-S", "-200")
	return string(out)
}

// defaultAccount is the account an agent uses where nothing chose one: the added account made the box's default,
// else the agent's own folder.
func (b *Box) defaultAccount(agent string) (Account, bool) {
	if id := b.loadAccounts().Defaults[agent]; id != "" {
		if a, ok := b.account(id); ok && a.Agent == agent {
			return a, true
		}
	}
	for _, a := range builtinAccounts() {
		if a.Agent == agent {
			return a, true
		}
	}
	return Account{}, false
}

func newLoginID() string {
	var b [6]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// startLogin starts a sign-in to tool (claude, codex or gh) in a session of its own: for claude and codex on account (an
// id of GET /v1/accounts; the default one when empty), whose folder the CLI gets. A sign-in already running for the
// same tool and account gives way to it.
func (b *Box) startLogin(r *http.Request, tool, account string) (Login, Session, error) {
	ctx := r.Context()
	t, ok := installer.Lookup(tool)
	if !ok {
		return Login{}, Session{}, badRequest("sign-ins are for claude, codex or gh, not %q", tool)
	}
	home, _ := os.UserHomeDir()
	dir := home
	// No browser opens on the box: the app opens the link where the person is.
	env := []string{"BROWSER=true"}
	var acct *Account
	switch tool {
	case "claude", "codex":
		var a Account
		if account == "" {
			a, ok = b.defaultAccount(tool)
		} else {
			a, ok = b.account(account)
		}
		if !ok {
			return Login{}, Session{}, errUnknownAccount
		}
		if a.Agent != tool {
			return Login{}, Session{}, badRequest("%q is not a %s account", a.ID, tool)
		}
		acct, account, dir = &a, a.ID, a.Dir
		if !a.Builtin {
			env = append(env, agentDirVar[tool]+"="+a.Dir)
		}
	case "gh":
		if account != "" {
			return Login{}, Session{}, badRequest("GitHub has no accounts on the box; leave account out")
		}
		env = append(env, "GH_BROWSER=true", "GH_NO_UPDATE_NOTIFIER=1")
	}
	f, ok := b.toolFound(ctx, t.Command)
	if !ok {
		return Login{}, Session{}, httpError{http.StatusFailedDependency, t.Name + " " + errToolMissing.Error() + "; install it first (POST /v1/tools/install)"}
	}
	if err := b.before(r, "login.start", map[string]any{"tool": tool, "account": account}); err != nil {
		return Login{}, Session{}, err
	}
	// The account's folder, with pierd's hooks, before its CLI writes its login there.
	if acct != nil {
		if err := b.prepareAccountDir(*acct); err != nil {
			return Login{}, Session{}, err
		}
	}
	name := "login-" + slug(firstNonEmpty(account, tool), 40)
	for _, id := range b.logins.running(name) {
		_, after, _ := b.logins.with(id, func(l *loginRun) { finished(l, LoginFailed, "another sign-in to the same account started") })
		b.publishLogin(origin(r), after)
	}
	b.endLoginSession(origin(r), name)
	command := shellQuote(f.Path) + " " + loginCommand[tool]
	sess, err := b.Sessions.createSized(ctx, name, "", dir, command, "", env, nil, loginCols, loginRows)
	if err != nil {
		return Login{}, Session{}, err
	}
	run := &loginRun{
		Login: Login{ID: newLoginID(), Tool: tool, Account: account, State: LoginStarting, NeedsCode: tool == "claude",
			Session: name, Started: time.Now().UTC()},
		bin: f.Path, path: f.PATH, env: env,
	}
	runCtx, cancel := context.WithCancel(context.Background())
	run.cancel = cancel
	b.logins.add(run)
	b.publish(r, "session.started", map[string]any{"name": sess.Name, "path": dir, "command": command})
	b.publishLogin(origin(r), run.Login)
	go b.runLogin(runCtx, origin(r), run.ID)
	return run.Login, sess, nil
}

// publishLogin says a sign-in's state, without its link or code: events are kept in the journal.
func (b *Box) publishLogin(origin string, l Login) {
	data := map[string]any{"id": l.ID, "tool": l.Tool, "state": l.State}
	if l.Account != "" {
		data["account"] = l.Account
	}
	b.Events.Publish(events.Event{Type: "login.changed", Box: b.Name, Origin: origin, Data: data})
}

// EndStaleSignIns ends the sign-in sessions a previous pierd left: a restart forgets its sign-ins, so nothing would
// follow them, and their CLIs would wait for a code until someone killed them.
func (b *Box) EndStaleSignIns(ctx context.Context) {
	all, err := b.Sessions.List(ctx)
	if err != nil {
		return
	}
	for _, s := range all {
		if strings.HasPrefix(s.Name, "login-") && signInCommand(s.Command) {
			b.endLoginSession(DefaultOrigin, s.Name)
		}
	}
}

// signInCommand says whether a session's command is a sign-in's: this pierd's, or the terminal an older one opened on
// Claude Code's /login or Codex's device sign-in.
func signInCommand(command string) bool {
	for _, args := range loginCommand {
		if strings.HasSuffix(command, " "+args) {
			return true
		}
	}
	switch command {
	case "claude", "claude /login", "codex login --device-auth":
		return true
	}
	return false
}

// endLoginSession ends a sign-in's session and says so, as ending any session does: the session lists and the turn
// ledger let go of it.
func (b *Box) endLoginSession(origin, name string) {
	if b.Sessions.Kill(context.Background(), name) == nil {
		b.Events.Publish(events.Event{Type: "session.stopped", Box: b.Name, Origin: origin, Data: map[string]any{"name": name}})
	}
}

// update changes a sign-in and says so when its state moved.
func (b *Box) updateLogin(origin, id string, f func(*loginRun)) (Login, bool) {
	before, after, ok := b.logins.with(id, f)
	if ok && before.State != after.State {
		b.publishLogin(origin, after)
	}
	return after, ok
}

// runLogin follows a sign-in's session until it is done, fails or times out (or the sign-in is canceled).
func (b *Box) runLogin(ctx context.Context, origin, id string) {
	deadline := time.Now().Add(loginTimeout)
	interval := 300 * time.Millisecond
	for i := 0; ; i++ {
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
		if i == 60 {
			interval = time.Second
		}
		run, ok := b.logins.get(id)
		if !ok || run.Finished != nil {
			return
		}
		if time.Now().After(deadline) {
			b.updateLogin(origin, id, func(l *loginRun) {
				finished(l, LoginFailed, fmt.Sprintf("the sign-in took more than %d minutes; start it again", int(loginTimeout.Minutes())))
			})
			b.endLoginSession(origin, run.Session)
			return
		}
		dead, status, err := b.Sessions.paneExit(ctx, run.Session)
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, ErrUnknownSession) {
			b.updateLogin(origin, id, func(l *loginRun) { finished(l, LoginFailed, "the sign-in's session ended before it was done") })
			return
		}
		if err != nil {
			continue // tmux did not answer this time: the next look will tell
		}
		screen := b.Sessions.loginScreenText(ctx, run.Session)
		if dead {
			b.finishLogin(ctx, origin, id, status, screen)
			return
		}
		var keys []string
		b.updateLogin(origin, id, func(l *loginRun) {
			if l.Finished == nil {
				keys = l.advance(readLoginScreen(l.Tool, screen))
			}
		})
		if len(keys) > 0 {
			b.Sessions.pressKeys(ctx, run.Session, false, keys...)
		}
	}
}

// finishLogin settles a sign-in whose CLI ended: done only when it exited cleanly and says it is signed in.
func (b *Box) finishLogin(ctx context.Context, origin, id string, status int, screen string) {
	run, _ := b.logins.get(id)
	state, why := LoginDone, ""
	switch {
	case status > 0:
		state, why = LoginFailed, lastWordyLines(screen, 4)
		if why == "" {
			why = fmt.Sprintf("the sign-in ended with status %d", status)
		}
	default:
		if ok, said := loginVerified(ctx, run); !ok {
			state, why = LoginFailed, "the sign-in ended, but "+run.Tool+" says it is not signed in"
			if said != "" {
				why += ": " + said
			}
		}
	}
	// What the sign-in is now decides what follows: it may have been canceled while the CLI was asked.
	after, _ := b.updateLogin(origin, id, func(l *loginRun) { finished(l, state, why) })
	b.endLoginSession(origin, run.Session)
	if run.Tool == "gh" {
		b.ghAuth.forget()
	}
	if after.State != LoginDone {
		return
	}
	if run.Tool == "gh" {
		// git push over HTTPS through gh's credentials, as the person would set it up. The sign-in's own context
		// ended with it.
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, run.bin, "auth", "setup-git", "--hostname", "github.com")
		cmd.Env = loginEnv(run)
		cmd.Run()
	}
	if run.Account != "" {
		// Its account reads as signed in now.
		b.Events.Publish(events.Event{Type: "account.changed", Box: b.Name, Origin: origin, Data: map[string]any{"id": run.Account}})
	}
}

// loginEnv is what a sign-in's CLI runs with outside its session: the account's folder and the PATH it was found with.
func loginEnv(run loginRun) []string {
	env := append(os.Environ(), run.env...)
	if run.path != "" {
		env = append(env, "PATH="+run.path)
	}
	return env
}

// loginVerified asks the CLI itself whether it is signed in now, as the session pointed it.
func loginVerified(ctx context.Context, run loginRun) (bool, string) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, run.bin, loginStatus[run.Tool]...)
	cmd.Env = loginEnv(run)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false, lastWordyLines(string(out), 2)
	}
	if run.Tool == "claude" {
		var st struct {
			LoggedIn *bool `json:"loggedIn"`
		}
		if json.Unmarshal(out, &st) == nil && st.LoggedIn != nil && !*st.LoggedIn {
			return false, "not logged in"
		}
	}
	return true, ""
}

// --- routes ---

func (b *Box) listLogins(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.logins.list())
	return nil
}

func (b *Box) getLogin(w http.ResponseWriter, r *http.Request) error {
	run, ok := b.logins.get(r.PathValue("id"))
	if !ok {
		return errUnknownLogin
	}
	writeJSON(w, run.Login)
	return nil
}

var errUnknownLogin = httpError{http.StatusNotFound, "no sign-in with that id"}

func (b *Box) postLogin(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Tool    string `json:"tool"`
		Account string `json:"account"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	l, _, err := b.startLogin(r, req.Tool, req.Account)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, l)
	return nil
}

// loginCode types the code the sign-in page showed into Claude Code, then Enter.
func (b *Box) loginCode(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Code string `json:"code"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	code := strings.TrimSpace(req.Code)
	if code == "" || len(code) > 4096 || strings.IndexFunc(code, unicode.IsControl) >= 0 {
		return badRequest("a code is one line of up to 4096 characters")
	}
	id := r.PathValue("id")
	run, ok := b.logins.get(id)
	if !ok {
		return errUnknownLogin
	}
	if !run.NeedsCode || run.Finished != nil || (run.State != LoginOpenLink && run.State != LoginEnterCode) {
		return httpError{http.StatusConflict, "this sign-in is not waiting for a code"}
	}
	prompts := readLoginScreen(run.Tool, b.Sessions.loginScreenText(r.Context(), run.Session)).Prompts
	// Whatever was typed at the prompt before goes first (C-u), then the code.
	if err := b.Sessions.pressKeys(r.Context(), run.Session, false, "C-u"); err != nil {
		return err
	}
	if err := b.Sessions.pressKeys(r.Context(), run.Session, true, literalChunks(code)...); err != nil {
		return err
	}
	// Once the code went in, its Enter goes too, even if the app stopped waiting for the answer. The prompt takes the
	// paste before Enter.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	time.Sleep(100 * time.Millisecond)
	if err := b.Sessions.pressKeys(ctx, run.Session, false, "Enter"); err != nil {
		return err
	}
	l, _ := b.updateLogin(origin(r), id, func(l *loginRun) {
		if l.Finished == nil {
			l.codeSent, l.prompts, l.code = true, prompts, code
			l.State, l.Error = LoginWaiting, ""
		}
	})
	writeJSON(w, l)
	return nil
}

// deleteLogin cancels a sign-in and ends its session.
func (b *Box) deleteLogin(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	run, ok := b.logins.get(id)
	if !ok {
		return errUnknownLogin
	}
	l, _ := b.updateLogin(origin(r), id, func(l *loginRun) { finished(l, LoginFailed, "canceled") })
	b.endLoginSession(origin(r), run.Session)
	writeJSON(w, l)
	return nil
}
