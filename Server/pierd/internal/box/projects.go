package box

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/groups"
	"pier/pierd/internal/trust"
)

// Projects come and go from the app: a repository is cloned onto the box
// (from the GitHub account's list or a pasted link) and made ready to work
// in, its setup run and its dev server started, and a project nobody works
// on is removed from the disk, leaving it on GitHub to be cloned again.

// Clone is one repository being brought onto the box (GET /v1/clones).
type Clone struct {
	ID       string `json:"id"`
	Repo     string `json:"repo"`
	Slug     string `json:"slug,omitempty"`
	Location string `json:"location"`
	Path     string `json:"path"`
	// State is "cloning", "setting_up", "ready" or "failed".
	State string `json:"state"`
	// Setup says what made the project ready: "repo" (its own
	// .pier/config.json), "detected" (what pierd recognised), or "none".
	Setup    string     `json:"setup,omitempty"`
	Services []string   `json:"services,omitempty"`
	Error    string     `json:"error,omitempty"`
	Log      string     `json:"log,omitempty"`
	Started  time.Time  `json:"started"`
	Finished *time.Time `json:"finished,omitempty"`
}

const (
	CloneCloning   = "cloning"
	CloneSettingUp = "setting_up"
	CloneReady     = "ready"
	CloneFailed    = "failed"
)

// clones are the clones of the last hour, in memory: a restart forgets
// them, and the locations they made stay.
type clones struct {
	mu  sync.Mutex
	all []*Clone
}

func (c *clones) add(cl *Clone) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.all = append(c.all, cl)
}

func (c *clones) set(id string, change func(*Clone)) Clone {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, cl := range c.all {
		if cl.ID == id {
			change(cl)
			return *cl
		}
	}
	return Clone{}
}

func (c *clones) list() []Clone {
	c.mu.Lock()
	defer c.mu.Unlock()
	keep := c.all[:0]
	out := []Clone{}
	for _, cl := range c.all {
		if cl.Finished != nil && time.Since(*cl.Finished) > time.Hour {
			continue
		}
		keep = append(keep, cl)
		out = append(out, *cl)
	}
	c.all = keep
	sort.Slice(out, func(i, j int) bool { return out[i].Started.After(out[j].Started) })
	return out
}

func (c *clones) forget(id string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i, cl := range c.all {
		if cl.ID == id && cl.State != CloneCloning && cl.State != CloneSettingUp {
			c.all = append(c.all[:i], c.all[i+1:]...)
			return true
		}
	}
	return false
}

// inFlight reports whether a running clone already uses name or path.
func (c *clones) inFlight(name, path string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.inFlightLocked(name, path)
}

func (c *clones) inFlightLocked(name, path string) bool {
	for _, cl := range c.all {
		if (cl.State == CloneCloning || cl.State == CloneSettingUp) && (name != "" && strings.EqualFold(cl.Location, name) || path != "" && cl.Path == path) {
			return true
		}
	}
	return false
}

// reserve adds cl unless a running clone already uses its name or folder:
// the check and the claim are one step, so two requests never both win.
func (c *clones) reserve(cl *Clone) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inFlightLocked(cl.Location, cl.Path) {
		return false
	}
	c.all = append(c.all, cl)
	return true
}

// drop forgets a clone that never started.
func (c *clones) drop(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i, cl := range c.all {
		if cl.ID == id {
			c.all = append(c.all[:i], c.all[i+1:]...)
			return
		}
	}
}

// CloneRequest is the body of POST /v1/clones.
type CloneRequest struct {
	// Repo is owner/repo, a GitHub page of it, or a clone URL.
	Repo string `json:"repo"`
	// Name is the location's name; the repository's by default.
	Name string `json:"name,omitempty"`
	// Dir is the folder to clone into; by default the projects folder (in
	// Space, when given), else the one the box's other projects share, else
	// ~/code.
	Dir string `json:"dir,omitempty"`
	// Space is the space of the projects folder to clone into, made if new.
	Space string `json:"space,omitempty"`
	// Setup makes the project ready: the repository's own config is
	// trusted, or one is worked out (detectSetup); then setup runs on the
	// main checkout and its services start.
	Setup bool `json:"setup"`
}

