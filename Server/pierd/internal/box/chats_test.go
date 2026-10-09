package box

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// chatAgent puts a stand-in for claude on PATH that writes where it runs,
// the session it was told it is and its arguments to a file in out (one per
// session), then waits, spending no tokens.
func chatAgent(t *testing.T) (out string) {
	t.Helper()
	bin, out := t.TempDir(), t.TempDir()
	script := "#!/bin/sh\nprintf '%s\\n%s\\n%s' \"$PWD\" \"$PIER_SESSION\" \"$*\" > " + shellQuote(out) + "/\"$PIER_SESSION\".tmp && mv " +
		shellQuote(out) + "/\"$PIER_SESSION\".tmp " + shellQuote(out) + "/\"$PIER_SESSION\"\nexec sleep 60\n"
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	return out
}

// seen is what the stand-in agent of session name wrote: its folder, its
// PIER_SESSION and its arguments.
func seen(t *testing.T, out, name string) []string {
	t.Helper()
	var got []byte
	waitUntil(t, name+"'s agent to start", 10*time.Second, func() bool {
		var err error
		got, err = os.ReadFile(filepath.Join(out, name))
		return err == nil
	})
	return strings.SplitN(string(got), "\n", 3)
}

// A chat is an agent in an empty folder of its own under ~/pier/chats,
// never the home folder: tied to no project, told its session like any
// other, and listed as a chat.
func TestAChatRunsItsAgentInAFolderOfItsOwn(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	out := chatAgent(t)
	c, _ := servedBox(t)

	var a, b Session
	if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude", Prompt: "plan a garden", Model: "opus", Effort: "high"}, &a); st != 200 {
		t.Fatalf("start a chat: %d", st)
	}
	defer call(t, c, "DELETE", "/v1/sessions/"+a.Name, "", nil, nil)
	if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude"}, &b); st != 200 {
		t.Fatalf("start another chat: %d", st)
	}
	defer call(t, c, "DELETE", "/v1/sessions/"+b.Name, "", nil, nil)

	root := filepath.Join(home, "pier", "chats")
	if !a.Chat || a.Location != "" || a.Agent != "claude" || a.Dir != filepath.Join(root, a.Name) || !strings.HasPrefix(a.Name, "chat-claude-") {
		t.Fatalf("chat = %+v, want an agent in %s/<name> with no location", a, root)
	}
	if a.Title != "plan a garden" {
		t.Fatalf("title = %q, want the prompt's", a.Title)
	}
	if !b.Chat || b.Dir == a.Dir || filepath.Dir(b.Dir) != root {
		t.Fatalf("a second chat shares or misses its folder: %s and %s", a.Dir, b.Dir)
	}
	if info, err := os.Stat(a.Dir); err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("chat folder: %v %v", info, err)
	}
	got := seen(t, out, a.Name)
	if dir, _ := filepath.EvalSymlinks(a.Dir); got[0] != a.Dir && got[0] != dir {
		t.Errorf("the agent runs in %q, want %q", got[0], a.Dir)
	}
	if got[1] != a.Name {
		t.Errorf("PIER_SESSION = %q, want %q", got[1], a.Name)
	}
	if got[2] != "--model opus --effort high plan a garden" {
		t.Errorf("the agent got %q", got[2])
	}

	var all []Session
	call(t, c, "GET", "/v1/sessions", "", nil, &all)
	chats := 0
	for _, s := range all {
		if s.Chat {
			chats++
		}
	}
	if chats != 2 {
		t.Fatalf("listed %d chats, want 2: %+v", chats, all)
	}
}

// What a chat takes: an agent and nothing that ties it to a place.
func TestAChatTakesAnAgentAndNoPlace(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	chatAgent(t)
	c, _ := servedBox(t)
	for _, body := range []map[string]any{
		{"chat": true},
		{"chat": true, "command": "cat"},
		{"chat": true, "agent": "claude", "command": "cat"},
		{"chat": true, "agent": "claude", "location": "cal"},
		{"chat": true, "agent": "claude", "home": true},
		{"chat": true, "agent": "no-such-agent"},
		{"chat": true, "agent": "claude", "model": "opus; touch /tmp/x"},
		{"chat": true, "agent": "claude", "name": "../escape"},
	} {
		var e struct{ Error string }
		if st := call(t, c, "POST", "/v1/sessions", "", body, &e); st != 400 {
			t.Errorf("%v = %d (%s), want 400", body, st, e.Error)
		}
	}
	entries, _ := os.ReadDir(filepath.Join(os.Getenv("HOME"), "pier", "chats"))
	if len(entries) != 0 {
		t.Fatalf("refused chats left folders: %v", entries)
	}
	bx := &Box{}
	if caps := strings.Join(bx.Capabilities(), " "); !strings.Contains(caps, "session.chat") {
		t.Errorf("capabilities %q lack session.chat", caps)
	}
}

