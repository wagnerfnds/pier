package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"pier/pierd/internal/statefile"
	"pier/pierd/internal/trust"
)

// The box's projects folder: once set, every project lives under it, the
// way a root holds everything pierd does. Clones go there, a location
// outside it cannot be added, and nothing outside it is ever deleted.
// Folders right under it that are not repositories are spaces: groups of
// projects kept apart on the disk (root/<space>/<repo>), each with its
// worktrees beside its repository, inside the space.

// Settings are the box's own settings (GET/PUT /v1/settings).
type Settings struct {
	// ProjectsRoot is the folder every project lives under; empty: anywhere.
	ProjectsRoot string `json:"projects_root,omitempty"`
	// PrepareRules is what every setup agent on this box must keep to
	// (setupagent.go); empty: defaultPrepareRules.
	PrepareRules string `json:"prepare_rules,omitempty"`
	// AutoShare gives a worktree's preview a public link by itself
	// (preview.go); nil is on. A location's own config can say otherwise.
	AutoShare *bool `json:"auto_share,omitempty"`
}

// SettingsView is what GET /v1/settings answers. Its prepare_rules and
// auto_share are what applies: the default rules and on until someone
// changes them.
type SettingsView struct {
	Settings
	Home   string      `json:"home"`
	Spaces []Space     `json:"spaces"`
	Docker DockerState `json:"docker"`
	// PrepareRules and AutoShare hide Settings' own (shallower fields win
	// in encoding/json): the text in force and whether links are on.
	PrepareRules string `json:"prepare_rules"`
	// PrepareRulesDefault says the rules are the box's defaults, nobody's
	// own text.
	PrepareRulesDefault bool `json:"prepare_rules_default"`
	AutoShare           bool `json:"auto_share"`
}

// maxPrepareRules bounds the rules' text: it goes into every setup agent's
// first prompt.
const maxPrepareRules = 8 << 10

// prepareRules is the text every setup agent gets: the box's own, or the
// defaults.
func (s Settings) prepareRules() string {
	if t := strings.TrimSpace(s.PrepareRules); t != "" {
		return t
	}
	return defaultPrepareRules
}

// autoShare says whether previews get a public link by themselves.
func (s Settings) autoShare() bool { return s.AutoShare == nil || *s.AutoShare }

// updateSettings changes the box's settings with change and saves them.
func (l *Locations) updateSettings(change func(*Settings)) (Settings, error) {
	s := l.Settings()
	change(&s)
	b, _ := json.MarshalIndent(s, "", "  ")
	return s, statefile.Write(l.settingsPath(), append(b, '\n'))
}

// Space is a folder of projects under the projects folder.
type Space struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	Projects int    `json:"projects"`
}

var ErrSpaceNotEmpty = errors.New("the space still holds projects")

// ErrSpaceHasFiles refuses to delete a space holding files that are no
// project's (an unregistered repository, notes…) unless asked to with
// delete_files=1.
var ErrSpaceHasFiles = errors.New("the space holds files that are not projects")

// spaceMarker is in every folder made as a space: only those are spaces, so
// a folder that just happens to be there is never deleted as one.
const spaceMarker = ".pier-space"

func (l *Locations) settingsPath() string {
	return filepath.Join(filepath.Dir(l.path), "settings.json")
}

// Settings reads the box's settings; none saved yet reads as the defaults.
func (l *Locations) Settings() Settings {
	var s Settings
	if b, err := os.ReadFile(l.settingsPath()); err == nil {
		json.Unmarshal(b, &s)
	}
	return s
}

