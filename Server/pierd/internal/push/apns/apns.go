// Package apns is a small APNs HTTP/2 provider client with token (ES256 JWT) authentication.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

const (
	HostDevelopment = "https://api.sandbox.push.apple.com"
	HostProduction  = "https://api.push.apple.com"
	// JWTLifetime: Apple wants a fresh token no more often than every 20 minutes and at least hourly.
	JWTLifetime = 40 * time.Minute
)

// Request is one notification.
type Request struct {
	Env        string // "development" | "production"
	Token      string
	PushType   string // alert | liveactivity | widgets | background
	Topic      string
	Priority   int       // 10 or 5; 0 = omit
	Expiration time.Time // zero = omit; Unix(0) = deliver once or drop
	CollapseID string
	Payload    []byte
}

// Result is APNs' answer.
type Result struct {
	Status    int
	APNsID    string
	Reason    string
	Timestamp int64 // for 410: when APNs confirmed the token is no longer valid (ms)
}

func (r Result) OK() bool { return r.Status == http.StatusOK }

// Dead: the token is not valid for this app/environment any more; drop it.
func (r Result) Dead() bool {
	if r.Status == http.StatusGone {
		return true
	}
	switch r.Reason {
	case "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic":
		return true
	}
	return false
}

func (r Result) String() string {
	if r.OK() {
		return fmt.Sprintf("200 %s", r.APNsID)
	}
	return fmt.Sprintf("%d %s", r.Status, r.Reason)
}

type Client struct {
	KeyID, TeamID string
	Key           *ecdsa.PrivateKey
	HTTP          *http.Client
	Hosts         map[string]string // env -> base URL
	Now           func() time.Time

	mu    sync.Mutex
	jwt   string
	jwtAt time.Time
}

// LoadKey reads an Apple .p8 (PKCS#8 EC P-256).
func LoadKey(path string) (*ecdsa.PrivateKey, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return nil, fmt.Errorf("%s: not a PEM file", path)
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s: not an EC key", path)
	}
	return ec, nil
}

func New(keyID, teamID string, key *ecdsa.PrivateKey) *Client {
	return &Client{
		KeyID: keyID, TeamID: teamID, Key: key,
		HTTP:  &http.Client{Timeout: 20 * time.Second}, // net/http negotiates h2 with APNs by itself
		Hosts: map[string]string{"development": HostDevelopment, "production": HostProduction},
		Now:   time.Now,
	}
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// makeJWT signs {"alg":"ES256","kid"} . {"iss":team,"iat"} with the .p8 key (r||s, 32 bytes each).
func (c *Client) makeJWT(now time.Time) (string, error) {
	h, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.KeyID})
	p, _ := json.Marshal(map[string]any{"iss": c.TeamID, "iat": now.Unix()})
	signing := b64(h) + "." + b64(p)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.Key, sum[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + b64(sig), nil
}

// Token returns the cached provider token, minting a new one every JWTLifetime (or when force is set).
func (c *Client) Token(force bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.Now()
	if !force && c.jwt != "" && now.Sub(c.jwtAt) < JWTLifetime {
		return c.jwt, nil
	}
	t, err := c.makeJWT(now)
	if err != nil {
		return "", err
	}
	c.jwt, c.jwtAt = t, now
	return t, nil
}

// Send posts one notification. A rejected provider token (403 ExpiredProviderToken/InvalidProviderToken) is retried
// once with a fresh one. Transport errors are returned; APNs refusals are in the Result.
func (c *Client) Send(ctx context.Context, r Request) (Result, error) {
	host, ok := c.Hosts[r.Env]
	if !ok {
		return Result{}, fmt.Errorf("unknown APNs environment %q", r.Env)
	}
	force := false
	for attempt := 0; ; attempt++ {
		tok, err := c.Token(force)
		if err != nil {
			return Result{}, err
		}
		res, err := c.post(ctx, host, tok, r)
		if err != nil {
			return res, err
		}
		if res.Status == http.StatusForbidden && (res.Reason == "ExpiredProviderToken" || res.Reason == "InvalidProviderToken") && attempt == 0 {
			force = true
			continue
		}
		return res, nil
	}
}

func (c *Client) post(ctx context.Context, host, jwt string, r Request) (Result, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+r.Token, bytes.NewReader(r.Payload))
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-push-type", r.PushType)
	req.Header.Set("apns-topic", r.Topic)
	req.Header.Set("content-type", "application/json")
	if r.Priority != 0 {
		req.Header.Set("apns-priority", strconv.Itoa(r.Priority))
	}
	if !r.Expiration.IsZero() {
		exp := r.Expiration.Unix()
		if exp < 0 {
			exp = 0
		}
		req.Header.Set("apns-expiration", strconv.FormatInt(exp, 10))
	}
	if r.CollapseID != "" {
		req.Header.Set("apns-collapse-id", r.CollapseID)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	res := Result{Status: resp.StatusCode, APNsID: resp.Header.Get("apns-id")}
	if resp.StatusCode != http.StatusOK && len(body) > 0 {
		var e struct {
			Reason    string `json:"reason"`
			Timestamp int64  `json:"timestamp"`
		}
		if json.Unmarshal(body, &e) == nil {
			res.Reason, res.Timestamp = e.Reason, e.Timestamp
		}
	}
	return res, nil
}

// ErrNoKey is returned when the .p8 is missing.
var ErrNoKey = errors.New("APNs key missing")
