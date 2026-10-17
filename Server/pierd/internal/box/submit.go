package box

import (
	"context"
	"regexp"
	"strings"
	"time"
	"unicode"
)

// Typing a prompt into an agent is a paste and an Enter, and the Enter is
// only a send when the agent's input box has taken the whole paste first:
// an Enter that reaches it while it still reads the paste (at the end of a
// turn, when the agent redraws everything, which is exactly when held
// prompts are typed) lands inside the paste as a new line, and the prompt
// sits in the box, unsent, while the app shows it on its way.
//
// So a prompt for Claude Code or Codex is submitted, not just typed:
//
//  1. a held prompt (and one typed while the agent shows it is working)
//     waits for a quiet screen: two reads quietGap apart the same, at most
//     quietLimit;
//  2. it is pasted, and pierd waits for the input box to show it (its first
//     words, or the agent's own "[Pasted text #1]" for a long one);
//  3. Enter, and pierd watches for it to go in: the agent's hooks say a
//     prompt started, or the box let go of it;
//  4. not gone and still in the box: one more Enter, after a quiet screen.
//     Never a third, and never an Enter into a box that is already empty
//     (that could send it twice);
//  5. still there: the box is cleared (Ctrl-U, line by line) and the send
//     fails with not_submitted, saying whether the text stayed in the box
//     (kept), so the app gives it back to the person only when it did not.
//
// An input box pierd cannot read (another agent, a layout it does not
// know) is typed into as before, the paste then Enter.

// submitTerm is the terminal a prompt is submitted into: the agent's tmux
// pane, or a model of it in tests.
type submitTerm interface {
	paste(text string) error
	keys(k ...string) error
	// screen is the pane as capture-pane -p -J -e gives it, with its styles.
	screen() (string, error)
}

// The steps' clocks; tests shorten them.
var (
	quietGap     = 120 * time.Millisecond
	quietLimit   = 1500 * time.Millisecond
	pasteShows   = 1500 * time.Millisecond
	boxShows     = 300 * time.Millisecond
	pastePoll    = 40 * time.Millisecond
	pasteSettle  = 50 * time.Millisecond
	submitWithin = 2500 * time.Millisecond
	submitPoll   = 60 * time.Millisecond
	clearPoll    = 60 * time.Millisecond
)

// ledgerState is what the turn ledger says of the session: its state's Seq,
// the state, and whether the agent's own hooks report there.
type ledgerState struct {
	seq    int64
	state  string
	hooked bool
}

// submitParams is what a submit knows besides the screen.
type submitParams struct {
	// agent is how the input box is read: "claude", "codex".
	agent string
	// quiet waits for a quiet screen before the paste.
	quiet bool
	// ledger reads the turn ledger; nil without one.
	ledger func() ledgerState
}

// submitPrompt types text into an agent's input box and makes sure it is
// sent, and answers when the Enter that sent it was pressed; a
// *NotSubmittedError says it was not sent.
func submitPrompt(ctx context.Context, t submitTerm, p submitParams, text string) (entered time.Time, err error) {
	key := promptKey(text)
	if p.quiet {
		waitQuiet(ctx, t, quietLimit)
	}
	if err := t.paste(text); err != nil {
		return time.Time{}, err
	}
	// 2. The box shows it.
	var view screenView
	shown, readable := false, false
	start := time.Now()
	for {
		v, err := readView(t, p.agent)
		if err != nil {
			return time.Time{}, err
		}
		view = v
		readable = readable || v.found
		if v.found && v.box.holds(key) {
			shown = true
			break
		}
		// No box at all a moment after the paste: not one pierd can read.
		if since := time.Since(start); since > pasteShows || !readable && since > boxShows || ctx.Err() != nil {
			break
		}
		time.Sleep(pastePoll)
	}
	if !readable {
		// A box pierd cannot read: as before, the paste (a moment ago), then
		// Enter.
		return time.Now(), t.keys("Enter")
	}
	time.Sleep(pasteSettle)
	// 3 and 4: Enter, and once more if the box still holds it.
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			waitQuiet(ctx, t, quietLimit)
			v, err := readView(t, p.agent)
			if err != nil {
				return time.Time{}, err
			}
			if !v.found || !v.box.holds(key) {
				// The box that held it let go of it since: the agent took
				// the Enter late. Another one could send it twice.
				return entered, nil
			}
			view, shown = v, true
		}
		var before ledgerState
		if p.ledger != nil {
			before = p.ledger()
		}
		entered = time.Now()
		if err := t.keys("Enter"); err != nil {
			return time.Time{}, err
		}
		res, last, err := afterEnter(ctx, t, p, key, shown, before, view)
		if err != nil {
			return time.Time{}, err
		}
		view = last
		switch res {
		case wentIn:
			return entered, nil
		case notShown:
			// Never in the box, and not in it now: nothing to press Enter on again.
			return time.Time{}, &NotSubmittedError{}
		}
	}
	// 5. Still in the box: take it out, so it is not sent later by surprise.
	return time.Time{}, &NotSubmittedError{Kept: !clearInput(ctx, t, p.agent)}
}

