package engine

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/push/apns"
	"pier/pierd/internal/push/boxapi"
	"pier/pierd/internal/push/state"
)

type fakeBox struct {
	mu       sync.Mutex
	sessions []boxapi.Session
	screen   string
	review   []boxapi.ReviewItem
	locs     []boxapi.Location
	bg       []string
	replyAt  time.Time // the reply reaches the transcript then (zero: already there)
	question []string  // the open question's choices in the transcript (nil: none)
}

func (f *fakeBox) Info(context.Context) (boxapi.Info, error) { return boxapi.Info{Name: "devbox"}, nil }
func (f *fakeBox) Sessions(context.Context) ([]boxapi.Session, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]boxapi.Session(nil), f.sessions...), nil
}
func (f *fakeBox) Locations(context.Context) ([]boxapi.Location, error) { return f.locs, nil }
func (f *fakeBox) Screen(context.Context, string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.screen, nil
}
func (f *fakeBox) Review(context.Context) ([]boxapi.ReviewItem, error) { return f.review, nil }
func (f *fakeBox) Draft(context.Context, string) (boxapi.Draft, error) { return boxapi.Draft{}, nil }
func (f *fakeBox) LastMessage(context.Context, string) string {
	f.mu.Lock()
	late := time.Now().Before(f.replyAt)
	f.mu.Unlock()
	if late {
		return ""
	}
	return "Adicionei a função mul em calc.py e os testes passaram. Depois rodei o lint."
}
func (f *fakeBox) Background(context.Context, string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bg
}
func (f *fakeBox) OpenQuestion(context.Context, string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.question
}
func (f *fakeBox) set(s ...boxapi.Session) {
	f.mu.Lock()
	f.sessions = s
	f.mu.Unlock()
}

type fakeSender struct {
	mu     sync.Mutex
	reqs   []apns.Request
	result func(apns.Request) apns.Result
}

func (f *fakeSender) Send(_ context.Context, r apns.Request) (apns.Result, error) {
	f.mu.Lock()
	f.reqs = append(f.reqs, r)
	f.mu.Unlock()
	if f.result != nil {
		return f.result(r), nil
	}
	return apns.Result{Status: 200, APNsID: "id-1"}, nil
}
func (f *fakeSender) byType(t string) (out []apns.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.reqs {
		if r.PushType == t {
			out = append(out, r)
		}
	}
	return
}

