package transcript

import (
	"encoding/json"
	"html"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Artifacts are the pages an agent published on claude.ai with Claude
// Code's Artifact tool. Each publish is an "artifact" item where it
// happened (its title and link once the result says them), and the
// conversation keeps one entry per page, its latest publish winning: a
// republish to the same page is an update. Only what the transcript says
// is read, as its lines go by; reading an artifact, listing them and the
// other actions are ordinary tool calls.

// Artifact is one page the agent published. Tool is the call that last
// published it, for "Show in chat"; Updated says it was published more
// than once (here, or before this conversation, as the result says).
type Artifact struct {
	URL         string `json:"url"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	File        string `json:"file,omitempty"`
	At          int64  `json:"at"`
	Tool        string `json:"tool"`
	Updated     bool   `json:"updated,omitempty"`

	// key is the page's ID when the result names it, else its URL: the
	// same page can be linked as /artifact/{slug} and /code/artifact/{id}.
	key string
}

const (
	// keepArtifacts is how many pages a conversation lists, newest kept.
	keepArtifacts = 40
	// maxTitleRead is how much of a published HTML file is read for its
	// <title>, when the result doesn't say it.
	maxTitleRead = 32 << 10
)

// artCall is a publish waiting for its result.
type artCall struct {
	item  int // absolute index of its item
	file  string
	title string
	desc  string
}

var (
	artifactURL = regexp.MustCompile(`https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]+`)
	htmlTitleRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
)

// claudeArtifact reads an Artifact tool call. A publish (no action, or
// "publish"; not an asset upload) becomes an artifact item and reports
// true; anything else is left to be an ordinary step.
func claudeArtifact(c *conv, bl claudeBlock, in map[string]any) bool {
	str := func(k string) string { v, _ := in[k].(string); return strings.TrimSpace(v) }
	if a := str("action"); a != "" && a != "publish" {
		return false
	}
	if asset, _ := in["asset"].(bool); asset {
		return false
	}
	file := str("file_path")
	it := Item{Kind: "artifact", ID: c.id(), Tool: bl.ID, Text: clip(firstNonEmpty(str("title"), filepath.Base(file)), 200), File: filepath.Base(file), Description: clip(str("description"), 300)}
	if it.File == "." {
		it.File = ""
	}
	// A republish names its page.
	if u := artifactURL.FindString(str("url")); u != "" {
		it.URL = u
	}
	i := c.add(it)
	if bl.ID != "" {
		if c.artCalls == nil {
			c.artCalls = map[string]artCall{}
		}
		c.artCalls[bl.ID] = artCall{item: i, file: file, title: str("title"), desc: str("description")}
		c.byTool[bl.ID] = -1
	}
	return true
}

// published reads a publish's result: the page's link and title from the
// structured result Claude Code writes beside the text (toolUseResult),
// else from the text itself.
func (c *conv) published(toolID string, line []byte, text string, failed bool, at int64) {
	call, ok := c.artCalls[toolID]
	if !ok {
		return
	}
	delete(c.artCalls, toolID)
	it := c.at(call.item)
	if it != nil && (it.Kind != "artifact" || it.Tool != toolID) {
		it = nil // rewound past it, or dropped off
	}
	settle := func() {
		if it != nil {
			it.Done = true
			it.resolved = c.base + len(c.items)
		}
	}
	if failed {
		if it != nil {
			it.Error = true
		}
		settle()
		return
	}
	var x struct {
		Result json.RawMessage `json:"toolUseResult"`
	}
	var r struct {
		URL     string `json:"url"`
		Title   string `json:"title"`
		ID      string `json:"artifact_id"`
		Updated bool   `json:"updated"`
	}
	if json.Unmarshal(line, &x) == nil && len(x.Result) > 0 && x.Result[0] == '{' {
		_ = json.Unmarshal(x.Result, &r)
	}
	url := artifactURL.FindString(r.URL)
	if url == "" {
		// The first link in the text is the page published; a page made
		// from a type names the type after it.
		url = artifactURL.FindString(text)
	}
	if url == "" {
		settle()
		return
	}
	title := strings.TrimSpace(r.Title)
	if title == "" {
		title = htmlTitle(call.file)
	}
	title = clip(firstNonEmpty(title, call.title, filepath.Base(call.file), "Artifact"), 200)
	key := firstNonEmpty(r.ID, url)
	a := Artifact{URL: url, Title: title, Description: clip(call.desc, 300), File: filepath.Base(call.file), At: at, Tool: toolID, Updated: r.Updated, key: key}
	if a.File == "." {
		a.File = ""
	}
	// The latest publish of a page wins, and moves it to the end.
	for i, o := range c.arts {
		if o.key == key || o.URL == url {
			a.Updated = true
			if a.Description == "" {
				a.Description = o.Description
			}
			c.arts = append(c.arts[:i], c.arts[i+1:]...)
			break
		}
	}
	c.arts = append(c.arts, a)
	if over := len(c.arts) - keepArtifacts; over > 0 {
		c.arts = append(c.arts[:0:0], c.arts[over:]...)
	}
	if it != nil {
		it.URL, it.Text, it.Updated = url, title, a.Updated
		if a.Description != "" {
			it.Description = a.Description
		}
	}
	settle()
}

// closeArtifacts settles the cards of publishes still without a result (a
// turn the person interrupted) once a prompt arrives, so none waits for
// ever; a result that does come later still fills its card in. Calls whose
// card has dropped off are forgotten.
func (c *conv) closeArtifacts() {
	for id, call := range c.artCalls {
		it := c.at(call.item)
		if it == nil || it.Kind != "artifact" || it.Tool != id {
			delete(c.artCalls, id)
			continue
		}
		if !it.Done {
			it.Done = true
			it.resolved = c.base + len(c.items)
		}
	}
}

// htmlTitle is an HTML file's <title>, read from its start: what claude.ai
// names a page whose publish didn't say.
func htmlTitle(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".html", ".htm":
	default:
		return ""
	}
	if !filepath.IsAbs(path) {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		return ""
	}
	b, _ := io.ReadAll(io.LimitReader(f, maxTitleRead))
	m := htmlTitleRe.FindSubmatch(b)
	if m == nil {
		return ""
	}
	return strings.Join(strings.Fields(html.UnescapeString(string(m[1]))), " ")
}

// artifactsSince are the artifact and question items before index from
// that a reader asking from since hasn't seen as they are now: still
// waiting for their result, or settled after it last read. A message from
// another agent changed since (a repeat counted, a question answered)
// comes again too.
func (c *conv) artifactsSince(from, since int) []Item {
	var out []Item
	for i := range c.items {
		abs := c.base + i
		if abs >= from {
			break
		}
		it := &c.items[i]
		if ((it.Kind == "artifact" || it.Kind == "question") && (!it.Done || it.resolved >= since)) || (it.Msg != nil && it.resolved > 0 && it.resolved >= since) {
			out = append(out, *it)
		}
	}
	return out
}

func (c *conv) artifacts() []Artifact {
	if len(c.arts) == 0 {
		return nil
	}
	return append([]Artifact(nil), c.arts...)
}
