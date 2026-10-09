package box

import (
	"net/http"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/pairing"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/wire"
)

// A paired client can ask the box for a pairing link for another device
// (POST /v1/pair/invite: the app shows it as a QR), and see and remove the
// clients the box trusts. A link minted here is the same as one `pierd pair`
// prints: single use, ten minutes, its code proven over the new device's
// own TLS session rather than sent. It is never logged or put in an event.

const (
	defaultInviteTTL = 10 * time.Minute
	// At most inviteBurst links per inviteWindow, from every client together:
	// enough for a person adding devices, not for minting codes in bulk.
	inviteBurst  = 10
	inviteWindow = 10 * time.Minute
)

// Invites lets paired clients mint pairing links. Leaving Box.Invites nil
// turns invites off.
type Invites struct {
	// Address is the address the link names: where pierd pair would
	// advertise.
	Address func() string
	// TTL is how long a code lasts; ten minutes when zero.
	TTL time.Duration
	Now func() time.Time

	mu     sync.Mutex
	recent []time.Time
}

func (i *Invites) now() time.Time {
	if i.Now != nil {
		return i.Now()
	}
	return time.Now()
}

// allow spends one of the window's invites, if any are left.
func (i *Invites) allow(now time.Time) bool {
	i.mu.Lock()
	defer i.mu.Unlock()
	live := i.recent[:0]
	for _, t := range i.recent {
		if now.Sub(t) < inviteWindow {
			live = append(live, t)
		}
	}
	i.recent = live
	if len(live) >= inviteBurst {
		return false
	}
	i.recent = append(i.recent, now)
	return true
}

// ClientInfo is one client the box trusts.
type ClientInfo struct {
	Name        string    `json:"name"`
	Fingerprint string    `json:"fingerprint"`
	PairedAt    time.Time `json:"paired_at"`
	// You marks the client asking.
	You bool `json:"you,omitempty"`
}

func (b *Box) mountPairing(s *wire.Server, route func(string, func(http.ResponseWriter, *http.Request) error)) {
	route("POST /v1/pair/invite", func(w http.ResponseWriter, r *http.Request) error { return b.invite(s, w, r) })
	route("GET /v1/clients", func(w http.ResponseWriter, r *http.Request) error { return b.listClients(s, w, r) })
	route("DELETE /v1/clients/{name}", func(w http.ResponseWriter, r *http.Request) error { return b.revokeClient(s, w, r) })
}

// PairInvite is POST /v1/pair/invite's answer: a pairing link for another
// device and when it stops working.
type PairInvite struct {
	Link    string    `json:"link"`
	Expires time.Time `json:"expires"`
}

func (b *Box) invite(s *wire.Server, w http.ResponseWriter, r *http.Request) error {
	var req struct {
		// For names the device being invited, for the gate and the event
		// only: the new device names itself when it pairs.
		For string `json:"for"`
	}
	if err := decodeOptional(r, &req, 4<<10); err != nil {
		return err
	}
	if !trust.ValidName(req.For) {
		req.For = ""
	}
	by := gateOrigin(r)
	if err := b.before(r, "pairing.invite", map[string]any{"for": req.For, "by": by}); err != nil {
		return err
	}
	if b.Invites == nil || s.Pending == nil || s.Identity == nil {
		return httpError{http.StatusNotImplemented, "this box does not make invites"}
	}
	address := ""
	if b.Invites.Address != nil {
		address = b.Invites.Address()
	}
	if address == "" {
		return httpError{http.StatusNotImplemented, "this box does not know the address to put in a link; run pierd pair --address on it"}
	}
	now := b.Invites.now()
	if !b.Invites.allow(now) {
		return httpError{http.StatusTooManyRequests, "too many invites from this box; try again in a few minutes"}
	}
	ttl := b.Invites.TTL
	if ttl <= 0 {
		ttl = defaultInviteTTL
	}
	code, err := s.Pending.Issue(ttl, now)
	if err != nil {
		return httpError{http.StatusInternalServerError, "could not store the pairing code: " + err.Error()}
	}
	out := PairInvite{
		Link:    pairing.Token{Address: address, Fingerprint: s.Identity.Fingerprint(), Code: code}.String(),
		Expires: now.Add(ttl).UTC().Truncate(time.Second),
	}
	// Never the link: events reach hooks and every paired client.
	b.publish(r, "pairing.invited", map[string]any{"for": req.For, "by": by, "expires": out.Expires})
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, out)
	return nil
}

func (b *Box) listClients(s *wire.Server, w http.ResponseWriter, r *http.Request) error {
	if s.Clients == nil {
		return httpError{http.StatusNotImplemented, "this box keeps no paired clients"}
	}
	peers, err := s.Clients.List()
	if err != nil {
		return httpError{http.StatusInternalServerError, err.Error()}
	}
	me := wire.PeerFrom(r.Context())
	out := make([]ClientInfo, 0, len(peers))
	for _, p := range peers {
		out = append(out, ClientInfo{
			Name:        p.Name,
			Fingerprint: p.Fingerprint.String(),
			PairedAt:    p.PairedAt,
			You:         !wire.IsLocal(r.Context()) && p.Fingerprint == me.Fingerprint,
		})
	}
	writeJSON(w, out)
	return nil
}

// revokeClient stops trusting a client, as pierd revoke does, and closes
// what it has open. A client may remove itself (the app does when it
// forgets the box): its connections then close a moment after the answer.
func (b *Box) revokeClient(s *wire.Server, w http.ResponseWriter, r *http.Request) error {
	if s.Clients == nil {
		return httpError{http.StatusNotImplemented, "this box keeps no paired clients"}
	}
	key := r.PathValue("name")
	peers, err := s.Clients.List()
	if err != nil {
		return httpError{http.StatusInternalServerError, err.Error()}
	}
	var target trust.Peer
	for _, p := range peers {
		if strings.EqualFold(p.Name, key) || p.Fingerprint.String() == key {
			target = p
			break
		}
	}
	if target.Name == "" {
		return httpError{http.StatusNotFound, trust.ErrNotFound.Error()}
	}
	data := map[string]any{"name": target.Name, "fingerprint": target.Fingerprint.String()}
	if err := b.before(r, "client.revoke", data); err != nil {
		return err
	}
	if _, err := s.Clients.Remove(target.Fingerprint.String()); err != nil {
		return err
	}
	if !wire.IsLocal(r.Context()) && target.Fingerprint == wire.PeerFrom(r.Context()).Fingerprint {
		// Closing its connections now would cut this answer short.
		time.AfterFunc(time.Second, s.ClientsChanged)
	} else {
		s.ClientsChanged()
	}
	b.publish(r, "client.revoked", data)
	writeJSON(w, map[string]string{"removed": target.Name})
	return nil
}
