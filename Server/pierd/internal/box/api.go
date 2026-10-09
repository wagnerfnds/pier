package box

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"

	"pier/pierd/internal/doctor"
	"pier/pierd/internal/events"
	"pier/pierd/internal/hooks"
	"pier/pierd/internal/integrations/adapters"
	"pier/pierd/internal/wire"
)

// OriginHeader names the tool a request comes from, so the events it causes
// carry that origin and hooks driving the same tool skip them.
const OriginHeader = "X-Pier-Origin"

// DefaultOrigin is the origin of requests that name none.
const DefaultOrigin = "pier"

var validOrigin = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

type Box struct {
	Name      string
	Locations *Locations
	Sessions  *Sessions
	Events    *events.Bus
	// Watcher, when set, is told about pierd's own worktree changes so it
	// does not announce them a second time.
	Watcher *Watcher
	// DaemonChecks adds pierd's own checks to Doctor.
	DaemonChecks func() []doctor.Check
	// LogDir holds the logs of lifecycle scripts.
	LogDir string
	// Units runs the worktrees' services as systemd user units; nil where
	// they cannot run.
	Units *Units
	// Turns is the turn ledger: what every agent session is doing, turn by
	// turn. Without it agents read as running.
	Turns *Turns
	// Hooks, when set, may refuse actions through "before:" hooks.
	Hooks *hooks.Runner
	// EnvFile is the box's own environment for every worktree,
	// ~/.pier/env.json.
	EnvFile string
	// Socket is the box's local API socket, which programs pierd starts can
	// report back through.
	Socket string
	// Invites, when set, lets paired clients mint pairing links for another
	// device (POST /v1/pair/invite).
	Invites *Invites
}

// Mount registers the box's routes on s. They are reachable by paired
// clients and, through ServeLocal, by the box's own user.
// docs/API-SURFACE.md lists each route with the app code that calls it.
func (b *Box) Mount(s *wire.Server) {
	route := func(pattern string, h func(http.ResponseWriter, *http.Request) error) {
		s.Handle(pattern, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if err := h(w, r); err != nil {
				writeErr(w, err)
			}
		}))
	}
	route("GET /v1/info", b.handleInfo)
	route("GET /v1/stats", b.handleStats)
	route("GET /v1/doctor", b.handleDoctor)
	route("GET /v1/agents", b.listAgentCLIs)

	route("GET /v1/locations", b.listLocations)
	route("POST /v1/locations", b.addLocation)
	route("DELETE /v1/locations/{name}", b.removeLocation)
	route("GET /v1/locations/{name}/branches", b.listBranches)
	// Config and trust are for `pierd location config`; the app reads only
	// the effective scripts, in GET /v1/locations.
	route("GET /v1/locations/{name}/config", b.getConfig)
	route("PUT /v1/locations/{name}/config", b.putConfig)
	route("POST /v1/locations/{name}/config/trust", b.trustRepoConfig)
	route("DELETE /v1/locations/{name}/config/trust", b.untrustRepoConfig)
	route("POST /v1/locations/{name}/worktrees", b.addWorktree)
	route("DELETE /v1/locations/{name}/worktrees/{worktree}", b.removeWorktree)
	route("POST /v1/locations/{name}/worktrees/{worktree}/attachments", b.worktreeAttachment)
	route("GET /v1/locations/{name}/worktrees/{worktree}/touched", b.worktreeTouched)
	route("GET /v1/locations/{name}/worktrees/{worktree}/services", b.listWorktreeServices)
	route("POST /v1/locations/{name}/worktrees/{worktree}/services/{service}/{action}", b.serviceAction)
	route("GET /v1/worktrees", b.listWorktreeStatuses)
	route("GET /v1/services", b.handleServices)
	route("GET /v1/review", b.review)
	route("POST /v1/exec", b.handleExec)

	route("POST /v1/tasks", b.addTask)
	route("GET /v1/sessions", b.listSessions)
	route("POST /v1/sessions", b.addSession)
	route("DELETE /v1/sessions/{name}", b.removeSession)
	route("PATCH /v1/sessions/{name}", b.renameSession)
	route("GET /v1/sessions/{name}/screen", b.screen)
	route("GET /v1/sessions/{name}/draft", b.draft)
	route("GET /v1/sessions/{name}/transcript", b.transcript)
	route("GET /v1/sessions/{name}/transcript/tool/{id}", b.toolDetail)
	route("POST /v1/sessions/{name}/attachments", b.sessionAttachment)
	route("POST /v1/sessions/{name}/send", b.sendToSession)
	route("POST /v1/sessions/{name}/keys", b.sessionKeys)
	route("POST /v1/sessions/{name}/interrupt", b.interruptSession)
	route("POST /v1/sessions/{name}/answer", b.answerSession)
	route("GET /v1/sessions/{name}/controls", b.sessionControls)
	route("POST /v1/sessions/{name}/mode", b.setMode)
	route("GET /v1/sessions/{name}/wait", b.waitForSession)
	route("GET /v1/sessions/{name}/turns", b.listTurns)
	route("GET /v1/sessions/{name}/queue", b.listQueue)
	route("DELETE /v1/sessions/{name}/queue/{turn}", b.cancelQueued)
	route("POST /v1/sessions/{name}/queue/{turn}/send", b.sendQueued)
	route("GET /v1/sessions/{name}/diff", b.sessionDiff)

	route("GET /v1/events", b.streamEvents)
	route("POST /v1/events", b.emit)
	b.mountPairing(s, route)
}

