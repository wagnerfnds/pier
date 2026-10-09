package box

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

func firstNonEmpty(v any, fallback string) string {
	if s, ok := v.(string); ok && s != "" {
		return s
	}
	return fallback
}

// gitPart says whether any part of a relative path is .git.
func gitPart(rel string) bool {
	for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
		if strings.EqualFold(part, ".git") {
			return true
		}
	}
	return false
}

// realPath is p with its symlinks resolved; for a file that doesn't exist
// yet, its folder's, and its own name.
func realPath(p string) (string, error) {
	r, err := filepath.EvalSymlinks(p)
	if err == nil {
		return r, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	if st, lerr := os.Lstat(p); lerr == nil && st.Mode()&fs.ModeSymlink != 0 {
		// A link to something missing: where it leads can't be checked.
		return "", errDangling
	}
	dir, err := filepath.EvalSymlinks(filepath.Dir(p))
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, filepath.Base(p)), nil
}

// relInside is target relative to root, when it is inside it (and not
// root itself).
func relInside(root, target string) (string, bool) {
	r, err := filepath.Rel(root, target)
	if err != nil || r == "." || r == ".." || strings.HasPrefix(r, ".."+string(filepath.Separator)) || filepath.IsAbs(r) {
		return "", false
	}
	return r, true
}

// isBinary says data isn't text the editor can hold: a NUL early on, or
// not UTF-8.
func isBinary(data []byte) bool {
	head := data[:min(len(data), 8000)]
	for _, c := range head {
		if c == 0 {
			return true
		}
	}
	return !utf8.Valid(data)
}

func remoteURL(ctx context.Context, repo string) string {
	out, err := git(ctx, "-C", repo, "remote", "get-url", "origin")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

var scpLike = regexp.MustCompile(`^[\w.-]+@([\w.-]+):(.+)$`)

// slugOf turns a remote URL into "owner/repo", whatever its form.
func slugOf(remote string) string {
	if remote == "" {
		return ""
	}
	path := ""
	if m := scpLike.FindStringSubmatch(remote); m != nil {
		path = m[2]
	} else if u, err := url.Parse(remote); err == nil && u.Host != "" {
		path = u.Path
	} else {
		return ""
	}
	path = strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	parts := strings.Split(path, "/")
	if len(parts) < 2 {
		return path
	}
	return strings.Join(parts[len(parts)-2:], "/")
}

func defaultBranch(ctx context.Context, repo string) string {
	if out, err := git(ctx, "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil {
		return strings.TrimPrefix(strings.TrimSpace(string(out)), "origin/")
	}
	if out, err := git(ctx, "-C", repo, "symbolic-ref", "--short", "HEAD"); err == nil {
		return strings.TrimSpace(string(out))
	}
	return ""
}

// Branch is one branch a worktree could start from or check out.
type Branch struct {
	Name    string `json:"name"`
	Remote  bool   `json:"remote"`
	Current bool   `json:"current,omitempty"`
}

func (b *Box) listBranches(w http.ResponseWriter, r *http.Request) error {
	loc, err := b.Locations.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	out, err := git(r.Context(), "-C", loc.Path, "for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes/origin")
	if err != nil {
		return fmt.Errorf("git for-each-ref: %s", strings.TrimSpace(string(out)))
	}
	current := defaultBranchOfCheckout(r.Context(), loc.Path)
	seen := map[string]bool{}
	branches := []Branch{}
	for _, ref := range strings.Fields(string(out)) {
		name, local := strings.CutPrefix(ref, "refs/heads/")
		if !local {
			name = strings.TrimPrefix(ref, "refs/remotes/origin/")
			if name == "HEAD" {
				continue
			}
		}
		if seen[name] {
			continue
		}
		seen[name] = true
		branches = append(branches, Branch{Name: name, Remote: !local, Current: name == current})
	}
	writeJSON(w, map[string]any{"default": defaultBranch(r.Context(), loc.Path), "branches": branches})
	return nil
}

func defaultBranchOfCheckout(ctx context.Context, repo string) string {
	out, err := git(ctx, "-C", repo, "symbolic-ref", "--short", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// slug makes a worktree-safe name from free text.
func slug(s string, max int) string {
	s = strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(s), "-"), "-")
	if len(s) > max {
		s = strings.TrimRight(s[:max], "-")
	}
	return s
}

// tmuxSocketPath is where pierd's tmux server listens, as tmux names it in
// the TMUX variable of its panes: $TMUX_TMPDIR (or /tmp), resolved, then
// tmux-UID/<tmuxSocket()>.
func tmuxSocketPath() string {
	dir := os.Getenv("TMUX_TMPDIR")
	if dir == "" {
		dir = "/tmp"
	}
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		dir = r
	}
	return filepath.Join(dir, "tmux-"+strconv.Itoa(os.Getuid()), tmuxSocket())
}

// sameSocket says whether a pane's TMUX value (socket,pid,index) names the
// socket at path.
func sameSocket(tmux, path string) bool {
	sock, _, _ := strings.Cut(tmux, ",")
	if sock == "" || path == "" {
		return false
	}
	norm := func(p string) string {
		p = filepath.Clean(p)
		if r, err := filepath.EvalSymlinks(filepath.Dir(p)); err == nil {
			return filepath.Join(r, filepath.Base(p))
		}
		return p
	}
	return norm(sock) == norm(path)
}

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

// maxEditableFile is the largest file whose lines are counted for touched
// files; larger ones are listed without counts.
const maxEditableFile = 2 << 20

var errDangling = httpError{http.StatusForbidden, "that path is a link to something that isn't there"}

// createAgentSession starts a session for the agent preset agent ("" for
// a plain command), with its worktree's environment.
func (b *Box) createAgentSession(ctx context.Context, name, location, dir, command, agent string) (Session, error) {
	return b.Sessions.create(ctx, name, location, dir, command, agent, b.sessionEnv(ctx, dir), nil)
}

// sessionEnv is the environment a session in dir gets: its worktree's
// (ports, the repository's and the box's env), or none outside one.
func (b *Box) sessionEnv(ctx context.Context, dir string) []string {
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
