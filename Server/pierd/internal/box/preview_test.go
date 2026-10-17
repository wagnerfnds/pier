package box

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/wire"
)

// lockedPublisher is a relay that serves links, safe to call from the
// goroutines that make previews' links.
type lockedPublisher struct {
	mu        sync.Mutex
	published map[string]int
}

func (p *lockedPublisher) Publish(_ context.Context, name string, port int) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.published[name] = port
	return "https://p-" + name + ".example.test", nil
}

func (p *lockedPublisher) Unpublish(name string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.published, name)
}

func (p *lockedPublisher) SharePrefix() string { return "abcd2345" }

func (p *lockedPublisher) port(name string) (int, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	port, ok := p.published[name]
	return port, ok
}

// testClock is a clock a test moves by hand.
type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) add(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// previewBox is a served box with a location "cal" and its worktree "login"
// (made with only its code), whose first port is returned.
func previewBox(t *testing.T, opts ...func(*Box)) (c clientT, bx *Box, port int) {
	t.Helper()
	opts = append(opts, func(b *Box) {
		if b.StateDir == "" {
			b.StateDir = t.TempDir()
		}
		bx = b
	})
	wc, bus := servedBox(t, opts...)
	repo := gitRepo(t)
	if call(t, wc, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil) != 200 {
		t.Fatal("add location")
	}
	var wt Worktree
	if code := call(t, wc, "POST", "/v1/locations/cal/worktrees", "", map[string]any{"name": "login", "prepare_with": "none"}, &wt); code != 200 {
		t.Fatalf("create worktree = %d", code)
	}
	if wt.Port == 0 {
		t.Skip("no port block on this machine")
	}
	return clientT{wc, bus}, bx, wt.Port
}

// A preview is kept in a 0600 file (it holds a test login), its event never
// carries the login, a bad one is refused, it reads the same after a
// restart, and it goes with its worktree.
func TestPreviewIsKeptPrivatelyAndGoesWithItsWorktree(t *testing.T) {
	state := t.TempDir()
	c, bx, port := previewBox(t, func(b *Box) { b.StateDir = state })
	ch, stop := c.bus.Subscribe()
	defer stop()

	var p Preview
	if code := call(t, c.wc, "GET", "/v1/locations/cal/worktrees/login/preview", "", nil, &p); code != 200 || !p.empty() {
		t.Fatalf("a worktree without a preview = %d %+v", code, p)
	}
	in := Preview{Port: port, Path: "/login", Note: "seeded", Login: &PreviewLogin{User: "demo@example.com", Password: "s3cret-pw"}}
	if code := call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", in, &p); code != 200 {
		t.Fatalf("put = %d", code)
	}
	if p.Port != port || p.Path != "/login" || p.Login == nil || p.Login.Password != "s3cret-pw" || p.Updated == nil || p.Share != nil {
		t.Fatalf("preview = %+v", p)
	}
	e := waitFor(t, ch, "preview.changed")
	raw, _ := json.Marshal(e)
	if strings.Contains(string(raw), "s3cret-pw") || strings.Contains(string(raw), "demo@example.com") || e.Data["worktree"] != "login" {
		t.Fatalf("the event carries the login: %s", raw)
	}
	info, err := os.Stat(filepath.Join(state, "previews.json"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("previews.json = %v %v", info, err)
	}

	for name, bad := range map[string]Preview{
		"a port that is not the worktree's": {Port: 1},
		"a path that is no path":            {Path: "login"},
		"a login without a user":            {Login: &PreviewLogin{Password: "x"}},
		"a URL that is no web address":      {URL: "file:///etc/passwd"},
	} {
		if code := call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", bad, nil); code != http.StatusBadRequest {
			t.Errorf("%s gave %d", name, code)
		}
	}
	if code := call(t, c.wc, "GET", "/v1/locations/cal/worktrees/nope/preview", "", nil, nil); code != http.StatusNotFound {
		t.Errorf("an unknown worktree gave %d", code)
	}

	// pierd restarts: the same state folder, the same preview.
	again := &Box{Locations: bx.Locations, StateDir: state, Events: bx.Events}
	if got := again.previewView("cal", "login"); got.Port != port || got.Login == nil || got.Login.User != "demo@example.com" {
		t.Fatalf("after a restart = %+v", got)
	}

	if code := call(t, c.wc, "DELETE", "/v1/locations/cal/worktrees/login", "", nil, nil); code != 200 {
		t.Fatalf("remove = %d", code)
	}
	data, _ := os.ReadFile(filepath.Join(state, "previews.json"))
	if strings.Contains(string(data), "cal/login") {
		t.Fatalf("the removed worktree's preview is still kept: %s", data)
	}
}

