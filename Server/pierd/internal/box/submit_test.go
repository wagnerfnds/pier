package box

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
)

// The fixtures in testdata/submit are Claude Code 2.1.302's and Codex
// 0.160.1's screens at 200×50, captured with tmux capture-pane -p -J -e in a
// scratch repository: at the trust question, idle, after a paste (a line,
// three lines, a 1,214-character line, twenty lines), with a new line after
// the text, while working, with a prompt sent while working, after a turn,
// and with a slash command typed; and Claude Code 2.1.308's tip to teach
// auto mode about the environment, after a turn in a chat in auto mode.

func submitScreen(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "submit", name+".ansi"))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

const (
	pasteLine  = "Reply with the single word OK and nothing else."
	pasteMulti = "Line one of a pasted note\nLine two of a pasted note\nLine three of a pasted note"
)

func TestReadInputOnRealScreens(t *testing.T) {
	for _, c := range []struct {
		name, agent string
		found       bool
		empty       bool
		shows       string // a prompt the box shows
		lines       int
	}{
		{"claude-idle", "claude", true, true, "", 1},
		{"claude-paste-line", "claude", true, false, pasteLine, 1},
		{"claude-paste-multi", "claude", true, false, pasteMulti, 3},
		{"claude-paste-long", "claude", true, false, "lorem ipsum, as long as you like", 1},
		{"claude-paste-many", "claude", true, false, "Line 1 of a longer pasted log", 1},
		{"claude-newline-in-input", "claude", true, false, pasteLine, 2},
		{"claude-fast-enter", "claude", true, true, "", 1},
		{"claude-busy-send", "claude", true, true, "", 1},
		{"claude-after-turn", "claude", true, true, "", 1},
		{"claude-slash", "claude", true, false, "/model", 1},
		{"claude-trust", "claude", false, false, "", 0},
		{"codex-idle", "codex", true, true, "", 1},
		{"codex-paste-line", "codex", true, false, pasteLine, 1},
		{"codex-paste-multi", "codex", true, false, pasteMulti, 3},
		{"codex-paste-long", "codex", true, false, "lorem ipsum, as long as you like", 1},
		{"codex-busy", "codex", true, true, "", 1},
		{"codex-busy-send", "codex", true, true, "", 1},
		{"codex-after", "codex", true, true, "", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			box, _, _, found := readInput(c.agent, parseStyled(submitScreen(t, c.name)))
			if found != c.found {
				t.Fatalf("found %v, want %v (box %q)", found, c.found, box.text)
			}
			if !found {
				return
			}
			if box.empty() != c.empty {
				t.Errorf("empty %v, want %v: %q", box.empty(), c.empty, box.text)
			}
			if box.lines != c.lines {
				t.Errorf("%d lines, want %d: %q", box.lines, c.lines, box.text)
			}
			if c.shows != "" && !box.shows(signOf(c.shows)) {
				t.Errorf("does not show %q: %q", c.shows, box.text)
			}
			if c.shows == pasteLine || c.shows == pasteMulti {
				// All of it: its last words, where the cursor is.
				if !box.landed(signOf(c.shows), inputBox{}) {
					t.Errorf("all of %q has not landed: %q", c.shows, box.text)
				}
			}
			// Nothing else is taken for the prompt: the conversation above
			// shows earlier prompts with the same marks.
			if c.empty && box.shows(signOf(pasteLine)) {
				t.Errorf("an empty box shows the prompt: %q", box.text)
			}
		})
	}
}

// The prompt sent while Claude Code worked shows above its box, queued; the
// box itself is empty again.
func TestReadViewSeesAQueuedPromptOutsideTheBox(t *testing.T) {
	ft := &fixedTerm{s: submitScreen(t, "claude-busy-send")}
	v, err := readView(ft, "claude")
	if err != nil || !v.found || !v.box.empty() {
		t.Fatalf("view %+v, %v", v, err)
	}
	if !strings.Contains(v.outside, signOf(pasteMulti).head) {
		t.Fatalf("the queued prompt is not outside the box: %q", v.outside)
	}
}

