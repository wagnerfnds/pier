package payload

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "rewrite golden files")

func golden(t *testing.T, name string, got []byte) {
	t.Helper()
	var buf bytes.Buffer
	if err := json.Indent(&buf, got, "", "  "); err != nil {
		t.Fatalf("%s: invalid JSON: %v\n%s", name, err, got)
	}
	buf.WriteByte('\n')
	path := filepath.Join("testdata", name+".golden.json")
	if *update {
		os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run go test -update)", err)
	}
	if !bytes.Equal(want, buf.Bytes()) {
		t.Fatalf("%s differs from golden\n--- got\n%s--- want\n%s", name, buf.String(), want)
	}
}

func sp(s string) *string { return &s }
func ip(i int) *int       { return &i }
func bp(b bool) *bool     { return &b }

var now = time.Unix(1790000000, 0).UTC()

func TestAlertPermission(t *testing.T) {
	b, err := BuildAlert(AlertParams{
		Box: "casa", Session: "projeto-wt-1", Location: "projeto/wt-1",
		Title: "✋ Precisa de você · Claude Code", Body: "Claude Code · projeto / wt-1 · casa\nBash  rm -rf build",
		Category: CategoryNeedsYou, HasMenu: bp(true), Level: "time-sensitive", Sound: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	golden(t, "alert_waiting_permission", b)
}

func TestAlertQuestion(t *testing.T) {
	b, _ := BuildAlert(AlertParams{
		Box: "casa", Session: "projeto-wt-1", Location: "projeto/wt-1", Title: "✋ Needs you · Claude Code", Body: "AskUserQuestion  Which colour?",
		Category: CategoryNeedsYouQuestion, HasMenu: bp(false), Level: "time-sensitive", Sound: true,
	})
	golden(t, "alert_waiting_question", b)
}

func TestAlertQuestionWithOptions(t *testing.T) {
	b, _ := BuildAlert(AlertParams{
		Box: "casa", Session: "projeto-wt-1", Location: "projeto/wt-1", Title: "✋ Needs you · Pricing page",
		Body:     "AskUserQuestion  Which layout?\n1 Three tiers · 2 One plan · 3 A table",
		Category: CategoryNeedsYouChoice(3), HasMenu: bp(false), Options: []string{"Three tiers", "One plan", "A table"}, OptionsKind: "menu",
		Level: "time-sensitive", Sound: true,
	})
	golden(t, "alert_waiting_question_options", b)
}

func TestAlertFinished(t *testing.T) {
	b, _ := BuildAlert(AlertParams{
		Box: "casa", Session: "projeto-wt-1", Location: "projeto/wt-1", Title: "✅ Concluído · Corrigir login", Body: "Claude Code · projeto / wt-1 · casa · +6 −0",
		Category: CategoryFinished, Level: "active", Sound: true,
	})
	golden(t, "alert_finished", b)
}

func TestActivityWaitingUpdate(t *testing.T) {
	since := now.Add(-90*time.Second + 250*time.Millisecond)
	b, _ := BuildActivity(ActivityParams{
		Event: "update", Now: now,
		State: ContentState{Phase: "waiting", Since: EncodeDate(since, "unix"), Ask: sp("Bash  rm -rf build"), HasMenu: true},
		Alert: &AlertText{Title: "Corrigir login", Body: "Precisa de você"},
	})
	golden(t, "activity_update_waiting", b)
}

func TestActivityRunningUpdateAllNulls(t *testing.T) {
	b, _ := BuildActivity(ActivityParams{
		Event: "update", Now: now, State: ContentState{Phase: "running", Since: EncodeDate(now, "unix")},
	})
	golden(t, "activity_update_running", b)
}

func TestActivityFinishedUpdate(t *testing.T) {
	b, _ := BuildActivity(ActivityParams{
		Event: "update", Now: now, StaleAfter: time.Hour,
		State: ContentState{Phase: "finished", Since: EncodeDate(now, "unix"), Added: ip(6), Removed: ip(0)},
		Alert: &AlertText{Title: "Corrigir login", Body: "Concluído"},
	})
	golden(t, "activity_update_finished", b)
}

func TestActivityEnd(t *testing.T) {
	d := now.Add(5 * time.Minute)
	b, _ := BuildActivity(ActivityParams{
		Event: "end", Now: now, DismissAt: &d, State: ContentState{Phase: "ended", Since: EncodeDate(now, "unix")},
	})
	golden(t, "activity_end", b)
}

func TestActivityStart(t *testing.T) {
	b, _ := BuildActivity(ActivityParams{
		Event: "start", Now: now, AttributeType: "SessionActivityAttributes",
		State:      ContentState{Phase: "running", Since: EncodeDate(now, "unix"), Step: sp("Brewing…")},
		Attributes: &Attributes{Box: "casa", Session: "projeto-wt-1", Title: "Corrigir login", Project: "projeto", Agent: sp("claude")},
		Alert:      &AlertText{Title: "Corrigir login", Body: "Trabalhando"},
	})
	golden(t, "activity_start", b)
}

func TestWidget(t *testing.T) { golden(t, "widget", BuildWidget()) }

func TestDateEncoding(t *testing.T) {
	ref := time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	if EncodeDate(ref, "unix") != 978307200 || EncodeDate(ref, "") != 978307200 {
		t.Fatal("unix seconds is the default")
	}
	// opt-in: Swift's default Date coding counts from 2001-01-01
	if EncodeDate(ref, "reference") != 0 {
		t.Fatalf("got %v", EncodeDate(ref, "reference"))
	}
	if got := EncodeDate(time.Unix(1790000000, 500_000_000), "unix"); got != 1790000000.5 {
		t.Fatalf("got %v", got)
	}
}

func TestContentStateRoundTripsLikeSwift(t *testing.T) {
	// every key present, so Codable's synthesized init(from:) never misses one
	b, _ := json.Marshal(ContentState{Phase: "running", Since: 1})
	var m map[string]any
	json.Unmarshal(b, &m)
	for _, k := range []string{"phase", "since", "step", "ask", "hasMenu", "added", "removed", "reply"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("missing key %s in %s", k, b)
		}
	}
}