var invalidNameChars = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// locationName makes a valid, unused location name from a repository's.
func locationName(want string, taken map[string]bool) string {
	n := strings.Trim(invalidNameChars.ReplaceAllString(want, "-"), "-._")
	if len(n) > 60 {
		n = n[:60]
	}
	if n == "" {
		n = "project"
	}
	out := n
	for i := 2; taken[strings.ToLower(out)]; i++ {
		out = n + "-" + strconv.Itoa(i)
	}
	return out
}

// projectsParent is where a new clone goes: the folder most of the box's
// repositories are in, else the first usual one that exists, else ~/code.
func projectsParent(locs []Location) string {
	count := map[string]int{}
	best := ""
	for _, l := range locs {
		if !l.Repo {
			continue
		}
		p := filepath.Dir(l.Path)
		count[p]++
		if count[p] > count[best] || count[p] == count[best] && p < best {
			best = p
		}
	}
	if best != "" {
		return best
	}
	home, _ := os.UserHomeDir()
	for _, f := range []string{"code", "Code", "Projects", "projects", "src", "dev", "Developer", "workspace", "repos"} {
		if fi, err := os.Stat(filepath.Join(home, f)); err == nil && fi.IsDir() {
			return filepath.Join(home, f)
		}
	}
	return filepath.Join(home, "code")
}

func (b *Box) listClones(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.clones.list())
	return nil
}

func (b *Box) forgetClone(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if !b.clones.forget(id) {
		return httpError{http.StatusNotFound, "no finished clone with that id"}
	}
	writeJSON(w, map[string]string{"forgotten": id})
	return nil
}

func (b *Box) addClone(w http.ResponseWriter, r *http.Request) error {
	var req CloneRequest
	if err := decode(r, &req); err != nil {
		return err
	}
	src, err := parseRepoSource(req.Repo)
	if err != nil {
		return err
	}
	ctx := r.Context()
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return err
	}
	taken := map[string]bool{}
	for _, l := range locs {
		taken[strings.ToLower(l.Name)] = true
		if src.Slug != "" && strings.EqualFold(l.Slug, src.Slug) || l.Remote != "" && l.Remote == src.URL {
			return httpError{http.StatusConflict, fmt.Sprintf("%s is already on this box as %s", req.Repo, l.Name)}
		}
	}
	name := req.Name
	if name == "" {
		name = src.Name
	} else if !trust.ValidName(name) {
		return badRequest("invalid location name %q", name)
	}
	b.clones.mu.Lock()
	for _, cl := range b.clones.all {
		if cl.State == CloneCloning || cl.State == CloneSettingUp {
			taken[strings.ToLower(cl.Location)] = true
		}
	}
	b.clones.mu.Unlock()
	name = locationName(name, taken)
	parent := req.Dir
	root := b.Locations.Settings().ProjectsRoot
	switch {
	case req.Space != "":
		// A space named for the first time is made, with its marker.
		if parent, err = b.Locations.spaceDir(req.Space, true); err != nil {
			return err
		}
	case parent == "" && root != "":
		parent = root
	case parent == "":
		parent = projectsParent(locs)
	}
	parent, err = filepath.Abs(expandHome(parent))
	if err != nil {
		return err
	}
	if err := b.Locations.checkInRoot(parent); err != nil {
		return err
	}
	// The folder: the repository's name, or name-2… when that is taken
	// by something else. A folder that already holds this very repository
	// (cloned by hand, or left by an earlier forget) is used as it is.
	dirName := locationName(src.Name, nil)
	path, adopt := "", false
	for i := 1; ; i++ {
		p := filepath.Join(parent, dirName)
		if i > 1 {
			p += "-" + strconv.Itoa(i)
		}
		if _, err := os.Stat(p); os.IsNotExist(err) && !b.clones.inFlight("", p) {
			path = p
			break
		}
		if sameRepo(ctx, p, src) {
			path, adopt = p, true
			break
		}
	}
	cl := &Clone{ID: newCloneID(), Repo: src.Display(), Slug: src.Slug, Location: name, Path: path, State: CloneCloning, Started: time.Now()}
	if adopt {
		cl.State = CloneSettingUp
	}
	if !b.clones.reserve(cl) {
		return httpError{http.StatusConflict, fmt.Sprintf("%s is being cloned already", name)}
	}
	if err := b.before(r, "location.clone", map[string]any{"location": name, "path": path, "repo": src.Display(), "setup": req.Setup}); err != nil {
		b.clones.drop(cl.ID)
		return err
	}
	b.publish(r, "clone.started", map[string]any{"id": cl.ID, "location": name, "path": path, "repo": cl.Repo})
	go b.runClone(origin(r), *cl, src, req.Setup, adopt)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, cl)
	return nil
}

