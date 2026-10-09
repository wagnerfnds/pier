package engine

import (
	"context"
	"time"

	"pier/pierd/internal/push/boxapi"
)

// finishPrep is what a finished announcement needs from the box and the model: read and written as soon as the turn
// is seen to end, alongside the settle wait, instead of after it. The recap alone takes seconds.
type finishPrep struct {
	since  time.Time
	cancel context.CancelFunc
	done   chan struct{}

	reply   string // the agent's last reply
	recap   string // the model's one sentence, "" when off or failed
	review  *boxapi.ReviewItem
	jobs    []string // background work still running
	meta    finishMeta
	hasMeta bool
}

// How long the reply is waited for: 20 reads, 150ms apart (3s).
const (
	replyTries = 20
	replyEvery = 150 * time.Millisecond
)

// metaFor is the finish's interrupted / failed flags, when the event that carried them is about this turn.
func (e *Engine) metaFor(s boxapi.Session, since time.Time) (finishMeta, bool) {
	e.mu.Lock()
	m, ok := e.meta[s.Name]
	if !ok {
		m, ok = e.meta["path:"+s.Dir]
	}
	e.mu.Unlock()
	if ok && absDur(m.at.Sub(since)) > 10*time.Second {
		return finishMeta{}, false
	}
	return m, ok
}

// prepFinished starts preparing the announcement of s's finished turn (once per turn) and returns it.
func (e *Engine) prepFinished(s boxapi.Session, since time.Time) *finishPrep {
	e.mu.Lock()
	if p := e.preps[s.Name]; p != nil {
		if p.since.Equal(since) {
			e.mu.Unlock()
			return p
		}
		p.cancel()
	}
	ctx, cancel := context.WithCancel(e.ctx)
	p := &finishPrep{since: since, cancel: cancel, done: make(chan struct{})}
	e.preps[s.Name] = p
	e.mu.Unlock()
	go func() {
		defer close(p.done)
		p.meta, p.hasMeta = e.metaFor(s, since)
		stale := e.now().Sub(since) > e.opt.StaleAfter
		recapDone := make(chan struct{})
		// The agent reports its end a moment before its reply reaches the transcript: read again until it is there.
		p.reply = e.box.LastMessage(ctx, s.Name)
		for i := 0; p.reply == "" && i < replyTries && ctx.Err() == nil; i++ {
			select {
			case <-time.After(replyEvery):
			case <-ctx.Done():
			}
			p.reply = e.box.LastMessage(ctx, s.Name)
		}
		go func() {
			defer close(recapDone)
			if e.opt.Recap != nil && p.reply != "" && !stale && !p.meta.interrupted {
				p.recap = e.opt.Recap(ctx, s.Name, since, p.reply)
			}
		}()
		p.review = e.reviewFor(ctx, s)
		if !p.meta.failed && !p.meta.interrupted {
			p.jobs = e.box.Background(ctx, s.Name)
		}
		<-recapDone
	}()
	return p
}

// dropPrep forgets (and stops) a session's preparation: its turn moved on.
func (e *Engine) dropPrep(name string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if p := e.preps[name]; p != nil {
		p.cancel()
		delete(e.preps, name)
	}
}
