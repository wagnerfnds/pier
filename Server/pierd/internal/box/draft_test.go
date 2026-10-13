package box

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

// The fixtures in testdata/draft are Claude Code 2.1's screens, captured
// with tmux capture-pane -p -J -e while it answered synthetic prompts
// (lighthouses, tide pools) in a scratch folder, at 100×40 and 64×30. The
// .final.md files are what it wrote to its transcript for those replies.

func screen(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "draft", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// words keeps letters and digits only: the screen and the transcript draw
// the same words with different marks.
func words(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, s)
}

// fromReply checks every line of a draft is the agent's own words: in its
// final reply, in order of lines, with nothing of Claude Code's chrome.
func fromReply(t *testing.T, d Draft, final string) {
	t.Helper()
	all := words(screen(t, final))
	for _, l := range strings.Split(d.Text, "\n") {
		if w := words(l); w != "" && !strings.Contains(all, w) {
			t.Errorf("draft line not in the reply: %q", l)
		}
	}
}

func TestDraftWhileWordsStream(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "streaming-list.ansi"))
	if d.Clipped || d.Status != nil {
		t.Fatalf("clipped %v, status %+v", d.Clipped, d.Status)
	}
	for _, want := range []string{
		"# How Lighthouses Work\n\nLighthouses are one of humanity's oldest navigation aids, serving as **beacons** for ships at sea. These tall structures",
		"\n\n- **The light source and optics**: A powerful lamp",
		"visible for 20+ miles\n- **The tower structure**: A tall building designed",
	} {
		if !strings.Contains(d.Text, want) {
			t.Errorf("missing %q in\n%s", want, d.Text)
		}
	}
	// The list item just begun ("-") and the tmux hint under the words
	// aren't part of it.
	if strings.HasSuffix(d.Text, "-") || strings.Contains(d.Text, "tmux") {
		t.Errorf("draft ends:\n%s", d.Text[len(d.Text)-80:])
	}
	fromReply(t, d, "lighthouses.final.md")
}

func TestDraftTallerThanTheScreenIsClipped(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "clipped-code.ansi"))
	if !d.Clipped || !strings.HasPrefix(d.Text, "These tall structures use light") {
		t.Fatalf("clipped %v:\n%s", d.Clipped, d.Text)
	}
	for _, want := range []string{
		"1. **Detection and activation**: At sunset",
		"operate `turn_light_on()` and `turn_light_off()` automatically",
		"automation logic:\n\n```\ndef lighthouse_control(light_level):\n    if light_level < 50:\n        return lamp_on()\n    else:\n        return lamp_off()\n```",
	} {
		if !strings.Contains(d.Text, want) {
			t.Errorf("missing %q in\n%s", want, d.Text)
		}
	}
	fromReply(t, d, "lighthouses.final.md")
}

func TestDraftOfAFinishedTurnHasNoStatus(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "finished.ansi"))
	if d.Status != nil || !d.Clipped || !strings.HasSuffix(d.Text, "protect maritime travelers during fog and storms.") {
		t.Fatalf("status %+v, clipped %v:\n%s", d.Status, d.Clipped, d.Text)
	}
	if strings.Contains(d.Text, "Cooked") || strings.Contains(d.Text, "Update installed") {
		t.Errorf("chrome in the draft:\n%s", d.Text)
	}
	fromReply(t, d, "lighthouses.final.md")
}

// A tool call is the last block: its ⏺ is grey, or blank between blinks,
// and its lines are grey. Nothing is drafted, and the words before it
// (already in the transcript) aren't either.
func TestNoDraftWhileAToolRuns(t *testing.T) {
	for _, f := range []string{"tool-reading.ansi", "tool-output.ansi", "tool-running.ansi"} {
		d := ParseClaudeDraft(screen(t, f))
		if d.Text != "" {
			t.Errorf("%s: drafted %q", f, d.Text)
		}
		if d.Status == nil || !strings.HasSuffix(d.Status.Word, "…") {
			t.Errorf("%s: status %+v", f, d.Status)
		}
	}
}

func TestDraftAfterToolCalls(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "text-after-tools.ansi"))
	want := "The ancient Pharos of Alexandria, one of the Seven Wonders of the Ancient World, stood over 300 feet tall and guided Mediterranean sailors for nearly 1,500 years. This magnificent lighthouse used mirrors and fire to reflect light across the harbor, demonstrating that civilizations have"
	if d.Text != want || d.Clipped {
		t.Fatalf("got %q (clipped %v)", d.Text, d.Clipped)
	}
	if d.Status == nil || *d.Status != (DraftStatus{Word: "Whirring…", Elapsed: "8s", Tokens: "678 tokens"}) {
		t.Errorf("status %+v", d.Status)
	}
}

