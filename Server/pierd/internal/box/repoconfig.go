package box

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"pier/pierd/internal/hooks"
	"pier/pierd/internal/statefile"
)

// What a repository asks of every worktree: its own ports, environment,
// services and hooks. A repository can commit this in .pier/config.json,
// and a box can add to it or override it for that location alone, for what
// should not be committed (a database password, a box's own paths).

// WorktreeService is a long-running program each worktree runs, such as its dev
// server. It gets the worktree's environment, so it can listen on
// $PIER_PORT.
type WorktreeService struct {
	Name string `json:"name"`
	Run  string `json:"run"`
	// Autostart starts it when the worktree is created, after setup.
	Autostart bool `json:"autostart,omitempty"`
}

var serviceName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// validate reports what is wrong with config someone wrote.
func (c RepoConfig) validate() error {
	if c.Ports < 0 || c.Ports > maxPortsPerWorktree {
		return fmt.Errorf("ports must be between 0 and %d", maxPortsPerWorktree)
	}
	seen := map[string]bool{}
	for _, s := range c.Services {
		if !serviceName.MatchString(s.Name) {
			return fmt.Errorf("service name %q must be lowercase letters, digits and dashes", s.Name)
		}
		if seen[s.Name] {
			return fmt.Errorf("two services are called %s", s.Name)
		}
		seen[s.Name] = true
		if strings.TrimSpace(s.Run) == "" {
			return fmt.Errorf("service %s has nothing to run", s.Name)
		}
	}
	for k := range c.Env {
		if !envName.MatchString(k) {
			return fmt.Errorf("%q is not an environment variable name", k)
		}
	}
	if c.Preview != nil {
		if err := c.Preview.validate(); err != nil {
			return err
		}
	}
	if err := c.Base.validate(); err != nil {
		return err
	}
	switch c.PrepareWith {
	case "", "agent", "script":
	default:
		return fmt.Errorf("prepare_with is agent or script")
	}
	if c.By != "" && c.By != "setup" {
		return fmt.Errorf("by is setup, or left out")
	}
	return hooks.Validate(c.Hooks)
}

var envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// merge lays local over repo: scalars and env entries replace, services and
// agents replace by name, and hooks add up.
func merge(repo, local RepoConfig) RepoConfig {
	out := repo
	if local.Setup != "" {
		out.Setup = local.Setup
	}
	if local.Archive != "" {
		out.Archive = local.Archive
	}
	if local.Ports != 0 {
		out.Ports = local.Ports
	}
	if len(local.Env) > 0 {
		out.Env = map[string]string{}
		for k, v := range repo.Env {
			out.Env[k] = v
		}
		for k, v := range local.Env {
			out.Env[k] = v
		}
	}
	out.Services = mergeBy(repo.Services, local.Services, func(s WorktreeService) string { return s.Name })
	out.Agents = mergeBy(repo.Agents, local.Agents, func(a AgentPreset) string { return a.ID })
	out.Hooks = append(append([]hooks.Hook{}, repo.Hooks...), local.Hooks...)
	if local.Preview != nil {
		out.Preview = local.Preview
	}
	out.Base = mergeBase(repo.Base, local.Base)
	// Whether previews go public, whether setup agents may prepare it, who
	// wrote the recipe and whether pierd guessed it are the box's to say,
	// never a repository's.
	out.AutoShare, out.Detected = local.AutoShare, local.Detected
	out.PrepareWith, out.By = local.PrepareWith, local.By
	return out
}

// layOver is what `PUT …/config {"merge": …}` saves: over lays on base the
// way merge lays the box's config on a repository's, except that a hook
// already there is not added twice, so a recipe saved again stays the same.
func layOver(base, over RepoConfig) RepoConfig {
	out := merge(base, over)
	out.Hooks = append([]hooks.Hook{}, base.Hooks...)
	for _, h := range over.Hooks {
		dup := false
		for _, have := range out.Hooks {
			dup = dup || have.On == h.On && have.Run == h.Run
		}
		if !dup {
			out.Hooks = append(out.Hooks, h)
		}
	}
	if over.AutoShare == nil {
		out.AutoShare = base.AutoShare
	}
	// The person's consent to setup agents is SetPrepareWith's alone: a
	// recipe saved over the config (a setup agent's) never gives it, nor
	// servers of their own to the worktrees (PUT …/base does).
	out.PrepareWith = base.PrepareWith
	if out.Base != nil {
		out.Base.DB, out.Base.Redis = nil, false
		if base.Base != nil {
			out.Base.DB, out.Base.Redis = base.Base.DB, base.Base.Redis
		}
	}
	// The recipe is whoever wrote it last: no longer only pierd's guess,
	// and a setup agent's only while a setup agent wrote it.
	if over.recipe() {
		out.Detected = false
	} else {
		out.Detected, out.By = base.Detected, base.By
	}
	return out
}