func newCloneID() string {
	var b [6]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// sameRepo reports whether dir is a checkout of src.
func sameRepo(ctx context.Context, dir string, src repoSource) bool {
	remote := remoteURL(ctx, dir)
	if remote == "" {
		return false
	}
	if src.Slug != "" {
		return strings.EqualFold(slugOf(remote), src.Slug)
	}
	return remote == src.URL
}

// runClone clones, adds the location, and makes it ready, saying how it
// went through the clone's record and events.
func (b *Box) runClone(from string, cl Clone, src repoSource, setup, adopt bool) {
	ctx := context.Background()
	logDir := b.LogDir
	if logDir == "" {
		logDir = filepath.Join(os.TempDir(), "pier-logs")
	}
	logPath := filepath.Join(logDir, "clone-"+cl.Location+".log")
	fail := func(err error) {
		now := time.Now()
		done := b.clones.set(cl.ID, func(c *Clone) { c.State, c.Error, c.Finished, c.Log = CloneFailed, err.Error(), &now, logPath })
		b.Events.Publish(events.Event{Type: "clone.failed", Box: b.Name, Origin: from, Error: err.Error(),
			Data: map[string]any{"id": done.ID, "location": done.Location, "path": done.Path, "repo": done.Repo}})
	}
	if !adopt {
		if err := os.MkdirAll(filepath.Dir(cl.Path), 0o755); err != nil {
			fail(err)
			return
		}
		b.own(cl.Path)
		// Into a folder of this clone's own, renamed into place when done: a
		// failure removes only what this clone made.
		tmp := filepath.Join(filepath.Dir(cl.Path), "."+filepath.Base(cl.Path)+".pier-clone-"+cl.ID)
		if err := cloneRepo(ctx, src, tmp, logPath); err != nil {
			os.RemoveAll(tmp)
			fail(err)
			return
		}
		if err := os.Rename(tmp, cl.Path); err != nil {
			os.RemoveAll(tmp)
			fail(fmt.Errorf("%s appeared while cloning: %w", cl.Path, err))
			return
		}
	}
	loc, err := b.Locations.Add(ctx, cl.Location, cl.Path)
	if err != nil {
		fail(err)
		return
	}
	b.Events.Publish(events.Event{Type: "location.added", Box: b.Name, Origin: from, Data: map[string]any{"location": loc.Name, "path": loc.Path}})
	how := "none"
	var services []string
	if setup {
		b.clones.set(cl.ID, func(c *Clone) { c.State = CloneSettingUp })
		how, err = b.prepareLocation(ctx, loc.Name)
		if err != nil {
			fail(err)
			return
		}
		if loc, err = b.Locations.Get(ctx, loc.Name); err != nil {
			fail(err)
			return
		}
		cfg, _ := b.Locations.Config(ctx, loc.Name)
		for _, s := range cfg.Effective.Services {
			services = append(services, s.Name)
		}
		var main Worktree
		for _, wt := range loc.Worktrees {
			if wt.Main {
				main = wt
			}
		}
		if main.Path != "" && b.prep.start(prepKey(loc.Name, main.Name)) {
			if err := b.prepareWorktree(from, loc, main); err != nil {
				fail(err)
				return
			}
		}
	}
	now := time.Now()
	done := b.clones.set(cl.ID, func(c *Clone) { c.State, c.Setup, c.Services, c.Finished = CloneReady, how, services, &now })
	b.Events.Publish(events.Event{Type: "clone.finished", Box: b.Name, Origin: from,
		Data: map[string]any{"id": done.ID, "location": done.Location, "path": done.Path, "repo": done.Repo, "setup": how}})
}

// cloneRepo clones src into dest: with gh when it is a GitHub repository and
// gh is signed in (its credentials reach private repositories), else git.
func cloneRepo(ctx context.Context, src repoSource, dest, logPath string) error {
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		return err
	}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer log.Close()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	gitClone := "git clone -- " + shellQuote(src.URL) + " " + shellQuote(dest)
	script := gitClone
	if src.Slug != "" {
		script = "if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then gh repo clone " +
			shellQuote(src.Slug) + " " + shellQuote(dest) + "; else " + gitClone + "; fi"
	}
	shArgs, shVar := shInLogin(script)
	cmd := groups.CommandContext(ctx, loginShell(), shArgs...)
	cmd.Env = append(os.Environ(), shVar, "GIT_TERMINAL_PROMPT=0", "GH_PROMPT_DISABLED=1", "GIT_SSH_COMMAND=ssh -o BatchMode=yes")
	cmd.Stdout, cmd.Stderr = log, log
	cmd.WaitDelay = 5 * time.Second
	if err := cmd.Run(); err != nil {
		if tail := logTail(logPath, 20, 2048); tail != "" {
			return fmt.Errorf("clone failed: %s", tail)
		}
		return fmt.Errorf("clone failed: %v", err)
	}
	return nil
}

