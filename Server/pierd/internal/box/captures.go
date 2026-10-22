package box

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"pier/pierd/internal/statefile"
	"pier/pierd/internal/transcript"
)

// Captures are what an agent hands the person to show its work: a
// screenshot of the page it changed, before and after, a recording of the
// app on a simulator. The agent runs `pierd capture add FILE`, which posts
// the file here with what it shows; the box keeps it in the session's
// worktree (.pier/captures, the box user's alone, which git never sees, as
// attachments are), with a small copy of a picture for the app's lists, and
// the command prints the capture's marker. The marker, in the agent's own
// record, puts the capture where it happened in the conversation
// (internal/transcript/captures.go): the box fills each one in as it sends
// the item, and the app reads the file through GET …/captures/{id}.

const (
	captureDir = ".pier/captures"
	// MaxCapture is the largest file a capture can be: a picture, or a
	// short recording the app can still download in one go.
	MaxCapture = 25 << 20
	// maxSessionCaptures is how many one session can hand over.
	maxSessionCaptures = 100
	// thumbSide is the longer side of a picture's small copy, in pixels;
	// thumbPixels the most a picture can have for the box to make one.
	thumbSide   = 640
	thumbPixels = 25 << 20
	maxCaption  = 300
)

// Capture is one picture or recording the agent handed over.
type Capture struct {
	ID      string `json:"id"`
	Session string `json:"session"`
	// Kind is "before" (what was wrong, or how it was), "after" (the
	// result) or empty.
	Kind    string `json:"kind,omitempty"`
	Caption string `json:"caption,omitempty"`
	// Name is the file's name as the agent had it.
	Name   string `json:"name,omitempty"`
	Type   string `json:"type"`
	Width  int    `json:"width,omitempty"`
	Height int    `json:"height,omitempty"`
	Size   int    `json:"size"`
	// At is when it was handed over (Unix ms).
	At int64 `json:"at"`
	// Thumb: the box keeps a small copy (?thumb=1).
	Thumb bool `json:"thumb,omitempty"`
	// Path is where the box keeps the file.
	Path string `json:"path"`
}

// CaptureRequest is POST …/captures: the file (base64) and what it shows.
type CaptureRequest struct {
	Name    string `json:"name,omitempty"`
	Data    string `json:"data"`
	Kind    string `json:"kind,omitempty"`
	Caption string `json:"caption,omitempty"`
}

var (
	captureID = regexp.MustCompile(`^[0-9a-f]{12}$`)
	// captureTypes are what a capture can be, by what its bytes say, and
	// the extension it is kept under: what the app can show.
	captureTypes = map[string]string{
		"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp",
		"video/mp4": ".mp4", "video/quicktime": ".mov",
	}
	errCaptureType = errors.New("a capture is a picture (PNG, JPEG, GIF, WebP) or a recording (MP4, MOV)")
)

// sniffCapture says what the bytes are, or refuses them. A recording is an
// ISO media file: QuickTime by its brand, MP4 otherwise.
func sniffCapture(data []byte) (string, error) {
	if len(data) >= 12 && string(data[4:8]) == "ftyp" {
		if string(data[8:12]) == "qt  " {
			return "video/quicktime", nil
		}
		return "video/mp4", nil
	}
	ct := http.DetectContentType(data)
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		ct = ct[:i]
	}
	if _, ok := captureTypes[ct]; ok && strings.HasPrefix(ct, "image/") {
		return ct, nil
	}
	return "", errCaptureType
}

// pictureSize is a picture's width and height, read from its header: 0, 0
// for a recording or what the box can't read.
func pictureSize(ct string, data []byte) (int, int) {
	if ct == "image/webp" {
		return webpSize(data)
	}
	if !strings.HasPrefix(ct, "image/") {
		return 0, 0
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return 0, 0
	}
	return cfg.Width, cfg.Height
}

// webpSize reads a WebP's canvas from its first chunk (the standard
// library has no WebP decoder): VP8X, lossless VP8L or lossy VP8.
func webpSize(b []byte) (int, int) {
	if len(b) < 30 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WEBP" {
		return 0, 0
	}
	u24 := func(p []byte) int { return int(p[0]) | int(p[1])<<8 | int(p[2])<<16 }
	switch string(b[12:16]) {
	case "VP8X":
		return u24(b[24:27]) + 1, u24(b[27:30]) + 1
	case "VP8L":
		if b[20] != 0x2f {
			return 0, 0
		}
		v := binary.LittleEndian.Uint32(b[21:25])
		return int(v&0x3fff) + 1, int(v>>14&0x3fff) + 1
	case "VP8 ":
		if b[23] != 0x9d || b[24] != 0x01 || b[25] != 0x2a {
			return 0, 0
		}
		return int(binary.LittleEndian.Uint16(b[26:28]) & 0x3fff), int(binary.LittleEndian.Uint16(b[28:30]) & 0x3fff)
	}
	return 0, 0
}

