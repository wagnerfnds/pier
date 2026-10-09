package integrations

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"pier/pierd/internal/events"
)

// maxSpooled bounds the spool: a box whose daemon stays down for days does
// not fill its disk with hooks.
const maxSpooled = 10000

// Unreachable says whether err means the daemon is not there to take an
// event (its socket is missing or refuses), rather than that it refused it.
func Unreachable(err error) bool {
	var op *net.OpError
	return errors.As(err, &op) || errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ENOENT) || errors.Is(err, os.ErrNotExist)
}

// Spool keeps an event that could not be delivered, as one small file in
// dir, for the daemon to publish when it starts. The name sorts in the
// order the hooks ran.
func Spool(dir string, e events.Event) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if ents, err := os.ReadDir(dir); err == nil && len(ents) >= maxSpooled {
		return fmt.Errorf("the hook spool in %s is full", dir)
	}
	if e.Time.IsZero() {
		e.Time = time.Now().UTC()
	}
	// A request that waited out a restart is stale, and the spool is
	// published as it is: no ask.
	e = StripAsk(e)
	b, err := json.Marshal(e)
	if err != nil {
		return err
	}
	name := fmt.Sprintf("%019d-%d.json", time.Now().UnixNano(), os.Getpid())
	tmp := filepath.Join(dir, "."+name)
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, name))
}

// DrainSpool publishes the spooled events in order, removing each once it
// is published, and returns how many it published.
func DrainSpool(dir string, publish func(events.Event)) int {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var names []string
	for _, e := range ents {
		if n := e.Name(); strings.HasSuffix(n, ".json") && !strings.HasPrefix(n, ".") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	n := 0
	for _, name := range names {
		path := filepath.Join(dir, name)
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var e events.Event
		if json.Unmarshal(b, &e) == nil && e.Type != "" {
			e.Seq = 0
			if e.Data == nil {
				e.Data = map[string]any{}
			}
			e.Data["spooled"] = true
			publish(e)
			n++
		}
		os.Remove(path)
	}
	return n
}