func (b *Box) own(path string) {
	if b.Watcher != nil {
		b.Watcher.Own(path)
	}
}

type httpError struct {
	status int
	msg    string
}

func (e httpError) Error() string { return e.msg }

func badRequest(format string, args ...any) error {
	return httpError{http.StatusBadRequest, fmt.Sprintf(format, args...)}
}

func statusFor(err error) int {
	var he httpError
	switch {
	case errors.As(err, &he):
		return he.status
	case errors.Is(err, ErrUnknownLocation), errors.Is(err, ErrUnknownWorktree), errors.Is(err, ErrUnknownSession), errors.Is(err, ErrUnknownUnit):
		return http.StatusNotFound
	case errors.Is(err, ErrSessionExists), errors.Is(err, ErrSessionExited):
		return http.StatusConflict
	case errors.Is(err, errTmuxMissing):
		return http.StatusServiceUnavailable
	}
	return http.StatusBadRequest
}

func origin(r *http.Request) string {
	if o := r.Header.Get(OriginHeader); validOrigin.MatchString(o) {
		return o
	}
	return DefaultOrigin
}

func (b *Box) publish(r *http.Request, typ string, data map[string]any) events.Event {
	return b.Events.Publish(events.Event{Type: typ, Box: b.Name, Origin: origin(r), Data: data})
}

func decode(r *http.Request, v any) error { return decodeLimit(r, v, 64<<10) }

// maxPromptBody bounds a request that carries a prompt (a task, a session,
// a send): 2 MB, room for a long spec pasted whole. A prompt never goes on
// a command line, so tmux's and the kernel's limits don't apply to it.
const maxPromptBody = 2 << 20

// decodeOptional is decodeLimit for a body that may be left out: an empty
// one leaves v as it is. Over HTTP/2 a request without a body can say its
// length is unknown (-1), not 0, so the body itself decides.
func decodeOptional(r *http.Request, v any, limit int64) error {
	data, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		return badRequest("invalid request body")
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return nil
	}
	r.Body = io.NopCloser(bytes.NewReader(data))
	return decodeLimit(r, v, limit)
}

func decodeLimit(r *http.Request, v any, limit int64) error {
	body := &countingReader{r: io.LimitReader(r.Body, limit)}
	if err := json.NewDecoder(body).Decode(v); err != nil {
		if body.n >= limit {
			return httpError{http.StatusRequestEntityTooLarge, fmt.Sprintf("the request is larger than this box takes (%d KB)", limit>>10)}
		}
		return badRequest("invalid request body")
	}
	return nil
}

