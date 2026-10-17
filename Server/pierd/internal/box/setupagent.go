package box

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"text/template"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/integrations"
	"pier/pierd/internal/integrations/adapters"
)

// A setup agent prepares a worktree the location has no recipe for: Claude
// Code, on the project's account, in a session of its own beside the
// worktree's other agents (<worktree>-setup), told by a prompt pierd writes
// (setupPromptText) to understand the project, install what it lacks, get
// it running on the worktree's port with a test login, save what it did as
// the location's setup script and report back (pierd preview set, pierd
// prepare done). It runs unattended: in bypassPermissions mode, unable to
// ask questions, with the dangerous-mode warning turned off in its
// account's settings, and through the normal session start, so whatever
// pierd does for every agent's folder (trusting it) holds for it too. The
// box's preparation rules (Settings.PrepareRules) go into its prompt: what
// it must never do on this box.
//
// Its preparation runs while its turn does. When the turn ends, the
// preparation is ready if the agent said it was done or recorded a preview,
// and failed otherwise (with why); a person who writes to it again starts a
// new turn, and the preparation runs again until that one ends.

// setupTitle names every setup agent's session.
const setupTitle = "Environment setup"

// defaultPrepareRules are the rules of a box nobody wrote its own for.
const defaultPrepareRules = `- Never install Docker or LXD, and never change networking or firewall rules (iptables, nftables, ufw, netplan, bridges, routes).
- Do not stop, remove or downgrade what other projects or people on this box use: install what is missing beside it.
- Do not print secrets you did not create (tokens, keys, other people's passwords).`

// setupSessionName is the session a worktree's setup agent runs in: its
// worktree's session name ("shop-checkout"), then "-setup".
func setupSessionName(loc Location, wt Worktree) string {
	base := loc.Name
	if !wt.Main {
		base += "-" + wt.Name
	}
	base = strings.Trim(unsafeSessionChars.ReplaceAllString(base, "-"), "-_")
	if len(base) > 56 {
		base = strings.TrimRight(base[:56], "-_")
	}
	if base == "" {
		base = "worktree"
	}
	return base + "-setup"
}

// sessionRef is how a session in wt names where it runs: the location for
// its main checkout, "location/worktree" for the others.
func sessionRef(loc Location, wt Worktree) string {
	if wt.Main {
		return loc.Name
	}
	return loc.Name + "/" + wt.Name
}

// autoSetupAgents lets a location without a recipe default to a setup
// agent. Tests turn it off, so a test that makes a worktree never starts
// the Claude Code of the machine it runs on; asking for one still works.
var autoSetupAgents = true

// setupAgentPreset is the Claude Code a setup agent of loc runs: the box's,
// or the one the location's config defines; false when there is none.
func setupAgentPreset(loc *Location) (AgentPreset, bool) {
	for _, p := range Presets(loc) {
		if p.ID == "claude" {
			return p, true
		}
	}
	return AgentPreset{}, false
}

// defaultPrepareWith is how a new worktree of loc is prepared when nobody
// says: by script when the location has a recipe (a setup script or a
// service that starts by itself, from the repository or the box's own
// config), by a setup agent when it has none, or only pierd's guess from
// its files, and the box has Claude Code. A repository config waiting to be
// trusted counts as a recipe: the person decides whether it runs.
func (b *Box) defaultPrepareWith(ctx context.Context, loc Location) string {
	if _, ok := setupAgentPreset(&loc); !ok || !autoSetupAgents {
		return "script"
	}
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil {
		return "script"
	}
	if cfg.RepoTrust.Pending() {
		return "script"
	}
	recipe := func(c *RepoConfig) bool {
		if c == nil {
			return false
		}
		if c.Setup != "" {
			return true
		}
		for _, s := range c.Services {
			if s.Autostart {
				return true
			}
		}
		return false
	}
	switch {
	case recipe(cfg.Repo):
		return "script"
	case cfg.Local.Detected:
		return "agent"
	case recipe(&cfg.Effective):
		return "script"
	}
	return "agent"
}

