package box

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// trustingAgent is a stand-in for Claude Code in a folder it hasn't seen:
// it keeps the prompt it was started with, asks whether to trust the
// folder, drops whatever is typed meanwhile (into out/swallowed), and
// exits on Enter unless Down picked "Yes, I trust this folder" first, as
// Claude Code's own question does. Trusted, it runs its first prompt
// (out/got), says so (out/trusted), and reads prompts a line at a time.
func trustingAgent(t *testing.T, out string) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "claude")
	script := `#!/bin/sh
out='` + out + `'
stty raw -echo
printf ' Accessing workspace:\r\n\r\n Quick safety check: Is this a project you created or one you trust?\r\n\r\n ❯ No, exit\r\n   Yes, I trust this folder\r\n\r\n Enter to confirm · Esc to cancel\r\n'
esc=$(printf '\033'); cr=$(printf '\r'); yes=0
while :; do
	c=$(dd bs=1 count=1 2>/dev/null)
	if [ "$c" = "$esc" ]; then
		s=$(dd bs=1 count=2 2>/dev/null)
		if [ "$s" = "[B" ]; then yes=1; continue; fi
		printf '%s%s' "$c" "$s" >> "$out/swallowed"
		continue
	fi
	if [ "$c" = "$cr" ]; then
		[ $yes = 1 ] && break
		echo exited > "$out/exited"
		exit 1
	fi
	printf '%s' "$c" >> "$out/swallowed"
done
stty sane
printf '\033[2J\033[H'
echo "ran: $1" >> "$out/got"
echo yes > "$out/trusted"
printf '> '
while IFS= read -r line; do echo "$line" >> "$out/got"; printf '> '; done
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
