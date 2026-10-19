package box

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Claude Code's question about a repository's MCP servers, answered over the
// wire: the dialog is read off the screen, the keys go in, and the answer
// comes back once the dialog is gone (testdata/mcp_dialog.py draws it and
// takes keys as Claude Code 2.1.30x does).
func TestMCPQuestionIsReadAndAnsweredFromTheScreen(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not installed")
	}
	script, _ := filepath.Abs("testdata/mcp_dialog.py")
	c, _ := servedBox(t)
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	start := func() string {
		var sess Session
		if status := call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal", "command": "python3 " + script}, &sess); status != 200 {
			t.Fatalf("add session: %d", status)
		}
		deadline := time.Now().Add(5 * time.Second)
		for {
			var q MCPQuestion
			if call(t, c, "GET", "/v1/sessions/"+sess.Name+"/mcp", "", nil, &q) == 200 {
				if len(q.Servers) != 2 || q.Servers[0].Name != "laravel-boost" || !q.Servers[1].Enabled {
					t.Fatalf("question = %+v", q)
				}
				return sess.Name
			}
			if time.Now().After(deadline) {
				t.Fatal("the dialog never showed")
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	screen := func(name string) string {
		var s struct{ Screen string }
		call(t, c, "GET", "/v1/sessions/"+name+"/screen", "", nil, &s)
		return s.Screen
	}

	// One of the two: herd untouched would stay on, so it is unticked.
	name := start()
	if status := call(t, c, "POST", "/v1/sessions/"+name+"/mcp", "", map[string]any{"enable": []string{"herd", "nope"}}, nil); status != 400 {
		t.Fatalf("a server not asked about = %d", status)
	}
	var res struct {
		Answered bool     `json:"answered"`
		Enabled  []string `json:"enabled"`
	}
	if status := call(t, c, "POST", "/v1/sessions/"+name+"/mcp", "", map[string]any{"enable": []string{"laravel-boost"}}, &res); status != 200 || !res.Answered {
		t.Fatalf("answer = %d %+v\n%s", status, res, screen(name))
	}
	if s := screen(name); !strings.Contains(s, "PICKED:laravel-boost\n") && !strings.HasSuffix(strings.TrimSpace(s), "PICKED:laravel-boost") {
		t.Fatalf("picked:\n%s", s)
	}
	if status := call(t, c, "GET", "/v1/sessions/"+name+"/mcp", "", nil, nil); status != 404 {
		t.Fatalf("after the answer = %d", status)
	}

	// None: all turned down.
	name = start()
	if status := call(t, c, "POST", "/v1/sessions/"+name+"/mcp", "", map[string]any{"enable": []string{}}, nil); status != 200 {
		t.Fatalf("turn down = %d\n%s", status, screen(name))
	}
	if s := screen(name); !strings.Contains(s, "REJECTED") {
		t.Fatalf("turned down:\n%s", s)
	}
}
