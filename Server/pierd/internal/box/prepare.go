package box

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"pier/pierd/internal/events"
	"pier/pierd/internal/statefile"
)

// Preparing a worktree is what makes it more than a checkout. Two ways:
//
//   - script: the location's setup script (an npm install, an env file
//     copied in), then the services that start on their own (a dev server,
//     the project's compose);
//   - agent: a setup agent (setupagent.go), Claude Code in a session of its
//     own, that works out what the project needs, installs it, gets the
//     app running with a test login, and saves what it did as the
//     location's setup script, so the next worktree is prepared by script.
//
// A new worktree is prepared as it is made, the way the request says
// (prepare_with) or, by default, by script when the location has a recipe
// and by an agent when it has none; "none" (or the older "prepare": false)
// makes only the checkout, for a quick fix, prepared later from the app
// (POST .../worktrees/{wt}/prepare). How each preparation went is kept in
// pierd's state folder, so it reads the same after a restart.

// PrepareStatus is how a worktree's preparation stands.
type PrepareStatus struct {
	// State is "running", "ready", "failed", "skipped" (made with prepare:
	// false and not prepared since) or "unknown" (nothing recorded).
	State string `json:"state"`
	// Since is when the state began (absent for unknown).
	Since *time.Time `json:"since,omitempty"`
	Error string     `json:"error,omitempty"`
	// Kind is how it is or was prepared: "script" or "agent".
	Kind string `json:"kind,omitempty"`
	// Session is the setup agent's session (kind "agent").
	Session string `json:"session,omitempty"`
	// Waiting says the setup agent, still at work, waits for someone.
	Waiting bool `json:"waiting,omitempty"`
	// Setup is the setup script that runs, empty when there is none.
	Setup string `json:"setup,omitempty"`
	// Services are the services that start on their own.
	Services []string `json:"services"`
	// PrepareWith is how preparing it now goes when the request does not
	// say: "agent" or "script".
	PrepareWith string `json:"prepare_with,omitempty"`
	// Step is what a running preparation is doing: "carry" (folders from
	// the main checkout), "setup" (the recipe), "agent" or "services".
	Step string `json:"step,omitempty"`
	// Base is how the project's base went into the worktree.
	Base *BaseReport `json:"base,omitempty"`
}

// prepRecord is a preparation as kept on disk.
type prepRecord struct {
	State   string     `json:"state"`
	Since   *time.Time `json:"since,omitempty"`
	Error   string     `json:"error,omitempty"`
	Kind    string     `json:"kind,omitempty"`
	Session string     `json:"session,omitempty"`
	// Done says the setup agent reported it was done (pierd prepare done):
	// a later turn of its conversation that reports nothing keeps it ready.
	Done bool `json:"done,omitempty"`
	// Last is the last setup agent's session, kept through runs of any
	// kind: the next one takes the other name (startAgent).
	Last string `json:"last_session,omitempty"`
	// Checkout marks a worktree made from a pull request (pr, ref): its
	// code is nobody's to vet, so no setup agent prepares it unasked.
	Checkout bool `json:"checkout,omitempty"`
	// Step is what a running preparation is doing (PrepareStatus.Step).
	Step string `json:"step,omitempty"`
	// Base is how the project's base went into the worktree.
	Base *BaseReport `json:"base,omitempty"`
}

type prepStates struct {
	mu   sync.Mutex
	once sync.Once
	// path is "" without a state folder: kept in memory only.
	path string
	all  map[string]prepRecord
}