// recipe says c holds what prepares a worktree: a setup script, services,
// variables or a preview.
func (c RepoConfig) recipe() bool {
	return c.Setup != "" || len(c.Services) > 0 || len(c.Env) > 0 || c.Preview != nil
}

func mergeBy[T any](base, over []T, key func(T) string) []T {
	out := append([]T{}, base...)
	for _, o := range over {
		replaced := false
		for i := range out {
			if key(out[i]) == key(o) {
				out[i], replaced = o, true
			}
		}
		if !replaced {
			out = append(out, o)
		}
	}
	return out
}

// Config is a location's config as the app shows and edits it.
type Config struct {
	// Repo is the repository's config file as this box applies it,
	// read-only here. Until the file is trusted that is its ports alone;
	// RepoTrust.Wants holds the rest.
	Repo     *RepoConfig `json:"repo"`
	RepoPath string      `json:"repo_path"`
	// RepoTrust says whether this box runs the repository's config.
	RepoTrust RepoTrust `json:"repo_trust"`
	// Team is the team's config for the project on this machine (team.go),
	// laid between the repository's and the box's own.
	Team *RepoConfig `json:"team,omitempty"`
	// Local is this box's own config for the location.
	Local     RepoConfig `json:"local"`
	Effective RepoConfig `json:"effective"`
}

// Config reads a location's config. A broken repository file is reported
// rather than silently ignored, since it would change what worktrees get.
func (l *Locations) Config(ctx context.Context, name string) (Config, error) {
	saved, err := l.saved(name)
	if err != nil {
		return Config{}, err
	}
	out := Config{RepoPath: repoConfigPath(saved.Path)}
	repo, trust, err := repoLayer(saved)
	if err != nil {
		return Config{}, err
	}
	out.RepoTrust = trust
	if trust.State != RepoTrustNone {
		out.Repo = &repo
	}
	if saved.Config != nil {
		out.Local = *saved.Config
	}
	// Scripts set the older way count as local config.
	if saved.Setup != "" {
		out.Local.Setup = saved.Setup
	}
	if saved.Archive != "" {
		out.Local.Archive = saved.Archive
	}
	team := RepoConfig{}
	if saved.Team != nil {
		out.Team = saved.Team
		team = *saved.Team
	}
	out.Effective = merge(merge(repo, team), out.Local)
	if saved.Environment != nil && saved.Environment.Compose {
		out.Effective.Services = mergeBy(out.Effective.Services, []WorktreeService{composeService}, func(s WorktreeService) string { return s.Name })
	}
	return out, nil
}

func (l *Locations) saved(name string) (savedLocation, error) {
	all, err := l.read()
	if err != nil {
		return savedLocation{}, err
	}
	for _, s := range all {
		if s.Name == name {
			return s, nil
		}
	}
	return savedLocation{}, ErrUnknownLocation
}

// SetLocalConfig replaces this box's own config for a location, all but the
// person's consent to setup agents, which only SetPrepareWith changes.
func (l *Locations) SetLocalConfig(name string, c RepoConfig) error {
	if err := c.validate(); err != nil {
		return err
	}
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name == name {
				cc := c
				cc.PrepareWith = ""
				if all[i].Config != nil {
					cc.PrepareWith = all[i].Config.PrepareWith
				}
				all[i].Config = &cc
				// The config now holds the scripts.
				all[i].Setup, all[i].Archive = "", ""
				return all, nil
			}
		}
		return nil, ErrUnknownLocation
	})
}

// SetPrepareWith records the person's consent to setup agents for a
// location ("agent"), or takes it back (""), leaving the rest of the box's
// config for it as it is.
func (l *Locations) SetPrepareWith(name, with string) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name != name {
				continue
			}
			c := RepoConfig{}
			if all[i].Config != nil {
				c = *all[i].Config
			}
			c.PrepareWith = with
			all[i].Config = &c
			return all, nil
		}
		return nil, ErrUnknownLocation
	})
}

