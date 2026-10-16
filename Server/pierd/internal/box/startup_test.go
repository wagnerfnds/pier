package box

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/integrations/adapters"
)

// The questions agents ask at start, as their screens show them, and
// screens that only mention the words.
func TestStartupQuestionsAreReadOffTheScreen(t *testing.T) {
	for _, c := range []struct {
		name          string
		screen        string
		asked, notify bool
	}{
		{"claude", `
 Accessing workspace:

 /w/shop-fix

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team).

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel
`, true, true},
		{"older claude", `
 Do you trust the files in this folder?

 /w/shop-fix

 ❯ 1. Yes, proceed
   2. No, exit

 Enter to confirm · Esc to exit
`, true, true},
		{"codex", `
> You are in /w/shop-fix

  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection.

› 1. Yes, continue
  2. No, quit

  Press enter to continue
`, true, false},
		{"words without the question's keys", "❯ grep -r 'Yes, I trust this folder' src\n  src/onboarding.ts:12: Yes, I trust this folder\n\n❯ \n  ? for shortcuts\n", false, false},
		{"its prompt", "❯ fix the flaky test\n\n✻ Working… (3s · esc to interrupt)\n", false, false},
	} {
		asked, notify := startupQuestion(c.screen)
		if asked != c.asked || notify != c.notify {
			t.Errorf("%s: asked %v notify %v, want %v %v", c.name, asked, notify, c.asked, c.notify)
		}
	}
}

// The menu of a startup question, in each agent's layout: the line its
// cursor is on and the line that says yes. Anything that is not one such
// menu is not read as one.
func TestTheTrustMenuIsReadOffTheScreen(t *testing.T) {
	foot := "\n\n Enter to confirm · Esc to cancel\n"
	for _, c := range []struct {
		name        string
		screen      string
		cursor, yes int
		ok          bool
	}{
		{"claude, on No", " Quick safety check: Is this a project you trust?\n\n ❯ No, exit\n   Yes, I trust this folder" + foot, 2, 3, true},
		{"claude, moved to Yes", " Quick safety check: Is this a project you trust?\n\n   No, exit\n ❯ Yes, I trust this folder" + foot, 3, 3, true},
		{"yes above the cursor", " Quick safety check\n\n   Yes, I trust this folder\n ❯ No, exit" + foot, 3, 2, true},
		{"older claude", " Do you trust the files in this folder?\n\n ❯ 1. Yes, proceed\n   2. No, exit" + foot, 2, 2, true},
		{"codex", "  Do you trust the contents of this directory?\n\n› 1. Yes, continue\n  2. No, quit\n\n  Press enter to continue\n", 2, 2, true},
		{"newer codex", "  Do you trust the contents of this directory?\n\n› 1. Trust and continue\n  2. Quit\n\n  Press enter to continue\n", 2, 2, true},
		{"two cursors", " ❯ No, exit\n ❯ Yes, I trust this folder" + foot, 0, 0, false},
		{"two yes rows", " ❯ No, exit\n   Yes, I trust this folder\n   Yes, always" + foot, 0, 0, false},
		{"no yes row", " ❯ No, exit\n   Maybe later" + foot, 0, 0, false},
		{"no cursor", "   No, exit\n   Yes, I trust this folder" + foot, 0, 0, false},
		{"yes far from the cursor", " ❯ No, exit\n\n\n\n\n Yes, I trust this folder" + foot, 0, 0, false},
		{"its prompt", "❯ fix the flaky test\n\n✻ Working… (3s · esc to interrupt)\n", 0, 0, false},
	} {
		cursor, yes, ok := trustMenu(c.screen)
		if ok != c.ok || ok && (cursor != c.cursor || yes != c.yes) {
			t.Errorf("%s: cursor %d yes %d ok %v, want %d %d %v", c.name, cursor, yes, ok, c.cursor, c.yes, c.ok)
		}
	}
}