type countingReader struct {
	r io.Reader
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

func (b *Box) listLocations(w http.ResponseWriter, r *http.Request) error {
	all, err := b.Locations.List(r.Context())
	if err != nil {
		return err
	}
	writeJSON(w, all)
	return nil
}

func (b *Box) addLocation(w http.ResponseWriter, r *http.Request) error {
	var req struct{ Name, Path string }
	if err := decode(r, &req); err != nil {
		return err
	}
	if err := b.before(r, "location.add", map[string]any{"location": req.Name, "path": req.Path}); err != nil {
		return err
	}
	loc, err := b.Locations.Add(r.Context(), req.Name, req.Path)
	if err != nil {
		return err
	}
	b.publish(r, "location.added", map[string]any{"location": loc.Name, "path": loc.Path})
	writeJSON(w, loc)
	return nil
}

func (b *Box) removeLocation(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	if err := b.before(r, "location.remove", map[string]any{"location": name}); err != nil {
		return err
	}
	if err := b.Locations.Remove(name); err != nil {
		return err
	}
	b.publish(r, "location.removed", map[string]any{"location": name})
	writeJSON(w, map[string]string{"removed": name})
	return nil
}

func (b *Box) addWorktree(w http.ResponseWriter, r *http.Request) error {
	var req WorktreeRequest
	if err := decode(r, &req); err != nil {
		return err
	}
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	wt, err := b.createWorktree(r, loc, req)
	if err != nil {
		return err
	}
	writeJSON(w, wt)
	return nil
}

// createWorktree makes a git worktree once the hooks allow it, then runs the
// location's setup script in the background.
func (b *Box) createWorktree(r *http.Request, loc Location, req WorktreeRequest) (Worktree, error) {
	if err := b.before(r, "worktree.create", map[string]any{
		"location": loc.Name, "name": req.Name, "branch": req.Branch, "base": req.Base,
	}); err != nil {
		return Worktree{}, err
	}
	wt, err := b.Locations.CreateWorktreeFrom(r.Context(), loc.Name, req)
	if err != nil {
		return Worktree{}, err
	}
	b.own(wt.Path)
	created := map[string]any{
		"location": loc.Name, "name": wt.Name, "path": wt.Path, "branch": wt.Branch,
	}
	// The repository's own config did not run: say so, so the app can
	// offer to trust it.
	if loc.RepoTrust == RepoTrustUntrusted || loc.RepoTrust == RepoTrustChanged {
		created["repo_config"] = loc.RepoTrust
	}
	b.publish(r, "worktree.created", created)
	// Services start once setup has made the worktree ready for them.
	if loc.Scripts.Setup != "" {
		go b.lifecycle(origin(r), "setup", loc, wt.Path, wt.Name, loc.Scripts.Setup, func() error {
			go b.startAutostart(loc.Name, wt.Name)
			return nil
		})
	} else {
		go b.startAutostart(loc.Name, wt.Name)
	}
	return wt, nil
}

// lifecycle runs a setup or archive script in the background, announcing its
// start and outcome, then calls next if it succeeded.
func (b *Box) lifecycle(from, kind string, loc Location, dir, name, script string, next func() error) {
	data := map[string]any{"location": loc.Name, "name": name, "path": dir, "script": script}
	b.Events.Publish(events.Event{Type: "worktree." + kind + ".started", Box: b.Name, Origin: from, Data: data})
	// Without a log folder (tests, embedded uses) the log goes to a temp
	// folder, never the working directory.
	logDir := b.LogDir
	if logDir == "" {
		logDir = filepath.Join(os.TempDir(), "pier-logs")
	}
	_ = os.MkdirAll(logDir, 0o700)
	logPath := filepath.Join(logDir, kind+"-"+loc.Name+"-"+name+".log")
	data["log"] = logPath
	err := runScript(context.Background(), script, loc.Path, dir, name, logPath, 30*time.Minute, b.envForDir(context.Background(), dir))
	if err == nil && next != nil {
		err = next()
	}
	if err != nil {
		b.Events.Publish(events.Event{Type: "worktree." + kind + ".failed", Box: b.Name, Origin: from, Error: err.Error(), Data: data})
		return
	}
	b.Events.Publish(events.Event{Type: "worktree." + kind + ".finished", Box: b.Name, Origin: from, Data: data})
}

func (b *Box) removeWorktree(w http.ResponseWriter, r *http.Request) error {
	location, name := r.PathValue("name"), r.PathValue("worktree")
	dir, err := b.Locations.Dir(r.Context(), location+"/"+name)
	if err != nil {
		return err
	}
	if err := b.before(r, "worktree.remove", map[string]any{"location": location, "name": name, "path": dir}); err != nil {
		return err
	}
	b.own(dir)
	force := r.URL.Query().Get("force") == "1"
	loc, err := b.Locations.Get(r.Context(), location)
	if err != nil {
		return err
	}
	// Only throwaway worktrees ask for their branch to go too.
	var branch string
	if r.URL.Query().Get("delete_branch") == "1" {
		for _, wt := range loc.Worktrees {
			if wt.Path == dir && !wt.Main {
				branch = wt.Branch
			}
		}
	}
	b.stopServices(location, name)
	from := origin(r)
	removed := func(ctx context.Context) {
		b.stopSessionsIn(from, dir)
		b.Locations.Ports.Release(dir)
		if branch != "" {
			git(ctx, "-C", loc.Path, "branch", "-D", branch)
		}
	}
	// A worktree with an archive script is torn down in the background: the
	// script may take minutes, and removal only follows if it succeeds.
	if loc.Scripts.Archive != "" {
		go b.lifecycle(from, "archive", loc, dir, name, loc.Scripts.Archive, func() error {
			if err := b.Locations.RemoveWorktree(context.Background(), location, name, force); err != nil {
				return err
			}
			removed(context.Background())
			b.Events.Publish(events.Event{Type: "worktree.removed", Box: b.Name, Origin: from, Data: map[string]any{"location": location, "name": name, "path": dir}})
			return nil
		})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		writeJSON(w, map[string]string{"removing": name, "archive": loc.Scripts.Archive})
		return nil
	}
	if err := b.Locations.RemoveWorktree(r.Context(), location, name, force); err != nil {
		return err
	}
	removed(context.WithoutCancel(r.Context()))
	b.publish(r, "worktree.removed", map[string]any{"location": location, "name": name, "path": dir})
	writeJSON(w, map[string]string{"removed": name})
	return nil
}

// stopSessionsIn ends the sessions working in a removed worktree: their
// folder is gone, so they would only linger in the app with nowhere to work.
func (b *Box) stopSessionsIn(from, dir string) {
	ctx := context.Background()
	all, err := b.Sessions.List(ctx)
	if err != nil {
		return
	}
	for _, s := range all {
		if s.Dir != dir && !strings.HasPrefix(s.Dir, dir+string(filepath.Separator)) {
			continue
		}
		if b.Sessions.Kill(ctx, s.Name) == nil {
			b.Events.Publish(events.Event{Type: "session.stopped", Box: b.Name, Origin: from, Data: map[string]any{"name": s.Name, "path": s.Dir}})
		}
	}
}

func (b *Box) listSessions(w http.ResponseWriter, r *http.Request) error {
	all, err := b.Sessions.List(r.Context())
	if err != nil {
		return err
	}
	writeJSON(w, b.enrich(r.Context(), all))
	return nil
}

// SessionRequest starts a session: Command, or the Agent preset with its
// first Prompt. Open asks the app to show it ("split" or "tab").
type SessionRequest struct {
	Name     string `json:"name,omitempty"`
	Location string `json:"location"`
	Command  string `json:"command,omitempty"`
	Agent    string `json:"agent,omitempty"`
	Prompt   string `json:"prompt,omitempty"`
	// Model and Effort, with an agent: see TaskRequest.
	Model  string `json:"model,omitempty"`
	Effort string `json:"effort,omitempty"`
	Open   string `json:"open,omitempty"`
	// Title names the work; without one, the prompt's first line does.
	Title string `json:"title,omitempty"`
	// Home starts it in the box user's home folder rather than a
	// location: a terminal on the box, tied to no worktree. It takes a
	// command or a shell, never an agent preset, and no location.
	Home bool `json:"home,omitempty"`
	// Chat starts the Agent preset (with its Prompt, Model and Effort)
	// in a new empty folder of its own, tied to no project (chats.go). It
	// takes no location, no command and no home.
	Chat bool `json:"chat,omitempty"`
}

func (b *Box) addSession(w http.ResponseWriter, r *http.Request) error {
	var req SessionRequest
	if err := decodeLimit(r, &req, maxPromptBody); err != nil {
		return err
	}
	if _, err := tmuxPath(); err != nil {
		return err
	}
	if req.Open != "" && req.Open != "split" && req.Open != "tab" {
		return badRequest("open must be split or tab")
	}
	if req.Home && req.Chat {
		return badRequest("give home or chat, not both")
	}
	if req.Home {
		return b.addHomeSession(w, r, req)
	}
	if req.Chat {
		return b.addChatSession(w, r, req)
	}
	dir, err := b.Locations.Dir(r.Context(), req.Location)
	if err != nil {
		return err
	}
	if req.Agent != "" {
		if req.Command != "" {
			return badRequest("give an agent or a command, not both")
		}
		name, _, _ := strings.Cut(req.Location, "/")
		loc, err := b.Locations.Get(r.Context(), name)
		if err != nil {
			return err
		}
		p, ok := presetFor(&loc, req.Agent)
		if !ok {
			return badRequest("unknown agent %q", req.Agent)
		}
		if req.Command, err = AgentCommandWith(p, req.Prompt, req.Model, req.Effort); err != nil {
			return err
		}
	} else if req.Model != "" || req.Effort != "" {
		return badRequest("a model or an effort needs an agent, not a command")
	}
	if req.Name == "" {
		req.Name = defaultSessionName(req.Location, req.Command)
	}
	preset := req.Agent
	sess, err := b.startSession(r, req.Name, req.Location, dir, req.Command, preset, preset != "" && req.Prompt != "")
	if err != nil {
		return err
	}
	sess = b.titleNew(r.Context(), sess, req.Title, req.Prompt)
	b.announceOpen(r, sess, req.Open)
	writeJSON(w, sess)
	return nil
}

// addHomeSession starts a session in the home folder of the user pierd
// runs as, for a terminal on the box that belongs to no worktree. The folder
// is always that one: the request names no path, so it cannot point
// anywhere else.
func (b *Box) addHomeSession(w http.ResponseWriter, r *http.Request, req SessionRequest) error {
	if req.Location != "" {
		return badRequest("give a location or home, not both")
	}
	if req.Agent != "" || req.Model != "" || req.Effort != "" || req.Prompt != "" {
		return badRequest("an agent needs a location; home takes a command or a shell")
	}
	dir, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("this box has no home folder for its user: %w", err)
	}
	if req.Name == "" {
		req.Name = defaultSessionName("home", req.Command)
	}
	sess, err := b.startSession(r, req.Name, "", dir, req.Command, "", false)
	if err != nil {
		return err
	}
	sess = b.titleNew(r.Context(), sess, req.Title, "")
	b.announceOpen(r, sess, req.Open)
	writeJSON(w, sess)
	return nil
}

