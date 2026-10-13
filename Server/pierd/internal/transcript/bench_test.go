package transcript

import (
	"encoding/json"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// What a chat costs the box: reading a long Claude Code record afresh
// (?since=0 on a conversation not yet followed, or after pierd restarts),
// the same window again (a chat opened on one already followed), and the
// polls that follow it, with nothing new or one line more. The record is
// synthetic, shaped and sized as Claude Code 2.1 writes one (by line type,
// as measured on real records): tool results, kept twice (in the message
// and in toolUseResult), are most of it.

// fakeText is deterministic filler of about n bytes in words of a chat.
func fakeText(r *rand.Rand, n int) string {
	words := []string{"the", "webhook", "retries", "order", "não", "está", "função", "payment", "ledger", "handler", "config", "test", "fails", "because", "async", "await", "cache", "índice", "migração", "user", "invoice", "token", "build", "deploy", "error", "value", "returns", "null", "when", "is"}
	var b strings.Builder
	for b.Len() < n {
		b.WriteString(words[r.IntN(len(words))])
		if r.IntN(12) == 0 {
			b.WriteString(".\n")
		} else {
			b.WriteByte(' ')
		}
	}
	return b.String()
}

// fakeCode is about n bytes of numbered source lines, as Read returns them.
func fakeCode(r *rand.Rand, n int) string {
	var b strings.Builder
	for i := 1; b.Len() < n; i++ {
		b.WriteString(strconv.Itoa(i) + "\t")
		switch r.IntN(4) {
		case 0:
			b.WriteString("export async function handle" + strconv.Itoa(r.IntN(99)) + "(req: Request): Promise<Response> {\n")
		case 1:
			b.WriteString("  const order = await db.orders.findUnique({ where: { id: req.params.id } });\n")
		case 2:
			b.WriteString("  if (!order) throw new HttpError(404, `order ${req.params.id} não encontrado`);\n")
		default:
			b.WriteString("  return json({ ok: true, retries: order.retries + 1 });\n")
		}
	}
	return b.String()
}

// fakeReply is an agent's Markdown answer of about n bytes: a heading,
// prose, a list, code and a table.
func fakeReply(r *rand.Rand, n int) string {
	var b strings.Builder
	b.WriteString("## What changed\n\n" + fakeText(r, n/4) + "\n\n")
	b.WriteString("- **Retries** are keyed by `idempotency_key`\n- **Refunds** go through `ledger.refund()`\n- Tests: `pnpm test payments`\n\n")
	b.WriteString("```ts\n" + fakeCode(r, n/4) + "```\n\n")
	b.WriteString("| Path | Keyed | Notes |\n|---|---|---|\n")
	for b.Len() < n {
		b.WriteString("| `apps/web/" + strconv.Itoa(r.IntN(99)) + ".ts` | yes | " + fakeText(r, 40) + " |\n")
	}
	return b.String()
}

// claudeRecord writes a synthetic Claude Code 2.1 record of at least size
// bytes to path, its lines timed from start, and returns how many turns it
// holds.
func claudeRecord(tb testing.TB, path string, size int64, start time.Time) int {
	tb.Helper()
	f, err := os.Create(path)
	if err != nil {
		tb.Fatal(err)
	}
	defer f.Close()
	r := rand.New(rand.NewPCG(1, 2))
	at, prev, n := start, "", 0
	var written int64
	put := func(typ string, msg any, extra map[string]any) {
		n++
		at = at.Add(1500 * time.Millisecond)
		l := map[string]any{"parentUuid": prev, "isSidechain": false, "userType": "external", "cwd": "/w/acme", "sessionId": "5b84275f-0000", "version": "2.1.296", "gitBranch": "main", "type": typ, "uuid": "u-" + strconv.Itoa(n), "timestamp": at.Format(time.RFC3339Nano)}
		if msg != nil {
			l["message"] = msg
		}
		for k, v := range extra {
			l[k] = v
		}
		prev = "u-" + strconv.Itoa(n)
		b, _ := json.Marshal(l)
		w, _ := f.Write(append(b, '\n'))
		written += int64(w)
	}
	usage := map[string]any{"input_tokens": 12, "cache_creation_input_tokens": 1800, "cache_read_input_tokens": 41000, "output_tokens": 420}
	said := func(blocks ...map[string]any) map[string]any {
		return map[string]any{"model": "claude-opus-5-5", "id": "msg_" + strconv.Itoa(n), "type": "message", "role": "assistant", "content": blocks, "usage": usage}
	}
	results := func(id, text string, res map[string]any) {
		put("user", map[string]any{"role": "user", "content": []map[string]any{{"type": "tool_result", "tool_use_id": id, "content": text}}}, map[string]any{"toolUseResult": res, "sourceToolAssistantUUID": prev})
	}
	turns := 0
	for written < size {
		turns++
		put("permission-mode", nil, map[string]any{"permissionMode": "default"})
		put("user", map[string]any{"role": "user", "content": fakeText(r, 120+r.IntN(500))}, map[string]any{"origin": map[string]any{"kind": "human"}, "promptSource": "typed", "permissionMode": "default", "promptId": "p-" + strconv.Itoa(turns)})
		put("last-prompt", nil, map[string]any{"lastPrompt": "…"})
		put("assistant", said(map[string]any{"type": "text", "text": "I'll trace the " + fakeText(r, 200)}), nil)
		for k := 0; k < 6; k++ {
			put("assistant", said(map[string]any{"type": "thinking", "thinking": fakeText(r, 2500), "signature": strings.Repeat("Ep8B", 100)}), nil)
			id := "toolu_" + strconv.Itoa(turns) + "_" + strconv.Itoa(k)
			file := "/w/acme/apps/web/src/payments/handler" + strconv.Itoa(k) + ".ts"
			switch k % 4 {
			case 0:
				put("assistant", said(map[string]any{"type": "tool_use", "id": id, "name": "Read", "input": map[string]any{"file_path": file}}), nil)
				code := fakeCode(r, 6000+r.IntN(14000))
				results(id, code, map[string]any{"type": "text", "file": map[string]any{"filePath": file, "content": code, "numLines": 300, "startLine": 1, "totalLines": 300}})
			case 1:
				put("assistant", said(map[string]any{"type": "tool_use", "id": id, "name": "Grep", "input": map[string]any{"pattern": "idempotency_key", "path": "/w/acme", "output_mode": "content"}}), nil)
				out := fakeCode(r, 1500)
				results(id, out, map[string]any{"mode": "content", "content": out, "numLines": 40})
			case 2:
				put("assistant", said(map[string]any{"type": "tool_use", "id": id, "name": "Bash", "input": map[string]any{"command": "pnpm test payments -- --reporter=verbose", "description": "Run the payment tests"}}), nil)
				out := fakeText(r, 4000+r.IntN(24000))
				results(id, out, map[string]any{"stdout": out, "stderr": "", "interrupted": false, "isImage": false})
			default:
				old, neu := fakeCode(r, 600+r.IntN(1500)), fakeCode(r, 800+r.IntN(1800))
				put("assistant", said(map[string]any{"type": "tool_use", "id": id, "name": "Edit", "input": map[string]any{"file_path": file, "old_string": old, "new_string": neu}}), nil)
				results(id, "The file "+file+" has been updated successfully.", map[string]any{"filePath": file, "oldString": old, "newString": neu, "originalFile": fakeCode(r, 8000+r.IntN(16000)), "structuredPatch": []map[string]any{{"oldStart": 10, "oldLines": 12, "newStart": 10, "newLines": 15, "lines": strings.Split(neu, "\n")}}, "userModified": false, "replaceAll": false})
			}
			put("attachment", nil, map[string]any{"attachment": map[string]any{"type": "hook_success", "hookName": "PostToolUse:Edit", "toolUseID": id, "hookEvent": "PostToolUse", "content": "", "stdout": fakeText(r, 300), "stderr": "", "exitCode": 0}})
		}
		put("assistant", said(map[string]any{"type": "text", "text": fakeReply(r, 1500+r.IntN(3000))}), nil)
		put("system", nil, map[string]any{"subtype": "turn_duration", "durationMs": 64000, "isMeta": false})
	}
	return turns
}

// benchRecord is a record of about 4 MB, the most a first read takes.
func benchRecord(b *testing.B) string {
	b.Helper()
	p := filepath.Join(b.TempDir(), "5b84275f-0000.jsonl")
	turns := claudeRecord(b, p, maxStart, time.Now().Add(-time.Hour))
	st, _ := os.Stat(p)
	b.Logf("record: %d KB, %d turns", st.Size()>>10, turns)
	return p
}

// encoded is the size of an answer as the handler writes it.
func encoded(b *testing.B, res Result) int {
	var c counter
	if err := json.NewEncoder(&c).Encode(res); err != nil {
		b.Fatal(err)
	}
	return int(c)
}

type counter int

func (c *counter) Write(p []byte) (int, error) { *c += counter(len(p)); return len(p), nil }

// BenchmarkTranscriptOpen is ?since=0: on a record not yet followed (read
// and parsed whole), and on one followed already (the window again), each
// with the answer encoded as the handler sends it.
func BenchmarkTranscriptOpen(b *testing.B) {
	p := benchRecord(b)
	b.Run("cold", func(b *testing.B) {
		var res Result
		for b.Loop() {
			var err error
			if res, err = NewReader().Follow("claude", p, "/w/acme", 0, ""); err != nil {
				b.Fatal(err)
			}
		}
		b.ReportMetric(float64(len(res.Items)), "items")
	})
	b.Run("cold+encode", func(b *testing.B) {
		size := 0
		for b.Loop() {
			res, err := NewReader().Follow("claude", p, "/w/acme", 0, "")
			if err != nil {
				b.Fatal(err)
			}
			size = encoded(b, res)
		}
		b.ReportMetric(float64(size), "json-bytes")
	})
	b.Run("warm+encode", func(b *testing.B) {
		r := NewReader()
		r.Follow("claude", p, "/w/acme", 0, "")
		size := 0
		for b.Loop() {
			res, err := r.Follow("claude", p, "/w/acme", 0, "")
			if err != nil {
				b.Fatal(err)
			}
			size = encoded(b, res)
		}
		b.ReportMetric(float64(size), "json-bytes")
	})
}

// BenchmarkTranscriptPoll is ?since=next&gen=G as a chat polls it: nothing
// new, and one line more each time (a step's result, the largest kind).
func BenchmarkTranscriptPoll(b *testing.B) {
	p := benchRecord(b)
	b.Run("idle", func(b *testing.B) {
		r := NewReader()
		res, _ := r.Follow("claude", p, "/w/acme", 0, "")
		size := 0
		for b.Loop() {
			next, err := r.Follow("claude", p, "/w/acme", res.Next, res.Gen)
			if err != nil || next.Reset {
				b.Fatal(err, next.Reset)
			}
			size = encoded(b, next)
		}
		b.ReportMetric(float64(size), "json-bytes")
	})
	b.Run("one-line", func(b *testing.B) {
		r := NewReader()
		res, _ := r.Follow("claude", p, "/w/acme", 0, "")
		f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
		if err != nil {
			b.Fatal(err)
		}
		defer f.Close()
		rnd := rand.New(rand.NewPCG(3, 4))
		i, size := 0, 0
		b.ResetTimer()
		for b.Loop() {
			b.StopTimer()
			i++
			id := "toolu_poll_" + strconv.Itoa(i)
			// A few words, then a step begun: read first, as a chat reads
			// them, so the line measured is the step's result.
			words, _ := json.Marshal(assistant(m{"type": "text", "text": fakeText(rnd, 300)}))
			call, _ := json.Marshal(assistant(tool(id, "Bash", m{"command": "pnpm test"})))
			f.Write(append(append(words, '\n'), append(call, '\n')...))
			res, _ = r.Follow("claude", p, "/w/acme", res.Next, res.Gen)
			out := fakeText(rnd, 8000)
			line, _ := json.Marshal(m{"type": "user", "timestamp": time.Now().Format(time.RFC3339Nano), "message": m{"role": "user", "content": []m{{"type": "tool_result", "tool_use_id": id, "content": out}}}, "toolUseResult": m{"stdout": out}})
			f.Write(append(line, '\n'))
			b.StartTimer()
			next, err := r.Follow("claude", p, "/w/acme", res.Next, res.Gen)
			if err != nil || next.Reset || len(next.Items) == 0 {
				b.Fatal(err, next.Reset, len(next.Items))
			}
			size = encoded(b, next)
			res = next
		}
		b.ReportMetric(float64(size), "json-bytes")
	})
}
