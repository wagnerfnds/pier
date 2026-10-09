// Package box is what pierd offers paired laptops beyond raw port streams:
// locations and worktrees, listening ports, agent sessions, and shares.
package box

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"pier/pierd/internal/statefile"
	"pier/pierd/internal/trust"
)

// Location is a named place on a box where work happens: a repository or any
// directory. Agents and worktrees are created relative to a location.
type Location struct {
	Name string `json:"name"`
	Path string `json:"path"`
	// Repo is true when Path is the root of a git repository.
	Repo      bool       `json:"repo"`
	Worktrees []Worktree `json:"worktrees,omitempty"`
	// Scripts run when pierd creates or removes worktrees here.
	Scripts Scripts `json:"scripts"`
	// Agents are the repository's own agent presets.
	Agents []AgentPreset `json:"agents,omitempty"`
	// Remote is origin's URL, Slug its "owner/repo", and DefaultBranch
	// what new branches start from.
	Remote        string `json:"remote,omitempty"`
	Slug          string `json:"slug,omitempty"`
	DefaultBranch string `json:"default_branch,omitempty"`
	// RepoTrust is whether this box runs the repository's
	// config file: "none" without one, "trusted", or "untrusted" /
	// "changed" while it waits to be trusted and only its ports apply.
	RepoTrust string `json:"repo_trust,omitempty"`
}

type Worktree struct {
	Name   string `json:"name"`
	Path   string `json:"path"`
	Branch string `json:"branch,omitempty"`
	Head   string `json:"head,omitempty"`
	// Main marks the repository's own checkout.
	Main bool `json:"main,omitempty"`
	// SettingUp is true when the tool that made it is still running its
	// setup; a worktree.setup event follows.
	SettingUp bool `json:"setting_up,omitempty"`
	// Port is the first of the worktree's own ports ($PIER_PORT).
	Port int `json:"port,omitempty"`
	// Locked is set when git has the worktree locked, with LockReason
	// its reason ("initializing" while `git worktree add` runs).
	Locked     bool   `json:"locked,omitempty"`
	LockReason string `json:"lock_reason,omitempty"`
}

var (
	ErrUnknownLocation = errors.New("no location with that name")
	ErrUnknownWorktree = errors.New("no worktree with that name in the location")
)

type Locations struct {
	path string
	// Ports gives each worktree its own block of ports.
	Ports *PortAlloc
}

func NewLocations(path string) *Locations {
	return &Locations{path: path, Ports: &PortAlloc{Path: filepath.Join(filepath.Dir(path), "ports.json")}}
}

type savedLocation struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Setup   string `json:"setup,omitempty"`
	Archive string `json:"archive,omitempty"`
	// Config is this box's own config for the location, laid over the
	// repository's.
	Config *RepoConfig `json:"config,omitempty"`
	// RepoTrust is the sha256 of the repository's config file as
	// someone trusted it here; any other version of the file does not run.
	RepoTrust string `json:"repo_trust,omitempty"`
}

func (l *Locations) Add(ctx context.Context, name, path string) (Location, error) {
	if !trust.ValidName(name) {
		return Location{}, fmt.Errorf("invalid location name %q", name)
	}
	abs, err := filepath.Abs(expandHome(path))
	if err != nil {
		return Location{}, err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}
	info, err := os.Stat(abs)
	if err != nil || !info.IsDir() {
		return Location{}, fmt.Errorf("%s is not a directory on this box", abs)
	}
	err = l.update(func(all []savedLocation) ([]savedLocation, error) {
		out := all[:0]
		for _, s := range all {
			if s.Name == name {
				continue
			}
			out = append(out, s)
		}
		return append(out, savedLocation{Name: name, Path: abs}), nil
	})
	if err != nil {
		return Location{}, err
	}
	return l.Get(ctx, name)
}

func (l *Locations) Remove(name string) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i, s := range all {
			if s.Name == name {
				return append(all[:i], all[i+1:]...), nil
			}
		}
		return nil, ErrUnknownLocation
	})
}