type enterResult int

const (
	wentIn   enterResult = iota // the agent took it
	stillIn                     // the box still holds it
	notShown                    // it never showed in the box, and nothing says it went
)

// afterEnter watches, at most submitWithin, for the prompt to go in after an
// Enter: the agent's hooks say a prompt started, or the box that showed it
// let go of it (an empty box, or the box gave way to what the prompt opened,
// a command's menu), or, for a prompt the box never showed, the prompt
// appears in the conversation above it.
func afterEnter(ctx context.Context, t submitTerm, p submitParams, key string, shown bool, before ledgerState, prev screenView) (enterResult, screenView, error) {
	end := time.Now().Add(submitWithin)
	res := stillIn
	if !shown {
		res = notShown
	}
	view := prev
	gone := 0
	for {
		time.Sleep(submitPoll)
		if p.ledger != nil {
			if now := p.ledger(); now.hooked && now.seq > before.seq && now.state == "running" && before.state != "running" {
				return wentIn, view, nil
			}
		}
		v, err := readView(t, p.agent)
		if err != nil {
			return 0, view, err
		}
		view = v
		switch {
		case v.found && v.box.holds(key):
			res, gone = stillIn, 0
			if prev.found && v.box.lines > prev.box.lines {
				// A line more under the prompt: the Enter was read as a new
				// line, and nothing more will come of it.
				return stillIn, v, nil
			}
		case !shown:
			if strings.Count(v.outside, key) > strings.Count(prev.outside, key) {
				return wentIn, v, nil
			}
			res = notShown
		case v.found:
			return wentIn, v, nil
		case v.plain != prev.plain:
			// No box: something the prompt opened is drawn over it. Twice
			// in a row, so a frame drawn halfway does not count.
			if gone++; gone >= 2 {
				return wentIn, v, nil
			}
		}
		if time.Now().After(end) || ctx.Err() != nil {
			return res, view, nil
		}
	}
}

// clearInput empties the agent's input box: Ctrl-U clears the line the
// cursor is on (the end of the text, after a paste), Backspace joins it to
// the line above, a dozen lines at most (a longer paste shows as one line,
// the agent's "[Pasted text #1 +40 lines]"). It says whether the box ended
// up empty.
func clearInput(ctx context.Context, t submitTerm, agent string) bool {
	for round := 0; round < 24 && ctx.Err() == nil; round++ {
		v, err := readView(t, agent)
		if err != nil || !v.found {
			return false
		}
		if v.box.empty() {
			return true
		}
		key := "C-u"
		if round%2 == 1 {
			key = "BSpace"
		}
		if t.keys(key) != nil {
			return false
		}
		time.Sleep(clearPoll)
	}
	return false
}