func TestSignOf(t *testing.T) {
	s := signOf("  Fix the *webhook* retries,\n  then run the tests in the payments package")
	if s.head != "fixthewebhookretriesthen" || s.tail != "estsinthepaymentspackage" {
		t.Fatalf("sign %+v", s)
	}
	if got := signOf("??"); got.head != "" || got.tail != "" {
		t.Fatalf("sign %+v", got)
	}
	// Wrapped by the box mid-word or at a space, it still matches.
	b := inputBox{text: "Fix the webho\n  ok retries, then run the tests"}
	if !b.shows(signOf("Fix the webhook retries, then run the tests")) || !b.landed(signOf("Fix the webhook retries, then run the tests"), inputBox{}) {
		t.Fatal("a wrapped prompt is not found")
	}
	// Only its start in the box: not all of it yet.
	if (inputBox{text: "Fix the webhook retries, th"}).landed(signOf("Fix the webhook retries, then run the tests in the payments package"), inputBox{}) {
		t.Fatal("the start of a paste counts as all of it")
	}
	// What the box held before does not count.
	was := inputBox{text: "earlier words"}
	if (inputBox{text: "earlier words"}).holds(signOf("earlier words"), was) {
		t.Fatal("the box's own text was taken for the paste")
	}
	if got := trimBlankLines("\n  \n  indented\nmore\n\n  "); got != "  indented\nmore" {
		t.Fatalf("trimmed %q", got)
	}
}

type fixedTerm struct{ s string }

func (f *fixedTerm) paste(string) error      { return nil }
func (f *fixedTerm) keys(...string) error    { return nil }
func (f *fixedTerm) screen() (string, error) { return f.s, nil }

// agentTerm is an agent's terminal: a conversation, the input box under it,
// and what each Enter does.
type agentTerm struct {
	mu        sync.Mutex
	agent     string
	convo     []string
	box       []string
	enters    []time.Time
	sent      []string // every key and paste, in order
	reads     int
	onEnter   func(n int) string // "submit", "newline", "nothing", "late"
	lateAt    time.Time          // when a late Enter goes in
	dropPaste bool               // the paste never shows
	partial   bool               // only the first half of the paste shows
	garble    bool               // the box draws its text in marks pierd cannot read as words
	flicker   int                // reads after an Enter drawn without the box, a frame halfway
	stuck     bool               // Ctrl-U and Backspace do nothing
	spinner   int                // reads that still show the agent working
	tip       bool               // Claude Code's auto-mode tip holds the box until Esc
}

func (f *agentTerm) paste(text string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, "paste")
	if f.dropPaste || f.tip {
		return nil
	}
	if f.partial {
		text = text[:len(text)/2]
	}
	lines := strings.Split(text, "\n")
	if len(f.box) == 0 {
		f.box = lines
	} else {
		f.box[len(f.box)-1] += lines[0]
		f.box = append(f.box, lines[1:]...)
	}
	return nil
}

func (f *agentTerm) submit() {
	if len(f.box) > 0 {
		f.convo = append(f.convo, "› "+strings.Join(f.box, " "))
	}
	f.box = nil
}

func (f *agentTerm) keys(k ...string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, key := range k {
		f.sent = append(f.sent, key)
		switch key {
		case "Enter":
			f.enters = append(f.enters, time.Now())
			switch f.onEnter(len(f.enters)) {
			case "submit":
				f.submit()
			case "newline":
				f.box = append(f.box, "")
			case "late":
				// Just after pierd stops watching for it.
				f.lateAt = time.Now().Add(submitWithin + 15*time.Millisecond)
			}
		case "Escape":
			f.tip = false
		case "C-u":
			if !f.stuck && len(f.box) > 0 {
				f.box[len(f.box)-1] = ""
			}
		case "BSpace":
			if !f.stuck && len(f.box) > 1 && f.box[len(f.box)-1] == "" {
				f.box = f.box[:len(f.box)-1]
			}
		}
	}
	return nil
}