// While a session's startup watch runs, its startup question is the
// watch's to answer or report: the screen poller, reading it first, would
// say the agent waits for someone, and a chat whose question pierd answers
// would flash "needs you". Once no watch runs (pierd restarted while it
// asked), the poller reads it as before.
func TestAStartupQuestionIsItsWatchsToRead(t *testing.T) {
	b := &Box{}
	question := " Quick safety check: Is this a project you trust?\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel\n"
	if b.startupOwns("s", question) {
		t.Fatal("no watch runs, yet the poller leaves the question alone")
	}
	st := &startup{changed: make(chan struct{})}
	startups.Store(startKey{b, "s"}, st)
	defer startups.Delete(startKey{b, "s"})
	if !b.startupOwns("s", question) {
		t.Fatal("the watch is starting, yet the poller reads its question")
	}
	if b.startupOwns("s", "❯ \n  ? for shortcuts\n") {
		t.Fatal("the poller leaves an agent at its prompt alone")
	}
	st.set(startReady)
	if b.startupOwns("s", question) {
		t.Fatal("the watch is over, yet the poller leaves the question alone")
	}
}

// A chat's agent asks whether to trust the folder pierd made for the chat:
// with nothing in it, pierd answers yes itself, moving the cursor and
// reading the screen as a person would, so the chat goes on to its first
// prompt with nobody told it waits (no push, no "needs you"); its start is
// over once its hooks speak, though its screen never holds still while it
// works on that prompt, so a send then is not kept waiting. A chat folder
// something was already put in is asked about, as a project's folder is.
func TestAChatTrustsItsOwnFolder(t *testing.T) {
	for _, c := range []struct {
		name                           string
		litter, spin, slow, drop, lose bool
	}{
		{name: "its own empty folder"},
		{name: "working at once", spin: true},
		{name: "a folder with files in it", litter: true},
		// Claude Code starting cold: its question stays drawn for seconds after the Enter, or the first Enter is lost.
		{name: "slow to take the answer", slow: true},
		{name: "missing the first Enter", drop: true},
		{name: "missing the first arrow key", lose: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
			out := t.TempDir()
			fake := trustingAgent(t, out)
			// claude on PATH is the stand-in, after writing a file into its folder, or with its spinner.
			bin := t.TempDir()
			script := "#!/bin/sh\n"
			if c.litter {
				script += "echo notes > notes.md\n"
			}
			if c.spin {
				script += "export SPIN=1\n"
			}
			if c.slow {
				script += "export SLOW=5\n"
			}
			if c.drop {
				script += "export DROP=1\n"
			}
			if c.lose {
				script += "export LOSE=1\n"
			}
			script += "exec " + shellQuote(fake) + " \"$@\"\n"
			if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			read := func(f string) string {
				b, _ := os.ReadFile(filepath.Join(out, f))
				return string(b)
			}

			turns := &Turns{}
			var bx *Box
			cl, bus := servedBox(t, func(b *Box) { b.Turns = turns; bx = b })
			turns.Attach(bus)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go turns.Run(ctx, bx)
			var mu sync.Mutex
			var waits []string
			stop := bus.Observe(func(e events.Event) {
				if e.Type == adapters.Waiting {
					mu.Lock()
					waits = append(waits, fmt.Sprint(e.Data["session"], " ", e.Data["reason"]))
					mu.Unlock()
				}
			})
			defer stop()
			told := func() []string {
				mu.Lock()
				defer mu.Unlock()
				return append([]string(nil), waits...)
			}

			var sess Session
			if st := call(t, cl, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude", Prompt: "plan a garden"}, &sess); st != 200 || sess.Turn == "" {
				t.Fatalf("start a chat: %d %+v", st, sess)
			}
			defer call(t, cl, "DELETE", "/v1/sessions/"+sess.Name, "", nil, nil)

			if c.litter {
				waitUntil(t, "the person to be asked", 10*time.Second, func() bool { return len(told()) > 0 })
				time.Sleep(time.Second)
				if read("trusted") != "" || read("exited") != "" || read("swallowed") != "" {
					t.Fatalf("pierd answered a folder with files in it: trusted %q exited %q typed %q", read("trusted"), read("exited"), read("swallowed"))
				}
				if got := told(); got[0] != sess.Name+" startup question" || bx.startingState(sess.Name) != startAsking {
					t.Fatalf("told %v, start state %d", got, bx.startingState(sess.Name))
				}
				return
			}
			waitUntil(t, "the agent to be trusted", 15*time.Second, func() bool { return read("trusted") != "" })
			if c.spin {
				time.Sleep(time.Second)
				if st := bx.startingState(sess.Name); st != startBooting {
					t.Fatalf("start state %d before its hooks spoke, its screen never still", st)
				}
				hook(bus, "agent.started", sess.Name, sess.Dir, "claude")
				waitUntil(t, "the start to end once its hooks speak", 2*time.Second, func() bool { return bx.startingState(sess.Name) == startReady })
			}
			waitUntil(t, "the start to end", 15*time.Second, func() bool { return bx.startingState(sess.Name) == startReady })
			if got := read("got"); got != "ran: plan a garden\n" {
				t.Fatalf("the agent got %q, want its first prompt", got)
			}
			if read("exited") != "" || read("swallowed") != "" {
				t.Fatalf("exited %q, typed into the question %q", read("exited"), read("swallowed"))
			}
			if got := told(); len(got) > 0 {
				t.Fatalf("told the person the chat waits: %v", got)
			}
			if tr, _ := turns.Get(sess.Turn); tr.State == "waiting" || len(tr.Waits) > 0 {
				t.Fatalf("the first turn waited: %+v", tr)
			}
		})
	}
}

