// Package sched has the two coalescing tools the push rules need: a keyed Debouncer (burst -> one call after quiet)
// and a keyed Throttle (at most one call per interval, the newest call wins the trailing slot).
package sched

import (
	"sync"
	"time"
)

// Debouncer runs fn once, `delay` after the last Do for a key.
type Debouncer struct {
	mu      sync.Mutex
	timers  map[string]*time.Timer
	gen     map[string]uint64
	stopped bool
}

func NewDebouncer() *Debouncer {
	return &Debouncer{timers: map[string]*time.Timer{}, gen: map[string]uint64{}}
}

func (d *Debouncer) Do(key string, delay time.Duration, fn func()) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.stopped {
		return
	}
	if t := d.timers[key]; t != nil {
		t.Stop()
	}
	d.gen[key]++
	g := d.gen[key]
	d.timers[key] = time.AfterFunc(delay, func() {
		d.mu.Lock()
		if d.gen[key] != g || d.stopped {
			d.mu.Unlock()
			return
		}
		delete(d.timers, key)
		delete(d.gen, key)
		d.mu.Unlock()
		fn()
	})
}

func (d *Debouncer) Cancel(key string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if t := d.timers[key]; t != nil {
		t.Stop()
		delete(d.timers, key)
	}
	d.gen[key]++
}

func (d *Debouncer) Stop() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.stopped = true
	for _, t := range d.timers {
		t.Stop()
	}
}

// Throttle lets one call per key through every `interval`. A call inside the window is held and runs at its end;
// a newer held call replaces an older one (the last state wins). `urgent` calls run at once and open a new window.
type Throttle struct {
	interval time.Duration
	now      func() time.Time

	mu      sync.Mutex
	last    map[string]time.Time
	pending map[string]*held
}

type held struct {
	timer *time.Timer
	fn    func()
}

func NewThrottle(interval time.Duration) *Throttle {
	return &Throttle{interval: interval, now: time.Now, last: map[string]time.Time{}, pending: map[string]*held{}}
}

func (t *Throttle) Do(key string, urgent bool, fn func()) {
	t.mu.Lock()
	now := t.now()
	if p := t.pending[key]; p != nil {
		if urgent {
			p.timer.Stop()
			delete(t.pending, key)
		} else {
			p.fn = fn // newest wins; the timer is already running
			t.mu.Unlock()
			return
		}
	}
	wait := t.last[key].Add(t.interval).Sub(now)
	if urgent || wait <= 0 {
		t.last[key] = now
		t.mu.Unlock()
		fn()
		return
	}
	h := &held{fn: fn}
	h.timer = time.AfterFunc(wait, func() {
		t.mu.Lock()
		if t.pending[key] != h {
			t.mu.Unlock()
			return
		}
		delete(t.pending, key)
		t.last[key] = t.now()
		f := h.fn
		t.mu.Unlock()
		f()
	})
	t.pending[key] = h
	t.mu.Unlock()
}

// Forget drops a key's history and any held call (the session is gone).
func (t *Throttle) Forget(key string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if p := t.pending[key]; p != nil {
		p.timer.Stop()
		delete(t.pending, key)
	}
	delete(t.last, key)
}
