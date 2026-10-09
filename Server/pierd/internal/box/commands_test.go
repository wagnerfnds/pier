package box

import (
	"testing"

	"pier/pierd/internal/events"
)

func TestLocalCommands(t *testing.T) {
	cases := []struct {
		agent, text, name string
		local             bool
	}{
		{"claude", "/cost", "/usage", true},
		{"claude", "/model opus", "/model", true},
		{"claude", "/compact keep the API notes", "/compact", true},
		{"claude", "/init", "/init", false},
		{"claude", "/simplify", "/simplify", false},
		{"claude", "/my-skill do it", "", false},
		{"claude", "/etc/hosts is wrong", "", false},
		{"claude", "fix /model", "", false},
		{"codex", "/status", "/status", true},
		{"codex", "/review", "/review", false},
		{"gemini", "/model", "", false},
		{"claude", "!ls", "!", true},
		{"codex", "!git status", "!", true},
		{"gemini", "!ls", "", false},
		{"claude", "!", "", false},
	}
	for _, c := range cases {
		name, local := localCommand(c.agent, c.text)
		if name != c.name || local != c.local {
			t.Errorf("localCommand(%s, %q) = %q %v, want %q %v", c.agent, c.text, name, local, c.name, c.local)
		}
	}
}

// A local command typed into an agent starts no turn, so the next prompt's
// start is its own.
func TestALocalCommandStartsNoTurn(t *testing.T) {
	tr, bus := ledger(t, Session{Name: "s", Dir: "/srv/a", Agent: "claude"})
	hook(bus, "agent.ready", "s", "/srv/a", "claude")
	hook(bus, "agent.started", "s", "/srv/a", "claude", "signal", "prompt")
	hook(bus, "agent.finished", "s", "/srv/a", "claude")
	cmd := bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "s", "command": "/usage"}})
	if _, ok := tr.ForSent("s", cmd.Seq); ok {
		t.Fatal("a command opened a turn")
	}
	sent := bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": "s"}})
	hook(bus, "agent.started", "s", "/srv/a", "claude", "signal", "prompt")
	mine, ok := tr.ForSent("s", sent.Seq)
	if !ok || turnState(t, tr, mine.ID) != "running" {
		t.Fatalf("the prompt's turn = %+v %v", mine, ok)
	}
}

func TestCommandName(t *testing.T) {
	for in, want := range map[string]string{"/model": "model", " /model x": "model", "/vercel:deploy prod": "vercel:deploy", "/a/b": "", "//x": "", "hi": "", "/": ""} {
		if got := commandName(in); got != want {
			t.Errorf("commandName(%q) = %q, want %q", in, got, want)
		}
	}
}