func readScreen(t *testing.T, name string) string {
	b, err := os.ReadFile(filepath.Join("..", "menu", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	var v struct{ Screen string }
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v.Screen
}

type rig struct {
	t   *testing.T
	box *fakeBox
	snd *fakeSender
	st  *state.Store
	eng *Engine
}

func newRig(t *testing.T, devs ...state.Device) *rig {
	st, err := state.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range devs {
		st.PutDevice(d)
	}
	box := &fakeBox{locs: []boxapi.Location{{Name: "sandbox", Worktrees: []boxapi.Worktree{{Name: "subtract", Path: "/w/subtract"}}}}}
	snd := &fakeSender{}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	if testing.Verbose() {
		log = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	eng := New(Options{
		BundleID: "com.example.pier", WaitingSettle: 30 * time.Millisecond, FinishedSettle: 30 * time.Millisecond,
		SyncDelay: 5 * time.Millisecond, SyncEvery: time.Hour, ScreenTries: 2, ScreenRetry: 5 * time.Millisecond,
		ActivityInterval: 20 * time.Millisecond, WidgetInterval: time.Hour, StartGrace: 40 * time.Millisecond,
	}, box, st, snd, nil, log)
	return &rig{t, box, snd, st, eng}
}

func dev(client, locale string) state.Device {
	return state.Device{Client: client, Token: "aabbccdd11223344", Env: "development", Locale: locale, Events: state.DefaultEvents, Updated: time.Now()}
}

func sess(state string, since time.Time) boxapi.Session {
	return boxapi.Session{
		Name: "sandbox-subtract-claude-6s1", Location: "sandbox/subtract", Dir: "/w/subtract", Agent: "claude", AgentState: state,
		StateSince: since, Created: since.Add(-time.Hour), Title: "Corrigir login",
	}
}

func (r *rig) start() {
	r.eng.Sync(context.Background(), true)
}

func (r *rig) change(s boxapi.Session) {
	r.box.set(s)
	r.eng.OnEvent(boxapi.Event{Seq: 1, Type: eventType(s), Time: s.StateSince, Data: map[string]any{"session": s.Name, "path": s.Dir}})
}

func eventType(s boxapi.Session) string {
	switch s.AgentState {
	case "running":
		return "agent.started"
	case "idle":
		return "agent.ready"
	}
	return "agent." + s.AgentState
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestWaitingPermissionSendsAlertWithMenuAndPortuguese(t *testing.T) {
	r := newRig(t, dev("c1", "pt-BR"))
	r.box.screen = readScreen(t, "screen_permission.json")
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	if len(r.snd.reqs) != 0 {
		t.Fatal("the baseline must not announce anything")
	}
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "Bash", Input: "rm -rf build"}
	r.change(s)
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	q := r.snd.byType("alert")[0]
	if q.Topic != "com.example.pier" || q.Priority != 10 || q.Env != "development" || q.CollapseID != s.Name {
		t.Fatalf("request %+v", q)
	}
	var p map[string]any
	json.Unmarshal(q.Payload, &p)
	aps := p["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if aps["category"] != "NEEDS_YOU" || aps["interruption-level"] != "time-sensitive" || aps["thread-id"] != "devbox/"+s.Name {
		t.Fatalf("aps %v", aps)
	}
	if alert["title"] != "✋ Precisa de você · Corrigir login" || alert["subtitle"] != "sandbox / subtract · Claude Code" || alert["body"] != "Bash  rm -rf build" {
		t.Fatalf("alert %v", alert)
	}
	if p["hasMenu"] != true || p["session"] != s.Name || p["location"] != "sandbox/subtract" || p["box"] != "devbox" {
		t.Fatalf("custom keys %v", p)
	}
	// A permission with its menu keeps Permitir / Negar: no option buttons ride along.
	if _, has := p["options"]; has {
		t.Fatalf("a permission menu must not carry options: %v", p)
	}
}

func TestWaitingQuestionWithNoReadableChoicesUsesTheQuestionCategory(t *testing.T) {
	r := newRig(t, dev("c1", "en-US"))
	r.box.screen = "Thinking about the colours…\n" // no numbered rows, no question in the transcript
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "AskUserQuestion", Input: "Which colour?"}
	r.change(s)
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	var p struct {
		APS     struct{ Category string }
		HasMenu bool     `json:"hasMenu"`
		Options []string `json:"options"`
	}
	json.Unmarshal(r.snd.byType("alert")[0].Payload, &p)
	if p.APS.Category != "NEEDS_YOU_QUESTION" || p.HasMenu || p.Options != nil {
		t.Fatalf("%+v", p)
	}
}

// --- Answer from the notification: the choices ride along as `options` ---

type optionsPayload struct {
	APS struct {
		Category string
		Alert    struct{ Body string }
	}
	HasMenu     bool     `json:"hasMenu"`
	Options     []string `json:"options"`
	OptionsKind string   `json:"optionsKind"`
}

func (r *rig) firstAlertOptions(t *testing.T) optionsPayload {
	t.Helper()
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	var p optionsPayload
	json.Unmarshal(r.snd.byType("alert")[0].Payload, &p)
	return p
}

func TestWaitingQuestionCarriesTheTranscriptChoices(t *testing.T) {
	r := newRig(t, dev("c1", "pt-BR"))
	r.box.question = []string{"Red", "Green", "Blue"}
	r.box.screen = "just some output\n"
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "AskUserQuestion", Input: "Which colour?"}
	r.change(s)
	p := r.firstAlertOptions(t)
	if p.APS.Category != "NEEDS_YOU_CHOICE_3" || p.HasMenu || p.OptionsKind != "question" || !reflect.DeepEqual(p.Options, []string{"Red", "Green", "Blue"}) {
		t.Fatalf("%+v", p)
	}
	// The numbered buttons of the app's own category need the choices in the body, numbered the same way.
	if !strings.HasSuffix(p.APS.Alert.Body, "\n1 Red · 2 Green · 3 Blue") {
		t.Fatalf("body %q", p.APS.Alert.Body)
	}
}

func TestWaitingQuestionReadsTheChoicesFromTheScreen(t *testing.T) {
	// Claude Code writes the question to its transcript only once answered: while it waits, the choices are on screen,
	// numbered, followed by its own "Type something." / "Chat about this" rows.
	r := newRig(t, dev("c1", "en"))
	r.box.screen = "● Which layout for the pricing page?\n\n ❯ 1. Three tiers\n      Starter, Pro and Team side by side\n   2. One plan\n   3. A table\n   4. Type something.\n   5. Chat about this\n\n  Enter to select · ↑↓ to move\n"
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "AskUserQuestion", Input: "Which layout for the pricing page?"}
	r.change(s)
	p := r.firstAlertOptions(t)
	if p.APS.Category != "NEEDS_YOU_CHOICE_3" || p.OptionsKind != "menu" || !reflect.DeepEqual(p.Options, []string{"Three tiers", "One plan", "A table"}) {
		t.Fatalf("%+v", p)
	}
}