// prepareWithFor is how a new worktree of loc is prepared: as asked
// ("agent", "script", "none"), "none" for the older "prepare": false, else
// the location's default.
func (b *Box) prepareWithFor(ctx context.Context, loc Location, asked string, prepare *bool) (string, error) {
	switch asked {
	case "agent":
		if _, ok := setupAgentPreset(&loc); !ok {
			return "", badRequest("this box has no Claude Code to prepare with: install it, or prepare with the setup script")
		}
		return "agent", nil
	case "script", "none":
		return asked, nil
	case "":
	default:
		return "", badRequest("prepare_with is agent, script or none")
	}
	if prepare != nil && !*prepare {
		return "none", nil
	}
	return b.defaultPrepareWith(ctx, loc), nil
}

// runSetupAgent starts wt's setup agent in session name (startAgent's),
// after the previous run's; a start that fails ends the preparation, saying
// why. failure is what a recipe that ran first said.
func (b *Box) runSetupAgent(from, gateFrom string, loc Location, wt Worktree, name, previous, failure string) {
	if err := b.startSetupAgent(context.Background(), from, gateFrom, loc, wt, name, previous, failure); err != nil {
		b.finishPrepare(from, loc, wt, fmt.Errorf("the setup agent could not start: %w", err))
	}
}

// startSetupAgent starts the session; what follows it is setupEvent's.
func (b *Box) startSetupAgent(ctx context.Context, from, gateFrom string, loc Location, wt Worktree, name, previous, failure string) error {
	p, ok := setupAgentPreset(&loc)
	if !ok {
		return errors.New("this box has no Claude Code")
	}
	if b.Sessions == nil {
		return errors.New("this box runs no sessions")
	}
	if _, err := tmuxPath(); err != nil {
		return err
	}
	ref := sessionRef(loc, wt)
	data := map[string]any{"name": name, "location": ref, "path": wt.Path, "command": p.Command, "setup": true}
	if err := b.beforeCtx(ctx, gateFrom, "session.start", data); err != nil {
		return err
	}
	// Earlier runs' sessions are pierd's own: they make way for this one,
	// no longer followed, so what they say as they stop is not this run's.
	for _, old := range []string{previous, name} {
		if old == "" {
			continue
		}
		b.setupSessions.Delete(old)
		if _, err := b.Sessions.Get(ctx, old); err == nil && b.Sessions.Kill(ctx, old) == nil {
			b.Events.Publish(events.Event{Type: "session.stopped", Box: b.Name, Origin: from, Data: map[string]any{"name": old, "path": wt.Path}})
		}
	}
	if err := allowBypass(b.sessionEnv(ctx, wt.Path)); err != nil {
		return fmt.Errorf("Claude Code's settings could not be made to skip its bypass-mode warning, where the agent would stop: %w", err)
	}
	prompt, err := b.setupPrompt(ctx, loc, wt, failure)
	if err != nil {
		return err
	}
	// Unattended: nothing to approve, no question it could ask (a variadic
	// flag, so the next flag ends its list before the prompt).
	setup := p
	setup.Command = p.Command + " --disallowedTools AskUserQuestion --permission-mode bypassPermissions"
	command, err := AgentCommandWith(setup, prompt, "", "")
	if err != nil {
		return err
	}
	// Followed from its first event on.
	b.watchSetupAgents()
	b.setupSessions.Store(name, prepKey(loc.Name, wt.Name))
	sess, err := b.createAgentSession(ctx, name, ref, wt.Path, command, p.ID)
	if err != nil {
		b.setupSessions.Delete(name)
		return err
	}
	data["agent"] = agentFor(sess)
	b.Events.Publish(events.Event{Type: "session.started", Box: b.Name, Origin: from, Data: data})
	b.startupPrompt(from, gateFrom, Session{Name: sess.Name, Agent: agentFor(sess)})
	sess = b.titleNew(ctx, sess, setupTitle, "")
	sess = b.enrich(ctx, []Session{sess})[0]
	b.beginStartup(from, sess)
	return nil
}

