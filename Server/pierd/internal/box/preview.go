package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/relay"
	"pier/pierd/internal/statefile"
)

// A worktree's preview: what its page is, recorded by whoever got it running
// (a setup agent, a task agent, a person) with `pierd preview set`: its port
// and path, the URL when the page is not on the box's port, a test login to
// sign in to it, a note. The app's Detalhes shows it with its public link: a
// preview with a port gets one by itself (unless the box or the location
// turned that off), under a name drawn once per worktree so its address
// never changes, for as long as a link may last, renewed while the worktree
// is there. Previews are kept in pierd's state folder (previews.json, 0600:
// they hold logins) and go with their worktree. Events about them never
// carry the login.

// PreviewLogin is a test login of the worktree's web app (a demo user its
// setup made), not anyone's real account.
type PreviewLogin struct {
	User     string `json:"user"`
	Password string `json:"password,omitempty"`
	Note     string `json:"note,omitempty"`
}

// PreviewTemplate is a location config's preview: what every worktree
// prepared by the setup script gets as its own, on its $PIER_PORT.
type PreviewTemplate struct {
	Path  string        `json:"path,omitempty"`
	Login *PreviewLogin `json:"login,omitempty"`
	Note  string        `json:"note,omitempty"`
}

// Preview is a worktree's preview (GET/PUT …/worktrees/{wt}/preview).
type Preview struct {
	// Port is where the page answers on the box: one of the worktree's own
	// ports, or one its processes listen on.
	Port int `json:"port,omitempty"`
	// Path is the page to open first ("/login", "/admin").
	Path string `json:"path,omitempty"`
	// URL is the page's own address, when it is not the box's port.
	URL   string        `json:"url,omitempty"`
	Login *PreviewLogin `json:"login,omitempty"`
	Note  string        `json:"note,omitempty"`
	// Updated is when it was last set.
	Updated *time.Time `json:"updated,omitempty"`
	// Share is the public link to its port, in answers only.
	Share *PreviewShare `json:"share,omitempty"`
}

// PreviewShare is a preview's public link.
type PreviewShare struct {
	Name    string    `json:"name"`
	URL     string    `json:"url"`
	Expires time.Time `json:"expires"`
	// Auto marks the link pierd made and renews for the preview itself.
	Auto bool `json:"auto,omitempty"`
}

func (p Preview) empty() bool {
	return p.Port == 0 && p.Path == "" && p.URL == "" && p.Login == nil && p.Note == ""
}

// previewEntry is one worktree's preview as kept, with the name its public
// link has, or will have: drawn once, so the link's address stays the same
// when it is made again.
type previewEntry struct {
	Preview
	ShareName string `json:"share_name,omitempty"`
	// ShareStopped: a person took the link down (DELETE /v1/shares). It
	// stays down until the preview names another port.
	ShareStopped bool `json:"share_stopped,omitempty"`
	// Detected: pierd found the page itself (detectPreviews), nobody
	// recorded it; it follows the worktree's dev server.
	Detected bool `json:"detected,omitempty"`
}

type previewStore struct {
	mu sync.Mutex
	// path is "" without a state folder: kept in memory only.
	path string
	all  map[string]previewEntry
	// failed is, for a worktree whose link could not be made, when to try
	// again: a relay is not asked every minute.
	failed map[string]time.Time
}

func (b *Box) previews() *previewStore {
	b.previewsOnce.Do(func() {
		st := &previewStore{all: map[string]previewEntry{}, failed: map[string]time.Time{}}
		if b.StateDir != "" {
			st.path = filepath.Join(b.StateDir, "previews.json")
			if data, err := os.ReadFile(st.path); err == nil {
				json.Unmarshal(data, &st.all)
			}
		}
		b.previewList = st
	})
	return b.previewList
}

// save writes the previews, mode 0600 (statefile.Write); st.mu is held.
func (st *previewStore) save() {
	if st.path == "" {
		return
	}
	for k, e := range st.all {
		e.Share = nil
		st.all[k] = e
	}
	data, _ := json.MarshalIndent(st.all, "", "  ")
	statefile.Write(st.path, append(data, '\n'))
}

func (st *previewStore) get(key string) (previewEntry, bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	e, ok := st.all[key]
	return e, ok
}

// Limits on what a preview holds: it is shown, never run.
const (
	maxPreviewText = 2000
	maxPreviewWord = 256
)