// prepareLocation makes a freshly cloned location's setup run: the
// repository's own config is trusted as it is now, and a repository without
// one gets what detectSetup recognises as the box's config for it. It says
// which it was: "repo", "detected" or "none".
func (b *Box) prepareLocation(ctx context.Context, name string) (string, error) {
	cfg, err := b.Locations.Config(ctx, name)
	if err != nil {
		return "", err
	}
	if cfg.RepoTrust.Pending() {
		if err := b.Locations.TrustRepo(name, cfg.RepoTrust.Hash); err != nil {
			return "", err
		}
		return "repo", nil
	}
	if cfg.RepoTrust.State == RepoTrustTrusted && cfg.Repo != nil && (cfg.Repo.Setup != "" || len(cfg.Repo.Services) > 0) {
		return "repo", nil
	}
	saved, err := b.Locations.saved(name)
	if err != nil {
		return "", err
	}
	found := detectSetup(saved.Path)
	if found.Setup == "" && len(found.Services) == 0 {
		return "none", nil
	}
	local := cfg.Local
	if local.Setup == "" {
		local.Setup = found.Setup
	}
	local.Services = mergeBy(found.Services, local.Services, func(s WorktreeService) string { return s.Name })
	if err := b.Locations.SetLocalConfig(name, local); err != nil {
		return "", err
	}
	return "detected", nil
}

// Disk: what a project takes and what removing it would lose.

// DiskUse answers GET /v1/locations/{name}/disk.
type DiskUse struct {
	// Bytes is the size of the repository and its worktrees on disk.
	Bytes int64    `json:"bytes"`
	Paths []string `json:"paths"`
	// Uncommitted are worktrees with changes nobody committed.
	Uncommitted []UncommittedWorktree `json:"uncommitted"`
	// Unpushed are local branches with commits no remote has.
	Unpushed []UnpushedBranch `json:"unpushed"`
	Stashes  int              `json:"stashes"`
	Sessions int              `json:"sessions"`
	// Unreadable are worktrees git could not read: what they hold is not
	// known, so it counts as work that would be lost.
	Unreadable []string `json:"unreadable"`
	// Removable is false when the project cannot be removed from the disk
	// at all, with Reason saying why (forgetting it still works).
	Removable bool   `json:"removable"`
	Reason    string `json:"reason,omitempty"`
	Remote    string `json:"remote,omitempty"`
}

type UncommittedWorktree struct {
	Worktree string `json:"worktree"`
	Files    int    `json:"files"`
}

type UnpushedBranch struct {
	Branch  string `json:"branch"`
	Commits int    `json:"commits"`
}

// Unsaved reports whether removing the project loses work.
func (d DiskUse) Unsaved() bool {
	return len(d.Uncommitted) > 0 || len(d.Unpushed) > 0 || d.Stashes > 0 || len(d.Unreadable) > 0
}

// ErrUnsavedWork refuses to remove a project from the disk with work that
// exists nowhere else, unless asked to with force.
var ErrUnsavedWork = errors.New("the project has work that is not on any remote")

