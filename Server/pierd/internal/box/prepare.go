package box

import (
	"context"
	"net/http"
	"sync"
	"time"

	"pier/pierd/internal/events"
)

// Preparing a worktree is what makes it more than a checkout: the
// location's setup script (an npm install, an env file copied in), then
// the services that start on their own (a dev server, the project's
// compose). A new worktree is prepared unless it was asked not to be
// ("prepare": false), for a quick fix that only needs the code; it can be
// prepared later from the app (POST .../worktrees/{wt}/prepare).

// PrepareStatus is how a worktree's preparation stands.
type PrepareStatus struct {
	// State is "running", "ready", "failed", "skipped" (made with
	// prepare: false and not prepared since) or "unknown" (nothing
	// recorded since pierd started).
	State string `json:"state"`
	// Since is when the state began (absent for unknown).
	Since *time.Time `json:"since,omitempty"`
	Error string     `json:"error,omitempty"`
	// Setup is the setup script that runs, empty when there is none.
	Setup string `json:"setup,omitempty"`
	// Services are the services that start on their own.
	Services []string `json:"services"`
}

type prepStates struct {
	mu  sync.Mutex
	all map[string]PrepareStatus
}

func (s *prepStates) get(key string) (PrepareStatus, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st, ok := s.all[key]
	return st, ok
}

func (s *prepStates) set(key string, st PrepareStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.all == nil {
		s.all = map[string]PrepareStatus{}
	}
	s.all[key] = st
}

// start marks key running unless it already is; false means it was.
func (s *prepStates) start(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.all[key].State == "running" {
		return false
	}
	if s.all == nil {
		s.all = map[string]PrepareStatus{}
	}
	now := time.Now()
	s.all[key] = PrepareStatus{State: "running", Since: &now}
	return true
}

func prepKey(location, worktree string) string { return location + "/" + worktree }

func (b *Box) setPrepare(location, worktree, state string, err error) {
	now := time.Now()
	st := PrepareStatus{State: state, Since: &now}
	if err != nil {
		st.Error = err.Error()
	}
	b.prep.set(prepKey(location, worktree), st)
}

// prepareWorktree runs the setup script, then the autostart services, and
// says how it went (worktree.prepare.started / .finished / .failed, beside
// the setup script's own events). Callers claim the run first
// (b.prep.start) and run this in the background.
func (b *Box) prepareWorktree(from string, loc Location, wt Worktree) error {
	data := map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path}
	b.Events.Publish(events.Event{Type: "worktree.prepare.started", Box: b.Name, Origin: from, Data: data})
	var err error
	if loc.Scripts.Setup != "" {
		err = b.lifecycle(from, "setup", loc, wt.Path, wt.Name, loc.Scripts.Setup, nil)
	}
	if err == nil {
		// Services start once setup has made the worktree ready for them.
		b.startAutostart(loc.Name, wt.Name)
		b.setPrepare(loc.Name, wt.Name, "ready", nil)
		b.Events.Publish(events.Event{Type: "worktree.prepare.finished", Box: b.Name, Origin: from, Data: data})
		return nil
	}
	b.setPrepare(loc.Name, wt.Name, "failed", err)
	b.Events.Publish(events.Event{Type: "worktree.prepare.failed", Box: b.Name, Origin: from, Error: err.Error(), Data: data})
	return err
}

// prepareStatus is the recorded state with what preparing would run.
func (b *Box) prepareStatus(ctx context.Context, loc Location, wt Worktree) PrepareStatus {
	st, ok := b.prep.get(prepKey(loc.Name, wt.Name))
	if !ok {
		st = PrepareStatus{State: "unknown"}
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
// (again, for one already prepared). 202 with the running status; 409 while
// a preparation of it still runs.
func (b *Box) postPrepare(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	if err := b.before(r, "worktree.prepare", map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path}); err != nil {
		return err
	}
	// Claimed before the answer, so a second tap is refused and the app's
	// next read already sees it running.
	if !b.prep.start(prepKey(loc.Name, wt.Name)) {
		return httpError{http.StatusConflict, "this worktree is already being prepared"}
	}
	go b.prepareWorktree(origin(r), loc, wt)
	st := b.prepareStatus(r.Context(), loc, wt)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, st)
	return nil
}
