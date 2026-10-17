package box

import (
	"context"
	"errors"
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
//  2. the box is read, the prompt pasted, and pierd waits for the box to
//     show all of it: its last words (the line the cursor is on), the
//     agent's own "[Pasted text #1]" for a long one, or, laid out in a way
//     pierd does not read word for word, more text than the box held, the
//     same over a few reads. No Enter before that: a paste that never shows
//     is taken out again and fails with not_submitted;
//  3. Enter, and pierd watches for it to go in: the agent's hooks say a
//     prompt started, or the box let go of it (two reads in a row, so a
//     frame drawn halfway does not count);
//  4. still in the box: one more Enter (after a quiet screen, unless the
//     screen already held still). Never a third, and never an Enter into a
//     box that is already empty (that could send it twice);
//  5. still there: the box is cleared (Ctrl-U, line by line) and the send
//     fails with not_submitted, saying whether the text stayed in the box
//     (kept), so the app gives it back to the person only when it did not.
//     Text pierd had to leave there is taken out before its next prompt to
//     the session, or that one would be sent with it.
//
// A submit, once it types, runs to its end even when the caller goes away
// (the app gives up on a send after 15 s, and asks again with the same
// key): a paste is never left without its Enter, and the answer waits for
// that same key (sendPrompt). An input box pierd cannot read (another agent,
// a layout it does not know) is typed into as before, the paste then Enter.

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
	pasteShows   = 1500 * time.Millisecond // a paste of up to 64 KB; a second more for every 64 KB after
	pasteMost    = 10 * time.Second
	boxShows     = 300 * time.Millisecond
	pastePoll    = 40 * time.Millisecond
	pasteSettle  = 50 * time.Millisecond
	submitWithin = 2 * time.Second
	submitPoll   = 60 * time.Millisecond
	clearPoll    = 60 * time.Millisecond
	clearLimit   = 1500 * time.Millisecond
	// submitBudget bounds a whole submit once it types, whoever waits on it.
	submitBudget = 30 * time.Second
)

// pasteWait is how long a paste of n bytes may take to show in the box.
func pasteWait(n int) time.Duration {
	return min(pasteShows+time.Duration(n/(64<<10))*time.Second, pasteMost)
}

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
// sent, and answers when its first Enter was pressed; a *NotSubmittedError
// says it was not sent.
func submitPrompt(ctx context.Context, t submitTerm, p submitParams, text string) (entered time.Time, err error) {
	sign := signOf(text)
	if p.quiet {
		waitQuiet(ctx, t, quietLimit)
	}
	before, err := readView(t, p.agent)
	if err != nil {
		return time.Time{}, err
	}
	if err := t.paste(text); err != nil {
		return time.Time{}, err
	}
	// 2. The box shows all of it.
	view, shown, readable, err := awaitPaste(ctx, t, p.agent, sign, before.box, pasteWait(len(text)))
	if err != nil {
		return time.Time{}, err
	}
	if !readable {
		// A box pierd cannot read: as before, the paste (a moment ago),
		// then Enter.
		return time.Now(), t.keys("Enter")
	}
	if !shown {
		// No Enter on what is not in the box; what of it may be there goes.
		return time.Time{}, notTaken(ctx, t, p.agent, before.box)
	}
	time.Sleep(pasteSettle)
	// 3 and 4: Enter, and once more if the box still holds it.
	still := false
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			if !still {
				waitQuiet(ctx, t, quietLimit)
			}
			v, err := readView(t, p.agent)
			if err != nil {
				return time.Time{}, err
			}
			if !v.found || !v.box.holds(sign, before.box) {
				// The box that held it let go of it since: the agent took
				// the Enter late. Another one could send it twice.
				return entered, nil
			}
			view = v
		}
		var lb ledgerState
		if p.ledger != nil {
			lb = p.ledger()
		}
		if entered.IsZero() {
			// The first Enter's: the agent's hooks can say it started after
			// either (turns.go, earlyStart).
			entered = time.Now()
		}
		if err := t.keys("Enter"); err != nil {
			return time.Time{}, err
		}
		var res enterResult
		res, view, still, err = afterEnter(ctx, t, p, sign, before.box, view, lb)
		if err != nil {
			return time.Time{}, err
		}
		if res == wentIn {
			return entered, nil
		}
	}
	// 5. Still in the box: take it out, so it is not sent later by surprise.
	return time.Time{}, &NotSubmittedError{Kept: !clearInput(ctx, t, p.agent)}
}

