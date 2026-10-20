package box

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"pier/pierd/internal/groups"
)

// The team: on a machine where several people each run their own pierd (one
// Linux user each), root keeps a base for a project in the team's folder
// (`pierd team`, run as root): the recipe, the files every worktree gets and,
// later, the database snapshot. Every member's pierd copies the team's config
// and files into its own folder (a mirror) and lays them under its own: the
// repository's config, then the team's, then the box's own.
//
// The team's folder is readable by its group alone. A member added to the
// group after their pierd started does not have it (a systemd user manager
// keeps the groups of the user's first login, so not even restarting pierd
// gives it), so every read of the team's folder goes through a child that sg
// gives the group (internal/groups).

// teamSettingsPath is the machine's team settings, which `pierd team init`
// writes; tests replace it.
var teamSettingsPath = "/etc/pier/team.json"

type teamSettings struct {
	// Dir is the team's folder: projects/<base key>/ in it.
	Dir   string `json:"dir"`
	Group string `json:"group,omitempty"`
}

// readTeamSettings reads the machine's team settings: ok is false when the
// machine has none. Settings that are there but cannot be read (being
// written, mistyped) are an error, which keeps what was copied.
func readTeamSettings() (s teamSettings, ok bool, err error) {
	err = loadJSON(teamSettingsPath, &s)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return teamSettings{}, false, nil
	case err != nil:
		return teamSettings{}, false, err
	case !filepath.IsAbs(s.Dir):
		return teamSettings{}, false, fmt.Errorf("%s: the team's folder %q is not an absolute path", teamSettingsPath, s.Dir)
	}
	return s, true, nil
}

// teamPublished is a team project's published.json, written last by root
// each time it changes the project: when, and what each file is, so a
// member copies exactly that.
type teamPublished struct {
	At    time.Time               `json:"at"`
	Files map[string]teamFileMeta `json:"files,omitempty"`
	// Config is the hash of config.json, "" without one.
	Config string `json:"config,omitempty"`
	// DB is the team's current database snapshot, in db/gen/<id>/ of the
	// project's folder.
	DB *teamSnapshot `json:"db,omitempty"`
}

type teamSnapshot struct {
	ID       string           `json:"id"`
	Manifest snapshotManifest `json:"manifest"`
}

type teamFileMeta struct {
	SHA  string `json:"sha"`
	Size int64  `json:"size"`
}

// TeamView is the team's base for a project as GET …/base shows it.
type TeamView struct {
	Dir       string     `json:"dir"`
	Published *time.Time `json:"published,omitempty"`
	// Error says why the team's folder could not be read (this box's user
	// is not in its group, say); the last copy taken still applies.
	Error string `json:"error,omitempty"`
}

// teamRead reads a file of the team's folder: directly when pierd has the
// group, else through cat run with it.
var teamRead = func(ctx context.Context, path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err == nil || !errors.Is(err, fs.ErrPermission) {
		return data, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var out, errOut bytes.Buffer
	cmd := groups.CommandContext(ctx, "cat", "--", path)
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errOut.String())
		if strings.Contains(msg, "No such file") {
			return nil, fs.ErrNotExist
		}
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("%w: %s", fs.ErrPermission, msg)
	}
	return out.Bytes(), nil
}

// teamStrip is a team's config as a member's pierd applies it: what
// prepares worktrees and what they get, never what is a person's to say
// (consent to setup agents, public links) nor what runs on events or
// starts agents.
func teamStrip(c RepoConfig) RepoConfig {
	c.PrepareWith, c.AutoShare, c.Detected, c.By = "", nil, false, ""
	c.Hooks, c.Agents = nil, nil
	return c
}

// syncTeam brings the box's copy of the team's base for location up to what
// root published last (at most every few seconds), and says how the team's
// base stands: nil when the machine has no team or the team no base for the
// project. Locations that share a base (two clones of one repository) share
// the copy; each takes the team's config from it.
func (b *Box) syncTeam(ctx context.Context, location string) *TeamView {
	key, err := b.Locations.BaseKey(ctx, location)
	if err != nil {
		return nil
	}
	// One copy at a time, and nobody reads it halfway (baseFiles' callers
	// hold the same lock).
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	mirror := filepath.Join(b.baseDir(key), "team")
	set, ok, err := readTeamSettings()
	if err != nil {
		b.applyTeam(location, mirror)
		return b.teamViewFromMirror(&TeamView{Error: "the machine's team settings cannot be read: " + err.Error()}, mirror)
	}
	if !ok {
		b.dropTeam(location, mirror)
		return nil
	}
	view := &TeamView{Dir: filepath.Join(set.Dir, "projects", key)}
	if last, ok := b.teamSynced.Load(key); ok && time.Since(last.(time.Time)) < 5*time.Second {
		b.applyTeam(location, mirror)
		return b.teamViewFromMirror(view, mirror)
	}
	b.teamSynced.Store(key, time.Now())
	pub, err := teamRead(ctx, filepath.Join(view.Dir, "published.json"))
	if errors.Is(err, fs.ErrNotExist) {
		b.dropTeam(location, mirror)
		return nil
	}
	if err != nil {
		view.Error = "the team's folder cannot be read: " + err.Error()
	} else if have, _ := os.ReadFile(filepath.Join(mirror, "published.json")); !bytes.Equal(have, pub) {
		if err := copyTeam(ctx, view.Dir, mirror, pub); err != nil {
			view.Error = "the team's base could not be copied: " + err.Error()
		}
	}
	b.applyTeam(location, mirror)
	return b.teamViewFromMirror(view, mirror)
}

