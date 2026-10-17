package box

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

// Every error the box answers with is {"error": "...", "code": "..."}. The
// message is for people and logs; the code is what clients branch on, so an
// app can say what happened in its own words and offer the one thing that
// helps (start the agent again, update the box) without reading the text.
//
// Codes:
//
//	not_found        no such session, worktree, location, …
//	session_exited   the session's program has ended; it takes no input
//	session_exists   a session with that name is already running
//	agent_waiting    the agent waits for an answer; sending would pick one
//	not_submitted    the agent never took a prompt typed into it (kept: it is
//	                 still in its input box)
//	refused          a before: hook (or the box's own rules) said no
//	unsupported      this box doesn't have that feature
//	tmux_missing     tmux is not installed on the box
//	git_failed       git refused; the message carries git's words
//	command_failed   a program the box ran failed
//	too_many         slow down and try again
//	file_changed     a save's file changed (or went) on the box since it was read
//	file_exists      a new file's path is taken
//	unsaved_work     removing a project would lose work no remote has
//	space_not_empty  a space still holds projects
//	space_has_files  a space holds files that are no project's
//	docker_missing   docker is not available on the box
//	gh_missing       gh (GitHub CLI) is not installed on the box
//	gh_auth          gh is not signed in on the box
//	tool_missing     the tool a sign-in is for is not installed (POST /v1/tools/install)
//	bad_request      the request itself was wrong
//	internal         anything else
const (
	CodeNotFound      = "not_found"
	CodeSessionExited = "session_exited"
	CodeSessionExists = "session_exists"
	CodeAgentWaiting  = "agent_waiting"
	CodeNotSubmitted  = "not_submitted"
	CodeRefused       = "refused"
	CodeUnsupported   = "unsupported"
	CodeTmuxMissing   = "tmux_missing"
	CodeGitFailed     = "git_failed"
	CodeCommandFailed = "command_failed"
	CodeTooMany       = "too_many"
	CodeFileChanged   = "file_changed"
	CodeFileExists    = "file_exists"
	CodeUnsavedWork   = "unsaved_work"
	CodeGHMissing     = "gh_missing"
	CodeSpaceNotEmpty = "space_not_empty"
	CodeSpaceHasFiles = "space_has_files"
	CodeDockerMissing = "docker_missing"
	CodeGHAuth        = "gh_auth"
	CodeToolMissing   = "tool_missing"
	CodeBadRequest    = "bad_request"
	CodeInternal      = "internal"
)

// ErrSessionExited refuses to type into a session whose program has ended:
// tmux keeps the dead pane so its last output stays readable, but nothing
// reads what is typed there.
var ErrSessionExited = errors.New("the session's program has ended, so it can't take input; start it again")

// NotSubmittedError is a prompt the agent never took (submit.go): typed,
// it never showed in the agent's input box, or stayed there through two
// Enters. Kept says it is still there because the box could not be cleared,
// so whoever sent it must not send it again from scratch (it would go twice
// once someone presses Enter there). Leftover says this one was not typed at
// all: the box still holds an earlier prompt pierd could not send nor clear.
type NotSubmittedError struct{ Kept, Leftover bool }

func (e *NotSubmittedError) Error() string {
	switch {
	case e.Kept:
		return "the agent didn't take the prompt, which is still in its input box: press Enter in its terminal to send it, or clear it there"
	case e.Leftover:
		return "the agent's input box still holds an earlier prompt that pierd could not send, so this one was not typed: send or clear that one in the agent's terminal, then send this again"
	}
	return "the agent didn't take the prompt, so nothing was sent; try again"
}

// errTmuxMissing is what every tmux call says on a box without it.
var errTmuxMissing = errors.New("tmux is not installed on this box")

// codeFor names an error for clients.
func codeFor(err error) string {
	var he httpError
	var ns *NotSubmittedError
	switch {
	case errors.As(err, &ns):
		return CodeNotSubmitted
	case errors.Is(err, ErrSessionExited):
		return CodeSessionExited
	case errors.Is(err, ErrSessionExists):
		return CodeSessionExists
	case errors.Is(err, errTmuxMissing):
		return CodeTmuxMissing
	case errors.Is(err, ErrFileChanged), errors.Is(err, ErrFileDeleted):
		return CodeFileChanged
	case errors.Is(err, ErrFileExists):
		return CodeFileExists
	case errors.Is(err, ErrUnsavedWork):
		return CodeUnsavedWork
	case errors.Is(err, ErrSpaceNotEmpty):
		return CodeSpaceNotEmpty
	case errors.Is(err, ErrSpaceHasFiles):
		return CodeSpaceHasFiles
	case errors.Is(err, ErrUnknownLocation), errors.Is(err, ErrUnknownWorktree), errors.Is(err, ErrUnknownSession), errors.Is(err, ErrUnknownUnit):
		return CodeNotFound
	case errors.As(err, &he):
		switch he.msg {
		case errGHMissing.Error():
			return CodeGHMissing
		case errGHAuth.Error():
			return CodeGHAuth
		}
		if strings.HasPrefix(he.msg, errDocker.Error()) {
			return CodeDockerMissing
		}
		if strings.Contains(he.msg, "is waiting for someone to answer it") || strings.Contains(he.msg, "is asking whether to trust this folder") {
			return CodeAgentWaiting
		}
		return codeForStatus(he.status)
	}
	msg := err.Error()
	switch {
	case exitedPane(msg):
		return CodeSessionExited
	case strings.HasPrefix(msg, "git ") || strings.Contains(msg, "fatal: "):
		return CodeGitFailed
	case strings.HasPrefix(msg, "tmux ") || strings.HasPrefix(msg, "exec: ") || strings.Contains(msg, "exit status"):
		return CodeCommandFailed
	}
	return codeForStatus(statusFor(err))
}

func codeForStatus(status int) string {
	switch status {
	case http.StatusNotFound:
		return CodeNotFound
	case http.StatusForbidden, http.StatusUnauthorized:
		return CodeRefused
	case http.StatusNotImplemented:
		return CodeUnsupported
	case http.StatusTooManyRequests:
		return CodeTooMany
	case http.StatusFailedDependency:
		return CodeToolMissing
	case http.StatusBadRequest, http.StatusConflict, http.StatusMethodNotAllowed, http.StatusRequestEntityTooLarge, http.StatusPreconditionRequired, http.StatusUnsupportedMediaType:
		return CodeBadRequest
	}
	return CodeInternal
}

// exitedPane is tmux's way of saying the program in a pane has ended.
func exitedPane(msg string) bool {
	return strings.Contains(msg, "pane has exited") || strings.Contains(msg, "pane is dead")
}

// writeErr answers with err, its status and its code; not_submitted also
// says whether the prompt was kept in the agent's box.
func writeErr(w http.ResponseWriter, err error) {
	var ns *NotSubmittedError
	if errors.As(err, &ns) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(statusFor(err))
		json.NewEncoder(w).Encode(map[string]any{"error": err.Error(), "code": CodeNotSubmitted, "kept": ns.Kept})
		return
	}
	writeCoded(w, statusFor(err), err.Error(), codeFor(err))
}
