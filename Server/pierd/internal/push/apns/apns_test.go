package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func newKey(t *testing.T) *ecdsa.PrivateKey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestJWTIsVerifiableES256AndCached(t *testing.T) {
	k := newKey(t)
	now := time.Unix(1790000000, 0)
	c := New("KEYID12345", "TEAMID1234", k)
	c.Now = func() time.Time { return now }
	tok, err := c.Token(false)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatal(tok)
	}
	var h map[string]string
	hb, _ := base64.RawURLEncoding.DecodeString(parts[0])
	json.Unmarshal(hb, &h)
	if h["alg"] != "ES256" || h["kid"] != "KEYID12345" {
		t.Fatalf("header %v", h)
	}
	var p struct {
		Iss string
		Iat int64
	}
	pb, _ := base64.RawURLEncoding.DecodeString(parts[1])
	json.Unmarshal(pb, &p)
	if p.Iss != "TEAMID1234" || p.Iat != 1790000000 {
		t.Fatalf("payload %+v", p)
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("signature is %d bytes, want 64 (r||s)", len(sig))
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(&k.PublicKey, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("signature does not verify")
	}
	// cached for 40 minutes, then renewed
	now = now.Add(39 * time.Minute)
	if again, _ := c.Token(false); again != tok {
		t.Fatal("token not cached")
	}
	now = now.Add(2 * time.Minute)
	if again, _ := c.Token(false); again == tok {
		t.Fatal("token not renewed after 40 minutes")
	}
}

type seen struct {
	h    http.Header
	path string
	body string
}

func server(t *testing.T, handler func(n int, w http.ResponseWriter, r *http.Request)) (*Client, *[]seen) {
	var mu sync.Mutex
	var log []seen
	n := 0
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		n++
		log = append(log, seen{r.Header.Clone(), r.URL.Path, string(b)})
		i := n
		mu.Unlock()
		if r.ProtoMajor != 2 {
			t.Errorf("request over HTTP/%d, want HTTP/2", r.ProtoMajor)
		}
		handler(i, w, r)
	}))
	ts.EnableHTTP2 = true
	ts.StartTLS()
	t.Cleanup(ts.Close)
	c := New("K", "T", newKey(t))
	c.HTTP = ts.Client()
	c.Hosts = map[string]string{"development": ts.URL, "production": ts.URL}
	return c, &log
}

func TestSendHeaders(t *testing.T) {
	c, log := server(t, func(_ int, w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("apns-id", "ABC-123")
		w.WriteHeader(200)
	})
	res, err := c.Send(context.Background(), Request{
		Env: "development", Token: "aabbcc", PushType: "liveactivity", Topic: "com.example.pier.push-type.liveactivity",
		Priority: 10, Expiration: time.Unix(1790003600, 0), CollapseID: "sess1", Payload: []byte(`{"aps":{}}`),
	})
	if err != nil || !res.OK() || res.APNsID != "ABC-123" {
		t.Fatalf("%+v %v", res, err)
	}
	s := (*log)[0]
	want := map[string]string{
		"Apns-Push-Type": "liveactivity", "Apns-Topic": "com.example.pier.push-type.liveactivity",
		"Apns-Priority": "10", "Apns-Expiration": "1790003600", "Apns-Collapse-Id": "sess1", "Content-Type": "application/json",
	}
	for k, v := range want {
		if s.h.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, s.h.Get(k), v)
		}
	}
	if !strings.HasPrefix(s.h.Get("Authorization"), "bearer ") || s.path != "/3/device/aabbcc" || s.body != `{"aps":{}}` {
		t.Fatalf("%v %s %s", s.h.Get("Authorization"), s.path, s.body)
	}
}

func TestBadDeviceTokenIsDead(t *testing.T) {
	c, _ := server(t, func(_ int, w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(400)
		w.Write([]byte(`{"reason":"BadDeviceToken"}`))
	})
	res, err := c.Send(context.Background(), Request{Env: "development", Token: "00", PushType: "alert", Topic: "t", Payload: []byte(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() || res.Reason != "BadDeviceToken" || !res.Dead() {
		t.Fatalf("%+v", res)
	}
}

func TestGoneIsDeadAndOtherErrorsAreNot(t *testing.T) {
	if !(Result{Status: 410, Reason: "Unregistered"}).Dead() || (Result{Status: 429, Reason: "TooManyRequests"}).Dead() ||
		(Result{Status: 400, Reason: "PayloadTooLarge"}).Dead() {
		t.Fatal("Dead() classification wrong")
	}
}

func TestExpiredProviderTokenIsRetriedOnce(t *testing.T) {
	var auth []string
	var mu sync.Mutex
	c, _ := server(t, func(n int, w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auth = append(auth, r.Header.Get("authorization"))
		mu.Unlock()
		if n == 1 {
			w.WriteHeader(403)
			w.Write([]byte(`{"reason":"ExpiredProviderToken"}`))
			return
		}
		w.WriteHeader(200)
	})
	now := time.Unix(1790000000, 0)
	c.Now = func() time.Time { n := now; now = now.Add(time.Second); return n }
	res, err := c.Send(context.Background(), Request{Env: "production", Token: "aa", PushType: "alert", Topic: "t", Payload: []byte(`{}`)})
	if err != nil || !res.OK() {
		t.Fatalf("%+v %v", res, err)
	}
	if len(auth) != 2 || auth[0] == auth[1] {
		t.Fatalf("expected a retry with a fresh token, got %d attempts", len(auth))
	}
}

func TestUnknownEnv(t *testing.T) {
	c := New("K", "T", newKey(t))
	if _, err := c.Send(context.Background(), Request{Env: "moon"}); err == nil {
		t.Fatal("unknown env accepted")
	}
}