// addChatSession starts an agent in a new folder of its own under
// ~/pier/chats, for a conversation that belongs to no project.
func (b *Box) addChatSession(w http.ResponseWriter, r *http.Request, req SessionRequest) error {
	if req.Location != "" {
		return badRequest("a chat belongs to no location")
	}
	if req.Agent == "" || req.Command != "" {
		return badRequest("a chat takes an agent, not a command")
	}
	p, ok := presetFor(nil, req.Agent)
	if !ok {
		return badRequest("unknown agent %q", req.Agent)
	}
	command, err := AgentCommandWith(p, req.Prompt, req.Model, req.Effort)
	if err != nil {
		return err
	}
	given := req.Name != ""
	if !given {
		req.Name = defaultSessionName("chat", command)
	} else if _, err := b.Sessions.Get(r.Context(), req.Name); err == nil {
		return ErrSessionExists
	}
	name, dir, err := makeChatDir(req.Name, given)
	if err != nil {
		return err
	}
	sess, err := b.startSession(r, name, "", dir, command, req.Agent, req.Prompt != "")
	if err != nil {
		os.Remove(dir)
		return err
	}
	sess = b.titleNew(r.Context(), sess, req.Title, req.Prompt)
	b.announceOpen(r, sess, req.Open)
	writeJSON(w, sess)
	return nil
}