func (l *Locations) List(ctx context.Context) ([]Location, error) {
	saved, err := l.read()
	if err != nil {
		return nil, err
	}
	out := make([]Location, 0, len(saved))
	for _, s := range saved {
		out = append(out, l.withPorts(describe(ctx, s)))
	}
	return out, nil
}

// withPorts adds each worktree's first port.
func (l *Locations) withPorts(loc Location) Location {
	for i := range loc.Worktrees {
		loc.Worktrees[i].Port, _ = l.Ports.For(loc.Worktrees[i].Path)
	}
	return loc
}

func (l *Locations) Get(ctx context.Context, name string) (Location, error) {
	saved, err := l.read()
	if err != nil {
		return Location{}, err
	}
	for _, s := range saved {
		if s.Name == name {
			return l.withPorts(describe(ctx, s)), nil
		}
	}
	return Location{}, ErrUnknownLocation
}

// Dir resolves "location" or "location/worktree" to a directory.
func (l *Locations) Dir(ctx context.Context, ref string) (string, error) {
	name, wt, _ := strings.Cut(ref, "/")
	loc, err := l.Get(ctx, name)
	if err != nil {
		return "", err
	}
	if wt == "" {
		return loc.Path, nil
	}
	for _, w := range loc.Worktrees {
		if w.Name == wt {
			return w.Path, nil
		}
	}
	return "", ErrUnknownWorktree
}

// CreateWorktree adds a git worktree next to the repository, following the
// <parent>/<repo>-<name> layout, on a new branch from base.
func (l *Locations) CreateWorktree(ctx context.Context, location, name, branch, base string) (Worktree, error) {
	return l.CreateWorktreeFrom(ctx, location, WorktreeRequest{Name: name, Branch: branch, Base: base})
}

// CreateWorktreeFrom makes a worktree for req: a new branch, an existing one
// (fetched from origin first, so it is current), or a pull request's head.
func (l *Locations) CreateWorktreeFrom(ctx context.Context, location string, req WorktreeRequest) (Worktree, error) {
	name, branch, base := req.Name, req.Branch, req.Base
	if !trust.ValidName(name) {
		return Worktree{}, fmt.Errorf("invalid worktree name %q", name)
	}
	// These go to git as arguments: a name starting with "-" would be read
	// as an option (--upload-pack=…), never as a ref.
	for _, ref := range []string{branch, base, req.Ref} {
		if strings.HasPrefix(ref, "-") {
			return Worktree{}, badRequest("%q is not a branch or ref name", ref)
		}
	}
	loc, err := l.Get(ctx, location)
	if err != nil {
		return Worktree{}, err
	}
	if !loc.Repo {
		return Worktree{}, fmt.Errorf("location %s is not a git repository", location)
	}
	if branch == "" {
		branch = name
	}
	path := filepath.Join(filepath.Dir(loc.Path), filepath.Base(loc.Path)+"-"+name)
	if !branchExists(ctx, loc.Path, "refs/heads/"+branch) && (req.PR > 0 || req.Ref != "" || branchExists(ctx, loc.Path, "refs/remotes/origin/"+branch)) {
		// Bring origin's branch up to date; a PR's own branch may live there.
		git(ctx, "-C", loc.Path, "fetch", "--quiet", "origin", branch)
		if !branchExists(ctx, loc.Path, "refs/remotes/origin/"+branch) && (req.PR > 0 || req.Ref != "") {
			ref := req.Ref
			if ref == "" {
				ref = fmt.Sprintf("pull/%d/head", req.PR)
			}
			if out, err := git(ctx, "-C", loc.Path, "fetch", "--quiet", "origin", ref+":"+branch); err != nil {
				return Worktree{}, fmt.Errorf("git fetch %s: %s", ref, strings.TrimSpace(string(out)))
			}
		}
	}
	args := []string{"-C", loc.Path, "worktree", "add"}
	switch {
	case branchExists(ctx, loc.Path, "refs/heads/"+branch):
		// An existing branch is checked out as it is, to review or continue.
		args = append(args, path, branch)
	case branchExists(ctx, loc.Path, "refs/remotes/origin/"+branch):
		args = append(args, "--track", "-b", branch, path, "origin/"+branch)
	default:
		args = append(args, "-b", branch, path)
		if base != "" {
			args = append(args, base)
		}
	}
	// The add runs to the end even if whoever asked goes away: one killed
	// halfway leaves a worktree git keeps locked as "initializing".
	_, statErr := os.Stat(path)
	hadPath := statErr == nil
	hadBranch := branchExists(ctx, loc.Path, "refs/heads/"+branch)
	if out, err := git(context.WithoutCancel(ctx), args...); err != nil {
		cleanUpFailedAdd(loc.Path, path, branch, hadPath, hadBranch)
		return Worktree{}, fmt.Errorf("git worktree add: %s", strings.TrimSpace(string(out)))
	}
	for _, w := range describe(ctx, savedLocation{Name: loc.Name, Path: loc.Path}).Worktrees {
		if w.Path == path {
			return w, nil
		}
	}
	return Worktree{Name: name, Path: path, Branch: branch}, nil
}

