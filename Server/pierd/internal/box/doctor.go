package box

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"

	"pier/pierd/internal/doctor"
	"pier/pierd/internal/groups"
	"pier/pierd/internal/integrations"
)

// Doctor reports what this box can do and what is missing. Daemon-level
// checks (service, listen address, paired laptops) come from pierd through
// DaemonChecks; the rest are the same on every box.
func (b *Box) Doctor(ctx context.Context) []doctor.Check {
	var checks []doctor.Check
	if b.DaemonChecks != nil {
		checks = append(checks, b.DaemonChecks()...)
	}
	checks = append(checks,
		doctor.ToolCheck("Worktrees and sessions", "git", "locations and worktrees", "Install git with your package manager", true),
		TmuxCheck(),
		// What sessions and the checks above find tools on: a service often
		// starts with less than a login shell has.
		doctor.Check{Area: "Worktrees and sessions", Name: "PATH", Status: doctor.Info, Detail: os.Getenv("PATH")},
	)
	// Doctor looks for the agent CLIs afresh: one installed since shows.
	b.refreshAgents(ctx)
	checks = append(checks, agentChecks()...)
	if m := groups.Now(); len(m.Groups) > 0 {
		checks = append(checks, doctor.Check{Area: "Worktrees and sessions", Name: "groups", Status: doctor.Info,
			Detail: "you joined " + strings.Join(m.Groups, ", ") + " after pierd started, so pierd lacks it; what pierd starts now (terminals, services, scripts, hooks) gets it through sg",
			Fix:    "Terminals and services already running keep their groups until they start again; after the next reboot this goes away"})
	}
	if home, err := os.UserHomeDir(); err == nil {
		for _, t := range integrations.Tools {
			if !t.Present(home) {
				continue
			}
			c := doctor.Check{Area: "Agents", Name: t.Name + " hooks", Status: doctor.OK, Detail: "pierd's hooks installed"}
			if !t.Hooked(home) {
				c.Status, c.Detail, c.Fix = doctor.Warn, "not installed, so pierd cannot tell when this agent is done or needs you", "pierd integrations install "+t.ID
			}
			checks = append(checks, c)
			// Signed out, a new session stops at the agent's login prompt and nothing in the app says why.
			if in, known := t.SignedIn(home); known {
				s := doctor.Check{Area: "Agents", Name: t.Name + " sign-in", Status: doctor.OK, Detail: "signed in"}
				if !in {
					s.Status, s.Detail, s.Fix = doctor.Warn, "not signed in on this box: a new session would stop at its login prompt", t.LoginFix
				}
				checks = append(checks, s)
			}
		}
	}
	checks = append(checks, b.eventChecks()...)
	locs, err := b.Locations.List(ctx)
	if err != nil {
		checks = append(checks, doctor.Check{Area: "Locations", Name: "locations", Status: doctor.Fail, Detail: err.Error()})
		return checks
	}
	for _, l := range locs {
		if _, err := os.Stat(l.Path); err != nil {
			checks = append(checks, doctor.Check{Area: "Locations", Name: l.Name, Status: doctor.Fail, Detail: l.Path + " no longer exists", Fix: "pierd location rm " + l.Name})
			continue
		}
		kind := "folder"
		if l.Repo {
			kind = "git repository"
		}
		checks = append(checks, doctor.Check{Area: "Locations", Name: l.Name, Status: doctor.OK, Detail: kind + " at " + l.Path})
	}
	if len(locs) == 0 {
		checks = append(checks, doctor.Check{Area: "Locations", Name: "locations", Status: doctor.Info, Detail: "none yet", Fix: "pierd location add NAME ~/path/to/repo"})
	}
	return append(checks, b.processChecks(ctx)...)
}

// processChecks say how sessions are cleaned up here.
func (b *Box) processChecks(ctx context.Context) []doctor.Check {
	var checks []doctor.Check
	if b.Sessions != nil {
		c := doctor.Check{Area: "Worktrees and sessions", Name: "session cleanup", Status: doctor.OK}
		switch {
		case b.Sessions.Scopes != nil && b.Sessions.Scopes.Available(ctx):
			c.Detail = "each new session runs in a systemd scope of its own; ending it stops everything it started"
		case useMarkers:
			c.Detail = "no systemd user manager, so ending a session stops the processes in its tree and those that carry its PIER_SESSION"
		default:
			c.Detail = "ending a session stops the processes in its tree"
		}
		checks = append(checks, c)
	}
	return checks
}

// eventChecks report the journal and every subscriber that fell behind or
// lost events.
func (b *Box) eventChecks() []doctor.Check {
	var checks []doctor.Check
	if j := b.Events.Journal; j != nil {
		st := j.Stats()
		c := doctor.Check{Area: "Events", Name: "journal", Status: doctor.OK,
			Detail: fmt.Sprintf("%d events, %d segments, %.1f MB", st.Head, st.Segments, float64(st.Bytes)/(1<<20))}
		if st.Errors > 0 {
			c.Status, c.Detail = doctor.Warn, fmt.Sprintf("%d writes failed; check the disk under %s", st.Errors, j.Dir)
		}
		checks = append(checks, c)
	}
	for _, s := range b.Events.Stats() {
		c := doctor.Check{Area: "Events", Name: s.Name, Status: doctor.OK, Detail: "no events lost"}
		if s.Lags > 0 {
			c.Detail = fmt.Sprintf("fell behind %d times and caught up from the journal", s.Lags)
		}
		if s.Dropped > 0 {
			c.Status, c.Detail = doctor.Warn, fmt.Sprintf("lost %d events", s.Dropped)
		}
		checks = append(checks, c)
	}
	if b.Turns != nil && b.Turns.Ambiguous.Load() > 0 {
		checks = append(checks, doctor.Check{Area: "Events", Name: "agent hooks", Status: doctor.Info,
			Detail: fmt.Sprintf("%d hook events named only a folder shared by several agents, so they were not used", b.Turns.Ambiguous.Load()),
			Fix:    "Restart those agent sessions: sessions pierd starts tell hooks their name"})
	}
	return checks
}

func (b *Box) handleDoctor(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.Doctor(r.Context()))
	return nil
}
