package boxcmd

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"pier/pierd/internal/box"
)

// What an agent runs to hand the person a screenshot: `pierd capture add`
// in its own session prints the marker its record keeps, and `capture ls`
// lists what it handed over.
func TestCaptureThroughTheLocalSocket(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	tmp, err := os.MkdirTemp("/tmp", "pcb")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", tmp)
	t.Setenv("TMUX", "")
	t.Setenv("SHELL", "/bin/sh")
	sessions, err := box.NewSessions(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		exec.Command("tmux", "-L", "pier", "kill-server").Run()
		os.RemoveAll(tmp)
	})
	c := socketBox(t, func(b *box.Box) { b.Sessions = sessions })
	var wt box.Worktree
	json.Unmarshal([]byte(runOK(t, c, "worktree", "new", "cal/shots", "--prepare-with", "none", "--json")), &wt)
	var sess box.Session
	if err := json.Unmarshal([]byte(runOK(t, c, "session", "new", "cal/shots", "--json", "--", "cat")), &sess); err != nil || sess.Name == "" {
		t.Fatalf("session: %+v %v", sess, err)
	}

	var buf bytes.Buffer
	png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 40, 30)))
	shot := filepath.Join(t.TempDir(), "after.png")
	os.WriteFile(shot, buf.Bytes(), 0o600)

	// Outside a session, it says how to name one.
	t.Setenv("PIER_SESSION", "")
	if err := Run(context.Background(), c, []string{"capture", "add", shot}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "--session") {
		t.Fatalf("outside a session: %v", err)
	}
	t.Setenv("PIER_SESSION", sess.Name)
	out := runOK(t, c, "capture", "add", shot, "--after", "--caption", "Login centered")
	m := regexp.MustCompile(`\[pier capture ([0-9a-f]{12})\]`).FindStringSubmatch(out)
	if m == nil || !strings.Contains(out, "after.png (after): Login centered") {
		t.Fatalf("add printed %q", out)
	}
	var list []box.Capture
	if err := json.Unmarshal([]byte(runOK(t, c, "capture", "ls", "--json")), &list); err != nil || len(list) != 1 || list[0].ID != m[1] || list[0].Kind != "after" {
		t.Fatalf("ls = %+v %v", list, err)
	}
	if !strings.HasPrefix(list[0].Path, filepath.Join(wt.Path, ".pier", "captures")) {
		t.Errorf("kept at %s", list[0].Path)
	}
	if ls := runOK(t, c, "capture", "ls"); !strings.Contains(ls, m[1]) || !strings.Contains(ls, "Login centered") {
		t.Errorf("ls = %q", ls)
	}
	for _, bad := range [][]string{
		{"capture", "add", shot, "--before", "--after"},
		{"capture", "add"},
		{"capture", "add", filepath.Dir(shot)},
		{"capture", "add", filepath.Join(t.TempDir(), "missing.png")},
	} {
		if err := Run(context.Background(), c, bad, &bytes.Buffer{}); err == nil {
			t.Errorf("%v: no error", bad)
		}
	}
	// What the box refuses comes back in its words.
	notes := filepath.Join(t.TempDir(), "notes.txt")
	os.WriteFile(notes, []byte("not a picture"), 0o600)
	if err := Run(context.Background(), c, []string{"capture", "add", notes}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "picture") {
		t.Errorf("text file: %v", err)
	}
}
