// Package engine turns pierd's session states into pushes: it tracks each agent session, notices transitions
// (waiting, finished, running, exited), enriches them (ask, menu on screen, review diff), and sends alerts, Live
// Activity updates and widget reloads to the registered phones.
package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"pier/pierd/internal/push/apns"
	"pier/pierd/internal/push/boxapi"
	"pier/pierd/internal/push/menu"
	"pier/pierd/internal/push/payload"
	"pier/pierd/internal/push/sched"
	"pier/pierd/internal/push/state"
	"pier/pierd/internal/push/text"
)

// Sender is the APNs client (an interface so tests can record what would be sent).
type Sender interface {
	Send(ctx context.Context, r apns.Request) (apns.Result, error)
}

type Options struct {
	BundleID  string
	DateEpoch string // "unix" (default) | "reference": how Dates in content-state are written

	// How long a transition must stay put before it is announced (a permission that is answered at once, or an
	// agent that flips straight back to running, never pings the phone).
	WaitingSettle  time.Duration // default 700ms
	FinishedSettle time.Duration // default 1s
	SyncDelay      time.Duration // events -> one session list fetch; default 300ms
	SyncEvery      time.Duration // safety resync; default 30s
	ScreenTries    int           // reads of the screen looking for the menu; default 4
	ScreenRetry    time.Duration // between them; default 600ms

	ActivityInterval time.Duration // Live Activity updates per session and device; default 5s
	WidgetInterval   time.Duration // widget reloads per device; default 60s
	StaleAfter       time.Duration // a state older than this is not announced (spooled events); default 10m
	// Push-to-start waits this long and starts only if the phone still has no activity for the session: the app
	// starts one itself for tasks made on the phone and registers its token a moment later. Default 8s.
	StartGrace time.Duration

	// Recap, when set, writes a one-sentence summary of a finished turn (session, the turn's state_since, the agent's
	// last reply); "" keeps the reply excerpt. See package recap. Nil: off.
	Recap func(ctx context.Context, session string, since time.Time, reply string) string
	// Prewarm, when set, is called as an agent starts working: the recap's model can get ready before the turn ends.
	Prewarm func()
}

func (o *Options) defaults() {
	d := func(p *time.Duration, v time.Duration) {
		if *p == 0 {
			*p = v
		}
	}
	d(&o.WaitingSettle, 700*time.Millisecond)
	d(&o.FinishedSettle, time.Second)
	d(&o.SyncDelay, 300*time.Millisecond)
	d(&o.SyncEvery, 30*time.Second)
	d(&o.ScreenRetry, 600*time.Millisecond)
	d(&o.ActivityInterval, 5*time.Second)
	d(&o.WidgetInterval, 60*time.Second)
	d(&o.StaleAfter, 10*time.Minute)
	d(&o.StartGrace, 8*time.Second)
	if o.ScreenTries == 0 {
		o.ScreenTries = 4
	}
	if o.DateEpoch == "" {
		o.DateEpoch = "unix"
	}
}

type finishMeta struct {
	at          time.Time
	interrupted bool
	failed      bool
}

type Engine struct {
	opt    Options
	box    boxapi.API
	st     *state.Store
	send   Sender
	paired func(client string) bool
	log    *slog.Logger
	now    func() time.Time

	deb       *sched.Debouncer
	actThr    *sched.Throttle
	widgThr   *sched.Throttle
	syncMu    sync.Mutex // one Sync at a time
	mu        sync.Mutex
	ctx       context.Context
	baselined bool
	boxName   string
	sessions  []boxapi.Session
	meta      map[string]finishMeta // by session name and "path:<dir>"
	started   map[string]bool       // push-to-start sent: client|session
	locs      []boxapi.Location
	locsAt    time.Time
	preps     map[string]*finishPrep // by session: the finished turn being prepared (prep.go)
}

func New(opt Options, box boxapi.API, st *state.Store, send Sender, paired func(string) bool, log *slog.Logger) *Engine {
	opt.defaults()
	if paired == nil {
		paired = func(string) bool { return true }
	}
	return &Engine{
		opt: opt, box: box, st: st, send: send, paired: paired, log: log, now: time.Now,
		deb: sched.NewDebouncer(), actThr: sched.NewThrottle(opt.ActivityInterval), widgThr: sched.NewThrottle(opt.WidgetInterval),
		meta: map[string]finishMeta{}, started: map[string]bool{}, preps: map[string]*finishPrep{}, ctx: context.Background(),
	}
}