// cleanUpFailedAdd undoes what a failed `git worktree add` left: its
// half-made worktree and lock, the folder if it was new, and the branch if
// the add made it.
func cleanUpFailedAdd(repo, path, branch string, hadPath, hadBranch bool) {
	ctx := context.Background()
	if !hadPath {
		git(ctx, "-C", repo, "worktree", "unlock", path)
		git(ctx, "-C", repo, "worktree", "remove", "--force", "--force", path)
		os.RemoveAll(path)
	}
	git(ctx, "-C", repo, "worktree", "prune")
	if !hadBranch && branchExists(ctx, repo, "refs/heads/"+branch) {
		git(ctx, "-C", repo, "branch", "-D", branch)
	}
}

// gitLockReason is the reason `git worktree add` locks a worktree with
// while it runs; one still there means the add was interrupted.
const gitLockReason = "initializing"

// ownLock is true for a lock nobody chose: git's own from an interrupted
// add. Removing such a worktree unlocks it first; a lock a
// person set with `git worktree lock` is theirs to lift.
func ownLock(reason string) bool {
	return reason == gitLockReason
}

// errLocked explains a lock a person set, and how to lift it.
func errLocked(repo string, w Worktree) error {
	why := "with no reason given"
	if w.LockReason != "" {
		why = fmt.Sprintf("with the reason %q", w.LockReason)
	}
	return httpError{status: http.StatusConflict, msg: fmt.Sprintf(
		"%s is locked (git worktree lock, %s), so it was left as it is. Unlock it on the box with `git -C %s worktree unlock %s`, then try again.",
		w.Name, why, repo, w.Path)}
}

func branchExists(ctx context.Context, repo, ref string) bool {
	_, err := git(ctx, "-C", repo, "rev-parse", "--verify", "--quiet", ref)
	return err == nil
}

// RemoveWorktree removes a worktree. Git refuses when it has uncommitted
// changes unless force is set, and that refusal is passed on unchanged.
func (l *Locations) RemoveWorktree(ctx context.Context, location, name string, force bool) error {
	loc, err := l.Get(ctx, location)
	if err != nil {
		return err
	}
	for _, w := range loc.Worktrees {
		if w.Name != name {
			continue
		}
		if w.Main {
			return errors.New("refusing to remove the repository's main checkout")
		}
		if w.Locked {
			if !ownLock(w.LockReason) {
				return errLocked(loc.Path, w)
			}
			if out, err := git(ctx, "-C", loc.Path, "worktree", "unlock", w.Path); err != nil {
				return fmt.Errorf("git worktree unlock: %s", strings.TrimSpace(string(out)))
			}
		}
		args := []string{"-C", loc.Path, "worktree", "remove", w.Path}
		if force {
			args = append(args, "--force")
		}
		if out, err := git(ctx, args...); err != nil {
			return fmt.Errorf("git worktree remove: %s", strings.TrimSpace(string(out)))
		}
		return nil
	}
	return ErrUnknownWorktree
}

