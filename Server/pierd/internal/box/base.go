package box

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/statefile"
)

// A project's base is what every new worktree of it gets that git does not
// bring, configured once:
//
//   - files the box keeps for the project, untracked in it (.env, auth.json,
//     keys), written into each checkout; a dotenv file key by key, so what
//     someone changed in a worktree stays;
//   - ignored folders of the main checkout (vendor, node_modules) copied
//     into each new worktree before its recipe runs (carry.go), so the
//     recipe's install only reconciles them.
//
// A person keeps a base for a project on their box; on a machine shared by
// a team, root keeps one in the team's folder (team.go) that every member's
// pierd lays under their own.

// BaseConfig is a config's part of the base.
type BaseConfig struct {
	// Carry are ignored folders or files of the main checkout copied into
	// each new worktree before its recipe runs, copy-on-write where the disk
	// can (vendor, node_modules, a downloaded binary).
	Carry []string `json:"carry,omitempty"`
}

const (
	maxCarry         = 50
	maxBaseFiles     = 200
	maxBaseFileBytes = 1 << 20
)

func (c *BaseConfig) validate() error {
	if c == nil {
		return nil
	}
	if len(c.Carry) > maxCarry {
		return fmt.Errorf("base.carry takes at most %d paths", maxCarry)
	}
	for _, p := range c.Carry {
		if _, err := cleanBasePath(p); err != nil {
			return fmt.Errorf("base.carry: %w", err)
		}
	}
	return nil
}

// mergeBase lays over on base: the folders to carry add up.
func mergeBase(base, over *BaseConfig) *BaseConfig {
	if base == nil && over == nil {
		return nil
	}
	out := &BaseConfig{}
	seen := map[string]bool{}
	for _, c := range []*BaseConfig{base, over} {
		if c == nil {
			continue
		}
		for _, p := range c.Carry {
			if clean, err := cleanBasePath(p); err == nil && !seen[clean] {
				seen[clean] = true
				out.Carry = append(out.Carry, clean)
			}
		}
	}
	return out
}

// cleanBasePath is p as a path inside a checkout, with / separators; an
// absolute path, one that leaves the checkout or goes into .git is refused.
func cleanBasePath(p string) (string, error) {
	p = strings.TrimSpace(strings.ReplaceAll(p, "\\", "/"))
	if p == "" || strings.ContainsRune(p, 0) {
		return "", fmt.Errorf("%q is not a path", p)
	}
	if strings.HasPrefix(p, "/") {
		return "", fmt.Errorf("%q is absolute: paths are inside the project", p)
	}
	p = strings.TrimSuffix(path.Clean(p), "/")
	if p == "." || p == ".." || strings.HasPrefix(p, "../") {
		return "", fmt.Errorf("%q is outside the project", p)
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".git" {
			return "", fmt.Errorf("%q is inside .git", p)
		}
	}
	return p, nil
}

// BaseResult is what applying the base did with one path.
type BaseResult struct {
	Path string `json:"path"`
	// Action is "written" (it was missing), "updated" (the base changed and
	// the checkout's copy was still pierd's), "unchanged" (already the
	// base's), "kept" (someone changed it there), "carried", "skipped" or
	// "failed".
	Action string `json:"action"`
	Reason string `json:"reason,omitempty"`
	// Keys are the dotenv keys someone changed in the checkout, kept as
	// they are.
	Keys []string `json:"keys,omitempty"`
	MS   int64    `json:"ms,omitempty"`
}

// BaseReport is how the base went into a worktree, kept with its
// preparation.
type BaseReport struct {
	Files   []BaseResult `json:"files,omitempty"`
	Carried []BaseResult `json:"carried,omitempty"`
}

// The box's own base for a project: $PIER_HOME/box/base/<key>/ holds
// base.json (what the files are), files/ (them) and written.json (what pierd
// wrote into each checkout, as hashes: the files hold secrets).

type baseManifest struct {
	Files map[string]baseFileMeta `json:"files"`
}

type baseFileMeta struct {
	SHA   string    `json:"sha"`
	Size  int64     `json:"size"`
	Added time.Time `json:"added"`
	// From is the checkout it was taken from.
	From string `json:"from,omitempty"`
}