// Init does the first sync (a baseline: nothing is announced for what is already there). Call it before feeding
// events.
func (e *Engine) Init(ctx context.Context) {
	e.mu.Lock()
	e.ctx = ctx
	e.mu.Unlock()
	if info, err := e.box.Info(ctx); err == nil {
		e.mu.Lock()
		e.boxName = info.Name
		e.mu.Unlock()
	}
	e.Sync(ctx, true)
}

// Run resyncs on a timer until ctx ends (a safety net for missed events). Feed events with OnEvent.
func (e *Engine) Run(ctx context.Context) {
	t := time.NewTicker(e.opt.SyncEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			e.deb.Stop()
			return
		case <-t.C:
			e.Sync(ctx, false)
		}
	}
}

func (e *Engine) context() context.Context {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.ctx
}

// OnEvent is called for every pierd event, in order.
func (e *Engine) OnEvent(ev boxapi.Event) {
	e.st.SetLastSeq(ev.Seq)
	switch ev.Type {
	case "agent.finished":
		m := finishMeta{
			at:          ev.Time,
			interrupted: ev.Str("source") == "interrupt" || ev.Str("status") == "interrupted",
			failed:      ev.Str("status") == "error",
		}
		e.mu.Lock()
		if s := ev.Str("session"); s != "" {
			e.meta[s] = m
		}
		if p := ev.Str("path"); p != "" {
			e.meta["path:"+p] = m
		}
		e.mu.Unlock()
		// A finish starts the recap: read the list now rather than after the burst debounce (the box's ledger already
		// has the event). The debounced read below still follows, for whatever came with it.
		go e.Sync(e.context(), false)
		fallthrough
	case "agent.ready", "agent.started", "agent.waiting", "agent.exited", "session.started", "session.stopped", "session.renamed":
		e.deb.Do("sync", e.opt.SyncDelay, func() { e.Sync(e.context(), false) })
	}
}

func isAgent(s boxapi.Session) bool { return s.AgentState != "" || (s.Agent != "" && s.Service == "") }

func stateOf(s boxapi.Session) string {
	if s.Exited {
		return "exited"
	}
	if s.AgentState == "" {
		return "idle"
	}
	return s.AgentState
}

// Sync reads the session list and acts on every change since the last one. With initial it only records a baseline
// for sessions not seen before (a fresh install must not announce what is already on screen).
func (e *Engine) Sync(ctx context.Context, initial bool) {
	e.syncMu.Lock()
	defer e.syncMu.Unlock()
	sessions, err := e.box.Sessions(ctx)
	if err != nil {
		e.log.Warn("sessions fetch failed", "err", err)
		return
	}
	e.mu.Lock()
	e.sessions = sessions
	initial = initial || !e.baselined // the first successful read is the baseline, whenever it happens
	e.baselined = true
	e.mu.Unlock()
	live := map[string]bool{}
	for _, s := range sessions {
		if !isAgent(s) {
			continue
		}
		live[s.Name] = true
		cur := state.Seen{State: stateOf(s), Since: s.StateSince}
		prev, had := e.st.Seen(s.Name)
		if had && prev.State == cur.State && prev.Since.Equal(cur.Since) {
			continue
		}
		e.st.SetSeen(s.Name, cur)
		if !had && initial {
			continue
		}
		e.log.Info("session transition", "session", s.Name, "from", prev.State, "to", cur.State, "since", cur.Since.Format(time.RFC3339))
		e.transition(s, prev.State, cur.State)
	}
	for name := range e.st.SeenAll() {
		if !live[name] {
			e.log.Info("session gone", "session", name)
			e.deb.Cancel("alert|" + name)
			e.dropPrep(name)
			e.endSession(ctx, name, e.snapshot(name))
			e.st.DeleteSeen(name)
		}
	}
}