func (b *Box) teamViewFromMirror(view *TeamView, mirror string) *TeamView {
	var p teamPublished
	if loadJSON(filepath.Join(mirror, "published.json"), &p) == nil && !p.At.IsZero() {
		at := p.At
		view.Published = &at
	}
	return view
}

// copyTeam takes the team's published config and files into mirror, whole
// or not at all: each file is checked against the hash published with it.
// The config goes in as a member applies it (teamStrip). The caller holds
// the base's lock.
func copyTeam(ctx context.Context, dir, mirror string, pubData []byte) error {
	var pub teamPublished
	if err := json.Unmarshal(pubData, &pub); err != nil {
		return fmt.Errorf("published.json: %w", err)
	}
	// What a copy cut short (pierd stopped halfway) left.
	if stale, _ := filepath.Glob(mirror + ".new-*"); len(stale) > 0 {
		for _, p := range stale {
			os.RemoveAll(p)
		}
	}
	if err := os.MkdirAll(filepath.Dir(mirror), 0o700); err != nil {
		return err
	}
	next, err := os.MkdirTemp(filepath.Dir(mirror), filepath.Base(mirror)+".new-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(next)
	if err := os.MkdirAll(filepath.Join(next, "files"), 0o700); err != nil {
		return err
	}
	if pub.Config != "" {
		data, err := teamRead(ctx, filepath.Join(dir, "config.json"))
		if err != nil {
			return err
		}
		if sha256Hex(data) != pub.Config {
			return errors.New("config.json is not the one published: root may be changing it, try again")
		}
		var c RepoConfig
		if err := json.Unmarshal(data, &c); err != nil {
			return fmt.Errorf("config.json: %w", err)
		}
		c = teamStrip(c)
		if err := c.validate(); err != nil {
			return fmt.Errorf("config.json: %w", err)
		}
		if err := saveJSON(filepath.Join(next, "config.json"), c); err != nil {
			return err
		}
	}
	for p, meta := range pub.Files {
		clean, err := cleanBasePath(p)
		if err != nil || clean != p {
			return fmt.Errorf("published file %q: not a path inside the project", p)
		}
		data, err := teamRead(ctx, filepath.Join(dir, "files", filepath.FromSlash(p)))
		if err != nil {
			return err
		}
		if sha256Hex(data) != meta.SHA {
			return fmt.Errorf("%s is not the one published: root may be changing it, try again", p)
		}
		dst := filepath.Join(next, "files", filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(dst, data, 0o600); err != nil {
			return err
		}
	}
	if err := os.WriteFile(filepath.Join(next, "published.json"), pubData, 0o600); err != nil {
		return err
	}
	old := next + ".old"
	if err := os.Rename(mirror, old); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := os.Rename(next, mirror); err != nil {
		os.Rename(old, mirror)
		return err
	}
	os.RemoveAll(old)
	return nil
}

// applyTeam gives location the team's config from the copy in mirror,
// unless it has that one already.
func (b *Box) applyTeam(location, mirror string) {
	saved, err := b.Locations.saved(location)
	if err != nil {
		return
	}
	var pub teamPublished
	if loadJSON(filepath.Join(mirror, "published.json"), &pub) != nil {
		if saved.Team != nil || saved.TeamAt != nil {
			b.Locations.SetTeam(location, nil, nil)
		}
		return
	}
	if saved.TeamAt != nil && saved.TeamAt.Equal(pub.At) {
		return
	}
	var cfg *RepoConfig
	if pub.Config != "" {
		var c RepoConfig
		if loadJSON(filepath.Join(mirror, "config.json"), &c) != nil {
			return
		}
		cfg = &c
	}
	at := pub.At
	b.Locations.SetTeam(location, cfg, &at)
}

// dropTeam forgets the team's base for location: the machine has no team any
// more, or the team no base for the project.
func (b *Box) dropTeam(location, mirror string) {
	if _, err := os.Stat(mirror); err == nil {
		os.RemoveAll(mirror)
	}
	if saved, err := b.Locations.saved(location); err == nil && (saved.Team != nil || saved.TeamAt != nil) {
		b.Locations.SetTeam(location, nil, nil)
	}
}

// SetTeam keeps the team's config for a location as last copied.
func (l *Locations) SetTeam(name string, cfg *RepoConfig, at *time.Time) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name == name {
				all[i].Team, all[i].TeamAt = cfg, at
				return all, nil
			}
		}
		return nil, ErrUnknownLocation
	})
}
