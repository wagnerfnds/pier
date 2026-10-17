package box

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/integrations"
	"pier/pierd/internal/statefile"
)

// Accounts: more than one Claude Code or Codex subscription on one box. Each
// account is a folder of the agent's own (CLAUDE_CONFIG_DIR, CODEX_HOME,
// the documented way to keep logins apart: code.claude.com/docs/en/
// authentication), holding its login, settings, history and skills. A
// project picks which account its agents use, the box a default; the
// account's folder then reaches every agent started in the project's
// worktrees. The agent's own folder (~/.claude, ~/.codex) is the built-in
// account of each agent.

// Account is one of the box's agent accounts.
type Account struct {
	ID      string    `json:"id"`
	Agent   string    `json:"agent"`
	Name    string    `json:"name"`
	Dir     string    `json:"dir"`
	Builtin bool      `json:"builtin,omitempty"`
	Created time.Time `json:"created,omitempty"`
}

// AccountView is an account as GET /v1/accounts shows it.
type AccountView struct {
	Account
	SignedIn bool `json:"signed_in"`
	// SignedInKnown is false where a file cannot tell (macOS's Keychain).
	SignedInKnown bool                 `json:"signed_in_known"`
	Default       bool                 `json:"default,omitempty"`
	Projects      []string             `json:"projects"`
	Limits        *integrations.Limits `json:"limits,omitempty"`
	// LimitsReady is false for a Claude account whose status line is not
	// pierd's yet: its limits cannot be read until it is.
	LimitsReady bool `json:"limits_ready"`
}

type accountsFile struct {
	Accounts []Account         `json:"accounts"`
	Defaults map[string]string `json:"defaults,omitempty"`
}

var agentDirVar = map[string]string{"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"}

var errUnknownAccount = httpError{http.StatusNotFound, "no account with that id"}

type accountStore struct{ mu sync.Mutex }

func (b *Box) accountsPath() string {
	dir := b.StateDir
	if dir == "" {
		dir = filepath.Join(os.TempDir(), "pier-accounts")
	}
	return filepath.Join(dir, "accounts.json")
}

func (b *Box) loadAccounts() accountsFile {
	var f accountsFile
	if data, err := os.ReadFile(b.accountsPath()); err == nil {
		json.Unmarshal(data, &f)
	}
	return f
}

func (b *Box) saveAccounts(f accountsFile) error {
	data, _ := json.MarshalIndent(f, "", "  ")
	return statefile.Write(b.accountsPath(), append(data, '\n'))
}

// builtinAccounts are each agent's own folder.
func builtinAccounts() []Account {
	home, _ := os.UserHomeDir()
	var out []Account
	for _, t := range integrations.Tools {
		out = append(out, Account{ID: t.ID, Agent: t.ID, Name: t.Name, Dir: t.ConfigDir(home), Builtin: true})
	}
	return out
}

// Accounts are the built-in accounts and the ones added on the box.
func (b *Box) Accounts() []Account {
	return append(builtinAccounts(), b.loadAccounts().Accounts...)
}

func (b *Box) account(id string) (Account, bool) {
	for _, a := range b.Accounts() {
		if a.ID == id {
			return a, true
		}
	}
	return Account{}, false
}

// accountVars are the variables that point a location's agents at their
// accounts: the project's choice, else the box's default; nothing for an
// agent on its built-in account.
func (b *Box) accountVars(location string) map[string]string {
	f := b.loadAccounts()
	chosen := map[string]string{}
	for agent, id := range f.Defaults {
		chosen[agent] = id
	}
	if s, err := b.Locations.saved(location); err == nil {
		for agent, id := range s.Accounts {
			chosen[agent] = id
		}
	}
	out := map[string]string{}
	for agent, id := range chosen {
		if a, ok := b.account(id); ok && !a.Builtin && a.Agent == agent {
			out[agentDirVar[agent]] = a.Dir
		}
	}
	return out
}