func (e *Engine) snapshot(name string) boxapi.Session {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.sessions {
		if s.Name == name {
			return s
		}
	}
	return boxapi.Session{Name: name}
}

func (e *Engine) transition(s boxapi.Session, prev, cur string) {
	name := s.Name
	e.deb.Cancel("alert|" + name) // a newer state supersedes an announcement still settling
	if cur != "finished" {
		e.dropPrep(name)
	}
	switch cur {
	case "waiting":
		e.deb.Do("alert|"+name, e.opt.WaitingSettle, func() { e.announceWaiting(name, s.StateSince) })
	case "finished":
		e.prepFinished(s, s.StateSince) // the reply, the recap and the diff, while the transition settles
		e.deb.Do("alert|"+name, e.opt.FinishedSettle, func() { e.announceFinished(name, s.StateSince) })
	case "running":
		if e.opt.Prewarm != nil && prev != "running" {
			go e.opt.Prewarm()
		}
		go e.announceRunning(s, prev != "running")
	case "idle":
		go e.activityOnly(s, "starting")
	case "exited":
		go e.endSession(e.context(), name, s)
	}
	go e.reloadWidgets()
}

// fresh re-reads one session; ok only while it is still in the state (and moment) we were told about.
func (e *Engine) fresh(ctx context.Context, name, state string, since time.Time) (boxapi.Session, bool) {
	list, err := e.box.Sessions(ctx)
	if err != nil {
		e.log.Warn("sessions fetch failed", "err", err)
		return boxapi.Session{}, false
	}
	e.mu.Lock()
	e.sessions = list
	e.mu.Unlock()
	for _, s := range list {
		if s.Name == name {
			if stateOf(s) == state && s.StateSince.Equal(since) {
				return s, true
			}
			e.log.Info("announcement superseded", "session", name, "wanted", state, "now", stateOf(s))
			return s, false
		}
	}
	return boxapi.Session{}, false
}

func (e *Engine) locations(ctx context.Context) []boxapi.Location {
	e.mu.Lock()
	if e.locs != nil && e.now().Sub(e.locsAt) < 20*time.Second {
		l := e.locs
		e.mu.Unlock()
		return l
	}
	e.mu.Unlock()
	l, err := e.box.Locations(ctx)
	if err != nil {
		e.log.Warn("locations fetch failed", "err", err)
		return e.locs
	}
	e.mu.Lock()
	e.locs, e.locsAt = l, e.now()
	e.mu.Unlock()
	return l
}

func (e *Engine) all() []boxapi.Session {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]boxapi.Session(nil), e.sessions...)
}

// ---- recipients ----

type recipient struct {
	d    state.Device
	lang text.Lang
	box  string
}

func (e *Engine) boxNameFor(d state.Device) string {
	if d.BoxName != "" {
		return d.BoxName
	}
	for _, a := range e.st.Activities() {
		if a.Client == d.Client && a.Box != "" {
			return a.Box
		}
	}
	e.mu.Lock()
	name := e.boxName
	e.mu.Unlock()
	if name == "" {
		ctx, cancel := context.WithTimeout(e.context(), 3*time.Second)
		defer cancel()
		if info, err := e.box.Info(ctx); err == nil {
			name = info.Name
			e.mu.Lock()
			e.boxName = name
			e.mu.Unlock()
		}
	}
	return name
}

func (e *Engine) recipients() []recipient {
	var out []recipient
	for _, d := range e.st.Devices() {
		if !e.paired(d.Client) {
			continue
		}
		out = append(out, recipient{d: d, lang: text.LangOf(d.Locale), box: e.boxNameFor(d)})
	}
	return out
}

// ---- announcements ----