func (f *agentTerm) screen() (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reads++
	if !f.lateAt.IsZero() && time.Now().After(f.lateAt) {
		f.lateAt = time.Time{}
		f.submit()
	}
	if len(f.box) == 1 && f.box[0] == "" {
		f.box = nil
	}
	var b strings.Builder
	for _, l := range f.convo {
		b.WriteString("\x1b[39m" + l + "\n")
	}
	if f.spinner > 0 || !f.lateAt.IsZero() {
		// Working: a late Enter's agent is busy redrawing until it takes it.
		if f.spinner > 0 {
			f.spinner--
		}
		b.WriteString("\x1b[39m✻ Brewing… (" + strings.Repeat("·", f.reads%5) + ")\n")
	}
	if f.flicker > 0 && len(f.enters) > 0 {
		f.flicker--
		return b.String(), nil // drawn halfway: no box yet
	}
	box := f.box
	if f.garble {
		box = nil
		for _, l := range f.box {
			box = append(box, strings.Repeat("•", len([]rune(l))))
		}
	}
	text := strings.Join(box, "\n")
	switch f.agent {
	case "claude":
		rule := "\x1b[38;5;244m" + strings.Repeat("─", 60) + "\n"
		if f.tip {
			b.WriteString(rule + "\x1b[1m  " + autoModeTip + "\x1b[0m\n  ❯ 1. Yes\n    2. Not now\n    3. Don't show again\n  Enter to confirm · Esc to cancel\n")
		}
		b.WriteString(rule)
		switch {
		case len(box) == 0:
			b.WriteString("\x1b[39m❯ \x1b[2mTry \"how does <filepath> work?\"\x1b[0m\n")
		case len(text) > 800:
			b.WriteString("\x1b[39m❯ [Pasted text #1]\n")
		default:
			for i, l := range box {
				if i == 0 {
					b.WriteString("\x1b[39m❯ " + l + "\n")
				} else {
					b.WriteString("  " + l + "\n")
				}
			}
		}
		b.WriteString(rule)
		b.WriteString("\x1b[39m  \x1b[38;5;220m⏵⏵ auto mode on\x1b[38;5;246m (shift+tab to cycle)\n")
	case "codex":
		b.WriteString("\n")
		switch {
		case len(box) == 0:
			b.WriteString("\x1b[1m›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m\n")
		case len(text) > 1000:
			b.WriteString("\x1b[1m›\x1b[0m \x1b[38;5;6m[Pasted Content 1214 chars]\x1b[39m\n")
		default:
			for i, l := range box {
				if i == 0 {
					b.WriteString("\x1b[1m›\x1b[0m " + l + "\n")
				} else {
					b.WriteString("  " + l + "\n")
				}
			}
		}
		b.WriteString("\n  GPT-6.1-Sol medium · /home/octocat/code/shop\n")
	default:
		b.WriteString("$ " + text + "\n")
	}
	return b.String(), nil
}

func (f *agentTerm) count(key string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, k := range f.sent {
		if k == key {
			n++
		}
	}
	return n
}

// fastSubmit runs a test's submits on short clocks.
func fastSubmit(t *testing.T) {
	saved := []time.Duration{quietGap, quietLimit, pasteShows, pastePoll, pasteSettle, submitWithin, submitPoll, clearPoll, boxShows, clearLimit}
	quietGap, quietLimit, pasteShows, pastePoll = 3*time.Millisecond, 60*time.Millisecond, 120*time.Millisecond, 2*time.Millisecond
	pasteSettle, submitWithin, submitPoll, clearPoll = 0, 150*time.Millisecond, 3*time.Millisecond, time.Millisecond
	boxShows, clearLimit = 30*time.Millisecond, 200*time.Millisecond
	t.Cleanup(func() {
		quietGap, quietLimit, pasteShows, pastePoll = saved[0], saved[1], saved[2], saved[3]
		pasteSettle, submitWithin, submitPoll, clearPoll, boxShows, clearLimit = saved[4], saved[5], saved[6], saved[7], saved[8], saved[9]
	})
}

func always(what string) func(int) string { return func(int) string { return what } }

func TestSubmitWhenTheBoxTakesTheEnter(t *testing.T) {
	fastSubmit(t)
	for _, agent := range []string{"claude", "codex"} {
		for _, text := range []string{pasteLine, pasteMulti, strings.Repeat("lorem ipsum dolor sit amet ", 45)} {
			f := &agentTerm{agent: agent, onEnter: always("submit")}
			entered, err := submitPrompt(context.Background(), f, submitParams{agent: agent}, text)
			if err != nil || entered.IsZero() {
				t.Fatalf("%s: %v (entered %v)", agent, err, entered)
			}
			if n := f.count("Enter"); n != 1 {
				t.Errorf("%s: %d Enters, want 1", agent, n)
			}
			if len(f.convo) != 1 {
				t.Errorf("%s: sent %d times", agent, len(f.convo))
			}
		}
	}
}

