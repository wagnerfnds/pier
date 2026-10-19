package menu

import (
	"regexp"
	"strings"
)

// MCPServer is one row of Claude Code's question about a repository's MCP
// servers: its name, and whether it is ticked.
type MCPServer struct {
	Name string
	On   bool
}

// MCPDialog is Claude Code's question about the MCP servers in a
// repository's .mcp.json when it finds more than one ("2 new MCP servers
// found in this project · Select any you wish to enable"): a list of ticked
// rows, then "Enable selected". Space or Enter on a row ticks it, Enter on
// "Enable selected" answers, Esc turns them all down. Cursor is the row the
// ❯ is on (len(Servers) for "Enable selected").
//
// Mirrors MenuParser.mcpDialog in PierKit (MenuParser.swift).
//
// With one server it asks in a menu instead ("New MCP server found in this
// project: echo-test", then "Use this MCP server", "Use this and all future
// MCP servers in this project", "Continue without using this MCP server"):
// Single is set, Options holds the menu's rows and Cursor the one picked.
type MCPDialog struct {
	Servers []MCPServer
	Cursor  int
	Single  bool
	Options []string
}

var (
	mcpHeading = regexp.MustCompile(`(?i)new MCP servers? found|select any you wish to enable`)
	mcpRow     = regexp.MustCompile(`^\s*(?:[│┃]\s*)?([❯›>])?\s*\[([ ✔✓xX×])\]\s+(\S.*?)(?:\s+[│┃])?\s*$`)
	mcpConfirm = regexp.MustCompile(`^\s*(?:[│┃]\s*)?([❯›>])?\s*Enable selected\b`)
	mcpOne     = regexp.MustCompile(`(?i)new MCP server found in (?:this project|\.mcp\.json):\s*(\S+)`)
	mcpOneRow  = regexp.MustCompile(`^\s*(?:[│┃]\s*)?([❯›>])?\s*(?:\d[.)]\s+)?((?:Use this|Continue without)\b.*?)(?:\s+[│┃])?\s*$`)
)

// MCP reads the dialog from the foot of a screen; ok is false when it is
// not there.
func MCP(screen string) (MCPDialog, bool) {
	lines := strings.Split(StripPanel(screen), "\n")
	if len(lines) > 30 {
		lines = lines[len(lines)-30:]
	}
	if d, ok := mcpSingle(lines); ok {
		return d, true
	}
	heading, confirm := false, false
	d := MCPDialog{Cursor: -1}
	for _, l := range lines {
		if mcpHeading.MatchString(l) {
			heading = true
			continue
		}
		if !heading {
			continue
		}
		if m := mcpRow.FindStringSubmatch(l); m != nil {
			if m[1] != "" {
				d.Cursor = len(d.Servers)
			}
			d.Servers = append(d.Servers, MCPServer{Name: strings.TrimSpace(m[3]), On: m[2] != " "})
			continue
		}
		if m := mcpConfirm.FindStringSubmatch(l); m != nil {
			confirm = true
			if m[1] != "" {
				d.Cursor = len(d.Servers)
			}
		}
	}
	if !heading || !confirm || len(d.Servers) == 0 || d.Cursor < 0 {
		return MCPDialog{}, false
	}
	return d, true
}

// mcpSingle reads the one-server menu.
func mcpSingle(lines []string) (MCPDialog, bool) {
	d := MCPDialog{Cursor: -1, Single: true}
	for _, l := range lines {
		if m := mcpOne.FindStringSubmatch(l); m != nil {
			d.Servers = []MCPServer{{Name: m[1]}}
			d.Options, d.Cursor = nil, -1
			continue
		}
		if len(d.Servers) == 0 {
			continue
		}
		if m := mcpOneRow.FindStringSubmatch(l); m != nil {
			if m[1] != "" {
				d.Cursor = len(d.Options)
			}
			d.Options = append(d.Options, m[2])
		}
	}
	if len(d.Servers) == 0 || len(d.Options) < 2 || d.Cursor < 0 || mcpUse(d.Options) < 0 {
		return MCPDialog{}, false
	}
	return d, true
}

// mcpUse is the one-server menu's row that turns the server on for this
// folder only ("Use this MCP server").
func mcpUse(options []string) int {
	for i, o := range options {
		if strings.EqualFold(strings.TrimSpace(o), "Use this MCP server") {
			return i
		}
	}
	return -1
}

// mcpWithout is the one-server menu's row that turns it down.
func mcpWithout(options []string) int {
	for i, o := range options {
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(o)), "continue without") {
			return i
		}
	}
	return -1
}

// Keys answers the dialog with the servers named in enable ticked and the
// others not, as tmux key names: down the rows from the cursor, Space where
// a row's tick must change, then Enter on "Enable selected"; nothing in
// enable is "Escape", which turns them all down. The one-server menu takes
// its own row: "Use this MCP server" or "Continue without using this MCP
// server".
func (d MCPDialog) Keys(enable []string) []string {
	want := map[string]bool{}
	for _, n := range enable {
		want[n] = true
	}
	any := false
	for _, s := range d.Servers {
		if want[s.Name] {
			any = true
		}
	}
	if d.Single {
		// Its own rows, not Esc ("Esc to cancel"): "Continue without using this MCP server" turns it down.
		to := mcpUse(d.Options)
		if !any {
			to = mcpWithout(d.Options)
		}
		if to < 0 {
			return []string{"Escape"}
		}
		var keys []string
		for i := d.Cursor; i != to; {
			if i < to {
				keys, i = append(keys, "Down"), i+1
			} else {
				keys, i = append(keys, "Up"), i-1
			}
		}
		return append(keys, "Enter")
	}
	if !any {
		return []string{"Escape"}
	}
	var keys []string
	for i := d.Cursor; i > 0; i-- {
		keys = append(keys, "Up")
	}
	for _, s := range d.Servers {
		if s.On != want[s.Name] {
			keys = append(keys, "Space")
		}
		keys = append(keys, "Down")
	}
	return append(keys, "Enter")
}