func TestDraftTable(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "table.ansi"))
	want := "## Notable Lighthouses Around the World\n\n| Lighthouse Name | Location | Height (feet) |\n|---|---|---|\n| Bell Rock | Scotland | 115 |\n| Cape Byron | Australia | 189 |\n| Minot's Ledge | Massachusetts | 97 |\n\nThese remarkable structures"
	if !strings.Contains(d.Text, want) || !strings.HasPrefix(d.Text, "The ancient Pharos") {
		t.Fatalf("got\n%s", d.Text)
	}
	fromReply(t, d, "pharos.final.md")
}

// Thinking shows only in the status line; a block just begun ("⏺" alone)
// has no words yet.
func TestNoDraftWhileThinking(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "thinking.ansi"))
	if d.Text != "" || d.Status == nil || d.Status.Word != "Composing…" || d.Status.Elapsed != "5s" {
		t.Fatalf("got %+v %+v", d, d.Status)
	}
	if d := ParseClaudeDraft(screen(t, "block-starting.ansi")); d.Text != "" || d.Status == nil || d.Status.Tokens != "1.1k tokens" {
		t.Fatalf("block starting: %+v %+v", d, d.Status)
	}
}

// A dialog drawn over the reply ("Teach auto mode…") isn't the reply.
func TestDraftUnderADialog(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "dialog.ansi"))
	if strings.Contains(d.Text, "auto mode") || strings.Contains(d.Text, "Not now") || !strings.Contains(d.Text, "## Exploring Responsibly") {
		t.Fatalf("got\n%s", d.Text)
	}
	fromReply(t, d, "tidepools.final.md")
}

func TestDraftQuotesListsAndCode(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "quote-list.ansi"))
	for _, want := range []string{
		"5. Check local regulations, since some reserves forbid collecting entirely.",
		"A good rule of thumb is `leave-no-trace`. Whatever you carry in",
		"\n\n> \"Take only pictures, leave only footprints.\"\n\n",
	} {
		if !strings.Contains(d.Text, want) {
			t.Errorf("missing %q in\n%s", want, d.Text)
		}
	}
	fromReply(t, d, "tidepools.final.md")
}

func TestDraftLinks(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "link-quote.ansi"))
	for _, want := range []string{
		"Official predictions from [NOAA](https://example.com/tides) account for these cycles",
		"> \"Time and tide wait for no one.\"",
		"## Working Out Your Window\n\nTides change gradually",
	} {
		if !strings.Contains(d.Text, want) {
			t.Errorf("missing %q in\n%s", want, d.Text)
		}
	}
	fromReply(t, d, "tidechart.final.md")
}

// A code block still being written is fenced, so it draws as code.
func TestDraftOpenCodeBlock(t *testing.T) {
	d := ParseClaudeDraft(screen(t, "code-partial.ansi"))
	if !strings.HasSuffix(d.Text, "```\nconst low = new Date(\"2026-10-06T07:42:00\");\nconst high = new Date(\"2026-10-06T13:55:00\");\nconst hours = (high - low) / (1000 * 60 * 60);\nconsole.log(`Rising for ${hours.toFixed(1)} hours`);\nconsole.log(`Roughly ${(hours / 6).toFixed(2)} hours per\n```") {
		t.Fatalf("got\n%s", d.Text)
	}
	fromReply(t, d, "tidechart.final.md")
}

// On Linux Claude Code marks a block with ● instead of ⏺.
func TestDraftLinuxMarker(t *testing.T) {
	mac := ParseClaudeDraft(screen(t, "streaming-list.ansi"))
	linux := ParseClaudeDraft(strings.ReplaceAll(screen(t, "streaming-list.ansi"), "⏺", "●"))
	if linux.Text != mac.Text || linux.Text == "" {
		t.Fatalf("linux:\n%s\nmac:\n%s", linux.Text, mac.Text)
	}
}

// Older Claude Code drew a tool's output in the foreground, under "⎿".
func TestNoDraftUnderAPlainToolCall(t *testing.T) {
	const rule = "────────────────────────────────────────"
	s := strings.Join([]string{
		"\x1b[38;5;231m⏺\x1b[39m I'll list the files.",
		"",
		"\x1b[32m⏺\x1b[39m Bash(ls)",
		"  ⎿  README.md",
		"     main.go",
		"",
		"\x1b[38;5;174m✶\x1b[39m Whirring… (3s · ↓ 20 tokens)",
		rule,
		"❯ ",
		rule,
	}, "\n")
	if d := ParseClaudeDraft(s); d.Text != "" {
		t.Fatalf("drafted %q", d.Text)
	}
	// The same call drawn with its ⏺ in the foreground is still a call.
	if d := ParseClaudeDraft(strings.Replace(s, "\x1b[32m⏺", "⏺", 1)); d.Text != "" {
		t.Fatalf("drafted %q", d.Text)
	}
}