// Claude Code 2.1.308 offers, after a turn in auto mode, to teach auto mode
// about the environment, and the box takes nothing while it shows: a prompt
// declines it (Esc) and goes in. A screen without it gets no Esc.
func TestSubmitDeclinesTheAutoModeTip(t *testing.T) {
	fastSubmit(t)
	if !strings.Contains(screenText(submitScreen(t, "claude-automode-tip")), autoModeTip) {
		t.Fatal("the tip is not read off Claude Code's own screen")
	}
	f := &agentTerm{agent: "claude", onEnter: always("submit"), tip: true}
	if _, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteLine); err != nil {
		t.Fatalf("under the tip: %v", err)
	}
	if f.count("Escape") != 1 || len(f.convo) != 1 || f.sent[0] != "Escape" {
		t.Errorf("sent %v, conversation %v", f.sent, f.convo)
	}
	plain := &agentTerm{agent: "claude", onEnter: always("submit")}
	if _, err := submitPrompt(context.Background(), plain, submitParams{agent: "claude"}, pasteLine); err != nil || plain.count("Escape") != 0 {
		t.Errorf("without the tip: %v, sent %v", err, plain.sent)
	}
	// Codex has no such tip: its screen is never read for it.
	codex := &agentTerm{agent: "codex", onEnter: always("submit")}
	if _, err := submitPrompt(context.Background(), codex, submitParams{agent: "codex"}, pasteLine); err != nil || codex.count("Escape") != 0 {
		t.Errorf("codex: %v, sent %v", err, codex.sent)
	}
}

// A box that draws its text in a way pierd cannot read word for word: more
// text than before, holding still, is the paste.
func TestSubmitSeesAPasteItCannotReadAsWords(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: always("submit"), garble: true}
	if _, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteLine); err != nil {
		t.Fatal(err)
	}
	if n := f.count("Enter"); n != 1 || len(f.convo) != 1 {
		t.Fatalf("%d Enters, sent %d times", n, len(f.convo))
	}
}

// The Enter that lands as a new line (the agent still reading the paste):
// one more, and it goes; the Enter that sent it is the first's time.
func TestSubmitRetriesAnEnterThatBecameANewLine(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: func(n int) string {
		if n == 1 {
			return "newline"
		}
		return "submit"
	}}
	entered, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteLine)
	if err != nil {
		t.Fatal(err)
	}
	if n := f.count("Enter"); n != 2 {
		t.Fatalf("%d Enters, want 2", n)
	}
	if len(f.convo) != 1 || len(f.box) != 0 {
		t.Fatalf("convo %q, box %q", f.convo, f.box)
	}
	if entered.After(f.enters[0]) || f.enters[0].Sub(entered) > 50*time.Millisecond {
		t.Fatalf("entered %v, the first Enter went at %v", entered, f.enters[0])
	}
}

// A frame drawn halfway after the Enter (the box not drawn yet) is not the
// box letting go of the prompt.
func TestSubmitDoesNotTakeAHalfDrawnFrameForASend(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", flicker: 1, onEnter: func(n int) string {
		if n == 1 {
			return "newline"
		}
		return "submit"
	}}
	if _, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteLine); err != nil {
		t.Fatal(err)
	}
	if n := f.count("Enter"); n != 2 {
		t.Fatalf("%d Enters: a half-drawn frame was taken for the prompt going in", n)
	}
}

// Never taken: two Enters at most, the box cleared, and the app told the
// text is not there any more (it gives it back to the person).
func TestSubmitGivesUpAfterTwoEnters(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: always("newline")}
	_, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteMulti)
	var ns *NotSubmittedError
	if !errors.As(err, &ns) || ns.Kept {
		t.Fatalf("err %v, want not submitted and not kept", err)
	}
	if n := f.count("Enter"); n != 2 {
		t.Fatalf("%d Enters, want 2", n)
	}
	if len(f.box) != 0 {
		t.Fatalf("the box was left holding %q", f.box)
	}
	if codeFor(err) != CodeNotSubmitted || statusFor(err) != 409 {
		t.Fatalf("code %s, status %d", codeFor(err), statusFor(err))
	}
}

