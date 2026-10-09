package box

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pier/pierd/internal/hooks"
	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/wire"
)

// newLaptop is another device, with its own key and nothing paired.
func newLaptop(t *testing.T) *identity.Identity {
	t.Helper()
	id, err := identity.LoadOrCreate(filepath.Join(t.TempDir(), "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// mintInvite asks the box for a pairing link for another device.
func mintInvite(t *testing.T, c *wire.Client) (PairInvite, int) {
	t.Helper()
	var inv PairInvite
	status := call(t, c, "POST", "/v1/pair/invite", "", map[string]string{"for": "mac-mini"}, &inv)
	return inv, status
}

func linkToken(t *testing.T, inv PairInvite) pairing.Token {
	t.Helper()
	tok, err := pairing.ParseToken(inv.Link)
	if err != nil {
		t.Fatalf("link %q: %v", inv.Link, err)
	}
	return tok
}

func TestAPairedClientInvitesAnotherDeviceOnce(t *testing.T) {
	// The link names the address the box listens on, known once it serves.
	var addr string
	c, bus := servedBox(t, func(b *Box) { b.Invites = &Invites{Address: func() string { return addr }} })
	addr = peerOf(c).Address
	seen, stop := bus.Subscribe()
	defer stop()

	inv, status := mintInvite(t, c)
	if status != 200 {
		t.Fatalf("invite: %d", status)
	}
	if !strings.HasPrefix(inv.Link, "pier://") {
		t.Fatalf("link %q is not a pier:// link", inv.Link)
	}
	tok := linkToken(t, inv)
	if tok.Fingerprint != peerOf(c).Fingerprint || tok.Address != peerOf(c).Address {
		t.Fatalf("link = %+v, box %+v", tok, peerOf(c))
	}
	if left := time.Until(inv.Expires); left < 9*time.Minute || left > 10*time.Minute {
		t.Fatalf("invite expires in %s, want ten minutes", left)
	}

	// The event says who invited, never the link.
	select {
	case e := <-seen:
		b, _ := json.Marshal(e)
		if e.Type != "pairing.invited" || e.Data["for"] != "mac-mini" || strings.Contains(string(b), tok.Code.String()) {
			t.Fatalf("event = %s", b)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no pairing.invited event")
	}

	mini := newLaptop(t)
	if _, err := wire.Pair(context.Background(), mini, tok, "mac-mini"); err != nil {
		t.Fatalf("pairing with the invite: %v", err)
	}
	// Single use, even for the device it was meant for.
	if _, err := wire.Pair(context.Background(), newLaptop(t), tok, "thief"); err == nil {
		t.Fatal("a used code paired a second device")
	}

	// Both clients are trusted, and each sees which one it is.
	var clients []ClientInfo
	call(t, c, "GET", "/v1/clients", "", nil, &clients)
	if len(clients) != 2 || clients[0].Name != "laptop" || !clients[0].You || clients[1].Name != "mac-mini" || clients[1].You || clients[1].Fingerprint != mini.Fingerprint().String() {
		t.Fatalf("clients = %+v", clients)
	}
	mc := wire.NewClient(mini, peerOf(c))
	defer mc.Close()
	if _, err := mc.Ping(context.Background()); err != nil {
		t.Fatalf("the new device: %v", err)
	}
	if _, err := c.Ping(context.Background()); err != nil {
		t.Fatalf("the inviting client lost access: %v", err)
	}
}

func TestAnInviteExpires(t *testing.T) {
	c, _ := servedBox(t, func(b *Box) {
		b.Invites = &Invites{TTL: 50 * time.Millisecond, Address: func() string { return "127.0.0.1:1" }}
	})
	inv, status := mintInvite(t, c)
	if status != 200 {
		t.Fatalf("invite: %d", status)
	}
	time.Sleep(150 * time.Millisecond)
	tok := linkToken(t, inv)
	tok.Address = peerOf(c).Address
	if _, err := wire.Pair(context.Background(), newLaptop(t), tok, "late"); err == nil {
		t.Fatal("an expired code paired")
	}
}

func TestAGateCanRefuseInvites(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), "hooks.json")
	os.WriteFile(cfg, []byte(`{"hooks":[{"on":"before:pairing.invite","run":"echo no new devices; exit 1"}]}`), 0o600)
	invites := &Invites{Address: func() string { return "127.0.0.1:1" }}
	c, _ := servedBox(t, func(b *Box) { b.Invites = invites; b.Hooks = &hooks.Runner{Path: cfg} })
	var resp struct {
		Error string
		Code  string
		Link  string
	}
	if status := call(t, c, "POST", "/v1/pair/invite", "", nil, &resp); status != 403 || !strings.Contains(resp.Error, "no new devices") || resp.Code != CodeRefused || resp.Link != "" {
		t.Fatalf("refused invite: %d %+v", status, resp)
	}
	if len(invites.recent) != 0 {
		t.Fatal("a refused invite counted against the limit")
	}
}

func TestInvitesAreRateLimited(t *testing.T) {
	c, _ := servedBox(t, func(b *Box) { b.Invites = &Invites{Address: func() string { return "127.0.0.1:1" }} })
	for i := range inviteBurst {
		if _, status := mintInvite(t, c); status != 200 {
			t.Fatalf("invite %d: %d", i+1, status)
		}
	}
	if _, status := mintInvite(t, c); status != 429 {
		t.Fatalf("invite past the limit: %d, want 429", status)
	}
}

func TestABoxWithoutInvitesRefusesThem(t *testing.T) {
	c, _ := servedBox(t)
	if _, status := mintInvite(t, c); status != 501 {
		t.Fatalf("invite: %d, want 501", status)
	}
	c, _ = servedBox(t, func(b *Box) { b.Invites = &Invites{Address: func() string { return "" }} })
	if _, status := mintInvite(t, c); status != 501 {
		t.Fatalf("invite without an address: %d, want 501", status)
	}
}

func TestRemovingClients(t *testing.T) {
	c, bus := servedBox(t, func(b *Box) { b.Invites = &Invites{Address: func() string { return "127.0.0.1:1" }} })
	inv, _ := mintInvite(t, c)
	tok := linkToken(t, inv)
	tok.Address = peerOf(c).Address
	mini := newLaptop(t)
	if _, err := wire.Pair(context.Background(), mini, tok, "mac-mini"); err != nil {
		t.Fatal(err)
	}
	mc := wire.NewClient(mini, peerOf(c))
	defer mc.Close()

	var resp struct{ Error string }
	if status := call(t, c, "DELETE", "/v1/clients/nobody", "", nil, &resp); status != 404 {
		t.Fatalf("removing an unknown client: %d", status)
	}
	seen, stop := bus.Subscribe()
	defer stop()
	if status := call(t, c, "DELETE", "/v1/clients/mac-mini", "", nil, &resp); status != 200 {
		t.Fatalf("removing mac-mini: %d %q", status, resp.Error)
	}
	if e := <-seen; e.Type != "client.revoked" || e.Data["name"] != "mac-mini" {
		t.Fatalf("event = %+v", e)
	}
	if _, err := mc.Ping(context.Background()); !errors.Is(err, wire.ErrUntrusted) {
		t.Fatalf("removed client still answered: %v", err)
	}
	if _, err := c.Ping(context.Background()); err != nil {
		t.Fatalf("the client that removed it lost access: %v", err)
	}
	// The app forgets a box by removing itself: the answer arrives, then
	// the box no longer knows it.
	if status := call(t, c, "DELETE", "/v1/clients/laptop", "", nil, &resp); status != 200 {
		t.Fatalf("removing itself: %d %q", status, resp.Error)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		c.Close()
		if _, err := c.Ping(context.Background()); errors.Is(err, wire.ErrUntrusted) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a client that removed itself is still trusted")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// The app sends an invite (and an inbox send) with no body; over HTTP/2 such a request can say its length is unknown
// (-1). An empty body is no options, not a bad request.
func TestAnOptionalBodyMayBeLeftOut(t *testing.T) {
	for _, tc := range []struct {
		body    string
		length  int64
		want    string
		wantErr bool
	}{
		{"", -1, "", false},
		{"", 0, "", false},
		{" \n", -1, "", false},
		{"{}", -1, "", false},
		{`{"for":"ipad"}`, -1, "ipad", false},
		{"{", -1, "", true},
	} {
		r := httptest.NewRequest("POST", "/v1/pair/invite", strings.NewReader(tc.body))
		r.ContentLength = tc.length
		var req struct {
			For string `json:"for"`
		}
		err := decodeOptional(r, &req, 4<<10)
		if (err != nil) != tc.wantErr || req.For != tc.want {
			t.Errorf("body %q (length %d): for=%q err=%v", tc.body, tc.length, req.For, err)
		}
	}
}