// SetProjectsRoot sets (or with "" clears) the projects folder, creating it.
func (l *Locations) SetProjectsRoot(root string) (Settings, error) {
	s := l.Settings()
	if strings.TrimSpace(root) == "" {
		s.ProjectsRoot = ""
	} else {
		abs, err := filepath.Abs(expandHome(strings.TrimSpace(root)))
		if err != nil {
			return s, err
		}
		abs = filepath.Clean(abs)
		if abs == "/" {
			return s, badRequest("the projects folder cannot be /")
		}
		if fi, err := os.Stat(abs); err == nil && !fi.IsDir() {
			return s, badRequest("%s is a file, not a folder", abs)
		}
		if err := os.MkdirAll(abs, 0o755); err != nil {
			return s, err
		}
		if resolved, err := filepath.EvalSymlinks(abs); err == nil {
			abs = resolved
		}
		// The folder pierd may delete projects and spaces in: never the home
		// folder or one holding it.
		if home, err := os.UserHomeDir(); err == nil {
			h := filepath.Clean(home)
			if r, err := filepath.EvalSymlinks(h); err == nil {
				h = r
			}
			if under(h, abs) {
				return s, badRequest("the projects folder cannot be the home folder or one holding it: use a folder such as %s", filepath.Join(h, "code"))
			}
		}
		s.ProjectsRoot = abs
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	return s, statefile.Write(l.settingsPath(), append(b, '\n'))
}

// under reports whether path is root or inside it.
func under(path, root string) bool {
	path, root = filepath.Clean(path), filepath.Clean(root)
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}

// placeOf says where a project at path sits against the projects folder:
// its space ("" right under the folder) and whether it is outside it.
func placeOf(path, root string) (space string, outside bool) {
	if root == "" {
		return "", false
	}
	if !under(path, root) {
		return "", true
	}
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return "", true
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if len(parts) >= 2 {
		return parts[0], false
	}
	return "", false
}

// withPlace sets loc's space against the projects folder.
func (l *Locations) withPlace(loc Location, root string) Location {
	loc.Space, loc.OutsideRoot = placeOf(loc.Path, root)
	return loc
}

// checkInRoot refuses a path outside the projects folder, when one is set.
func (l *Locations) checkInRoot(path string) error {
	root := l.Settings().ProjectsRoot
	if root == "" {
		return nil
	}
	abs, err := filepath.Abs(expandHome(path))
	if err != nil {
		return err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}
	if !under(abs, root) {
		return httpError{http.StatusForbidden, fmt.Sprintf("%s is outside the box's projects folder (%s)", abs, root)}
	}
	return nil
}

// Spaces lists the folders right under the projects folder that are not
// repositories (nor worktrees) themselves, with how many projects each holds.
func (l *Locations) Spaces(ctx context.Context) []Space {
	root := l.Settings().ProjectsRoot
	out := []Space{}
	if root == "" {
		return out
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return out
	}
	locs, _ := l.List(ctx)
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		p := filepath.Join(root, e.Name())
		if st, err := os.Lstat(filepath.Join(p, spaceMarker)); err != nil || !st.Mode().IsRegular() {
			continue
		}
		s := Space{Name: e.Name(), Path: p}
		for _, loc := range locs {
			if loc.Space == e.Name() {
				s.Projects++
			}
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// spaceDir is the folder of a space, made if it is not there yet.
func (l *Locations) spaceDir(name string, create bool) (string, error) {
	root := l.Settings().ProjectsRoot
	if root == "" {
		return "", badRequest("set the box's projects folder before using spaces")
	}
	if name == "" {
		return root, nil
	}
	if !trust.ValidName(name) {
		return "", badRequest("invalid space name %q", name)
	}
	p := filepath.Join(root, name)
	if _, err := os.Stat(filepath.Join(p, ".git")); err == nil {
		return "", badRequest("%s is a project, not a space", name)
	}
	_, markErr := os.Lstat(filepath.Join(p, spaceMarker))
	switch {
	case markErr == nil:
	case create:
		if fi, err := os.Lstat(p); err == nil && !fi.IsDir() {
			return "", badRequest("%s is a file, not a folder", p)
		}
		if err := os.MkdirAll(p, 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(p, spaceMarker), []byte("A space of Pier's projects folder: the projects in it are removed with it.\n"), 0o644); err != nil {
			return "", err
		}
	default:
		return "", httpError{http.StatusNotFound, "no space called " + name}
	}
	return p, nil
}

func (b *Box) settingsView(ctx context.Context) SettingsView {
	s := b.Locations.Settings()
	v := SettingsView{Settings: s, Spaces: b.Locations.Spaces(ctx), Docker: dockerState(ctx)}
	v.Home, _ = os.UserHomeDir()
	v.PrepareRules, v.PrepareRulesDefault, v.AutoShare = s.prepareRules(), strings.TrimSpace(s.PrepareRules) == "", s.autoShare()
	return v
}

func (b *Box) getSettings(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.settingsView(r.Context()))
	return nil
}

func (b *Box) putSettings(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		ProjectsRoot *string `json:"projects_root"`
		// PrepareRules "" (or only spaces) brings the default rules back.
		PrepareRules *string `json:"prepare_rules"`
		AutoShare    *bool   `json:"auto_share"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.PrepareRules != nil && len(*req.PrepareRules) > maxPrepareRules {
		return badRequest("the preparation rules are longer than %d KB", maxPrepareRules>>10)
	}
	if req.ProjectsRoot != nil {
		if err := b.before(r, "settings.change", map[string]any{"projects_root": *req.ProjectsRoot}); err != nil {
			return err
		}
		s, err := b.Locations.SetProjectsRoot(*req.ProjectsRoot)
		if err != nil {
			return err
		}
		b.publish(r, "settings.changed", map[string]any{"projects_root": s.ProjectsRoot})
	}
	if req.PrepareRules != nil || req.AutoShare != nil {
		// The rules' text goes to every setup agent, never into an event.
		changed := []string{}
		if req.PrepareRules != nil {
			changed = append(changed, "prepare_rules")
		}
		if req.AutoShare != nil {
			changed = append(changed, "auto_share")
		}
		if err := b.before(r, "settings.change", map[string]any{"changed": changed}); err != nil {
			return err
		}
		if _, err := b.Locations.updateSettings(func(s *Settings) {
			if req.PrepareRules != nil {
				s.PrepareRules = strings.TrimSpace(*req.PrepareRules)
			}
			if req.AutoShare != nil {
				on := *req.AutoShare
				s.AutoShare = &on
			}
		}); err != nil {
			return err
		}
		b.publish(r, "settings.changed", map[string]any{"changed": changed})
	}
	writeJSON(w, b.settingsView(r.Context()))
	return nil
}

func (b *Box) addSpace(w http.ResponseWriter, r *http.Request) error {
	var req struct{ Name string }
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.Name == "" {
		return badRequest("a space needs a name")
	}
	p, err := b.Locations.spaceDir(req.Name, true)
	if err != nil {
		return err
	}
	b.publish(r, "space.added", map[string]any{"space": req.Name, "path": p})
	writeJSON(w, Space{Name: req.Name, Path: p})
	return nil
}

// removeSpace deletes a space: empty, or with ?purge=1 its projects are
// removed from the disk with it (each checked for unsaved work unless
// force=1). Its projects never move out of it.
func (b *Box) removeSpace(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	name := r.PathValue("name")
	if name == "" {
		return badRequest("which space?")
	}
	dir, err := b.Locations.spaceDir(name, false)
	if err != nil {
		return err
	}
	q := r.URL.Query()
	purge, force, deleteFiles := q.Get("purge") == "1", q.Get("force") == "1", q.Get("delete_files") == "1"
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return err
	}
	var inside []Location
	for _, l := range locs {
		if under(l.Path, dir) {
			inside = append(inside, l)
		}
	}
	if len(inside) > 0 && !purge {
		names := make([]string, len(inside))
		for i, l := range inside {
			names[i] = l.Name
		}
		return fmt.Errorf("%w: %s (remove them with it with purge=1)", ErrSpaceNotEmpty, strings.Join(names, ", "))
	}
	// Every project is checked before any is touched: all go, or none.
	disks := make([]DiskUse, len(inside))
	for i, l := range inside {
		disks[i] = b.diskUse(ctx, l)
		if !disks[i].Removable {
			return httpError{http.StatusConflict, l.Name + ": " + disks[i].Reason}
		}
		if disks[i].Unsaved() && !force {
			return fmt.Errorf("%w: %s: %s", ErrUnsavedWork, l.Name, unsavedSummary(disks[i]))
		}
	}
	// What is in it besides its projects (and their worktrees) goes only
	// when asked to: an unregistered repository may hold work.
	var others []string
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			p := filepath.Join(dir, e.Name())
			if e.Name() == spaceMarker {
				continue
			}
			known := false
			for _, l := range inside {
				for _, wt := range l.Worktrees {
					known = known || samePath(wt.Path, p)
				}
				known = known || samePath(l.Path, p)
			}
			if !known {
				others = append(others, e.Name())
			}
		}
	}
	if len(others) > 0 && !deleteFiles {
		shown := others
		if len(shown) > 5 {
			shown = append(shown[:5:5], fmt.Sprintf("and %d more", len(others)-5))
		}
		return fmt.Errorf("%w: %s (delete them with it with delete_files=1)", ErrSpaceHasFiles, strings.Join(shown, ", "))
	}
	if err := b.before(r, "space.remove", map[string]any{"space": name, "path": dir, "projects": len(inside), "files": len(others)}); err != nil {
		return err
	}
	var freed int64
	for i, l := range inside {
		if err := b.purge(r, l, disks[i]); err != nil {
			return err
		}
		freed += disks[i].Bytes
	}
	if len(others) > 0 {
		freed += dirSize(ctx, dir)
	}
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	b.publish(r, "space.removed", map[string]any{"space": name, "path": dir, "freed": freed})
	writeJSON(w, map[string]any{"removed": name, "freed": freed})
	return nil
}