func describe(ctx context.Context, s savedLocation) Location {
	loc := Location{Name: s.Name, Path: s.Path, Scripts: scriptsFor(s)}
	repo, trust, _ := repoLayer(s)
	loc.RepoTrust = trust.State
	out, err := git(ctx, "-C", s.Path, "worktree", "list", "--porcelain")
	if err != nil {
		return loc
	}
	loc.Repo = true
	loc.Remote = remoteURL(ctx, s.Path)
	loc.Slug = slugOf(loc.Remote)
	loc.DefaultBranch = defaultBranch(ctx, s.Path)
	// Agent presets come from both layers: the repository's and this box's.
	local := RepoConfig{}
	if s.Config != nil {
		local = *s.Config
	}
	loc.Agents = merge(repo, local).Agents
	loc.Worktrees = parseWorktrees(out, s.Path)
	return loc
}

// parseWorktrees reads `git worktree list --porcelain`. Each worktree is named
// by its directory, with the repository's own "<repo>-" prefix removed, so
// ~/work/shop-checkout is "checkout" in location "shop".
func parseWorktrees(out []byte, repo string) []Worktree {
	var all []Worktree
	var cur *Worktree
	prefix := filepath.Base(repo) + "-"
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := scanner.Text()
		key, value, _ := strings.Cut(line, " ")
		switch key {
		case "worktree":
			all = append(all, Worktree{Path: value})
			cur = &all[len(all)-1]
			cur.Main = len(all) == 1
			if cur.Main {
				cur.Name = filepath.Base(value)
			} else {
				cur.Name = strings.TrimPrefix(filepath.Base(value), prefix)
			}
		case "HEAD":
			if cur != nil && len(value) >= 10 {
				cur.Head = value[:10]
			}
		case "branch":
			if cur != nil {
				cur.Branch = strings.TrimPrefix(value, "refs/heads/")
			}
		case "locked":
			if cur != nil {
				cur.Locked, cur.LockReason = true, unquoteGit(value)
			}
		}
	}
	// Worktrees git has lost track of (prunable, e.g. under a cleared /tmp)
	// are not places anyone can work.
	live := all[:0]
	for _, w := range all {
		if _, err := os.Stat(w.Path); err == nil {
			live = append(live, w)
		}
	}
	return live
}

// unquoteGit reads a value git may have C-quoted (one with a line break or
// a quote in it).
func unquoteGit(v string) string {
	if strings.HasPrefix(v, `"`) {
		if u, err := strconv.Unquote(v); err == nil {
			return u
		}
	}
	return v
}

func git(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	// A fetch's ssh keeps the output open after git itself is killed at
	// the deadline: give up on it rather than wait for it.
	cmd.WaitDelay = 5 * time.Second
	return cmd.CombinedOutput()
}

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~"))
		}
	}
	return path
}

func (l *Locations) read() ([]savedLocation, error) {
	b, err := os.ReadFile(l.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var all []savedLocation
	if err := json.Unmarshal(b, &all); err != nil {
		return nil, fmt.Errorf("%s is unreadable (a backup may be at %s.bak): %w", l.path, l.path, err)
	}
	return all, nil
}

func (l *Locations) update(change func([]savedLocation) ([]savedLocation, error)) error {
	unlock, err := statefile.Lock(l.path)
	if err != nil {
		return err
	}
	defer unlock()
	all, err := l.read()
	if err != nil {
		return err
	}
	all, err = change(all)
	if err != nil {
		return err
	}
	sort.Slice(all, func(i, j int) bool { return all[i].Name < all[j].Name })
	b, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	return statefile.WriteWithBackup(l.path, append(b, '\n'))
}
