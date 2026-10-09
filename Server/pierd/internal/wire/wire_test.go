package wire

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/trust"
)

type box struct {
	server   *Server
	address  string
	dir      string
	accepted *atomic.Int32
}

// countingListener records how many TCP connections the box accepts, to prove
// that streams share one connection.
type countingListener struct {
	net.Listener
	n *atomic.Int32
}

func (l countingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		l.n.Add(1)
	}
	return c, err
}

func startBox(t *testing.T) *box { return startBoxWith(t, nil) }

func startBoxWith(t *testing.T, configure func(*Server)) *box {
	t.Helper()
	dir := t.TempDir()
	id, err := identity.LoadOrCreate(filepath.Join(dir, "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{
		Identity: id,
		Clients:  trust.NewStore(filepath.Join(dir, "clients.json")),
		Pending:  pairing.NewPending(filepath.Join(dir, "pairing.json")),
		Name:     "dev-test",
	}
	if configure != nil {
		configure(s)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	accepted := new(atomic.Int32)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx, countingListener{ln, accepted}) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("Serve: %v", err)
		}
	})
	return &box{server: s, address: ln.Addr().String(), dir: dir, accepted: accepted}
}

func (b *box) issue(t *testing.T) pairing.Token {
	t.Helper()
	code, err := b.server.Pending.Issue(10*time.Minute, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return pairing.Token{Address: b.address, Fingerprint: b.server.Identity.Fingerprint(), Code: code}
}

func (b *box) peer() trust.Peer {
	return trust.Peer{Name: "dev-test", Address: b.address, Fingerprint: b.server.Identity.Fingerprint()}
}

func laptop(t *testing.T) *identity.Identity {
	t.Helper()
	id, err := identity.LoadOrCreate(filepath.Join(t.TempDir(), "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// paired returns a client for a laptop that has completed pairing with b.
func paired(t *testing.T, b *box) *Client {
	t.Helper()
	me := laptop(t)
	if _, err := Pair(context.Background(), me, b.issue(t), "alex-mbp"); err != nil {
		t.Fatal(err)
	}
	c := NewClient(me, b.peer())
	t.Cleanup(c.Close)
	return c
}

func TestPairThenPing(t *testing.T) {
	b := startBox(t)
	me := laptop(t)
	c := NewClient(me, b.peer())
	defer c.Close()
	if _, err := c.Ping(context.Background()); !errors.Is(err, ErrUntrusted) {
		t.Fatalf("unpaired ping: %v, want ErrUntrusted", err)
	}
	name, err := Pair(context.Background(), me, b.issue(t), "alex-mbp")
	if err != nil {
		t.Fatal(err)
	}
	if name != "dev-test" {
		t.Fatalf("box reported name %q", name)
	}
	client, ok, err := b.server.Clients.Trusted(me.Fingerprint())
	if err != nil || !ok || client.Name != "alex-mbp" {
		t.Fatalf("box did not pin the laptop: %+v %v %v", client, ok, err)
	}
	if got, err := c.Ping(context.Background()); err != nil || got != "dev-test" {
		t.Fatalf("paired ping = %q, %v", got, err)
	}
}

func TestAWrongCodeIsRejectedAndLeavesTheRealCodeUsable(t *testing.T) {
	b := startBox(t)
	tok := b.issue(t)
	forged := tok
	forged.Code[0] ^= 1
	attacker := laptop(t)
	if _, err := Pair(context.Background(), attacker, forged, "attacker"); err == nil {
		t.Fatal("a wrong code paired")
	}
	if _, ok, _ := b.server.Clients.Trusted(attacker.Fingerprint()); ok {
		t.Fatal("a rejected laptop was pinned")
	}
	if _, err := Pair(context.Background(), laptop(t), tok, "alex-mbp"); err != nil {
		t.Fatalf("a failed guess burned the real code: %v", err)
	}
}

func TestACodeCannotBeUsedTwice(t *testing.T) {
	b := startBox(t)
	tok := b.issue(t)
	if _, err := Pair(context.Background(), laptop(t), tok, "first"); err != nil {
		t.Fatal(err)
	}
	second := laptop(t)
	if _, err := Pair(context.Background(), second, tok, "second"); err == nil {
		t.Fatal("a used code paired a second laptop")
	}
	if _, ok, _ := b.server.Clients.Trusted(second.Fingerprint()); ok {
		t.Fatal("the second laptop was pinned")
	}
}

func TestAnExpiredCodeIsRejected(t *testing.T) {
	b := startBox(t)
	tok := b.issue(t)
	b.server.Now = func() time.Time { return time.Now().Add(11 * time.Minute) }
	if _, err := Pair(context.Background(), laptop(t), tok, "late"); err == nil {
		t.Fatal("an expired code paired")
	}
}

func TestLaptopRefusesABoxPresentingAnotherKey(t *testing.T) {
	real := startBox(t)
	impostor := startBox(t)
	tok := real.issue(t)
	tok.Address = impostor.address
	_, err := Pair(context.Background(), laptop(t), tok, "alex-mbp")
	if err == nil || !strings.Contains(err.Error(), "does not match its pairing") {
		t.Fatalf("pairing with an impostor: %v", err)
	}
	tok.Address = real.address
	if _, err := Pair(context.Background(), laptop(t), tok, "alex-mbp"); err != nil {
		t.Fatalf("the code was spent on the impostor: %v", err)
	}
	// An established client refuses an impostor too.
	me := laptop(t)
	if _, err := Pair(context.Background(), me, real.issue(t), "x"); err != nil {
		t.Fatal(err)
	}
	peer := real.peer()
	peer.Address = impostor.address
	c := NewClient(me, peer)
	defer c.Close()
	if _, err := c.Ping(context.Background()); err == nil || !strings.Contains(err.Error(), "does not match its pairing") {
		t.Fatalf("client pinged an impostor: %v", err)
	}
}

func exporterOf(t *testing.T, conn *tls.Conn) []byte {
	t.Helper()
	cs := conn.ConnectionState()
	exporter, err := cs.ExportKeyingMaterial(pairing.ExporterLabel, nil, pairing.ExporterSize)
	if err != nil {
		t.Fatal(err)
	}
	return exporter
}

// rawPair sends an arbitrary proof as id, for building attacks the real
// client would never produce.
func rawPair(t *testing.T, id *identity.Identity, b *box, proof func(exporter []byte) []byte) (int, errorResponse) {
	t.Helper()
	cfg := clientConfig(id, b.server.Identity.Fingerprint())
	cfg.NextProtos = []string{"http/1.1"}
	conn, err := dialTLS(context.Background(), cfg, b.address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	body, _ := json.Marshal(pairRequest{Name: "raw", Proof: proof(exporterOf(t, conn))})
	resp, err := exchange(context.Background(), conn, b.address, "/v1/pair", body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var e errorResponse
	json.NewDecoder(resp.Body).Decode(&e)
	return resp.StatusCode, e
}

func TestAProofReplayedOnAnotherConnectionIsRejected(t *testing.T) {
	b := startBox(t)
	tok := b.issue(t)
	me := laptop(t)
	cfg := clientConfig(me, tok.Fingerprint)
	cfg.NextProtos = []string{"http/1.1"}
	conn, err := dialTLS(context.Background(), cfg, b.address)
	if err != nil {
		t.Fatal(err)
	}
	captured := pairing.Proof(tok.Code, exporterOf(t, conn), me.Fingerprint())
	conn.Close()
	if status, _ := rawPair(t, me, b, func([]byte) []byte { return captured }); status == http.StatusOK {
		t.Fatal("a proof from another session was accepted")
	}
}

func TestAProofForAnotherKeyIsRejected(t *testing.T) {
	b := startBox(t)
	tok := b.issue(t)
	victim := laptop(t)
	attacker := laptop(t)
	status, _ := rawPair(t, attacker, b, func(exporter []byte) []byte {
		return pairing.Proof(tok.Code, exporter, victim.Fingerprint())
	})
	if status == http.StatusOK {
		t.Fatal("a proof naming another key pinned the presenting key")
	}
	if _, ok, _ := b.server.Clients.Trusted(attacker.Fingerprint()); ok {
		t.Fatal("attacker was pinned")
	}
}

func TestRejectionsDoNotRevealWhy(t *testing.T) {
	b := startBox(t)
	used := b.issue(t)
	if _, err := Pair(context.Background(), laptop(t), used, "first"); err != nil {
		t.Fatal(err)
	}
	var wrong pairing.Code
	for name, proof := range map[string]func([]byte) []byte{
		"used code": func(e []byte) []byte { return pairing.Proof(used.Code, e, identity.Fingerprint{}) },
		"unknown":   func(e []byte) []byte { return pairing.Proof(wrong, e, identity.Fingerprint{}) },
		"no proof":  func([]byte) []byte { return nil },
	} {
		status, e := rawPair(t, laptop(t), b, proof)
		if status != http.StatusForbidden || e.Error != errPairingRejected {
			t.Fatalf("%s: got %d %+v, want the generic rejection", name, status, e)
		}
	}
}

func TestPairingAttemptsAreRateLimited(t *testing.T) {
	b := startBox(t)
	var limited bool
	for range 15 {
		status, _ := rawPair(t, laptop(t), b, func([]byte) []byte { return nil })
		if status == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("15 rapid pairing attempts were never rate limited")
	}
	b.server.pairLimit = newPairLimiter()
	c := paired(t, b)
	b.server.pairLimit = &pairLimiter{perIP: map[string]*limiter{}, global: newLimiter(0, 0), maxPeers: 1}
	if _, err := c.Ping(context.Background()); err != nil {
		t.Fatalf("an exhausted pairing limit blocked a paired laptop: %v", err)
	}
}

// One source's failures must not lock out another, and successful pairings
// are not charged (security audit L-7).
func TestPairingLimitIsPerSourceAndChargesOnlyFailures(t *testing.T) {
	now := time.Now()
	p := newPairLimiter()
	for range 10 {
		if !p.allow("100.64.0.9", now) {
			t.Fatal("limited before the burst was spent")
		}
	}
	if p.allow("100.64.0.9", now) {
		t.Fatal("a noisy source was never limited")
	}
	if !p.allow("100.64.0.2", now) {
		t.Fatal("one source's failures locked out another")
	}
	// Successes are refunded: any number of them never runs a source dry.
	for range 50 {
		if !p.allow("100.64.0.3", now) {
			t.Fatal("successful pairings were charged")
		}
		p.refund("100.64.0.3")
	}
	// The global backstop still bounds many sources together.
	limited := false
	for i := range 200 {
		if !p.allow(fmt.Sprintf("10.0.%d.%d", i/250, i%250), now) {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("no global backstop")
	}
}

// Ten bogus attempts from one peer must not stop the owner pairing with a
// real code (the audit's PoC TestPairingLockout).
func TestBogusAttemptsDoNotLockOutTheOwner(t *testing.T) {
	b := startBox(t)
	for range 10 {
		rawPair(t, laptop(t), b, func([]byte) []byte { return nil })
	}
	// Both come from 127.0.0.1 here, so give the owner its own source the
	// way a second machine would have.
	b.server.pairLimit.mu.Lock()
	delete(b.server.pairLimit.perIP, "127.0.0.1")
	b.server.pairLimit.mu.Unlock()
	if _, err := Pair(context.Background(), laptop(t), b.issue(t), "owner"); err != nil {
		t.Fatalf("owner pairing after bogus attempts: %v", err)
	}
}

// A failed attempt with no code pending must not rewrite pairing.json.
func TestFailedPairingWithNothingPendingWritesNothing(t *testing.T) {
	b := startBox(t)
	rawPair(t, laptop(t), b, func([]byte) []byte { return nil })
	if _, err := os.Stat(filepath.Join(b.dir, "pairing.json")); !os.IsNotExist(err) {
		t.Fatalf("pairing.json written for a stranger: %v", err)
	}
}

// Revoking a laptop ends the streams it already has open (security audit
// L-2; the audit's PoC TestRevokeKeepsOpenStreams).
func testRevokeClosesOpenStreams(t *testing.T, every time.Duration, tell bool) {
	b := startBoxWith(t, func(s *Server) { s.RevokeCheck = every })
	// A stream like GET /v1/events: a line now and then until it ends.
	b.server.Handle("GET /v1/stream", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rc := http.NewResponseController(w)
		for {
			if _, err := w.Write([]byte("tick\n")); err != nil || rc.Flush() != nil {
				return
			}
			select {
			case <-r.Context().Done():
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}))
	c := paired(t, b)
	resp, err := c.DoWithHeader(context.Background(), http.MethodGet, "/v1/stream", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := make([]byte, 5)
	if _, err := io.ReadFull(resp.Body, buf); err != nil {
		t.Fatal(err)
	}
	if _, err := b.server.Clients.Remove("alex-mbp"); err != nil {
		t.Fatal(err)
	}
	if tell {
		b.server.ClientsChanged()
	}
	ended := make(chan error, 1)
	go func() {
		_, err := io.Copy(io.Discard, resp.Body)
		ended <- err
	}()
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("revoked client's stream was left open")
	}
}

func TestRevokeClosesOpenStreams(t *testing.T) {
	// The daemon looks on its own, and pierd revoke tells it at once.
	t.Run("noticed", func(t *testing.T) {
		testRevokeClosesOpenStreams(t, 50*time.Millisecond, false)
	})
	t.Run("told", func(t *testing.T) {
		testRevokeClosesOpenStreams(t, time.Hour, true)
	})
}

func TestRevokedLaptopCanNoLongerPing(t *testing.T) {
	b := startBox(t)
	c := paired(t, b)
	if _, err := b.server.Clients.Remove("alex-mbp"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Ping(context.Background()); !errors.Is(err, ErrUntrusted) {
		t.Fatalf("revoked laptop ping: %v", err)
	}
}

func TestAnUnreadableTrustStoreAuthorizesNobody(t *testing.T) {
	b := startBox(t)
	c := paired(t, b)
	if err := os.WriteFile(filepath.Join(b.dir, "clients.json"), []byte("{corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Ping(context.Background()); !errors.Is(err, ErrUntrusted) {
		t.Fatalf("a corrupt trust store still authorized a laptop: %v", err)
	}
}

func TestOversizedPairingBodyIsRejectedAndTheServerKeepsServing(t *testing.T) {
	b := startBox(t)
	me := laptop(t)
	cfg := clientConfig(me, b.server.Identity.Fingerprint())
	cfg.NextProtos = []string{"http/1.1"}
	conn, err := dialTLS(context.Background(), cfg, b.address)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := exchange(context.Background(), conn, b.address, "/v1/pair", bytes.Repeat([]byte("a"), maxPairBody*4))
	if err == nil {
		if resp.StatusCode == http.StatusOK {
			t.Fatal("an oversized pairing request succeeded")
		}
		resp.Body.Close()
	}
	conn.Close()
	if _, err := Pair(context.Background(), me, b.issue(t), "alex-mbp"); err != nil {
		t.Fatalf("server stopped serving after an oversized request: %v", err)
	}
}

func TestAClientWithoutACertificateGetsNoReply(t *testing.T) {
	b := startBox(t)
	transport := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS13}}
	defer transport.CloseIdleConnections()
	resp, err := (&http.Client{Transport: transport, Timeout: 5 * time.Second}).Get("https://" + b.address + "/v1/ping")
	if err == nil {
		resp.Body.Close()
		t.Fatalf("a certificate-less client got %s", resp.Status)
	}
}

func TestHandleRoutesRequireAPairedLaptopAndSeeWhoItIs(t *testing.T) {
	b := startBox(t)
	b.server.Handle("GET /v1/whoami", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, nameResponse{Name: PeerFrom(r.Context()).Name})
	}))
	stranger := NewClient(laptop(t), b.peer())
	defer stranger.Close()
	if _, err := stranger.DoWithHeader(context.Background(), http.MethodGet, "/v1/whoami", nil, nil); !errors.Is(err, ErrUntrusted) {
		t.Fatalf("unpaired laptop reached a mounted route: %v", err)
	}
	c := paired(t, b)
	resp, err := c.DoWithHeader(context.Background(), http.MethodGet, "/v1/whoami", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out nameResponse
	json.NewDecoder(resp.Body).Decode(&out)
	if out.Name != "alex-mbp" {
		t.Fatalf("route saw peer %q, want alex-mbp", out.Name)
	}
}

func TestServeLocalOffersMountedRoutesButNotStreamsOrPairing(t *testing.T) {
	b := startBox(t)
	b.server.Handle("GET /v1/whoami", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, nameResponse{Name: PeerFrom(r.Context()).Name})
	}))
	dir, err := os.MkdirTemp("/tmp", "cpw")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "d.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.server.ServeLocal(ctx, ln)
	client := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", sock)
	}}}
	resp, err := client.Get("http://box/v1/whoami")
	if err != nil {
		t.Fatal(err)
	}
	var out nameResponse
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	if out.Name != "local" {
		t.Fatalf("local caller seen as %q", out.Name)
	}
	b.server.Handle("GET /v1/islocal", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, IsLocal(r.Context()))
	}))
	if resp, err := client.Get("http://box/v1/islocal"); err != nil {
		t.Fatal(err)
	} else {
		var local bool
		json.NewDecoder(resp.Body).Decode(&local)
		resp.Body.Close()
		if !local {
			t.Fatal("the box's own socket is not IsLocal")
		}
	}
	for _, path := range []string{"/v1/tcp?port=1", "/v1/pair"} {
		resp, err := client.Post("http://box"+path, "application/json", strings.NewReader("{}"))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s over the local socket: %s, want 404", path, resp.Status)
		}
	}
}

