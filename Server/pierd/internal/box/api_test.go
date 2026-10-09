package box

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/wire"
)

// servedPeers is the box each servedBox client talks to.
var servedPeers sync.Map

// peerOf is the box c was made for by servedBox.
func peerOf(c *wire.Client) trust.Peer {
	p, _ := servedPeers.Load(c)
	return p.(trust.Peer)
}

// servedBox runs pierd's server with the box routes mounted and returns a
// client for a laptop paired with it.
func servedBox(t *testing.T, opts ...func(*Box)) (*wire.Client, *events.Bus) {
	t.Helper()
	dir := t.TempDir()
	id, err := identity.LoadOrCreate(filepath.Join(dir, "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	srv := &wire.Server{
		Identity: id,
		Clients:  trust.NewStore(filepath.Join(dir, "clients.json")),
		Pending:  pairing.NewPending(filepath.Join(dir, "pairing.json")),
		Name:     "devbox",
	}
	sessions := testSessions(t)
	bus := &events.Bus{Sequence: true}
	units := &Units{Dir: filepath.Join(dir, "units")}
	units.svc, _ = fakeService() // never install a real unit from a test
	bx := &Box{Name: "devbox", Locations: NewLocations(filepath.Join(dir, "locations.json")), Sessions: sessions, Units: units, Events: bus}
	for _, opt := range opts {
		opt(bx)
	}
	bx.Mount(srv)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.Serve(ctx, ln)

	me, err := identity.LoadOrCreate(filepath.Join(t.TempDir(), "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	code, _ := srv.Pending.Issue(time.Minute, time.Now())
	tok := pairing.Token{Address: ln.Addr().String(), Fingerprint: id.Fingerprint(), Code: code}
	if _, err := wire.Pair(context.Background(), me, tok, "laptop"); err != nil {
		t.Fatal(err)
	}
	peer := trust.Peer{Name: "devbox", Address: tok.Address, Fingerprint: tok.Fingerprint}
	c := wire.NewClient(me, peer)
	servedPeers.Store(c, peer)
	t.Cleanup(c.Close)
	return c, bus
}

func call(t *testing.T, c *wire.Client, method, path, origin string, in, out any) int {
	t.Helper()
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	ctx := context.Background()
	req := func() (*http.Response, error) {
		if origin == "" {
			return c.DoWithHeader(ctx, method, path, body, nil)
		}
		return c.DoWithHeader(ctx, method, path, body, http.Header{OriginHeader: {origin}})
	}
	resp, err := req()
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

func TestLocationsWorktreesSessionsAndAttachOverTheWire(t *testing.T) {
	c, bus := servedBox(t)
	seen, stop := bus.Subscribe()
	defer stop()
	repo := gitRepo(t)

	var loc Location
	if status := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, &loc); status != 200 || !loc.Repo {
		t.Fatalf("add location: %d %+v", status, loc)
	}
	var wt Worktree
	if status := call(t, c, "POST", "/v1/locations/cal/worktrees", "orca", WorktreeRequest{Name: "billing"}, &wt); status != 200 || wt.Name != "billing" {
		t.Fatalf("add worktree: %d %+v", status, wt)
	}
	var sess Session
	if status := call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal/billing", "command": "cat"}, &sess); status != 200 {
		t.Fatalf("add session: %d", status)
	}
	if sess.Location != "cal/billing" || !strings.HasPrefix(sess.Name, "cal-billing-cat-") {
		t.Fatalf("session = %+v", sess)
	}

	// Type, then read the echo back from the screen.
	if status := call(t, c, "POST", "/v1/sessions/"+sess.Name+"/send", "", map[string]any{"text": "hello-over-the-wire"}, nil); status != 200 {
		t.Fatalf("send: %d", status)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		var screen struct{ Screen string }
		call(t, c, "GET", "/v1/sessions/"+sess.Name+"/screen", "", nil, &screen)
		if strings.Contains(screen.Screen, "hello-over-the-wire") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("keystrokes never came back; screen %q", screen.Screen)
		}
		time.Sleep(50 * time.Millisecond)
	}

	var all []Session
	call(t, c, "GET", "/v1/sessions", "", nil, &all)
	if len(all) != 1 || all[0].Exited {
		t.Fatalf("the session ended: %+v", all)
	}
	if status := call(t, c, "DELETE", "/v1/sessions/"+sess.Name, "", nil, nil); status != 200 {
		t.Fatalf("kill session: %d", status)
	}

	want := map[string]string{"location.added": "pier", "worktree.created": "orca", "session.started": "pier", "session.stopped": "pier"}
	deadline = time.Now().Add(3 * time.Second)
	for len(want) > 0 && time.Now().Before(deadline) {
		select {
		case e := <-seen:
			if origin, ok := want[e.Type]; ok {
				if e.Origin != origin || e.Box != "devbox" {
					t.Errorf("%s: origin %q box %q, want origin %q", e.Type, e.Origin, e.Box, origin)
				}
				delete(want, e.Type)
			}
		case <-time.After(100 * time.Millisecond):
		}
	}
	if len(want) > 0 {
		t.Fatalf("events never published: %v", want)
	}
}

func TestErrorsMapToStatuses(t *testing.T) {
	c, _ := servedBox(t)
	for _, tc := range []struct {
		method, path string
		body         any
		want         int
	}{
		{"DELETE", "/v1/locations/nope", nil, 404},
		{"POST", "/v1/sessions", map[string]string{"location": "nope"}, 404},
		{"DELETE", "/v1/shares/nope", nil, 404},
		{"POST", "/v1/events", map[string]string{"type": "Not An Event"}, 400},
		{"POST", "/v1/locations", "not an object", 400},
	} {
		if got := call(t, c, tc.method, tc.path, "", tc.body, nil); got != tc.want {
			t.Errorf("%s %s = %d, want %d", tc.method, tc.path, got, tc.want)
		}
	}
}

func TestEmittedEventsReachTheStream(t *testing.T) {
	c, _ := servedBox(t)
	resp, err := c.DoWithHeader(context.Background(), "GET", "/v1/events", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	lines := make(chan string, 8)
	go func() {
		s := bufio.NewScanner(resp.Body)
		for s.Scan() {
			lines <- s.Text()
		}
	}()
	time.Sleep(100 * time.Millisecond)
	if status := call(t, c, "POST", "/v1/events", "cursor", map[string]any{"type": "agent.finished", "data": map[string]any{"path": "/w"}}, nil); status != 200 {
		t.Fatalf("emit: %d", status)
	}
	select {
	case line := <-lines:
		var e events.Event
		json.Unmarshal([]byte(line), &e)
		if e.Type != "agent.finished" || e.Origin != "cursor" || e.Data["path"] != "/w" {
			t.Fatalf("streamed event = %+v", e)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("emitted event never reached the stream")
	}
}

// An app that kept its position from another journal (a box set up again,
// a migration without the journal) resumes from now, not after the box
// has published that many events.
func TestResumingPastTheEndStartsFromNow(t *testing.T) {
	c, _ := servedBox(t)
	call(t, c, "POST", "/v1/events", "", map[string]any{"type": "agent.ready", "data": map[string]any{"path": "/w"}}, nil)
	resp, err := c.DoWithHeader(context.Background(), "GET", "/v1/events?since=999999", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	lines := make(chan string, 8)
	go func() {
		s := bufio.NewScanner(resp.Body)
		for s.Scan() {
			lines <- s.Text()
		}
	}()
	time.Sleep(100 * time.Millisecond)
	call(t, c, "POST", "/v1/events", "", map[string]any{"type": "agent.finished", "data": map[string]any{"path": "/w"}}, nil)
	select {
	case line := <-lines:
		var e events.Event
		json.Unmarshal([]byte(line), &e)
		if e.Type != "agent.finished" {
			t.Fatalf("streamed event = %+v", e)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("a stream resumed past the end never got the new event")
	}
}

func TestEmptyListsAreArraysNotNull(t *testing.T) {
	rec := httptest.NewRecorder()
	var none []Service
	writeJSON(rec, none)
	if got := strings.TrimSpace(rec.Body.String()); got != "[]" {
		t.Fatalf("empty list = %s", got)
	}
}

func TestArchivingAnswersInJSONAndRemovalStopsTheWorktreesSessions(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	c, bus := servedBox(t)
	seen, stop := bus.Subscribe()
	defer stop()
	repo := gitRepo(t)
	if status := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil); status != 200 {
		t.Fatalf("add location: %d", status)
	}
	for _, name := range []string{"billing", "keep"} {
		if status := call(t, c, "POST", "/v1/locations/cal/worktrees", "", WorktreeRequest{Name: name}, nil); status != 200 {
			t.Fatalf("add worktree %s: %d", name, status)
		}
	}
	var in, other Session
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal/billing", "command": "cat"}, &in)
	call(t, c, "POST", "/v1/sessions", "", map[string]string{"location": "cal/keep", "command": "cat"}, &other)
	if status := call(t, c, "PUT", "/v1/locations/cal/config", "", map[string]any{"local": map[string]string{"archive": "true"}}, nil); status != 200 {
		t.Fatalf("set the archive script: %d", status)
	}

	resp, err := c.DoWithHeader(context.Background(), "DELETE", "/v1/locations/cal/worktrees/billing", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	// A 202 is still JSON: the app reads "archive" to know it is not gone yet.
	if resp.StatusCode != 202 || resp.Header.Get("Content-Type") != "application/json" || body["archive"] != "true" {
		t.Fatalf("archive answered %d %q %v", resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
	waitFor(t, seen, "worktree.removed")
	var all []Session
	call(t, c, "GET", "/v1/sessions", "", nil, &all)
	names := map[string]bool{}
	for _, s := range all {
		names[s.Name] = true
	}
	if names[in.Name] || !names[other.Name] {
		t.Fatalf("after removing billing, sessions = %v; want %s gone and %s kept", names, in.Name, other.Name)
	}
}

func TestHomeSessionStartsInTheUsersHomeAndNowhereElse(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	c, _ := servedBox(t)

	var sess Session
	if status := call(t, c, "POST", "/v1/sessions", "", map[string]any{"home": true, "command": "cat"}, &sess); status != 200 {
		t.Fatalf("add home session: %d", status)
	}
	if sess.Dir != home || sess.Location != "" || !strings.HasPrefix(sess.Name, "home-cat-") {
		t.Fatalf("session = %+v, want one in %s with no location", sess, home)
	}
	if sess.Agent != "" {
		t.Fatalf("a home shell is no agent: %+v", sess)
	}
	defer call(t, c, "DELETE", "/v1/sessions/"+sess.Name, "", nil, nil)

	// Home is the only folder it takes: no location beside it, no agent,
	// and the box's own info says it can.
	for _, body := range []map[string]any{
		{"home": true, "location": "cal"},
		{"home": true, "agent": "claude"},
		{"home": true, "prompt": "do it"},
	} {
		var e struct{ Error string }
		if status := call(t, c, "POST", "/v1/sessions", "", body, &e); status != 400 {
			t.Errorf("%v = %d (%s), want 400", body, status, e.Error)
		}
	}
	bx := &Box{Events: &events.Bus{}}
	if caps := strings.Join(bx.Capabilities(), " "); !strings.Contains(caps, "session.home") {
		t.Errorf("capabilities %q lack session.home", caps)
	}
}

// A client that leaves while its stream still replays the journal (a
// reconnect from far back, dropped at once) ends the stream cleanly: the
// cursor is closed only once its reader is done with it.
func TestAStreamClientThatLeavesMidReplayEndsCleanly(t *testing.T) {
	journal, err := events.OpenJournal(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	var bus *events.Bus
	c, _ := servedBox(t, func(b *Box) { bus = &events.Bus{Journal: journal}; b.Events = bus })
	for i := 0; i < 3000; i++ {
		bus.Publish(events.Event{Type: "agent.ready", Data: map[string]any{"path": "/w", "i": i}})
	}
	for round := 0; round < 10; round++ {
		resp, err := c.DoWithHeader(context.Background(), "GET", "/v1/events?since=1", nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Duration(round) * time.Millisecond)
		resp.Body.Close()
	}
	// Still serving, and still streaming.
	if st := call(t, c, "POST", "/v1/events", "", map[string]any{"type": "agent.finished", "data": map[string]any{"path": "/w"}}, nil); st != 200 {
		t.Fatalf("emit after the dropped streams = %d", st)
	}
}