// thumbnail is a small JPEG of a picture larger than thumbSide, over white
// where it is see-through; nil when there is no need for one or the box
// can't make it (a WebP, a picture too large to decode).
func thumbnail(ct string, data []byte, w, h int) []byte {
	if !strings.HasPrefix(ct, "image/") || ct == "image/webp" || w <= 0 || h <= 0 || w*h > thumbPixels || max(w, h) <= thumbSide {
		return nil
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	b := src.Bounds()
	full := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(full, full.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	draw.Draw(full, full.Bounds(), src, b.Min, draw.Over)
	small := shrink(full, thumbSide)
	var out bytes.Buffer
	if jpeg.Encode(&out, small, &jpeg.Options{Quality: 82}) != nil {
		return nil
	}
	return out.Bytes()
}

// shrink scales an opaque picture down so its longer side is side pixels,
// each pixel the average of those it covers.
func shrink(src *image.RGBA, side int) *image.RGBA {
	w, h := src.Rect.Dx(), src.Rect.Dy()
	nw, nh := max(1, w*side/max(w, h)), max(1, h*side/max(w, h))
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		y0, y1 := y*h/nh, max((y+1)*h/nh, y*h/nh+1)
		for x := 0; x < nw; x++ {
			x0, x1 := x*w/nw, max((x+1)*w/nw, x*w/nw+1)
			var r, g, bl, n int
			for sy := y0; sy < y1; sy++ {
				row := src.Pix[sy*src.Stride:]
				for sx := x0; sx < x1; sx++ {
					p := row[sx*4 : sx*4+4]
					r, g, bl, n = r+int(p[0]), g+int(p[1]), bl+int(p[2]), n+1
				}
			}
			d := dst.Pix[y*dst.Stride+x*4:]
			d[0], d[1], d[2], d[3] = uint8(r/n), uint8(g/n), uint8(bl/n), 0xff
		}
	}
	return dst
}

func newCaptureID() string {
	var b [6]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// captureFolder is where a session's worktree (or a chat's folder) keeps
// its captures.
func captureFolder(dir string) string { return filepath.Join(dir, filepath.FromSlash(captureDir)) }

// loadCapture is capture id of the folder dir, if it is that session's.
func loadCapture(dir, session, id string) (Capture, bool) {
	if !captureID.MatchString(id) {
		return Capture{}, false
	}
	data, err := os.ReadFile(filepath.Join(captureFolder(dir), id+".json"))
	if err != nil {
		return Capture{}, false
	}
	var c Capture
	if json.Unmarshal(data, &c) != nil || c.ID != id || c.Session != session {
		return Capture{}, false
	}
	return c, true
}

// listCaptures are the captures a session handed over in its folder,
// oldest first.
func listCaptures(dir, session string) []Capture {
	out := []Capture{}
	names, _ := filepath.Glob(filepath.Join(captureFolder(dir), "*.json"))
	for _, n := range names {
		if c, ok := loadCapture(dir, session, strings.TrimSuffix(filepath.Base(n), ".json")); ok {
			out = append(out, c)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At < out[j].At })
	return out
}

// SaveCapture keeps a capture for session in its folder dir.
func SaveCapture(ctx context.Context, dir, session string, req CaptureRequest, now time.Time) (Capture, error) {
	switch req.Kind {
	case "", "before", "after":
	default:
		return Capture{}, badRequest("kind is before, after or nothing")
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return Capture{}, badRequest("data must be base64")
	}
	if len(data) == 0 {
		return Capture{}, badRequest("the file is empty")
	}
	if len(data) > MaxCapture {
		return Capture{}, httpError{http.StatusRequestEntityTooLarge, fmt.Sprintf("a capture can be up to %d MB", MaxCapture>>20)}
	}
	ct, err := sniffCapture(data)
	if err != nil {
		return Capture{}, httpError{http.StatusUnsupportedMediaType, err.Error()}
	}
	if n := len(listCaptures(dir, session)); n >= maxSessionCaptures {
		return Capture{}, httpError{http.StatusConflict, fmt.Sprintf("this session handed over %d captures already: show the person the ones that matter", n)}
	}
	folder := captureFolder(dir)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return Capture{}, err
	}
	excludeFromGit(ctx, dir, captureDir+"/")
	c := Capture{ID: newCaptureID(), Session: session, Kind: req.Kind, Type: ct, Size: len(data), At: now.UnixMilli()}
	c.Caption = clip(strings.Join(strings.Fields(req.Caption), " "), maxCaption)
	if n := filepath.Base(strings.ReplaceAll(req.Name, "\\", "/")); n != "." && n != "/" {
		c.Name = clip(n, 120)
	}
	c.Width, c.Height = pictureSize(ct, data)
	c.Path = filepath.Join(folder, c.ID+captureTypes[ct])
	if err := statefile.Write(c.Path, data); err != nil {
		return Capture{}, err
	}
	if t := thumbnail(ct, data, c.Width, c.Height); t != nil && statefile.Write(filepath.Join(folder, c.ID+".thumb.jpg"), t) == nil {
		c.Thumb = true
	}
	meta, _ := json.Marshal(c)
	// The record goes last: a capture is there once its record is.
	if err := statefile.Write(filepath.Join(folder, c.ID+".json"), meta); err != nil {
		os.Remove(c.Path)
		return Capture{}, err
	}
	return c, nil
}

// fillCaptures is items as the app gets them: each capture item's captures
// filled in from what the session's folder keeps, those it doesn't keep
// (a marker other output printed) left out, and an item left with none
// dropped. The reader's own items are never changed.
func fillCaptures(dir, session string, items []transcript.Item) []transcript.Item {
	has := false
	for _, it := range items {
		has = has || it.Kind == "capture"
	}
	if !has {
		return items
	}
	out := make([]transcript.Item, 0, len(items))
	for _, it := range items {
		if it.Kind != "capture" {
			out = append(out, it)
			continue
		}
		var refs []transcript.CaptureRef
		for _, ref := range it.Captures {
			if c, ok := loadCapture(dir, session, ref.ID); ok {
				refs = append(refs, transcript.CaptureRef{ID: c.ID, Kind: c.Kind, Caption: c.Caption, Type: c.Type, Width: c.Width, Height: c.Height, Size: c.Size, At: c.At, Thumb: c.Thumb})
			}
		}
		if len(refs) > 0 {
			it.Captures = refs
			out = append(out, it)
		}
	}
	return out
}

// POST /v1/sessions/{name}/captures {name?, data, kind?, caption?}: what
// `pierd capture add` sends from the agent's session.
func (b *Box) addCapture(w http.ResponseWriter, r *http.Request) error {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	var req CaptureRequest
	// base64 is 4/3 the size, plus room for the caption.
	if err := decodeLimit(r, &req, MaxCapture/3*4+64<<10); err != nil {
		return err
	}
	c, err := SaveCapture(r.Context(), sess.Dir, sess.Name, req, b.now())
	if err != nil {
		return err
	}
	b.publish(r, "capture.added", map[string]any{"session": sess.Name, "id": c.ID, "kind": c.Kind, "path": sess.Dir})
	writeJSON(w, c)
	return nil
}

// GET /v1/sessions/{name}/captures: what the session handed over, oldest
// first.
func (b *Box) listSessionCaptures(w http.ResponseWriter, r *http.Request) error {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	writeJSON(w, listCaptures(sess.Dir, sess.Name))
	return nil
}

// GET /v1/sessions/{name}/captures/{id}[?thumb=1]: the file, or its small
// copy when the box keeps one.
func (b *Box) getCapture(w http.ResponseWriter, r *http.Request) error {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	c, ok := loadCapture(sess.Dir, sess.Name, r.PathValue("id"))
	if !ok {
		return httpError{http.StatusNotFound, "no such capture in this session"}
	}
	path, ct := c.Path, c.Type
	if c.Thumb && r.URL.Query().Get("thumb") == "1" {
		path, ct = filepath.Join(captureFolder(sess.Dir), c.ID+".thumb.jpg"), "image/jpeg"
	}
	// The file is read where this session's captures are, whatever the
	// record says.
	if filepath.Dir(path) != captureFolder(sess.Dir) {
		return httpError{http.StatusNotFound, "no such capture in this session"}
	}
	f, err := os.Open(path)
	if err != nil {
		return httpError{http.StatusNotFound, "the capture's file is gone"}
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "private, max-age=86400, immutable")
	http.ServeContent(w, r, filepath.Base(path), st.ModTime(), f)
	return nil
}

// GET /v1/sessions/{name}/transcript/tool/{id}/image/{n}: picture n (from
// 0) of what a call returned (ToolDetail.Images says how many).
func (b *Box) toolImage(w http.ResponseWriter, r *http.Request) error {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil || n < 0 {
		return badRequest("n is a picture's number, from 0")
	}
	agent, path, _ := b.transcriptFile(r, sess)
	if path == "" {
		return httpError{http.StatusNotFound, "this session's conversation can't be read"}
	}
	ct, data, err := transcript.DetailImage(agent, path, r.PathValue("id"), n)
	switch {
	case errors.Is(err, transcript.ErrNoTool):
		return httpError{http.StatusNotFound, "that step is no longer in the conversation"}
	case errors.Is(err, transcript.ErrNoImage):
		return httpError{http.StatusNotFound, "that step returned no such picture"}
	case err != nil:
		return err
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "private, max-age=86400, immutable")
	w.Write(data)
	return nil
}
