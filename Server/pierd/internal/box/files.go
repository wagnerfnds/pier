package box

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"
)

// A worktree's files, for the app's file tree and editor (docs/API.md
// §2.7): one folder at a time with git's word on each entry, one file with
// its content, and a save that never silently overwrites what an agent
// wrote since the file was opened.
//
// A path is relative to the worktree's root. It never goes up (..) or into
// .git, and it stays inside the worktree once its links are followed: a
// link may lead elsewhere in the worktree, where the app follows it through
// these same routes, but never out of it.

// FileEntry is one entry of a folder.
type FileEntry struct {
	Name string `json:"name"`
	// Type is "dir", "file", "link" or "other" (a socket, a device, a fifo).
	Type string `json:"type"`
	// Size is a file's, in bytes.
	Size int64 `json:"size,omitempty"`
	// Status is git's two-character porcelain code for a file with changes
	// (" M", "A ", "??", "UU", …).
	Status string `json:"status,omitempty"`
	// Changed marks a folder with changes somewhere below it.
	Changed bool `json:"changed,omitempty"`
	Ignored bool `json:"ignored,omitempty"`
	// Target is a link's own text. Points is what it leads to, "dir" or
	// "file", when that is in the worktree.
	Target string `json:"target,omitempty"`
	Points string `json:"points,omitempty"`
}

// DirListing is one folder of a worktree.
type DirListing struct {
	// Path is the folder, relative to the worktree's root ("" for the root).
	Path    string      `json:"path"`
	Entries []FileEntry `json:"entries"`
	// Truncated says the folder has more than maxDirEntries entries.
	Truncated bool `json:"truncated"`
}