func (l *PreviewLogin) validate() error {
	l.User, l.Note = strings.TrimSpace(l.User), strings.TrimSpace(l.Note)
	if l.User == "" {
		return badRequest("a test login needs a user")
	}
	if len(l.User) > maxPreviewWord || len(l.Password) > maxPreviewWord || len(l.Note) > maxPreviewText {
		return badRequest("a test login's user and password are at most %d characters, its note %d", maxPreviewWord, maxPreviewText)
	}
	return nil
}

func validPreviewPath(p string) error {
	if p == "" {
		return nil
	}
	if !strings.HasPrefix(p, "/") || len(p) > 1024 || strings.ContainsAny(p, " \t\r\n") {
		return badRequest("the preview's path is the page's path on its server, such as /login")
	}
	return nil
}

func (t *PreviewTemplate) validate() error {
	t.Path, t.Note = strings.TrimSpace(t.Path), strings.TrimSpace(t.Note)
	if err := validPreviewPath(t.Path); err != nil {
		return err
	}
	if len(t.Note) > maxPreviewText {
		return badRequest("the preview's note is at most %d characters", maxPreviewText)
	}
	if t.Login != nil {
		return t.Login.validate()
	}
	return nil
}

// clean trims what a preview says and refuses what it cannot be.
func (p *Preview) clean() error {
	p.Path, p.URL, p.Note = strings.TrimSpace(p.Path), strings.TrimSpace(p.URL), strings.TrimSpace(p.Note)
	p.Share, p.Updated = nil, nil
	if p.Port < 0 || p.Port > 65535 {
		return badRequest("%d is not a port", p.Port)
	}
	if err := validPreviewPath(p.Path); err != nil {
		return err
	}
	if p.URL != "" {
		u, err := url.Parse(p.URL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || len(p.URL) > 2048 {
			return badRequest("the preview's URL must be an http or https address")
		}
	}
	if len(p.Note) > maxPreviewText {
		return badRequest("the preview's note is at most %d characters", maxPreviewText)
	}
	if p.Login != nil {
		if strings.TrimSpace(p.Login.User) == "" && p.Login.Password == "" {
			p.Login = nil
		} else if err := p.Login.validate(); err != nil {
			return err
		}
	}
	return nil
}

// GET /v1/locations/{name}/worktrees/{worktree}/preview: {} when nothing
// was recorded.
func (b *Box) getPreview(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	writeJSON(w, b.previewView(loc.Name, wt.Name))
	return nil
}

// PUT /v1/locations/{name}/worktrees/{worktree}/preview replaces it ({}
// clears it); a port makes or moves its public link.
func (b *Box) putPreview(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	var p Preview
	if err := decodeOptional(r, &p, 64<<10); err != nil {
		return err
	}
	if err := p.clean(); err != nil {
		return err
	}
	if p.Port > 0 && !b.shareablePort(r.Context(), loc, wt, p.Port) {
		return badRequest("port %d is not one of %s's: give its own port ($PIER_PORT…) or one its dev server listens on", p.Port, wt.Name)
	}
	if err := b.before(r, "preview.change", map[string]any{"location": loc.Name, "worktree": wt.Name, "port": p.Port}); err != nil {
		return err
	}
	b.setPreview(origin(r), loc.Name, wt, p)
	writeJSON(w, b.previewView(loc.Name, wt.Name))
	return nil
}

// setPreview records a worktree's preview, says so (preview.changed, with
// no login in it) and brings its public link in line, in the background:
// the relay may take seconds to answer.
func (b *Box) setPreview(from, location string, wt Worktree, p Preview) {
	b.recordPreview(from, location, wt, p, false)
}

func (b *Box) recordPreview(from, location string, wt Worktree, p Preview, detected bool) {
	key := prepKey(location, wt.Name)
	st := b.previews()
	st.mu.Lock()
	e := st.all[key]
	e.Detected = detected
	if !p.empty() {
		now := b.now().UTC()
		p.Updated = &now
	}
	if p.Port != e.Port {
		// Another page: it may have a link again.
		e.ShareStopped = false
	}
	e.Preview = p
	if p.empty() && e.ShareName == "" {
		delete(st.all, key)
	} else {
		st.all[key] = e
	}
	delete(st.failed, key)
	st.save()
	st.mu.Unlock()
	data := map[string]any{"location": location, "worktree": wt.Name, "path": wt.Path}
	if p.Port > 0 {
		data["port"] = p.Port
	}
	b.Events.Publish(events.Event{Type: "preview.changed", Box: b.Name, Origin: from, Data: data})
	go b.syncPreviewShare(context.Background(), location, wt.Name)
}

// previewView is a worktree's preview with its public link: the one pierd
// made for it, else any live link of the worktree to the same port.
func (b *Box) previewView(location, worktree string) Preview {
	e, ok := b.previews().get(prepKey(location, worktree))
	if !ok {
		return Preview{}
	}
	p := e.Preview
	if p.Port == 0 {
		return p
	}
	now := b.now()
	sh := b.shareStore()
	sh.mu.Lock()
	defer sh.mu.Unlock()
	for _, s := range sh.all {
		if s.Name == e.ShareName && e.ShareName != "" && now.Before(s.Expires) {
			p.Share = &PreviewShare{Name: s.Name, URL: s.URL, Expires: s.Expires, Auto: s.Auto}
			return p
		}
	}
	for _, s := range sh.all {
		if s.Location == location && s.Worktree == worktree && s.Port == p.Port && now.Before(s.Expires) {
			p.Share = &PreviewShare{Name: s.Name, URL: s.URL, Expires: s.Expires, Auto: s.Auto}
			return p
		}
	}
	return p
}

// shareDomain is the domain the box's relay publishes links on, as a link it
// made says ("example.com" for https://p-….example.com); "" before it made
// any, or without a relay.
func (b *Box) shareDomain() string {
	if b.Publisher == nil {
		return ""
	}
	sh := b.shareStore()
	sh.mu.Lock()
	defer sh.mu.Unlock()
	for _, s := range sh.all {
		u, err := url.Parse(s.URL)
		if err != nil {
			continue
		}
		if _, domain, ok := strings.Cut(u.Hostname(), "."); ok && strings.Contains(domain, ".") {
			return domain
		}
	}
	return ""
}

// autoShareFor says whether location's previews get public links by
// themselves: its own config's say, else the box's.
func (b *Box) autoShareFor(ctx context.Context, location string) bool {
	if cfg, err := b.Locations.Config(ctx, location); err == nil && cfg.Local.AutoShare != nil {
		return *cfg.Local.AutoShare
	}
	return b.Locations.Settings().autoShare()
}

// How long an automatic link lasts at a time (a link someone forgot about
// ends within a day of its worktree going quiet), when it is renewed, and
// how long a relay that could not make one is left alone: one that could not
// be reached, and one that serves no links.
const (
	autoShareFor     = defaultShareHours * time.Hour
	autoShareRenew   = 12 * time.Hour
	autoShareBackoff = 10 * time.Minute
	autoShareNoRelay = 6 * time.Hour
	// How often a worktree's dev servers are looked for (detectPreviews).
	previewDetectEvery = 10 * time.Second
)

// previewLocks keeps one sync of a worktree's link at a time, and its
// forgetting apart from them.
var previewLocks sync.Map // *Box + key → *sync.Mutex

type previewLockKey struct {
	b   *Box
	key string
}

func (b *Box) previewLock(key string) *sync.Mutex {
	m, _ := previewLocks.LoadOrStore(previewLockKey{b, key}, &sync.Mutex{})
	return m.(*sync.Mutex)
}

// syncPreviewShare makes the worktree's public link match its preview: made
// for its port (or moved to a new one) when the preview has a port and links
// are on, renewed for another day in its last twelve hours, taken down when
// they are off. A box without a relay, or whose relay serves no links, gets
// none and no error.
func (b *Box) syncPreviewShare(ctx context.Context, location, worktree string) {
	if b.Publisher == nil {
		return
	}
	key := prepKey(location, worktree)
	mu := b.previewLock(key)
	mu.Lock()
	defer mu.Unlock()

	ps := b.previews()
	e, ok := ps.get(key)
	if !ok {
		return
	}
	on := e.Port > 0 && !e.ShareStopped && b.autoShareFor(ctx, location)
	sh := b.shareStore()
	now := b.now().UTC()
	prefix := b.Publisher.SharePrefix()

	sh.mu.Lock()
	idx := -1
	for i, s := range sh.all {
		if e.ShareName != "" && s.Name == e.ShareName {
			idx = i
		}
	}
	// A name drawn under another key's prefix (the box's identity changed)
	// is one the relay no longer serves: that link is made again, under a
	// new name.
	current := idx >= 0 && strings.HasPrefix(e.ShareName, prefix)
	switch {
	case !on && idx >= 0:
		// Links are off now: the one made for the preview goes.
		gone := sh.all[idx]
		sh.all = append(sh.all[:idx], sh.all[idx+1:]...)
		sh.save()
		sh.mu.Unlock()
		b.Publisher.Unpublish(gone.Name)
		b.Events.Publish(eventf(b, "share.removed", map[string]any{"name": gone.Name, "location": location, "worktree": worktree}))
		return
	case !on:
		sh.mu.Unlock()
		return
	case current && sh.all[idx].Port == e.Port:
		if sh.all[idx].Expires.Sub(now) < autoShareRenew {
			sh.all[idx].Expires = now.Add(autoShareFor)
			sh.save()
		}
		sh.mu.Unlock()
		return
	}
	sh.mu.Unlock()

	ps.mu.Lock()
	if until, failed := ps.failed[key]; failed && now.Before(until) {
		ps.mu.Unlock()
		return
	}
	name := e.ShareName
	stale := ""
	if name == "" || !strings.HasPrefix(name, prefix) {
		// Drawn once and kept with the preview: the link's address stays
		// the same whenever it is made again, until the box's key changes.
		stale = name
		name = newShareName(prefix)
		if cur, ok := ps.all[key]; ok {
			cur.ShareName = name
			ps.all[key] = cur
			ps.save()
		}
	}
	ps.mu.Unlock()
	if stale != "" {
		b.Publisher.Unpublish(stale)
		if b.dropShare(stale) {
			b.Events.Publish(eventf(b, "share.removed", map[string]any{"name": stale, "location": location, "worktree": worktree}))
		}
	}

	// Moved to another port: published again under the same name.
	if current {
		b.Publisher.Unpublish(name)
	}
	link, err := b.Publisher.Publish(ctx, name, e.Port)
	if err != nil {
		b.Publisher.Unpublish(name)
		// The link to the old port is down too: not listed as if it were up.
		sh.mu.Lock()
		keep := sh.all[:0]
		for _, old := range sh.all {
			if old.Name != name {
				keep = append(keep, old)
			}
		}
		if len(keep) != len(sh.all) {
			sh.all = keep
			sh.save()
		} else {
			sh.all = keep
		}
		sh.mu.Unlock()
		// A relay that serves no links is asked again much later than one
		// that could not be reached (each ask can wait for its answer).
		wait := autoShareBackoff
		if errors.Is(err, relay.ErrNoShares) {
			wait = autoShareNoRelay
		}
		ps.mu.Lock()
		ps.failed[key] = now.Add(wait)
		ps.mu.Unlock()
		if !errors.Is(err, relay.ErrNoShares) {
			b.Events.Publish(eventf(b, "share.failed", map[string]any{"location": location, "worktree": worktree, "error": err.Error(), "auto": true}))
		}
		return
	}
	// Published while nothing could change the preview (its lock is held, and
	// forgetting a worktree takes it too), but checked again all the same:
	// a link for a preview that is gone or moved on is taken down at once.
	ps.mu.Lock()
	cur, still := ps.all[key]
	still = still && cur.ShareName == name && cur.Port == e.Port && !cur.ShareStopped
	ps.mu.Unlock()
	if !still {
		b.Publisher.Unpublish(name)
		return
	}
	s := Share{Name: name, URL: link, Location: location, Worktree: worktree, Port: e.Port, Created: now, Expires: now.Add(autoShareFor), Auto: true}
	sh.mu.Lock()
	keep := sh.all[:0]
	for _, old := range sh.all {
		if old.Name != name {
			keep = append(keep, old)
		}
	}
	sh.all = append(keep, s)
	sh.save()
	sh.mu.Unlock()
	b.Events.Publish(eventf(b, "share.created", map[string]any{"name": name, "url": link, "location": location, "worktree": worktree, "port": e.Port, "auto": true}))
}

// renewPreviewShares keeps every preview's link alive while its worktree is
// there (StartShares runs it every minute): renewed for another day in its
// last twelve hours, made again when it went missing (a relay that was
// down), taken down when links were turned off.
func (b *Box) renewPreviewShares(ctx context.Context) {
	if b.Publisher == nil {
		return
	}
	ps := b.previews()
	ps.mu.Lock()
	keys := make([]string, 0, len(ps.all))
	for k, e := range ps.all {
		if e.Port > 0 || e.ShareName != "" {
			keys = append(keys, k)
		}
	}
	ps.mu.Unlock()
	for _, k := range keys {
		location, worktree, _ := strings.Cut(k, "/")
		if _, _, err := b.worktreeRef(ctx, location, worktree); err != nil {
			// Gone without pierd (removed by hand): no renewal, so its link
			// ends when it expires.
			continue
		}
		b.syncPreviewShare(ctx, location, worktree)
	}
}

// detectPreviews gives a worktree whose dev server came up with no preview
// recorded (an agent that never ran `pierd preview set`) one of its own, so
// its page has a public link as soon as it answers: the first of its servers
// that speaks HTTP, its own port ($PIER_PORT) first, then the rest of its
// block, then any other it runs, lowest first. The relay reaches the page at
// 127.0.0.1, so a server that listens on localhost only is seen too, which
// the box's own address never shows. A preview found this way moves to
// another server once its own stops; one somebody recorded is left alone.
func (b *Box) detectPreviews(ctx context.Context) {
	if b.Publisher == nil {
		return
	}
	ports, err := ListPorts(ctx)
	if err != nil {
		return
	}
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return
	}
	services := b.withoutServers(Services(ports, locs))
	for _, loc := range locs {
		if !loc.Repo {
			continue
		}
		for _, wt := range loc.Worktrees {
			var listening []int
			for _, s := range services {
				if s.Location == loc.Name && s.Path == wt.Path {
					listening = append(listening, s.Port)
				}
			}
			if len(listening) == 0 {
				continue
			}
			e, ok := b.previews().get(prepKey(loc.Name, wt.Name))
			if ok && !e.Detected && !e.Preview.empty() {
				continue
			}
			ordered := previewPortOrder(listening, wt.Port)
			if ok && e.Detected && containsPort(ordered, e.Port) {
				continue
			}
			if !b.autoShareFor(ctx, loc.Name) {
				continue
			}
			for _, p := range ordered {
				if answersHTTP(ctx, p) {
					b.recordPreview(DefaultOrigin, loc.Name, wt, Preview{Port: p}, true)
					break
				}
			}
		}
	}
}