// MergeLocalConfig lays over on this box's own config for a location
// (layOver), in one step, so two writers never lose each other's keys: a
// setup agent saves its recipe this way.
func (l *Locations) MergeLocalConfig(name string, over RepoConfig) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name != name {
				continue
			}
			cur := RepoConfig{Setup: all[i].Setup, Archive: all[i].Archive}
			if all[i].Config != nil {
				cur = merge(cur, *all[i].Config)
			}
			next := layOver(cur, over)
			if err := next.validate(); err != nil {
				return nil, badRequest("%v", err)
			}
			all[i].Config = &next
			all[i].Setup, all[i].Archive = "", ""
			return all, nil
		}
		return nil, ErrUnknownLocation
	})
}

// Ports: each worktree gets a stable block of ports of its own, so two
// worktrees of one app never fight over 3000.

const (
	portBase            = 41000
	portLimit           = 48999
	portBlock           = 10
	maxPortsPerWorktree = portBlock
)

// PortAlloc remembers which block each worktree has, by path.
type PortAlloc struct {
	Path string
	// First and Last bound the blocks given out (0: 41000 to 48999). Each
	// user of a shared box runs a pierd with a range of its own, so two of
	// them never hand out the same block.
	First, Last int
	mu          sync.Mutex
}

func (p *PortAlloc) bounds() (int, int) {
	first, last := portBase, portLimit
	if p.First > 0 && p.Last >= p.First+portBlock-1 {
		first, last = p.First, p.Last
	}
	return first, last
}

// ParsePortRange reads "FIRST-LAST" (inclusive), room for at least one block
// of ports.
func ParsePortRange(s string) (int, int, error) {
	a, b, ok := strings.Cut(strings.TrimSpace(s), "-")
	first, err1 := strconv.Atoi(strings.TrimSpace(a))
	last, err2 := strconv.Atoi(strings.TrimSpace(b))
	if !ok || err1 != nil || err2 != nil || first < 1024 || last > 65535 || last < first+portBlock-1 {
		return 0, 0, fmt.Errorf("port range %q: want FIRST-LAST between 1024 and 65535, at least %d ports", s, portBlock)
	}
	return first, last, nil
}

func (p *PortAlloc) load() map[string]int {
	m := map[string]int{}
	if b, err := os.ReadFile(p.Path); err == nil {
		json.Unmarshal(b, &m)
	}
	return m
}

// For returns dir's first port, giving it a free block if it has none.
// Blocks of worktrees whose folder is gone are reused.
func (p *PortAlloc) For(dir string) (int, error) {
	if p == nil {
		return 0, nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	m := p.load()
	if port, ok := m[dir]; ok {
		return port, nil
	}
	used := map[int]bool{}
	for path, port := range m {
		if _, err := os.Stat(path); err != nil {
			delete(m, path)
			continue
		}
		used[port] = true
	}
	first, last := p.bounds()
	for port := first; port+portBlock-1 <= last; port += portBlock {
		if !used[port] && !blockInUse(port) {
			m[dir] = port
			b, _ := json.MarshalIndent(m, "", "  ")
			return port, statefile.Write(p.Path, b)
		}
	}
	return 0, fmt.Errorf("every port block from %d to %d is taken", first, last)
}

// blockInUse says whether something already listens on a port of the
// block starting at first: a block this box's ports.json has never given
// out may still be taken, by another program or by another server keeping
// its own ports.json.
func blockInUse(first int) bool {
	for port := first; port < first+portBlock; port++ {
		if portInUse(port) {
			return true
		}
	}
	return false
}

// portInUse says whether port cannot be listened on, on any address; tests
// replace it.
var portInUse = func(port int) bool {
	ln, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		return true
	}
	ln.Close()
	return false
}

// Release frees dir's block.
func (p *PortAlloc) Release(dir string) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	m := p.load()
	if _, ok := m[dir]; ok {
		delete(m, dir)
		b, _ := json.MarshalIndent(m, "", "  ")
		statefile.Write(p.Path, b)
	}
}

var nonIdent = regexp.MustCompile(`[^a-z0-9]+`)

