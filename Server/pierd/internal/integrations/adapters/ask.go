package adapters

import (
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// AskKey is where an adapter puts what a waiting agent asks for: the tool,
// a short summary of its input (a command or a file path, never a file's
// contents) and the agent's own reason. It rides to the box with the hook,
// and the box takes it out before the event is published: it is kept only
// on the turn's wait, in the ledger's private file, so it never reaches
// the journal, hooks or flows.
const AskKey = "ask"

// AskLimit caps each string an ask keeps.
const AskLimit = 300

// claudeAsk is a PermissionRequest's ask: tool_name and a summary of
// tool_input.
func claudeAsk(in Payload) map[string]any {
	tool := in.Str("tool_name")
	if tool == "" {
		return nil
	}
	input, _ := in["tool_input"].(map[string]any)
	ask := map[string]any{"tool": clip(tool)}
	if s := inputSummary(tool, input, in.Str("cwd")); s != "" {
		ask["input"] = s
	}
	// Bash says why it runs a command; that is the agent's reason.
	if why, _ := input["description"].(string); why != "" && tool == "Bash" {
		ask["why"] = clip(why)
	}
	return ask
}

// inputSummary is the one line a person needs to decide: the command to
// run, the file to touch, the URL to fetch. It never includes what would
// be written to a file.
func inputSummary(tool string, input map[string]any, cwd string) string {
	get := func(k string) string {
		s, _ := input[k].(string)
		return s
	}
	switch tool {
	case "Bash":
		return clip(get("command"))
	case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
		return clip(relTo(cwd, firstOf(Payload(input), "file_path", "notebook_path")))
	case "WebFetch":
		return clip(get("url"))
	case "WebSearch":
		return clip(get("query"))
	case "Grep", "Glob":
		return clip(get("pattern"))
	case "Task", "Agent":
		return clip(get("description"))
	case "AskUserQuestion":
		// The question itself: the person answers it from its options.
		if qs, _ := input["questions"].([]any); len(qs) > 0 {
			if q, _ := qs[0].(map[string]any); q != nil {
				s, _ := q["question"].(string)
				return clip(s)
			}
		}
		return ""
	}
	// Anything else (an MCP tool): the first field that names a target.
	for _, k := range []string{"command", "file_path", "path", "url", "query", "pattern"} {
		if s := get(k); s != "" {
			if k == "file_path" || k == "path" {
				s = relTo(cwd, s)
			}
			return clip(s)
		}
	}
	return ""
}

// relTo shows a path inside the agent's directory relative to it.
func relTo(dir, p string) string {
	if dir == "" || !filepath.IsAbs(p) {
		return p
	}
	if r, err := filepath.Rel(dir, p); err == nil && !strings.HasPrefix(r, "..") {
		return r
	}
	return p
}

// clip trims s and cuts it to AskLimit bytes, on a rune boundary, with an
// ellipsis when cut.
func clip(s string) string {
	s = strings.TrimSpace(s)
	if len(s) <= AskLimit {
		return s
	}
	cut := AskLimit - len("…")
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}
