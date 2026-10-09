package adapters

import (
	"regexp"
	"strings"
)

// Screen is the fallback for sessions whose agent has no hooks: pierd reads
// the pane every couple of seconds while a turn is open. Output that keeps
// changing is working; an approval question is waiting; a screen that has
// not changed for a while is a finished turn.
var Screen = register(&Adapter{
	Name: "screen",
	Caps: Caps{Ready: true, Started: true, Waiting: true, Finished: true, Via: "screen"},
	Translate: func(string, Payload) (string, map[string]any, bool) {
		return "", nil, false
	},
})

// approval matches the questions agents stop at for a person.
var approval = regexp.MustCompile(`(?i)(do you want to (proceed|make this edit|allow)|allow (once|always)|\(y/n\)|\[y/n\]|approve\b.*\?|yes, (and )?(allow|proceed|i trust)|trust (this folder|the files)|press enter to confirm|waiting for (your )?(approval|permission))`)

// ScreenState reads the bottom of a pane: "waiting" when it shows an
// approval question, "" otherwise. Quiescence is the caller's to judge.
func ScreenState(screen string) string {
	lines := strings.Split(strings.TrimRight(screen, "\n "), "\n")
	if len(lines) > 15 {
		lines = lines[len(lines)-15:]
	}
	if approval.MatchString(strings.Join(lines, "\n")) {
		return "waiting"
	}
	return ""
}