func TestPlanApprovalCarriesItsMenu(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.screen = "Ready to code?\n\n ❯ 1. Yes, and auto-accept edits\n   2. Yes, and manually approve edits\n   3. No, keep planning\n"
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "ExitPlanMode", Input: "plan"}
	r.change(s)
	p := r.firstAlertOptions(t)
	if p.APS.Category != "NEEDS_YOU_CHOICE_3" || p.OptionsKind != "menu" || len(p.Options) != 3 || p.Options[2] != "No, keep planning" {
		t.Fatalf("%+v", p)
	}
}

func TestQuestionAnsweredWhileReadingTheChoicesSendsNoAlert(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.question = []string{"Red", "Green"}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "AskUserQuestion", Input: "Which colour?"}
	r.box.set(s)
	// The person answers in the terminal right after the event: the second look at the session finds it running again.
	go func() {
		time.Sleep(10 * time.Millisecond)
		r.box.set(sess("running", time.Now()))
	}()
	r.eng.OnEvent(boxapi.Event{Seq: 2, Type: "agent.waiting", Time: s.StateSince, Data: map[string]any{"session": s.Name, "path": s.Dir}})
	time.Sleep(150 * time.Millisecond)
	if n := len(r.snd.byType("alert")); n != 0 {
		t.Fatalf("expected no alert for a wait answered meanwhile, got %d", n)
	}
}

// --- end answer from the notification ---

func TestPermissionWithoutMenuFallsBackToQuestionCategory(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.screen = "just some output\n"
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	s := sess("waiting", time.Now())
	s.Ask = &boxapi.Ask{Tool: "Bash", Input: "ls"}
	r.change(s)
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	if !strings.Contains(string(r.snd.byType("alert")[0].Payload), `"category":"NEEDS_YOU_QUESTION"`) {
		t.Fatalf("%s", r.snd.byType("alert")[0].Payload)
	}
}

func TestAnsweredBeforeItSettlesSendsNoAlert(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.screen = readScreen(t, "screen_permission.json")
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	w := sess("waiting", time.Now())
	w.Ask = &boxapi.Ask{Tool: "Bash", Input: "ls"}
	r.change(w)
	time.Sleep(5 * time.Millisecond)
	r.change(sess("running", time.Now().Add(time.Millisecond))) // answered at once
	time.Sleep(200 * time.Millisecond)
	if n := len(r.snd.byType("alert")); n != 0 {
		t.Fatalf("%d alerts for a state that lasted milliseconds", n)
	}
}