// A laptop that asks to pair as "local" is renamed, and is never IsLocal
// (security audit I-5).
func TestALaptopCannotPairAsLocal(t *testing.T) {
	b := startBox(t)
	b.server.Handle("GET /v1/whoami", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"name": PeerFrom(r.Context()).Name, "local": IsLocal(r.Context())})
	}))
	me := laptop(t)
	if _, err := Pair(context.Background(), me, b.issue(t), "local"); err != nil {
		t.Fatal(err)
	}
	c := NewClient(me, b.peer())
	defer c.Close()
	resp, err := c.DoWithHeader(context.Background(), http.MethodGet, "/v1/whoami", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Name  string
		Local bool
	}
	json.NewDecoder(resp.Body).Decode(&out)
	if out.Name == "local" || out.Local {
		t.Fatalf("remote laptop seen as %+v", out)
	}
}

// A listener with NoPairing (the push port) answers paired clients but takes
// no pairing: the box has one place to pair, behind one rate limit.
func TestAListenerWithoutPairingStillServesPairedClients(t *testing.T) {
	b := startBoxWith(t, func(s *Server) { s.NoPairing = true })
	me := laptop(t)
	if _, err := Pair(context.Background(), me, b.issue(t), "alex-mbp"); !errors.Is(err, ErrPairingRefused) {
		t.Fatalf("pairing on a NoPairing listener: %v, want %v", err, ErrPairingRefused)
	}
	// Pinned by hand, as pairing on the box's own listener would have
	// done, the laptop is served here.
	if err := b.server.Clients.Add(trust.Peer{Name: "alex-mbp", Fingerprint: me.Fingerprint(), PairedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	c := NewClient(me, b.peer())
	defer c.Close()
	if name, err := c.Ping(context.Background()); err != nil || name != "dev-test" {
		t.Fatalf("ping = %q, %v", name, err)
	}
}