func (b *Box) diskUse(ctx context.Context, loc Location) DiskUse {
	d := DiskUse{Paths: []string{}, Uncommitted: []UncommittedWorktree{}, Unpushed: []UnpushedBranch{}, Unreadable: []string{}, Remote: loc.Remote}
	d.Removable, d.Reason = b.purgeable(ctx, loc)
	for _, wt := range loc.Worktrees {
		d.Paths = append(d.Paths, wt.Path)
		out, err := git(ctx, "-C", wt.Path, "status", "--porcelain=v1")
		if err != nil {
			d.Unreadable = append(d.Unreadable, wt.Name)
			continue
		}
		if s := strings.TrimRight(string(out), "\n"); strings.TrimSpace(s) != "" {
			d.Uncommitted = append(d.Uncommitted, UncommittedWorktree{Worktree: wt.Name, Files: strings.Count(s, "\n") + 1})
		}
		// A detached HEAD's commits are on no branch: counted here.
		if wt.Branch == "" {
			if n, err := git(ctx, "-C", wt.Path, "rev-list", "--count", "HEAD", "--not", "--remotes", "--branches"); err == nil {
				if c, _ := strconv.Atoi(strings.TrimSpace(string(n))); c > 0 {
					d.Unpushed = append(d.Unpushed, UnpushedBranch{Branch: wt.Name + " (HEAD)", Commits: c})
				}
			}
		}
	}
	if len(d.Paths) == 0 {
		d.Paths = append(d.Paths, loc.Path)
	}
	if loc.Repo {
		if out, err := git(ctx, "-C", loc.Path, "for-each-ref", "--format=%(refname:short)", "refs/heads"); err == nil {
			for _, br := range strings.Fields(string(out)) {
				n, err := git(ctx, "-C", loc.Path, "rev-list", "--count", "refs/heads/"+br, "--not", "--remotes")
				if err != nil {
					continue
				}
				if c, _ := strconv.Atoi(strings.TrimSpace(string(n))); c > 0 {
					d.Unpushed = append(d.Unpushed, UnpushedBranch{Branch: br, Commits: c})
				}
			}
		}
		if out, err := git(ctx, "-C", loc.Path, "stash", "list"); err == nil && strings.TrimSpace(string(out)) != "" {
			d.Stashes = strings.Count(strings.TrimRight(string(out), "\n"), "\n") + 1
		}
	}
	if all, err := b.Sessions.List(ctx); err == nil {
		for _, s := range all {
			for _, p := range d.Paths {
				if !s.Exited && (s.Dir == p || strings.HasPrefix(s.Dir, p+string(filepath.Separator))) {
					d.Sessions++
				}
			}
		}
	}
	sizeCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for _, p := range d.Paths {
		d.Bytes += dirSize(sizeCtx, p)
	}
	return d
}

