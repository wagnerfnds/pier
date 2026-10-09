package box

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/events"
)

func TestSendWaitAndExecOrchestrateASession(t *testing.T) {
	states := &Turns{}
	c, bus := servedBox(t, func(b *Box) { b.Turns = states })
	states.Attach(bus)
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)

	// A stand-in agent: named claude, it echoes what it is sent.
	bin := t.TempDir()
	fake := filepath.Join(bin, "claude")
	os.WriteFile(fake, []byte("#!/bin/sh\nexec cat\n"), 0o755)
	var sess Session
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal", "name": "agent", "command": fake}, &sess)

	if status := call(t, c, "POST", "/v1/sessions/agent/send", "", map[string]any{"text": "line one\nline two"}, nil); status != 200 {
		t.Fatalf("send: %d", status)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		var screen struct{ Screen string }
		call(t, c, "GET", "/v1/sessions/agent/screen", "", nil, &screen)
		if strings.Contains(screen.Screen, "line two") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the paste never arrived: %q", screen.Screen)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// An old "finished" does not end a wait that started after it.
	bus.Publish(events.Event{Type: "agent.finished", Data: map[string]any{"path": sess.Dir}})
	time.Sleep(100 * time.Millisecond)
	after := time.Now().UTC().Format(time.RFC3339Nano)
	var res WaitResult
	call(t, c, "GET", "/v1/sessions/agent/wait?for=finished&timeout=1s&after="+after, "", nil, &res)
	if !res.TimedOut {
		t.Fatalf("a stale state ended the wait: %+v", res)
	}
	go func() {
		time.Sleep(300 * time.Millisecond)
		bus.Publish(events.Event{Type: "agent.finished", Data: map[string]any{"path": sess.Dir}})
	}()
	res = WaitResult{}
	call(t, c, "GET", "/v1/sessions/agent/wait?for=finished&timeout=10s&after="+after, "", nil, &res)
	if res.State != "finished" || res.TimedOut {
		t.Fatalf("wait = %+v", res)
	}

	var ex ExecResult
	call(t, c, "POST", "/v1/exec", "", ExecRequest{Location: "cal", Command: "echo checking; exit 3"}, &ex)
	if ex.ExitCode != 3 || !strings.Contains(ex.Output, "checking") {
		t.Fatalf("exec = %+v", ex)
	}
}

func TestExecKeepsTheEndOfLongOutput(t *testing.T) {
	var tb tailBuffer
	tb.Write([]byte(strings.Repeat("a", execOutputLimit)))
	tb.Write([]byte("the end"))
	if !tb.dropped || tb.Len() != execOutputLimit || !strings.HasSuffix(tb.String(), "the end") {
		t.Fatalf("len %d dropped %v", tb.Len(), tb.dropped)
	}
}

// Text cannot end its own paste: the paste-end sequence in a prompt would
// hand what follows it to the agent as keystrokes.
func TestASendCannotLeaveItsPaste(t *testing.T) {
	if got := inPaste("fix it\x1b[201~\x1b[A\rrm -rf /"); got != "fix it\x1b[A\rrm -rf /" {
		t.Fatalf("inPaste = %q", got)
	}
	if got := inPaste("plain text\n"); got != "plain text\n" {
		t.Fatalf("inPaste changed plain text: %q", got)
	}
}

// An answer to a menu is one key, pressed rather than pasted: agents'
// menus ignore a bracketed paste of "2".
func TestOneKeyAnswersArePressedNotPasted(t *testing.T) {
	for _, k := range []string{"1", "9", "y", "N"} {
		if !isKey(k) {
			t.Fatalf("%q is a key", k)
		}
	}
	for _, k := range []string{"", "12", "yes", " ", "\n", "-", "é"} {
		if isKey(k) {
			t.Fatalf("%q is not one key", k)
		}
	}
	c, _ := servedBox(t)
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	// A stand-in menu: it reads one byte without a paste and prints it.
	bin := t.TempDir()
	fake := filepath.Join(bin, "menu")
	os.WriteFile(fake, []byte("#!/bin/sh\nstty raw -echo\nk=$(dd bs=1 count=1 2>/dev/null)\nstty sane\necho \"picked [$k]\"\nsleep 5\n"), 0o755)
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal", "name": "menu", "command": fake}, nil)
	time.Sleep(300 * time.Millisecond)
	if status := call(t, c, "POST", "/v1/sessions/menu/send", "", map[string]any{"text": "2", "enter": false}, nil); status != 200 {
		t.Fatalf("send: %d", status)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		var screen struct{ Screen string }
		call(t, c, "GET", "/v1/sessions/menu/screen", "", nil, &screen)
		if strings.Contains(screen.Screen, "picked [2]") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the key never arrived as one keystroke: %q", screen.Screen)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