func (e *Engine) announceWaiting(name string, since time.Time) {
	ctx := e.context()
	s, ok := e.fresh(ctx, name, "waiting", since)
	if !ok {
		return
	}
	rcpts := e.recipients()
	acts := e.st.ActivitiesFor(name)
	if len(rcpts) == 0 && len(acts) == 0 {
		return
	}
	hasMenu := false
	permission := s.Ask == nil || !menu.IsQuestionTool(s.Ask.Tool)
	if permission {
		// The menu is drawn a moment after the event: look a few times.
		tries := e.opt.ScreenTries
		if s.Ask == nil {
			tries = 2
		}
		for i := 0; i < tries && !hasMenu; i++ {
			if i > 0 {
				select {
				case <-ctx.Done():
					return
				case <-time.After(e.opt.ScreenRetry):
				}
			}
			if screen, err := e.box.Screen(ctx, name); err == nil {
				_, hasMenu = menu.PermissionMenu(screen)
			} else {
				e.log.Warn("screen fetch failed", "session", name, "err", err)
			}
		}
		// Gone or changed while we looked?
		if _, ok := e.fresh(ctx, name, "waiting", since); !ok {
			return
		}
	}
	category := payload.CategoryNeedsYouQuestion
	if hasMenu {
		category = payload.CategoryNeedsYou
	}
	// --- Answer from the notification: a question's (or a plain menu's) choices ride along as `options`, so the phone
	// shows them as the notification's buttons (docs/PUSH.md 4.3). A permission with a menu keeps Permitir / Negar. ---
	var options []string
	optionsKind := ""
	if !hasMenu {
		options, optionsKind = e.waitingOptions(ctx, name, permission)
		if len(options) > 0 {
			if _, ok := e.fresh(ctx, name, "waiting", since); !ok {
				return
			}
			// Numbered buttons from the app's own categories; the service extension swaps in the words when it runs.
			category = payload.CategoryNeedsYouChoice(len(options))
		}
	}
	// --- end answer from the notification ---
	stale := e.now().Sub(since) > e.opt.StaleAfter
	locs := e.locations(ctx)
	all := e.all()
	ask := s.Ask.Summary()
	cs := e.contentState(s, "waiting", hasMenu, nil, nil, text.Clip(ask, 200), "")
	log := e.log.With("session", name, "category", category, "hasMenu", hasMenu, "options", len(options))
	if stale {
		log.Info("waiting state is stale; no alert")
	}
	for _, r := range rcpts {
		if stale || !r.d.Events.Waiting || r.d.Token == "" {
			continue
		}
		body := text.WaitingBody(r.lang, ask)
		if len(options) > 0 {
			body += "\n" + text.ChoicesLine(options)
		}
		b, err := payload.BuildAlert(payload.AlertParams{
			Box: r.box, Session: name, Location: s.Location,
			Title:    text.Title(r.lang, "waiting", text.SessionName(s, all)),
			Subtitle: text.Subtitle(text.PlaceOf(r.lang, s, locs), text.AgentLabel(text.AgentOf(s)), r.box, false),
			Body:     body,
			Category: category, HasMenu: &hasMenu, Options: options, OptionsKind: optionsKind, Level: "time-sensitive", Sound: true,
		})
		if err != nil {
			log.Error("build alert", "err", err)
			continue
		}
		e.dispatchAlert(ctx, r, name, "waiting", b, 10, time.Hour)
	}
	e.updateActivities(ctx, s, rcpts, "waiting", cs, !stale)
}

// maxOptions is how many choices an alert carries (the phone shows at most this many buttons).
const maxOptions = 4

// waitingOptions reads the choices a waiting agent offers, for the alert's buttons: a single-choice question from the
// transcript ("question"), else the numbered rows on screen ("menu": a plan approval, or a question Claude Code draws
// as a list and only writes to its transcript once answered). The agent draws them a moment after the event, so a
// question is looked for a few times; a permission's screen was already read for its menu, so it gets one look.
func (e *Engine) waitingOptions(ctx context.Context, name string, permission bool) ([]string, string) {
	tries := e.opt.ScreenTries
	if permission {
		tries = 1
	}
	for i := 0; i < tries; i++ {
		if i > 0 {
			select {
			case <-ctx.Done():
				return nil, ""
			case <-time.After(e.opt.ScreenRetry):
			}
		}
		if !permission {
			if opts := e.box.OpenQuestion(ctx, name); len(opts) >= 2 {
				return clipOptions(opts), "question"
			}
		}
		if screen, err := e.box.Screen(ctx, name); err == nil {
			if opts := menu.OptionLabels(screen); len(opts) >= 2 {
				return clipOptions(opts), "menu"
			}
		} else {
			e.log.Warn("screen fetch failed", "session", name, "err", err)
		}
	}
	return nil, ""
}

