package box

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/relay"
	"pier/pierd/internal/statefile"
)

// Public links: one of a worktree's dev servers published through the box's
// relay at https://p-<name>.<the relay's share domain> (internal/relay
// shares.go), for anyone with the link, until it expires or is taken down.
// Only a port of the worktree's own block, or one its processes listen on,
// can be published; the name is random and long enough not to be guessed.

// Publisher is the box's relay as far as links go (*relay.Listener).
type Publisher interface {
	Publish(ctx context.Context, name string, port int) (string, error)
	Unpublish(name string)
	// SharePrefix is how this box's link names start (its key's).
	SharePrefix() string
}

// Share is one public link (GET /v1/shares).
type Share struct {
	Name     string    `json:"name"`
	URL      string    `json:"url"`
	Location string    `json:"location"`
	Worktree string    `json:"worktree"`
	Port     int       `json:"port"`
	Created  time.Time `json:"created"`
	Expires  time.Time `json:"expires"`
	// Auto marks the link pierd made for the worktree's preview
	// (preview.go), renewed while the worktree is there.
	Auto bool `json:"auto,omitempty"`
}

var errNoTunnel = errors.New("this box has no tunnel: public links go through its relay (pierd relay default)")

const (
	defaultShareHours = 24
	maxShareHours     = 7 * 24
)

type shareStore struct {
	mu   sync.Mutex
	path string
	all  []Share
}

func (b *Box) shareStore() *shareStore {
	b.sharesOnce.Do(func() {
		dir := b.StateDir
		if dir == "" {
			dir = os.TempDir()
		}
		b.shareList = &shareStore{path: filepath.Join(dir, "shares.json")}
		if data, err := os.ReadFile(b.shareList.path); err == nil {
			json.Unmarshal(data, &b.shareList.all)
		}
	})
	return b.shareList
}

func (s *shareStore) save() {
	data, _ := json.MarshalIndent(s.all, "", "  ")
	statefile.Write(s.path, append(data, '\n'))
}

// StartShares publishes the links kept from before a restart again and
// takes expired ones down as they expire. It runs until ctx ends.
func (b *Box) StartShares(ctx context.Context) {
	if b.Publisher == nil {
		return
	}
	st := b.shareStore()
	st.mu.Lock()
	for _, sh := range st.all {
		if b.now().Before(sh.Expires) {
			// Registered now, published once the relay is connected.
			go b.Publisher.Publish(ctx, sh.Name, sh.Port)
		}
	}
	st.mu.Unlock()
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	// A dev server nobody recorded gets its link within seconds of coming up.
	detect := time.NewTicker(previewDetectEvery)
	defer detect.Stop()
	b.detectPreviews(ctx)
	for {
		// Previews' links are renewed before anything expires.
		b.renewPreviewShares(ctx)
		b.expireShares()
		for minute := false; !minute; {
			select {
			case <-ctx.Done():
				return
			case <-detect.C:
				b.detectPreviews(ctx)
			case <-t.C:
				minute = true
			}
		}
	}
}

func (b *Box) expireShares() {
	st := b.shareStore()
	st.mu.Lock()
	defer st.mu.Unlock()
	keep := st.all[:0]
	for _, sh := range st.all {
		if b.now().Before(sh.Expires) {
			keep = append(keep, sh)
			continue
		}
		if b.Publisher != nil {
			b.Publisher.Unpublish(sh.Name)
		}
		b.Events.Publish(eventf(b, "share.expired", map[string]any{"name": sh.Name, "location": sh.Location, "worktree": sh.Worktree}))
	}
	if len(keep) != len(st.all) {
		st.all = keep
		st.save()
	} else {
		st.all = keep
	}
}

// newShareName is the box's key prefix and 16 random characters (80 bits).
func newShareName(prefix string) string {
	var b [10]byte
	rand.Read(b[:])
	return prefix + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b[:]))
}

// shareablePort says whether port belongs to the worktree: its own block,
// or a port its processes listen on.
func (b *Box) shareablePort(ctx context.Context, loc Location, wt Worktree, port int) bool {
	if wt.Port > 0 && port >= wt.Port && port < wt.Port+portBlock {
		return true
	}
	ports, err := ListPorts(ctx)
	if err != nil {
		return false
	}
	for _, s := range Services(ports, []Location{loc}) {
		if s.Path == wt.Path && s.Port == port {
			return true
		}
	}
	return false
}

