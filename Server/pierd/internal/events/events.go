// Package events is the one event model shared by the box, the laptop agent,
// and hooks. Every event records the tool it came from, so an integration
// never reacts to its own changes and bounces them back and forth.
package events

import (
	"context"
	"sort"
	"sync"
	"time"
)

// TranscriptChanged says an agent wrote to its transcript, which a chat is
// showing: sent at most every few hundred milliseconds per session while
// its agent writes (box/transcriptwatch.go), so the app reads it at once.
// It is chatter: "*" hooks don't run for it, only hooks that name it.
const TranscriptChanged = "transcript.changed"

// Chatty says events of type typ come too often for hooks on "*".
func Chatty(typ string) bool { return typ == TranscriptChanged }

type Event struct {
	// Seq numbers the box's events in the order they happened, from its
	// journal. It is 0 where nothing numbers them (the laptop's own events).
	Seq    int64          `json:"seq,omitempty"`
	Type   string         `json:"type"`
	Time   time.Time      `json:"time"`
	Box    string         `json:"box,omitempty"`
	Origin string         `json:"origin,omitempty"`
	Error  string         `json:"error,omitempty"`
	Data   map[string]any `json:"data,omitempty"`
}

// Bus fans events out. Publishing never blocks on a subscriber:
//
//   - Observers run synchronously, in order, while the event is published.
//     They are for small in-memory projections that must never miss one,
//     such as agent states.
//   - Cursors (SubscribeFrom) read in Seq order. One that falls behind is
//     marked lagged and catches up from the Journal, so with a journal it
//     loses nothing; each holds at most cursorBuffer events.
//   - Subscribe is the old live channel: a subscriber that falls behind
//     loses events, which Stats counts.
type Bus struct {
	// Journal, when set, numbers and keeps every event, and lets cursors
	// catch up. Sequence numbers events without keeping them.
	Journal  *Journal
	Sequence bool
	Now      func() time.Time

	mu      sync.Mutex
	seq     int64
	subs    map[chan Event]*subStat
	cursors map[*Cursor]struct{}
	obs     []*observer
}

type subStat struct {
	name    string
	dropped uint64
}

type observer struct{ fn func(Event) }

const cursorBuffer = 64

// Observe runs fn for every event, synchronously and in Seq order, until
// the returned func is called. fn must be quick and must not publish.
func (b *Bus) Observe(fn func(Event)) func() {
	o := &observer{fn}
	b.mu.Lock()
	b.obs = append(b.obs, o)
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		for i, x := range b.obs {
			if x == o {
				b.obs = append(b.obs[:i:i], b.obs[i+1:]...)
				return
			}
		}
	}
}

func (b *Bus) Subscribe() (<-chan Event, func()) {
	return b.SubscribeNamed("live")
}

// SubscribeNamed is Subscribe with a name for Stats.
func (b *Bus) SubscribeNamed(name string) (<-chan Event, func()) {
	ch := make(chan Event, cursorBuffer)
	b.mu.Lock()
	if b.subs == nil {
		b.subs = map[chan Event]*subStat{}
	}
	b.subs[ch] = &subStat{name: name}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		delete(b.subs, ch)
		b.mu.Unlock()
	}
}

// Publish stamps e with the current time unless it already has one, numbers
// it, journals it, and fans it out. It returns e as published.
func (b *Bus) Publish(e Event) Event {
	if e.Time.IsZero() {
		if b.Now != nil {
			e.Time = b.Now()
		} else {
			e.Time = time.Now()
		}
	}
	if e.Origin == "" {
		e.Origin = "pier"
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	switch {
	case b.Journal != nil:
		b.Journal.Append(&e)
		b.seq = e.Seq
	case b.Sequence:
		b.seq++
		e.Seq = b.seq
	}
	for _, o := range b.obs {
		o.fn(e)
	}
	for ch, st := range b.subs {
		select {
		case ch <- e:
		default:
			st.dropped++
		}
	}
	for c := range b.cursors {
		if c.lagged {
			if b.Journal == nil {
				c.dropped++
			}
			continue
		}
		select {
		case c.ch <- e:
		default:
			c.lagged = true
			c.lags++
			if b.Journal == nil {
				c.dropped++
			}
			select {
			case c.wake <- struct{}{}:
			default:
			}
		}
	}
	return e
}

// Head is the Seq of the last event published.
func (b *Bus) Head() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.seq
}