// preps is how the box's worktrees' preparations stand, read from disk the
// first time.
func (b *Box) preps() *prepStates {
	b.prep.once.Do(func() {
		b.prep.mu.Lock()
		defer b.prep.mu.Unlock()
		if b.prep.all == nil {
			b.prep.all = map[string]prepRecord{}
		}
		if b.StateDir == "" {
			return
		}
		b.prep.path = filepath.Join(b.StateDir, "prepare.json")
		data, err := os.ReadFile(b.prep.path)
		if err != nil {
			return
		}
		var saved map[string]prepRecord
		if json.Unmarshal(data, &saved) != nil {
			return
		}
		for k, r := range saved {
			// A setup script runs inside pierd: one running when pierd went
			// down was stopped with it. A setup agent runs in its own
			// session and may still be at work (ResumePrepare).
			if r.State == "running" && r.Kind != "agent" {
				now := time.Now()
				r.State, r.Since, r.Error = "failed", &now, "pierd restarted before the setup script ended: prepare it again"
			}
			// A setup agent's run still putting the base in place had no
			// session yet: nothing goes on with it.
			if r.State == "running" && r.Kind == "agent" && baseStep(r.Step) {
				now := time.Now()
				r.State, r.Since, r.Error, r.Step = "failed", &now, "pierd restarted while it put the project's base in place: prepare it again", ""
			}
			b.prep.all[k] = r
		}
	})
	return &b.prep
}

// save writes the records; s.mu is held.
func (s *prepStates) save() {
	if s.path == "" {
		return
	}
	data, _ := json.MarshalIndent(s.all, "", "  ")
	statefile.Write(s.path, append(data, '\n'))
}

func (s *prepStates) get(key string) (prepRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.all[key]
	return r, ok
}

// update changes key's record with change and saves it.
func (s *prepStates) update(key string, change func(r *prepRecord)) prepRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.all[key]
	change(&r)
	s.all[key] = r
	s.save()
	return r
}

// finishIfPresent records how key's preparation ended, if pierd still keeps
// it: a worktree forgotten meanwhile (removed) is not brought back.
func (s *prepStates) finishIfPresent(key, state string, err error) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.all[key]
	if !ok {
		return false
	}
	now := time.Now()
	r.State, r.Since, r.Error, r.Step = state, &now, "", ""
	if err != nil {
		r.Error = err.Error()
	}
	s.all[key] = r
	s.save()
	return true
}

// markCheckout records that key's worktree was made from a pull request.
func (s *prepStates) markCheckout(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.all[key]
	r.Checkout = true
	if r.State == "" {
		r.State = "unknown"
	}
	s.all[key] = r
	s.save()
}

// named says some worktree's setup agent ran or runs in session name.
func (s *prepStates) named(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.all {
		if name != "" && (r.Session == name || r.Last == name) {
			return true
		}
	}
	return false
}

// start marks key running, prepared as kind (by session, for an agent),
// unless it already is; false means it was.
func (s *prepStates) start(key, kind, session string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.all[key].State == "running" {
		return false
	}
	now := time.Now()
	old := s.all[key]
	last := old.Last
	if session != "" {
		last = session
	}
	s.all[key] = prepRecord{State: "running", Since: &now, Kind: kind, Session: session, Last: last, Checkout: old.Checkout, Base: old.Base}
	s.save()
	return true
}

// startAgent marks key running by a setup agent, unless it already is. Its
// session is base, or base-2 when the last run's was base: a run's session
// never has the last one's name, so what the last one says as it is stopped
// is never taken for this one's. previous is the last run's session.
func (s *prepStates) startAgent(key, base string) (name, previous string, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, had := s.all[key]
	if r.State == "running" {
		return "", "", false
	}
	return s.agentRunLocked(key, r, had, base)
}

// handToAgent turns key's running script preparation into a setup agent's
// (prepareByScript's fallback), with startAgent's names; false when pierd no
// longer keeps it (the worktree went away).
func (s *prepStates) handToAgent(key, base string) (name, previous string, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, had := s.all[key]
	if !had {
		return "", "", false
	}
	return s.agentRunLocked(key, r, had, base)
}

func (s *prepStates) agentRunLocked(key string, r prepRecord, had bool, base string) (name, previous string, ok bool) {
	if had {
		previous = r.Last
		if previous == "" {
			previous = r.Session
		}
	}
	name = base
	if previous == base {
		name = base + "-2"
	}
	now := time.Now()
	s.all[key] = prepRecord{State: "running", Since: &now, Kind: "agent", Session: name, Last: name, Checkout: r.Checkout, Base: r.Base}
	s.save()
	return name, previous, true
}

