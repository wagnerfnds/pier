package transcript

import (
	"path/filepath"
	"strings"
	"testing"
)

// A long conversation: prompts each answered with a read and a reply.
func longChat(t *testing.T, p string, turns int) {
	t.Helper()
	for i := 0; i < turns; i++ {
		n := itoa(i)
		u := user("prompt " + n)
		u["uuid"], u["parentUuid"] = "u-"+n+"-0000", "p-"+n+"-0000"
		write(t, p,
			u,
			assistant(tool("r"+n, "Read", m{"file_path": "/w/f" + n + ".go"})),
			result("r"+n),
			assistant(m{"type": "text", "text": "reply " + n}),
		)
	}
}

func texts(items []Item) []string {
	var out []string
	for _, it := range items {
		switch it.Kind {
		case "user", "text":
			out = append(out, it.Text)
		case "tools":
			out = append(out, "tools:"+it.Items[0].Target)
		}
	}
	return out
}

func TestPagesReachTheStartWithoutRepeats(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	longChat(t, p, 400) // 1200 items: 300 live, the rest in pages
	r := NewReader()
	live, err := r.Read("claude", p, "/w", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(live.Items) != keep || !live.Truncated {
		t.Fatalf("live = %d items, truncated %v", len(live.Items), live.Truncated)
	}
	first := live.Items[0]
	if first.Off == 0 {
		t.Fatal("live items carry no offset")
	}
	all := texts(live.Items)
	seen := map[string]bool{}
	before, pages := first.Off, 0
	for {
		page, err := Before("claude", p, "/w", before, 250)
		if err != nil {
			t.Fatal(err)
		}
		if len(page.Items) == 0 {
			t.Fatal("an empty page")
		}
		for _, it := range page.Items {
			if seen[it.ID] || it.Off >= before {
				t.Fatalf("item %+v repeats or is past %d", it, before)
			}
			seen[it.ID] = true
			if it.Kind == "tools" && !it.Done {
				t.Fatalf("an older group is still open: %+v", it)
			}
		}
		all = append(texts(page.Items), all...)
		before = page.Items[0].Off
		pages++
		if !page.More {
			break
		}
	}
	if len(all) != 1200 || all[0] != "prompt 0" || all[1] != "tools:f0.go" || all[1199] != "reply 399" {
		t.Fatalf("paged %d items in %d pages: first %v", len(all), pages, all[:3])
	}
	for i := 0; i < 400; i++ {
		if all[i*3] != "prompt "+itoa(i) {
			t.Fatalf("item %d = %q", i*3, all[i*3])
		}
	}
}

func TestPromptsCarryTheirEntry(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	longChat(t, p, 2)
	res, _ := NewReader().Read("claude", p, "/w", 0)
	u := res.Items[3]
	if u.Kind != "user" || u.UUID != "u-1-0000" || u.Parent != "p-1-0000" || u.Off == 0 {
		t.Fatalf("prompt = %+v", u)
	}
}

// After /rewind, the next prompt picks up where the rewound one did: it
// and what followed it are gone from the conversation.
func TestRewindDropsTheRewoundTurn(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.jsonl")
	longChat(t, p, 3)
	r := NewReader()
	before, _ := r.Read("claude", p, "/w", 0)
	if len(before.Items) != 9 {
		t.Fatalf("items = %d", len(before.Items))
	}
	again := user("prompt 1, said differently")
	again["uuid"], again["parentUuid"] = "u-again-0000", "p-1-0000"
	write(t, p, again, assistant(m{"type": "text", "text": "a different reply"}))
	after, _ := r.Read("claude", p, "/w", 0)
	got := strings.Join(texts(after.Items), "|")
	if got != "prompt 0|tools:f0.go|reply 0|prompt 1, said differently|a different reply" {
		t.Fatalf("after rewind: %s", got)
	}
	if after.Next >= before.Next {
		t.Fatalf("next %d → %d: the app wouldn't read it afresh", before.Next, after.Next)
	}
}
