package box

import (
	"context"
	"fmt"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Managing worktrees in bulk: where each stands against its base, its
// commits, bringing it up to date, and pausing it so it costs nothing until
// it is wanted again.

// Commit is one commit in a worktree's history.
type Commit struct {
	SHA     string    `json:"sha"`
	Short   string    `json:"short"`
	Subject string    `json:"subject"`
	Author  string    `json:"author"`
	Time    time.Time `json:"time"`
	Refs    string    `json:"refs,omitempty"`
	// Parents are the commits this one follows; two or more for a merge.
	// With them a client can draw the history as a graph.
	Parents []string `json:"parents"`
	// OnBase is false for commits the base branch does not have yet.
	OnBase bool `json:"on_base"`
}

// WorktreeStatus is where a worktree stands.
type WorktreeStatus struct {
	Location string  `json:"location"`
	Name     string  `json:"name"`
	Path     string  `json:"path"`
	Branch   string  `json:"branch,omitempty"`
	Main     bool    `json:"main,omitempty"`
	Port     int     `json:"port,omitempty"`
	Base     string  `json:"base,omitempty"`
	Ahead    int     `json:"ahead"`
	Behind   int     `json:"behind"`
	Changed  int     `json:"changed"`
	Untrack  int     `json:"untracked"`
	Last     *Commit `json:"last_commit,omitempty"`
	Sessions int     `json:"sessions"`
	Error    string  `json:"error,omitempty"`
}

// baseOf is what a worktree is compared and synced against: its upstream,
// else origin's default branch, else the local default branch.
func baseOf(ctx context.Context, wt Worktree, loc Location) string {
	if out, err := git(ctx, "-C", wt.Path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"); err == nil {
		if u := strings.TrimSpace(string(out)); u != "" && u != wt.Branch {
			return u
		}
	}
	def := loc.DefaultBranch
	if def == "" {
		def = "main"
	}
	if wt.Branch == def {
		if branchExists(ctx, loc.Path, "refs/remotes/origin/"+def) {
			return "origin/" + def
		}
		return ""
	}
	if branchExists(ctx, loc.Path, "refs/remotes/origin/"+def) {
		return "origin/" + def
	}
	return def
}

func (b *Box) worktreeStatus(ctx context.Context, loc Location, wt Worktree, sessions []Session) WorktreeStatus {
	st := WorktreeStatus{Location: loc.Name, Name: wt.Name, Path: wt.Path, Branch: wt.Branch, Main: wt.Main, Port: wt.Port}
	st.Base = baseOf(ctx, wt, loc)
	if st.Base != "" {
		if out, err := git(ctx, "-C", wt.Path, "rev-list", "--left-right", "--count", st.Base+"...HEAD"); err == nil {
			f := strings.Fields(string(out))
			if len(f) == 2 {
				st.Behind, _ = strconv.Atoi(f[0])
				st.Ahead, _ = strconv.Atoi(f[1])
			}
		}
	}
	if out, err := git(ctx, "-C", wt.Path, "status", "--porcelain=v1"); err == nil {
		for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
			switch {
			case line == "":
			case strings.HasPrefix(line, "??"):
				st.Untrack++
			default:
				st.Changed++
			}
		}
	} else {
		st.Error = strings.TrimSpace(string(out))
	}
	if commits, err := gitLog(ctx, wt.Path, "", 1); err == nil && len(commits) == 1 {
		st.Last = &commits[0]
	}
	for _, s := range sessions {
		if samePath(s.Dir, wt.Path) && !s.Exited {
			st.Sessions++
		}
	}
	return st
}

const logFormat = "%H%x1f%h%x1f%s%x1f%an%x1f%aI%x1f%D%x1f%P%x1e"

// gitLog lists commits from HEAD, newest first. With withBase, the base's
// own recent commits come too, in graph order, so the history shows where
// the branch left its base and what the base has done since.
func gitLog(ctx context.Context, dir, base string, limit int, withBase ...bool) ([]Commit, error) {
	args := []string{"-C", dir, "log", "-n", strconv.Itoa(limit), "--format=" + logFormat}
	if len(withBase) > 0 && withBase[0] && base != "" {
		args = append(args, "--topo-order", "HEAD", base)
	}
	out, err := git(ctx, args...)
	if err != nil {
		return nil, fmt.Errorf("git log: %s", strings.TrimSpace(string(out)))
	}
	notOnBase := map[string]bool{}
	if base != "" {
		if ahead, err := git(ctx, "-C", dir, "rev-list", base+"..HEAD"); err == nil {
			for _, sha := range strings.Fields(string(ahead)) {
				notOnBase[sha] = true
			}
		}
	}
	commits := []Commit{}
	for _, rec := range strings.Split(string(out), "\x1e") {
		f := strings.Split(strings.TrimSpace(rec), "\x1f")
		if len(f) != 7 {
			continue
		}
		t, _ := time.Parse(time.RFC3339, f[4])
		parents := strings.Fields(f[6])
		if parents == nil {
			parents = []string{}
		}
		commits = append(commits, Commit{SHA: f[0], Short: f[1], Subject: f[2], Author: f[3], Time: t, Refs: f[5], Parents: parents, OnBase: base == "" || !notOnBase[f[0]]})
	}
	return commits, nil
}

func (b *Box) listWorktreeStatuses(w http.ResponseWriter, r *http.Request) error {
	locs, err := b.Locations.List(r.Context())
	if err != nil {
		return err
	}
	only := r.URL.Query().Get("location")
	sessions, _ := b.Sessions.List(r.Context())
	type job struct {
		loc Location
		wt  Worktree
	}
	var jobs []job
	for _, l := range locs {
		if !l.Repo || (only != "" && l.Name != only) {
			continue
		}
		for _, wt := range l.Worktrees {
			jobs = append(jobs, job{l, wt})
		}
	}
	out := make([]WorktreeStatus, len(jobs))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, j := range jobs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[i] = b.worktreeStatus(r.Context(), j.loc, j.wt, sessions)
		}()
	}
	wg.Wait()
	writeJSON(w, out)
	return nil
}

// Pausing: an agent's processes are stopped where they are (SIGSTOP), so
// it uses no CPU and carries on exactly where it was when resumed, and the
// worktree's services are stopped and remembered to be started again.

// samePath compares directories as the filesystem sees them: tmux reports
// /private/var where git says /var on macOS.
func samePath(a, b string) bool {
	if a == b {
		return true
	}
	ra, err1 := filepath.EvalSymlinks(a)
	rb, err2 := filepath.EvalSymlinks(b)
	return err1 == nil && err2 == nil && ra == rb
}
