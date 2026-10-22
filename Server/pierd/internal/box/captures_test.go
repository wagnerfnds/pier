package box

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/transcript"
)

// testPNG is a w×h picture, see-through on its left half.
func testPNG(t testing.TB, w, h int) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			a := uint8(255)
			if x < w/2 {
				a = 0
			}
			img.Set(x, y, color.NRGBA{R: 200, G: 40, B: 40, A: a})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func captureReq(data []byte, kind, caption string) CaptureRequest {
	return CaptureRequest{Name: "shot.png", Data: base64.StdEncoding.EncodeToString(data), Kind: kind, Caption: caption}
}

func TestSaveCapture(t *testing.T) {
	dir := t.TempDir()
	if out, err := exec.Command("git", "-C", dir, "init", "-q").CombinedOutput(); err != nil {
		t.Skipf("git init: %v %s", err, out)
	}
	ctx := context.Background()
	now := time.UnixMilli(1760000000000)

	big, err := SaveCapture(ctx, dir, "shop-login-claude-1", captureReq(testPNG(t, 1600, 1000), "after", "  Login\nbutton   centered "), now)
	if err != nil {
		t.Fatal(err)
	}
	if !captureID.MatchString(big.ID) || big.Type != "image/png" || big.Width != 1600 || big.Height != 1000 || big.Kind != "after" ||
		big.Caption != "Login button centered" || big.Name != "shot.png" || big.At != now.UnixMilli() || !big.Thumb {
		t.Fatalf("capture = %+v", big)
	}
	if filepath.Dir(big.Path) != filepath.Join(dir, ".pier", "captures") || filepath.Ext(big.Path) != ".png" {
		t.Errorf("kept at %s", big.Path)
	}
	if fi, err := os.Stat(big.Path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("file: %v %v", fi, err)
	}
	thumb, err := os.ReadFile(filepath.Join(dir, ".pier", "captures", big.ID+".thumb.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(thumb))
	if err != nil || cfg.Width != 640 || cfg.Height != 400 {
		t.Fatalf("thumb %+v %v", cfg, err)
	}
	// The see-through half is white in the small copy, not black.
	if small, _ := jpeg.Decode(bytes.NewReader(thumb)); small != nil {
		if r, g, b, _ := small.At(10, 200).RGBA(); r>>8 < 240 || g>>8 < 240 || b>>8 < 240 {
			t.Errorf("transparent part is %d %d %d", r>>8, g>>8, b>>8)
		}
	}

	// A small picture needs no small copy.
	small, err := SaveCapture(ctx, dir, "shop-login-claude-1", captureReq(testPNG(t, 300, 200), "before", ""), now.Add(time.Second))
	if err != nil || small.Thumb || small.Width != 300 {
		t.Fatalf("small: %+v %v", small, err)
	}

	// Types come from the bytes.
	webp := append([]byte("RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00"), 0x7f, 0x04, 0x00, 0xff, 0x02, 0x00)
	mp4 := []byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2")
	mov := []byte("\x00\x00\x00\x14ftypqt  \x00\x00\x02\x00qt  ")
	for _, tc := range []struct {
		data      []byte
		ct        string
		w, h      int
		extension string
	}{
		{webp, "image/webp", 1152, 768, ".webp"},
		{mp4, "video/mp4", 0, 0, ".mp4"},
		{mov, "video/quicktime", 0, 0, ".mov"},
	} {
		c, err := SaveCapture(ctx, dir, "shop-login-claude-1", captureReq(tc.data, "", ""), now.Add(time.Minute))
		if err != nil || c.Type != tc.ct || c.Width != tc.w || c.Height != tc.h || filepath.Ext(c.Path) != tc.extension || c.Thumb {
			t.Errorf("%s: %+v %v", tc.ct, c, err)
		}
	}

	var he httpError
	for _, tc := range []struct {
		req    CaptureRequest
		status int
	}{
		{captureReq([]byte("just text"), "", ""), http.StatusUnsupportedMediaType},
		{captureReq([]byte{0x7f, 'E', 'L', 'F', 0, 1, 2}, "", ""), http.StatusUnsupportedMediaType},
		{captureReq(nil, "", ""), http.StatusBadRequest},
		{captureReq(testPNG(t, 2, 2), "during", ""), http.StatusBadRequest},
		{CaptureRequest{Data: "not base64!"}, http.StatusBadRequest},
		{captureReq(bytes.Repeat([]byte{0}, MaxCapture+1), "", ""), http.StatusRequestEntityTooLarge},
	} {
		if _, err := SaveCapture(ctx, dir, "shop-login-claude-1", tc.req, now); !errors.As(err, &he) || he.status != tc.status {
			t.Errorf("%.20q: %v, want %d", tc.req.Data, err, tc.status)
		}
	}

	// git never sees them.
	ex, _ := os.ReadFile(filepath.Join(dir, ".git", "info", "exclude"))
	if strings.Count(string(ex), ".pier/captures/\n") != 1 {
		t.Errorf("exclude: %q", ex)
	}
	if out, _ := exec.Command("git", "-C", dir, "status", "--porcelain").Output(); len(out) != 0 {
		t.Errorf("git sees captures: %s", out)
	}

	// Each session sees its own, oldest first; another session's is not
	// there for it.
	all := listCaptures(dir, "shop-login-claude-1")
	if len(all) != 5 || all[0].ID != big.ID {
		t.Fatalf("list = %d, first %s", len(all), all[0].ID)
	}
	if got := listCaptures(dir, "shop-login-codex-2"); len(got) != 0 {
		t.Errorf("another session's: %+v", got)
	}
	if _, ok := loadCapture(dir, "shop-login-codex-2", big.ID); ok {
		t.Error("another session read this one's capture")
	}
	if _, ok := loadCapture(dir, "shop-login-claude-1", "../../etc"); ok {
		t.Error("an ID that is a path was read")
	}
}

func TestSessionCapturesAreBounded(t *testing.T) {
	dir := t.TempDir()
	folder := filepath.Join(dir, ".pier", "captures")
	os.MkdirAll(folder, 0o700)
	for i := range maxSessionCaptures {
		id := fmt.Sprintf("%012x", i)
		meta, _ := json.Marshal(Capture{ID: id, Session: "s", Type: "image/png", At: int64(i)})
		os.WriteFile(filepath.Join(folder, id+".json"), meta, 0o600)
	}
	var he httpError
	if _, err := SaveCapture(context.Background(), dir, "s", captureReq(testPNG(t, 2, 2), "", ""), time.Now()); !errors.As(err, &he) || he.status != http.StatusConflict {
		t.Fatalf("the 101st: %v", err)
	}
	if _, err := SaveCapture(context.Background(), dir, "other", captureReq(testPNG(t, 2, 2), "", ""), time.Now()); err != nil {
		t.Fatalf("another session's first: %v", err)
	}
}

func TestFillCaptures(t *testing.T) {
	dir := t.TempDir()
	kept, err := SaveCapture(context.Background(), dir, "s", captureReq(testPNG(t, 800, 600), "before", "Broken total"), time.UnixMilli(5))
	if err != nil {
		t.Fatal(err)
	}
	items := []transcript.Item{
		{Kind: "user", ID: "a"},
		{Kind: "capture", ID: "b", Captures: []transcript.CaptureRef{{ID: kept.ID}, {ID: "000000000000"}}},
		{Kind: "capture", ID: "c", Captures: []transcript.CaptureRef{{ID: "ffffffffffff"}}},
		{Kind: "text", ID: "d"},
	}
	before := append([]transcript.Item(nil), items...)
	got := fillCaptures(dir, "s", items)
	if len(got) != 3 || got[1].ID != "b" || len(got[1].Captures) != 1 {
		t.Fatalf("filled = %+v", got)
	}
	want := transcript.CaptureRef{ID: kept.ID, Kind: "before", Caption: "Broken total", Type: "image/png", Width: 800, Height: 600, Size: kept.Size, At: 5, Thumb: true}
	if got[1].Captures[0] != want {
		t.Errorf("ref = %+v, want %+v", got[1].Captures[0], want)
	}
	if !reflect.DeepEqual(items, before) {
		t.Error("the reader's items were changed")
	}
	// Another session's conversation naming it gets nothing.
	if got := fillCaptures(dir, "t", items); len(got) != 2 {
		t.Errorf("another session's = %+v", got)
	}
	// Nothing to fill: the same items back.
	plain := []transcript.Item{{Kind: "text", ID: "x"}}
	if got := fillCaptures(dir, "s", plain); &got[0] != &plain[0] {
		t.Error("items without captures were copied")
	}
}

func TestCapturesOverTheWire(t *testing.T) {
	c, bus := servedBox(t)
	seen, stop := bus.Subscribe()
	defer stop()
	repo := gitRepo(t)
	if status := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil); status != 200 {
		t.Fatalf("add location: %d", status)
	}
	var wt Worktree
	if status := call(t, c, "POST", "/v1/locations/cal/worktrees", "", WorktreeRequest{Name: "shots"}, &wt); status != 200 {
		t.Fatalf("add worktree: %d", status)
	}
	var sess Session
	if status := call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal/shots", "command": "cat"}, &sess); status != 200 {
		t.Fatalf("add session: %d", status)
	}
	base := "/v1/sessions/" + sess.Name + "/captures"
	shot := testPNG(t, 1280, 800)
	var added Capture
	if status := call(t, c, "POST", base, "", captureReq(shot, "after", "Login centered"), &added); status != 200 || added.Session != sess.Name || !added.Thumb {
		t.Fatalf("add = %d %+v", status, added)
	}
	if !strings.HasPrefix(added.Path, wt.Path) {
		t.Errorf("kept at %s, outside the worktree %s", added.Path, wt.Path)
	}
	var list []Capture
	if status := call(t, c, "GET", base, "", nil, &list); status != 200 || len(list) != 1 || list[0].ID != added.ID {
		t.Fatalf("list = %d %+v", status, list)
	}
	get := func(path string) (int, string, []byte) {
		resp, err := c.DoWithHeader(context.Background(), "GET", path, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("Content-Type"), data
	}
	if status, ct, data := get(base + "/" + added.ID); status != 200 || ct != "image/png" || !bytes.Equal(data, shot) {
		t.Errorf("file = %d %s %d bytes", status, ct, len(data))
	}
	if status, ct, data := get(base + "/" + added.ID + "?thumb=1"); status != 200 || ct != "image/jpeg" || len(data) == 0 || len(data) >= len(shot) {
		t.Errorf("thumb = %d %s %d bytes", status, ct, len(data))
	}
	if status, _, _ := get(base + "/000000000000"); status != 404 {
		t.Errorf("unknown capture = %d", status)
	}
	if status, _, _ := get("/v1/sessions/nobody/captures/" + added.ID); status != 404 {
		t.Errorf("unknown session = %d", status)
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case e := <-seen:
			if e.Type == "capture.added" && e.Data["id"] == added.ID && e.Data["session"] == sess.Name && e.Data["kind"] == "after" {
				return
			}
		case <-deadline:
			t.Fatal("no capture.added event")
		}
	}
}
