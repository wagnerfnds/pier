package transcript

import (
	"bytes"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func captureIDs(items []Item) [][]string {
	var out [][]string
	for _, it := range items {
		if it.Kind != "capture" {
			continue
		}
		var ids []string
		for _, c := range it.Captures {
			ids = append(ids, c.ID)
		}
		out = append(out, ids)
	}
	return out
}

func TestCapturesFromClaudeResults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	write(t, p,
		user("Center the login button"),
		assistant(tool("b1", "Bash", m{"command": "pierd capture add before.png --before"})),
		user([]m{{"type": "tool_result", "tool_use_id": "b1", "content": "Captured for the person: before.png (before) " + CaptureMarker("0a1b2c3d4e5f")}}),
		assistant(tool("e1", "Edit", m{"file_path": "/w/app/login.css", "old_string": "a", "new_string": "b"})),
		user([]m{{"type": "tool_result", "tool_use_id": "e1", "content": "ok"}}),
		// Two in one call: one item naming both.
		assistant(tool("b2", "Bash", m{"command": "pierd capture add after.png --after && pierd capture add mobile.png --after"})),
		user([]m{{"type": "tool_result", "tool_use_id": "b2", "content": CaptureMarker("111111111111") + "\n" + CaptureMarker("222222222222") + "\n"}}),
		// Output that names them again (a log read back) adds nothing.
		assistant(tool("b3", "Bash", m{"command": "cat run.log"})),
		user([]m{{"type": "tool_result", "tool_use_id": "b3", "content": "earlier: " + CaptureMarker("0a1b2c3d4e5f") + " [pier capture nothex12345]"}}),
		assistant(m{"type": "text", "text": "Centered; before and after are above."}),
	)
	res, err := NewReader().Read("claude", p, "/w/app", 0)
	if err != nil {
		t.Fatal(err)
	}
	got := captureIDs(res.Items)
	if len(got) != 2 || len(got[0]) != 1 || got[0][0] != "0a1b2c3d4e5f" || len(got[1]) != 2 || got[1][0] != "111111111111" || got[1][1] != "222222222222" {
		t.Fatalf("captures = %v", got)
	}
	// Each sits where its call returned, after the call's group, in the turn.
	kinds := []string{}
	for _, it := range res.Items {
		kinds = append(kinds, it.Kind)
	}
	want := []string{"user", "tools", "capture", "edit", "tools", "capture", "tools", "text"}
	if len(kinds) != len(want) {
		t.Fatalf("kinds = %v, want %v", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Fatalf("kinds = %v, want %v", kinds, want)
		}
	}
	if !res.Items[1].Done {
		t.Error("the capture's own call still reads as running")
	}
}

func TestCapturesFromCodexOutput(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "rollout.jsonl")
	call := `{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\"command\":[\"bash\",\"-lc\",\"pierd capture add shot.png --after\"]}"}}`
	out := `{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"{\"output\":\"Captured for the person: shot.png (after) [pier capture abcdefabcdef]\\n\",\"metadata\":{\"exit_code\":0}}"}}`
	if err := os.WriteFile(p, []byte(call+"\n"+out+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, _ := NewReader().Read("codex", p, dir, 0)
	if got := captureIDs(res.Items); len(got) != 1 || len(got[0]) != 1 || got[0][0] != "abcdefabcdef" {
		t.Fatalf("codex captures = %v (items %+v)", got, res.Items)
	}
}

func TestDetailImages(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	shot := []byte("\x89PNG\r\n\x1a\nnot really a picture")
	img := func(data []byte, mt string) m {
		return m{"type": "image", "source": m{"type": "base64", "media_type": mt, "data": base64.StdEncoding.EncodeToString(data)}}
	}
	write(t, p,
		assistant(tool("s1", "mcp__playwright__browser_take_screenshot", m{"filename": "home.png"})),
		user([]m{{"type": "tool_result", "tool_use_id": "s1", "content": []m{{"type": "text", "text": "Took the screenshot"}, img(shot, "image/png"), img([]byte("\xff\xd8\xff\xe0 jpeg"), "image/jpeg")}}}),
		assistant(tool("r1", "Read", m{"file_path": "/w/app/notes.md"})),
		user([]m{{"type": "tool_result", "tool_use_id": "r1", "content": "# Notes"}}),
	)
	d, err := Detail("claude", p, "/w/app", "s1")
	if err != nil {
		t.Fatal(err)
	}
	if d.Images != 2 || d.Output != "Took the screenshot\n[image]\n[image]" {
		t.Fatalf("detail = %+v", d)
	}
	ct, data, err := DetailImage("claude", p, "s1", 0)
	if err != nil || ct != "image/png" || !bytes.Equal(data, shot) {
		t.Fatalf("picture 0 = %q %q %v", ct, data, err)
	}
	if ct, _, err := DetailImage("claude", p, "s1", 1); err != nil || ct != "image/jpeg" {
		t.Fatalf("picture 1 = %q %v", ct, err)
	}
	if _, _, err := DetailImage("claude", p, "s1", 2); !errors.Is(err, ErrNoImage) {
		t.Errorf("picture 2: %v", err)
	}
	if _, _, err := DetailImage("claude", p, "r1", 0); !errors.Is(err, ErrNoImage) {
		t.Errorf("a call without pictures: %v", err)
	}
	if _, _, err := DetailImage("claude", p, "zz", 0); !errors.Is(err, ErrNoTool) {
		t.Errorf("an unknown call: %v", err)
	}
	if d, _ := Detail("claude", p, "/w/app", "r1"); d.Images != 0 {
		t.Errorf("a call without pictures counts %d", d.Images)
	}
}