// running lists the setup agents still at work, by key.
func (s *prepStates) agents() map[string]prepRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]prepRecord{}
	for k, r := range s.all {
		if r.Kind == "agent" && r.State == "running" && r.Session != "" {
			out[k] = r
		}
	}
	return out
}

// forget drops the records of a location's worktree (worktree "": all of
// them), telling gone about each setup session they named.
func (s *prepStates) forget(location, worktree string, gone func(session string)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for k, r := range s.all {
		l, w, _ := strings.Cut(k, "/")
		if l == location && (worktree == "" || w == worktree) {
			for _, name := range []string{r.Session, r.Last} {
				if name != "" {
					gone(name)
				}
			}
			delete(s.all, k)
			changed = true
		}
	}
	if changed {
		s.save()
	}
}

func prepKey(location, worktree string) string { return location + "/" + worktree }

// setPrepare records a preparation's end (or skip), keeping how it ran.
func (b *Box) setPrepare(location, worktree, state string, err error) {
	b.preps().update(prepKey(location, worktree), func(r *prepRecord) {
		now := time.Now()
		r.State, r.Since, r.Error = state, &now, ""
		if err != nil {
			r.Error = err.Error()
		}
		if state == "skipped" {
			r.Kind, r.Session, r.Done = "", "", false
		}
	})
}

// prepareData is what the worktree.prepare.* events carry.
func (b *Box) prepareData(loc Location, wt Worktree) map[string]any {
	data := map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path}
	if r, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && r.Kind != "" {
		data["kind"] = r.Kind
		if r.Session != "" {
			data["session"] = r.Session
		}
	}
	return data
}

// finishPrepare records how a preparation ended and says so
// (worktree.prepare.finished, or .failed with err); nothing for a worktree
// that went away meanwhile.
func (b *Box) finishPrepare(from string, loc Location, wt Worktree, err error) {
	key := prepKey(loc.Name, wt.Name)
	if err != nil {
		if b.preps().finishIfPresent(key, "failed", err) {
			b.Events.Publish(events.Event{Type: "worktree.prepare.failed", Box: b.Name, Origin: from, Error: err.Error(), Data: b.prepareData(loc, wt)})
		}
		return
	}
	if b.preps().finishIfPresent(key, "ready", nil) {
		b.Events.Publish(events.Event{Type: "worktree.prepare.finished", Box: b.Name, Origin: from, Data: b.prepareData(loc, wt)})
	}
}

// agentFallback says a failed run of loc's setup script goes on with a setup
// agent: a setup agent saved that recipe (a person's own is only ever run),
// the person allowed setup agents for the location, the worktree is not a
// pull request's, the repository's config is trusted and the box can run
// one.
func (b *Box) agentFallback(ctx context.Context, loc Location, wt Worktree) bool {
	if r, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && r.Checkout {
		return false
	}
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil || cfg.Local.PrepareWith != "agent" || cfg.Local.By != "setup" || cfg.Local.Setup == "" || !repoVetted(cfg) {
		return false
	}
	_, ok := setupAgentPreset(&loc)
	return ok
}

// prepareWorktree runs the setup script, then the autostart services, and
// says how it went (worktree.prepare.started / .finished / .failed, beside
// the setup script's own events). Callers claim the run first
// (preps().start) and run this in the background.
func (b *Box) prepareWorktree(from string, loc Location, wt Worktree) error {
	return b.prepareByScript(from, DefaultOrigin, loc, wt, false)
}

