// Package push sends APNs pushes (alerts, Live Activity updates, widget
// reloads) for this box to the phones paired with it. It reads the event
// bus in-process and serves its routes on pierd's own listener. docs/PUSH.md in
// the app's repository is the contract.
package push

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/push/apns"
	"pier/pierd/internal/push/boxapi"
	"pier/pierd/internal/push/engine"
	"pier/pierd/internal/push/recap"
	"pier/pierd/internal/push/state"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/wire"
)

// Config is push.json, in pierd's home.
type Config struct {
	KeyID  string `json:"key_id"`
	TeamID string `json:"team_id"`
	// BundleID is the app's bundle id (PIER_BUNDLE_ID in the app's
	// Config/Signing.xcconfig), the topic of its pushes.
	BundleID string `json:"bundle_id"`
	// KeyPath is the APNs auth key (.p8); AuthKey.p8 beside push.json by
	// default.
	KeyPath string `json:"key_path,omitempty"`
	// Listen is where else the push routes are served, comma separated
	// ("" or "off": nowhere else). They are always on pierd's own listener.
	Listen string `json:"listen,omitempty"`
	// ActivityDateEpoch is how Dates inside a Live Activity content-state
	// are encoded: "unix" (default; the app decodes Unix seconds) or
	// "reference" (seconds since 2001-01-01).
	ActivityDateEpoch string `json:"activity_date_epoch,omitempty"`
	// Recaps: a finished turn's alert and Live Activity carry a one-sentence
	// summary written by `claude -p --model haiku` on the box instead of the
	// reply's first sentence. Default true; false turns it off.
	Recaps *bool `json:"recaps,omitempty"`
}

// RecapsOn is Recaps with its default (on).
func (c *Config) RecapsOn() bool { return c == nil || c.Recaps == nil || *c.Recaps }

// ConfigFile is push.json's name in pierd's home.
const ConfigFile = "push.json"

// LoadConfig reads dir/push.json. ok is false when there is none: push is
// then off.
func LoadConfig(dir string) (c Config, ok bool, err error) {
	path := filepath.Join(dir, ConfigFile)
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Config{}, false, nil
	}
	if err != nil {
		return Config{}, false, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return Config{}, false, fmt.Errorf("%s: %w", path, err)
	}
	if c.KeyPath == "" {
		c.KeyPath = filepath.Join(dir, "AuthKey.p8")
	}
	if strings.HasPrefix(c.KeyPath, "~/") {
		h, _ := os.UserHomeDir()
		c.KeyPath = filepath.Join(h, c.KeyPath[2:])
	}
	if c.ActivityDateEpoch == "" {
		c.ActivityDateEpoch = "unix"
	}
	if c.ActivityDateEpoch != "reference" && c.ActivityDateEpoch != "unix" {
		return Config{}, false, errors.New("activity_date_epoch must be \"reference\" or \"unix\"")
	}
	if c.KeyID == "" || c.TeamID == "" || c.BundleID == "" {
		return Config{}, false, fmt.Errorf("%s: key_id, team_id and bundle_id are required", path)
	}
	return c, true, nil
}

// StateFile is where registrations are kept, in pierd's home.
const StateFile = "push-state.json"

// Service is push, wired into a running pierd.
type Service struct {
	Config  Config
	State   *state.Store
	Engine  *engine.Engine
	Clients *trust.Store
	Log     *slog.Logger
	// sendTest sends POST /v1/push/test's alert: the engine's, a fake in tests.
	sendTest func(ctx context.Context, d state.Device) (apns.Result, error)
}

// Open starts push from the config in dir. local answers the box's API
// in-process (wire.Server.LocalHandler), for what the engine reads.
func Open(dir string, cfg Config, clients *trust.Store, local http.Handler, log *slog.Logger) (*Service, error) {
	if fi, err := os.Stat(cfg.KeyPath); err != nil {
		return nil, fmt.Errorf("APNs key: %w", err)
	} else if fi.Mode().Perm()&0o077 != 0 {
		log.Warn("APNs key is readable by others; chmod 600", "path", cfg.KeyPath)
	}
	key, err := apns.LoadKey(cfg.KeyPath)
	if err != nil {
		return nil, err
	}
	st, err := state.Open(filepath.Join(dir, StateFile))
	if err != nil {
		return nil, fmt.Errorf("push state: %w", err)
	}
	s := &Service{Config: cfg, State: st, Clients: clients, Log: log}
	opts := engine.Options{BundleID: cfg.BundleID, DateEpoch: cfg.ActivityDateEpoch}
	if cfg.RecapsOn() {
		w := &recap.Warm{}
		opts.Recap, opts.Prewarm = recap.New(w).Recap, w.Prewarm
	}
	s.Engine = engine.New(opts, boxapi.New(local), st, apns.New(cfg.KeyID, cfg.TeamID, key), s.paired, log)
	s.sendTest = s.Engine.SendTest
	return s, nil
}

