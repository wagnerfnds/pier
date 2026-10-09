package push

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/push/apns"
	"pier/pierd/internal/push/boxapi"
	"pier/pierd/internal/push/engine"
	"pier/pierd/internal/push/state"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/wire"
)

// The push routes as the app reaches them: pierd's own TLS listener and
// paired clients (wire.Server), with the push service mounted on it.

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

type env struct {
	addr    string
	box     *identity.Identity
	server  *wire.Server
	clients *trust.Store
	svc     *Service
}

func newID(t *testing.T) *identity.Identity {
	t.Helper()
	id, err := identity.LoadOrCreate(filepath.Join(t.TempDir(), "identity.pem"))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// start serves push for a box whose paired clients are paired, sending
// POST /v1/push/test's alert through test.
func start(t *testing.T, paired map[string]*identity.Identity, test func(context.Context, state.Device) (apns.Result, error)) *env {
	t.Helper()
	dir := t.TempDir()
	e := &env{box: newID(t), clients: trust.NewStore(filepath.Join(dir, "clients.json"))}
	for name, id := range paired {
		if err := e.clients.Add(trust.Peer{Name: name, Fingerprint: id.Fingerprint(), PairedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	st, err := state.Open(filepath.Join(dir, StateFile))
	if err != nil {
		t.Fatal(err)
	}
	e.svc = &Service{Config: Config{BundleID: testBundleID}, State: st, Clients: e.clients, Log: quiet, sendTest: test}
	e.server = &wire.Server{Identity: e.box, Clients: e.clients, Pending: pairing.NewPending(filepath.Join(dir, "pairing.json")), Name: "devbox", RevokeCheck: 50 * time.Millisecond}
	e.svc.Mount(e.server)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	e.addr = ln.Addr().String()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go e.server.Serve(ctx, ln)
	return e
}

// client is the app: mutual TLS 1.3 with its key, pinning the box's.
func (e *env) client(id *identity.Identity) *http.Client {
	return &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		ForceAttemptHTTP2: true,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{id.Certificate()}, InsecureSkipVerify: true,
			VerifyConnection: func(cs tls.ConnectionState) error {
				if identity.FingerprintOf(cs.PeerCertificates[0]) != e.box.Fingerprint() {
					return io.ErrUnexpectedEOF
				}
				return nil
			},
		},
	}}
}

func do(t *testing.T, c *http.Client, e *env, method, path, body string) (int, string, string) {
	t.Helper()
	req, _ := http.NewRequest(method, "https://"+e.addr+path, strings.NewReader(body))
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp.Proto
}

func TestInfoDeviceAndActivityOverMutualTLS(t *testing.T) {
	phone := newID(t)
	e := start(t, map[string]*identity.Identity{"iphone": phone}, nil)
	c := e.client(phone)

	code, body, proto := do(t, c, e, "GET", "/v1/push/info", "")
	if code != 200 || proto != "HTTP/2.0" {
		t.Fatalf("%d %s %s", code, proto, body)
	}
	var info struct {
		Version  string   `json:"version"`
		Envs     []string `json:"apns_env_supported"`
		BundleID string   `json:"bundle_id"`
	}
	json.Unmarshal([]byte(body), &info)
	if info.Version != "1" || len(info.Envs) != 2 || info.BundleID != testBundleID {
		t.Fatalf("%s", body)
	}

	code, _, _ = do(t, c, e, "PUT", "/v1/push/device", `{"device_token":"aabbccddeeff0011","env":"development","locale":"pt-BR","events":{"waiting":true,"finished":false,"working":true},"widget_token":"11223344","box_name":"casa"}`)
	if code != 204 {
		t.Fatal(code)
	}
	d, ok := e.svc.State.Device(phone.Fingerprint().String())
	if !ok || d.Locale != "pt-BR" || d.Events.Finished || !d.Events.Working || d.BoxName != "casa" || d.ClientName != "iphone" || d.WidgetToken != "11223344" {
		t.Fatalf("%+v", d)
	}
	// Session names are percent-encoded by the phone.
	if code, _, _ = do(t, c, e, "PUT", "/v1/push/activities/casa%20mac/proj%2Fwt-1", `{"token":"deadbeef","env":"development"}`); code != 204 {
		t.Fatal(code)
	}
	if a := e.svc.State.Activities(); len(a) != 1 || a[0].Box != "casa mac" || a[0].Session != "proj/wt-1" {
		t.Fatalf("%+v", a)
	}
	if code, _, _ = do(t, c, e, "DELETE", "/v1/push/activities/casa%20mac/proj%2Fwt-1", ""); code != 204 || len(e.svc.State.Activities()) != 0 {
		t.Fatal("delete activity")
	}
	if code, _, _ = do(t, c, e, "DELETE", "/v1/push/device", ""); code != 204 {
		t.Fatal(code)
	}
	if _, ok := e.svc.State.Device(phone.Fingerprint().String()); ok {
		t.Fatal("device remains")
	}
}

func TestValidation(t *testing.T) {
	phone := newID(t)
	e := start(t, map[string]*identity.Identity{"iphone": phone}, nil)
	c := e.client(phone)
	for _, body := range []string{`{`, `{"device_token":"zz","env":"development"}`, `{"device_token":"aabbccdd","env":"mars"}`} {
		code, resp, _ := do(t, c, e, "PUT", "/v1/push/device", body)
		var er struct{ Error, Code string }
		json.Unmarshal([]byte(resp), &er)
		if code != 400 || er.Error == "" || er.Code == "" {
			t.Fatalf("%q -> %d %s", body, code, resp)
		}
	}
	if code, _, _ := do(t, c, e, "POST", "/v1/push/test", ""); code != 404 {
		t.Fatalf("test without device: %d", code)
	}
}

func TestUnpairedKeyIsRefused(t *testing.T) {
	phone, stranger := newID(t), newID(t)
	e := start(t, map[string]*identity.Identity{"iphone": phone}, nil)
	if code, body, _ := do(t, e.client(stranger), e, "GET", "/v1/push/info", ""); code != 401 || !strings.Contains(body, "unauthorized") {
		t.Fatalf("%d %s", code, body)
	}
}

func TestRevocationTakesEffectWithinSeconds(t *testing.T) {
	phone, other := newID(t), newID(t)
	e := start(t, map[string]*identity.Identity{"iphone": phone, "other": other}, nil)
	c := e.client(phone)
	if code, _, _ := do(t, c, e, "GET", "/v1/push/info", ""); code != 200 {
		t.Fatal(code)
	}
	if _, err := e.clients.Remove("iphone"); err != nil { // pierd revoke iphone
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		req, _ := http.NewRequest("GET", "https://"+e.addr+"/v1/push/info", nil)
		resp, err := c.Do(req)
		if err == nil {
			resp.Body.Close()
		}
		if err != nil || resp.StatusCode == 401 {
			break // refused, or its connection was cut
		}
		if time.Now().After(deadline) {
			t.Fatal("revoked client still authorised after 3s")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestTLS12AndNoClientCertAreRefused(t *testing.T) {
	phone := newID(t)
	e := start(t, map[string]*identity.Identity{"iphone": phone}, nil)
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12, InsecureSkipVerify: true, Certificates: []tls.Certificate{phone.Certificate()}}
	if conn, err := tls.Dial("tcp", e.addr, cfg); err == nil {
		conn.Close()
		t.Fatal("TLS 1.2 accepted")
	}
	// TLS 1.3 without a client certificate: the handshake (or the first read) fails.
	conn, err := tls.Dial("tcp", e.addr, &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true})
	if err == nil {
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(2 * time.Second))
		conn.Write([]byte("GET /v1/push/info HTTP/1.1\r\nHost: x\r\n\r\n"))
		buf := make([]byte, 64)
		if n, err := conn.Read(buf); err == nil && bytes.Contains(buf[:n], []byte("200 OK")) {
			t.Fatal("served a client without a certificate")
		}
	}
}

func TestPushTestResults(t *testing.T) {
	phone := newID(t)
	for _, tc := range []struct {
		res  apns.Result
		code int
		want string
	}{
		{apns.Result{Status: 200, APNsID: "ID-1"}, 200, `"sent":true`},
		{apns.Result{Status: 400, Reason: "BadDeviceToken"}, 502, `BadDeviceToken`},
	} {
		res := tc.res
		e := start(t, map[string]*identity.Identity{"iphone": phone}, func(context.Context, state.Device) (apns.Result, error) { return res, nil })
		c := e.client(phone)
		do(t, c, e, "PUT", "/v1/push/device", `{"device_token":"aabbccdd","env":"development"}`)
		code, body, _ := do(t, c, e, "POST", "/v1/push/test", "")
		if code != tc.code || !strings.Contains(body, tc.want) {
			t.Fatalf("%d %s", code, body)
		}
		if tc.res.OK() && !strings.Contains(body, `"apns_id":"ID-1"`) {
			t.Fatal(body)
		}
	}
}

// The box's own socket is not a phone: it cannot register a device.
func TestTheLocalSocketCannotRegister(t *testing.T) {
	e := start(t, nil, nil)
	req, _ := http.NewRequest("PUT", "/v1/push/device", strings.NewReader(`{"device_token":"aabbccdd","env":"development"}`))
	rec := &recorder{header: http.Header{}}
	e.server.LocalHandler().ServeHTTP(rec, req)
	if rec.status != http.StatusForbidden {
		t.Fatalf("local registration: %d", rec.status)
	}
}

type recorder struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (r *recorder) Header() http.Header { return r.header }
func (r *recorder) WriteHeader(s int)   { r.status = s }
func (r *recorder) Write(p []byte) (int, error) {
	if r.status == 0 {
		r.status = 200
	}
	return r.body.Write(p)
}

// recordingSender keeps what would have gone to APNs.
type recordingSender struct {
	mu   sync.Mutex
	reqs []apns.Request
}

func (s *recordingSender) Send(_ context.Context, r apns.Request) (apns.Result, error) {
	s.mu.Lock()
	s.reqs = append(s.reqs, r)
	s.mu.Unlock()
	return apns.Result{Status: 200, APNsID: "id"}, nil
}

func (s *recordingSender) alerts() []apns.Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []apns.Request
	for _, r := range s.reqs {
		if r.PushType == "alert" {
			out = append(out, r)
		}
	}
	return out
}