// A box that cannot be cleared: kept, so the app does not give the text back
// (sent again, it would go twice once someone presses Enter there).
func TestSubmitSaysWhenTheTextStaysInTheBox(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "codex", onEnter: always("nothing"), stuck: true}
	_, err := submitPrompt(context.Background(), f, submitParams{agent: "codex"}, pasteLine)
	var ns *NotSubmittedError
	if !errors.As(err, &ns) || !ns.Kept {
		t.Fatalf("err %v, want kept", err)
	}
	if n := f.count("Enter"); n != 2 {
		t.Fatalf("%d Enters, want 2", n)
	}
}

// A paste that never shows: no Enter at all, and, the box as it was, not
// kept (nothing of it is there).
func TestSubmitNeverPressesEnterOnAPasteThatDidNotShow(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: always("submit"), dropPaste: true}
	_, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteLine)
	var ns *NotSubmittedError
	if !errors.As(err, &ns) || ns.Kept {
		t.Fatalf("err %v, want not submitted, not kept", err)
	}
	if n := f.count("Enter"); n != 0 {
		t.Fatalf("%d Enters, want none", n)
	}
}

// Only part of a paste shows: no Enter on it; what landed is taken out
// again, and kept only when it could not be.
func TestSubmitTakesOutAPasteThatShowedInPart(t *testing.T) {
	fastSubmit(t)
	text := "Fix the webhook retries, then run the tests in the payments package and report what failed"
	f := &agentTerm{agent: "claude", onEnter: always("submit"), partial: true}
	_, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, text)
	var ns *NotSubmittedError
	if !errors.As(err, &ns) || ns.Kept || f.count("Enter") != 0 || len(f.box) != 0 {
		t.Fatalf("err %v, %d Enters, box %q", err, f.count("Enter"), f.box)
	}
	f = &agentTerm{agent: "claude", onEnter: always("submit"), partial: true, stuck: true}
	_, err = submitPrompt(context.Background(), f, submitParams{agent: "claude"}, text)
	if !errors.As(err, &ns) || !ns.Kept || f.count("Enter") != 0 {
		t.Fatalf("err %v, %d Enters: a half paste that stayed must be kept", err, f.count("Enter"))
	}
}

// A long paste is given longer to show.
func TestPasteWaitGrowsWithThePaste(t *testing.T) {
	if pasteWait(10) != pasteShows || pasteWait(256<<10) != pasteShows+4*time.Second || pasteWait(64<<20) != pasteMost {
		t.Fatalf("waits %v %v %v", pasteWait(10), pasteWait(256<<10), pasteWait(64<<20))
	}
}

// An Enter the agent takes only after pierd stopped watching: the box is
// empty by the second try, so no second Enter.
func TestSubmitTakesALateEnter(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: always("late")}
	if _, err := submitPrompt(context.Background(), f, submitParams{agent: "claude"}, pasteLine); err != nil {
		t.Fatal(err)
	}
	if n := f.count("Enter"); n != 1 {
		t.Fatalf("%d Enters, want 1", n)
	}
	if len(f.convo) != 1 {
		t.Fatalf("sent %d times", len(f.convo))
	}
}

// The agent's hooks say the prompt started: that is enough, whatever the
// screen shows yet.
func TestSubmitBelievesTheHooks(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: always("nothing")}
	var mu sync.Mutex
	state := ledgerState{seq: 10, state: "finished", hooked: true}
	p := submitParams{agent: "claude", ledger: func() ledgerState {
		mu.Lock()
		defer mu.Unlock()
		if f.count("Enter") > 0 {
			state = ledgerState{seq: 11, state: "running", hooked: true}
		}
		return state
	}}
	if _, err := submitPrompt(context.Background(), f, p, pasteLine); err != nil {
		t.Fatal(err)
	}
	if n := f.count("Enter"); n != 1 {
		t.Fatalf("%d Enters, want 1", n)
	}
}