// worktreeSlug names a worktree safely in database, user and container
// names: shop_fix_checkout. MySQL takes user names of at most 32 characters
// (databases 64), so a longer slug keeps its start and ends in a hash of the
// whole name, which keeps two long names that share a start apart.
func worktreeSlug(location, worktree string) string {
	s := wholeSlug(location, worktree)
	if len(s) <= slugMax {
		return s
	}
	sum := sha256.Sum256([]byte(location + "/" + worktree))
	return strings.TrimRight(s[:25], "_") + "_" + hex.EncodeToString(sum[:3])
}

const slugMax = 32

// wholeSlug is the slug before it was cut: the whole name.
func wholeSlug(location, worktree string) string {
	return strings.Trim(nonIdent.ReplaceAllString(strings.ToLower(location+"_"+worktree), "_"), "_")
}

// slug is wt's $PIER_WORKTREE_SLUG: the longer one it had if it was made
// before slugs were cut.
func (l *Locations) slug(location string, wt Worktree) string {
	if s, err := l.saved(location); err == nil && s.Slugs[wt.Path] != "" {
		return s.Slugs[wt.Path]
	}
	return worktreeSlug(location, wt.Name)
}

// KeepLongSlugs records, once per location, the worktrees already there
// whose whole slug is longer than a cut one: they keep it, since their
// recipes named a database or a cookie after it. pierd runs it as it starts,
// before it makes any worktree.
func (l *Locations) KeepLongSlugs(ctx context.Context) error {
	saved, err := l.read()
	if err != nil {
		return err
	}
	found := map[string]map[string]string{}
	for _, s := range saved {
		if s.SlugsCut {
			continue
		}
		if _, err := os.Stat(s.Path); err != nil {
			// Unreachable now (an unmounted disk): looked for next time.
			continue
		}
		kept := map[string]string{}
		for _, w := range describe(ctx, s).Worktrees {
			if whole := wholeSlug(s.Name, w.Name); len(whole) > slugMax {
				kept[w.Path] = whole
			}
		}
		found[s.Name] = kept
	}
	if len(found) == 0 {
		return nil
	}
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			kept, ok := found[all[i].Name]
			if !ok || all[i].SlugsCut {
				continue
			}
			if len(kept) > 0 {
				all[i].Slugs = kept
			}
			all[i].SlugsCut = true
		}
		return all, nil
	})
}

// forgetSlug drops a removed worktree's kept slug: a new worktree on its
// path gets a cut one.
func (l *Locations) forgetSlug(location, path string) {
	if s, err := l.saved(location); err != nil || s.Slugs[path] == "" {
		return
	}
	l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name == location {
				delete(all[i].Slugs, path)
				if len(all[i].Slugs) == 0 {
					all[i].Slugs = nil
				}
			}
		}
		return all, nil
	})
}