// The engine runs in pierd's process: it follows the event bus (no socket)
// and reads sessions and screens through pierd's handler. An agent that
// finishes reaches the phone as a FINISHED alert; events from before a
// restart are not announced twice.
func TestTheEngineFollowsTheBusInProcess(t *testing.T) {
	var mu sync.Mutex
	var sessions string
	setSession := func(state string, since time.Time) {
		mu.Lock()
		defer mu.Unlock()
		sessions = fmt.Sprintf(`[{"name":"cal-fix","location":"cal/fix","dir":"/w/cal-fix","agent":"claude","agent_state":%q,"state_since":%q,"title":"Fix login"}]`, state, since.UTC().Format(time.RFC3339Nano))
	}
	setSession("running", time.Now().Add(-time.Minute))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"name":"devbox"}`)) })
	mux.HandleFunc("GET /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		w.Write([]byte(sessions))
	})
	mux.HandleFunc("GET /v1/locations", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`[{"name":"cal","path":"/w/cal","worktrees":[{"name":"fix","path":"/w/cal-fix"}]}]`))
	})
	mux.HandleFunc("GET /v1/review", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`[]`)) })
	mux.HandleFunc("GET /v1/sessions/{name}/transcript", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"items":[]}`)) })
	mux.HandleFunc("GET /v1/sessions/{name}/screen", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"screen":""}`)) })
	mux.HandleFunc("GET /v1/sessions/{name}/draft", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{}`)) })

	phone := newID(t)
	dir := t.TempDir()
	clients := trust.NewStore(filepath.Join(dir, "clients.json"))
	clients.Add(trust.Peer{Name: "iphone", Fingerprint: phone.Fingerprint(), PairedAt: time.Now()})
	st, err := state.Open(filepath.Join(dir, StateFile))
	if err != nil {
		t.Fatal(err)
	}
	st.PutDevice(state.Device{Client: phone.Fingerprint().String(), ClientName: "iphone", Token: "aabbccdd", Env: "development", Locale: "en", Events: state.DefaultEvents})
	snd := &recordingSender{}
	svc := &Service{Config: Config{BundleID: testBundleID}, State: st, Clients: clients, Log: quiet}
	svc.Engine = engine.New(engine.Options{
		BundleID: testBundleID, WaitingSettle: 20 * time.Millisecond, FinishedSettle: 20 * time.Millisecond,
		SyncDelay: 5 * time.Millisecond, SyncEvery: time.Hour, ScreenTries: 1, ScreenRetry: time.Millisecond,
	}, boxapi.New(mux), st, snd, svc.paired, quiet)

	journal, err := events.OpenJournal(filepath.Join(dir, "journal"))
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	bus := &events.Bus{Journal: journal}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go svc.Run(ctx, bus)
	time.Sleep(100 * time.Millisecond) // the baseline sync

	setSession("finished", time.Now())
	bus.Publish(events.Event{Type: "agent.finished", Box: "devbox", Data: map[string]any{"session": "cal-fix"}})

	deadline := time.Now().Add(5 * time.Second)
	for len(snd.alerts()) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("no alert; sent %+v", snd.reqs)
		}
		time.Sleep(20 * time.Millisecond)
	}
	a := snd.alerts()[0]
	var p struct {
		APS struct {
			Category string `json:"category"`
		} `json:"aps"`
		Box, Session string
	}
	json.Unmarshal(a.Payload, &p)
	if p.APS.Category != "FINISHED" || p.Session != "cal-fix" || a.Token != "aabbccdd" {
		t.Fatalf("alert = %s (token %s)", a.Payload, a.Token)
	}
	if svc.State.LastSeq() == 0 {
		t.Fatal("the bus position was not kept")
	}
}

// testBundleID stands for the app's bundle id.
const testBundleID = "com.example.pier"

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	if _, ok, err := LoadConfig(dir); ok || err != nil {
		t.Fatalf("no push.json: %v %v", ok, err)
	}
	os.WriteFile(filepath.Join(dir, ConfigFile), []byte(`{"key_id":"K","team_id":"T","bundle_id":"`+testBundleID+`"}`), 0o600)
	c, ok, err := LoadConfig(dir)
	if !ok || err != nil || c.BundleID != testBundleID || c.KeyPath != filepath.Join(dir, "AuthKey.p8") || c.ActivityDateEpoch != "unix" {
		t.Fatalf("defaults: %+v %v %v", c, ok, err)
	}
	os.WriteFile(filepath.Join(dir, ConfigFile), []byte(`{"key_id":"K"}`), 0o600)
	if _, _, err := LoadConfig(dir); err == nil {
		t.Fatal("a config without team_id was taken")
	}
	os.WriteFile(filepath.Join(dir, ConfigFile), []byte(`{"key_id":"K","team_id":"T"}`), 0o600)
	if _, _, err := LoadConfig(dir); err == nil {
		t.Fatal("a config without bundle_id was taken")
	}
}
