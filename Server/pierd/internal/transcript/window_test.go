package transcript

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The chat never loses a turn its record still has: a window read afresh
// (a restart, a conversation let go while no one looked) names its items
// as before and says so, a paste reads as typed, and compaction and resume
// stay in one conversation. Every transcript here is synthetic, shaped as
// Claude Code 2.1 writes them.

// bigChat writes turns until the file passes size: each a prompt, a run,
// its (large) output and a reply.
func bigChat(t *testing.T, p string, from int, size int64) int {
	t.Helper()
	pad := strings.Repeat("x", 16<<10)
	i := from
	for {
		n := itoa(i)
		u := user("prompt " + n)
		u["uuid"], u["parentUuid"] = "u-"+n, "a-"+itoa(i-1)
		out := user([]m{{"type": "tool_result", "tool_use_id": "b" + n, "content": pad}})
		reply := assistant(m{"type": "text", "text": "reply " + n})
		reply["uuid"] = "a-" + n
		write(t, p, u, assistant(tool("b"+n, "Bash", m{"command": "make " + n})), out, reply)
		i++
		if st, _ := os.Stat(p); st.Size() >= size {
			return i
		}
	}
}

// prompts are the prompts in items, in order.
func prompts(items []Item) []string {
	var out []string
	for _, it := range items {
		if it.Kind == "user" {
			out = append(out, it.Text)
		}
	}
	return out
}

