package box

import (
	"context"
	"net/http"
	"time"

	"pier/pierd/internal/push/menu"
)

// MCPQuestion is Claude Code's question about a repository's MCP servers
// (its .mcp.json) as the app shows it: each server and whether it is ticked.
type MCPQuestion struct {
	Servers []MCPQuestionServer `json:"servers"`
}

type MCPQuestionServer struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
}

// mcpQuestion reads the question off a session's screen.
func (b *Box) mcpQuestion(ctx context.Context, name string) (menu.MCPDialog, error) {
	screen, err := b.Sessions.Screen(ctx, name, 0)
	if err != nil {
		return menu.MCPDialog{}, err
	}
	d, ok := menu.MCP(screen)
	if !ok {
		return menu.MCPDialog{}, httpError{http.StatusNotFound, "Claude isn't asking about MCP servers"}
	}
	return d, nil
}

// getMCPQuestion answers GET /v1/sessions/{name}/mcp: the question on
// screen, 404 when there is none.
func (b *Box) getMCPQuestion(w http.ResponseWriter, r *http.Request) error {
	d, err := b.mcpQuestion(r.Context(), r.PathValue("name"))
	if err != nil {
		return err
	}
	out := MCPQuestion{Servers: []MCPQuestionServer{}}
	for _, s := range d.Servers {
		out.Servers = append(out.Servers, MCPQuestionServer{Name: s.Name, Enabled: s.On})
	}
	writeJSON(w, out)
	return nil
}

// answerMCPQuestion answers POST /v1/sessions/{name}/mcp {"enable": [...]}:
// the servers named are turned on, the others down (none: all turned down),
// with the keys Claude Code's dialog takes, read again from the screen right
// before they are pressed. It returns once the dialog is gone.
func (b *Box) answerMCPQuestion(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Enable []string `json:"enable"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	name := r.PathValue("name")
	d, err := b.mcpQuestion(r.Context(), name)
	if err != nil {
		return err
	}
	known := map[string]bool{}
	for _, s := range d.Servers {
		known[s.Name] = true
	}
	for _, n := range req.Enable {
		if !known[n] {
			return badRequest("no MCP server named %q in Claude's question", n)
		}
	}
	if err := b.before(r, "session.send", map[string]any{"name": name, "key": "mcp"}); err != nil {
		return err
	}
	for _, k := range d.Keys(req.Enable) {
		if err := b.pressKeys(r.Context(), name, k); err != nil {
			return err
		}
		// Claude Code's dialog redraws after each key: one sent before it did is lost.
		time.Sleep(mcpKeyGap)
	}
	deadline := time.Now().Add(4 * time.Second)
	for {
		if _, err := b.mcpQuestion(r.Context(), name); err != nil {
			break
		}
		if time.Now().After(deadline) {
			return httpError{http.StatusConflict, "Claude didn't take the answer: the question is still on screen"}
		}
		time.Sleep(150 * time.Millisecond)
	}
	enabled := req.Enable
	if enabled == nil {
		enabled = []string{}
	}
	writeJSON(w, map[string]any{"answered": true, "enabled": enabled})
	return nil
}

// mcpKeyGap is the pause between the keys that answer the dialog.
var mcpKeyGap = 80 * time.Millisecond