// beforeCtx is before for work that goes on after its request: the hooks see
// gateFrom as its origin.
func (b *Box) beforeCtx(ctx context.Context, gateFrom, typ string, data map[string]any) error {
	e := events.Event{Type: typ, Box: b.Name, Origin: gateFrom, Data: data}
	if b.Hooks != nil {
		if err := b.Hooks.Before(ctx, e); err != nil {
			return httpError{http.StatusForbidden, err.Error()}
		}
	}
	return b.beforeRepoCtx(ctx, e)
}

// allowBypass is allowBypassMode; tests replace it, so they never touch the
// settings of the machine they run on.
var allowBypass = allowBypassMode

// allowBypassMode lets the account a setup agent runs on start in
// bypassPermissions mode without Claude Code's warning, which waits for a
// person: skipDangerousModePermissionPrompt in that account's settings.json
// (env's CLAUDE_CONFIG_DIR, else Claude Code's own folder), every other key
// kept.
func allowBypassMode(env []string) error {
	dir := ""
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "CLAUDE_CONFIG_DIR="); ok && v != "" {
			dir = v
		}
	}
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		t, _ := toolByID("claude")
		dir = t.ConfigDir(home)
	}
	_, err := integrations.SkipBypassWarning(filepath.Join(dir, "settings.json"))
	return err
}

// Following setup agents: the bus's observer queues the events of their
// sessions (it must not block or publish), and one worker per box handles
// them in order, so a turn's start never lands after its end.

type setupQueue struct {
	mu    sync.Mutex
	items []events.Event
	wake  chan struct{}
}

func (b *Box) watchSetupAgents() {
	b.setupWatch.Do(func() {
		q := &setupQueue{wake: make(chan struct{}, 1)}
		b.Events.Observe(func(e events.Event) {
			var name string
			switch e.Type {
			case adapters.Started, adapters.Finished, adapters.Exited:
				name = str(e.Data, "session")
			case "session.stopped":
				name = str(e.Data, "name")
			default:
				return
			}
			if name == "" {
				return
			}
			if _, ok := b.setupSessions.Load(name); !ok {
				return
			}
			q.mu.Lock()
			if len(q.items) < 1024 {
				q.items = append(q.items, e)
			}
			q.mu.Unlock()
			select {
			case q.wake <- struct{}{}:
			default:
			}
		})
		go func() {
			for range q.wake {
				q.mu.Lock()
				items := q.items
				q.items = nil
				q.mu.Unlock()
				for _, e := range items {
					b.setupEvent(e)
				}
			}
		}()
	})
}

// setupEvent moves a setup agent's preparation along with its session: a new
// turn runs it again, a turn's end settles it, the agent or its session
// ending fails it.
func (b *Box) setupEvent(e events.Event) {
	name := str(e.Data, "session")
	if e.Type == "session.stopped" {
		name = str(e.Data, "name")
	}
	v, ok := b.setupSessions.Load(name)
	if !ok {
		return
	}
	key := v.(string)
	rec, ok := b.preps().get(key)
	if !ok || rec.Kind != "agent" || rec.Session != name {
		b.setupSessions.Delete(name)
		return
	}
	// What happened before the state it is in began is behind it (an
	// earlier run's, or this one's before it was settled).
	if rec.Since != nil && e.Time.Before(*rec.Since) {
		return
	}
	from := e.Origin
	switch e.Type {
	case adapters.Started:
		if str(e.Data, "signal") == "tool" || rec.State == "running" {
			return
		}
		// Someone wrote to it again: it prepares again until that turn ends.
		location, worktree, _ := strings.Cut(key, "/")
		loc, wt, err := b.worktreeRef(context.Background(), location, worktree)
		if err != nil {
			return
		}
		b.preps().update(key, func(r *prepRecord) {
			now := time.Now()
			r.State, r.Since, r.Error = "running", &now, ""
		})
		b.Events.Publish(events.Event{Type: "worktree.prepare.started", Box: b.Name, Origin: from, Data: b.prepareData(loc, wt)})
	case adapters.Finished:
		b.setupTurnEnded(from, key, name, str(e.Data, "status") == "error", false)
	case adapters.Exited, "session.stopped":
		b.setupTurnEnded(from, key, name, false, true)
		if e.Type == "session.stopped" {
			b.setupSessions.Delete(name)
		}
	}
}

