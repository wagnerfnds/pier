package box

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// Attachments are files pasted or dropped into the app for an agent: a
// screenshot, a PDF, a log. The agent runs on the box, so the app uploads
// the bytes here and puts the file's path in the prompt, which is how
// Claude Code (and the others) take an image: "Look at /path/to/shot.png".
//
// They land in the worktree's .pier/attachments, readable only by the
// box's user, and git never sees them: the folder goes in the repository's
// .git/info/exclude, never its .gitignore.

// MaxAttachment is the largest file the box takes.
const MaxAttachment = 20 << 20

// attachmentDir is where a worktree keeps its attachments.
const attachmentDir = ".pier/attachments"

// Attachment is what an upload answers: where the file is, for the prompt.
type Attachment struct {
	Path string `json:"path"`
	Name string `json:"name"`
	Type string `json:"type"`
	Size int    `json:"size"`
}

// attachmentRequest is the JSON form of an upload; the bytes are base64.
// A raw body (any other Content-Type) is the file itself, named by ?name=.
type attachmentRequest struct {
	Name string `json:"name"`
	Data string `json:"data"`
}

// ErrAttachmentType refuses a file that isn't an image, a PDF or text.
var ErrAttachmentType = errors.New("only images (PNG, JPEG, GIF, WebP), PDFs and plain text files can be attached")

// Image and PDF types by what their bytes say, never by the name they came
// with, and the extension they are saved under.
var attachmentKinds = map[string]string{
	"image/png":       ".png",
	"image/jpeg":      ".jpg",
	"image/gif":       ".gif",
	"image/webp":      ".webp",
	"application/pdf": ".pdf",
}

// Extensions a text attachment keeps; any other text is saved as .txt.
var textExts = map[string]bool{
	".txt": true, ".md": true, ".log": true, ".csv": true, ".tsv": true, ".json": true, ".yaml": true, ".yml": true, ".toml": true, ".xml": true, ".html": true, ".css": true,
	".js": true, ".jsx": true, ".ts": true, ".tsx": true, ".go": true, ".py": true, ".rb": true, ".rs": true, ".java": true, ".kt": true, ".swift": true, ".c": true, ".h": true,
	".cpp": true, ".sh": true, ".sql": true, ".diff": true, ".patch": true, ".env.example": true,
}

var unsafeFileChars = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// attachmentName is a safe file name for what was uploaded: its own name,
// cleaned and shortened, with the extension its contents call for.
func attachmentName(name, ext string) string {
	base := filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	base = strings.TrimSuffix(base, filepath.Ext(base))
	base = strings.Trim(unsafeFileChars.ReplaceAllString(base, "-"), "-.")
	if len(base) > 60 {
		base = base[:60]
	}
	if base == "" {
		base = "pasted"
	}
	return base + ext
}

// sniffAttachment says what the bytes are, and the extension to save them
// under, or refuses them.
func sniffAttachment(name string, data []byte) (string, string, error) {
	ct := http.DetectContentType(data)
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		ct = ct[:i]
	}
	if ext, ok := attachmentKinds[ct]; ok {
		return ct, ext, nil
	}
	// Text: valid UTF-8 without NULs (DetectContentType calls JSON and
	// HTML text too).
	if utf8.Valid(data) && !bytes.ContainsRune(data, 0) {
		ext := strings.ToLower(filepath.Ext(name))
		if !textExts[ext] {
			ext = ".txt"
		}
		return "text/plain", ext, nil
	}
	return "", "", ErrAttachmentType
}

// SaveAttachment writes an attachment into the worktree at dir and returns
// it. The file is the box user's alone (0600), in a folder git ignores.
func SaveAttachment(ctx context.Context, dir, name string, data []byte) (Attachment, error) {
	if len(data) == 0 {
		return Attachment{}, badRequest("the file is empty")
	}
	if len(data) > MaxAttachment {
		return Attachment{}, httpError{http.StatusRequestEntityTooLarge, fmt.Sprintf("attachments can be up to %d MB", MaxAttachment>>20)}
	}
	ct, ext, err := sniffAttachment(name, data)
	if err != nil {
		return Attachment{}, httpError{http.StatusUnsupportedMediaType, err.Error()}
	}
	folder := filepath.Join(dir, filepath.FromSlash(attachmentDir))
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return Attachment{}, err
	}
	excludeFromGit(ctx, dir, attachmentDir+"/")
	file := attachmentName(name, ext)
	stamp := time.Now().Format("20060102-150405")
	for i := 0; ; i++ {
		n := stamp + "-" + file
		if i > 0 {
			n = fmt.Sprintf("%s-%d-%s", stamp, i, file)
		}
		path := filepath.Join(folder, n)
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if errors.Is(err, os.ErrExist) && i < 100 {
			continue
		}
		if err != nil {
			return Attachment{}, err
		}
		if _, err := f.Write(data); err != nil {
			f.Close()
			os.Remove(path)
			return Attachment{}, err
		}
		if err := f.Close(); err != nil {
			return Attachment{}, err
		}
		return Attachment{Path: path, Name: n, Type: ct, Size: len(data)}, nil
	}
}

// excludeFromGit adds pattern to the repository's .git/info/exclude (shared
// by its worktrees) unless it is there already. It is best effort: a folder
// that isn't a git checkout has nothing to exclude from.
func excludeFromGit(ctx context.Context, dir, pattern string) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := git(ctx, "-C", dir, "rev-parse", "--git-path", "info/exclude")
	if err != nil {
		return
	}
	ex := strings.TrimSpace(string(out))
	if !filepath.IsAbs(ex) {
		ex = filepath.Join(dir, ex)
	}
	cur, _ := os.ReadFile(ex)
	for _, line := range strings.Split(string(cur), "\n") {
		if strings.TrimSpace(line) == pattern {
			return
		}
	}
	if err := os.MkdirAll(filepath.Dir(ex), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(ex, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if len(cur) > 0 && !bytes.HasSuffix(cur, []byte("\n")) {
		f.WriteString("\n")
	}
	f.WriteString(pattern + "\n")
}

// readAttachment reads an upload's name and bytes, as JSON (base64 data) or
// as the raw body.
func readAttachment(r *http.Request) (string, []byte, error) {
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		var req attachmentRequest
		// base64 is 4/3 the size, plus room for the name.
		if err := json.NewDecoder(io.LimitReader(r.Body, MaxAttachment/3*4+64<<10)).Decode(&req); err != nil {
			return "", nil, badRequest("invalid request body")
		}
		data, err := base64.StdEncoding.DecodeString(req.Data)
		if err != nil {
			return "", nil, badRequest("data must be base64")
		}
		return req.Name, data, nil
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, MaxAttachment+1))
	if err != nil {
		return "", nil, err
	}
	return r.URL.Query().Get("name"), data, nil
}

// POST /v1/sessions/{name}/attachments: into the session's worktree.
func (b *Box) sessionAttachment(w http.ResponseWriter, r *http.Request) error {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	return b.attach1(w, r, sess.Dir)
}

// POST /v1/locations/{name}/worktrees/{worktree}/attachments: before an
// agent runs there, for the prompt that starts one.
func (b *Box) worktreeAttachment(w http.ResponseWriter, r *http.Request) error {
	_, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	return b.attach1(w, r, wt.Path)
}

func (b *Box) attach1(w http.ResponseWriter, r *http.Request, dir string) error {
	name, data, err := readAttachment(r)
	if err != nil {
		return err
	}
	a, err := SaveAttachment(r.Context(), dir, name, data)
	if err != nil {
		return err
	}
	writeJSON(w, a)
	return nil
}