func TestOneAlertPerTransitionDespiteEventBurst(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.screen = readScreen(t, "screen_permission.json")
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	w := sess("waiting", time.Now())
	w.Ask = &boxapi.Ask{Tool: "Bash", Input: "ls"}
	r.box.set(w)
	for i := 0; i < 10; i++ { // the same state announced by several events (and a periodic resync)
		r.eng.OnEvent(boxapi.Event{Seq: uint64(i + 1), Type: "agent.waiting", Time: w.StateSince, Data: map[string]any{"session": w.Name}})
		r.eng.Sync(context.Background(), false)
	}
	time.Sleep(250 * time.Millisecond)
	if n := len(r.snd.byType("alert")); n != 1 {
		t.Fatalf("%d alerts, want 1", n)
	}
}

func TestEventsPrefsRespectedButActivityStillUpdates(t *testing.T) {
	d := dev("c1", "en")
	d.Events = state.Events{Waiting: false, Finished: true}
	r := newRig(t, d)
	r.st.PutActivity(state.Activity{Client: "c1", Box: "casa", Session: "sandbox-subtract-claude-6s1", Token: "00aa11bb", Env: "development"})
	r.box.screen = readScreen(t, "screen_permission.json")
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	w := sess("waiting", time.Now())
	w.Ask = &boxapi.Ask{Tool: "Bash", Input: "rm -rf build"}
	r.change(w)
	waitFor(t, "activity update", func() bool { return len(r.snd.byType("liveactivity")) == 1 })
	if len(r.snd.byType("alert")) != 0 {
		t.Fatal("alert sent although events.waiting is off")
	}
	q := r.snd.byType("liveactivity")[0]
	if q.Topic != "com.example.pier.push-type.liveactivity" || q.Token != "00aa11bb" || q.Priority != 10 {
		t.Fatalf("%+v", q)
	}
	var p struct {
		APS struct {
			Event string
			CS    struct {
				Phase   string
				Ask     string
				HasMenu bool `json:"hasMenu"`
				Since   float64
			} `json:"content-state"`
		}
	}
	json.Unmarshal(q.Payload, &p)
	if p.APS.Event != "update" || p.APS.CS.Phase != "waiting" || p.APS.CS.Ask != "Bash  rm -rf build" || !p.APS.CS.HasMenu {
		t.Fatalf("%s", q.Payload)
	}
	// since is Unix seconds
	if want := float64(w.StateSince.Unix()); p.APS.CS.Since < want-1 || p.APS.CS.Since > want+1 {
		t.Fatalf("since %v, want about %v", p.APS.CS.Since, want)
	}
}

func TestFinishedAlertWithReviewCounts(t *testing.T) {
	r := newRig(t, dev("c1", "pt-BR"))
	r.box.review = []boxapi.ReviewItem{{Session: "sandbox-subtract-claude-6s1", Added: 6, Removed: 2}}
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	var p struct {
		APS struct {
			Alert    struct{ Title, Body string }
			Category string
		}
		HasMenu *bool `json:"hasMenu"`
	}
	json.Unmarshal(r.snd.byType("alert")[0].Payload, &p)
	if p.APS.Category != "FINISHED" || p.APS.Alert.Title != "✅ Concluído · Corrigir login" || p.APS.Alert.Body != "Adicionei a função mul em calc.py e os testes passaram.\n+6 −2" || p.HasMenu != nil {
		t.Fatalf("%+v", p)
	}
}

func TestInterruptedFinishNoAlert(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	f := sess("finished", time.Now())
	r.box.set(f)
	r.eng.OnEvent(boxapi.Event{Seq: 2, Type: "agent.finished", Time: f.StateSince, Data: map[string]any{"session": f.Name, "source": "interrupt"}})
	time.Sleep(200 * time.Millisecond)
	if len(r.snd.byType("alert")) != 0 {
		t.Fatal("an interrupted turn must not alert")
	}
}

func TestFailedFinish(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	f := sess("finished", time.Now())
	r.box.set(f)
	r.eng.OnEvent(boxapi.Event{Seq: 2, Type: "agent.finished", Time: f.StateSince, Data: map[string]any{"session": f.Name, "status": "error"}})
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
	if !strings.Contains(string(r.snd.byType("alert")[0].Payload), "⚠️ Failed · Corrigir login") {
		t.Fatalf("%s", r.snd.byType("alert")[0].Payload)
	}
}