// SetLocationAccounts sets which account each agent uses in a location
// ("" for the box's default).
func (l *Locations) SetLocationAccounts(name string, choice map[string]string) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name != name {
				continue
			}
			if all[i].Accounts == nil {
				all[i].Accounts = map[string]string{}
			}
			for agent, id := range choice {
				if id == "" {
					delete(all[i].Accounts, agent)
				} else {
					all[i].Accounts[agent] = id
				}
			}
			if len(all[i].Accounts) == 0 {
				all[i].Accounts = nil
			}
			return all, nil
		}
		return nil, ErrUnknownLocation
	})
}

// prepareAccountDir puts pierd's hooks, its status line (Claude) and the
// box's skills in an account's folder, and answers in it the questions the
// agent would stop its first sessions at: its first-run screens (a new
// Claude Code account), the bypass mode's warning, trusting each of the
// box's projects, and Codex's review of pierd's hooks.
func (b *Box) prepareAccountDir(a Account) error {
	if err := os.MkdirAll(a.Dir, 0o700); err != nil {
		return err
	}
	bin := b.Exe
	if bin == "" {
		bin = "pierd"
	}
	switch a.Agent {
	case "claude":
		if _, err := integrations.InstallClaudeHooks(filepath.Join(a.Dir, "settings.json"), bin); err != nil {
			return err
		}
		if _, err := integrations.InstallStatusLine(filepath.Join(a.Dir, "settings.json"), bin); err != nil {
			return err
		}
		if !a.Builtin {
			// An account pierd made: the theme its first run would ask for,
			// and its first-run screens seen, so its first task goes straight
			// to work. Signing in is /login (loginAccount).
			if _, err := integrations.PrepareClaudeSettings(filepath.Join(a.Dir, "settings.json"), "dark"); err != nil {
				return err
			}
			if _, err := integrations.MarkClaudeOnboarded(integrations.ClaudeConfigFile(a.Dir, "")); err != nil {
				logf("pierd: %s: %v", a.Dir, err)
			}
		}
	case "codex":
		if _, err := integrations.InstallCodexHooks(filepath.Join(a.Dir, "hooks.json"), bin); err != nil {
			return err
		}
		if _, err := integrations.InstallCodexNotify(filepath.Join(a.Dir, "config.toml"), bin); err != nil && !errors.Is(err, integrations.ErrNotifyTaken) {
			return err
		}
	}
	b.trustProjectsFor(a)
	b.syncSkills()
	return nil
}

func (b *Box) accountViews(ctx context.Context) []AccountView {
	f := b.loadAccounts()
	locs, _ := b.Locations.List(ctx)
	saved := map[string]map[string]string{}
	for _, l := range locs {
		if s, err := b.Locations.saved(l.Name); err == nil {
			saved[l.Name] = s.Accounts
		}
	}
	var out []AccountView
	for _, a := range b.Accounts() {
		v := AccountView{Account: a, Projects: []string{}}
		def := f.Defaults[a.Agent]
		v.Default = def == a.ID || def == "" && a.Builtin
		for name, choice := range saved {
			id := choice[a.Agent]
			if id == "" {
				id = def
			}
			if id == a.ID || id == "" && a.Builtin {
				v.Projects = append(v.Projects, name)
			}
		}
		sort.Strings(v.Projects)
		if t, ok := toolByID(a.Agent); ok {
			v.SignedIn, v.SignedInKnown = t.SignedInAt(a.Dir)
		}
		v.Limits = b.readLimits(a)
		v.LimitsReady = a.Agent != "claude" || integrations.HasStatusLine(filepath.Join(a.Dir, "settings.json"))
		out = append(out, v)
	}
	return out
}

func toolByID(id string) (integrations.Tool, bool) {
	for _, t := range integrations.Tools {
		if t.ID == id {
			return t, true
		}
	}
	return integrations.Tool{}, false
}

// limitsDir holds what pierd's status line saw of each Claude account.
func (b *Box) limitsDir() string {
	dir := b.StateDir
	if dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "limits")
}