// writtenFile is what pierd last wrote of one file into one checkout.
type writtenFile struct {
	// SHA is the whole file's, for a plain file.
	SHA string `json:"sha,omitempty"`
	// Keys are a dotenv file's, each with its value's hash.
	Keys map[string]string `json:"keys,omitempty"`
}

func (b *Box) baseRoot() string {
	if b.StateDir == "" {
		return filepath.Join(os.TempDir(), "pier-base")
	}
	return filepath.Join(b.StateDir, "base")
}

func (b *Box) baseDir(key string) string { return filepath.Join(b.baseRoot(), key) }

// baseLock serialises changes to one base's files and records.
func (b *Box) baseLock(key string) *sync.Mutex {
	mu, _ := b.baseLocks.LoadOrStore(key, &sync.Mutex{})
	return mu.(*sync.Mutex)
}

func loadJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

func saveJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return statefile.Write(path, append(data, '\n'))
}

func (b *Box) baseManifest(key string) baseManifest {
	var m baseManifest
	loadJSON(filepath.Join(b.baseDir(key), "base.json"), &m)
	if m.Files == nil {
		m.Files = map[string]baseFileMeta{}
	}
	return m
}

// baseFile is one file of a project's base, from whichever layer has it.
type baseFile struct {
	Path   string
	Source string
	SHA    string
	Size   int64
	// Layer is "box" (the person's own) or "team".
	Layer string
	Added time.Time
}

