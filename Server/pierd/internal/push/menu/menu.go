// Package menu finds the numbered permission menu on an agent's screen.
//
// A Go port of PierKit's MenuParser (Packages/PierKit/Sources/PierKit/Support/MenuParser.swift). Keep the regexes identical to the Swift source.
package menu

import (
	"regexp"
	"strings"
)

// Choice is a numbered option read from an agent's screen (`1. Yes`).
type Choice struct{ Key, Label string }

var option = regexp.MustCompile(`^\s*(?:[❯›>]\s*)?(\d)[.)]\s+(\S.*)$`)

// trimEnd is JavaScript's trimEnd (also drops a BOM).
func trimEnd(s string) string {
	return strings.TrimRightFunc(s, func(r rune) bool { return r == '\uFEFF' || isSpace(r) })
}

func isSpace(r rune) bool {
	return strings.ContainsRune(" \t\n\v\f\r\u0085      　", r) || (r >= ' ' && r <= ' ')
}

func isBlank(s string) bool { return strings.TrimFunc(s, isSpace) == "" }

// StripPanel cuts the side panel the box draws next to a wide pane (`agent text … │ panel text`): when most non-blank
// lines carry a `│` at one common column (past column 30), everything from that column on is dropped, and trailing
// blanks too. Idempotent; screens without a panel come back unchanged (apart from trailing whitespace).
func StripPanel(screen string) string {
	lines := strings.Split(screen, "\n")
	counts := map[int]int{}
	nonBlank := 0
	for _, l := range lines {
		if isBlank(l) {
			continue
		}
		nonBlank++
		r := []rune(l)
		for i := len(r) - 1; i >= 0; i-- {
			if r[i] == '│' {
				if i > 30 {
					counts[i]++
				}
				break
			}
		}
	}
	if nonBlank > 3 {
		col, n := -1, 0
		for c, k := range counts {
			if k > n || (k == n && c < col) {
				col, n = c, k
			}
		}
		if col >= 0 && float64(n)/float64(nonBlank) > 0.5 {
			for i, l := range lines {
				r := []rune(l)
				if len(r) > col && r[col] == '│' {
					lines[i] = trimEnd(string(r[:col]))
				}
			}
		}
	}
	return trimEnd(strings.Join(lines, "\n"))
}

var (
	formTabs   = regexp.MustCompile(`^\s*←\s+[☐☒]`)
	formBox    = regexp.MustCompile(`[☐☒]`)
	formSubmit = regexp.MustCompile(`✔\s*Submit`)
)

// QuestionForm: the screen's foot shows Claude Code's form of questions with steps (a tab row with ☐ and ✔ Submit).
func QuestionForm(screen string) bool {
	lines := strings.Split(StripPanel(screen), "\n")
	if len(lines) > 40 {
		lines = lines[len(lines)-40:]
	}
	for _, l := range lines {
		if formTabs.MatchString(l) || (formBox.MatchString(l) && formSubmit.MatchString(l)) {
			return true
		}
	}
	return false
}

// Choices are the numbered options an agent is asking about: the first of each digit within the last 14 lines; a real
// menu counts up from 1 and has 2+ options (max 4). A form of questions is not a menu.
func Choices(screen string) []Choice {
	if QuestionForm(screen) {
		return nil
	}
	lines := strings.Split(StripPanel(screen), "\n")
	if len(lines) > 14 {
		lines = lines[len(lines)-14:]
	}
	var out []Choice
	for _, l := range lines {
		m := option.FindStringSubmatch(l)
		if m == nil {
			continue
		}
		dup := false
		for _, c := range out {
			if c.Key == m[1] {
				dup = true
				break
			}
		}
		if !dup {
			out = append(out, Choice{Key: m[1], Label: strings.TrimFunc(m[2], isSpace)})
		}
	}
	if len(out) >= 2 && out[0].Key == "1" {
		if len(out) > 4 {
			out = out[:4]
		}
		return out
	}
	return nil
}

// ownRows are the rows a question's numbered list ends with that are the agent's, not choices ("4. Type something.",
// "5. Chat about this").
var ownRows = regexp.MustCompile(`(?i)^(type something|chat about this|other)\b`)

// OptionLabels is what the numbered menu on screen offers, in order and as the agent words it, without a question's
// own trailing rows: a plan approval's "Yes, approve plan" / "No, keep planning", a question's "Three tiers" / "One
// plan". nil when the screen shows no menu (a form of questions included).
func OptionLabels(screen string) []string {
	var out []string
	for _, c := range Choices(screen) {
		if ownRows.MatchString(c.Label) {
			continue
		}
		out = append(out, c.Label)
	}
	return out
}

var (
	alwaysRx = regexp.MustCompile(`(?i)don.t ask again|always|allow all|this session`)
	extraRx  = regexp.MustCompile(`(?i)^yes,?\s+(and\s+)?(allow\s+\w+\s+from|switch to|allow\b.*\b(project|directory|folder)\b)|this project\b`)
	allowRx  = regexp.MustCompile(`(?i)^(yes|allow|approve|proceed)\b`)
	denyRx   = regexp.MustCompile(`(?i)^(no|deny|reject)\b`)
)

// Actions is the raw classification of a menu: Allow / Always allow / Deny (nil when not offered).
type Actions struct{ Allow, Always, Deny *Choice }

func Classify(c []Choice) Actions {
	find := func(f func(Choice) bool) *Choice {
		for i := range c {
			if f(c[i]) {
				return &c[i]
			}
		}
		return nil
	}
	// "Don't ask again" wins; Claude's other Yes-extras stand in for it when it is not offered. An option worded as a
	// refusal ("No, and don't ask again") is never "Always allow", whatever else its label says.
	always := find(func(x Choice) bool { return alwaysRx.MatchString(x.Label) && !denyRx.MatchString(x.Label) })
	if always == nil {
		always = find(func(x Choice) bool { return extraRx.MatchString(x.Label) && !denyRx.MatchString(x.Label) })
	}
	allow := find(func(x Choice) bool {
		return (always == nil || x != *always) && !alwaysRx.MatchString(x.Label) && !extraRx.MatchString(x.Label) && allowRx.MatchString(x.Label)
	})
	deny := find(func(x Choice) bool { return denyRx.MatchString(x.Label) })
	return Actions{allow, always, deny}
}

// IsPermission is true when the menu has both an Allow and a Deny option (what the Allow/Deny buttons need).
func (a Actions) IsPermission() bool { return a.Allow != nil && a.Deny != nil }

// PermissionMenu is the menu on screen as Allow/Deny actions, or ok=false.
func PermissionMenu(screen string) (Actions, bool) {
	a := Classify(Choices(screen))
	return a, a.IsPermission()
}

var questionTools = regexp.MustCompile(`^(AskUserQuestion|request_user_input|ExitPlanMode)$`)

// IsQuestionTool: the ask's tool is a question or plan approval, not a permission (API.md 5.3).
func IsQuestionTool(tool string) bool { return tool == "" || questionTools.MatchString(tool) }