// waitQuiet waits, at most limit, for the screen to hold still: two reads
// quietGap apart the same.
func waitQuiet(ctx context.Context, t submitTerm, limit time.Duration) {
	last := ""
	for end := time.Now().Add(limit); ctx.Err() == nil; {
		raw, err := t.screen()
		if err != nil {
			return
		}
		plain := screenText(raw)
		if plain == last {
			return
		}
		last = plain
		if time.Now().After(end) {
			return
		}
		time.Sleep(quietGap)
	}
}

// screenText is a styled capture's text alone.
func screenText(raw string) string { return plainOf(parseStyled(raw)) }

// screenView is one read of the agent's screen: its input box, when one
// shows, and the text of everything else, as letters (see letters).
type screenView struct {
	found   bool
	box     inputBox
	outside string
	plain   string
}

func readView(t submitTerm, agent string) (screenView, error) {
	raw, err := t.screen()
	if err != nil {
		return screenView{}, err
	}
	lines := parseStyled(raw)
	box, from, to, found := readInput(agent, lines)
	v := screenView{found: found, box: box, plain: plainOf(lines)}
	if found {
		v.outside = letters(plainOf(lines[:from]) + plainOf(lines[to:]))
	} else {
		v.outside = letters(v.plain)
	}
	return v, nil
}

// inputBox is what an agent's input box holds: its text (what the person
// typed or pasted, never the dim placeholder it shows when empty) and its
// lines.
type inputBox struct {
	text  string
	lines int
}

func (b inputBox) empty() bool {
	return strings.TrimSpace(strings.ReplaceAll(b.text, "\u00a0", " ")) == ""
}

// pastedMark is the agents' stand-in for a long paste: Claude Code's
// "[Pasted text #1 +19 lines]", Codex's "[Pasted Content 1214 chars]".
var pastedMark = regexp.MustCompile(`\[Pasted (text #\d+|Content \d+)`)

// holds says the box holds a prompt with this key (promptKey): its first
// words in the box, or the agent's stand-in for a long paste. A prompt with
// no letters at all counts as held while the box holds anything.
func (b inputBox) holds(key string) bool {
	if pastedMark.MatchString(b.text) {
		return true
	}
	if key == "" {
		return !b.empty()
	}
	return strings.Contains(letters(b.text), key)
}

// promptKeyLen is how many letters and digits of a prompt find it in the
// box: enough to tell it from anything else there, few enough to fit on the
// box's first line in a narrow pane.
const promptKeyLen = 24

// promptKey is the first letters and digits of a prompt, lowercased:
// whitespace and marks left out, so a line the box wraps (mid-word, or at a
// space) still matches.
func promptKey(text string) string {
	k := letters(text)
	r := []rune(k)
	if len(r) > promptKeyLen {
		r = r[:promptKeyLen]
	}
	return string(r)
}

var (
	// Codex's composer: "› " at the margin, bold (its past prompts above are
	// drawn dim, a menu's cursor reversed).
	codexPrompt = regexp.MustCompile(`^›(\s|\x{a0}|$)`)
	// What the box's first line starts with, taken off its text.
	promptPrefix = regexp.MustCompile(`^\s*[❯>›](\s|\x{a0})?`)
)

// readInput finds an agent's input box at the foot of its screen: its
// contents and the lines it takes (from, to). ok is false where pierd does
// not know how the agent draws it.
//
// Claude Code 2.1: a rule at the margin, the prompt line under it ("❯ "),
// the box's other lines indented, and a rule closing it; hints and the
// mode under that. Codex 0.16: the composer is the last "› " line at the
// margin not drawn dim, and the lines under it indented, up to a blank line
// (its status lines follow).
func readInput(agent string, lines []styledLine) (box inputBox, from, to int, ok bool) {
	switch agent {
	case "claude":
		for i := len(lines) - 2; i >= 0; i-- {
			if !lines[i].rule() || lines[i].indent() != 0 || !promptLine.MatchString(lines[i+1].plain) {
				continue
			}
			for j := i + 2; j < len(lines); j++ {
				if lines[j].rule() {
					return boxOf(lines[i+1 : j]), i + 1, j, true
				}
			}
			return inputBox{}, 0, 0, false
		}
	case "codex":
		for i := len(lines) - 1; i >= 0; i-- {
			l := lines[i]
			if !codexPrompt.MatchString(l.plain) || len(l.spans) == 0 || firstVisible(l).st.dim {
				continue
			}
			j := i + 1
			for j < len(lines) && !lines[j].blank() && strings.HasPrefix(lines[j].plain, "  ") {
				j++
			}
			return boxOf(lines[i:j]), i, j, true
		}
	}
	return inputBox{}, 0, 0, false
}