// A chat's folder goes when it ends with nothing written there (the app's
// attachments aside); one where the agent left something stays. A name is
// never given a folder an earlier chat left.
func TestAnEndedChatKeepsItsFolderOnlyWhenTheAgentWroteThere(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	out := chatAgent(t)
	c, _ := servedBox(t)

	start := func(name string) Session {
		t.Helper()
		var s Session
		if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude", Name: name}, &s); st != 200 {
			t.Fatalf("start %s: %d", name, st)
		}
		seen(t, out, s.Name)
		return s
	}
	end := func(s Session) {
		t.Helper()
		if st := call(t, c, "DELETE", "/v1/sessions/"+s.Name, "", nil, nil); st != 200 {
			t.Fatalf("end %s: %d", s.Name, st)
		}
	}

	empty := start("idea")
	os.MkdirAll(filepath.Join(empty.Dir, attachmentDir), 0o700)
	os.WriteFile(filepath.Join(empty.Dir, attachmentDir, "shot.png"), []byte("png"), 0o600)
	end(empty)
	if _, err := os.Stat(empty.Dir); !os.IsNotExist(err) {
		t.Fatalf("an empty chat's folder stayed: %v", err)
	}

	plan := start("plan")
	os.WriteFile(filepath.Join(plan.Dir, "PLAN.md"), []byte("# the plan\n"), 0o600)
	end(plan)
	if _, err := os.Stat(filepath.Join(plan.Dir, "PLAN.md")); err != nil {
		t.Fatalf("what the agent wrote went with the chat: %v", err)
	}
	var e struct{ Error string }
	if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude", Name: "plan"}, &e); st != 409 {
		t.Fatalf("a name whose folder is kept = %d (%s), want 409", st, e.Error)
	}
	// A default name never collides: it takes the next free folder.
	name, dir, err := makeChatDir("plan", false)
	if err != nil || name != "plan-2" || dir != filepath.Join(filepath.Dir(plan.Dir), "plan-2") {
		t.Fatalf("makeChatDir = %q %q %v", name, dir, err)
	}
}

// Two chats are two folders, so a hook that names no session (an agent
// started outside pierd's environment) is still placed in the right one,
// and never in a chat that runs elsewhere.
func TestHooksOfOneChatNeverReachAnother(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	chatAgent(t)
	turns := &Turns{}
	c, bus := servedBox(t, func(b *Box) { b.Turns = turns })
	turns.Attach(bus)

	var a, b Session
	call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude"}, &a)
	call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude"}, &b)
	defer call(t, c, "DELETE", "/v1/sessions/"+a.Name, "", nil, nil)
	defer call(t, c, "DELETE", "/v1/sessions/"+b.Name, "", nil, nil)
	if a.Name == "" || b.Name == "" {
		t.Fatalf("chats: %+v %+v", a, b)
	}

	hook(bus, "agent.ready", "", a.Dir, "claude")
	hook(bus, "agent.started", "", a.Dir, "claude", "signal", "prompt")
	hook(bus, "agent.waiting", "", a.Dir, "claude", "reason", "permission")
	if st, _ := turns.State(a.Name); st.State != "waiting" {
		t.Fatalf("%s = %+v, want waiting", a.Name, st)
	}
	if st, _ := turns.State(b.Name); st.State == "waiting" {
		t.Fatalf("%s took the other chat's hook: %+v", b.Name, st)
	}
	var all []Session
	call(t, c, "GET", "/v1/sessions", "", nil, &all)
	for _, s := range all {
		if s.Name == a.Name && (s.AgentState != "waiting" || !s.Chat) {
			t.Fatalf("listed %+v, want a waiting chat", s)
		}
	}
}

// A chat has no location: exec names the chat and runs in its folder (next steps and titles). A session that is not a
// chat is refused that way.
func TestExecRunsInAChatsFolder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	chatAgent(t)
	c, _ := servedBox(t)
	var s Session
	if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Chat: true, Agent: "claude"}, &s); st != 200 {
		t.Fatalf("chat: %d", st)
	}
	defer call(t, c, "DELETE", "/v1/sessions/"+s.Name, "", nil, nil)
	var ex ExecResult
	if st := call(t, c, "POST", "/v1/exec", "", ExecRequest{Session: s.Name, Command: "pwd"}, &ex); st != 200 || ex.ExitCode != 0 {
		t.Fatalf("exec in the chat: %d %+v", st, ex)
	}
	real, _ := filepath.EvalSymlinks(s.Dir)
	if got := strings.TrimSpace(ex.Output); got != s.Dir && got != real {
		t.Fatalf("ran in %q, not the chat's folder %q", got, s.Dir)
	}
	var shell Session
	if st := call(t, c, "POST", "/v1/sessions", "", SessionRequest{Home: true, Command: "sleep 30"}, &shell); st != 200 {
		t.Fatalf("shell: %d", st)
	}
	defer call(t, c, "DELETE", "/v1/sessions/"+shell.Name, "", nil, nil)
	if st := call(t, c, "POST", "/v1/exec", "", ExecRequest{Session: shell.Name, Command: "pwd"}, nil); st != 400 {
		t.Fatalf("exec by a session that is not a chat: %d", st)
	}
}
