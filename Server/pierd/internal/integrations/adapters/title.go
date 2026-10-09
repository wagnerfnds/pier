package adapters

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// TitleMax is how long a title made from a prompt may be, in characters.
const TitleMax = 48

// Title names a piece of work after its prompt: the first line with words
// in it, spaces collapsed, cut at a word near TitleMax characters with an
// ellipsis. It is all of a prompt pierd keeps: the rest never leaves the
// agent.
func Title(prompt string) string {
	line := ""
	for l := range strings.SplitSeq(prompt, "\n") {
		if l = strings.Join(strings.Fields(l), " "); l != "" {
			line = l
			break
		}
	}
	return Clip(line, TitleMax)
}

// Clip cuts s to at most n characters, at a word when there is one in the
// last third, and marks the cut with an ellipsis.
func Clip(s string, n int) string {
	s = strings.Join(strings.FieldsFunc(s, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	all := []rune(s)
	r := all[:n-1]
	cut := len(r)
	// A word that ends right at the cut is kept whole.
	for i := len(r) - 1; i >= (n*2)/3 && all[n-1] != ' '; i-- {
		if r[i] == ' ' {
			cut = i
			break
		}
	}
	return strings.TrimRight(string(r[:cut]), " .,;:-") + "…"
}
