// Package state persists what phones registered (devices, Live Activities) and where the follower stopped.
package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Events struct {
	Waiting  bool `json:"waiting"`
	Finished bool `json:"finished"`
	Working  bool `json:"working"`
}

// DefaultEvents is what a device that sends no `events` gets.
var DefaultEvents = Events{Waiting: true, Finished: true}

// Device is one paired client's phone. Keyed by the client's key fingerprint.
type Device struct {
	Client           string    `json:"client"` // fingerprint (text form)
	ClientName       string    `json:"client_name,omitempty"`
	Token            string    `json:"device_token"`
	Env              string    `json:"env"`
	Locale           string    `json:"locale"`
	Events           Events    `json:"events"`
	WidgetToken      string    `json:"widget_token,omitempty"`
	PushToStartToken string    `json:"push_to_start_token,omitempty"`
	BoxName          string    `json:"box_name,omitempty"`
	Updated          time.Time `json:"updated"`
	LastWidget       time.Time `json:"last_widget,omitempty"`
}

// Activity is a Live Activity update token for one session on one device.
type Activity struct {
	Client  string    `json:"client"`
	Box     string    `json:"box"`
	Session string    `json:"session"`
	Token   string    `json:"token"`
	Env     string    `json:"env"`
	Updated time.Time `json:"updated"`
}

// Seen is the last session state the follower acted on, so a restart does not re-announce it (or miss a change).
type Seen struct {
	State string    `json:"state"`
	Since time.Time `json:"since"`
}

type data struct {
	Devices    map[string]*Device   `json:"devices"`
	Activities map[string]*Activity `json:"activities"`
	Seen       map[string]Seen      `json:"seen"`
	LastSeq    uint64               `json:"last_seq"`
}

type Store struct {
	path string
	mu   sync.Mutex
	d    data
	// dirtySeq: LastSeq changed since the last write (written by Flush, not on every event).
	dirtySeq bool
}

func Open(path string) (*Store, error) {
	s := &Store{path: path, d: data{Devices: map[string]*Device{}, Activities: map[string]*Activity{}, Seen: map[string]Seen{}}}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &s.d); err != nil {
		return nil, err
	}
	if s.d.Devices == nil {
		s.d.Devices = map[string]*Device{}
	}
	if s.d.Activities == nil {
		s.d.Activities = map[string]*Activity{}
	}
	if s.d.Seen == nil {
		s.d.Seen = map[string]Seen{}
	}
	return s, nil
}

// save writes atomically with mode 0600. Callers hold s.mu.
func (s *Store) save() error {
	b, err := json.MarshalIndent(&s.d, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	s.dirtySeq = false
	return os.Rename(tmp, s.path)
}

func ActivityKey(client, box, session string) string { return client + "|" + box + "/" + session }

func (s *Store) PutDevice(d Device) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if old, ok := s.d.Devices[d.Client]; ok {
		d.LastWidget = old.LastWidget
	}
	s.d.Devices[d.Client] = &d
	return s.save()
}

func (s *Store) Device(client string) (Device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.d.Devices[client]
	if !ok {
		return Device{}, false
	}
	return *d, true
}

func (s *Store) Devices() []Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Device, 0, len(s.d.Devices))
	for _, d := range s.d.Devices {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Client < out[j].Client })
	return out
}

// DeleteDevice removes a device and its activities.
func (s *Store) DeleteDevice(client string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.d.Devices, client)
	for k, a := range s.d.Activities {
		if a.Client == client {
			delete(s.d.Activities, k)
		}
	}
	return s.save()
}

// DropDeviceToken clears a token APNs said is dead; the device row goes when nothing is left to push to.
func (s *Store) DropDeviceToken(client, kind string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.d.Devices[client]
	if !ok {
		return nil
	}
	switch kind {
	case "device":
		d.Token = ""
	case "widget":
		d.WidgetToken = ""
	case "start":
		d.PushToStartToken = ""
	}
	if d.Token == "" && d.WidgetToken == "" && d.PushToStartToken == "" {
		delete(s.d.Devices, client)
	}
	return s.save()
}

func (s *Store) PutActivity(a Activity) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.d.Activities[ActivityKey(a.Client, a.Box, a.Session)] = &a
	return s.save()
}

func (s *Store) DeleteActivity(client, box, session string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.d.Activities, ActivityKey(client, box, session))
	return s.save()
}

// ActivitiesFor lists the activities of a session across devices. The `box` in an activity's path is the name the
// phone gave the box, so it is not compared.
func (s *Store) ActivitiesFor(session string) []Activity {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Activity
	for _, a := range s.d.Activities {
		if a.Session == session {
			out = append(out, *a)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Client < out[j].Client })
	return out
}

func (s *Store) Activities() []Activity {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Activity, 0, len(s.d.Activities))
	for _, a := range s.d.Activities {
		out = append(out, *a)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Client+out[i].Box+out[i].Session < out[j].Client+out[j].Box+out[j].Session
	})
	return out
}

// PruneClients drops devices and activities of clients that are no longer paired.
func (s *Store) PruneClients(paired func(client string) bool) (removed int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.d.Devices {
		if !paired(c) {
			delete(s.d.Devices, c)
			removed++
		}
	}
	for k, a := range s.d.Activities {
		if !paired(a.Client) {
			delete(s.d.Activities, k)
			removed++
		}
	}
	if removed > 0 {
		_ = s.save()
	}
	return removed
}

func (s *Store) Seen(name string) (Seen, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.d.Seen[name]
	return v, ok
}

func (s *Store) SeenAll() map[string]Seen {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]Seen, len(s.d.Seen))
	for k, v := range s.d.Seen {
		out[k] = v
	}
	return out
}

func (s *Store) SetSeen(name string, v Seen) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.d.Seen[name] = v
	_ = s.save()
}

func (s *Store) DeleteSeen(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.d.Seen[name]; ok {
		delete(s.d.Seen, name)
		_ = s.save()
	}
}

func (s *Store) LastSeq() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.d.LastSeq
}

func (s *Store) SetLastSeq(n uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if n > s.d.LastSeq {
		s.d.LastSeq, s.dirtySeq = n, true
	}
}

// Flush writes a pending LastSeq.
func (s *Store) Flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dirtySeq {
		_ = s.save()
	}
}

// ValidToken: APNs tokens are hex.
func ValidToken(t string) bool {
	if len(t) < 8 || len(t) > 400 || len(t)%2 != 0 {
		return false
	}
	return strings.Trim(strings.ToLower(t), "0123456789abcdef") == ""
}
