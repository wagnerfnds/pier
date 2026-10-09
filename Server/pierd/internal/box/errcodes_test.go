package box

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestErrorsCarryACode(t *testing.T) {
	for _, tc := range []struct {
		err  error
		code string
	}{
		{ErrUnknownSession, CodeNotFound},
		{fmt.Errorf("x: %w", ErrUnknownWorktree), CodeNotFound},
		{ErrSessionExited, CodeSessionExited},
		{tmuxSendError("paste-buffer", []byte("target pane has exited\n"), errors.New("exit status 1")), CodeSessionExited},
		{ErrSessionExists, CodeSessionExists},
		{errTmuxMissing, CodeTmuxMissing},
		{httpError{409, ErrAgentWaiting{"a"}.Error()}, CodeAgentWaiting},
		{httpError{403, "a hook stopped it"}, CodeRefused},
		{httpError{501, "this box has no resource guard"}, CodeUnsupported},
		{errors.New("git worktree add: fatal: invalid reference: nope"), CodeGitFailed},
		{errors.New("tmux kill-session: server exited"), CodeCommandFailed},
		{badRequest("name is required"), CodeBadRequest},
	} {
		if got := codeFor(tc.err); got != tc.code {
			t.Errorf("codeFor(%q) = %s, want %s", tc.err, got, tc.code)
		}
	}
	if statusFor(ErrSessionExited) != 409 {
		t.Errorf("an exited session is a conflict, got %d", statusFor(ErrSessionExited))
	}
}

func TestSendingToAnEndedSessionSaysSo(t *testing.T) {
	c, _ := servedBox(t)
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal", "name": "quick", "command": "true"}, nil)
	deadline := time.Now().Add(5 * time.Second)
	for {
		var list []Session
		call(t, c, "GET", "/v1/sessions", "", nil, &list)
		if len(list) == 1 && list[0].Exited {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the session never ended: %+v", list)
		}
		time.Sleep(50 * time.Millisecond)
	}
	var out struct{ Error, Code string }
	if status := call(t, c, "POST", "/v1/sessions/quick/send", "", map[string]any{"text": "hello", "when": "idle"}, &out); status != 409 || out.Code != CodeSessionExited {
		t.Fatalf("send to an ended session = %d %+v", status, out)
	}
	out = struct{ Error, Code string }{}
	if status := call(t, c, "POST", "/v1/sessions/nope/send", "", map[string]any{"text": "hello"}, &out); status != 404 || out.Code != CodeNotFound {
		t.Fatalf("send to a missing session = %d %+v", status, out)
	}
}