func TestStaleStateIsNotAnnounced(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.box.set(sess("running", time.Now().Add(-time.Hour)))
	r.start()
	r.change(sess("finished", time.Now().Add(-30*time.Minute)))
	time.Sleep(200 * time.Millisecond)
	if len(r.snd.byType("alert")) != 0 {
		t.Fatal("a 30 minute old state must not alert")
	}
}

func TestBadDeviceTokenIsDropped(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.snd.result = func(apns.Request) apns.Result { return apns.Result{Status: 400, Reason: "BadDeviceToken"} }
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	waitFor(t, "token dropped", func() bool { _, ok := r.st.Device("c1"); return !ok })
}

func TestRestartAnnouncesWhatChangedWhileDown(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.st.SetSeen("sandbox-subtract-claude-6s1", state.Seen{State: "running", Since: time.Now().Add(-time.Minute)})
	r.box.set(sess("finished", time.Now())) // finished while push was down
	r.start()                               // initial sync, but the session is known: it is a real transition
	waitFor(t, "alert", func() bool { return len(r.snd.byType("alert")) == 1 })
}

func TestExitEndsActivityAndForgetsToken(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.st.PutActivity(state.Activity{Client: "c1", Box: "casa", Session: "sandbox-subtract-claude-6s1", Token: "00aa11bb", Env: "development"})
	r.box.set(sess("finished", time.Now().Add(-time.Minute)))
	r.start()
	x := sess("finished", time.Now().Add(-time.Minute))
	x.Exited = true
	r.change(x)
	waitFor(t, "end push", func() bool { return len(r.snd.byType("liveactivity")) == 1 })
	var p struct {
		APS struct {
			Event         string
			DismissalDate int64                  `json:"dismissal-date"`
			CS            struct{ Phase string } `json:"content-state"`
		}
	}
	json.Unmarshal(r.snd.byType("liveactivity")[0].Payload, &p)
	if p.APS.Event != "end" || p.APS.CS.Phase != "ended" || p.APS.DismissalDate == 0 {
		t.Fatalf("%s", r.snd.byType("liveactivity")[0].Payload)
	}
	waitFor(t, "activity forgotten", func() bool { return len(r.st.Activities()) == 0 })
}

func TestRevokedClientGetsNothing(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.eng.paired = func(string) bool { return false }
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	time.Sleep(200 * time.Millisecond)
	if len(r.snd.reqs) != 0 {
		t.Fatalf("%d pushes to a revoked client", len(r.snd.reqs))
	}
}

func TestWidgetReloadThrottledAndPushToStart(t *testing.T) {
	d := dev("c1", "en")
	d.WidgetToken = "aa11bb22"
	d.PushToStartToken = "cc33dd44"
	d.BoxName = "casa"
	r := newRig(t, d)
	r.box.set(sess("idle", time.Now().Add(-time.Hour)))
	r.start()
	r.change(sess("running", time.Now()))
	waitFor(t, "start+widget", func() bool { return len(r.snd.byType("liveactivity")) == 1 && len(r.snd.byType("widgets")) == 1 })
	st := r.snd.byType("liveactivity")[0]
	var p struct {
		APS struct {
			Event string
			Type  string         `json:"attributes-type"`
			Attrs map[string]any `json:"attributes"`
			CS    map[string]any `json:"content-state"`
		}
	}
	json.Unmarshal(st.Payload, &p)
	if st.Token != "cc33dd44" || p.APS.Event != "start" || p.APS.Type != "SessionActivityAttributes" || p.APS.Attrs["box"] != "casa" || p.APS.Attrs["project"] != "sandbox · subtract" || p.APS.Attrs["agent"] != "claude" {
		t.Fatalf("%+v", p)
	}
	if w := r.snd.byType("widgets")[0]; w.Topic != "com.example.pier.push-type.widgets" || w.Token != "aa11bb22" || string(w.Payload) != `{"aps":{"content-changed":true}}` {
		t.Fatalf("%+v", w)
	}
	// more transitions within the window: no second start, no second widget push
	r.change(sess("waiting", time.Now().Add(time.Second)))
	time.Sleep(200 * time.Millisecond)
	if len(r.snd.byType("widgets")) != 1 {
		t.Fatal("widget reloads must be throttled to one per interval")
	}
	starts := 0
	for _, q := range r.snd.byType("liveactivity") {
		if strings.Contains(string(q.Payload), `"event":"start"`) {
			starts++
		}
	}
	if starts != 1 {
		t.Fatalf("%d push-to-start requests, want 1", starts)
	}
}

