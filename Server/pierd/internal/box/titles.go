package box

import (
	"context"
	"net/http"
	"strings"

	"pier/pierd/internal/events"
	"pier/pierd/internal/integrations/adapters"
)

// A session is named after its work: "Fix checkout webhook", not "Claude
// Code 2". The title is the first line of the prompt it started with; a
// session started without one takes it from the first prompt the turn
// ledger sees, sent through pierd or typed into the agent. Only the title
// is kept, as the tmux option @pier_title; the prompt itself is not.

// titleNew names a session just started with prompt, unless the caller
// named it (title). It returns the session as it is now.
func (b *Box) titleNew(ctx context.Context, sess Session, title, prompt string) Session {
	if title == "" {
		title = adapters.Title(prompt)
	}
	if title == "" {
		return sess
	}
	if err := b.Sessions.SetTitle(ctx, sess.Name, title); err == nil {
		sess.Title = adapters.Clip(title, TitleMax)
	}
	return sess
}

// nameAfter names a session after a prompt (already its title) when it is
// the first the ledger has seen for it and the session has no title yet.
func (b *Box) nameAfter(ctx context.Context, name, title string) {
	if b.Turns == nil || title == "" || !b.Turns.FirstPrompt(name) {
		return
	}
	sess, err := b.Sessions.Get(ctx, name)
	if err != nil || sess.Title != "" {
		return
	}
	if b.Sessions.SetTitle(ctx, name, title) == nil {
		b.Events.Publish(events.Event{Type: "session.renamed", Box: b.Name, Data: map[string]any{"name": name}})
	}
}

// renameSession is PATCH /v1/sessions/{name}: {"title": "..."} names the
// session's work; an empty title clears it, so the app falls back to the
// agent's name.
func (b *Box) renameSession(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	var req struct {
		Title *string `json:"title"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if req.Title == nil {
		return badRequest("give a title (an empty one clears it)")
	}
	title := strings.TrimSpace(*req.Title)
	if err := b.before(r, "session.rename", map[string]any{"name": name, "title": title}); err != nil {
		return err
	}
	if err := b.Sessions.SetTitle(r.Context(), name, title); err != nil {
		return err
	}
	// It has a name now: a first prompt must not replace it.
	if b.Turns != nil {
		b.Turns.FirstPrompt(name)
	}
	b.publish(r, "session.renamed", map[string]any{"name": name})
	sess, err := b.Sessions.Get(r.Context(), name)
	if err != nil {
		return err
	}
	writeJSON(w, b.enrich(r.Context(), []Session{sess})[0])
	return nil
}