// readLimits is an account's latest usage: Claude Code's from pierd's status
// line, Codex's from the newest session log in its folder.
func (b *Box) readLimits(a Account) *integrations.Limits {
	switch a.Agent {
	case "claude":
		data, err := os.ReadFile(integrations.LimitsFile(b.limitsDir(), "claude", a.Dir))
		if err != nil {
			return nil
		}
		var l integrations.Limits
		if json.Unmarshal(data, &l) != nil {
			return nil
		}
		// A window past its reset is used up no more.
		keep := l.Windows[:0]
		for _, w := range l.Windows {
			if w.ResetsAt.IsZero() || time.Now().Before(w.ResetsAt) {
				keep = append(keep, w)
			}
		}
		l.Windows = keep
		return &l
	case "codex":
		return codexLimits(a.Dir)
	}
	return nil
}

// codexLimits reads the last rate limits Codex wrote in its newest session
// log ($CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl, its token_count events).
func codexLimits(home string) *integrations.Limits {
	root := filepath.Join(home, "sessions")
	var newest string
	var newestTime time.Time
	// The newest days only: the folders are by date.
	years, _ := os.ReadDir(root)
	for yi := len(years) - 1; yi >= 0 && newest == ""; yi-- {
		months, _ := os.ReadDir(filepath.Join(root, years[yi].Name()))
		for mi := len(months) - 1; mi >= 0 && newest == ""; mi-- {
			days, _ := os.ReadDir(filepath.Join(root, years[yi].Name(), months[mi].Name()))
			for di := len(days) - 1; di >= 0 && newest == ""; di-- {
				dir := filepath.Join(root, years[yi].Name(), months[mi].Name(), days[di].Name())
				files, _ := os.ReadDir(dir)
				for _, f := range files {
					if !strings.HasSuffix(f.Name(), ".jsonl") {
						continue
					}
					if info, err := f.Info(); err == nil && info.ModTime().After(newestTime) {
						newest, newestTime = filepath.Join(dir, f.Name()), info.ModTime()
					}
				}
			}
		}
	}
	if newest == "" {
		return nil
	}
	l := lastCodexLimits(newest)
	if l != nil {
		l.Dir = home
		if l.Updated.IsZero() {
			l.Updated = newestTime.UTC()
		}
	}
	return l
}

// lastCodexLimits finds the last rate_limits in the tail of a session log.
func lastCodexLimits(path string) *integrations.Limits {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	const tail = 512 << 10
	if st, err := f.Stat(); err == nil && st.Size() > tail {
		f.Seek(st.Size()-tail, io.SeekStart)
	}
	var last []byte
	var lastAt string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if bytes.Contains(line, []byte(`"rate_limits"`)) {
			last = append(last[:0], line...)
		}
	}
	if last == nil {
		return nil
	}
	var rec struct {
		Timestamp string `json:"timestamp"`
		Payload   struct {
			RateLimits map[string]*struct {
				Used     float64 `json:"used_percent"`
				Window   int     `json:"window_minutes"`
				ResetsAt int64   `json:"resets_at"`
				ResetsIn int64   `json:"resets_in_seconds"`
			} `json:"rate_limits"`
		} `json:"payload"`
	}
	if json.Unmarshal(last, &rec) != nil {
		return nil
	}
	lastAt = rec.Timestamp
	at, _ := time.Parse(time.RFC3339Nano, lastAt)
	l := &integrations.Limits{Agent: "codex", Source: "session_log", Updated: at.UTC()}
	for _, kind := range []string{"primary", "secondary"} {
		w := rec.Payload.RateLimits[kind]
		if w == nil {
			continue
		}
		lw := integrations.LimitWindow{Kind: kind, Minutes: w.Window, UsedPercent: w.Used}
		switch {
		case w.ResetsAt > 0:
			lw.ResetsAt = time.Unix(w.ResetsAt, 0).UTC()
		case w.ResetsIn > 0 && !at.IsZero():
			lw.ResetsAt = at.Add(time.Duration(w.ResetsIn) * time.Second).UTC()
		}
		if !lw.ResetsAt.IsZero() && time.Now().After(lw.ResetsAt) {
			continue
		}
		l.Windows = append(l.Windows, lw)
	}
	return l
}