// announceOpen asks the app to show a new session, beside the terminal the
// user is looking at or as a tab.
func (b *Box) announceOpen(r *http.Request, sess Session, open string) {
	if open == "" {
		return
	}
	b.publish(r, "session.open", map[string]any{"name": sess.Name, "location": sess.Location, "path": sess.Dir, "open": open, "agent": sess.Agent})
}

// startSession runs command in dir once the hooks allow it; preset is the
// agent preset it runs, if any, and prompted says its command carries a
// first prompt.
func (b *Box) startSession(r *http.Request, name, location, dir, command, preset string, prompted bool) (Session, error) {
	data := map[string]any{"name": name, "location": location, "path": dir, "command": command}
	if location == "" && isChatDir(dir) {
		data["chat"] = true
	}
	if err := b.before(r, "session.start", data); err != nil {
		return Session{}, err
	}
	sess, err := b.createAgentSession(r.Context(), name, location, dir, command, preset)
	if err != nil {
		return Session{}, err
	}
	if a := agentFor(sess); a != "" {
		data["agent"] = a
	}
	b.publish(r, "session.started", data)
	if prompted {
		b.startupPrompt(origin(r), gateOrigin(r), Session{Name: sess.Name, Agent: agentFor(sess)})
	}
	sess = b.enrich(r.Context(), []Session{sess})[0]
	b.beginStartup(origin(r), sess)
	return sess, nil
}

