package transcript

import (
	"encoding/json"
	"path/filepath"
	"strings"
)

// codexParser reads a Codex session file (rollout-*.jsonl): response items
// for messages, function calls and their output, plus events and metadata,
// which are skipped.
type codexParser struct{}

type codexLine struct {
	Type      string          `json:"type"`
	Timestamp string          `json:"timestamp"`
	Payload   json.RawMessage `json:"payload"`
}

type codexItem struct {
	Type      string `json:"type"`
	Role      string `json:"role"`
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
	Input     string `json:"input"`
	CallID    string `json:"call_id"`
	// Output is a call's output: request_user_input's answers.
	Output  json.RawMessage `json:"output"`
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
}

func (codexParser) line(c *conv, b []byte) {
	var l codexLine
	if json.Unmarshal(b, &l) != nil {
		return
	}
	if l.Type != "response_item" {
		// Its model, mode, context and errors (signals.go).
		codexSignals(c, l.Type, l.Payload, parseTime(l.Timestamp))
		return
	}
	var it codexItem
	if json.Unmarshal(l.Payload, &it) != nil {
		return
	}
	at := parseTime(l.Timestamp)
	if l.Timestamp != "" {
		c.lineAt = at
	}
	switch it.Type {
	case "message":
		var parts []string
		for _, p := range it.Content {
			if p.Text != "" {
				parts = append(parts, p.Text)
			}
		}
		text := strings.TrimSpace(strings.Join(parts, "\n"))
		switch it.Role {
		case "user":
			// Codex writes its environment and instructions as user
			// messages wrapped in tags.
			userText(c, text)
		case "assistant":
			if text != "" {
				c.add(Item{Kind: "text", ID: c.id(), Text: clip(text, maxText)})
			}
		}
	case "function_call", "custom_tool_call", "local_shell_call":
		codexCall(c, it)
	case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
		c.result(it.CallID, at)
		var out string
		_ = json.Unmarshal(it.Output, &out)
		c.codexAnswered(it.CallID, out)
	}
}

func codexCall(c *conv, it codexItem) {
	if it.Name == "update_plan" {
		// Its plan is the task list (signals.go), not a step.
		codexPlan(c, it.Arguments)
		c.byTool[it.CallID] = -1
		return
	}
	if it.Name == "request_user_input" {
		// Its questions, shown with their answers (questions.go).
		var args map[string]any
		_ = json.Unmarshal([]byte(it.Arguments), &args)
		if c.asked(it.CallID, args["questions"]) {
			return
		}
	}
	if it.Name == "apply_patch" {
		codexPatch(c, firstNonEmpty(it.Input, patchFromArgs(it.Arguments)), it.CallID)
		c.byTool[it.CallID] = -1
		return
	}
	var args struct {
		Command any    `json:"command"`
		Cmd     string `json:"cmd"`
		Path    string `json:"path"`
	}
	_ = json.Unmarshal([]byte(it.Arguments), &args)
	cmd := args.Cmd
	switch v := args.Command.(type) {
	case string:
		cmd = v
	case []any:
		var parts []string
		for _, p := range v {
			if s, ok := p.(string); ok {
				parts = append(parts, s)
			}
		}
		// ["bash", "-lc", "the command"] reads as the command.
		if len(parts) == 3 && (parts[1] == "-lc" || parts[1] == "-c") {
			cmd = parts[2]
		} else {
			cmd = strings.Join(parts, " ")
		}
	}
	switch {
	case strings.Contains(cmd, "apply_patch"):
		codexPatch(c, cmd, it.CallID)
		c.byTool[it.CallID] = -1
	case it.Name == "read_file" || it.Name == "view_image":
		c.call(it.CallID, ToolCall{Verb: "Read", Target: filepath.Base(args.Path), File: true})
	case readsFile(cmd):
		f := strings.Fields(cmd)
		c.call(it.CallID, ToolCall{Verb: "Read", Target: filepath.Base(f[len(f)-1]), File: true})
	case strings.HasPrefix(cmd, "rg ") || strings.HasPrefix(cmd, "grep ") || strings.HasPrefix(cmd, "find ") || strings.HasPrefix(cmd, "ls"):
		c.call(it.CallID, ToolCall{Verb: "Search", Target: clip(firstLine(cmd), 80)})
	case cmd != "":
		c.call(it.CallID, ToolCall{Verb: "Run", Target: clip(firstLine(cmd), 80)})
	default:
		c.call(it.CallID, ToolCall{Verb: "Run", Target: clip(it.Name, 80)})
	}
}

// readsFile is a plain look at one file: cat, sed -n, head, tail.
func readsFile(cmd string) bool {
	f := strings.Fields(cmd)
	if len(f) < 2 || strings.ContainsAny(cmd, "|;&>") {
		return false
	}
	switch f[0] {
	case "cat", "head", "tail", "nl":
		return true
	case "sed":
		return len(f) >= 3 && f[1] == "-n"
	}
	return false
}

func patchFromArgs(args string) string {
	var a struct {
		Input string `json:"input"`
		Patch string `json:"patch"`
	}
	_ = json.Unmarshal([]byte(args), &a)
	return firstNonEmpty(a.Input, a.Patch)
}

// codexPatch turns an apply_patch body into one edit per file.
func codexPatch(c *conv, patch, callID string) {
	var file string
	added, removed := 0, 0
	flush := func() {
		if file != "" {
			c.add(Item{Kind: "edit", ID: c.id(), File: rel(c.dir, file), Added: added, Removed: removed, Tool: callID})
		}
		file, added, removed = "", 0, 0
	}
	for _, l := range strings.Split(patch, "\n") {
		switch {
		case strings.HasPrefix(l, "*** Update File: "), strings.HasPrefix(l, "*** Add File: "), strings.HasPrefix(l, "*** Delete File: "):
			flush()
			file = strings.TrimSpace(l[strings.Index(l, ":")+1:])
		case strings.HasPrefix(l, "*** "):
		case strings.HasPrefix(l, "+"):
			added++
		case strings.HasPrefix(l, "-"):
			removed++
		}
	}
	flush()
}
