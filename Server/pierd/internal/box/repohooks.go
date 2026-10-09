package box

import (
	"context"
	"log"
	"net/http"
	"strings"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/hooks"
)

// A repository's hooks run only for its own events, inside the worktree the
// event is about, with that worktree's environment.

// eventScope finds the location and worktree an event is about: from its
// "location" ("shop" or "shop/checkout") or, failing that, its path.
func (b *Box) eventScope(ctx context.Context, data map[string]any) (Location, Worktree, bool) {
	if p, _ := data["path"].(string); p != "" {
		if loc, wt, ok := b.worktreeAt(ctx, p); ok {
			return loc, wt, true
		}
	}
	ref, _ := data["location"].(string)
	if ref == "" {
		return Location{}, Worktree{}, false
	}
	name, wtName, _ := strings.Cut(ref, "/")
	if wtName == "" {
		wtName, _ = data["name"].(string)
	}
	loc, err := b.Locations.Get(ctx, name)
	if err != nil {
		return Location{}, Worktree{}, false
	}
	for _, w := range loc.Worktrees {
		if w.Name == wtName {
			return loc, w, true
		}
	}
	for _, w := range loc.Worktrees {
		if w.Main {
			return loc, w, true
		}
	}
	return loc, Worktree{Name: loc.Name, Path: loc.Path, Main: true}, true
}

// repoHooks returns the hooks of the location an event is about, ready to
// run in its worktree, and that worktree's environment.
func (b *Box) repoHooks(ctx context.Context, data map[string]any) ([]hooks.Hook, []string) {
	loc, wt, ok := b.eventScope(ctx, data)
	if !ok {
		return nil, nil
	}
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil || len(cfg.Effective.Hooks) == 0 {
		return nil, nil
	}
	env, err := b.WorktreeEnv(ctx, loc.Name, wt)
	if err != nil {
		return nil, nil
	}
	out := make([]hooks.Hook, len(cfg.Effective.Hooks))
	for i, h := range cfg.Effective.Hooks {
		h.Dir = wt.Path
		if h.Source == "" {
			h.Source = "repo:" + loc.Name
		}
		out[i] = h
	}
	return out, env
}

// RunRepoHooks follows the box's events and runs repositories' hooks for
// them, one at a time, off the event path.
func (b *Box) RunRepoHooks(ctx context.Context, logger *log.Logger) {
	cur := b.Events.SubscribeFrom(-1).Named("repo hooks")
	defer cur.Close()
	hooks.RunWorkers(ctx, cur, 4, func(e events.Event) {
		if e.Data == nil {
			return
		}
		hs, env := b.repoHooks(ctx, e.Data)
		for _, h := range hs {
			if !hooks.Matches(h, e) {
				continue
			}
			out, err := hooks.Exec(ctx, h, e, time.Minute, env)
			if logger != nil {
				if err != nil {
					logger.Printf("%s hook %q for %s failed: %v: %s", h.Source, h.On, e.Type, err, strings.TrimSpace(string(out)))
				} else {
					logger.Printf("%s hook %q ran for %s", h.Source, h.On, e.Type)
				}
			}
		}
	})
}

// beforeRepo runs the gates of the repository an action is about.
func (b *Box) beforeRepo(r *http.Request, e events.Event) error {
	return b.beforeRepoCtx(r.Context(), e)
}

func (b *Box) beforeRepoCtx(ctx context.Context, e events.Event) error {
	hs, env := b.repoHooks(ctx, e.Data)
	for _, hk := range hs {
		if !hooks.MatchesBefore(hk, e) {
			continue
		}
		if out, err := hooks.Exec(ctx, hk, e, 30*time.Second, env); err != nil {
			msg := strings.TrimSpace(string(out))
			if msg == "" {
				msg = err.Error()
			}
			return httpError{http.StatusForbidden, "a " + hk.Source + " \"" + hk.On + "\" hook stopped " + e.Type + ": " + msg}
		}
	}
	return nil
}
