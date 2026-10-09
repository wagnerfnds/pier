package transcript

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

// The latest turn's files: only edits after the last prompt count, a
// file's first edit holds it as the turn found it, a write that made a
// file says so, and a failed edit is no change.
func TestLastTurnKeepsEachFileAsTheTurnFoundIt(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	at := func(l m, ts string) m { l["timestamp"] = ts; return l }
	write(t, p,
		user("Add a health check"),
		assistant(tool("old", "Edit", m{"file_path": "/w/shop/old.ts", "old_string": "a", "new_string": "b"})),
		withResult("old", m{"filePath": "/w/shop/old.ts", "originalFile": "a\n"}),
		at(user("Make the webhook idempotent"), "2026-10-04T12:10:00Z"),
		assistant(tool("e1", "Edit", m{"file_path": "/w/shop/webhook.ts", "old_string": "x", "new_string": "y\nz"})),
		at(withResult("e1", m{"filePath": "/w/shop/webhook.ts", "originalFile": "one\nx\n"}), "2026-10-04T12:11:00Z"),
		// A second edit of the same file: its originalFile is the first
		// edit's result, not what the turn found.
		assistant(tool("e2", "Edit", m{"file_path": "/w/shop/webhook.ts", "old_string": "one", "new_string": "uno"})),
		at(withResult("e2", m{"filePath": "/w/shop/webhook.ts", "originalFile": "one\ny\nz\n"}), "2026-10-04T12:12:00Z"),
		assistant(tool("w1", "Write", m{"file_path": "/w/shop/idempotency.ts", "content": "export {}\n"})),
		withResult("w1", m{"type": "create", "filePath": "/w/shop/idempotency.ts", "content": "export {}\n", "originalFile": nil}),
		// A failed edit changed nothing.
		assistant(tool("e3", "Edit", m{"file_path": "/w/shop/nope.ts", "old_string": "q", "new_string": "r"})),
		func() m {
			l := user([]m{{"type": "tool_result", "tool_use_id": "e3", "content": "not found", "is_error": true}})
			l["toolUseResult"] = "Error: String to replace not found in file."
			return l
		}(),
		// Plan mode's plan is not the work.
		assistant(tool("p1", "Write", m{"file_path": "/home/me/.claude/plans/plan.md", "content": "# Plan\n"})),
		withResult("p1", m{"type": "create"}),
		// An edit from an older record: no toolUseResult.
		assistant(tool("e4", "Edit", m{"file_path": "/w/shop/legacy.ts", "old_string": "a", "new_string": "b"})),
		user([]m{{"type": "tool_result", "tool_use_id": "e4", "content": "ok"}}),
		// Still running: no result yet.
		assistant(tool("e5", "Edit", m{"file_path": "/w/shop/pending.ts", "old_string": "a", "new_string": "b"})),
	)
	turn, err := LastTurn("claude", p, "/w/shop")
	if err != nil {
		t.Fatal(err)
	}
	if turn.Started == 0 || turn.Off == 0 {
		t.Fatalf("turn %+v", turn)
	}
	got := map[string]TurnFile{}
	for _, f := range turn.Files {
		got[f.Path] = f
	}
	if len(turn.Files) != 3 {
		t.Fatalf("files %+v", turn.Files)
	}
	w := got["/w/shop/webhook.ts"]
	if w.Original == nil || *w.Original != "one\nx\n" || w.Created || w.Added != 3 || w.Removed != 2 || w.At != parseTime("2026-10-04T12:12:00Z") {
		t.Fatalf("webhook %+v", w)
	}
	if n := got["/w/shop/idempotency.ts"]; !n.Created || n.Original != nil || n.Added != 1 {
		t.Fatalf("created %+v", n)
	}
	if l, ok := got["/w/shop/legacy.ts"]; !ok || l.Original != nil || l.Created {
		t.Fatalf("legacy %+v", l)
	}
	if turn.Files[0].Path != "/w/shop/webhook.ts" {
		t.Fatalf("order %+v", turn.Files)
	}
}

func TestLastTurnWithoutAPromptReadsTheWholeRecord(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	write(t, p,
		assistant(tool("e1", "Write", m{"file_path": "/w/a.ts", "content": "a\n"})),
		withResult("e1", m{"type": "create"}),
	)
	turn, err := LastTurn("claude", p, "/w")
	if err != nil || len(turn.Files) != 1 || !turn.Files[0].Created {
		t.Fatalf("%+v %v", turn, err)
	}
}

func TestLastTurnFromCodexHasCountsButNoOriginals(t *testing.T) {
	p := filepath.Join(t.TempDir(), "rollout.jsonl")
	ri := func(payload m) m {
		return m{"type": "response_item", "timestamp": "2026-10-04T12:00:00Z", "payload": payload}
	}
	args := func(v any) string { b, _ := json.Marshal(v); return string(b) }
	patch := func(id, file string) m {
		return ri(m{"type": "function_call", "name": "shell", "call_id": id, "arguments": args(m{"command": []string{"apply_patch", "*** Begin Patch\n*** Update File: " + file + "\n@@\n-old\n+new\n+more\n*** End Patch"}})})
	}
	write(t, p,
		m{"type": "session_meta", "payload": m{"cwd": "/w/shop"}},
		ri(m{"type": "message", "role": "user", "content": []m{{"type": "input_text", "text": "First"}}}),
		patch("c1", "apps/web/first.ts"),
		ri(m{"type": "message", "role": "user", "content": []m{{"type": "input_text", "text": "Export orders as CSV"}}}),
		patch("c2", "apps/web/orders.ts"),
		patch("c3", "apps/web/orders.ts"),
	)
	turn, err := LastTurn("codex", p, "/w/shop")
	if err != nil {
		t.Fatal(err)
	}
	if len(turn.Files) != 1 || turn.Files[0].Path != "apps/web/orders.ts" || turn.Files[0].Added != 4 || turn.Files[0].Removed != 2 || turn.Files[0].Original != nil {
		t.Fatalf("%+v", turn.Files)
	}
}
