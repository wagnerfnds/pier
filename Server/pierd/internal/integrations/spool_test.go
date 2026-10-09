package integrations

import (
	"os"
	"testing"
	"time"

	"pier/pierd/internal/events"
)

// E13: hooks that ran while pierd was down are published, in order and
// with their own times, when it starts.
func TestSpooledHooksDrainInOrder(t *testing.T) {
	dir := t.TempDir()
	at := time.Date(2026, 5, 1, 12, 5, 33, 0, time.UTC)
	for i, typ := range []string{"agent.started", "agent.waiting", "agent.finished"} {
		if err := Spool(dir, events.Event{Type: typ, Time: at.Add(time.Duration(i) * time.Second), Origin: "claude", Data: map[string]any{"session": "shop-feat-a-claude"}}); err != nil {
			t.Fatal(err)
		}
	}
	var got []events.Event
	if n := DrainSpool(dir, func(e events.Event) { got = append(got, e) }); n != 3 {
		t.Fatalf("drained %d", n)
	}
	if got[0].Type != "agent.started" || got[2].Type != "agent.finished" || !got[2].Time.Equal(at.Add(2*time.Second)) || got[1].Data["spooled"] != true {
		t.Fatalf("drained = %+v", got)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatalf("left %d files", len(ents))
	}
	if DrainSpool(dir, func(events.Event) { t.Fatal("drained twice") }) != 0 {
		t.Fatal("drained twice")
	}
}

func TestUnreachableTellsAMissingDaemonFromARefusal(t *testing.T) {
	_, err := os.Stat("/nonexistent/pierd.sock")
	if !Unreachable(err) {
		t.Fatal("a missing socket is unreachable")
	}
	if Unreachable(os.ErrPermission) {
		t.Fatal("a refusal is not unreachable")
	}
}