// setupTurnEnded settles a setup agent's preparation when its turn ends:
// ready when it said it was done or recorded a preview during it, failed
// otherwise, and when it ended on an error or its session went.
func (b *Box) setupTurnEnded(from, key, session string, errored, exited bool) {
	rec, ok := b.preps().get(key)
	if !ok || rec.Kind != "agent" || rec.State != "running" || rec.Session != session {
		return
	}
	var err error
	switch {
	case exited:
		err = errorText("the setup agent ended before it was done: read its conversation, then prepare again")
	case errored:
		err = errorText("the setup agent stopped on an error: its conversation says what happened")
	case rec.Done || b.previewSince(key, rec.Since):
	default:
		err = errorText("the setup agent ended its turn without saying it was done (pierd prepare done): read its conversation")
	}
	location, worktree, _ := strings.Cut(key, "/")
	loc, wt, lerr := b.worktreeRef(context.Background(), location, worktree)
	if lerr != nil {
		return
	}
	if err != nil {
		b.finishPrepare(from, loc, wt, err)
		return
	}
	b.finishAgentPrepare(from, loc, wt)
}

// previewSince says whether a worktree's preview with a port was recorded
// since t.
func (b *Box) previewSince(key string, t *time.Time) bool {
	e, ok := b.previews().get(key)
	if !ok || e.Port == 0 || e.Updated == nil {
		return false
	}
	return t == nil || !e.Updated.Before(*t)
}

// finishAgentPrepare ends a setup agent's preparation as ready. The services
// its recipe starts by themselves start now if it left them stopped, unless
// something already answers on the worktree's port.
func (b *Box) finishAgentPrepare(from string, loc Location, wt Worktree) {
	ctx := context.Background()
	if wt.Port == 0 {
		wt.Port, _ = b.Locations.Ports.For(wt.Path)
	}
	if all, err := b.WorktreeServices(ctx, loc.Name, wt.Name); err == nil && (wt.Port == 0 || !portInUse(wt.Port)) {
		for _, s := range all {
			if s.Autostart && s.State != "running" && s.State != "activating" {
				if _, err := b.StartService(ctx, loc.Name, wt.Name, s.Name); err != nil {
					b.Events.Publish(eventf(b, "service.failed", map[string]any{"location": loc.Name, "name": wt.Name, "service": s.Name, "error": err.Error()}))
				}
			}
		}
	}
	b.finishPrepare(from, loc, wt, nil)
}

// ResumePrepare follows the setup agents still at work when pierd started
// again: their sessions outlive pierd. One whose session ended meanwhile
// failed; one whose turn ended meanwhile is settled.
func (b *Box) ResumePrepare() {
	running := b.preps().agents()
	if len(running) == 0 || b.Sessions == nil {
		return
	}
	b.watchSetupAgents()
	for key, r := range running {
		b.setupSessions.Store(r.Session, key)
	}
	go func() {
		ctx := context.Background()
		for key, r := range running {
			sess, err := b.Sessions.Get(ctx, r.Session)
			switch {
			case errors.Is(err, ErrUnknownSession), err == nil && sess.Exited:
				b.setupTurnEnded("pier", key, r.Session, false, true)
			case err != nil:
			case b.Turns != nil:
				if st, ok := b.Turns.State(r.Session); ok && st.State == "finished" && (r.Since == nil || st.Since.After(*r.Since)) {
					b.setupTurnEnded("pier", key, r.Session, false, false)
				}
			}
		}
	}()
}

// The prompt.

// setupPromptData is what the setup agent's prompt is made of.
type setupPromptData struct {
	Location, Worktree, Ref, Path, Root, Branch string
	Main                                        bool
	Port, PortLast                              int
	// Sudo says `sudo -n true` works on this box.
	Sudo     bool
	OS, User string
	// Rules are the box's preparation rules.
	Rules string
	// Pierd is how to run pierd from the agent's shell.
	Pierd    string
	Isolated bool
	// Recipe and Failure: the location's setup script that failed here,
	// and what it said.
	Recipe, Failure string
}