func TestWindowReadAfreshNamesItsItemsAsBefore(t *testing.T) {
	p := filepath.Join(t.TempDir(), "conv.jsonl")
	n := bigChat(t, p, 0, maxStart+(1<<20))
	first, err := NewReader().Follow("claude", p, "/w", 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if !first.Truncated || first.Gen == "" || first.File != "conv" || first.Start != first.Items[0].Off {
		t.Fatalf("first read: truncated %v gen %q file %q start %d", first.Truncated, first.Gen, first.File, first.Start)
	}
	ids := map[string]string{}
	for _, it := range first.Items {
		ids[it.ID] = it.Kind + ":" + it.Text
	}
	// pierd restarts (or lets the conversation go) as the agent writes a
	// little more: a new reader, its window a little further on.
	n = bigChat(t, p, n, maxStart+(1<<20)+(128<<10))
	soon, err := NewReader().Follow("claude", p, "/w", first.Next, first.Gen)
	if err != nil {
		t.Fatal(err)
	}
	if !soon.Reset || soon.Gen == first.Gen || soon.Start <= first.Start || soon.Start != soon.Items[0].Off {
		t.Fatalf("a window read afresh: reset %v gen %q→%q start %d→%d", soon.Reset, first.Gen, soon.Gen, first.Start, soon.Start)
	}
	// What it shares with the first reading has the same names.
	shared := 0
	for _, it := range soon.Items {
		if was, ok := ids[it.ID]; ok {
			shared++
			if was != it.Kind+":"+it.Text {
				t.Fatalf("%s was %q, is %s:%q", it.ID, was, it.Kind, it.Text)
			}
		}
	}
	if shared == 0 {
		t.Fatal("the two windows share no item")
	}
	// Then the agent writes on a long while no one looks: the next window
	// starts past everything the app held.
	n = bigChat(t, p, n, maxStart+(4<<20))
	again, err := NewReader().Follow("claude", p, "/w", first.Next, first.Gen)
	if err != nil {
		t.Fatal(err)
	}
	if !again.Reset || again.Start <= first.Items[len(first.Items)-1].Off {
		t.Fatalf("a window past what was held: reset %v start %d", again.Reset, again.Start)
	}
	// What the app held before the new window, plus the pages between,
	// plus the window: every prompt once, in order.
	var all []Item
	for _, it := range first.Items {
		if it.Off < again.Start {
			all = append(all, it)
		}
	}
	held := all[len(all)-1].Off
	var gap []Item
	for before := again.Start; ; {
		page, err := Before("claude", p, "/w", before, 200)
		if err != nil {
			t.Fatal(err)
		}
		var fresh []Item
		for _, it := range page.Items {
			if it.Off > held {
				fresh = append(fresh, it)
			}
		}
		gap = append(fresh, gap...)
		if len(fresh) < len(page.Items) || !page.More || len(page.Items) == 0 {
			break
		}
		before = page.Items[0].Off
	}
	all = append(append(all, gap...), again.Items...)
	got := prompts(all)
	start := strings.TrimPrefix(got[0], "prompt ")
	for i, s := range got {
		if want := "prompt " + itoa(atoi(start)+i); s != want {
			t.Fatalf("prompt %d = %q, want %q (of %d)", i, s, want, n)
		}
	}
	if got[len(got)-1] != "prompt "+itoa(n-1) {
		t.Fatalf("last prompt %q, want prompt %d", got[len(got)-1], n-1)
	}
	seen := map[string]bool{}
	for _, it := range all {
		if seen[it.ID] {
			t.Fatalf("%s twice", it.ID)
		}
		seen[it.ID] = true
	}
}

func atoi(s string) int {
	n := 0
	for _, r := range s {
		n = n*10 + int(r-'0')
	}
	return n
}

func TestReadingTheSameGenerationGoesOn(t *testing.T) {
	p := filepath.Join(t.TempDir(), "conv.jsonl")
	write(t, p, user("first"), assistant(m{"type": "text", "text": "one"}))
	r := NewReader()
	a, _ := r.Follow("claude", p, "", 0, "")
	write(t, p, user("second"))
	b, _ := r.Follow("claude", p, "", a.Next, a.Gen)
	if b.Reset || b.Gen != a.Gen || strings.Join(prompts(b.Items), ",") != "second" {
		t.Fatalf("a poll in the same reading: reset %v gen %q→%q items %+v", b.Reset, a.Gen, b.Gen, b.Items)
	}
}

func TestPollingBehindTheKeptItemsIsAReset(t *testing.T) {
	p := filepath.Join(t.TempDir(), "conv.jsonl")
	write(t, p, user("first"))
	r := NewReader()
	a, _ := r.Follow("claude", p, "", 0, "")
	var lines []any
	for i := 0; i < keep+20; i++ {
		lines = append(lines, assistant(m{"type": "text", "text": "line " + itoa(i)}))
	}
	write(t, p, lines...)
	b, _ := r.Follow("claude", p, "", a.Next, a.Gen)
	if !b.Reset || len(b.Items) != keep || b.Start != b.Items[0].Off {
		t.Fatalf("more than a window since the last poll: reset %v, %d items, start %d", b.Reset, len(b.Items), b.Start)
	}
}

func TestRewindStartsANewGeneration(t *testing.T) {
	p := filepath.Join(t.TempDir(), "conv.jsonl")
	a1 := user("first")
	a1["uuid"], a1["parentUuid"] = "u1", "root"
	write(t, p, a1, assistant(m{"type": "text", "text": "one"}))
	r := NewReader()
	a, _ := r.Follow("claude", p, "", 0, "")
	again := user("first, again")
	again["uuid"], again["parentUuid"] = "u2", "root" // picks up where "first" did
	write(t, p, again)
	b, _ := r.Follow("claude", p, "", a.Next, a.Gen)
	if !b.Reset || b.Gen == a.Gen || strings.Join(prompts(b.Items), ",") != "first, again" {
		t.Fatalf("after a rewind: reset %v items %+v", b.Reset, b.Items)
	}
}

// Claude Code 2.1 closes a paste with its id: </pasted_content id="…">.
func TestPasteClosedWithItsIDShows(t *testing.T) {
	p := filepath.Join(t.TempDir(), "conv.jsonl")
	write(t, p,
		user("\n\n<pasted_content id=\"a1b2\">\nQUERY PLAN\n  Seq Scan on t\n</pasted_content id=\"a1b2\">\n"),
		user("<pasted_content id=\"c3\">\nhalf a paste"),
		user("before <pasted_content id=\"d4\">\nthe log\n</pasted_content id=\"d4\"> and after"),
	)
	res, _ := NewReader().Read("claude", p, "", 0)
	got := prompts(res.Items)
	want := []string{"QUERY PLAN\n  Seq Scan on t", "half a paste", "before the log and after"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("prompts %q, want %q", got, want)
	}
}

// Claude Code 2.1 compacts and resumes in the conversation's own file: the
// chat keeps every turn, the compaction a divider between them.
func TestCompactAndResumeKeepEveryTurn(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "conv.jsonl")
	start := func(source string) m {
		return m{"type": "attachment", "parentUuid": nil, "attachment": m{"type": "hook_success", "hookName": "SessionStart:" + source}}
	}
	ask := func(n, parent string) m {
		u := user(n)
		u["uuid"], u["parentUuid"] = "u-"+n, parent
		return u
	}
	reply := func(n string) m {
		a := assistant(m{"type": "text", "text": "re " + n})
		a["uuid"] = "a-" + n
		return a
	}
	write(t, p, start("startup"), ask("one", "h"), reply("one"), ask("two", "a-one"), reply("two"))
	write(t, p, user("/compact"),
		m{"type": "system", "subtype": "compact_boundary", "parentUuid": nil, "logicalParentUuid": "a-two", "uuid": "cb"},
		m{"type": "user", "isCompactSummary": true, "parentUuid": "cb", "uuid": "sum", "message": m{"role": "user", "content": "This session is being continued…"}},
		ask("three", "sum"), reply("three"))
	write(t, p, start("resume"), ask("four", "a-three"), reply("four"))
	r := NewReader()
	res, _ := r.Read("claude", p, dir, 0)
	if got := strings.Join(prompts(res.Items), ","); got != "one,two,three,four" {
		t.Fatalf("prompts %q", got)
	}
	compacted := 0
	for _, it := range res.Items {
		if it.Kind == "command" && it.Command == "/compact" && it.Text != "" {
			compacted++
		}
	}
	if compacted != 1 || kinds(res.Items) != "user,text,user,text,command,user,text,user,text" {
		t.Fatalf("one compaction divider, between the turns: %s", kinds(res.Items))
	}
	// Pages read across the compaction too.
	page, _ := Before("claude", p, dir, res.Items[len(res.Items)-2].Off, 50)
	if got := strings.Join(prompts(page.Items), ","); got != "one,two,three" {
		t.Fatalf("a page before the last turn: %q", got)
	}
}

// Two agents in one folder: one whose hooks named its conversation, which
// Claude Code writes only at its first prompt, never takes its sibling's.
func TestAssignClaudeNamedAgentWaitsForItsOwnFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", home)
	dir := "/w/two"
	proj := ClaudeDirIn("", dir)
	os.MkdirAll(proj, 0o700)
	t0 := time.Now().Add(-time.Minute)
	sib := filepath.Join(proj, "bbbbbbbb-2.jsonl")
	write(t, sib, m{"type": "user", "timestamp": t0.Add(30 * time.Second).Format(time.RFC3339Nano), "message": m{"role": "user", "content": "the sibling's"}})
	claims := []Claim{
		{Name: "named", ID: "aaaaaaaa-1", Started: t0},
		{Name: "sibling", Started: t0.Add(20 * time.Second)},
	}
	got := AssignClaude(dir, claims)
	if got["named"] != "" || got["sibling"] != sib {
		t.Fatalf("before the named agent writes: %v", got)
	}
	own := filepath.Join(proj, "aaaaaaaa-1.jsonl")
	write(t, own, user("mine"))
	got = AssignClaude(dir, claims)
	if got["named"] != own || got["sibling"] != sib {
		t.Fatalf("once it writes: %v", got)
	}
}
