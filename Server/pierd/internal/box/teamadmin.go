package box

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"

	"pier/pierd/internal/statefile"
)

// Root's side of the team (`pierd team`): the team's folder holds a base per
// project, projects/<owner__repo>/ with config.json, files/, db/ (gen/<id>/,
// current) and published.json, written last each time, which every member's
// pierd copies (team.go). Everything in it is the team's group's to read and
// the team's user's to write.

// TeamSettings are /etc/pier/team.json's.
type TeamSettings = teamSettings

// ReadTeamSettings reads /etc/pier/team.json: ok is false when the machine
// has none.
func ReadTeamSettings() (TeamSettings, bool, error) { return readTeamSettings() }

// AppArmorRuleFor is the AppArmor lines for a team's folder at dir.
func AppArmorRuleFor(dir string) string { return apparmorRule(dir) }

// AppArmorMarker starts the AppArmor lines in the MySQL server's local
// profile.
const AppArmorMarker = apparmorMarker

// TeamSettingsPath is where they are.
func TeamSettingsPath() string { return teamSettingsPath }

// TeamOwner is who owns what root writes in the team's folder: the team's
// user and group. Zero (a test, a dry run) leaves ownership as it is.
type TeamOwner struct{ UID, GID int }

// TeamProject is a project's base in the team's folder.
type TeamProject struct {
	Dir   string
	Key   string
	Owner TeamOwner
}

// OpenTeamProject is slug's (owner/repo) base in the team's folder dir, made
// if missing.
func OpenTeamProject(dir, slug string, owner TeamOwner) (*TeamProject, error) {
	key := baseKeyFor(slug, "")
	if key == "" || len(key) > 6 && key[:6] == "local-" {
		return nil, fmt.Errorf("%q is not owner/repo", slug)
	}
	p := &TeamProject{Dir: filepath.Join(dir, "projects", key), Key: key, Owner: owner}
	for _, d := range []string{filepath.Join(dir, "projects"), p.Dir, filepath.Join(p.Dir, "files"), filepath.Join(p.Dir, "db")} {
		if err := os.MkdirAll(d, 0o750); err != nil {
			return nil, err
		}
		p.own(d, true)
	}
	return p, nil
}

func (p *TeamProject) own(path string, dir bool) {
	if p.Owner.UID == 0 && p.Owner.GID == 0 {
		return
	}
	os.Lchown(path, p.Owner.UID, p.Owner.GID)
	if dir {
		os.Chmod(path, 0o750|fs.ModeSetgid)
	} else {
		os.Chmod(path, 0o640)
	}
}

// Published is what was published last.
func (p *TeamProject) Published() teamPublished {
	var pub teamPublished
	loadJSON(filepath.Join(p.Dir, "published.json"), &pub)
	if pub.Files == nil {
		pub.Files = map[string]teamFileMeta{}
	}
	return pub
}

