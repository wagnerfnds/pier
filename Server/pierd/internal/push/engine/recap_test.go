package engine

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/push/boxapi"
	"pier/pierd/internal/push/state"
)

// AI recap (Options.Recap): a fake stands in for the model; the real claude is never called in tests.

func TestFinishedUsesTheAIRecapForAlertAndActivity(t *testing.T) {
	r := newRig(t, dev("c1", "pt-BR"))
	var mu sync.Mutex
	calls := 0
	r.eng.opt.Recap = func(_ context.Context, session string, since time.Time, reply string) string {
		mu.Lock()
		calls++
		mu.Unlock()
		if session != "sandbox-subtract-claude-6s1" || since.IsZero() || !strings.Contains(reply, "mul") {
			t.Errorf("recap asked for %q %v %q", session, since, reply)
		}
		return "Criou mul() em calc.py com testes."
	}
	r.st.PutActivity(state.Activity{Client: "c1", Box: "casa", Session: "sandbox-subtract-claude-6s1", Token: "00aa11bb", Env: "development"})
	r.box.review = []boxapi.ReviewItem{{Session: "sandbox-subtract-claude-6s1", Added: 6, Removed: 2}}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	waitFor(t, "alert and activity", func() bool { return len(r.snd.byType("alert")) == 1 && len(r.snd.byType("liveactivity")) == 1 })
	var a struct {
		APS struct{ Alert struct{ Body string } }
	}
	json.Unmarshal(r.snd.byType("alert")[0].Payload, &a)
	if a.APS.Alert.Body != "Criou mul() em calc.py com testes.\n+6 −2" {
		t.Fatalf("alert body %q", a.APS.Alert.Body)
	}
	var p struct {
		APS struct {
			CS struct{ Reply string } `json:"content-state"`
		}
	}
	json.Unmarshal(r.snd.byType("liveactivity")[0].Payload, &p)
	if p.APS.CS.Reply != "Criou mul() em calc.py com testes." {
		t.Fatalf("activity reply %q", p.APS.CS.Reply)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls != 1 {
		t.Fatalf("recap ran %d times", calls)
	}
}

func TestFinishedFallsBackToTheExcerptWhenTheRecapFails(t *testing.T) {
	r := newRig(t, dev("c1", "pt-BR"))
	r.eng.opt.Recap = func(context.Context, string, time.Time, string) string { return "" }
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	var a struct {
		APS struct{ Alert struct{ Body string } }
	}
	json.Unmarshal(r.snd.byType("alert")[0].Payload, &a)
	if a.APS.Alert.Body != "Adicionei a função mul em calc.py e os testes passaram." {
		t.Fatalf("alert body %q", a.APS.Alert.Body)
	}
}

func TestFinishedNotAnnouncedWhenTheTurnMovedOnDuringTheRecap(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.eng.opt.Recap = func(context.Context, string, time.Time, string) string {
		r.box.set(sess("running", time.Now().Add(time.Second))) // the person already sent the next prompt
		return "Done."
	}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.box.set(sess("finished", time.Now()))
	r.eng.Sync(context.Background(), false)
	time.Sleep(150 * time.Millisecond)
	if n := len(r.snd.byType("alert")); n != 0 {
		t.Fatalf("%d finished alerts for a turn that moved on", n)
	}
}

func TestInterruptedFinishDoesNotRunTheRecap(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	ran := make(chan struct{}, 1)
	r.eng.opt.Recap = func(context.Context, string, time.Time, string) string { ran <- struct{}{}; return "x" }
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	f := sess("finished", time.Now())
	r.box.set(f)
	r.eng.OnEvent(boxapi.Event{Seq: 2, Type: "agent.finished", Time: f.StateSince, Data: map[string]any{"session": f.Name, "source": "interrupt"}})
	time.Sleep(150 * time.Millisecond)
	select {
	case <-ran:
		t.Fatal("an interrupted turn ran the recap")
	default:
	}
}

// The recap is written while the finish settles, not after: with a settle and a recap of 300ms each, the alert goes
// out in about 300ms, not 600ms.
func TestTheRecapRunsDuringTheSettle(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.eng.opt.FinishedSettle = 300 * time.Millisecond
	r.eng.opt.Recap = func(ctx context.Context, _ string, _ time.Time, _ string) string {
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
		}
		return "Done."
	}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	t0 := time.Now()
	r.change(sess("finished", time.Now()))
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	if d := time.Since(t0); d > 500*time.Millisecond {
		t.Fatalf("the alert took %v: the recap waited for the settle", d)
	}
}

// A turn that moves on stops its recap: the model is not left running for nothing.
func TestARecapIsCancelledWhenTheTurnMovesOn(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.eng.opt.FinishedSettle = 300 * time.Millisecond
	cancelled := make(chan struct{})
	r.eng.opt.Recap = func(ctx context.Context, _ string, _ time.Time, _ string) string {
		select {
		case <-ctx.Done():
			close(cancelled)
		case <-time.After(2 * time.Second):
		}
		return ""
	}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	time.Sleep(50 * time.Millisecond)
	r.change(sess("running", time.Now().Add(time.Second)))
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("the recap kept running after the turn moved on")
	}
	if n := len(r.snd.byType("alert")); n != 0 {
		t.Fatalf("%d alerts for a turn that moved on", n)
	}
}

// The finish is reported before the reply reaches the transcript: the recap waits for the reply, not for nothing.
func TestTheRecapWaitsForTheReplyToLand(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	var got string
	var mu sync.Mutex
	r.eng.opt.Recap = func(_ context.Context, _ string, _ time.Time, reply string) string {
		mu.Lock()
		got = reply
		mu.Unlock()
		return "Added mul()."
	}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.box.mu.Lock()
	r.box.replyAt = time.Now().Add(400 * time.Millisecond)
	r.box.mu.Unlock()
	r.change(sess("finished", time.Now()))
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	var a struct {
		APS struct{ Alert struct{ Body string } }
	}
	json.Unmarshal(r.snd.byType("alert")[0].Payload, &a)
	mu.Lock()
	defer mu.Unlock()
	if !strings.Contains(got, "mul") || a.APS.Alert.Body != "Added mul()." {
		t.Fatalf("recap of %q, alert %q", got, a.APS.Alert.Body)
	}
}
