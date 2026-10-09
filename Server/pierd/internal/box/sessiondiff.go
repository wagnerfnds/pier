package box

import (
	"bytes"
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// GET /v1/sessions/{name}/diff?file=PATH is one file's current diff in the
// session's worktree, against HEAD (an untracked file shows as added), for
// the conversation view's edits. Like the screen and the transcript, it is
// the session's content, so only paired peers reach it; nothing is kept.

// SessionDiff is one file's diff.
type SessionDiff struct {
	File      string `json:"file"`
	Diff      string `json:"diff"`
	Untracked bool   `json:"untracked,omitempty"`
	// Truncated says only the first sessionDiffLimit bytes are in Diff.
	Truncated bool `json:"truncated,omitempty"`
}

const sessionDiffLimit = 64 << 10

func (b *Box) sessionDiff(w http.ResponseWriter, r *http.Request) error {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	file, err := diffPath(sess.Dir, r.URL.Query().Get("file"))
	if err != nil {
		return err
	}
	d, err := fileDiff(r.Context(), sess.Dir, file)
	if err != nil {
		return err
	}
	writeJSON(w, d)
	return nil
}

// diffPath checks a file named by the agent's transcript: relative to the
// session's directory (or absolute inside it), and never outside it.
func diffPath(dir, file string) (string, error) {
	if file == "" || strings.ContainsRune(file, 0) {
		return "", badRequest("which file? Pass ?file=PATH, relative to the session's directory")
	}
	if filepath.IsAbs(file) {
		rel, err := filepath.Rel(dir, file)
		if err != nil {
			return "", badRequest("%s is not in this session's directory", file)
		}
		file = rel
	}
	file = filepath.Clean(file)
	if file == ".." || strings.HasPrefix(file, ".."+string(filepath.Separator)) || filepath.IsAbs(file) {
		return "", badRequest("%s is not in this session's directory", file)
	}
	return file, nil
}

// fileDiff is git's diff of file in dir against HEAD, or, for a file git
// does not track yet, all of it as added. It keeps the first 64 KB.
func fileDiff(ctx context.Context, dir, file string) (SessionDiff, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	d := SessionDiff{File: file}
	out, err := gitOut(ctx, dir, "diff", "--no-color", "--no-ext-diff", "HEAD", "--", file)
	if err != nil {
		// No HEAD yet (a repository without commits): against the index.
		out, err = gitOut(ctx, dir, "diff", "--no-color", "--no-ext-diff", "--", file)
		if err != nil {
			return d, badRequest("git can't diff %s here: %v", file, err)
		}
	}
	if len(out) == 0 {
		if o, _ := gitOut(ctx, dir, "ls-files", "--others", "--exclude-standard", "--", file); len(bytes.TrimSpace(o)) > 0 {
			d.Untracked = true
			// --no-index exits 1 when the files differ, which they do.
			out, _ = gitOut(ctx, dir, "diff", "--no-color", "--no-ext-diff", "--no-index", "--", os.DevNull, file)
		}
	}
	if len(out) > sessionDiffLimit {
		cut := bytes.LastIndexByte(out[:sessionDiffLimit], '\n')
		if cut < 0 {
			cut = sessionDiffLimit
		}
		out, d.Truncated = out[:cut+1], true
	}
	d.Diff = string(out)
	return d, nil
}

// gitOut runs git in dir and returns its standard output only. An exit
// status of 1 with output (diff --no-index) is not an error.
func gitOut(ctx context.Context, dir string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 && out.Len() > 0 {
			return out.Bytes(), nil
		}
		if msg := strings.TrimSpace(errb.String()); msg != "" {
			return nil, &gitError{msg}
		}
		return nil, err
	}
	return out.Bytes(), nil
}

type gitError struct{ msg string }

func (e *gitError) Error() string { return e.msg }
