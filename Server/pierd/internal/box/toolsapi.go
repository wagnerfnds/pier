package box

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"pier/pierd/internal/agentpath"
	"pier/pierd/internal/events"
	"pier/pierd/internal/installer"
	"pier/pierd/internal/integrations"
)

// The command-line tools the app can have pierd install (internal/installer, the same as `pierd tools install`):
// Claude Code and Codex, the agents, and the GitHub CLI behind pull requests and the GitHub list. GET /v1/tools says
// which the box has; POST /v1/tools/install installs the missing ones in the background, for the app's onboarding and
// its Inbox cards, with no sudo and no terminal.

// ToolStatus is one tool as GET /v1/tools shows it.
type ToolStatus struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Command   string `json:"command"`
	Installed bool   `json:"installed"`
	Path      string `json:"path,omitempty"`
	Version   string `json:"version,omitempty"`
	// Installing says an install runs now. Error is why the last one failed, kept until the tool is there; Log is
	// where that install wrote what it did.
	Installing bool   `json:"installing,omitempty"`
	Error      string `json:"error,omitempty"`
	Log        string `json:"log,omitempty"`
	// SignedIn is whether the GitHub CLI is signed in to github.com (gh only, by its own status, as doctor keeps it).
	SignedIn *bool `json:"signed_in,omitempty"`
}

// toolJobs are the installs pierd ran since it started.
type toolJobs struct {
	mu   sync.Mutex
	jobs map[string]*toolJob
	// lookedAgain is when a tool not found last had the agents looked for again.
	lookedAgain time.Time
}

// mayLookAgain says whether a tool not found may have the agents looked for again now: a look asks the person's
// shell, so it happens at most every 30 seconds.
func (t *toolJobs) mayLookAgain() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if time.Since(t.lookedAgain) < 30*time.Second {
		return false
	}
	t.lookedAgain = time.Now()
	return true
}

// toolFound finds a tool's CLI as agentFound does, but looks again before it says one is missing: the finder keeps an
// answer for ten minutes, and a CLI installed by hand since would read as missing until then.
func (b *Box) toolFound(ctx context.Context, command string) (agentpath.Found, bool) {
	if f, ok := agentFound(command); ok {
		return f, true
	}
	if !b.tools.mayLookAgain() {
		return agentpath.Found{}, false
	}
	b.refreshAgents(ctx)
	return agentFound(command)
}

type toolJob struct {
	running bool
	err     string
	log     string
}

// start claims id's install, unless one runs already.
func (t *toolJobs) start(id, log string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.jobs == nil {
		t.jobs = map[string]*toolJob{}
	}
	if j := t.jobs[id]; j != nil && j.running {
		return false
	}
	t.jobs[id] = &toolJob{running: true, log: log}
	return true
}

func (t *toolJobs) finish(id string, err error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	j := t.jobs[id]
	if j == nil {
		return
	}
	j.running = false
	if err != nil {
		j.err = err.Error()
	}
}

func (t *toolJobs) snapshot() map[string]toolJob {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := map[string]toolJob{}
	for id, j := range t.jobs {
		out[id] = *j
	}
	return out
}

// toolStatuses are the tools as this box has them now.
func (b *Box) toolStatuses(ctx context.Context) []ToolStatus {
	jobs := b.tools.snapshot()
	out := []ToolStatus{}
	for _, t := range installer.Tools {
		s := ToolStatus{ID: t.ID, Name: t.Name, Command: t.Command}
		f, ok := b.toolFound(ctx, t.Command)
		if ok {
			s.Installed, s.Path, s.Version = true, f.Path, f.Version
		}
		if j, ok := jobs[t.ID]; ok {
			s.Installing, s.Log = j.running, j.log
			if !s.Installed && !j.running {
				s.Error = j.err
			}
		} else if marker := b.toolLog(t.ID) + ".running"; fileExists(marker) {
			// An install a previous pierd started never said how it went.
			if s.Installed {
				os.Remove(marker)
			} else {
				s.Error, s.Log = "the install was cut short when pierd restarted; install it again", b.toolLog(t.ID)
			}
		}
		if t.ID == "gh" && ok {
			if in, known := b.ghSignedIn(ctx, f); known {
				s.SignedIn = &in
			}
		}
		out = append(out, s)
	}
	return out
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (b *Box) listTools(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.toolStatuses(r.Context()))
	return nil
}

