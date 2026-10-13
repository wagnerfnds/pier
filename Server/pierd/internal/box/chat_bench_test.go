package box

import (
	"context"
	"encoding/json"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/transcript"
)

// What a chat costs the box per request: the draft's parse of a styled
// screen, and GET …/draft and GET …/transcript end to end, in the handler
// (tmux and the file included) and over the wire (mutual TLS on loopback).

// styledScreen is a Claude Code 2.1 screen of about 60 lines at 120
// columns, drawn as tmux capture-pane -e gives it: a reply streaming in
// with a heading, prose with bold, `code` and a link, a list, a quote, a
// table and a highlighted code block, then the status line, a hint and
// the prompt box.
func styledScreen() string {
	const fg = "\x1b[38;5;231m⏺\x1b[39m "
	rule := "\x1b[38;5;244m" + strings.Repeat("─", 120) + "\x1b[39m"
	link := "\x1b[94m\x1b]8;id=a1;https://example.com/ledger\x1b\\the ledger docs\x1b[39m\x1b]8;;\x1b\\"
	lines := []string{
		"\x1b[38;5;246m⏺\x1b[39m \x1b[38;5;246mRead \x1b[1m3\x1b[0m\x1b[38;5;246m files, ran \x1b[1m2\x1b[0m\x1b[38;5;246m shell commands\x1b[39m",
		"",
		fg + "\x1b[1;4mWhy refunds were charged twice\x1b[0m",
		"",
		"  The webhook handler retried on every \x1b[38;5;153m5xx\x1b[39m, and the refund path had no \x1b[1midempotency key\x1b[0m, so a",
		"  timeout after the ledger write sent the same refund again. See " + link + " for how keys are",
		"  checked before a write is applied.",
		"",
		"  \x1b[1mWhat changed\x1b[0m",
		"",
		"  - \x1b[1mRetries\x1b[0m: only on network errors, at most 3, with \x1b[38;5;153mbackoff(250ms)\x1b[39m",
		"  - \x1b[1mRefunds\x1b[0m: keyed by \x1b[38;5;153mrefund:{orderId}:{amount}\x1b[39m, so a retry is a no-op",
		"    and the ledger keeps one entry per refund",
		"  - \x1b[1mTests\x1b[0m: two new cases in \x1b[38;5;153mpayments.test.ts\x1b[39m",
		"    1. a retried refund writes once",
		"    2. a refund that times out is retried with the same key",
		"",
		"  \x1b[2m▎\x1b[0m \x1b[3m\"Make every write safe to repeat.\"\x1b[0m",
		"",
		"  ┌──────────────────────────┬──────────┬──────────────────────────────┐",
		"  │ Path                     │ Keyed    │ Notes                        │",
		"  ├──────────────────────────┼──────────┼──────────────────────────────┤",
		"  │ settle                   │ yes      │ unchanged                    │",
		"  ├──────────────────────────┼──────────┼──────────────────────────────┤",
		"  │ refund                   │ now      │ refund:{orderId}:{amount}    │",
		"  ├──────────────────────────┼──────────┼──────────────────────────────┤",
		"  │ chargeback               │ no       │ handled by the bank's id     │",
		"  └──────────────────────────┴──────────┴──────────────────────────────┘",
		"",
		"  The handler now reads:",
		"",
		"  \x1b[34mexport\x1b[39m \x1b[34masync\x1b[39m \x1b[34mfunction\x1b[39m \x1b[33mrefund\x1b[39m(order: Order, amount: \x1b[34mnumber\x1b[39m) {",
		"    \x1b[34mconst\x1b[39m key = \x1b[31m`refund:${order.id}:${amount}`\x1b[39m;",
		"    \x1b[34mif\x1b[39m (\x1b[34mawait\x1b[39m ledger.\x1b[33mhas\x1b[39m(key)) \x1b[34mreturn\x1b[39m;",
		"    \x1b[34mawait\x1b[39m ledger.\x1b[33mwrite\x1b[39m({ key, amount, kind: \x1b[31m\"refund\"\x1b[39m });",
		"    \x1b[34mreturn\x1b[39m gateway.\x1b[33mrefund\x1b[39m(order.paymentId, amount, { idempotencyKey: key });",
		"  }",
		"",
		"  Run \x1b[38;5;153mpnpm test payments\x1b[39m to check it; both new cases pass and the old ones still do. The",
		"  migration adds a unique index on \x1b[38;5;153mledger.key\x1b[39m, which takes about a second on a table of this",
		"  size, so it can run without a window. Two things are worth a look before merging:",
		"",
		"  1. \x1b[1mThe gateway's own key\x1b[0m: it keeps keys for 24 hours, so a refund retried a day later is new",
		"     to it, though the ledger still stops it.",
		"  2. \x1b[1mOld entries\x1b[0m: entries written before this have no key; the backfill script gives",
		"     them one from their order and amount.",
		"",
		"  Want me to open the pull request now, or run the backfill on staging",
		"",
		"\x1b[38;5;174m✻\x1b[39m \x1b[38;5;174mPondering…\x1b[39m \x1b[38;5;246m(1m 12s · ↓ 3.4k tokens · esc to interrupt)\x1b[39m",
		"  \x1b[38;5;246m⎿  Tip: Run tasks in the cloud while you keep coding locally\x1b[39m",
		rule,
		"\x1b[39m❯ ",
		rule,
		"\x1b[39m  \x1b[38;5;246mOpus 5.5 · context 41% · 5h 12% · 7d 3%",
		"\x1b[39m  \x1b[38;5;246m⏵⏵ accept edits on (shift+tab to cycle)\x1b[39m",
	}
	return strings.Join(lines, "\n") + "\n"
}