func (b *Box) removeSession(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	if err := b.before(r, "session.stop", map[string]any{"name": name}); err != nil {
		return err
	}
	sess, _ := b.Sessions.Get(r.Context(), name)
	if err := b.Sessions.Kill(r.Context(), name); err != nil {
		return err
	}
	if sess.Location == "" && sess.Dir != "" {
		// A chat's folder goes with it when the agent left nothing there.
		removeChatDir(sess.Dir)
	}
	b.publish(r, "session.stopped", map[string]any{"name": name})
	writeJSON(w, map[string]string{"removed": name})
	return nil
}

func (b *Box) screen(w http.ResponseWriter, r *http.Request) error {
	history, _ := strconv.Atoi(r.URL.Query().Get("history"))
	text, err := b.Sessions.Screen(r.Context(), r.PathValue("name"), min(history, 10000))
	if err != nil {
		return err
	}
	writeJSON(w, map[string]string{"screen": text})
	return nil
}

// streamEvents streams the box's events as NDJSON. With ?since=SEQ it first
// replays what the journal holds after SEQ (at most ?max= events, default
// 5000), so a laptop that slept catches up; a client that falls behind is
// caught up from the journal rather than losing events.
func (b *Box) streamEvents(w http.ResponseWriter, r *http.Request) error {
	since := int64(-1)
	if v := r.URL.Query().Get("since"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			return badRequest("since must be an event seq")
		}
		since = n
		limit := int64(5000)
		if m, err := strconv.ParseInt(r.URL.Query().Get("max"), 10, 64); err == nil && m >= 0 {
			limit = m
		}
		switch head := b.Events.Head(); {
		case head-since > limit:
			since = head - limit
		case since > head:
			// A position past the end is from another journal (a box
			// set up again): from now on, rather than nothing until the
			// numbers catch up. The client refetches what it shows anyway.
			since = head
		}
	}
	cur := b.Events.SubscribeFrom(since).Named("http " + origin(r))
	ch := make(chan events.Event)
	ctx, cancel := context.WithCancel(r.Context())
	defer func() {
		// The cursor is the reader's until it ends: closing it under a
		// reader still replaying the journal is a race (and a nil
		// dereference). The reader leaves on ctx and closes ch.
		cancel()
		for range ch {
		}
		cur.Close()
	}()
	go func() {
		defer close(ch)
		for {
			e, err := cur.Next(ctx)
			if err != nil {
				return
			}
			select {
			case ch <- e:
			case <-ctx.Done():
				return
			}
		}
	}()
	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.WriteHeader(http.StatusOK)
	rc.Flush()
	enc := json.NewEncoder(w)
	keepalive := time.NewTicker(25 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return nil
		case e, ok := <-ch:
			if !ok || enc.Encode(e) != nil || rc.Flush() != nil {
				return nil
			}
		case <-keepalive.C:
			if _, err := w.Write([]byte("\n")); err != nil || rc.Flush() != nil {
				return nil
			}
		}
	}
}