// previewPortOrder is the order a worktree's servers are tried in: its own
// port, then its block of ten, then the others, lowest first.
func previewPortOrder(ports []int, own int) []int {
	seen := map[int]bool{}
	var out []int
	for _, p := range ports {
		if p > 0 && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	rank := func(p int) int {
		switch {
		case own > 0 && p == own:
			return 0
		case own > 0 && p > own && p < own+portBlock:
			return 1
		}
		return 2
	}
	sort.Slice(out, func(i, j int) bool {
		if rank(out[i]) != rank(out[j]) {
			return rank(out[i]) < rank(out[j])
		}
		return out[i] < out[j]
	})
	return out
}

func containsPort(ports []int, p int) bool {
	for _, q := range ports {
		if q == p {
			return true
		}
	}
	return false
}

// answersHTTP says whether something on the box's port answers HTTP: a dev
// server, not a database or a debugger that only listens.
func answersHTTP(ctx context.Context, port int) bool {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/", port), nil)
	if err != nil {
		return false
	}
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// applyPreviewTemplate gives a worktree the location's preview (its config's
// "preview") once the setup script prepared it, on the worktree's own port,
// unless it already has one.
func (b *Box) applyPreviewTemplate(ctx context.Context, from string, loc Location, wt Worktree) {
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil || cfg.Effective.Preview == nil {
		return
	}
	if e, ok := b.previews().get(prepKey(loc.Name, wt.Name)); ok && !e.Preview.empty() {
		return
	}
	port := wt.Port
	if port == 0 {
		port, _ = b.Locations.Ports.For(wt.Path)
	}
	t := cfg.Effective.Preview
	p := Preview{Port: port, Path: t.Path, Note: t.Note}
	if t.Login != nil {
		l := *t.Login
		p.Login = &l
	}
	b.setPreview(from, loc.Name, wt, p)
}

// previewShareRemoved notes that a person took a preview's own link down:
// it is not made again by itself (syncPreviewShare).
func (b *Box) previewShareRemoved(name string) {
	ps := b.previews()
	ps.mu.Lock()
	defer ps.mu.Unlock()
	for k, e := range ps.all {
		if e.ShareName == name && !e.ShareStopped {
			e.ShareStopped = true
			ps.all[k] = e
			ps.save()
		}
	}
}

// forgetWorktree drops what pierd keeps about a worktree that went away
// (worktree "": every worktree of the location): its preview, its public
// links, how its preparation went. Each preview goes under its sync's lock,
// so a link being made for it is done (and then taken down here) or never
// made.
func (b *Box) forgetWorktree(location, worktree string) {
	ps := b.previews()
	ps.mu.Lock()
	var keys []string
	for k := range ps.all {
		l, w, _ := strings.Cut(k, "/")
		if l == location && (worktree == "" || w == worktree) {
			keys = append(keys, k)
		}
	}
	ps.mu.Unlock()
	for _, k := range keys {
		mu := b.previewLock(k)
		mu.Lock()
		ps.mu.Lock()
		delete(ps.all, k)
		delete(ps.failed, k)
		ps.save()
		ps.mu.Unlock()
		mu.Unlock()
	}
	b.dropShares(location, worktree)
	b.preps().forget(location, worktree, func(session string) { b.setupSessions.Delete(session) })
}