func TestPushToStartSkippedWhenThePhoneStartedItsOwn(t *testing.T) {
	d := dev("c1", "en")
	d.PushToStartToken = "cc33dd44"
	r := newRig(t, d)
	r.box.set(sess("idle", time.Now().Add(-time.Hour)))
	r.start()
	r.change(sess("running", time.Now()))
	// the app registers the token of the activity it started itself, inside the grace period
	r.st.PutActivity(state.Activity{Client: "c1", Box: "casa", Session: "sandbox-subtract-claude-6s1", Token: "00aa11bb", Env: "development"})
	time.Sleep(200 * time.Millisecond)
	for _, q := range r.snd.byType("liveactivity") {
		if strings.Contains(string(q.Payload), `"event":"start"`) {
			t.Fatal("push-to-start sent although the phone has its own activity (duplicate Live Activity)")
		}
	}
}

func TestFinishedActivityCarriesTheReply(t *testing.T) {
	r := newRig(t, dev("c1", "en"))
	r.st.PutActivity(state.Activity{Client: "c1", Box: "casa", Session: "sandbox-subtract-claude-6s1", Token: "00aa11bb", Env: "development"})
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	waitFor(t, "activity update", func() bool { return len(r.snd.byType("liveactivity")) == 1 })
	var p struct {
		APS struct {
			CS struct{ Reply string } `json:"content-state"`
		}
	}
	json.Unmarshal(r.snd.byType("liveactivity")[0].Payload, &p)
	if !strings.HasPrefix(p.APS.CS.Reply, "Adicionei a função mul") || !strings.Contains(p.APS.CS.Reply, "lint") {
		t.Fatalf("reply %q", p.APS.CS.Reply)
	}
}

func TestFinishedWithBackgroundWorkIsNotDone(t *testing.T) {
	r := newRig(t, dev("c1", "pt-BR"))
	r.box.bg = []string{"scripts/verificar.sh 41710"}
	r.st.PutActivity(state.Activity{Client: "c1", Box: "casa", Session: "sandbox-subtract-claude-6s1", Token: "00aa11bb", Env: "development"})
	r.box.set(sess("running", time.Now().Add(-time.Minute)))
	r.start()
	r.change(sess("finished", time.Now()))
	waitFor(t, "alert+activity", func() bool { return len(r.snd.byType("alert")) == 1 && len(r.snd.byType("liveactivity")) == 1 })
	a := string(r.snd.byType("alert")[0].Payload)
	if !strings.Contains(a, "⏳ Em segundo plano") || !strings.Contains(a, "⏳ scripts/verificar.sh 41710") {
		t.Fatalf("%s", a)
	}
	if la := string(r.snd.byType("liveactivity")[0].Payload); !strings.Contains(la, `"phase":"running"`) {
		t.Fatalf("%s", la)
	}
}

func TestPushToStartAfterAQuickTurnStillStartsTheNextOne(t *testing.T) {
	d := dev("c1", "en")
	d.PushToStartToken = "cc33dd44"
	r := newRig(t, d)
	r.box.set(sess("idle", time.Now().Add(-time.Hour)))
	r.start()
	r.change(sess("running", time.Now()))
	r.change(sess("finished", time.Now().Add(10*time.Millisecond))) // done before the grace period ends
	time.Sleep(150 * time.Millisecond)
	r.change(sess("running", time.Now().Add(time.Second))) // a longer turn later
	waitFor(t, "push-to-start for the second turn", func() bool {
		for _, q := range r.snd.byType("liveactivity") {
			if strings.Contains(string(q.Payload), `"event":"start"`) {
				return true
			}
		}
		return false
	})
}
