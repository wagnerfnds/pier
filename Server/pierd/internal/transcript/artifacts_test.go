package transcript

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// published is a publish's result as Claude Code writes it: the text, and
// the structured result beside it.
func published(id, text string, res any) m {
	l := user([]m{{"type": "tool_result", "tool_use_id": id, "content": text}})
	if res != nil {
		l["toolUseResult"] = res
	}
	return l
}

func artifactItems(items []Item) []Item {
	var out []Item
	for _, it := range items {
		if it.Kind == "artifact" {
			out = append(out, it)
		}
	}
	return out
}

func TestArtifactsPublished(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	page := filepath.Join(dir, "notes", "index.html")
	os.MkdirAll(filepath.Dir(page), 0o700)
	os.WriteFile(page, []byte("<!doctype html><html><head><style>body{}</style></head><body>\n<title>Release  &amp; QA notes</title>"), 0o600)
	write(t, p,
		user("Write up the results as a page"),
		assistant(tool("a1", "Artifact", m{"file_path": "/scratch/report/index.html", "description": "Benchmarks for the search change", "icon": "chart"})),
		published("a1", "Published /scratch/report/index.html at https://claude.ai/artifact/AAAAexample1 (Version 1)", m{"url": "https://claude.ai/artifact/AAAAexample1", "artifact_id": "id-1", "title": "Search Benchmarks", "updated": false, "seq": 1}),
		assistant(tool("r1", "Artifact", m{"action": "read", "url": "https://claude.ai/artifact/AAAAexample1"})),
		user([]m{{"type": "tool_result", "tool_use_id": "r1", "content": "<title>Search Benchmarks</title>"}}),
		// Published again: an update, and the latest wins.
		assistant(tool("a2", "Artifact", m{"file_path": "/scratch/report/index.html"})),
		published("a2", "Published /scratch/report/index.html at https://claude.ai/artifact/AAAAexample1 (Version 2)", m{"url": "https://claude.ai/artifact/AAAAexample1", "artifact_id": "id-1", "title": "Search Benchmarks v2", "updated": true, "seq": 2}),
		// No structured result: the link from the text, the title from the page.
		assistant(tool("a3", "Artifact", m{"file_path": page, "description": "What to check before release"})),
		published("a3", "Published "+page+" at https://claude.ai/code/artifact/0000-example-2\n\nTo update: …", nil),
		// A publish that failed is a card, not a page.
		assistant(tool("a4", "Artifact", m{"file_path": "/elsewhere/x.html", "root": "/elsewhere"})),
		user([]m{{"type": "tool_result", "tool_use_id": "a4", "is_error": true, "content": "root: \"/elsewhere\" is outside the working directory"}}),
		// Made from a type: its own link comes first, the type's after.
		assistant(tool("a5", "Artifact", m{"type_url": "https://claude.ai/artifact/TypeExample", "title": "Launch deck"})),
		published("a5", "Created a new Artifact at https://claude.ai/artifact/DeckExample (version 1) from the Artifact type https://claude.ai/artifact/TypeExample", m{"created_from_type": true, "url": "https://claude.ai/artifact/DeckExample", "title": "Launch deck"}),
		// An asset upload isn't a page.
		assistant(tool("a6", "Artifact", m{"url": "https://claude.ai/artifact/DeckExample", "file_path": "/scratch/logo.png", "asset": true})),
		published("a6", "Uploaded", nil),
		assistant(m{"type": "text", "text": "Published."}),
	)
	r := NewReader()
	res, err := r.Read("claude", p, dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := len(res.Artifacts); got != 3 {
		t.Fatalf("artifacts = %d, want 3: %+v", got, res.Artifacts)
	}
	// Newest last, a page where it was last published.
	a := res.Artifacts
	if a[0].URL != "https://claude.ai/artifact/AAAAexample1" || a[0].Title != "Search Benchmarks v2" || !a[0].Updated || a[0].Tool != "a2" || a[0].Description != "Benchmarks for the search change" {
		t.Errorf("republished = %+v", a[0])
	}
	if a[1].URL != "https://claude.ai/code/artifact/0000-example-2" || a[1].Title != "Release & QA notes" || a[1].Updated || a[1].Description != "What to check before release" || a[1].File != "index.html" {
		t.Errorf("from the page = %+v", a[1])
	}
	if a[2].URL != "https://claude.ai/artifact/DeckExample" || a[2].Title != "Launch deck" || a[2].At == 0 {
		t.Errorf("from a type = %+v", a[2])
	}
	items := artifactItems(res.Items)
	if len(items) != 5 {
		t.Fatalf("artifact items = %d, want 5 (%s)", len(items), kinds(res.Items))
	}
	if it := items[0]; it.Tool != "a1" || it.Text != "Search Benchmarks" || it.URL == "" || !it.Done || it.Updated {
		t.Errorf("first publish item = %+v", it)
	}
	if it := items[1]; it.Text != "Search Benchmarks v2" || !it.Updated {
		t.Errorf("republish item = %+v", it)
	}
	if it := items[3]; !it.Error || !it.Done || it.URL != "" {
		t.Errorf("failed publish item = %+v", it)
	}
	// Reading a page, or uploading to one, is a step.
	var steps []string
	for _, it := range res.Items {
		if it.Kind == "tools" {
			for _, c := range it.Items {
				steps = append(steps, c.Target)
			}
		}
	}
	if strings.Join(steps, ",") != "Artifact read,Artifact upload" {
		t.Errorf("steps = %v", steps)
	}
}

func TestArtifactSettlesAfterSent(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	write(t, p,
		user("Publish it"),
		assistant(tool("a1", "Artifact", m{"file_path": "/scratch/page.html"})),
	)
	r := NewReader()
	res, _ := r.Read("claude", p, dir, 0)
	it := artifactItems(res.Items)
	if len(it) != 1 || it[0].Done || it[0].Text != "page.html" || len(res.Artifacts) != 0 {
		t.Fatalf("waiting: %+v %+v", it, res.Artifacts)
	}
	// Still waiting: it comes again.
	again, _ := r.Read("claude", p, dir, res.Next)
	if len(artifactItems(again.Items)) != 1 {
		t.Fatalf("a waiting publish isn't sent again: %s", kinds(again.Items))
	}
	write(t, p, published("a1", "Published at https://claude.ai/artifact/PageExample", m{"url": "https://claude.ai/artifact/PageExample", "title": "The Page"}))
	settled, _ := r.Read("claude", p, dir, res.Next)
	it = artifactItems(settled.Items)
	if len(it) != 1 || !it[0].Done || it[0].URL != "https://claude.ai/artifact/PageExample" || it[0].Text != "The Page" || it[0].ID != artifactItems(res.Items)[0].ID {
		t.Fatalf("settled: %+v", it)
	}
	if len(settled.Artifacts) != 1 {
		t.Fatalf("artifacts = %+v", settled.Artifacts)
	}
	// Once the conversation has moved on, it isn't sent again.
	write(t, p, assistant(m{"type": "text", "text": "Here it is."}))
	moved, _ := r.Read("claude", p, dir, settled.Next)
	moved2, _ := r.Read("claude", p, dir, moved.Next)
	if n := len(artifactItems(moved2.Items)); n != 0 {
		t.Fatalf("sent again after the conversation moved on: %s", kinds(moved2.Items))
	}
	if len(moved2.Artifacts) != 1 {
		t.Fatalf("every answer lists the artifacts: %+v", moved2.Artifacts)
	}
}

func TestArtifactInterrupted(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	write(t, p,
		user("Publish it"),
		assistant(tool("a1", "Artifact", m{"file_path": "/scratch/page.html"})),
		user("Actually, stop"),
	)
	r := NewReader()
	res, _ := r.Read("claude", p, dir, 0)
	it := artifactItems(res.Items)
	if len(it) != 1 || !it[0].Done || it[0].URL != "" {
		t.Fatalf("an unanswered publish settles at the next prompt: %+v", it)
	}
	if len(res.Artifacts) != 0 {
		t.Fatalf("nothing was published: %+v", res.Artifacts)
	}
}

func TestArtifactsKept(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	var lines []any
	for i := 0; i < keepArtifacts+5; i++ {
		id := "a" + itoa(i)
		u := "https://claude.ai/artifact/Example" + itoa(i)
		lines = append(lines, assistant(tool(id, "Artifact", m{"file_path": "/scratch/p" + itoa(i) + ".html"})), published(id, "Published at "+u, m{"url": u, "title": "Page " + itoa(i)}))
	}
	write(t, p, lines...)
	res, _ := NewReader().Read("claude", p, dir, 0)
	if len(res.Artifacts) != keepArtifacts || res.Artifacts[0].Title != "Page 5" || res.Artifacts[keepArtifacts-1].Title != "Page "+itoa(keepArtifacts+4) {
		t.Fatalf("kept %d, first %q", len(res.Artifacts), res.Artifacts[0].Title)
	}
}

func TestHTMLTitle(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(body), 0o600)
		return p
	}
	if got := htmlTitle(write("a.html", "<html><head><TITLE>\n  A   page\n</TITLE>")); got != "A page" {
		t.Errorf("title = %q", got)
	}
	if got := htmlTitle(write("b.md", "<title>Not HTML</title>")); got != "" {
		t.Errorf("a .md file's title = %q", got)
	}
	if got := htmlTitle(write("c.html", strings.Repeat("x", maxTitleRead)+"<title>Too far</title>")); got != "" {
		t.Errorf("read past the start: %q", got)
	}
	if got := htmlTitle("relative.html"); got != "" {
		t.Errorf("relative path read: %q", got)
	}
}