// A preview with a port gets a public link by itself: named once for the
// worktree (the same address when its port changes or it is made again),
// for the longest a link lasts, renewed a day before it would expire, taken
// down when links are turned off, and gone with the worktree.
func TestPreviewsGetAStableLinkRenewedWhileTheWorktreeIsThere(t *testing.T) {
	pub := &lockedPublisher{published: map[string]int{}}
	clock := &testClock{now: time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)}
	c, bx, port := previewBox(t, func(b *Box) { b.Publisher = pub; b.clock = clock.Now })
	ch, stop := c.bus.Subscribe()
	defer stop()
	ctx := context.Background()

	view := func() Preview {
		var p Preview
		call(t, c.wc, "GET", "/v1/locations/cal/worktrees/login/preview", "", nil, &p)
		return p
	}
	call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", Preview{Port: port}, nil)
	if e := waitFor(t, ch, "share.created"); e.Data["auto"] != true {
		t.Fatalf("share.created = %+v", e.Data)
	}
	p := view()
	if p.Share == nil || !p.Share.Auto || !strings.HasPrefix(p.Share.Name, "abcd2345") || len(p.Share.Name) != 24 {
		t.Fatalf("the preview's link = %+v", p.Share)
	}
	name := p.Share.Name
	if !p.Share.Expires.Equal(clock.Now().Add(maxShareHours * time.Hour)) {
		t.Errorf("it lasts until %v", p.Share.Expires)
	}
	if got, ok := pub.port(name); !ok || got != port {
		t.Fatalf("published %d %v", got, ok)
	}

	// Another port of its block: the same link, moved.
	call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", Preview{Port: port + 1}, nil)
	waitFor(t, ch, "share.created")
	if p := view(); p.Share == nil || p.Share.Name != name {
		t.Fatalf("after moving = %+v", p.Share)
	}
	if got, _ := pub.port(name); got != port+1 {
		t.Fatalf("the link points at %d", got)
	}

	// Six days on, nothing to do; half a day more and it is renewed.
	expires := view().Share.Expires
	clock.add(6 * 24 * time.Hour)
	bx.renewPreviewShares(ctx)
	if p := view(); !p.Share.Expires.Equal(expires) {
		t.Fatalf("renewed too early: %v", p.Share.Expires)
	}
	clock.add(12 * time.Hour)
	bx.renewPreviewShares(ctx)
	if p := view(); p.Share == nil || !p.Share.Expires.Equal(clock.Now().Add(maxShareHours*time.Hour)) || p.Share.Name != name {
		t.Fatalf("not renewed: %+v", p.Share)
	}

	// Links turned off on the box: the next renewal takes it down.
	call(t, c.wc, "PUT", "/v1/settings", "", map[string]any{"auto_share": false}, nil)
	bx.renewPreviewShares(ctx)
	if p := view(); p.Share != nil {
		t.Fatalf("still public with links off: %+v", p.Share)
	}
	if _, ok := pub.port(name); ok {
		t.Fatal("still published on the relay")
	}
	// On again: the same address as before.
	call(t, c.wc, "PUT", "/v1/settings", "", map[string]any{"auto_share": true}, nil)
	bx.renewPreviewShares(ctx)
	if p := view(); p.Share == nil || p.Share.Name != name {
		t.Fatalf("made again as %+v, want %s", p.Share, name)
	}
	// A location can turn its own off.
	call(t, c.wc, "PUT", "/v1/locations/cal/config", "", map[string]any{"merge": map[string]any{"auto_share": false}}, nil)
	bx.renewPreviewShares(ctx)
	if p := view(); p.Share != nil {
		t.Fatalf("the location turned links off, yet %+v", p.Share)
	}
	call(t, c.wc, "PUT", "/v1/locations/cal/config", "", map[string]any{"merge": map[string]any{"auto_share": true}}, nil)
	bx.renewPreviewShares(ctx)
	if p := view(); p.Share == nil || p.Share.Name != name {
		t.Fatalf("on again for the location = %+v", p.Share)
	}

	// Taken down by hand: it stays down, even when the preview is set again
	// on the same port; another port brings it back.
	if code := call(t, c.wc, "DELETE", "/v1/shares/"+name, "", nil, nil); code != 200 {
		t.Fatalf("take down = %d", code)
	}
	call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", Preview{Port: port + 1, Note: "again"}, nil)
	waitFor(t, ch, "preview.changed")
	bx.renewPreviewShares(ctx)
	if p := view(); p.Share != nil {
		t.Fatalf("a link taken down came back: %+v", p.Share)
	}
	call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", Preview{Port: port + 2}, nil)
	waitFor(t, ch, "share.created")
	if p := view(); p.Share == nil || p.Share.Name != name {
		t.Fatalf("another port = %+v", p.Share)
	}

	// The worktree goes: its link goes with it.
	if code := call(t, c.wc, "DELETE", "/v1/locations/cal/worktrees/login", "", nil, nil); code != 200 {
		t.Fatalf("remove = %d", code)
	}
	if _, ok := pub.port(name); ok {
		t.Fatal("the removed worktree's link is still published")
	}
	var list []Share
	call(t, c.wc, "GET", "/v1/shares", "", nil, &list)
	if len(list) != 0 {
		t.Fatalf("shares = %+v", list)
	}
}