// dirSize adds up the files under dir, without following links, as far as
// it gets before ctx ends.
func dirSize(ctx context.Context, dir string) int64 {
	var total int64
	filepath.WalkDir(dir, func(_ string, e fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if ctx.Err() != nil {
			return filepath.SkipAll
		}
		if e.Type().IsRegular() {
			if info, err := e.Info(); err == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

// purgeable says whether a location may be deleted from the disk: only a
// git repository, never the home folder or above it, and never one holding
// another location.
func (b *Box) purgeable(ctx context.Context, loc Location) (bool, string) {
	if !loc.Repo {
		return false, "only a git repository can be removed from the disk; this location can only be forgotten"
	}
	home, _ := os.UserHomeDir()
	clean := filepath.Clean(loc.Path)
	if clean == "/" || clean == filepath.Clean(home) || strings.HasPrefix(filepath.Clean(home)+"/", clean+"/") {
		return false, clean + " is the home folder or holds it"
	}
	if root := b.Locations.Settings().ProjectsRoot; root != "" {
		if !under(clean, root) {
			return false, clean + " is outside the box's projects folder (" + root + ")"
		}
		if space, _ := placeOf(clean, root); clean == filepath.Clean(root) || space != "" && clean == filepath.Join(root, space) {
			return false, clean + " is the projects folder or one of its spaces"
		}
	}
	// Only a repository's own top folder: a location that is a folder inside
	// a repository would take the whole repository's worktrees with it.
	if out, err := git(ctx, "-C", clean, "rev-parse", "--show-toplevel"); err != nil || !samePath(strings.TrimSpace(string(out)), clean) {
		return false, clean + " is not the top folder of its git repository; forget it instead"
	}
	paths := []string{clean}
	for _, wt := range loc.Worktrees {
		paths = append(paths, filepath.Clean(wt.Path))
	}
	if root := b.Locations.Settings().ProjectsRoot; root != "" {
		for _, p := range paths[1:] {
			if !under(p, root) {
				return false, "the worktree " + p + " is outside the box's projects folder (" + root + ")"
			}
		}
	}
	if locs, err := b.Locations.List(ctx); err == nil {
		for _, other := range locs {
			if other.Name == loc.Name {
				continue
			}
			o := filepath.Clean(other.Path)
			for _, p := range paths {
				if o == p || strings.HasPrefix(o, p+"/") {
					return false, fmt.Sprintf("the location %s is inside %s", other.Name, p)
				}
			}
		}
	}
	return true, ""
}

func (b *Box) locationDisk(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	writeJSON(w, b.diskUse(r.Context(), loc))
	return nil
}

// purgeLocation deletes a location's repository and worktrees from the disk
// and forgets it: DELETE /v1/locations/{name}?purge=1[&force=1].
func (b *Box) purgeLocation(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	name := r.PathValue("name")
	loc, err := b.Locations.Get(ctx, name)
	if err != nil {
		return err
	}
	d := b.diskUse(ctx, loc)
	if !d.Removable {
		return httpError{http.StatusConflict, d.Reason}
	}
	if d.Unsaved() && r.URL.Query().Get("force") != "1" {
		return fmt.Errorf("%w: %s", ErrUnsavedWork, unsavedSummary(d))
	}
	if err := b.before(r, "location.remove", map[string]any{"location": name, "path": loc.Path, "purge": true}); err != nil {
		return err
	}
	if err := b.purge(r, loc, d); err != nil {
		return err
	}
	writeJSON(w, map[string]any{"removed": name, "freed": d.Bytes})
	return nil
}

// purge takes a project off the box: its services, sessions, ports and
// environment, the location, then its folders.
func (b *Box) purge(r *http.Request, loc Location, d DiskUse) error {
	name := loc.Name
	from := origin(r)
	for _, wt := range loc.Worktrees {
		b.own(wt.Path)
		b.stopServices(loc.Name, wt.Name)
		b.stopSessionsIn(from, wt.Path)
		b.Locations.Ports.Release(wt.Path)
	}
	b.dropEnvironment(name, true)
	b.dropShares(name, "")
	// Forgotten first: a location whose folder is half gone is worse than
	// a folder nothing points at.
	if err := b.Locations.Remove(name); err != nil {
		return err
	}
	var failed []string
	for _, wt := range loc.Worktrees {
		if !wt.Main {
			if err := os.RemoveAll(wt.Path); err != nil {
				failed = append(failed, err.Error())
			}
		}
	}
	if err := os.RemoveAll(loc.Path); err != nil {
		failed = append(failed, err.Error())
	}
	data := map[string]any{"location": name, "path": loc.Path, "purged": true, "freed": d.Bytes}
	if len(failed) > 0 {
		data["error"] = strings.Join(failed, "; ")
	}
	b.publish(r, "location.removed", data)
	if len(failed) > 0 {
		return fmt.Errorf("%s was forgotten, but some files could not be deleted: %s", name, strings.Join(failed, "; "))
	}
	return nil
}

func unsavedSummary(d DiskUse) string {
	var parts []string
	for _, u := range d.Uncommitted {
		parts = append(parts, fmt.Sprintf("%s has %d uncommitted files", u.Worktree, u.Files))
	}
	for _, u := range d.Unpushed {
		parts = append(parts, fmt.Sprintf("%s has %d commits no remote has", u.Branch, u.Commits))
	}
	if d.Stashes > 0 {
		parts = append(parts, fmt.Sprintf("%d stashes", d.Stashes))
	}
	for _, w := range d.Unreadable {
		parts = append(parts, w+" could not be read by git")
	}
	return strings.Join(parts, "; ") + " (remove with force=1 to lose them)"
}