// A held prompt waits for the screen to hold still before it is pasted.
func TestSubmitWaitsForAQuietScreen(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "claude", onEnter: always("submit"), spinner: 6}
	if _, err := submitPrompt(context.Background(), f, submitParams{agent: "claude", quiet: true}, pasteLine); err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.spinner != 0 {
		t.Fatalf("pasted while the agent still drew its spinner (%d reads left)", f.spinner)
	}
}

// An input box pierd cannot read: typed as before, the paste then Enter.
func TestSubmitTypesBlindIntoABoxItCannotRead(t *testing.T) {
	fastSubmit(t)
	f := &agentTerm{agent: "opencode", onEnter: always("nothing")}
	if _, err := submitPrompt(context.Background(), f, submitParams{agent: "opencode"}, pasteLine); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(f.sent, " "); got != "paste Enter" {
		t.Fatalf("sent %q", got)
	}
}

// A prompt pierd had to leave in the box comes out before the next one, and
// only that: the person's own words stay.
func TestClearLeftover(t *testing.T) {
	fastSubmit(t)
	left := signOf(pasteLine)
	f := &agentTerm{agent: "claude", box: []string{pasteLine}}
	if !clearLeftover(context.Background(), f, "claude", left) || len(f.box) != 0 {
		t.Fatalf("the leftover is still there: %q", f.box)
	}
	f = &agentTerm{agent: "claude", box: []string{"my own words"}}
	if !clearLeftover(context.Background(), f, "claude", left) || len(f.box) != 1 || f.count("C-u") != 0 {
		t.Fatalf("the person's words were cleared: %q %v", f.box, f.sent)
	}
	f = &agentTerm{agent: "claude", box: []string{pasteLine}, stuck: true}
	if clearLeftover(context.Background(), f, "claude", left) {
		t.Fatal("a leftover that stays was taken for cleared")
	}
}

// A send that typed and was not taken answers a retry with the same key the
// same way, instead of typing it again.
func TestARetryGetsTheAnswerOfTheSendItRepeats(t *testing.T) {
	b := &Box{}
	b.rememberTyped("shop-claude", "k1", &NotSubmittedError{Kept: true})
	b.rememberTyped("shop-claude", "k2", errors.New("tmux: no server")) // not kept: typed again
	var ns *NotSubmittedError
	if err := b.typedFailure("shop-claude", "k1"); !errors.As(err, &ns) || !ns.Kept {
		t.Fatalf("k1: %v", err)
	}
	if err := b.typedFailure("shop-claude", "k2"); err != nil {
		t.Fatalf("k2: %v", err)
	}
	if err := b.typedFailure("shop-claude", ""); err != nil {
		t.Fatalf("no key: %v", err)
	}
}

func TestSubmits(t *testing.T) {
	for _, c := range []struct {
		agent, text string
		enter, want bool
	}{
		{"claude", "fix it", true, true},
		{"codex", "fix it", true, true},
		{"claude", "fix it", false, false}, // a paste alone
		{"claude", "1", true, false},       // a key
		{"claude", "  \n", true, false},    // nothing to send
		{"opencode", "fix it", true, false},
		{"", "ls", true, false}, // a shell
	} {
		if got := submits(c.agent, c.text, c.enter); got != c.want {
			t.Errorf("submits(%q, %q, %v) = %v", c.agent, c.text, c.enter, got)
		}
	}
}

// A held prompt being typed keeps the session's next one waiting for it:
// two typed at once would be read as one.
func TestOneHeldPromptAtATimePerSession(t *testing.T) {
	s, dir := "shop-claude", "/srv/shop"
	tr, bus := ledger(t, Session{Name: s, Dir: dir, Agent: "claude"})
	hook(bus, "agent.ready", s, dir, "claude")
	for _, text := range []string{"one", "two"} {
		if _, err := tr.Queue(s, text, true, "client:phone", ""); err != nil {
			t.Fatal(err)
		}
	}
	if items := tr.nextDeliveries(); len(items) != 1 || items[0].Text != "one" {
		t.Fatalf("first deliveries %+v", items)
	}
	if items := tr.nextDeliveries(); len(items) != 0 {
		t.Fatalf("the second went while the first was being typed: %+v", items)
	}
	tr.delivered(s)
	if items := tr.nextDeliveries(); len(items) != 1 || items[0].Text != "two" {
		t.Fatalf("after the first: %+v", items)
	}
}