// clipOptions keeps the first maxOptions choices, each short enough for a button.
func clipOptions(opts []string) []string {
	if len(opts) > maxOptions {
		opts = opts[:maxOptions]
	}
	out := make([]string, 0, len(opts))
	for _, o := range opts {
		out = append(out, text.Clip(o, 60))
	}
	return out
}

func (e *Engine) announceFinished(name string, since time.Time) {
	ctx := e.context()
	s, ok := e.fresh(ctx, name, "finished", since)
	if !ok {
		return
	}
	rcpts := e.recipients()
	acts := e.st.ActivitiesFor(name)
	if len(rcpts) == 0 && len(acts) == 0 {
		return
	}
	p := e.prepFinished(s, since)
	select {
	case <-p.done:
	case <-ctx.Done():
		return
	}
	m := p.meta
	var added, removed *int
	if it := p.review; it != nil {
		a, r := it.Added, it.Removed
		added, removed = &a, &r
	}
	stale := e.now().Sub(since) > e.opt.StaleAfter
	locs := e.locations(ctx)
	all := e.all()
	log := e.log.With("session", name, "interrupted", m.interrupted, "failed", m.failed)
	reply := p.reply
	// The turn ended but the agent still runs something in the background (a long test suite, a subagent): it will speak
	// again when that ends, so this is not "done" yet. The activity stays "running" with the job as its step.
	jobs := p.jobs
	phase := "finished"
	cs := e.contentState(s, "finished", false, added, removed, "", "")
	if sum := text.Excerpt(reply, 280); sum != "" {
		cs.Reply = &sum
	}
	// --- AI recap: one sentence written by a small model (prepared in prep.go) replaces the excerpt. ---
	if p.recap != "" {
		log.Info("recap", "text", p.recap)
		reply = p.recap
		cs.Reply = &p.recap
		// The model can take seconds: a turn that moved on meanwhile is not announced as finished.
		if _, ok := e.fresh(ctx, name, "finished", since); !ok {
			return
		}
	}
	// --- end AI recap ---
	if len(jobs) > 0 {
		phase = "running"
		cs = e.contentState(s, "running", false, nil, nil, "", "⏳ "+text.Clip(jobs[0], 60))
	}
	for _, r := range rcpts {
		if stale || m.interrupted || !r.d.Events.Finished || r.d.Token == "" {
			continue
		}
		kind, body := "finished", text.FinishedBody(r.lang, reply, added, removed)
		if m.failed {
			kind = "failed"
		} else if len(jobs) > 0 {
			kind, body = "background", text.BackgroundBody(r.lang, reply, jobs)
		}
		b, err := payload.BuildAlert(payload.AlertParams{
			Box: r.box, Session: name, Location: s.Location,
			Title:    text.Title(r.lang, kind, text.SessionName(s, all)),
			Subtitle: text.Subtitle(text.PlaceOf(r.lang, s, locs), text.AgentLabel(text.AgentOf(s)), r.box, false),
			Body:     body,
			Category: payload.CategoryFinished, Level: "active", Sound: true,
		})
		if err != nil {
			log.Error("build alert", "err", err)
			continue
		}
		e.dispatchAlert(ctx, r, name, "finished", b, 10, 4*time.Hour)
	}
	e.updateActivities(ctx, s, rcpts, phase, cs, !stale && !m.interrupted)
}

func (e *Engine) announceRunning(s boxapi.Session, fromOther bool) {
	ctx := e.context()
	rcpts := e.recipients()
	if len(rcpts) == 0 && len(e.st.ActivitiesFor(s.Name)) == 0 {
		return
	}
	step := ""
	if d, err := e.box.Draft(ctx, s.Name); err == nil && d.Status != nil {
		step = d.Status.Word
	}
	cs := e.contentState(s, "running", false, nil, nil, "", step)
	if fromOther && e.now().Sub(s.StateSince) <= e.opt.StaleAfter {
		locs := e.locations(ctx)
		all := e.all()
		for _, r := range rcpts {
			if !r.d.Events.Working || r.d.Token == "" {
				continue
			}
			b, err := payload.BuildAlert(payload.AlertParams{
				Box: r.box, Session: s.Name, Location: s.Location,
				Title:    text.Title(r.lang, "working", text.SessionName(s, all)),
				Subtitle: text.Subtitle(text.PlaceOf(r.lang, s, locs), text.AgentLabel(text.AgentOf(s)), r.box, false),
				Body:     text.Clip(step, 120),
				Level:    "passive",
			})
			if err == nil {
				e.dispatchAlert(ctx, r, s.Name, "working", b, 5, 10*time.Minute)
			}
		}
	}
	e.updateActivities(ctx, s, rcpts, "running", cs, false)
}