// paired says whether a client (its fingerprint, as state keeps it) is
// still paired.
func (s *Service) paired(client string) bool {
	peers, err := s.Clients.List()
	if err != nil {
		return false
	}
	for _, p := range peers {
		if p.Fingerprint.String() == client {
			return true
		}
	}
	return false
}

// Run feeds the engine from bus until ctx ends: a baseline first (nothing
// already there is announced), then every event after the last one it saw,
// so a restart announces what changed meanwhile. It also forgets the
// registrations of clients that were revoked.
func (s *Service) Run(ctx context.Context, bus *events.Bus) {
	s.Log.Info("push starting", "key_id", s.Config.KeyID, "team_id", s.Config.TeamID, "bundle_id", s.Config.BundleID, "last_seq", s.State.LastSeq())
	s.Engine.Init(ctx)
	go s.Engine.Run(ctx)
	go s.housekeeping(ctx)
	since := int64(min(s.State.LastSeq(), math.MaxInt64))
	if head := bus.Head(); since > head {
		// A position from another journal (one that was reset or
		// replaced): start from now; Init has the baseline.
		since = head
	}
	cur := bus.SubscribeFrom(since).Named("push")
	defer cur.Close()
	for {
		e, err := cur.Next(ctx)
		if err != nil {
			s.State.Flush()
			return
		}
		s.Engine.OnEvent(boxapi.Event{Seq: uint64(e.Seq), Type: e.Type, Time: e.Time, Origin: e.Origin, Error: e.Error, Data: e.Data})
	}
}

func (s *Service) housekeeping(ctx context.Context) {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.State.Flush()
			if _, err := s.Clients.List(); err != nil {
				continue // unreadable: keep everyone until it reads again
			}
			if n := s.State.PruneClients(s.paired); n > 0 {
				s.Log.Info("dropped push registrations of revoked clients", "count", n)
			}
		}
	}
}

// Mount serves the push routes on srv, behind its authentication.
func (s *Service) Mount(srv *wire.Server) {
	route := func(pattern string, h http.HandlerFunc) {
		srv.Handle(pattern, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if wire.IsLocal(r.Context()) {
				fail(w, http.StatusForbidden, "refused", "push registrations come from paired devices")
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
			h(w, r)
		}))
	}
	route("GET /v1/push/info", s.info)
	route("PUT /v1/push/device", s.putDevice)
	route("DELETE /v1/push/device", s.deleteDevice)
	route("PUT /v1/push/activities/{box}/{session}", s.putActivity)
	route("DELETE /v1/push/activities/{box}/{session}", s.deleteActivity)
	route("POST /v1/push/test", s.test)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}

func (s *Service) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"version": "1", "apns_env_supported": []string{"development", "production"}, "bundle_id": s.Config.BundleID,
	})
}

func validEnv(e string) bool { return e == "development" || e == "production" }

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	b, err := io.ReadAll(r.Body)
	if err != nil {
		fail(w, http.StatusBadRequest, "bad_request", "unreadable body")
		return false
	}
	if err := json.Unmarshal(b, v); err != nil {
		fail(w, http.StatusBadRequest, "bad_request", "invalid JSON: "+err.Error())
		return false
	}
	return true
}