// installTools installs the named tools the box does not have yet (every one of them when none is named), each in the
// background; the answer is GET /v1/tools's as it stands, with those installing.
func (b *Box) installTools(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Tools []string `json:"tools"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	ids := req.Tools
	if len(ids) == 0 {
		for _, t := range installer.Tools {
			ids = append(ids, t.ID)
		}
	}
	for _, id := range ids {
		if _, ok := installer.Lookup(id); !ok {
			return badRequest("pierd installs claude, codex and gh, not %q", id)
		}
	}
	if err := b.before(r, "tools.install", map[string]any{"tools": ids}); err != nil {
		return err
	}
	for _, id := range ids {
		t, _ := installer.Lookup(id)
		if _, ok := b.toolFound(r.Context(), t.Command); ok {
			continue
		}
		if log := b.toolLog(id); b.tools.start(id, log) {
			go b.installTool(origin(r), id, log)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, b.toolStatuses(r.Context()))
	return nil
}

// toolLog is where an install of id writes what it did.
func (b *Box) toolLog(id string) string {
	dir := b.LogDir
	if dir == "" {
		dir = filepath.Join(os.TempDir(), "pier-logs")
	}
	return filepath.Join(dir, "tools", id+".log")
}

// installTool installs one tool, then looks for the agents again (the box's info lists a new one at once, agents.found)
// and puts pierd's hooks in a new agent's settings, as `pierd setup` does. tool.installed or tool.failed says how it
// went.
func (b *Box) installTool(origin, id, logPath string) {
	t, _ := installer.Lookup(id)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	var out io.Writer = io.Discard
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err == nil {
		if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600); err == nil {
			defer f.Close()
			out = f
		}
	}
	fmt.Fprintf(out, "Installing %s (%s)\n", t.Name, time.Now().Format(time.RFC3339))
	// While it runs, a marker beside the log: a pierd that restarts meanwhile says the install was cut short.
	marker := logPath + ".running"
	os.WriteFile(marker, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600)
	defer os.Remove(marker)
	err := b.runInstall(ctx, id, out)
	b.refreshAgents(ctx)
	if id == "gh" {
		b.ghAuth.forget()
	}
	found, ok := agentFound(t.Command)
	if err == nil && !ok {
		err = fmt.Errorf("%s was installed, but pierd does not find it", t.Name)
	}
	if err == nil && (id == "claude" || id == "codex") {
		if home, herr := os.UserHomeDir(); herr == nil && b.Exe != "" {
			if herr := integrations.InstallTool(home, id, b.Exe, out); herr != nil {
				fmt.Fprintf(out, "Hooks not installed: %v\n", herr)
			}
		}
	}
	if err != nil {
		fmt.Fprintf(out, "Failed: %v\n", err)
	}
	b.tools.finish(id, err)
	e := events.Event{Type: "tool.installed", Box: b.Name, Origin: origin, Data: map[string]any{"tool": id, "path": found.Path, "version": found.Version}}
	if err != nil {
		e.Type, e.Error, e.Data = "tool.failed", err.Error(), map[string]any{"tool": id, "log": logPath}
	}
	b.Events.Publish(e)
}

// runInstall installs one tool through internal/installer, or what a test put in its place.
func (b *Box) runInstall(ctx context.Context, id string, out io.Writer) error {
	if b.ToolInstaller != nil {
		return b.ToolInstaller(ctx, id, out)
	}
	_, err := (&installer.Installer{Out: out}).Install(ctx, id)
	return err
}

// localBinLast puts ~/.local/bin, where pierd installs the agents and the
// GitHub CLI, last on a login shell's PATH when the person's profile leaves it
// out (zsh's does by default), so the app's pull request commands find a gh
// installed from the app.
const localBinLast = `case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$PATH:$HOME/.local/bin" ;; esac; `

// errToolMissing refuses a sign-in to a tool the box does not have.
var errToolMissing = errors.New("is not installed on this box")
