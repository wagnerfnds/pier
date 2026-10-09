package box

import (
	"os"
	"sync"
	"time"

	"pier/pierd/internal/events"
)

// A chat shows each step the moment the agent writes it: the box watches
// the transcript of every session a chat has read in the last few seconds
// and, once a write settles, sends transcript.changed, on which the app
// reads the transcript at once instead of on its next 2-second look.
//
// It is a stat of the file, not a file-system watch: a handful of files at
// most, on macOS and Linux alike, with nothing to set up. The file is
// looked at every 100ms while its agent works and every second while it
// rests; a chat that stops reading (hidden, closed) stops the watching
// after watchFor, and with nothing to watch the loop ends. Apps on boxes
// without it read every 2s as before.

const (
	// A showing chat reads every 2s: one that hasn't for this long has gone.
	watchFor = 8 * time.Second
	// How often a file is looked at, while its agent works and at rest.
	watchBusy = 100 * time.Millisecond
	watchIdle = time.Second
	// A write has settled once the file has been still this long, or been
	// written to for settleMax: an agent writes a step as a few lines.
	settleFor = 90 * time.Millisecond
	settleMax = 350 * time.Millisecond
)

type transcriptWatch struct {
	mu    sync.Mutex
	files map[string]*watchedFile
	loop  bool
	// manual: the caller drives tick (tests).
	manual  bool
	now     func() time.Time
	busy    func(session string) bool
	publish func(session, dir string, size int64)
}

type watchedFile struct {
	path, dir string
	// When a chat last read it.
	read      time.Time
	size      int64
	mod       time.Time
	next      time.Time
	pending   bool
	first     time.Time // the first change not yet sent
	lastWrite time.Time
}

var transcriptWatches sync.Map // *Box → *transcriptWatch

// transcriptWatch is the box's watcher, made on first use.
func (b *Box) transcriptWatch() *transcriptWatch {
	if w, ok := transcriptWatches.Load(b); ok {
		return w.(*transcriptWatch)
	}
	w := newTranscriptWatch(func(name, dir string, size int64) {
		b.Events.Publish(events.Event{Type: events.TranscriptChanged, Box: b.Name, Data: map[string]any{"session": name, "name": name, "path": dir, "size": size}})
	})
	w.busy = func(name string) bool {
		if b.Turns == nil {
			return true
		}
		st, ok := b.Turns.State(name)
		return !ok || st.State == "running" || st.State == "waiting" || st.State == "pending"
	}
	got, _ := transcriptWatches.LoadOrStore(b, w)
	return got.(*transcriptWatch)
}

func newTranscriptWatch(publish func(session, dir string, size int64)) *transcriptWatch {
	return &transcriptWatch{files: map[string]*watchedFile{}, now: time.Now, busy: func(string) bool { return true }, publish: publish}
}

// seen notes that a chat read session's transcript at path (the agent's
// record; dir is the session's folder, which events name as "path").
func (w *transcriptWatch) seen(session, dir, path string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	now := w.now()
	f := w.files[session]
	if f == nil || f.path != path {
		// What the file holds now is what the chat just read.
		f = &watchedFile{path: path, dir: dir}
		f.size, f.mod, _ = statFile(path)
		w.files[session] = f
	}
	f.read = now
	if !w.loop && !w.manual {
		w.loop = true
		go w.run()
	}
}

func (w *transcriptWatch) run() {
	t := time.NewTicker(watchBusy)
	defer t.Stop()
	for range t.C {
		if !w.tick() {
			return
		}
	}
}

// tick looks at the files that are due, sends what settled, and says
// whether anything is left to watch.
func (w *transcriptWatch) tick() bool {
	type change struct {
		session, dir string
		size         int64
	}
	var out []change
	w.mu.Lock()
	now := w.now()
	for session, f := range w.files {
		if now.Sub(f.read) > watchFor {
			delete(w.files, session)
			continue
		}
		if now.Before(f.next) && !f.pending {
			continue
		}
		every := watchIdle
		if w.busy(session) {
			every = watchBusy
		}
		f.next = now.Add(every)
		if size, mod, ok := statFile(f.path); ok && (size != f.size || !mod.Equal(f.mod)) {
			f.size, f.mod, f.lastWrite = size, mod, now
			if !f.pending {
				f.pending, f.first = true, now
			}
		}
		if f.pending && (now.Sub(f.lastWrite) >= settleFor || now.Sub(f.first) >= settleMax) {
			f.pending = false
			out = append(out, change{session, f.dir, f.size})
		}
	}
	left := len(w.files) > 0
	if !left {
		w.loop = false
	}
	w.mu.Unlock()
	for _, c := range out {
		w.publish(c.session, c.dir, c.size)
	}
	return left
}

func statFile(path string) (int64, time.Time, bool) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, time.Time{}, false
	}
	return fi.Size(), fi.ModTime(), true
}