func TestStyledScreenDrafts(t *testing.T) {
	d := ParseClaudeDraft(styledScreen())
	for _, want := range []string{
		"# Why refunds were charged twice",
		"[the ledger docs](https://example.com/ledger)",
		"- **Refunds**: keyed by `refund:{orderId}:{amount}`, so a retry is a no-op and the ledger keeps one entry per refund",
		"| refund | now | refund:{orderId}:{amount} |",
		"```\nexport async function refund(order: Order, amount: number) {",
		"> \"Make every write safe to repeat.\"",
		"Want me to open the pull request now, or run the backfill on staging",
	} {
		if !strings.Contains(d.Text, want) {
			t.Errorf("missing %q in\n%s", want, d.Text)
		}
	}
	if d.Status == nil || d.Status.Word != "Pondering…" || d.Status.Elapsed != "1m 12s" || d.Clipped {
		t.Errorf("status %+v, clipped %v", d.Status, d.Clipped)
	}
}

// BenchmarkParseClaudeDraft is the draft's parse of one screen, as every
// poll of GET …/draft does it.
func BenchmarkParseClaudeDraft(b *testing.B) {
	screens := map[string]string{"styled-60-lines": styledScreen()}
	for _, f := range []string{"table.ansi", "clipped-code.ansi", "text-after-tools.ansi"} {
		raw, err := os.ReadFile(filepath.Join("testdata", "draft", f))
		if err != nil {
			b.Fatal(err)
		}
		screens[f] = string(raw)
	}
	for _, name := range []string{"styled-60-lines", "table.ansi", "clipped-code.ansi", "text-after-tools.ansi"} {
		raw := screens[name]
		b.Run(name, func(b *testing.B) {
			b.SetBytes(int64(len(raw)))
			for b.Loop() {
				if d := ParseClaudeDraft(raw); d.Text == "" {
					b.Fatal("no draft")
				}
			}
		})
	}
}

// benchRecord writes a Claude Code 2.1 record of about size bytes, as a
// long session leaves one: prompts, thinking, steps with large results
// (kept twice by Claude Code), edits with their file, Markdown replies.
func benchRecord(tb testing.TB, path string, size int64, start time.Time) {
	f, err := os.Create(path)
	if err != nil {
		tb.Fatal(err)
	}
	defer f.Close()
	r := rand.New(rand.NewPCG(1, 2))
	text := func(n int) string {
		words := []string{"the", "webhook", "retries", "não", "está", "função", "ledger", "handler", "test", "fails", "because", "`await`", "índice", "**cache**", "returns", "null"}
		var s strings.Builder
		for s.Len() < n {
			s.WriteString(words[r.IntN(len(words))] + " ")
		}
		return s.String()
	}
	at, n := start, 0
	var written int64
	put := func(v map[string]any) {
		n++
		at = at.Add(1500 * time.Millisecond)
		v["uuid"], v["timestamp"], v["sessionId"], v["version"], v["cwd"] = "u-"+strconv.Itoa(n), at.Format(time.RFC3339Nano), "5b84275f-0000", "2.1.296", "/w/acme"
		line, _ := json.Marshal(v)
		w, _ := f.Write(append(line, '\n'))
		written += int64(w)
	}
	said := func(block map[string]any) map[string]any {
		return map[string]any{"type": "assistant", "message": map[string]any{"model": "claude-opus-5-5", "role": "assistant", "content": []any{block}, "usage": map[string]any{"input_tokens": 12, "cache_read_input_tokens": 41000, "output_tokens": 420}}}
	}
	for turn := 0; written < size; turn++ {
		put(map[string]any{"type": "user", "origin": map[string]any{"kind": "human"}, "promptSource": "typed", "permissionMode": "default", "message": map[string]any{"role": "user", "content": text(120 + r.IntN(500))}})
		for k := 0; k < 6; k++ {
			put(said(map[string]any{"type": "thinking", "thinking": text(2500), "signature": strings.Repeat("Ep8B", 100)}))
			id := "toolu_" + strconv.Itoa(turn) + "_" + strconv.Itoa(k)
			name, input := "Bash", map[string]any{"command": "pnpm test payments", "description": "Run the tests"}
			out := text(4000 + r.IntN(20000))
			res := map[string]any{"stdout": out, "stderr": ""}
			switch k % 3 {
			case 0:
				name, input = "Read", map[string]any{"file_path": "/w/acme/apps/web/handler" + strconv.Itoa(k) + ".ts"}
				res = map[string]any{"type": "text", "file": map[string]any{"content": out, "numLines": 300}}
			case 1:
				old, neu := text(600+r.IntN(1500)), text(800+r.IntN(1800))
				name, input = "Edit", map[string]any{"file_path": "/w/acme/apps/web/handler.ts", "old_string": old, "new_string": neu}
				out = "The file has been updated successfully."
				res = map[string]any{"oldString": old, "newString": neu, "originalFile": text(8000 + r.IntN(16000))}
			}
			put(said(map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}))
			put(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": id, "content": out}}}, "toolUseResult": res})
			put(map[string]any{"type": "attachment", "attachment": map[string]any{"type": "hook_success", "hookName": "PostToolUse:" + name, "toolUseID": id, "stdout": text(300)}})
		}
		put(said(map[string]any{"type": "text", "text": "## What changed\n\n" + text(1500) + "\n\n- **Retries** keyed\n- `ledger.refund()`\n\n```ts\nconst key = `refund:${id}`;\n```\n\n| Path | Keyed |\n|---|---|\n| refund | yes |\n"}))
	}
}

