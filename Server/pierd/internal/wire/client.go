package wire

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/trust"
)

// The client side of the protocol, as the app speaks it: pairing over its
// own HTTP/1.1 connection, then authenticated requests over a pooled HTTP/2
// connection pinned to the box's key. pierd uses it for `pierd client`
// (scripts/smoke.sh) and in tests.

const dialTimeout = 15 * time.Second

// ErrPairingRefused means the box answered and refused the code: used,
// expired, or never issued by it.
var ErrPairingRefused = errors.New("box refused pairing: the link may be expired, already used, or for another box; run `pierd pair` for a new one")

// ErrStopping means the box answered that it is on its way down.
var ErrStopping = errors.New("the box is stopping")

// ErrUntrusted means the box answered but no longer trusts this client.
var ErrUntrusted = errors.New("box no longer trusts this client; pair again")

// Pair proves to the box that this client holds tok's code, and returns the
// name the box reports for itself. The code never leaves the client.
//
// Pairing uses its own HTTP/1.1 connection so the proof can be bound to that
// exact TLS session; a pooled HTTP/2 connection would hide which session a
// request travels on.
func Pair(ctx context.Context, id *identity.Identity, tok pairing.Token, clientName string) (string, error) {
	cfg := clientConfig(id, tok.Fingerprint)
	cfg.NextProtos = []string{"http/1.1"}
	conn, err := dialTLS(ctx, cfg, tok.Address)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	cs := conn.ConnectionState()
	exporter, err := cs.ExportKeyingMaterial(pairing.ExporterLabel, nil, pairing.ExporterSize)
	if err != nil {
		return "", err
	}
	body, _ := json.Marshal(pairRequest{Name: clientName, Proof: pairing.Proof(tok.Code, exporter, id.Fingerprint())})
	resp, err := exchange(ctx, conn, tok.Address, "/v1/pair", body)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		var out nameResponse
		if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&out); err != nil {
			return "", fmt.Errorf("reading reply: %w", err)
		}
		return out.Name, nil
	case http.StatusTooManyRequests:
		return "", errors.New(errTooManyPairings)
	default:
		return "", ErrPairingRefused
	}
}

func exchange(ctx context.Context, conn *tls.Conn, address, path string, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+address+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if err := req.Write(conn); err != nil {
		return nil, err
	}
	return http.ReadResponse(bufio.NewReader(conn), req)
}

func dialTLS(ctx context.Context, cfg *tls.Config, address string) (*tls.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	raw, err := (&net.Dialer{Timeout: dialTimeout}).DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}
	tc := tls.Client(raw, cfg)
	tc.SetDeadline(time.Now().Add(dialTimeout))
	if err := tc.HandshakeContext(ctx); err != nil {
		raw.Close()
		return nil, err
	}
	tc.SetDeadline(time.Time{})
	return tc, nil
}

// Client talks to one paired box over a pooled HTTP/2 connection.
type Client struct {
	box       trust.Peer
	transport *http.Transport
}

// NewClient is a client for box, which was paired at box.Address with the
// key box.Fingerprint.
func NewClient(id *identity.Identity, box trust.Peer) *Client {
	protocols := new(http.Protocols)
	protocols.SetHTTP2(true)
	return &Client{box: box, transport: &http.Transport{
		TLSClientConfig:       clientConfig(id, box.Fingerprint),
		Protocols:             protocols,
		DialContext:           (&net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   dialTimeout,
		ResponseHeaderTimeout: 3 * time.Minute,
		IdleConnTimeout:       5 * time.Minute,
		HTTP2:                 &http.HTTP2Config{SendPingTimeout: 15 * time.Second, PingTimeout: 10 * time.Second},
	}}
}

// DoWithHeader is Do with extra request headers, such as the origin a tool
// attributes its request to.
func (c *Client) DoWithHeader(ctx context.Context, method, path string, body io.Reader, header http.Header) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, "https://"+c.box.Address+path, body)
	if err != nil {
		return nil, err
	}
	for k, v := range header {
		req.Header[k] = v
	}
	resp, err := c.transport.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		return nil, ErrUntrusted
	}
	return resp, nil
}

// Ping checks that the box is reachable and still trusts this client, and
// returns the name it reports.
func (c *Client) Ping(ctx context.Context) (string, error) {
	resp, err := c.DoWithHeader(ctx, http.MethodGet, "/v1/ping", nil, nil)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusServiceUnavailable {
		return "", ErrStopping
	}
	if resp.StatusCode != http.StatusOK {
		return "", responseError(resp)
	}
	var out nameResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&out); err != nil {
		return "", err
	}
	return out.Name, nil
}

// Close drops the client's connections.
func (c *Client) Close() { c.transport.CloseIdleConnections() }

func responseError(resp *http.Response) error {
	var e errorResponse
	if json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&e) == nil && e.Error != "" {
		return errors.New(e.Error)
	}
	return fmt.Errorf("box replied %s", resp.Status)
}