func newAccountID(agent string) string {
	var b [4]byte
	rand.Read(b[:])
	return agent + "-" + hex.EncodeToString(b[:])
}

// --- routes ---

func (b *Box) listAccounts(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.accountViews(r.Context()))
	return nil
}

// addAccount makes a new account's folder, ready to sign in (POST
// /v1/accounts/{id}/login).
func (b *Box) addAccount(w http.ResponseWriter, r *http.Request) error {
	var req struct{ Agent, Name string }
	if err := decode(r, &req); err != nil {
		return err
	}
	if agentDirVar[req.Agent] == "" {
		return badRequest("accounts are for claude or codex")
	}
	name := strings.TrimSpace(req.Name)
	if name == "" || len(name) > 60 {
		return badRequest("an account needs a name of up to 60 characters")
	}
	if err := b.before(r, "account.add", map[string]any{"agent": req.Agent, "name": name}); err != nil {
		return err
	}
	b.accounts.mu.Lock()
	defer b.accounts.mu.Unlock()
	f := b.loadAccounts()
	id := newAccountID(req.Agent)
	a := Account{ID: id, Agent: req.Agent, Name: name, Dir: filepath.Join(filepath.Dir(b.accountsPath()), "accounts", id), Created: time.Now().UTC()}
	if err := b.prepareAccountDir(a); err != nil {
		return err
	}
	f.Accounts = append(f.Accounts, a)
	if err := b.saveAccounts(f); err != nil {
		return err
	}
	b.publish(r, "account.added", map[string]any{"id": id, "agent": a.Agent, "name": name})
	writeJSON(w, AccountView{Account: a, Projects: []string{}})
	return nil
}