// BenchmarkChatHandlers runs GET …/transcript and GET …/draft for a Claude
// Code session whose pane shows a reply streaming in and whose record is
// about 4 MB: in the handler alone (server time, tmux and the file
// included), and over the wire (the app's request on loopback).
func BenchmarkChatHandlers(b *testing.B) {
	screenFile := filepath.Join(b.TempDir(), "screen.ansi")
	if err := os.WriteFile(screenFile, []byte(styledScreen()), 0o600); err != nil {
		b.Fatal(err)
	}
	var bx *Box
	c, _, sess := claudeBox(b, `cat "`+screenFile+`"; exec sleep 600`, func(x *Box) { bx = x })
	proj := transcript.ClaudeDirIn("", sess.Dir)
	os.MkdirAll(proj, 0o700)
	benchRecord(b, filepath.Join(proj, "5b84275f-0000.jsonl"), 4<<20, time.Now())
	path := "/v1/sessions/" + url.PathEscape(sess.Name)

	handler := func(h func(http.ResponseWriter, *http.Request) error, target string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", target, nil)
		r.SetPathValue("name", sess.Name)
		w := httptest.NewRecorder()
		if err := h(w, r); err != nil {
			b.Fatal(err)
		}
		return w
	}
	var page transcript.Result
	open := func() {
		w := handler(bx.transcript, path+"/transcript?since=0")
		page = transcript.Result{}
		if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || page.Source != "claude" || len(page.Items) == 0 {
			b.Fatalf("transcript: %v %s %d", err, page.Reason, len(page.Items))
		}
	}
	open()
	// The pane draws the screen once the stand-in has run.
	deadline := time.Now().Add(5 * time.Second)
	for {
		var d Draft
		json.Unmarshal(handler(bx.draft, path+"/draft").Body.Bytes(), &d)
		if d.Text != "" {
			break
		}
		if time.Now().After(deadline) {
			b.Fatal("the pane never showed a draft")
		}
		time.Sleep(50 * time.Millisecond)
	}

	b.Run("handler/transcript-open-cold", func(b *testing.B) {
		for b.Loop() {
			transcripts = transcript.NewReader()
			open()
		}
	})
	b.Run("handler/transcript-open-warm", func(b *testing.B) {
		for b.Loop() {
			open()
		}
	})
	b.Run("handler/transcript-poll-idle", func(b *testing.B) {
		open()
		poll := path + "/transcript?since=" + strconv.Itoa(page.Next) + "&gen=" + url.QueryEscape(page.Gen)
		for b.Loop() {
			handler(bx.transcript, poll)
		}
	})
	b.Run("handler/draft", func(b *testing.B) {
		for b.Loop() {
			handler(bx.draft, path+"/draft")
		}
	})
	get := func(b *testing.B, target string) {
		resp, err := c.DoWithHeader(context.Background(), "GET", target, nil, nil)
		if err != nil {
			b.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			b.Fatalf("%s: %d", target, resp.StatusCode)
		}
	}
	b.Run("wire/transcript-open-warm", func(b *testing.B) {
		for b.Loop() {
			get(b, path+"/transcript?since=0")
		}
	})
	b.Run("wire/transcript-poll-idle", func(b *testing.B) {
		open()
		poll := path + "/transcript?since=" + strconv.Itoa(page.Next) + "&gen=" + url.QueryEscape(page.Gen)
		for b.Loop() {
			get(b, poll)
		}
	})
	b.Run("wire/draft", func(b *testing.B) {
		for b.Loop() {
			get(b, path+"/draft")
		}
	})
}