const setupPromptText = `You are the setup agent of a Pier box: you prepare a fresh checkout of the project {{.Location}} so that it runs, alone and unattended. Nobody is watching and nobody will answer a question, so never ask one: decide, act, and say what you did. Work on the box's environment only: another agent may be changing the project's code in this folder at the same time.

## Where you are
- Folder: {{.Path}} ({{if .Main}}the repository's main checkout{{else}}worktree {{.Worktree}} of the repository at {{.Root}}{{end}}){{if .Branch}}, branch {{.Branch}}{{end}}.
- Box: {{.OS}}{{if .User}}, user {{.User}}{{end}}.
- System packages: {{if .Sudo}}` + "`sudo -n`" + ` works on this box: install what is missing with the system's package manager through ` + "`sudo -n`" + ` (for example ` + "`sudo -n apt-get install -y php8.3-cli`" + `).{{else}}there is no password-free sudo on this box, so never call sudo: install what is missing in your own user space (mise or asdf for language runtimes, ` + "`uv python install`" + `, prebuilt binaries in ~/.local/bin).{{end}}
{{- if .Port}}
- Ports: this worktree owns {{.Port}} to {{.PortLast}}. ` + "`$PIER_PORT`" + ` ({{.Port}}) is the dev server's; the others are free for a database or a second server. Other worktrees of this project run on this box at the same time: never take a port outside this block, nor a fixed one such as 3000 or 8000.
{{- end}}
- Your environment already has ` + "`PIER_PORT`, `PIER_LOCATION`, `PIER_WORKTREE_NAME`, `PIER_WORKTREE_PATH`, `PIER_ROOT_PATH`, `PIER_BRANCH` and `PIER_WORKTREE_SLUG`" + ` (safe in database names).
{{- if .Isolated}}
- This project has an isolated environment: its language runs from launchers in ` + "`$PIER_ENV_BIN`" + ` (first on PATH), and its databases are reached through ` + "`DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` and `DATABASE_URL`" + `. Use them: do not install another runtime or database for it.
{{- end}}
- ` + "`{{.Pierd}}`" + ` is Pier's own command on this box; the steps below use it.

## Rules of this box
{{.Rules}}

## What to do
1. Understand the project: its README and docs, lockfiles, framework, ` + "`.env.example`" + `, any compose or Docker files (read them only, to learn which services the app expects), CI config, seeders.
2. Install the runtimes and system packages it needs and the box lacks (language and extensions, database server, build tools).
3. Install its dependencies (composer install, npm ci, bundle install, uv sync…).
4. Database: give it what it expects (MySQL/MariaDB or Postgres, installed as above), with one database and user for this worktree named after ` + "`$PIER_WORKTREE_SLUG`" + `; SQLite only when the project supports it and nothing else works. Write ` + "`.env`" + ` from ` + "`.env.example`" + ` with this worktree's port, URL and database.
5. Run the migrations and the seeders.
6. If the app has a sign-in, create a test user through its seeders or its own console (artisan tinker, rails runner, a management command) with a password you choose, and check that it can sign in.
7. Run the dev server as a Pier service on ` + "`$PIER_PORT`" + `, listening on 0.0.0.0. People open it through a public link (https://p-….docktopier.com, a proxy that sends X-Forwarded-Proto and X-Forwarded-Host), so make the app work behind it: trust the proxy, take the scheme and host from the request (APP_URL, allowed hosts, trusted origins), and build the assets (npm run build) rather than serving them from a dev server whose hot reload cannot pass the link. Define the service in the recipe (next step), start it with ` + "`{{.Pierd}} service start {{.Ref}} <service>`" + ` and check it with ` + "`curl -sS -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:$PIER_PORT/`" + `.
8. Save a recipe so the next worktree is prepared without you:

       {{.Pierd}} location config {{.Location}} --merge - <<'JSON'
       {"setup": "<a shell script>",
        "services": [{"name": "web", "run": "<the dev server's command>", "autostart": true}],
        "preview": {"path": "/login", "login": {"user": "<test user>", "password": "<its password>"}}}
       JSON

   The setup script runs in each new worktree's folder with that worktree's own ` + "`$PIER_*`" + ` variables: use them, never this worktree's values. It must work on a fresh checkout and when run twice, and hold only what each worktree needs (dependencies, .env, its database, migrations, seeders, the asset build), not what you installed once for the box. Run it here once to check it. Leave "preview" out when the app has no page.
9. Report:
   - for a web app: ` + "`{{.Pierd}} preview set {{.Ref}} --port $PIER_PORT --path /login --user <test user> --password <its password>`" + ` (leave out what does not apply);
   - then ` + "`{{.Pierd}} prepare done {{.Ref}}`" + `, or, when you could not get it to run, ` + "`{{.Pierd}} prepare done {{.Ref}} --failed \"<what is missing and why>\"`" + `.
10. Do not change files git tracks unless there is no other way (local, untracked config such as .env comes first), do not commit, and do not run git commands that change the folder (checkout, stash, reset, clean).
{{- if .Failure}}

## The saved recipe failed here
The location's setup script ran in this worktree and failed. Find out why, fix what is wrong, save the corrected recipe (step 8) and go on.

Script:
{{.Recipe}}

What it said:
{{.Failure}}
{{- end}}

Finish with a short summary: what you installed, how to run it, the test login, and anything left for a person to do.
`