// Without a relay, a preview is recorded all the same: no link, no error.
func TestPreviewWithoutARelayHasNoLink(t *testing.T) {
	c, bx, port := previewBox(t)
	if code := call(t, c.wc, "PUT", "/v1/locations/cal/worktrees/login/preview", "", Preview{Port: port, Path: "/"}, nil); code != 200 {
		t.Fatalf("put = %d", code)
	}
	bx.renewPreviewShares(context.Background())
	if p := bx.previewView("cal", "login"); p.Share != nil || p.Port != port {
		t.Fatalf("preview = %+v", p)
	}
}

// A worktree prepared by the setup script gets the location's preview, on
// its own port, once the script is done.
func TestScriptPreparationGivesTheLocationsPreview(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	c, _, _ := previewBox(t, func(b *Box) { b.LogDir = t.TempDir() })
	ch, stop := c.bus.Subscribe()
	defer stop()
	recipe := map[string]any{"setup": "true", "preview": map[string]any{"path": "/admin", "login": map[string]any{"user": "admin@example.com", "password": "admin123"}}}
	if code := call(t, c.wc, "PUT", "/v1/locations/cal/config", "", map[string]any{"merge": recipe}, nil); code != 200 {
		t.Fatalf("merge = %d", code)
	}
	var wt Worktree
	if code := call(t, c.wc, "POST", "/v1/locations/cal/worktrees", "", map[string]any{"name": "next"}, &wt); code != 200 {
		t.Fatalf("create = %d", code)
	}
	waitFor(t, ch, "worktree.prepare.finished")
	var p Preview
	call(t, c.wc, "GET", "/v1/locations/cal/worktrees/next/preview", "", nil, &p)
	if p.Port != wt.Port || p.Path != "/admin" || p.Login == nil || p.Login.User != "admin@example.com" || p.Login.Password != "admin123" {
		t.Fatalf("preview = %+v (port %d)", p, wt.Port)
	}
}

// clientT is a served box's client and its bus.
type clientT struct {
	wc  *wire.Client
	bus *events.Bus
}