// Cursor reads the bus in Seq order from a starting point. Only one
// goroutine may call Next.
type Cursor struct {
	bus  *Bus
	ch   chan Event
	wake chan struct{}
	name string
	last int64
	it   *Iter
	// guarded by bus.mu
	lagged        bool
	lags, dropped uint64
}

// SubscribeFrom returns a cursor that delivers events after seq; a negative
// seq starts at the next event. Events older than the journal keeps are
// skipped.
func (b *Bus) SubscribeFrom(seq int64) *Cursor {
	c := &Cursor{bus: b, ch: make(chan Event, cursorBuffer), wake: make(chan struct{}, 1), name: "cursor"}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cursors == nil {
		b.cursors = map[*Cursor]struct{}{}
	}
	b.cursors[c] = struct{}{}
	if seq < 0 || seq >= b.seq || b.Journal == nil {
		c.last = b.seq
	} else {
		c.last, c.lagged = seq, true
	}
	return c
}

// Named labels the cursor in Stats.
func (c *Cursor) Named(name string) *Cursor {
	c.bus.mu.Lock()
	c.name = name
	c.bus.mu.Unlock()
	return c
}

// Close stops the cursor.
func (c *Cursor) Close() {
	c.bus.mu.Lock()
	delete(c.bus.cursors, c)
	c.bus.mu.Unlock()
	if c.it != nil {
		c.it.Close()
		c.it = nil
	}
}

// Next returns the next event in Seq order, catching up from the journal
// when the cursor fell behind. It returns ctx's error when ctx ends.
func (c *Cursor) Next(ctx context.Context) (Event, error) {
	for {
		if c.it != nil {
			if e, ok := c.it.Next(); ok {
				if e.Seq > c.last {
					c.last = e.Seq
					return e, nil
				}
				continue
			}
			c.it.Close()
			c.it = nil
		}
		select {
		case e := <-c.ch:
			if e.Seq != 0 && e.Seq <= c.last {
				continue
			}
			c.last = max(c.last, e.Seq)
			return e, nil
		default:
		}
		b := c.bus
		b.mu.Lock()
		if c.lagged && len(c.ch) == 0 {
			c.lagged = false
			head := b.seq
			b.mu.Unlock()
			if b.Journal != nil && head > c.last {
				c.it = b.Journal.Iter(c.last, head)
			} else {
				c.last = max(c.last, head)
			}
			continue
		}
		b.mu.Unlock()
		select {
		case <-ctx.Done():
			return Event{}, ctx.Err()
		case e := <-c.ch:
			if e.Seq != 0 && e.Seq <= c.last {
				continue
			}
			c.last = max(c.last, e.Seq)
			return e, nil
		case <-c.wake:
		}
	}
}

// SubStats is one subscriber's health, for doctor.
type SubStats struct {
	Name string `json:"name"`
	// Lags counts the times a cursor fell behind and caught up from the
	// journal; Dropped counts events a subscriber lost for good.
	Lags    uint64 `json:"lags,omitempty"`
	Dropped uint64 `json:"dropped"`
	Pending int    `json:"pending"`
}

// Stats reports every subscriber, worst first.
func (b *Bus) Stats() []SubStats {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []SubStats
	for ch, st := range b.subs {
		out = append(out, SubStats{Name: st.name, Dropped: st.dropped, Pending: len(ch)})
	}
	for c := range b.cursors {
		out = append(out, SubStats{Name: c.name, Lags: c.lags, Dropped: c.dropped, Pending: len(c.ch)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dropped != out[j].Dropped {
			return out[i].Dropped > out[j].Dropped
		}
		return out[i].Name < out[j].Name
	})
	return out
}