// baseFiles are a project's base files: the team's, and the box's own over
// them by path. The caller holds the base's lock, or the team's copy could
// be read halfway through being replaced (lockedBaseFiles).
func (b *Box) baseFiles(key string) []baseFile {
	byPath := map[string]baseFile{}
	var pub teamPublished
	if loadJSON(filepath.Join(b.baseDir(key), "team", "published.json"), &pub) == nil {
		for p, meta := range pub.Files {
			byPath[p] = baseFile{Path: p, Source: filepath.Join(b.baseDir(key), "team", "files", filepath.FromSlash(p)),
				SHA: meta.SHA, Size: meta.Size, Layer: "team", Added: pub.At}
		}
	}
	for p, meta := range b.baseManifest(key).Files {
		byPath[p] = baseFile{Path: p, Source: filepath.Join(b.baseDir(key), "files", filepath.FromSlash(p)),
			SHA: meta.SHA, Size: meta.Size, Layer: "box", Added: meta.Added}
	}
	out := make([]baseFile, 0, len(byPath))
	for _, f := range byPath {
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

// lockedBaseFiles is baseFiles for a caller that does not hold the lock.
func (b *Box) lockedBaseFiles(key string) []baseFile {
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	return b.baseFiles(key)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// gitTracks says git tracks rel (or, for a folder, something in it) in the
// checkout at dir. When git cannot tell (a request cancelled), callers leave
// the path alone rather than write secrets into a file a commit takes.
func gitTracks(ctx context.Context, dir, rel string) (bool, error) {
	out, err := git(ctx, "-C", dir, "ls-files", "-z", "--", rel)
	if err != nil {
		if msg := strings.TrimSpace(string(out)); msg != "" {
			return false, fmt.Errorf("git ls-files: %s", msg)
		}
		return false, fmt.Errorf("git ls-files: %w", err)
	}
	return len(bytes.TrimSpace(out)) > 0, nil
}

// gitIgnores says git ignores rel in the checkout at dir.
func gitIgnores(ctx context.Context, dir, rel string) bool {
	_, err := git(ctx, "-C", dir, "check-ignore", "-q", "--", rel)
	return err == nil
}

// excludeLocally keeps git from offering rel for a commit in every checkout
// of the repository (the app commits with `git add -A`): an anchored line in
// the shared info/exclude, the repository's own ignore file left as it is.
func excludeLocally(ctx context.Context, dir, rel string) error {
	return excludeLine(ctx, dir, "/"+rel)
}

// excludeLine adds line to the repository's shared info/exclude, under a
// comment that says it is Pier's.
func excludeLine(ctx context.Context, dir, line string) error {
	out, err := git(ctx, "-C", dir, "rev-parse", "--git-common-dir")
	if err != nil {
		return fmt.Errorf("git rev-parse: %s", strings.TrimSpace(string(out)))
	}
	common := strings.TrimSpace(string(out))
	if !filepath.IsAbs(common) {
		common = filepath.Join(dir, common)
	}
	exclude := filepath.Join(common, "info", "exclude")
	have, _ := os.ReadFile(exclude)
	header := false
	for _, l := range strings.Split(string(have), "\n") {
		switch strings.TrimSpace(l) {
		case line:
			return nil
		case excludeHeader:
			header = true
		}
	}
	if err := os.MkdirAll(filepath.Dir(exclude), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(exclude, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	var add strings.Builder
	if len(have) > 0 && !bytes.HasSuffix(have, []byte("\n")) {
		add.WriteString("\n")
	}
	// A comment is a line of its own: after a pattern it would be part of
	// it.
	if !header {
		add.WriteString(excludeHeader + "\n")
	}
	add.WriteString(line + "\n")
	_, err = f.WriteString(add.String())
	return err
}

const excludeHeader = "# Files the project's base writes into its checkouts (Pier)"

// writeInRoot writes data to rel inside root, whole or not at all: a
// temporary file beside it, renamed over it. Nothing is written through a
// link: the rename replaces the name itself. The temporary file's name is
// one git is told to ignore (tempExclude), so one left by a crash is never
// committed.
func writeInRoot(root *os.Root, rel string, data []byte) error {
	dir := filepath.Dir(rel)
	if dir != "." {
		if err := root.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	var suffix [4]byte
	rand.Read(suffix[:])
	tmp := filepath.Join(dir, tempPrefix+hex.EncodeToString(suffix[:]))
	if err := root.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := root.Rename(tmp, rel); err != nil {
		root.Remove(tmp)
		return err
	}
	return nil
}

// tempPrefix starts the name of a file writeInRoot is writing, and
// tempExclude is the info/exclude line that matches it anywhere.
const (
	tempPrefix  = ".pier-write-"
	tempExclude = tempPrefix + "*"
)

// applyBaseFiles writes the project's base files into the checkout at wt: a
// missing one is written; one the checkout still has as pierd wrote it is
// updated to the base's; one someone changed there is kept. A dotenv file
// goes key by key the same way. A path git tracks there is skipped, and one
// it does not ignore is added to the repository's local excludes. Callers
// leave a pull request's checkout out unless asked (placeBaseFiles): its code
// could read the secrets.
func (b *Box) applyBaseFiles(ctx context.Context, loc Location, wt Worktree) []BaseResult {
	key, err := b.Locations.BaseKey(ctx, loc.Name)
	if err != nil {
		return nil
	}
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	files := b.baseFiles(key)
	if len(files) == 0 {
		return nil
	}
	if err := excludeLine(ctx, wt.Path, tempExclude); err != nil {
		return []BaseResult{{Path: ".", Action: "failed", Reason: "adding pierd's temporary files to .git/info/exclude failed: " + err.Error()}}
	}
	writtenPath := filepath.Join(b.baseDir(key), "written.json")
	written := map[string]map[string]writtenFile{}
	loadJSON(writtenPath, &written)
	mine := written[wt.Path]
	if mine == nil {
		mine = map[string]writtenFile{}
	}
	root, err := os.OpenRoot(wt.Path)
	if err != nil {
		return []BaseResult{{Path: ".", Action: "failed", Reason: err.Error()}}
	}
	defer root.Close()
	var out []BaseResult
	for _, f := range files {
		res := b.applyBaseFile(ctx, root, wt, f, mine)
		if res.Action == "written" || res.Action == "updated" {
			if !gitIgnores(ctx, wt.Path, f.Path) {
				if err := excludeLocally(ctx, wt.Path, f.Path); err != nil {
					res.Reason = "not ignored by git, and adding it to .git/info/exclude failed: " + err.Error()
				}
			}
		}
		out = append(out, res)
	}
	written[wt.Path] = mine
	saveJSON(writtenPath, written)
	return out
}

func (b *Box) applyBaseFile(ctx context.Context, root *os.Root, wt Worktree, f baseFile, mine map[string]writtenFile) BaseResult {
	res := BaseResult{Path: f.Path}
	rel := filepath.FromSlash(f.Path)
	if tracked, err := gitTracks(ctx, wt.Path, f.Path); err != nil {
		res.Action, res.Reason = "skipped", "git could not say whether it tracks it: "+err.Error()
		return res
	} else if tracked {
		res.Action, res.Reason = "skipped", "git tracks it in this checkout"
		return res
	}
	data, err := os.ReadFile(f.Source)
	if err != nil {
		res.Action, res.Reason = "failed", "the base's copy is missing: "+err.Error()
		return res
	}
	if info, err := root.Lstat(rel); err == nil {
		if info.Mode()&fs.ModeSymlink != 0 {
			res.Action, res.Reason = "kept", "it is a link someone made"
			return res
		}
		if !info.Mode().IsRegular() {
			res.Action, res.Reason = "skipped", "something that is not a file is there"
			return res
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		res.Action, res.Reason = "failed", err.Error()
		return res
	} else {
		if err := writeInRoot(root, rel, data); err != nil {
			res.Action, res.Reason = "failed", err.Error()
			return res
		}
		mine[f.Path] = recordWritten(f.Path, data)
		res.Action = "written"
		return res
	}
	cur, err := root.ReadFile(rel)
	if err != nil {
		res.Action, res.Reason = "failed", err.Error()
		return res
	}
	if isEnvFile(f.Path) {
		return mergeBaseEnv(root, rel, f.Path, cur, data, mine)
	}
	had := mine[f.Path]
	switch sha := sha256Hex(cur); {
	case sha == f.SHA:
		mine[f.Path] = recordWritten(f.Path, data)
		res.Action = "unchanged"
	case had.SHA != "" && sha == had.SHA:
		if err := writeInRoot(root, rel, data); err != nil {
			res.Action, res.Reason = "failed", err.Error()
			return res
		}
		mine[f.Path] = recordWritten(f.Path, data)
		res.Action = "updated"
	default:
		res.Action, res.Reason = "kept", "someone changed it in this checkout"
	}
	return res
}

// recordWritten is what pierd keeps of a file it wrote: hashes only.
func recordWritten(p string, data []byte) writtenFile {
	if !isEnvFile(p) {
		return writtenFile{SHA: sha256Hex(data)}
	}
	f := parseEnvFile(data)
	keys := map[string]string{}
	for _, k := range f.keys() {
		v, _, _ := f.get(k)
		keys[k] = envValueHash(v)
	}
	return writtenFile{Keys: keys}
}

// mergeBaseEnv brings the checkout's dotenv file cur up to the base's,
// key by key: a key it lacks is added (unless pierd wrote it before and
// someone took it out), one it still has as pierd wrote it gets the base's
// value, one someone changed stays.
func mergeBaseEnv(root *os.Root, rel, p string, cur, base []byte, mine map[string]writtenFile) BaseResult {
	res := BaseResult{Path: p}
	had := mine[p].Keys
	if had == nil {
		had = map[string]string{}
	}
	file, from := parseEnvFile(cur), parseEnvFile(base)
	record := map[string]string{}
	changed := false
	for _, k := range from.keys() {
		want, rhs, _ := from.get(k)
		have, _, ok := file.get(k)
		switch {
		case !ok && had[k] != "":
			// Taken out by someone after pierd wrote it.
			res.Keys = append(res.Keys, k)
			record[k] = had[k]
		case !ok:
			file.set(k, rhs)
			changed = true
			record[k] = envValueHash(want)
		case have == want:
			record[k] = envValueHash(want)
		case had[k] != "" && envValueHash(have) == had[k]:
			file.set(k, rhs)
			changed = true
			record[k] = envValueHash(want)
		default:
			res.Keys = append(res.Keys, k)
			if had[k] != "" {
				record[k] = had[k]
			}
		}
	}
	mine[p] = writtenFile{Keys: record}
	if changed {
		if err := writeInRoot(root, rel, file.bytes()); err != nil {
			res.Action, res.Reason = "failed", err.Error()
			return res
		}
		res.Action = "updated"
	} else if len(res.Keys) > 0 {
		res.Action = "kept"
	} else {
		res.Action = "unchanged"
	}
	if len(res.Keys) > 0 {
		res.Reason = "someone changed these keys in this checkout"
	}
	return res
}

// forgetWritten drops what pierd recorded of a checkout that went away.
func (b *Box) forgetWritten(ctx context.Context, location, dir string) {
	key, err := b.Locations.BaseKey(ctx, location)
	if err != nil {
		return
	}
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	path := filepath.Join(b.baseDir(key), "written.json")
	written := map[string]map[string]writtenFile{}
	if loadJSON(path, &written) != nil {
		return
	}
	if _, ok := written[dir]; ok {
		delete(written, dir)
		saveJSON(path, written)
	}
}

// addBaseFile takes rel from the checkout at dir into the box's own base for
// the project.
func (b *Box) addBaseFile(ctx context.Context, loc Location, dir, from, rel string) error {
	p, err := cleanBasePath(rel)
	if err != nil {
		return badRequest("%v", err)
	}
	key, err := b.Locations.BaseKey(ctx, loc.Name)
	if err != nil {
		return err
	}
	if tracked, err := gitTracks(ctx, dir, p); err != nil {
		return fmt.Errorf("git could not say whether it tracks %s: %w", p, err)
	} else if tracked {
		return badRequest("git tracks %s: the base is for files the repository leaves out", p)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	info, err := root.Lstat(filepath.FromSlash(p))
	if errors.Is(err, fs.ErrNotExist) {
		return httpError{http.StatusNotFound, p + " is not in that checkout"}
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return badRequest("%s is not a plain file", p)
	}
	if info.Size() > maxBaseFileBytes {
		return badRequest("%s is larger than %d bytes: a base keeps small files (folders go in base.carry)", p, maxBaseFileBytes)
	}
	data, err := root.ReadFile(filepath.FromSlash(p))
	if err != nil {
		return err
	}
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	m := b.baseManifest(key)
	if _, ok := m.Files[p]; !ok && len(m.Files) >= maxBaseFiles {
		return badRequest("a base keeps at most %d files", maxBaseFiles)
	}
	dst := filepath.Join(b.baseDir(key), "files", filepath.FromSlash(p))
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	if err := statefile.Write(dst, data); err != nil {
		return err
	}
	m.Files[p] = baseFileMeta{SHA: sha256Hex(data), Size: int64(len(data)), Added: time.Now().UTC(), From: from}
	return saveJSON(filepath.Join(b.baseDir(key), "base.json"), m)
}

// removeBaseFile drops rel from the box's own base; the team's copy, if
// any, applies again.
func (b *Box) removeBaseFile(ctx context.Context, loc Location, rel string) error {
	p, err := cleanBasePath(rel)
	if err != nil {
		return badRequest("%v", err)
	}
	key, err := b.Locations.BaseKey(ctx, loc.Name)
	if err != nil {
		return err
	}
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	m := b.baseManifest(key)
	if _, ok := m.Files[p]; !ok {
		for _, f := range b.baseFiles(key) {
			if f.Path == p {
				return httpError{http.StatusConflict, p + " is the team's: root changes it with `pierd team`"}
			}
		}
		return httpError{http.StatusNotFound, p + " is not in the project's base"}
	}
	delete(m.Files, p)
	os.Remove(filepath.Join(b.baseDir(key), "files", filepath.FromSlash(p)))
	return saveJSON(filepath.Join(b.baseDir(key), "base.json"), m)
}

// The API.

// BaseView answers GET /v1/locations/{name}/base: what the project's base
// holds and where each part comes from. It never holds a file's content.
type BaseView struct {
	Key   string          `json:"key"`
	Files []BaseFileView  `json:"files"`
	Carry []BaseCarryView `json:"carry"`
	// Team is the team's base for the project on this machine, when there
	// is one.
	Team *TeamView `json:"team,omitempty"`
	// Recipe is what prepares each worktree by script, and whose it is.
	Recipe *BaseRecipe `json:"recipe,omitempty"`
	// Copy is how carried folders are copied on this disk: "reflink"
	// (instant, sharing the main checkout's blocks) or "copy".
	Copy     string   `json:"copy,omitempty"`
	Warnings []string `json:"warnings"`
}

type BaseFileView struct {
	Path string `json:"path"`
	// Kind is "env" (merged key by key) or "file".
	Kind string `json:"kind"`
	Size int64  `json:"size"`
	// SHA is the start of the content's hash, to tell versions apart.
	SHA string `json:"sha"`
	// Keys are a dotenv file's keys, never their values.
	Keys  []string   `json:"keys,omitempty"`
	From  string     `json:"from"`
	Added *time.Time `json:"added,omitempty"`
}

type BaseCarryView struct {
	Path string `json:"path"`
	// From is whose config names it ("repo", "team", "box") or
	// "worktreeinclude" (the repository's .worktreeinclude).
	From   string `json:"from"`
	InMain bool   `json:"in_main"`
}

type BaseRecipe struct {
	Setup    string   `json:"setup,omitempty"`
	Services []string `json:"services,omitempty"`
	// From is "repo", "team" or "box"; By is "setup" when a setup agent
	// saved it.
	From string `json:"from,omitempty"`
	By   string `json:"by,omitempty"`
}

var keyPart = regexp.MustCompile(`[^a-z0-9._-]+`)

// baseFileViews are the base's files as GET …/base shows them: a dotenv
// file's keys, never a value.
func (b *Box) baseFileViews(key string) []BaseFileView {
	mu := b.baseLock(key)
	mu.Lock()
	defer mu.Unlock()
	var out []BaseFileView
	for _, f := range b.baseFiles(key) {
		fv := BaseFileView{Path: f.Path, Kind: "file", Size: f.Size, SHA: f.SHA, From: f.Layer}
		if len(fv.SHA) > 8 {
			fv.SHA = fv.SHA[:8]
		}
		if !f.Added.IsZero() {
			added := f.Added
			fv.Added = &added
		}
		if isEnvFile(f.Path) {
			fv.Kind = "env"
			if data, err := os.ReadFile(f.Source); err == nil {
				fv.Keys = parseEnvFile(data).keys()
			}
		}
		out = append(out, fv)
	}
	return out
}

func (b *Box) baseView(ctx context.Context, loc Location) (BaseView, error) {
	key, err := b.Locations.BaseKey(ctx, loc.Name)
	if err != nil {
		return BaseView{}, err
	}
	view := BaseView{Key: key, Files: []BaseFileView{}, Carry: []BaseCarryView{}, Warnings: []string{}}
	view.Team = b.syncTeam(ctx, loc.Name)
	view.Files = append(view.Files, b.baseFileViews(key)...)
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil {
		return view, err
	}
	from := map[string]string{}
	for _, layer := range []struct {
		name string
		c    *RepoConfig
	}{{"repo", cfg.Repo}, {"team", cfg.Team}, {"box", &cfg.Local}} {
		if layer.c == nil || layer.c.Base == nil {
			continue
		}
		for _, p := range layer.c.Base.Carry {
			if clean, err := cleanBasePath(p); err == nil {
				if _, ok := from[clean]; !ok {
					from[clean] = layer.name
				}
			}
		}
	}
	for _, p := range worktreeIncludes(ctx, loc.Path, loc.Path) {
		if _, ok := from[p]; !ok {
			from[p] = "worktreeinclude"
		}
	}
	for p, who := range from {
		_, err := os.Lstat(filepath.Join(loc.Path, filepath.FromSlash(p)))
		view.Carry = append(view.Carry, BaseCarryView{Path: p, From: who, InMain: err == nil})
	}
	sort.Slice(view.Carry, func(i, j int) bool { return view.Carry[i].Path < view.Carry[j].Path })
	if len(view.Carry) > 0 {
		view.Copy = copyKind(loc.Path)
	}
	if setup := cfg.Effective.Setup; setup != "" || len(cfg.Effective.Services) > 0 {
		r := &BaseRecipe{Setup: setup}
		for _, s := range cfg.Effective.Services {
			if s.Autostart {
				r.Services = append(r.Services, s.Name)
			}
		}
		switch {
		case cfg.Local.Setup != "" || len(cfg.Local.Services) > 0:
			r.From, r.By = "box", cfg.Local.By
		case cfg.Team != nil && (cfg.Team.Setup != "" || len(cfg.Team.Services) > 0):
			r.From = "team"
		default:
			r.From = "repo"
		}
		view.Recipe = r
		view.Warnings = append(view.Warnings, recipeWarnings(cfg, setup, len(view.Files) > 0, len(view.Carry) > 0)...)
	}
	return view, nil
}

// GET /v1/locations/{name}/base
func (b *Box) getBase(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	view, err := b.baseView(r.Context(), loc)
	if err != nil {
		return err
	}
	writeJSON(w, view)
	return nil
}

// PUT /v1/locations/{name}/base {"carry": [...]}: the folders this box's
// own config carries into the project's new worktrees.
func (b *Box) putBase(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	var req struct {
		Carry *[]string `json:"carry"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	if req.Carry == nil {
		return badRequest("send carry: the folders to copy from the main checkout")
	}
	c := &BaseConfig{Carry: *req.Carry}
	if err := c.validate(); err != nil {
		return badRequest("%v", err)
	}
	if err := b.before(r, "base.change", map[string]any{"location": loc.Name, "carry": c.Carry}); err != nil {
		return err
	}
	if err := b.Locations.SetLocalCarry(loc.Name, c.Carry); err != nil {
		return err
	}
	b.publish(r, "base.changed", map[string]any{"location": loc.Name})
	return b.getBase(w, r)
}

// POST /v1/locations/{name}/base/files {"path", "from"?}: take a file from
// a checkout of the project (from: a worktree's name; the main checkout by
// default) into the box's own base.
func (b *Box) postBaseFile(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	var req struct {
		Path string `json:"path"`
		From string `json:"from"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	dir := loc.Path
	from := req.From
	if from != "" {
		_, wt, err := b.worktreeRef(r.Context(), loc.Name, from)
		if err != nil {
			return err
		}
		dir = wt.Path
	}
	if err := b.before(r, "base.change", map[string]any{"location": loc.Name, "file": req.Path}); err != nil {
		return err
	}
	if err := b.addBaseFile(r.Context(), loc, dir, from, req.Path); err != nil {
		return err
	}
	b.publish(r, "base.changed", map[string]any{"location": loc.Name, "files": []string{req.Path}})
	return b.getBase(w, r)
}

// DELETE /v1/locations/{name}/base/files?path=P
func (b *Box) deleteBaseFile(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	p := r.URL.Query().Get("path")
	if err := b.before(r, "base.change", map[string]any{"location": loc.Name, "file": p, "removed": true}); err != nil {
		return err
	}
	if err := b.removeBaseFile(r.Context(), loc, p); err != nil {
		return err
	}
	b.publish(r, "base.changed", map[string]any{"location": loc.Name, "files": []string{p}})
	return b.getBase(w, r)
}

// BaseApplied is one checkout's part of POST …/base/apply.
type BaseApplied struct {
	Worktree string       `json:"worktree"`
	Path     string       `json:"path"`
	Results  []BaseResult `json:"results"`
}

// POST /v1/locations/{name}/base/apply {"worktrees"?: [...]}: write the
// base's files into checkouts that already exist (by default every one but
// a pull request's), the same way a new worktree gets them.
func (b *Box) applyBase(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	var req struct {
		Worktrees []string `json:"worktrees"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	named := map[string]bool{}
	for _, n := range req.Worktrees {
		named[n] = true
	}
	var targets []Worktree
	for _, wt := range loc.Worktrees {
		if len(named) > 0 {
			if named[wt.Name] {
				targets = append(targets, wt)
				delete(named, wt.Name)
			}
			continue
		}
		if rec, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && rec.Checkout {
			continue
		}
		targets = append(targets, wt)
	}
	for n := range named {
		return httpError{http.StatusNotFound, "no worktree " + n + " in " + loc.Name}
	}
	if err := b.before(r, "base.apply", map[string]any{"location": loc.Name, "worktrees": len(targets)}); err != nil {
		return err
	}
	b.syncTeam(r.Context(), loc.Name)
	out := struct {
		Results []BaseApplied `json:"results"`
	}{Results: []BaseApplied{}}
	for _, wt := range targets {
		res := b.applyBaseFiles(r.Context(), loc, wt)
		b.recordBase(loc.Name, wt.Name, func(rep *BaseReport) { rep.Files = res })
		out.Results = append(out.Results, BaseApplied{Worktree: wt.Name, Path: wt.Path, Results: nonNil(res)})
	}
	writeJSON(w, out)
	return nil
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// recordBase keeps how the base went into a worktree with its preparation.
func (b *Box) recordBase(location, worktree string, change func(*BaseReport)) {
	b.preps().update(prepKey(location, worktree), func(r *prepRecord) {
		if r.State == "" {
			r.State = "unknown"
		}
		if r.Base == nil {
			r.Base = &BaseReport{}
		}
		change(r.Base)
	})
}

// baseKeyFor is the name of a project's base: owner__repo of its origin,
// the same on every box and in the team's folder, else local-<envKey>.
func baseKeyFor(slug, location string) string {
	owner, repo, ok := strings.Cut(strings.ToLower(slug), "/")
	if ok && owner != "" && repo != "" && !strings.Contains(repo, "/") {
		k := keyPart.ReplaceAllString(owner, "-") + "__" + keyPart.ReplaceAllString(repo, "-")
		if len(k) <= 100 {
			return k
		}
	}
	return "local-" + envKey(location)
}

// BaseKey is the location's base key, worked out once and kept: a project
// renamed, or one whose origin moved, keeps its base.
func (l *Locations) BaseKey(ctx context.Context, name string) (string, error) {
	saved, err := l.saved(name)
	if err != nil {
		return "", err
	}
	if saved.BaseKey != "" {
		return saved.BaseKey, nil
	}
	key := baseKeyFor(slugOf(remoteURL(ctx, saved.Path)), name)
	err = l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name == name {
				if all[i].BaseKey == "" {
					all[i].BaseKey = key
				}
				key = all[i].BaseKey
				return all, nil
			}
		}
		return nil, ErrUnknownLocation
	})
	return key, err
}

// SetLocalCarry replaces the folders the box's own config carries.
func (l *Locations) SetLocalCarry(name string, carry []string) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name != name {
				continue
			}
			c := RepoConfig{}
			if all[i].Config != nil {
				c = *all[i].Config
			}
			if len(carry) == 0 {
				c.Base = nil
			} else {
				c.Base = &BaseConfig{Carry: append([]string(nil), carry...)}
			}
			all[i].Config = &c
			return all, nil
		}
		return nil, ErrUnknownLocation
	})
}

// recipeWarnings are what a recipe written before the base does that the
// base makes wrong.
func recipeWarnings(cfg Config, setup string, files, carry bool) []string {
	var out []string
	if cfg.Team != nil && cfg.Team.Setup != "" && cfg.Local.Setup != "" {
		out = append(out, "this box's own recipe is used instead of the team's")
	}
	if carry && strings.Contains(setup, "npm ci") {
		out = append(out, "the recipe runs npm ci, which deletes the node_modules the base copies in: npm install reconciles it")
	}
	if files && strings.Contains(setup, ".env.example") {
		out = append(out, "the recipe writes .env from .env.example, over the one the base puts there")
	}
	return out
}

// baseStep says a preparation's step puts the project's base in place.
func baseStep(step string) bool { return step == "carry" }

// prepareStep records what wt's running preparation does now and says so
// (worktree.prepare.step), so the app follows it.
func (b *Box) prepareStep(from string, loc Location, wt Worktree, step string) {
	b.preps().update(prepKey(loc.Name, wt.Name), func(r *prepRecord) {
		if r.State == "running" {
			r.Step = step
		}
	})
	data := b.prepareData(loc, wt)
	data["step"] = step
	b.Events.Publish(events.Event{Type: "worktree.prepare.step", Box: b.Name, Origin: from, Data: data})
}

// prepareBase puts the project's base in place in a new worktree, before
// its recipe runs or its setup agent starts: the folders carried from the
// main checkout (its files went in as it was made). Nothing in the main
// checkout, the folders' source, nor in a pull request's checkout.
func (b *Box) prepareBase(from string, loc Location, wt Worktree) {
	if wt.Path == loc.Path {
		return
	}
	if rec, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && rec.Checkout {
		return
	}
	ctx := context.Background()
	entries := b.carryEntries(ctx, loc, wt)
	if len(entries) == 0 {
		return
	}
	b.prepareStep(from, loc, wt, "carry")
	var res []BaseResult
	for _, p := range entries {
		res = append(res, carryOne(ctx, loc.Path, wt.Path, p))
	}
	b.recordBase(loc.Name, wt.Name, func(rep *BaseReport) { rep.Carried = res })
}

// placeBaseFiles writes the project's base files into a checkout as it is
// made or prepared again, and keeps how it went; nothing in a pull
// request's checkout.
func (b *Box) placeBaseFiles(ctx context.Context, loc Location, wt Worktree) {
	if rec, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && rec.Checkout {
		return
	}
	res := b.applyBaseFiles(ctx, loc, wt)
	if res == nil {
		return
	}
	b.recordBase(loc.Name, wt.Name, func(rep *BaseReport) { rep.Files, rep.Carried = res, nil })
}
