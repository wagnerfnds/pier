package box

import (
	"net/http"
	"strconv"

	"pier/pierd/internal/transcript"
)

// A conversation's history beyond its live end (the "history" capability):
// older items a page at a time (GET …/transcript?before=OFF), the helpers'
// own conversations (…/subagents), a fork that goes on from any prompt in
// a new session, and a rewind to before one, driven through the agent's
// own /rewind. Like the transcript, these are the session's content: only
// paired peers reach them, and nothing is stored but a fork's own record.

func reader() *transcript.Reader {
	transcriptsOnce.Do(func() { transcripts = transcript.NewReader() })
	return transcripts
}

// olderPage answers ?before=OFF on a transcript: the items made before
// that offset, a page at a time, read afresh and never kept.
func olderPage(w http.ResponseWriter, r *http.Request, agent, path, dir string) error {
	before, err := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	if err != nil || before < 0 {
		return badRequest("before must be an offset")
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	res, err := transcript.Before(agent, path, dir, before, limit)
	if err != nil {
		return err
	}
	writeJSON(w, res)
	return nil
}

// claudeRecord is a session's Claude Code record, or why there is none.
func (b *Box) claudeRecord(r *http.Request) (Session, string, error) {
	sess, err := b.Sessions.Get(r.Context(), r.PathValue("name"))
	if err != nil {
		return Session{}, "", err
	}
	agent, path, _ := b.transcriptFile(r, sess)
	switch {
	case agent != "claude":
		return sess, "", httpError{http.StatusBadRequest, "this works with Claude Code's conversations; this session runs " + firstNonEmpty(agent, "no agent")}
	case path == "":
		return sess, "", httpError{http.StatusNotFound, "this session's conversation can't be read yet"}
	}
	return sess, path, nil
}

// ForkRequest starts a new session that goes on from a point in this one.
type ForkRequest struct {
	// At is the entry to go on from: a prompt's parent (the transcript
	// item's "parent"), so the fork has everything before that prompt.
	// Empty starts afresh, as a fork of the first prompt does.
	At string `json:"at,omitempty"`
	// Text is the fork's first prompt, typed for it once it starts.
	Text  string `json:"text,omitempty"`
	Title string `json:"title,omitempty"`
	// Open asks the app to show it: "tab" or "split".
	Open string `json:"open,omitempty"`
}

// RewindRequest takes a Claude Code conversation back to before a prompt.
type RewindRequest struct {
	// Text is the prompt; Nth which of the prompts reading so, counting
	// back from the newest (0).
	Text string `json:"text"`
	Nth  int    `json:"nth,omitempty"`
	// Restore is "conversation" (the default), "both" (and the code), or
	// "code".
	Restore string `json:"restore,omitempty"`
}

// RewindResult says what was restored, and gives back the prompt to edit.
type RewindResult struct {
	Restored string `json:"restored"`
	Text     string `json:"text"`
}

// session name → *sync.Mutex