var setupPromptTmpl = template.Must(template.New("setup").Parse(setupPromptText))

// renderSetupPrompt writes the setup agent's first prompt.
func renderSetupPrompt(d setupPromptData) (string, error) {
	var out strings.Builder
	if err := setupPromptTmpl.Execute(&out, d); err != nil {
		return "", err
	}
	return out.String(), nil
}

// setupPrompt is wt's setup agent's first prompt, from what the box is.
func (b *Box) setupPrompt(ctx context.Context, loc Location, wt Worktree, failure string) (string, error) {
	port := wt.Port
	if port == 0 {
		port, _ = b.Locations.Ports.For(wt.Path)
	}
	d := setupPromptData{
		Location: loc.Name, Worktree: wt.Name, Ref: loc.Name + "/" + wt.Name, Path: wt.Path, Root: loc.Path,
		Branch: wt.Branch, Main: wt.Main, Port: port, Sudo: canSudo(ctx), OS: boxOS(), User: currentUser(),
		Rules: b.Locations.Settings().prepareRules(), Pierd: pierdCommand(b.Exe), Isolated: loc.Isolated,
	}
	if port > 0 {
		d.PortLast = port + portBlock - 1
	}
	if failure != "" {
		d.Recipe, d.Failure = loc.Scripts.Setup, clip(strings.TrimSpace(failure), 4000)
	}
	return renderSetupPrompt(d)
}

// canSudo says whether sudo works without a password here; tests replace
// it.
var canSudo = func(ctx context.Context) bool {
	if _, err := exec.LookPath("sudo"); err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "sudo", "-n", "true").Run() == nil
}

// boxOS names the system ("Ubuntu 24.04.1 LTS, amd64"); tests replace it.
var boxOS = func() string {
	name := runtime.GOOS
	if data, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
				name = strings.Trim(strings.TrimSpace(v), `"'`)
			}
		}
	} else if runtime.GOOS == "darwin" {
		name = "macOS"
		if out, err := exec.Command("sw_vers", "-productVersion").Output(); err == nil {
			name += " " + strings.TrimSpace(string(out))
		}
	}
	return name + ", " + runtime.GOARCH
}

func currentUser() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return ""
}

// pierdCommand is how a shell runs pierd: its own path when known.
func pierdCommand(exe string) string {
	if exe == "" {
		return "pierd"
	}
	if strings.Trim(exe, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./") != "" {
		return shellQuote(exe)
	}
	return exe
}