// WorktreeFile is one file, as a read finds it or a save leaves it.
type WorktreeFile struct {
	Path     string    `json:"path"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
	// SHA is the sha256 of the file's bytes: a save names it to say which
	// version it replaces.
	SHA        string `json:"sha"`
	Executable bool   `json:"executable"`
	Binary     bool   `json:"binary"`
	// TooLarge: over maxFileContent, so the file comes without its content.
	TooLarge bool `json:"too_large,omitempty"`
	// Encoding is "utf8" (Content is the text) or "base64" (a binary file).
	Encoding string  `json:"encoding,omitempty"`
	Content  *string `json:"content,omitempty"`
}

// FileWrite is a save.
type FileWrite struct {
	Content string `json:"content"`
	// Encoding is "utf8" (the default) or "base64".
	Encoding string `json:"encoding,omitempty"`
	// SHA is the version of the file the edit started from.
	SHA string `json:"sha,omitempty"`
	// Create makes a new file, and the folders it needs.
	Create bool `json:"create,omitempty"`
	// Force writes whatever is there now.
	Force bool `json:"force,omitempty"`
}

// A save that would lose someone else's work is a 409 with a code of its
// own, so the app can offer to reload or to overwrite: the agents edit
// these same files.
var (
	ErrFileChanged = errors.New("the file changed on the box since you opened it")
	ErrFileDeleted = errors.New("the file was deleted on the box since you opened it")
	ErrFileExists  = errors.New("there is already a file at that path")
)

// errDanglingLink: the path goes through a link to something missing, so
// where it leads can't be checked.
var errDanglingLink = httpError{http.StatusNotFound, "that path goes through a link to something that isn't there"}

// maxFileContent is the largest file a read carries the content of, the
// same 2 MB touched counts lines in; a larger one comes with its metadata
// only. A variable so tests can lower it.
var maxFileContent int64 = maxEditableFile

// maxFileWrite bounds a save's body: a file of maxFileContent fits as
// base64, or as text with room for JSON's escapes.
const maxFileWrite = 4 << 20

// maxDirEntries is the most entries a listing answers with. A variable so
// tests can lower it.
var maxDirEntries = 5000

// GET /v1/locations/{name}/worktrees/{worktree}/files?path=DIR
func (b *Box) listFiles(w http.ResponseWriter, r *http.Request) error {
	_, wt, err := b.fileWorktree(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	t, err := resolveIn(wt.Path, r.URL.Query().Get("path"))
	if err != nil {
		return err
	}
	listing, err := listDir(r.Context(), t)
	if err != nil {
		return err
	}
	writeJSON(w, listing)
	return nil
}

// GET /v1/locations/{name}/worktrees/{worktree}/file?path=FILE[&stat=1].
// stat=1 leaves the content out: the app asks that way, often, to notice an
// agent changing the file it shows.
func (b *Box) readFile(w http.ResponseWriter, r *http.Request) error {
	_, wt, err := b.fileWorktree(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	t, err := fileTarget(wt.Path, r.URL.Query().Get("path"))
	if err != nil {
		return err
	}
	f, err := readWorktreeFile(t, r.URL.Query().Get("stat") != "1")
	if err != nil {
		return err
	}
	writeJSON(w, f)
	return nil
}

// PUT /v1/locations/{name}/worktrees/{worktree}/file?path=FILE saves a file
// and answers what GET …/file?stat=1 says of it then.
func (b *Box) writeFile(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.fileWorktree(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	t, err := fileTarget(wt.Path, r.URL.Query().Get("path"))
	if err != nil {
		return err
	}
	var req FileWrite
	if err := decodeLimit(r, &req, maxFileWrite); err != nil {
		return err
	}
	data, err := req.bytes()
	if err != nil {
		return err
	}
	// As in every event, "path" is the worktree's folder (hooks run there,
	// in order per worktree); "file" is where the save really lands, links
	// followed, so a gate that refuses a path can't be gone around by a link.
	scope := map[string]any{"location": loc.Name, "worktree": wt.Name, "path": wt.Path, "file": t.realRel}
	if err := b.before(r, "file.write", scope); err != nil {
		return err
	}
	unlock := lockPath(t.real)
	err = saveFile(t, req, data)
	unlock()
	if err != nil {
		return err
	}
	st, err := os.Stat(t.real)
	if err != nil {
		return fsErr(err, t.rel)
	}
	// What was written, not what is there by now: an agent's write right
	// after this one must still read as a change to the app.
	sum := sha256.Sum256(data)
	scope["size"] = len(data)
	b.publish(r, "file.written", scope)
	writeJSON(w, fileState(t.rel, st, hex.EncodeToString(sum[:]), int64(len(data)), data))
	return nil
}

// fileWorktree is worktreeRef for the file routes, which refuse a name two
// worktrees share (one added outside pier can take another's name): reading
// or saving the wrong checkout's files is worse than an error.
func (b *Box) fileWorktree(ctx context.Context, location, name string) (Location, Worktree, error) {
	loc, wt, err := b.worktreeRef(ctx, location, name)
	if err != nil {
		return loc, wt, err
	}
	n := 0
	for _, w := range loc.Worktrees {
		if w.Name == name {
			n++
		}
	}
	if n > 1 {
		return loc, wt, badRequest("%d worktrees of %s are called %s; rename one (git worktree move) to reach its files", n, loc.Name, name)
	}
	return loc, wt, nil
}

// Saves through pierd take turns per file, so two clients saving the same
// version can't both pass the sha check: the second gets file_changed.
// Agents write without asking; their writes still race a save.
var saveLocks sync.Map // real path -> *sync.Mutex

func lockPath(p string) (unlock func()) {
	m, _ := saveLocks.LoadOrStore(p, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// worktreeTarget is a path a client named in a worktree, checked.
type worktreeTarget struct {
	// rel is the path as named: cleaned, with / separators, "" for the root.
	rel string
	// real is where it is on disk with its links followed, realRel that
	// relative to root, the worktree's own real path.
	real, realRel, root string
}

// resolveIn checks a path named in the worktree at dir and finds where it
// really is. One that doesn't exist yet (a new file, its new folders)
// resolves through the nearest part that does.
func resolveIn(dir, p string) (worktreeTarget, error) {
	switch {
	case strings.ContainsRune(p, 0):
		return worktreeTarget{}, badRequest("a path can't have a NUL in it")
	case filepath.IsAbs(p):
		return worktreeTarget{}, badRequest("%s is not relative to the worktree's root", p)
	case slices.Contains(strings.Split(p, "/"), ".."):
		return worktreeTarget{}, badRequest("%s goes up a folder (..); paths stay inside the worktree", p)
	case gitPart(p):
		return worktreeTarget{}, badRequest("%s is in .git, which is git's own", p)
	}
	rel := path.Clean(p)
	if rel == "." {
		rel = ""
	}
	root, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return worktreeTarget{}, err
	}
	real, err := realTarget(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return worktreeTarget{}, fsErr(err, rel)
	}
	realRel, err := within(root, real, rel)
	if err != nil {
		return worktreeTarget{}, err
	}
	return worktreeTarget{rel: rel, real: real, realRel: realRel, root: root}, nil
}

// fileTarget is resolveIn for a file, whose path is required.
func fileTarget(dir, p string) (worktreeTarget, error) {
	if p == "" {
		return worktreeTarget{}, badRequest("which file? Pass ?path=FILE, relative to the worktree's root")
	}
	return resolveIn(dir, p)
}

// realTarget is p with its links resolved, like realPath, through as many
// missing folders as a new file needs: the nearest part that exists is
// resolved, and the missing ones go on top of it.
func realTarget(p string) (string, error) {
	var missing []string
	for {
		r, err := filepath.EvalSymlinks(p)
		if err == nil {
			return filepath.Join(append([]string{r}, missing...)...), nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		if st, lerr := os.Lstat(p); lerr == nil && st.Mode()&fs.ModeSymlink != 0 {
			return "", errDanglingLink
		}
		parent := filepath.Dir(p)
		if parent == p {
			return "", err
		}
		missing = append([]string{filepath.Base(p)}, missing...)
		p = parent
	}
}

// within is real relative to root ("" for root itself), or why the file
// routes don't go there: outside the worktree, or into its .git. rel names
// the path in the refusal.
func within(root, real, rel string) (string, error) {
	if real == root {
		return "", nil
	}
	r, ok := relInside(root, real)
	if !ok {
		return "", badRequest("%s leads outside the worktree", rel)
	}
	if gitPart(r) {
		return "", badRequest("%s leads into .git, which is git's own", rel)
	}
	return filepath.ToSlash(r), nil
}

// fsErr puts a filesystem error about rel in the client's terms.
func fsErr(err error, rel string) error {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return httpError{http.StatusNotFound, fmt.Sprintf("there is no %s in this worktree", rel)}
	case errors.Is(err, syscall.ENOTDIR):
		return badRequest("part of %s is a file, not a folder", rel)
	case errors.Is(err, fs.ErrPermission):
		return httpError{http.StatusForbidden, fmt.Sprintf("the box's user has no permission for %s", rel)}
	case errors.Is(err, syscall.ENAMETOOLONG):
		return badRequest("the name %s is too long for the box's file system", rel)
	case errors.Is(err, syscall.ELOOP):
		return badRequest("%s goes through too many links", rel)
	case errors.Is(err, syscall.ENOSPC), errors.Is(err, syscall.EDQUOT):
		return httpError{http.StatusInsufficientStorage, fmt.Sprintf("the box's disk is full: %s was not saved", rel)}
	case errors.Is(err, syscall.EROFS):
		return httpError{http.StatusInternalServerError, fmt.Sprintf("the box's file system is read-only: %s was not saved", rel)}
	}
	// Anything else is the box's trouble, told without its absolute paths.
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return httpError{http.StatusInternalServerError, fmt.Sprintf("can't %s %s: %v", pe.Op, rel, pe.Err)}
	}
	return err
}

// listDir lists the folder t names, with git's word on each entry.
func listDir(ctx context.Context, t worktreeTarget) (DirListing, error) {
	st, err := os.Stat(t.real)
	if err != nil {
		return DirListing{}, fsErr(err, t.rel)
	}
	if !st.IsDir() {
		return DirListing{}, badRequest("%s is a file, not a folder", t.rel)
	}
	all, err := os.ReadDir(t.real)
	if err != nil {
		return DirListing{}, fsErr(err, t.rel)
	}
	entries := make([]FileEntry, 0, len(all))
	for _, d := range all {
		if strings.EqualFold(d.Name(), ".git") {
			continue
		}
		e := FileEntry{Name: d.Name(), Type: entryType(d.Type())}
		switch e.Type {
		case "file":
			if info, err := d.Info(); err == nil {
				e.Size = info.Size()
			}
		case "link":
			link := filepath.Join(t.real, e.Name)
			e.Target, _ = os.Readlink(link)
			e.Points = linkPoints(t.root, link)
		}
		entries = append(entries, e)
	}
	sortEntries(entries)
	out := DirListing{Path: t.rel, Entries: entries}
	if len(entries) > maxDirEntries {
		out.Entries, out.Truncated = entries[:maxDirEntries], true
	}
	if v, ok := gitView(ctx, t.root, t.realRel); ok {
		v.apply(out.Entries)
	}
	return out, nil
}

// entryType names an entry's kind from its mode.
func entryType(m fs.FileMode) string {
	switch {
	case m.IsDir():
		return "dir"
	case m&fs.ModeSymlink != 0:
		return "link"
	case m.IsRegular():
		return "file"
	}
	return "other"
}

// linkPoints is what a link leads to, "dir" or "file", when that is in the
// worktree at root, where the app can follow it; "" for a dangling link or
// one that leads out.
func linkPoints(root, link string) string {
	real, err := filepath.EvalSymlinks(link)
	if err != nil {
		return ""
	}
	if _, err := within(root, real, ""); err != nil {
		return ""
	}
	st, err := os.Stat(real)
	switch {
	case err != nil:
		return ""
	case st.IsDir():
		return "dir"
	case st.Mode().IsRegular():
		return "file"
	}
	return ""
}

// sortEntries puts folders (and links to folders the app can open) first,
// then the rest, each by name whatever its case.
func sortEntries(entries []FileEntry) {
	folder := func(e FileEntry) bool { return e.Type == "dir" || e.Points == "dir" }
	slices.SortFunc(entries, func(a, b FileEntry) int {
		if fa, fb := folder(a), folder(b); fa != fb {
			if fa {
				return -1
			}
			return 1
		}
		if c := compareFold(a.Name, b.Name); c != 0 {
			return c
		}
		return strings.Compare(a.Name, b.Name)
	})
}

// compareFold orders two names letter by letter, whatever their case.
func compareFold(a, b string) int {
	for a != "" && b != "" {
		ra, na := utf8.DecodeRuneInString(a)
		rb, nb := utf8.DecodeRuneInString(b)
		if la, lb := unicode.ToLower(ra), unicode.ToLower(rb); la != lb {
			return cmp.Compare(la, lb)
		}
		a, b = a[na:], b[nb:]
	}
	return cmp.Compare(len(a), len(b))
}

// folderView is git's word on one folder's entries.
type folderView struct {
	marks map[string]gitMark
	// allUntracked and allIgnored: git reported the folder itself, or one
	// above it, as a whole ("?? new/", "!! node_modules/"), so every entry
	// in it is that.
	allUntracked, allIgnored bool
}

// gitMark is what git says of one entry.
type gitMark struct {
	status           string // a file's own code
	changed, ignored bool
}

// gitView asks git, once, about the folder at rel (relative to root, ""
// for root itself). ok is false outside a repository or when git fails:
// the listing goes on without git's word.
func gitView(ctx context.Context, root, rel string) (folderView, bool) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	// Porcelain paths start at the top of the checkout. A worktree's root
	// is that top, with a .git of its own; a folder inside a repository
	// isn't, and its prefix comes off what git says.
	prefix := ""
	if _, err := os.Lstat(filepath.Join(root, ".git")); err != nil {
		out, err := gitOut(ctx, root, "rev-parse", "--show-prefix")
		if err != nil {
			return folderView{}, false
		}
		prefix = strings.TrimSuffix(string(out), "\n")
	}
	spec, base := ".", ""
	if rel != "" {
		spec, base = ":(literal)"+rel, rel+"/"
	}
	// --ignored=matching names what an ignore pattern matches without
	// looking inside an ignored folder; "traditional" would read every file
	// under node_modules to say the same of it.
	out, err := gitOut(ctx, root, "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=normal", "--", spec)
	if err != nil {
		return folderView{}, false
	}
	return viewOf(out, prefix, base), true
}

// viewOf reads `git status --porcelain=v1 -z` for the folder at base.
func viewOf(out []byte, prefix, base string) folderView {
	v := folderView{marks: map[string]gitMark{}}
	for _, f := range parsePorcelain(out, &ReviewItem{}) {
		v.note(f.Code, f.Path, prefix, base, true)
		if f.From != "" {
			// A rename's source left its folder, which changed too.
			v.note(f.Code, f.From, prefix, base, false)
		}
	}
	return v
}

// note takes one path git reported, relative to the top of the checkout
// (prefix is the root's place there), for the entries of the folder at base
// ("dir/", or "" for the root). own is false for a rename's source, which
// only tells that its folder changed.
func (v *folderView) note(code, p, prefix, base string, own bool) {
	p, ok := strings.CutPrefix(p, prefix)
	if !ok {
		return
	}
	if strings.HasSuffix(p, "/") && strings.HasPrefix(base, p) {
		if code == "!!" {
			v.allIgnored = true
		} else {
			v.allUntracked = true
		}
		return
	}
	rest, ok := strings.CutPrefix(p, base)
	if !ok || rest == "" {
		return
	}
	// "x.go" is the entry itself; "new/" a folder git collapsed, untracked
	// or ignored as a whole; "src/a.go" something below the entry src.
	name, below, deeper := strings.Cut(rest, "/")
	m := v.marks[name]
	switch {
	case code == "!!" && below == "":
		m.ignored = true
	case code == "!!":
		// Something ignored further down says nothing about the entry.
		return
	case deeper:
		m.changed = true
	case own:
		m.status = code
	default:
		return
	}
	v.marks[name] = m
}

// apply marks entries with what git said of them. What git said of an
// entry itself goes before what it said of the whole folder, and changes
// git tracks before what it ignores.
func (v folderView) apply(entries []FileEntry) {
	for i := range entries {
		e := &entries[i]
		m := v.marks[e.Name]
		if e.Type == "dir" {
			// A submodule with changes reads as a file with a status.
			own := m.changed || m.status != ""
			e.Changed = own || (v.allUntracked && !m.ignored)
			e.Ignored = !own && (m.ignored || v.allIgnored)
			continue
		}
		e.Status = m.status
		if e.Status == "" && v.allUntracked && !m.ignored {
			e.Status = "??"
		}
		e.Ignored = e.Status == "" && (m.ignored || v.allIgnored)
	}
}

// readWorktreeFile reads the file t names: its metadata and sha always,
// with the whole file through the hash however large, and its content when
// withContent and it is small enough to edit.
func readWorktreeFile(t worktreeTarget, withContent bool) (WorktreeFile, error) {
	st, err := os.Stat(t.real)
	if err != nil {
		return WorktreeFile{}, fsErr(err, t.rel)
	}
	if err := regularFile(st, t.rel); err != nil {
		return WorktreeFile{}, err
	}
	f, err := os.Open(t.real)
	if err != nil {
		return WorktreeFile{}, fsErr(err, t.rel)
	}
	defer f.Close()
	// The metadata of what was opened, should a save have renamed another
	// file over the path since.
	if st, err = f.Stat(); err != nil {
		return WorktreeFile{}, err
	}
	sum := sha256.New()
	head := &headBuffer{max: maxFileContent}
	n, err := io.Copy(io.MultiWriter(sum, head), f)
	if err != nil {
		return WorktreeFile{}, err
	}
	out := fileState(t.rel, st, hex.EncodeToString(sum.Sum(nil)), n, head.data)
	if withContent && !out.TooLarge {
		content, enc := string(head.data), "utf8"
		if out.Binary {
			content, enc = base64.StdEncoding.EncodeToString(head.data), "base64"
		}
		out.Content, out.Encoding = &content, enc
	}
	return out, nil
}

// fileState describes a file from its metadata, the sha and size of its
// bytes, and the bytes themselves when there are no more than
// maxFileContent of them.
func fileState(rel string, st fs.FileInfo, sum string, size int64, data []byte) WorktreeFile {
	f := WorktreeFile{Path: rel, Size: size, Modified: st.ModTime().UTC(), SHA: sum, Executable: st.Mode().Perm()&0o111 != 0}
	if size > maxFileContent {
		f.TooLarge = true
	} else {
		f.Binary = isBinary(data)
	}
	return f
}

// regularFile refuses what can't be read or saved as a file: a folder, or
// a socket, a device or a fifo (opening a fifo would wait forever).
func regularFile(st fs.FileInfo, rel string) error {
	switch {
	case st.IsDir():
		return badRequest("%s is a folder, not a file", rel)
	case !st.Mode().IsRegular():
		return badRequest("%s is not a regular file", rel)
	}
	return nil
}

// headBuffer keeps the first max bytes written to it and lets the rest go.
type headBuffer struct {
	data []byte
	max  int64
}

func (h *headBuffer) Write(p []byte) (int, error) {
	if room := h.max - int64(len(h.data)); room > 0 {
		h.data = append(h.data, p[:min(int64(len(p)), room)]...)
	}
	return len(p), nil
}

// bytes is the content a save carries, decoded.
func (req FileWrite) bytes() ([]byte, error) {
	switch req.Encoding {
	case "", "utf8":
		return []byte(req.Content), nil
	case "base64":
		data, err := base64.StdEncoding.DecodeString(req.Content)
		if err != nil {
			return nil, badRequest("content is not base64")
		}
		return data, nil
	}
	return nil, badRequest("encoding must be utf8 or base64, not %q", req.Encoding)
}

// saveFile writes data where t points once req's checks pass: the file is
// still the version the edit started from or, for a new one, nothing is
// there yet. The checks run as close to the write as they can; there is no
// lock agents would honour.
func saveFile(t worktreeTarget, req FileWrite, data []byte) error {
	mode := fs.FileMode(0o644)
	var old fs.FileInfo
	st, err := os.Stat(t.real)
	switch {
	case err == nil:
		if err := regularFile(st, t.rel); err != nil {
			return err
		}
		mode = st.Mode().Perm()
		old = st
		if req.Force {
			break
		}
		if req.Create {
			return ErrFileExists
		}
		now, err := readWorktreeFile(t, false)
		if err != nil {
			return err
		}
		if !strings.EqualFold(now.SHA, req.SHA) {
			return ErrFileChanged
		}
	case !errors.Is(err, fs.ErrNotExist):
		return fsErr(err, t.rel)
	case !req.Create && !req.Force && req.SHA != "":
		return ErrFileDeleted
	case !req.Create && !req.Force:
		return httpError{http.StatusNotFound, fmt.Sprintf("there is no %s to save; send create to make it", t.rel)}
	default:
		if err := os.MkdirAll(filepath.Dir(t.real), 0o755); err != nil {
			return fsErr(err, t.rel)
		}
	}
	if err := replaceFile(t.real, data, mode, old); err != nil {
		return fsErr(err, t.rel)
	}
	return nil
}

// replaceFile puts data at path. Usually in one step, a temp file beside it
// renamed over it, so an agent or a dev server reading the file never sees
// half of it; the temp file takes the old file's mode and, where the box's
// user may give them, its owner and group. A file with other hard links is
// written in place instead, so the links keep sharing it.
func replaceFile(path string, data []byte, mode fs.FileMode, old fs.FileInfo) error {
	if old != nil && hardLinks(old) > 1 {
		return writeInPlace(path, data)
	}
	pattern := "." + filepath.Base(path) + ".pier-*"
	if len(pattern) > 200 {
		// A long name leaves no room for the temp file's own.
		pattern = ".pier-*"
	}
	f, err := os.CreateTemp(filepath.Dir(path), pattern)
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp) // after the rename, there is nothing left to remove
	_, err = f.Write(data)
	if err == nil {
		err = f.Chmod(mode)
	}
	if err == nil && old != nil {
		keepOwner(f, old)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// writeInPlace rewrites a file's own bytes, for a file other hard links
// share.
func writeInPlace(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}