func (e *Engine) activityOnly(s boxapi.Session, phase string) {
	rcpts := e.recipients()
	e.updateActivities(e.context(), s, rcpts, phase, e.contentState(s, phase, false, nil, nil, "", ""), false)
}

// endSession ends the session's Live Activities and forgets their tokens.
func (e *Engine) endSession(ctx context.Context, name string, s boxapi.Session) {
	acts := e.st.ActivitiesFor(name)
	if len(acts) == 0 {
		return
	}
	now := e.now()
	since := s.StateSince
	if since.IsZero() {
		since = now
	}
	cs := payload.ContentState{Phase: "ended", Since: payload.EncodeDate(since, e.opt.DateEpoch)}
	dismiss := now.Add(5 * time.Minute)
	b, err := payload.BuildActivity(payload.ActivityParams{Event: "end", Now: now, State: cs, DismissAt: &dismiss})
	if err != nil {
		return
	}
	for _, a := range acts {
		if !e.paired(a.Client) {
			continue
		}
		req := apns.Request{
			Env: a.Env, Token: a.Token, PushType: "liveactivity", Topic: e.opt.BundleID + ".push-type.liveactivity",
			Priority: 10, Expiration: now.Add(time.Hour), Payload: b,
		}
		e.actThr.Forget(a.Client + "|" + name)
		e.deliver(ctx, req, a.Client, "activity", name, "end")
		_ = e.st.DeleteActivity(a.Client, a.Box, a.Session)
		e.mu.Lock()
		delete(e.started, a.Client+"|"+name)
		e.mu.Unlock()
	}
}

func (e *Engine) reviewFor(ctx context.Context, s boxapi.Session) *boxapi.ReviewItem {
	items, err := e.box.Review(ctx)
	if err != nil {
		e.log.Warn("review fetch failed", "session", s.Name, "err", err)
		return nil
	}
	for i := range items {
		if items[i].Session == s.Name {
			return &items[i]
		}
	}
	for i := range items {
		if items[i].Path == s.Dir && s.Dir != "" {
			return &items[i]
		}
	}
	return nil
}

func (e *Engine) contentState(s boxapi.Session, phase string, hasMenu bool, added, removed *int, ask, step string) payload.ContentState {
	since := s.StateSince
	if since.IsZero() {
		since = s.Created
	}
	if since.IsZero() {
		since = e.now()
	}
	cs := payload.ContentState{Phase: phase, Since: payload.EncodeDate(since, e.opt.DateEpoch), HasMenu: hasMenu, Added: added, Removed: removed}
	if ask != "" {
		cs.Ask = &ask
	}
	if step != "" {
		cs.Step = &step
	}
	return cs
}