// publish writes published.json, last and whole: members copy what it says.
func (p *TeamProject) publish(pub teamPublished) error {
	pub.At = time.Now().UTC()
	data, err := json.MarshalIndent(pub, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(p.Dir, "published.json")
	if err := statefile.Write(path, append(data, '\n')); err != nil {
		return err
	}
	if p.Owner.UID != 0 || p.Owner.GID != 0 {
		p.own(path, false)
	} else {
		os.Chmod(path, 0o640)
	}
	return nil
}

// AddFile publishes rel (a path inside the project) with data.
func (p *TeamProject) AddFile(rel string, data []byte) error {
	clean, err := cleanBasePath(rel)
	if err != nil {
		return err
	}
	if len(data) > maxBaseFileBytes {
		return fmt.Errorf("%s is larger than %d bytes: a base keeps small files", rel, maxBaseFileBytes)
	}
	pub := p.Published()
	if _, ok := pub.Files[clean]; !ok && len(pub.Files) >= maxBaseFiles {
		return fmt.Errorf("a base keeps at most %d files", maxBaseFiles)
	}
	path := filepath.Join(p.Dir, "files", filepath.FromSlash(clean))
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	for d := filepath.Dir(path); d != filepath.Join(p.Dir, "files") && len(d) > len(p.Dir); d = filepath.Dir(d) {
		p.own(d, true)
	}
	if err := statefile.Write(path, data); err != nil {
		return err
	}
	if p.Owner.UID != 0 || p.Owner.GID != 0 {
		p.own(path, false)
	} else {
		os.Chmod(path, 0o640)
	}
	pub.Files[clean] = teamFileMeta{SHA: sha256Hex(data), Size: int64(len(data))}
	return p.publish(pub)
}

// RemoveFile stops publishing rel.
func (p *TeamProject) RemoveFile(rel string) error {
	clean, err := cleanBasePath(rel)
	if err != nil {
		return err
	}
	pub := p.Published()
	if _, ok := pub.Files[clean]; !ok {
		return fmt.Errorf("%s is not in the team's base", clean)
	}
	delete(pub.Files, clean)
	if err := p.publish(pub); err != nil {
		return err
	}
	return os.Remove(filepath.Join(p.Dir, "files", filepath.FromSlash(clean)))
}

// FilePaths are the published files, sorted.
func (p *TeamProject) FilePaths() []string {
	pub := p.Published()
	out := make([]string, 0, len(pub.Files))
	for k := range pub.Files {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// File is one published file's content.
func (p *TeamProject) File(rel string) ([]byte, error) {
	clean, err := cleanBasePath(rel)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(filepath.Join(p.Dir, "files", filepath.FromSlash(clean)))
}

// Config is the team's config for the project ({} without one).
func (p *TeamProject) Config() (RepoConfig, error) {
	var c RepoConfig
	err := loadJSON(filepath.Join(p.Dir, "config.json"), &c)
	if errors.Is(err, fs.ErrNotExist) {
		return RepoConfig{}, nil
	}
	return c, err
}

// SetConfig publishes c as the team's config: what prepares worktrees and
// what they get; a person's say (consent to setup agents, public links),
// hooks and agents are refused.
func (p *TeamProject) SetConfig(c RepoConfig) error {
	if c.PrepareWith != "" || c.AutoShare != nil || c.Detected || c.By != "" || len(c.Hooks) > 0 || len(c.Agents) > 0 {
		return errors.New("a team's config holds what prepares worktrees and what they get: prepare_with, auto_share, detected, by, hooks and agents are each person's")
	}
	if err := c.validate(); err != nil {
		return err
	}
	if c.Base != nil && (c.Base.DB != nil || c.Base.Redis) && c.Ports > maxPortsWithServers {
		return fmt.Errorf("the config asks for %d ports per worktree; the worktrees' own servers take the last two of ten, so it may ask for at most %d", c.Ports, maxPortsWithServers)
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	path := filepath.Join(p.Dir, "config.json")
	if err := statefile.Write(path, data); err != nil {
		return err
	}
	p.own(path, false)
	os.Chmod(path, 0o640)
	pub := p.Published()
	pub.Config = sha256Hex(data)
	return p.publish(pub)
}

// DBDir is where the project's snapshots go.
func (p *TeamProject) DBDir() string { return filepath.Join(p.Dir, "db") }

// PublishDB makes the current snapshot what members' worktrees copy.
func (p *TeamProject) PublishDB() error {
	gens, current := SnapshotGens(p.DBDir())
	pub := p.Published()
	pub.DB = nil
	for _, g := range gens {
		if g.ID == current {
			pub.DB = &teamSnapshot{ID: g.ID, Manifest: g}
		}
	}
	return p.publish(pub)
}

// LocalRecipe is a person's box config for one of their locations, read
// from their locations.json (root copying a recipe a setup agent saved into
// the team's base), stripped to what a team's config may hold.
func LocalRecipe(locationsFile, location string) (RepoConfig, error) {
	var all []savedLocation
	if err := loadJSON(locationsFile, &all); err != nil {
		return RepoConfig{}, err
	}
	for _, s := range all {
		if s.Name != location {
			continue
		}
		c := RepoConfig{Setup: s.Setup, Archive: s.Archive}
		if s.Config != nil {
			c = merge(c, *s.Config)
		}
		c = teamStrip(c)
		if c.Base != nil {
			// Servers stay as the team's own config says.
			c.Base.DB, c.Base.Redis = nil, false
		}
		return c, nil
	}
	return RepoConfig{}, fmt.Errorf("no location %s in %s", location, locationsFile)
}