// firstVisible is a line's first span with something drawn in it.
func firstVisible(l styledLine) span {
	for _, sp := range l.spans {
		if strings.TrimSpace(sp.text) != "" {
			return sp
		}
	}
	return span{}
}

// boxOf reads a box's lines: what is not dim, the prompt taken off the
// first line.
func boxOf(lines []styledLine) inputBox {
	var parts []string
	for i, l := range lines {
		var b strings.Builder
		for _, sp := range l.spans {
			if !sp.st.dim {
				b.WriteString(sp.text)
			}
		}
		s := b.String()
		if i == 0 {
			s = promptPrefix.ReplaceAllString(s, "")
		}
		parts = append(parts, strings.TrimRight(s, " \u00a0"))
	}
	return inputBox{text: strings.Join(parts, "\n"), lines: len(lines)}
}

// trimBlankLines takes the blank lines off both ends of a prompt (the
// agents do too), keeping the first line's indentation: the box then shows
// the prompt's first words on its first line.
func trimBlankLines(text string) string {
	text = strings.TrimRightFunc(text, unicode.IsSpace)
	for {
		line, rest, ok := strings.Cut(text, "\n")
		if !ok || strings.TrimSpace(line) != "" {
			return text
		}
		text = rest
	}
}

// submits says whether text sent to a session running agent goes through
// submitPrompt: a prompt (words, then Enter) for an agent whose input box
// pierd can read. Anything else is typed as it always was.
func submits(agent, text string, enter bool) bool {
	return enter && (agent == "claude" || agent == "codex") && strings.TrimSpace(text) != "" && !isKey(text)
}

// submitToAgent types a prompt into a session's agent and makes sure it
// went in (submitPrompt). quiet waits for a quiet screen first, as a
// prompt typed while the agent shows it is working always does. It answers
// when the Enter that sent it was pressed.
func (b *Box) submitToAgent(ctx context.Context, name, agent, text string, quiet bool) (time.Time, error) {
	t := paneTerm{ctx: ctx, s: b.Sessions, name: name}
	if !quiet {
		if raw, err := t.screen(); err == nil && working.MatchString(lastLines(screenText(raw), 14)) {
			quiet = true
		}
	}
	p := submitParams{agent: agent, quiet: quiet}
	if b.Turns != nil {
		p.ledger = func() ledgerState {
			st, _ := b.Turns.State(name)
			return ledgerState{seq: st.Seq, state: st.State, hooked: b.hooked(name)}
		}
	}
	return submitPrompt(ctx, t, p, trimBlankLines(text))
}

// paneTerm is a session's tmux pane, as submitPrompt reads and types into it.
type paneTerm struct {
	ctx  context.Context
	s    *Sessions
	name string
}

func (p paneTerm) paste(text string) error { return p.s.paste(p.ctx, p.name, text) }

func (p paneTerm) keys(k ...string) error {
	for _, key := range k {
		if out, err := p.s.tmux(p.ctx, "send-keys", "-t", "="+p.name+":", key); err != nil {
			return tmuxSendError("send-keys", out, err)
		}
	}
	return nil
}

func (p paneTerm) screen() (string, error) {
	out, err := p.s.tmux(p.ctx, "capture-pane", "-p", "-J", "-e", "-t", "="+p.name+":")
	if err != nil {
		return "", tmuxSendError("capture-pane", out, err)
	}
	return string(out), nil
}