// updateActivities pushes the new content-state to each device's Live Activity for the session; a device with a
// push-to-start token and no activity for it gets one started (once per session) for working/waiting. withAlert adds
// the activity's own alert (lights the screen) when the device wants that kind of event.
func (e *Engine) updateActivities(ctx context.Context, s boxapi.Session, rcpts []recipient, phase string, cs payload.ContentState, withAlert bool) {
	acts := e.st.ActivitiesFor(s.Name)
	byClient := map[string]state.Activity{}
	for _, a := range acts {
		byClient[a.Client] = a
	}
	urgent := phase == "waiting" || phase == "finished"
	all := e.all()
	locs := e.locations(ctx)
	seen := map[string]bool{}
	for _, r := range rcpts {
		seen[r.d.Client] = true
		act, has := byClient[r.d.Client]
		var alert *payload.AlertText
		wants := (phase == "waiting" && r.d.Events.Waiting) || (phase == "finished" && r.d.Events.Finished)
		// The regular alert already lights the screen (and carries the buttons); a second banner from the activity
		// would double it, so the activity's own alert is only for a device with no alert token.
		if withAlert && wants && r.d.Token == "" {
			alert = &payload.AlertText{Title: text.SessionName(s, all), Body: text.PhaseTitle(r.lang, phase)}
		}
		now := e.now()
		switch {
		case has:
			p := payload.ActivityParams{Event: "update", Now: now, State: cs, Alert: alert}
			if phase == "finished" {
				p.StaleAfter = time.Hour
			}
			b, err := payload.BuildActivity(p)
			if err != nil {
				continue
			}
			prio := 5
			if urgent {
				prio = 10
			}
			req := apns.Request{
				Env: act.Env, Token: act.Token, PushType: "liveactivity", Topic: e.opt.BundleID + ".push-type.liveactivity",
				Priority: prio, Expiration: now.Add(time.Hour), Payload: b,
			}
			client, name := r.d.Client, s.Name
			e.actThr.Do(client+"|"+name, urgent, func() { e.deliver(ctx, req, client, "activity", name, "update:"+phase) })
		case r.d.PushToStartToken != "" && (phase == "running" || phase == "waiting") && e.markStarted(r.d.Client+"|"+s.Name):
			e.deb.Do("start|"+r.d.Client+"|"+s.Name, e.opt.StartGrace, func() { e.pushToStart(ctx, r, s, phase, cs, all, locs) })
		}
	}
}

// pushToStart starts an activity on a device that has none for the session (checked again after the grace period).
func (e *Engine) pushToStart(ctx context.Context, r recipient, s boxapi.Session, phase string, cs payload.ContentState, all []boxapi.Session, locs []boxapi.Location) {
	for _, a := range e.st.ActivitiesFor(s.Name) {
		if a.Client == r.d.Client {
			e.log.Info("push-to-start skipped: the phone started its own", "session", s.Name)
			return
		}
	}
	if cur := e.snapshot(s.Name); stateOf(cur) == "exited" || stateOf(cur) == "finished" {
		// Over before the grace ended (a one-second answer): nothing to follow now, but a later, longer turn may start one.
		e.mu.Lock()
		delete(e.started, r.d.Client+"|"+s.Name)
		e.mu.Unlock()
		return
	}
	now := e.now()
	agent := text.AgentOf(s)
	var ag *string
	if agent != "" {
		ag = &agent
	}
	title := text.SessionName(s, all)
	project, wt := s.Location, ""
	if i := indexByte(project, '/'); i >= 0 {
		project, wt = project[:i], project[i+1:]
	}
	if project == "" {
		project = text.PlaceOf(r.lang, s, locs)
	}
	// Same shape as the app's own activities: "repo · worktree" unless the worktree is the title.
	if wt != "" && wt != project && wt != title {
		project += " · " + wt
	}
	b, err := payload.BuildActivity(payload.ActivityParams{
		Event: "start", Now: now, State: cs, AttributeType: "SessionActivityAttributes",
		Attributes: &payload.Attributes{Box: r.box, Session: s.Name, Title: title, Project: project, Agent: ag},
		Alert:      &payload.AlertText{Title: title, Body: text.PhaseTitle(r.lang, phase)},
	})
	if err != nil {
		return
	}
	req := apns.Request{
		Env: r.d.Env, Token: r.d.PushToStartToken, PushType: "liveactivity", Topic: e.opt.BundleID + ".push-type.liveactivity",
		Priority: 10, Expiration: now.Add(10 * time.Minute), Payload: b,
	}
	e.deliver(ctx, req, r.d.Client, "start", s.Name, "start:"+phase)
}