// awaitPaste waits, at most limit, for the box to show all of a paste with
// this sign. readable is false when no input box ever showed (none pierd
// can read, a moment after the paste).
func awaitPaste(ctx context.Context, t submitTerm, agent string, sign pasteSign, before inputBox, limit time.Duration) (view screenView, shown, readable bool, err error) {
	start := time.Now()
	grown, same := "", 0
	for {
		v, err := readView(t, agent)
		if err != nil {
			return view, false, readable, err
		}
		view = v
		readable = readable || v.found
		if v.found {
			if v.box.landed(sign, before) {
				return v, true, true, nil
			}
			// Laid out in a way pierd does not read word for word (not even
			// its first words show): more text than before, the same over
			// three reads. A paste whose first words show waits for its
			// last ones: it is still landing.
			switch {
			case !v.box.grewFrom(before) || more(letters(v.box.text), letters(before.text), sign.head):
				grown, same = "", 0
			case v.box.text == grown:
				if same++; same >= 2 {
					return v, true, true, nil
				}
			default:
				grown, same = v.box.text, 0
			}
		}
		since := time.Since(start)
		if since > limit || !readable && since > boxShows || ctx.Err() != nil {
			return view, false, readable, nil
		}
		time.Sleep(pastePoll)
	}
}

// notTaken answers for a paste that never showed in the box: nothing is
// pressed on it, and what of it may have landed is taken out. Kept says the
// box could not be seen without it afterwards.
func notTaken(ctx context.Context, t submitTerm, agent string, before inputBox) error {
	v, err := readView(t, agent)
	switch {
	case err != nil:
		return err
	case !v.found:
		return &NotSubmittedError{Kept: true} // what the box holds cannot be told
	case v.box.text == before.text:
		return &NotSubmittedError{} // as it was: nothing of the paste there
	}
	return &NotSubmittedError{Kept: !clearInput(ctx, t, agent)}
}

type enterResult int

const (
	wentIn  enterResult = iota // the agent took it
	stillIn                    // the box still holds it
)

// afterEnter watches, at most submitWithin, for the prompt to go in after an
// Enter: the agent's hooks say a prompt started, or the box let go of it
// (empty again, or given way to what the prompt opened, a command's menu)
// two reads in a row. still says the screen held still over the last reads,
// so the next Enter need not wait for it to.
func afterEnter(ctx context.Context, t submitTerm, p submitParams, sign pasteSign, before inputBox, prev screenView, lb ledgerState) (res enterResult, view screenView, still bool, err error) {
	end := time.Now().Add(submitWithin)
	view, res = prev, stillIn
	letGo, same := 0, 0
	for {
		time.Sleep(submitPoll)
		if p.ledger != nil {
			if now := p.ledger(); now.hooked && now.seq > lb.seq && now.state == "running" && lb.state != "running" {
				return wentIn, view, false, nil
			}
		}
		v, err := readView(t, p.agent)
		if err != nil {
			return stillIn, view, false, err
		}
		if v.plain == view.plain {
			same++
		} else {
			same = 0
		}
		view = v
		if v.found && v.box.holds(sign, before) {
			letGo = 0
			if prev.found && v.box.lines > prev.box.lines && same >= 1 {
				// A line more under the prompt, drawn and held: the Enter was
				// read as a new line, and nothing more will come of it.
				return stillIn, v, true, nil
			}
		} else if letGo++; letGo >= 2 {
			return wentIn, v, false, nil
		}
		if time.Now().After(end) || ctx.Err() != nil {
			return res, view, same >= 1, nil
		}
	}
}