// prepareByScript is prepareWorktree; with fallback, a recipe a setup agent
// saved that fails hands the worktree to a setup agent, told what failed,
// rather than leaving it half made (it may not fit every branch), where
// agentFallback allows it.
func (b *Box) prepareByScript(from, gateFrom string, loc Location, wt Worktree, fallback bool) error {
	b.Events.Publish(events.Event{Type: "worktree.prepare.started", Box: b.Name, Origin: from, Data: b.prepareData(loc, wt)})
	if err := b.prepareBase(from, loc, wt); err != nil {
		b.finishPrepare(from, loc, wt, err)
		return err
	}
	var err error
	if loc.Scripts.Setup != "" {
		b.prepareStep(from, loc, wt, "setup")
		err = b.lifecycle(from, "setup", loc, wt.Path, wt.Name, loc.Scripts.Setup, nil)
	}
	if err == nil {
		// A recipe written before the worktree had servers of its own may
		// have pointed the app back at the box's: put it right.
		if fixed := b.rewriteConnections(context.Background(), loc, wt); len(fixed) > 0 {
			b.recordBase(loc.Name, wt.Name, func(rep *BaseReport) { rep.Connections = append(rep.Connections, fixed...) })
		}
		// Services start once setup has made the worktree ready for them.
		b.prepareStep(from, loc, wt, "services")
		b.startAutostart(loc.Name, wt.Name)
		b.applyPreviewTemplate(context.Background(), from, loc, wt)
		b.finishPrepare(from, loc, wt, nil)
		return nil
	}
	if fallback && b.agentFallback(context.Background(), loc, wt) {
		// The same preparation goes on, by an agent now.
		if name, previous, ok := b.preps().handToAgent(prepKey(loc.Name, wt.Name), setupSessionName(loc, wt)); ok {
			b.Events.Publish(events.Event{Type: "worktree.prepare.started", Box: b.Name, Origin: from, Data: b.prepareData(loc, wt)})
			b.runSetupAgent(from, gateFrom, loc, wt, name, previous, err.Error())
			return err
		}
	}
	b.finishPrepare(from, loc, wt, err)
	return err
}

// setupGrace is how long a setup agent's run may be without its session:
// the one it starts in comes a moment after the run is claimed. Tests
// shorten it.
var setupGrace = 20 * time.Second

// settleVanished ends a setup agent's run whose session is gone or its
// agent exited without a word reaching pierd (a session killed from outside,
// a box that rebooted): it would read running forever otherwise.
func (b *Box) settleVanished(ctx context.Context, key string) {
	r, ok := b.preps().get(key)
	if !ok || r.Kind != "agent" || r.State != "running" || r.Since == nil || time.Since(*r.Since) < setupGrace || b.Sessions == nil {
		return
	}
	// Still putting the base in place: its session comes after.
	if baseStep(r.Step) {
		return
	}
	sess, err := b.Sessions.Get(ctx, r.Session)
	if errors.Is(err, ErrUnknownSession) || err == nil && sess.Exited {
		b.setupTurnEnded(DefaultOrigin, key, r.Session, false, true)
	}
}

// prepareStatus is the recorded state with what preparing would run.
func (b *Box) prepareStatus(ctx context.Context, loc Location, wt Worktree) PrepareStatus {
	st := PrepareStatus{State: "unknown"}
	b.settleVanished(ctx, prepKey(loc.Name, wt.Name))
	if r, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok {
		st.Base = r.Base
	}
	if r, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && r.State != "unknown" {
		st = PrepareStatus{State: r.State, Since: r.Since, Error: r.Error, Kind: r.Kind, Session: r.Session, Base: r.Base}
		if r.State == "running" {
			st.Step = r.Step
		}
		if r.Kind == "agent" && r.State == "running" && b.Turns != nil {
			if ss, ok := b.Turns.State(r.Session); ok && ss.State == "waiting" {
				st.Waiting = true
			}
		}
	}
	st.Setup = loc.Scripts.Setup
	st.Services = []string{}
	if all, err := b.WorktreeServices(ctx, loc.Name, wt.Name); err == nil {
		for _, s := range all {
			if s.Autostart {
				st.Services = append(st.Services, s.Name)
			}
		}
	}
	st.PrepareWith = b.defaultPrepareWith(ctx, loc)
	if r, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && r.Checkout {
		st.PrepareWith = "script"
	}
	return st
}