func TestNoDraftWithoutThePromptBox(t *testing.T) {
	if d := ParseClaudeDraft("⏺ Hello there\n  more words\n"); d.Text != "" || d.Status != nil {
		t.Fatalf("got %+v", d)
	}
}

func TestStyledLines(t *testing.T) {
	ls := parseStyled("\x1b[38;2;128;128;128mgrey words\x1b[0m\nplain \x1b]8;id=x;https://e.com\x1b\\link\x1b]8;;\x1b\\ end\n\x1b[1mbold\x1b[22m and \x1b[38;5;153mcode\x1b[39m")
	if !ls[0].chrome() {
		t.Errorf("a 24-bit grey is chrome")
	}
	if got := inline(ls[1].spans, false); got != "plain [link](https://e.com) end" {
		t.Errorf("link: %q", got)
	}
	if got := inline(ls[2].spans, false); got != "**bold** and `code`" {
		t.Errorf("styles: %q", got)
	}
	if got := inline([]span{{"a_b *c* [d]", style{fg: -1}}}, false); got != `a\_b \*c\* \[d\]` {
		t.Errorf("escaped: %q", got)
	}
}

// The status word is whatever Claude Code's spinnerVerbs say, in any
// language or case: a word it can't read must not lose the reply under it.
func TestDraftStatusInAnyWord(t *testing.T) {
	base := screen(t, "text-after-tools.ansi")
	want := ParseClaudeDraft(base).Text
	for _, w := range []string{"Pensando", "Ação", "Élaborant", "pondering", "Думаю", "思考中"} {
		d := ParseClaudeDraft(strings.Replace(base, "Whirring", w, 1))
		if d.Text != want || d.Status == nil || d.Status.Word != w+"…" || d.Status.Elapsed != "8s" {
			t.Errorf("%s: status %+v, text %q", w, d.Status, d.Text)
		}
	}
	// "✻ Cooked for 7s" once the turn ends, in any word too.
	finished := ParseClaudeDraft(screen(t, "finished.ansi")).Text
	done := strings.Replace(screen(t, "finished.ansi"), "Cooked for", "Ação for", 1)
	if d := ParseClaudeDraft(done); d.Status != nil || d.Text != finished || finished == "" {
		t.Errorf("a turn ended in other words: status %+v, text %q", d.Status, d.Text)
	}
}

// claudeScreen draws a reply block in Claude Code's way, under its prompt box.
func claudeScreen(first string, rest ...string) string {
	const rule = "────────────────────────────────────────"
	lines := append([]string{"\x1b[38;5;231m⏺\x1b[39m " + first}, rest...)
	return strings.Join(append(lines, "", rule, "❯ ", rule), "\n")
}

// A reply in CJK can hold lines of wide spaces ("　") alone or before a
// list item, and lists can be drawn with "•": none of it may crash the
// parser (it did, index out of range) or lose a character.
func TestDraftWideSpacesAndBullets(t *testing.T) {
	for _, tc := range []struct{ line, want string }{
		{"  　　", "日本語の説明です。\n\n続きの文章です。"},
		{"  　- 項目一", "日本語の説明です。\n- 項目一\n続きの文章です。"},
		{"   - item two", "日本語の説明です。\n - item two\n続きの文章です。"},
		{"  • First item", "日本語の説明です。\n- First item\n続きの文章です。"},
	} {
		var d Draft
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("%q: panic %v", tc.line, r)
				}
			}()
			d = ParseClaudeDraft(claudeScreen("日本語の説明です。", tc.line, "  続きの文章です。"))
		}()
		if d.Text != tc.want {
			t.Errorf("%q: got %q, want %q", tc.line, d.Text, tc.want)
		}
	}
}

// A draft past its limit keeps its end from a line's start: never half a
// character (sent as "�"), and it says it is clipped.
func TestDraftLongerThanItsLimit(t *testing.T) {
	var rest []string
	for i := 0; i < 1200; i++ {
		rest = append(rest, "  "+strings.Repeat("語", 11)+"x")
	}
	d := ParseClaudeDraft(claudeScreen(strings.Repeat("語", 10), rest...))
	if len(d.Text) > maxDraft || !utf8.ValidString(d.Text) || !strings.HasPrefix(d.Text, "語") || !d.Clipped {
		t.Fatalf("%d bytes, valid %v, clipped %v, starts %q", len(d.Text), utf8.ValidString(d.Text), d.Clipped, d.Text[:min(len(d.Text), 9)])
	}
}