func (s *Service) putDevice(w http.ResponseWriter, r *http.Request) {
	peer := wire.PeerFrom(r.Context())
	body := struct {
		DeviceToken      string        `json:"device_token"`
		Env              string        `json:"env"`
		Locale           string        `json:"locale"`
		Events           *state.Events `json:"events"`
		WidgetToken      string        `json:"widget_token"`
		PushToStartToken string        `json:"push_to_start_token"`
		BoxName          string        `json:"box_name"`
	}{}
	if !decode(w, r, &body) {
		return
	}
	if !state.ValidToken(body.DeviceToken) {
		fail(w, http.StatusBadRequest, "bad_token", "device_token must be hex")
		return
	}
	if !validEnv(body.Env) {
		fail(w, http.StatusBadRequest, "bad_env", `env must be "development" or "production"`)
		return
	}
	for _, t := range []string{body.WidgetToken, body.PushToStartToken} {
		if t != "" && !state.ValidToken(t) {
			fail(w, http.StatusBadRequest, "bad_token", "tokens must be hex")
			return
		}
	}
	ev := state.DefaultEvents
	if body.Events != nil {
		ev = *body.Events
	}
	if body.Locale == "" {
		body.Locale = "en"
	}
	d := state.Device{
		Client: peer.Fingerprint.String(), ClientName: peer.Name, Token: body.DeviceToken, Env: body.Env, Locale: body.Locale, Events: ev,
		WidgetToken: body.WidgetToken, PushToStartToken: body.PushToStartToken, BoxName: body.BoxName, Updated: time.Now().UTC(),
	}
	if err := s.State.PutDevice(d); err != nil {
		s.Log.Error("save push state", "err", err)
		fail(w, http.StatusInternalServerError, "internal", "could not save")
		return
	}
	s.Log.Info("push device registered", "client", peer.Name, "env", d.Env, "locale", d.Locale, "events", d.Events,
		"widget", d.WidgetToken != "", "push_to_start", d.PushToStartToken != "", "box_name", d.BoxName)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) deleteDevice(w http.ResponseWriter, r *http.Request) {
	peer := wire.PeerFrom(r.Context())
	if err := s.State.DeleteDevice(peer.Fingerprint.String()); err != nil {
		fail(w, http.StatusInternalServerError, "internal", "could not save")
		return
	}
	s.Log.Info("push device unregistered", "client", peer.Name)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) putActivity(w http.ResponseWriter, r *http.Request) {
	peer := wire.PeerFrom(r.Context())
	var body struct {
		Token string `json:"token"`
		Env   string `json:"env"`
	}
	if !decode(w, r, &body) {
		return
	}
	if !state.ValidToken(body.Token) {
		fail(w, http.StatusBadRequest, "bad_token", "token must be hex")
		return
	}
	if !validEnv(body.Env) {
		fail(w, http.StatusBadRequest, "bad_env", `env must be "development" or "production"`)
		return
	}
	a := state.Activity{Client: peer.Fingerprint.String(), Box: r.PathValue("box"), Session: r.PathValue("session"), Token: body.Token, Env: body.Env, Updated: time.Now().UTC()}
	if a.Session == "" {
		fail(w, http.StatusBadRequest, "bad_request", "session required")
		return
	}
	if err := s.State.PutActivity(a); err != nil {
		fail(w, http.StatusInternalServerError, "internal", "could not save")
		return
	}
	s.Log.Info("push activity registered", "client", peer.Name, "box", a.Box, "session", a.Session, "env", a.Env)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) deleteActivity(w http.ResponseWriter, r *http.Request) {
	peer := wire.PeerFrom(r.Context())
	if err := s.State.DeleteActivity(peer.Fingerprint.String(), r.PathValue("box"), r.PathValue("session")); err != nil {
		fail(w, http.StatusInternalServerError, "internal", "could not save")
		return
	}
	s.Log.Info("push activity unregistered", "client", peer.Name, "box", r.PathValue("box"), "session", r.PathValue("session"))
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) test(w http.ResponseWriter, r *http.Request) {
	peer := wire.PeerFrom(r.Context())
	d, ok := s.State.Device(peer.Fingerprint.String())
	if !ok || d.Token == "" {
		fail(w, http.StatusNotFound, "no_device", "no device registered for this client; PUT /v1/push/device first")
		return
	}
	res, err := s.sendTest(r.Context(), d)
	switch {
	case err != nil:
		fail(w, http.StatusBadGateway, "apns_unreachable", "APNs: "+err.Error())
	case !res.OK():
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error": fmt.Sprintf("APNs: %s (%d)", res.Reason, res.Status), "code": "apns_error", "reason": res.Reason, "status": res.Status,
		})
	default:
		writeJSON(w, http.StatusOK, map[string]any{"sent": true, "apns_id": res.APNsID})
	}
}