func (b *Box) updateAccount(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Name    *string `json:"name"`
		Default *bool   `json:"default"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	id := r.PathValue("id")
	a, ok := b.account(id)
	if !ok {
		return errUnknownAccount
	}
	b.accounts.mu.Lock()
	defer b.accounts.mu.Unlock()
	f := b.loadAccounts()
	if req.Name != nil && !a.Builtin {
		n := strings.TrimSpace(*req.Name)
		if n == "" || len(n) > 60 {
			return badRequest("an account needs a name of up to 60 characters")
		}
		for i := range f.Accounts {
			if f.Accounts[i].ID == id {
				f.Accounts[i].Name = n
			}
		}
	}
	if req.Default != nil && *req.Default {
		if f.Defaults == nil {
			f.Defaults = map[string]string{}
		}
		if a.Builtin {
			delete(f.Defaults, a.Agent)
		} else {
			f.Defaults[a.Agent] = id
		}
	}
	if err := b.saveAccounts(f); err != nil {
		return err
	}
	b.publish(r, "account.changed", map[string]any{"id": id})
	for _, v := range b.accountViews(r.Context()) {
		if v.ID == id {
			writeJSON(w, v)
		}
	}
	return nil
}

// removeAccount forgets an added account and deletes its folder (its login
// with it); projects on it go back to the default.
func (b *Box) removeAccount(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	a, ok := b.account(id)
	if !ok {
		return errUnknownAccount
	}
	if a.Builtin {
		return badRequest("the agent's own account cannot be removed")
	}
	if err := b.before(r, "account.remove", map[string]any{"id": id, "agent": a.Agent}); err != nil {
		return err
	}
	b.accounts.mu.Lock()
	f := b.loadAccounts()
	keep := f.Accounts[:0]
	for _, x := range f.Accounts {
		if x.ID != id {
			keep = append(keep, x)
		}
	}
	f.Accounts = keep
	if f.Defaults[a.Agent] == id {
		delete(f.Defaults, a.Agent)
	}
	err := b.saveAccounts(f)
	b.accounts.mu.Unlock()
	if err != nil {
		return err
	}
	if locs, err := b.Locations.List(r.Context()); err == nil {
		for _, l := range locs {
			if s, err := b.Locations.saved(l.Name); err == nil && s.Accounts[a.Agent] == id {
				b.Locations.SetLocationAccounts(l.Name, map[string]string{a.Agent: ""})
			}
		}
	}
	// Only a folder pierd made is deleted.
	if strings.HasPrefix(a.Dir, filepath.Join(filepath.Dir(b.accountsPath()), "accounts")+string(filepath.Separator)) {
		os.RemoveAll(a.Dir)
	}
	os.Remove(integrations.LimitsFile(b.limitsDir(), a.Agent, a.Dir))
	b.publish(r, "account.removed", map[string]any{"id": id})
	writeJSON(w, map[string]string{"removed": id})
	return nil
}

// loginAccount signs in to an account through a sign-in (logins.go) and answers
// its session, as before sign-ins existed: an app that opens it as a terminal
// sees the CLI's sign-in there, and login names the sign-in for one that
// follows it (GET /v1/logins/{id}).
func (b *Box) loginAccount(w http.ResponseWriter, r *http.Request) error {
	a, ok := b.account(r.PathValue("id"))
	if !ok {
		return errUnknownAccount
	}
	l, sess, err := b.startLogin(r, a.Agent, a.ID)
	if err != nil {
		return err
	}
	writeJSON(w, struct {
		Session
		Login string `json:"login"`
	}{sess, l.ID})
	return nil
}

// signInDir is where a sign-in terminal runs: an empty folder of pierd's
// own, which Claude Code is told it trusts. In the home folder it would ask
// first, every time (it never keeps an answer about the home folder).
func (b *Box) signInDir(a Account, env []string) string {
	home, _ := os.UserHomeDir()
	if b.StateDir == "" {
		return home
	}
	dir := filepath.Join(b.StateDir, "sign-in")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return home
	}
	if a.Agent == "claude" {
		b.pretrust(dir, env, "claude")
	}
	return dir
}

// enableLimits puts pierd's status line in the Claude accounts that lack it,
// so their limits can be read.
func (b *Box) enableLimits(w http.ResponseWriter, r *http.Request) error {
	bin := b.Exe
	if bin == "" {
		return httpError{http.StatusNotImplemented, "pierd does not know its own path"}
	}
	var changed []string
	for _, a := range b.Accounts() {
		if a.Agent != "claude" {
			continue
		}
		if _, err := os.Stat(a.Dir); err != nil {
			continue
		}
		did, err := integrations.InstallStatusLine(filepath.Join(a.Dir, "settings.json"), bin)
		if err != nil {
			return fmt.Errorf("%s: %w", a.Name, err)
		}
		if did {
			changed = append(changed, a.ID)
		}
	}
	writeJSON(w, map[string]any{"enabled": changed})
	return nil
}

func (b *Box) putLocationAccounts(w http.ResponseWriter, r *http.Request) error {
	var req map[string]string
	if err := decode(r, &req); err != nil {
		return err
	}
	for agent, id := range req {
		if agentDirVar[agent] == "" {
			return badRequest("unknown agent %q", agent)
		}
		if id != "" {
			// The built-in account is kept as a choice of its own: it wins over
			// a box default that is an added account.
			a, ok := b.account(id)
			if !ok || a.Agent != agent {
				return badRequest("%q is not a %s account", id, agent)
			}
		}
	}
	name := r.PathValue("name")
	if err := b.Locations.SetLocationAccounts(name, req); err != nil {
		return err
	}
	b.publish(r, "location.accounts", map[string]any{"location": name})
	loc, err := b.Locations.Get(r.Context(), name)
	if err != nil {
		return err
	}
	writeJSON(w, loc)
	return nil
}