// trustingAgent is a stand-in for Claude Code in a folder it hasn't seen:
// it keeps the prompt it was started with, asks whether to trust the
// folder, drops whatever is typed meanwhile (into out/swallowed), and
// exits on Enter unless Down moved its cursor to "Yes, I trust this
// folder" first (Up moves it back), redrawing the menu as Claude Code's own
// question does. Trusted, it runs its first prompt (out/got), says so
// (out/trusted), and reads prompts a line at a time (an empty one does
// nothing); with SPIN set, while a spinner runs on, as it does working on
// that prompt. SLOW keeps the question drawn that many seconds after it is
// answered; DROP loses the first Enter, LOSE the first arrow key.
func trustingAgent(t *testing.T, out string) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "claude")
	script := `#!/bin/sh
out='` + out + `'
stty raw -echo
yes=0 dropped=0 lost=0
menu() {
	printf '\033[2J\033[H Accessing workspace:\r\n\r\n Quick safety check: Is this a project you created or one you trust?\r\n\r\n'
	if [ $yes = 1 ]; then printf '   No, exit\r\n ❯ Yes, I trust this folder\r\n'; else printf ' ❯ No, exit\r\n   Yes, I trust this folder\r\n'; fi
	printf '\r\n Enter to confirm · Esc to cancel\r\n'
}
menu
esc=$(printf '\033'); cr=$(printf '\r')
while :; do
	c=$(dd bs=1 count=1 2>/dev/null)
	if [ "$c" = "$esc" ]; then
		s=$(dd bs=1 count=2 2>/dev/null)
		if [ -n "$LOSE" ] && [ $lost = 0 ]; then lost=1; continue; fi
		case "$s" in
		"[B") yes=1; menu; continue ;;
		"[A") yes=0; menu; continue ;;
		esac
		printf '%s%s' "$c" "$s" >> "$out/swallowed"
		continue
	fi
	if [ "$c" = "$cr" ]; then
		if [ -n "$DROP" ] && [ $dropped = 0 ]; then dropped=1; continue; fi
		[ $yes = 1 ] && break
		echo exited > "$out/exited"
		exit 1
	fi
	printf '%s' "$c" >> "$out/swallowed"
done
[ -n "$SLOW" ] && sleep "$SLOW"
stty sane
printf '\033[2J\033[H'
echo "ran: $1" >> "$out/got"
echo yes > "$out/trusted"
if [ -n "$SPIN" ]; then (i=0; while printf '\r✻ Working %s ' "$i"; do i=$((i+1)); sleep 0.1; done) & fi
printf '> '
while IFS= read -r line; do [ -n "$line" ] && echo "$line" >> "$out/got"; printf '> '; done
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// An agent started with a prompt, in a folder it hasn't trusted yet,
// stops at its trust question. Prompts sent meanwhile, even "now", are
// held rather than typed into the question (which would drop them, and
// whose Enter would answer "No, exit"). Once the person answers, the agent
// runs the prompt it was started with, then the held ones.
func TestPromptsWaitForTheTrustQuestion(t *testing.T) {
	turns := &Turns{}
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { b.Turns = turns; bx = b })
	turns.Attach(bus)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go turns.Run(ctx, bx)
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "shop", "path": repo}, nil)
	out := t.TempDir()
	fake := trustingAgent(t, out)
	if st := call(t, c, "PUT", "/v1/locations/shop/config", "", map[string]any{"local": RepoConfig{Agents: []AgentPreset{{ID: "claude", Name: "Claude Code", Command: fake}}}}, nil); st != 200 {
		t.Fatalf("config = %d", st)
	}
	read := func(f string) string {
		b, _ := os.ReadFile(filepath.Join(out, f))
		return string(b)
	}

	var sess Session
	if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Location: "shop", Name: "fix", Agent: "claude", Prompt: "fix the flaky test"}, &sess); st != 200 {
		t.Fatalf("start = %d %+v", st, sess)
	}
	if sess.Turn != "fix#1" {
		t.Fatalf("the first prompt is no turn: %+v", sess)
	}
	// Sent at once, before the question even shows: held, not typed.
	var early SendResult
	if st := call(t, c, "POST", "/v1/sessions/fix/send", "", SendRequest{Text: "then update the changelog", When: "now"}, &early); st != 200 || !early.Queued {
		t.Fatalf("early send = %d %+v", st, early)
	}
	waitUntil(t, "the trust question", 10*time.Second, func() bool {
		st, _ := turns.State("fix")
		return st.State == "waiting" && bx.startingState("fix") == startAsking
	})
	var idle SendResult
	if st := call(t, c, "POST", "/v1/sessions/fix/send", "", SendRequest{Text: "and add a test", When: "idle"}, &idle); st != 200 || !idle.Queued {
		t.Fatalf("idle send = %d %+v", st, idle)
	}
	// Text for the question itself (forced, as the chat answers a question
	// with a word, or a key and Enter) is no answer it takes: refused.
	for _, req := range []SendRequest{{Text: "Yes", When: "now", Force: true}, {Text: "1", When: "now"}} {
		var refused map[string]string
		if st := call(t, c, "POST", "/v1/sessions/fix/send", "", req, &refused); st != 409 || !strings.Contains(refused["error"], "trust this folder") || refused["code"] != CodeAgentWaiting {
			t.Fatalf("send %+v = %d %v", req, st, refused)
		}
	}
	var refused map[string]string
	// Nor is a held prompt typed now.
	path := "/v1/sessions/fix/queue/" + strings.ReplaceAll(early.Turn, "#", "%23") + "/send"
	if st := call(t, c, "POST", path, "", map[string]bool{"force": true}, &refused); st != 409 {
		t.Fatalf("send a held prompt now = %d %v", st, refused)
	}
	time.Sleep(time.Second) // the inbox and the screen poller had their chance
	if s := read("swallowed"); s != "" || read("exited") != "" {
		t.Fatalf("typed into the question: %q (exited %q)", s, read("exited"))
	}
	if got, _ := turns.Get("fix#1"); got.State != "waiting" {
		t.Fatalf("the first turn while it asks = %+v", got)
	}

	// The person answers in its screen.
	for _, k := range []string{"Down", "Enter"} {
		if out, err := bx.Sessions.tmux(ctx, "send-keys", "-t", "=fix:", k); err != nil {
			t.Fatal(tmuxError("send-keys", out, err))
		}
		time.Sleep(100 * time.Millisecond)
	}
	waitUntil(t, "the agent to be trusted", 10*time.Second, func() bool { return read("trusted") != "" })
	// Its hooks run now: it reads the prompt it was started with, and ends.
	hook(bus, "agent.ready", "fix", sess.Dir, "claude")
	hook(bus, "agent.started", "fix", sess.Dir, "claude", "signal", "prompt")
	hook(bus, "agent.finished", "fix", sess.Dir, "claude")
	// Then the held prompts, one turn each.
	waitUntil(t, "the first held prompt", 15*time.Second, func() bool {
		tr, _ := turns.Get(early.Turn)
		return strings.Contains(read("got"), "then update the changelog") && tr.State == "pending"
	})
	hook(bus, "agent.started", "fix", sess.Dir, "claude", "signal", "prompt")
	hook(bus, "agent.finished", "fix", sess.Dir, "claude")
	waitUntil(t, "the second held prompt", 15*time.Second, func() bool {
		return strings.Contains(read("got"), "and add a test")
	})
	want := "ran: fix the flaky test\nthen update the changelog\nand add a test\n"
	if got := read("got"); got != want {
		t.Fatalf("the agent got %q, want %q", got, want)
	}
	if got, _ := turns.Get("fix#1"); got.State != "finished" || len(got.Waits) == 0 || got.Waits[0].Reason != "startup question" {
		t.Fatalf("the first turn = %+v", got)
	}
}