// WorktreeEnv is what everything run in a worktree gets: pierd's variables
// for it (PIER_*), then the box's and the
// location's env with those variables expanded.
func (b *Box) WorktreeEnv(ctx context.Context, location string, wt Worktree) ([]string, error) {
	loc, err := b.Locations.Get(ctx, location)
	if err != nil {
		return nil, err
	}
	cfg, err := b.Locations.Config(ctx, location)
	if err != nil {
		return nil, err
	}
	vars := map[string]string{
		"PIER_BOX":           b.Name,
		"PIER_LOCATION":      loc.Name,
		"PIER_ROOT_PATH":     loc.Path,
		"PIER_WORKTREE_PATH": wt.Path,
		"PIER_WORKTREE_NAME": wt.Name,
		// Safe in database, user and container names: shop_fix_checkout.
		"PIER_WORKTREE_SLUG": b.Locations.slug(loc.Name, wt),
		"PIER_BRANCH":        wt.Branch,
	}
	// A checkout with servers of its own (database.go) has them on the last
	// two ports of its block: those are not the app's to use.
	srvVars, srvOver := b.instanceEnv(wt.Path)
	if port, err := b.Locations.Ports.For(wt.Path); err != nil {
		return nil, err
	} else if port > 0 {
		vars["PIER_PORT"] = strconv.Itoa(port)
		ports := max(cfg.Effective.Ports, 1)
		if len(srvVars) > 0 {
			ports = min(ports, maxPortsWithServers)
		}
		for i := 1; i < ports; i++ {
			vars["PIER_PORT_"+strconv.Itoa(i)] = strconv.Itoa(port + i)
		}
	}
	for k, v := range srvVars {
		vars[k] = v
	}
	// The box's own environment comes first; the project's overrides it.
	boxEnv, err := loadBoxEnv(b.EnvFile)
	if err != nil {
		return nil, err
	}
	merged := map[string]string{}
	for k, v := range boxEnv.Env {
		merged[k] = v
	}
	if env, err := b.Locations.Environment(location); err == nil && env.Compose {
		vars["PIER_COMPOSE_PROJECT"] = composeProject(location, wt)
	}
	// The project's isolated environment: its launchers first on PATH, its
	// containers' addresses, unless the project's own env says otherwise.
	for k, v := range b.envVariables(ctx, location) {
		switch k {
		case "PATH", "PIER_ENV_BIN":
			vars[k] = v
		default:
			merged[k] = v
		}
	}
	for k, v := range cfg.Effective.Env {
		merged[k] = v
	}
	// The checkout's own servers win over what the box and the project say
	// about where the database is: the app reaches its own.
	for k, v := range srvOver {
		merged[k] = v
	}
	// Many dev servers read PORT (Express, Next.js): give it the worktree's
	// own in every terminal, agent and service, unless the box or the
	// project sets it, so two worktrees' `npm start` never collide.
	// The account the project's agents use, chosen in the app: over any
	// CLAUDE_CONFIG_DIR / CODEX_HOME in the box's or the project's env.
	for k, v := range b.accountVars(location) {
		merged[k] = v
	}
	if _, ok := merged["PORT"]; !ok && vars["PIER_PORT"] != "" {
		vars["PORT"] = vars["PIER_PORT"]
	}
	env := make([]string, 0, len(vars)+len(merged))
	for k, v := range vars {
		env = append(env, k+"="+v)
	}
	sort.Strings(env)
	keys := make([]string, 0, len(merged))
	for k := range merged {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		env = append(env, k+"="+expandPier(merged[k], vars))
	}
	return env, nil
}

// envForDir is the worktree environment for dir, or nothing when dir is not
// in a location.
func (b *Box) envForDir(ctx context.Context, dir string) []string {
	loc, wt, ok := b.worktreeAt(ctx, dir)
	if !ok {
		return nil
	}
	env, err := b.WorktreeEnv(ctx, loc.Name, wt)
	if err != nil {
		return nil
	}
	return env
}

// worktreeAt finds the location and worktree containing dir.
func (b *Box) worktreeAt(ctx context.Context, dir string) (Location, Worktree, bool) {
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return Location{}, Worktree{}, false
	}
	var best Worktree
	var bestLoc Location
	for _, l := range locs {
		for _, w := range l.Worktrees {
			if (dir == w.Path || strings.HasPrefix(dir, w.Path+string(filepath.Separator))) && len(w.Path) > len(best.Path) {
				best, bestLoc = w, l
			}
		}
	}
	return bestLoc, best, best.Path != ""
}

func (b *Box) getConfig(w http.ResponseWriter, r *http.Request) error {
	c, err := b.Locations.Config(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	writeJSON(w, c)
	return nil
}

// putConfig replaces the box's own config for a location ({"local": …}), or
// lays keys over it ({"merge": …}: what `pierd location config --merge`
// sends, and how a setup agent saves its recipe).
func (b *Box) putConfig(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Local RepoConfig  `json:"local"`
		Merge *RepoConfig `json:"merge"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	name := r.PathValue("name")
	if err := b.before(r, "config.change", map[string]any{"location": name}); err != nil {
		return err
	}
	var err error
	if req.Merge != nil {
		err = b.Locations.MergeLocalConfig(name, *req.Merge)
	} else {
		err = b.Locations.SetLocalConfig(name, req.Local)
	}
	if err != nil {
		var he httpError
		if err == ErrUnknownLocation || errors.As(err, &he) {
			return err
		}
		return badRequest("%v", err)
	}
	b.publish(r, "config.changed", map[string]any{"location": name})
	return b.getConfig(w, r)
}

var varRef = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

// expandPier puts pierd's own variables ($PIER_PORT, ${PIER_WORKTREE_SLUG},
// $PORT…) into a value and leaves every other "$" as it is: a password or a
// hash with a "$" in it arrives intact.
func expandPier(v string, vars map[string]string) string {
	return varRef.ReplaceAllStringFunc(v, func(m string) string {
		name := strings.Trim(m, "${}")
		if val, ok := vars[name]; ok {
			return val
		}
		return m
	})
}