// emit lets tools announce their own events, such as an agent finishing in
// Cursor, so hooks and the laptop can react to them.
func (b *Box) emit(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Type string         `json:"type"`
		Data map[string]any `json:"data"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if !validEventType.MatchString(req.Type) {
		return badRequest("event type must look like area.action, e.g. agent.finished")
	}
	if err := b.before(r, "event.emit", map[string]any{"type": req.Type}); err != nil {
		return err
	}
	// A tool use while the agent is already working changes nothing, and
	// agents use tools constantly: keep them out of the journal.
	// A prompt's title (adapters.Title) names the session; it is never
	// published, so the journal and hooks never see it.
	title, _ := req.Data["title"].(string)
	delete(req.Data, "title")
	// What a waiting agent asks for (its hook's tool and a summary of its
	// input) is never published: it goes on the turn's wait, in the
	// ledger's private file, once the event has made that wait.
	ask, hasAsk := req.Data[adapters.AskKey]
	delete(req.Data, adapters.AskKey)
	if b.Turns != nil && b.Turns.Redundant(req.Type, req.Data) {
		writeJSON(w, map[string]bool{"ok": true})
		return nil
	}
	b.publish(r, req.Type, req.Data)
	if title != "" && req.Type == adapters.Started && b.Turns != nil {
		if name := b.Turns.SessionOf(req.Data); name != "" {
			b.nameAfter(r.Context(), name, adapters.Clip(title, adapters.TitleMax))
		}
	}
	if hasAsk && b.Turns != nil && req.Type == adapters.Waiting {
		b.Turns.NoteAsk(req.Data, ask)
	}
	writeJSON(w, map[string]bool{"ok": true})
	return nil
}

var validEventType = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}\.[a-z][a-z0-9-]{0,31}$`)

var unsafeSessionChars = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

// defaultSessionName names a session after where it runs and what it runs,
// e.g. "shop-checkout-claude".
func defaultSessionName(location, command string) string {
	prog := "shell"
	if f := splitFirst(command); f != "" {
		prog = filepath.Base(f)
	}
	name := unsafeSessionChars.ReplaceAllString(location+"-"+prog, "-")
	if len(name) > 48 {
		name = name[:48]
	}
	return name + "-" + strconv.FormatInt(time.Now().Unix()%100000, 36)
}

func splitFirst(command string) string {
	for i, r := range command {
		if r == ' ' || r == '\t' {
			return command[:i]
		}
	}
	return command
}

// writeJSON sends v, with an empty list as [] rather than null: every list
// the box answers with is one the app and plugins iterate over.
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if rv := reflect.ValueOf(v); rv.Kind() == reflect.Slice && rv.IsNil() {
		v = []struct{}{}
	}
	json.NewEncoder(w).Encode(v)
}

func writeCoded(w http.ResponseWriter, status int, msg, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg, "code": code})
}