// GET /v1/locations/{name}/worktrees/{worktree}/prepare
func (b *Box) getPrepare(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	writeJSON(w, b.prepareStatus(r.Context(), loc, wt))
	return nil
}

// POST /v1/locations/{name}/worktrees/{worktree}/prepare: prepare it now
// (again, for one already prepared), the way the body says
// ({"prepare_with": "agent"|"script"}; without one, the location's
// default). 202 with the running status; 409 while a preparation of it
// still runs.
func (b *Box) postPrepare(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	var req struct {
		PrepareWith string `json:"prepare_with"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	if req.PrepareWith == "none" {
		return badRequest("prepare_with is agent or script here")
	}
	if b.syncTeam(r.Context(), loc.Name) != nil {
		if fresh, err := b.Locations.Get(r.Context(), loc.Name); err == nil {
			loc = fresh
		}
	}
	// A pull request's worktree is never handed to a setup agent unasked.
	rec, _ := b.preps().get(prepKey(loc.Name, wt.Name))
	how, err := b.prepareWithFor(r.Context(), loc, req.PrepareWith, nil, rec.Checkout)
	if err != nil {
		return err
	}
	if err := b.before(r, "worktree.prepare", map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path, "prepare_with": how}); err != nil {
		return err
	}
	if cur, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && cur.State == "running" {
		return httpError{http.StatusConflict, "this worktree is already being prepared"}
	}
	// The base's files first, as for a new worktree: the recipe or agent
	// finds them in place.
	b.placeBaseFiles(r.Context(), loc, wt)
	// Claimed before the answer, so a second tap is refused and the app's
	// next read already sees it running.
	if !b.beginPrepare(r, loc, wt, how, false) {
		return httpError{http.StatusConflict, "this worktree is already being prepared"}
	}
	st := b.prepareStatus(r.Context(), loc, wt)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, st)
	return nil
}

// beginPrepare claims wt's preparation and starts it in the background, by
// script or by a setup agent; false when one already runs. fallback lets a
// failing recipe of the box's own go on with an agent (prepareByScript).
func (b *Box) beginPrepare(r *http.Request, loc Location, wt Worktree, how string, fallback bool) bool {
	key := prepKey(loc.Name, wt.Name)
	from, gateFrom := origin(r), gateOrigin(r)
	switch how {
	case "agent":
		name, previous, ok := b.preps().startAgent(key, setupSessionName(loc, wt))
		if !ok {
			return false
		}
		go func() {
			b.Events.Publish(events.Event{Type: "worktree.prepare.started", Box: b.Name, Origin: from, Data: b.prepareData(loc, wt)})
			b.runSetupAgent(from, gateFrom, loc, wt, name, previous, "")
		}()
	default:
		if !b.preps().start(key, "script", "") {
			return false
		}
		go b.prepareByScript(from, gateFrom, loc, wt, fallback)
	}
	return true
}

// POST /v1/locations/{name}/worktrees/{worktree}/prepare/done: the setup
// agent says it is done ({}), or that it could not finish ({"failed":
// "why"}); `pierd prepare done` sends it.
func (b *Box) prepareDone(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	var req struct {
		Failed string `json:"failed"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	key := prepKey(loc.Name, wt.Name)
	if rec, ok := b.preps().get(key); !ok || rec.Kind != "agent" {
		return httpError{http.StatusConflict, "this worktree is not being prepared by a setup agent"}
	}
	if why := strings.TrimSpace(req.Failed); why != "" {
		b.preps().update(key, func(r *prepRecord) { r.Done = false })
		b.finishPrepare(origin(r), loc, wt, errorText(clip(why, 4096)))
	} else {
		b.preps().update(key, func(r *prepRecord) { r.Done = true })
		b.finishAgentPrepare(origin(r), loc, wt)
	}
	writeJSON(w, b.prepareStatus(r.Context(), loc, wt))
	return nil
}

// errorText is an error that is only its text.
type errorText string

func (e errorText) Error() string { return string(e) }

// clip is s cut to at most n bytes, at a character's start.
func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}