// A prompt is published once the agent took it, and its own hook can come
// first: the start the ledger took for a prompt typed at the terminal is
// the send's.
func TestASendKeepsTheStartItsHookGaveFirst(t *testing.T) {
	s, dir := "shop-claude", "/srv/shop"
	tr, bus := ledger(t, Session{Name: s, Dir: dir, Agent: "claude"})
	hook(bus, "agent.ready", s, dir, "claude")
	entered := time.Now().UTC()
	hook(bus, "agent.started", s, dir, "claude", "signal", "prompt")
	sent := bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{
		"name": s, "from": "client:phone", "idem_key": "k1", "entered": entered.Format(time.RFC3339Nano),
	}})
	got, ok := tr.ForSent(s, sent.Seq)
	if !ok || got.State != "running" || got.Origin != "client:phone" || got.IdemKey != "k1" {
		t.Fatalf("the send's turn = %+v %v", got, ok)
	}
	if all := tr.List(s, 10); len(all) != 1 {
		t.Fatalf("%d turns, want the one: %+v", len(all), all)
	}
	if again, ok := tr.ByIdem(s, "k1"); !ok || again.ID != got.ID {
		t.Fatalf("a retry finds %+v %v", again, ok)
	}
	hook(bus, "agent.finished", s, dir, "claude")
	if st := turnState(t, tr, got.ID); st != "finished" {
		t.Fatalf("the send's turn is %s after the agent's Stop", st)
	}

	// A held prompt delivered the same way takes the start's place.
	q, err := tr.Queue(s, "next", true, "client:phone", "k2")
	if err != nil {
		t.Fatal(err)
	}
	if items := tr.nextDeliveries(); len(items) != 1 || items[0].Turn != q.ID {
		t.Fatalf("deliveries %+v", items)
	}
	entered = time.Now().UTC()
	hook(bus, "agent.started", s, dir, "claude", "signal", "prompt")
	bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": s, "turn": q.ID, "when": "idle", "entered": entered.Format(time.RFC3339Nano)}})
	if st := turnState(t, tr, q.ID); st != "running" {
		t.Fatalf("the held prompt's turn is %s", st)
	}
	if all := tr.List(s, 10); len(all) != 2 {
		t.Fatalf("%d turns, want 2: %+v", len(all), all)
	}
}

// A turn the person started at the terminal before the send's Enter is
// theirs: the send gets a turn of its own.
func TestASendDoesNotTakeAnEarlierTerminalTurn(t *testing.T) {
	s, dir := "shop-claude", "/srv/shop"
	tr, bus := ledger(t, Session{Name: s, Dir: dir, Agent: "claude"})
	hook(bus, "agent.ready", s, dir, "claude")
	hook(bus, "agent.started", s, dir, "claude", "signal", "prompt")
	time.Sleep(2 * time.Millisecond)
	entered := time.Now().UTC()
	sent := bus.Publish(events.Event{Type: "session.sent", Data: map[string]any{"name": s, "from": "client:phone", "entered": entered.Format(time.RFC3339Nano)}})
	got, ok := tr.ForSent(s, sent.Seq)
	if !ok || got.ID != s+"#2" || got.State != "pending" {
		t.Fatalf("the send's turn = %+v %v", got, ok)
	}
}

// A caller that gives up waiting (the app bounds a send at 15 s) does not cut
// a submit between its paste and its Enter: the prompt still goes.
func TestASubmitOutlivesItsCaller(t *testing.T) {
	fastSubmit(t)
	// The caller leaves (at 50 ms) while pierd still looks for the box.
	boxShows, pasteShows = 300*time.Millisecond, 300*time.Millisecond
	s := testSessions(t)
	out := filepath.Join(t.TempDir(), "got")
	script := filepath.Join(t.TempDir(), "agent")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '"+out+"'; done\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Create(context.Background(), "outlives", "", t.TempDir(), script, nil); err != nil {
		t.Fatal(err)
	}
	b := &Box{Sessions: s}
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(50*time.Millisecond, cancel)
	if _, err := b.submitToAgent(ctx, "outlives", "claude", "run the tests", false); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "the prompt and its Enter", 5*time.Second, func() bool {
		got, _ := os.ReadFile(out)
		return strings.Contains(string(got), "run the tests")
	})
}