func (b *Box) listShares(w http.ResponseWriter, r *http.Request) error {
	b.expireShares()
	st := b.shareStore()
	st.mu.Lock()
	out := append([]Share{}, st.all...)
	st.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Created.After(out[j].Created) })
	writeJSON(w, out)
	return nil
}

func (b *Box) addShare(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Location string `json:"location"`
		Worktree string `json:"worktree"`
		Port     int    `json:"port"`
		Hours    int    `json:"hours"`
	}
	if err := decode(r, &req); err != nil {
		return err
	}
	if b.Publisher == nil {
		return httpError{http.StatusNotImplemented, errNoTunnel.Error()}
	}
	loc, wt, err := b.worktreeRef(r.Context(), req.Location, req.Worktree)
	if err != nil {
		return err
	}
	if req.Port <= 0 || !b.shareablePort(r.Context(), loc, wt, req.Port) {
		return badRequest("port %d is not one of %s's: publish its own port ($PIER_PORT…) or one its dev server listens on", req.Port, wt.Name)
	}
	hours := req.Hours
	if hours <= 0 {
		hours = defaultShareHours
	}
	if hours > maxShareHours {
		return badRequest("a link lasts at most %d hours", maxShareHours)
	}
	if err := b.before(r, "share.create", map[string]any{"location": loc.Name, "worktree": wt.Name, "port": req.Port, "hours": hours}); err != nil {
		return err
	}
	name := newShareName(b.Publisher.SharePrefix())
	url, err := b.Publisher.Publish(r.Context(), name, req.Port)
	if err != nil {
		b.Publisher.Unpublish(name)
		if errors.Is(err, relay.ErrNoShares) {
			return httpError{http.StatusNotImplemented, err.Error() + "; links need a relay run with --share-domain"}
		}
		return err
	}
	now := b.now().UTC()
	sh := Share{Name: name, URL: url, Location: loc.Name, Worktree: wt.Name, Port: req.Port, Created: now, Expires: now.Add(time.Duration(hours) * time.Hour)}
	st := b.shareStore()
	st.mu.Lock()
	st.all = append(st.all, sh)
	st.save()
	st.mu.Unlock()
	b.publish(r, "share.created", map[string]any{"name": name, "url": url, "location": loc.Name, "worktree": wt.Name, "port": req.Port})
	writeJSON(w, sh)
	return nil
}

// dropShare forgets the link called name, already taken down; false when it
// was not listed.
func (b *Box) dropShare(name string) bool {
	st := b.shareStore()
	st.mu.Lock()
	defer st.mu.Unlock()
	keep := st.all[:0]
	for _, sh := range st.all {
		if sh.Name != name {
			keep = append(keep, sh)
		}
	}
	if len(keep) == len(st.all) {
		return false
	}
	st.all = keep
	st.save()
	return true
}

// dropShares takes down the links of a location (worktree "": all of its
// worktrees) that is going away.
func (b *Box) dropShares(location, worktree string) {
	st := b.shareStore()
	st.mu.Lock()
	defer st.mu.Unlock()
	keep := st.all[:0]
	for _, sh := range st.all {
		if sh.Location == location && (worktree == "" || sh.Worktree == worktree) {
			if b.Publisher != nil {
				b.Publisher.Unpublish(sh.Name)
			}
			continue
		}
		keep = append(keep, sh)
	}
	if len(keep) != len(st.all) {
		st.all = keep
		st.save()
	}
}

func (b *Box) removeShare(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	st := b.shareStore()
	st.mu.Lock()
	found := false
	keep := st.all[:0]
	for _, sh := range st.all {
		if sh.Name == name {
			found = true
			continue
		}
		keep = append(keep, sh)
	}
	st.all = keep
	if found {
		st.save()
	}
	st.mu.Unlock()
	if !found {
		return httpError{http.StatusNotFound, fmt.Sprintf("no link %s", name)}
	}
	if b.Publisher != nil {
		b.Publisher.Unpublish(name)
	}
	// A preview's own link taken down by hand stays down.
	b.previewShareRemoved(name)
	b.publish(r, "share.removed", map[string]any{"name": name})
	writeJSON(w, map[string]string{"removed": name})
	return nil
}
