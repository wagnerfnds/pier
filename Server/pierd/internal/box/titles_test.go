package box

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A session started with a prompt is named after it; one started without
// takes its first prompt's title, sent or typed; a rename sticks, and the
// prompt itself is never published.
func TestSessionsAreNamedAfterTheirTask(t *testing.T) {
	turns := &Turns{}
	c, bus := servedBox(t, func(b *Box) { b.Turns = turns })
	turns.Attach(bus)
	seen, stop := bus.Subscribe()
	defer stop()
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "shop", "path": repo}, nil)

	bin := t.TempDir()
	fake := filepath.Join(bin, "claude")
	os.WriteFile(fake, []byte("#!/bin/sh\nexec cat\n"), 0o755)

	title := func(name string) string {
		t.Helper()
		var all []Session
		call(t, c, "GET", "/v1/sessions", "", nil, &all)
		for _, s := range all {
			if s.Name == name {
				return s.Title
			}
		}
		t.Fatalf("no session %s in %+v", name, all)
		return ""
	}

	// An explicit title wins over the prompt's.
	var named Session
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "shop", "name": "named", "command": fake, "title": "Fix checkout webhook"}, &named)
	if named.Title != "Fix checkout webhook" || title("named") != "Fix checkout webhook" {
		t.Fatalf("named = %+v, listed %q", named, title("named"))
	}

	// No title yet: the first prompt sent names it, the second does not.
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "shop", "name": "plain", "command": fake}, nil)
	if got := title("plain"); got != "" {
		t.Fatalf("a session with no prompt has title %q", got)
	}
	call(t, c, "POST", "/v1/sessions/plain/send", "", map[string]any{"text": "\n  Add a   health check endpoint to the API server so the load balancer can probe it\nwith details"}, nil)
	if got := title("plain"); got != "Add a health check endpoint to the API server…" {
		t.Fatalf("after the first send, title = %q", got)
	}
	call(t, c, "POST", "/v1/sessions/plain/send", "", map[string]any{"text": "now something else"}, nil)
	if got := title("plain"); !strings.HasPrefix(got, "Add a health") {
		t.Fatalf("a second prompt renamed it: %q", got)
	}

	// Renamed by hand; an empty title clears it.
	var renamed Session
	if status := call(t, c, "PATCH", "/v1/sessions/plain", "", map[string]string{"title": "  Health check  "}, &renamed); status != 200 || renamed.Title != "Health check" {
		t.Fatalf("rename: %d %+v", status, renamed)
	}
	call(t, c, "PATCH", "/v1/sessions/plain", "", map[string]string{"title": ""}, nil)
	if got := title("plain"); got != "" {
		t.Fatalf("clearing left %q", got)
	}
	if status := call(t, c, "PATCH", "/v1/sessions/nope", "", map[string]string{"title": "x"}, nil); status != 404 {
		t.Fatalf("renaming an unknown session: %d", status)
	}

	// Typed into the agent: its UserPromptSubmit hook carries the title,
	// which names the session and is dropped from the event.
	var typed Session
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "shop", "name": "typed", "command": fake}, &typed)
	call(t, c, "POST", "/v1/events", "claude", map[string]any{"type": "agent.started", "data": map[string]any{"session": "typed", "path": typed.Dir, "agent": "claude", "signal": "prompt", "title": "Refactor the cart"}}, nil)
	if got := title("typed"); got != "Refactor the cart" {
		t.Fatalf("typed prompt: title = %q", got)
	}
	deadline := time.After(3 * time.Second)
	for {
		select {
		case e := <-seen:
			if _, ok := e.Data["title"]; ok {
				t.Fatalf("an event carried a title: %+v", e)
			}
			if e.Type == "agent.started" {
				return
			}
		case <-deadline:
			t.Fatal("never saw agent.started")
		}
	}
}