// clearInput empties the agent's input box: Ctrl-U clears the line the
// cursor is on (the end of the text, after a paste), Backspace joins it to
// the line above, for at most clearLimit (a dozen lines; a long paste shows
// as one, the agent's "[Pasted text #1 +40 lines]"). It says whether the box
// ended up empty.
func clearInput(ctx context.Context, t submitTerm, agent string) bool {
	end := time.Now().Add(clearLimit)
	for round := 0; ctx.Err() == nil; round++ {
		v, err := readView(t, agent)
		if err != nil || !v.found {
			return false
		}
		if v.box.empty() {
			return true
		}
		if round >= 24 || time.Now().After(end) {
			return false
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

// clearLeftover takes out of the box a prompt pierd typed before and could
// not send (NotSubmittedError.Kept), ahead of a new one: typed after it, the
// new one would be sent with it. It says whether the box is free of it:
// empty, no longer showing it (sent or cleared at the terminal since), or
// cleared now.
func clearLeftover(ctx context.Context, t submitTerm, agent string, s pasteSign) bool {
	v, err := readView(t, agent)
	if err != nil || !v.found {
		return true // nothing to read: the submit itself goes as it can
	}
	if v.box.empty() || !v.box.shows(s) {
		return true
	}
	return clearInput(ctx, t, agent)
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
	return strings.TrimSpace(strings.ReplaceAll(b.text, " ", " ")) == ""
}

// pastedMark is the agents' stand-in for a long paste: Claude Code's
// "[Pasted text #1 +19 lines]", Codex's "[Pasted Content 1214 chars]".
var pastedMark = regexp.MustCompile(`\[Pasted (text #\d+|Content \d+)`)

// pasteSign is what finds a prompt in the box: the first and the last
// letters and digits of its words, lowercased (promptKeyLen of each; the
// box may show either end of a long one, its first line or the line its
// cursor is on).
type pasteSign struct {
	head, tail string
}

// promptKeyLen is how many letters and digits make each end of a sign:
// enough to tell it from anything else in the box, few enough to fit on one
// line of it in a narrow pane.
const promptKeyLen = 24

// signOf is a prompt's sign: letters and digits only, so a line the box
// wraps (mid-word, or at a space) still matches.
func signOf(text string) pasteSign {
	r := []rune(letters(text))
	head, tail := r, r
	if len(r) > promptKeyLen {
		head, tail = r[:promptKeyLen], r[len(r)-promptKeyLen:]
	}
	return pasteSign{string(head), string(tail)}
}

// more says now holds more of key than was did.
func more(now, was, key string) bool {
	return key != "" && strings.Count(now, key) > strings.Count(was, key)
}

// landed says the box shows all of a paste with this sign, beyond what it
// held before it: its last words, where the cursor is, or the agent's
// stand-in for it.
func (b inputBox) landed(s pasteSign, before inputBox) bool {
	if len(pastedMark.FindAllString(b.text, -1)) > len(pastedMark.FindAllString(before.text, -1)) {
		return true
	}
	return more(letters(b.text), letters(before.text), s.tail)
}

// grewFrom says the box holds more text than it did.
func (b inputBox) grewFrom(before inputBox) bool {
	return len([]rune(letters(b.text))) > len([]rune(letters(before.text))) ||
		len(strings.TrimSpace(b.text)) > len(strings.TrimSpace(before.text))
}

// holds says the box still holds (part of) a paste with this sign, beyond
// what it held before it: either end of its words, the agent's stand-in for
// it, or more text than before.
func (b inputBox) holds(s pasteSign, before inputBox) bool {
	now, was := letters(b.text), letters(before.text)
	return len(pastedMark.FindAllString(b.text, -1)) > len(pastedMark.FindAllString(before.text, -1)) ||
		more(now, was, s.head) || more(now, was, s.tail) || b.grewFrom(before)
}

// shows says the box shows a prompt with this sign: either end of its
// words, or the agents' stand-in for a long paste. Unlike holds, never
// just any text: the person's own is not taken for it.
func (b inputBox) shows(s pasteSign) bool {
	now := letters(b.text)
	return pastedMark.MatchString(b.text) || more(now, "", s.head) || more(now, "", s.tail)
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
		parts = append(parts, strings.TrimRight(s, "  "))
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
//
// It runs to its end once called, within submitBudget, whether or not the
// caller still waits (ctx's cancellation is not followed): a paste is never
// left without its Enter, nor an Enter without its check.
func (b *Box) submitToAgent(ctx context.Context, name, agent, text string, quiet bool) (time.Time, error) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), submitBudget)
	defer cancel()
	t := paneTerm{ctx: ctx, s: b.Sessions, name: name}
	if left, ok := b.leftovers.Load(name); ok {
		if !clearLeftover(ctx, t, agent, left.(pasteSign)) {
			return time.Time{}, &NotSubmittedError{Leftover: true}
		}
		b.leftovers.Delete(name)
	}
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
	text = trimBlankLines(text)
	entered, err := submitPrompt(ctx, t, p, text)
	if ns := (*NotSubmittedError)(nil); errors.As(err, &ns) && ns.Kept {
		// Still in the box: taken out before the next prompt (clearLeftover).
		b.leftovers.Store(name, signOf(text))
	}
	return entered, err
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