// markStarted is true the first time it is called for a key: one push-to-start per session and device, so an
// activity the person dismissed does not come back at every transition.
func (e *Engine) markStarted(key string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.started[key] {
		return false
	}
	e.started[key] = true
	return true
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func absDur(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}

// reloadWidgets asks each device with a widget token to reload its widgets, at most once per WidgetInterval.
func (e *Engine) reloadWidgets() {
	ctx := e.context()
	for _, r := range e.recipients() {
		if r.d.WidgetToken == "" {
			continue
		}
		d := r.d
		e.widgThr.Do("w|"+d.Client, false, func() {
			req := apns.Request{
				Env: d.Env, Token: d.WidgetToken, PushType: "widgets", Topic: e.opt.BundleID + ".push-type.widgets",
				Priority: 5, Expiration: e.now().Add(30 * time.Minute), Payload: payload.BuildWidget(),
			}
			e.deliver(ctx, req, d.Client, "widget", "", "reload")
		})
	}
}

func collapseID(session string) string {
	if len(session) <= 64 {
		return session
	}
	h := sha256.Sum256([]byte(session))
	return hex.EncodeToString(h[:16])
}

func (e *Engine) dispatchAlert(ctx context.Context, r recipient, session, what string, body []byte, prio int, ttl time.Duration) {
	req := apns.Request{
		Env: r.d.Env, Token: r.d.Token, PushType: "alert", Topic: e.opt.BundleID, Priority: prio,
		Expiration: e.now().Add(ttl), CollapseID: collapseID(session), Payload: body,
	}
	// The title says which kind went out (✅ done, ⏳ background, ✋ needs you): worth having in the journal.
	var p struct {
		APS struct {
			Alert struct{ Title string } `json:"alert"`
		} `json:"aps"`
	}
	if json.Unmarshal(body, &p) == nil {
		e.log.Info("alert", "session", session, "client", short(r.d.Client), "title", p.APS.Alert.Title)
	}
	e.deliver(ctx, req, r.d.Client, "device", session, what)
}

// deliver sends one request, logs APNs' answer and drops a token APNs says is dead. kind is device | widget |
// start | activity.
func (e *Engine) deliver(ctx context.Context, req apns.Request, client, kind, session, what string) apns.Result {
	log := e.log.With("push", req.PushType, "what", what, "kind", kind, "session", session, "env", req.Env, "token", short(req.Token), "client", short(client))
	res, err := e.send.Send(ctx, req)
	if err != nil {
		log.Error("apns send failed", "err", err)
		return res
	}
	if res.OK() {
		log.Info("apns accepted", "apns_id", res.APNsID)
		return res
	}
	log.Warn("apns rejected", "status", res.Status, "reason", res.Reason, "apns_id", res.APNsID)
	if res.Dead() {
		switch kind {
		case "activity":
			for _, a := range e.st.ActivitiesFor(session) {
				if a.Client == client && a.Token == req.Token {
					_ = e.st.DeleteActivity(a.Client, a.Box, a.Session)
				}
			}
		default:
			_ = e.st.DropDeviceToken(client, kind)
		}
		log.Warn("dropped dead token", "reason", res.Reason)
	}
	return res
}

func short(s string) string {
	if len(s) > 8 {
		return s[:8] + "…"
	}
	return s
}

// SendTest sends the test alert to one device and returns APNs' answer.
func (e *Engine) SendTest(ctx context.Context, d state.Device) (apns.Result, error) {
	r := recipient{d: d, lang: text.LangOf(d.Locale), box: e.boxNameFor(d)}
	title, body := text.TestAlert(r.lang, r.box)
	b, err := payload.BuildTest(r.box, title, body)
	if err != nil {
		return apns.Result{}, err
	}
	req := apns.Request{
		Env: d.Env, Token: d.Token, PushType: "alert", Topic: e.opt.BundleID, Priority: 10,
		Expiration: e.now().Add(10 * time.Minute), Payload: b,
	}
	res, err := e.send.Send(ctx, req)
	log := e.log.With("push", "alert", "what", "test", "env", d.Env, "token", short(d.Token), "client", short(d.Client))
	if err != nil {
		log.Error("apns send failed", "err", err)
		return res, err
	}
	if res.OK() {
		log.Info("apns accepted", "apns_id", res.APNsID)
	} else {
		log.Warn("apns rejected", "status", res.Status, "reason", res.Reason)
		if res.Dead() {
			_ = e.st.DropDeviceToken(d.Client, "device")
			log.Warn("dropped dead token", "reason", res.Reason)
		}
	}
	return res, nil
}
