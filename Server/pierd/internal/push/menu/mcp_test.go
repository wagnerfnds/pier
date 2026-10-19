package menu

import (
	"reflect"
	"testing"
)

// Claude Code 2.1.303's question on a repository with two servers in its
// .mcp.json, as captured on a box.
const mcpScreen = `────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  2 new MCP servers found in this project
  Select any you wish to enable.

  MCP servers may execute code or access system resources. All tool calls require approval. Learn more in the MCP
  documentation.

  ❯ [✔] laravel-boost
    [✔] herd
       Enable selected
 Space to select · Esc to reject all
`

func TestMCPReadsTheServersAndWhereTheCursorIs(t *testing.T) {
	d, ok := MCP(mcpScreen)
	if !ok {
		t.Fatal("not read")
	}
	want := []MCPServer{{"laravel-boost", true}, {"herd", true}}
	if !reflect.DeepEqual(d.Servers, want) || d.Cursor != 0 {
		t.Fatalf("got %+v", d)
	}
	// Moved to "Enable selected", one row turned off.
	moved := "  2 new MCP servers found in this project\n  Select any you wish to enable.\n    [ ] laravel-boost\n    [✔] herd\n  ❯    Enable selected\n"
	d, ok = MCP(moved)
	if !ok || d.Cursor != 2 || d.Servers[0].On {
		t.Fatalf("moved: %+v %v", d, ok)
	}
	// Not the dialog: a plain checklist in the agent's words, a numbered menu.
	for _, s := range []string{"- [x] done\n- [ ] todo\n", " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"} {
		if _, ok := MCP(s); ok {
			t.Errorf("read a dialog in %q", s)
		}
	}
}

func TestMCPKeysTickWhatIsWantedThenConfirm(t *testing.T) {
	d, _ := MCP(mcpScreen)
	if got := d.Keys([]string{"laravel-boost", "herd"}); !reflect.DeepEqual(got, []string{"Down", "Down", "Enter"}) {
		t.Errorf("all: %v", got)
	}
	if got := d.Keys([]string{"herd"}); !reflect.DeepEqual(got, []string{"Space", "Down", "Down", "Enter"}) {
		t.Errorf("herd only: %v", got)
	}
	if got := d.Keys(nil); !reflect.DeepEqual(got, []string{"Escape"}) {
		t.Errorf("none: %v", got)
	}
	// From "Enable selected" with laravel-boost off: back up, tick it, down again.
	d.Cursor, d.Servers[0].On = 2, false
	if got := d.Keys([]string{"laravel-boost", "herd"}); !reflect.DeepEqual(got, []string{"Up", "Up", "Space", "Down", "Down", "Enter"}) {
		t.Errorf("from the end: %v", got)
	}
}

func TestMCPReadsTheOneServerMenu(t *testing.T) {
	// Claude Code with one server in .mcp.json (PierKit's fixture screen_mcp_dialog.json).
	screen := "\n────────\n  New MCP server found in this project: echo-test\n\n  MCP servers may execute code or access system resources.\n\n" +
		"    Use this MCP server\n    Use this and all future MCP servers in this project\n  ❯ Continue without using this MCP server\n\n  Enter to confirm · Esc to cancel\n"
	d, ok := MCP(screen)
	if !ok || !d.Single || len(d.Servers) != 1 || d.Servers[0].Name != "echo-test" || d.Cursor != 2 || len(d.Options) != 3 {
		t.Fatalf("got %+v %v", d, ok)
	}
	if got := d.Keys([]string{"echo-test"}); !reflect.DeepEqual(got, []string{"Up", "Up", "Enter"}) {
		t.Errorf("enable: %v", got)
	}
	if got := d.Keys(nil); !reflect.DeepEqual(got, []string{"Enter"}) {
		t.Errorf("turn down (the cursor is on Continue without): %v", got)
	}
}
