package events

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Journal is the box's event log: append-only JSONL segments in Dir, each
// event numbered by a monotonic Seq. It is what lets a subscriber that fell
// behind, or a laptop that slept, catch up instead of losing events.
//
// Memory stays bounded whatever the log's size: the journal keeps only the
// last tailSize events and a sparse offset index in memory, and reading
// from an older Seq streams the segments from disk a line at a time.
//
// Appends are written at once and made durable in groups: one fsync per
// SyncEvery, not one per event.
type Journal struct {
	Dir string
	// MaxSegment rotates to a new segment past this size (default 16 MB).
	MaxSegment int64
	// MaxTotal caps the segments kept on disk (default 256 MB), and MaxAge
	// drops older ones (default 14 days). The current segment is never
	// dropped.
	MaxTotal int64
	MaxAge   time.Duration
	// SyncEvery is the group-commit interval (default 50 ms).
	SyncEvery time.Duration

	mu       sync.Mutex
	f        *os.File
	segStart int64 // first Seq of the current segment
	size     int64 // bytes in the current segment
	seq      int64 // last Seq assigned
	dirty    bool
	retired  []*os.File // rotated segments still to be synced and closed
	tail     [tailSize]tailEntry
	tailN    int // entries filled, at most tailSize
	tailAt   int // next slot to write
	index    []indexEntry
	errs     uint64
	syncs    uint64
	closed   bool
	stop     chan struct{}
	stopped  chan struct{}
	// wake tells syncLoop something was written.
	wake chan struct{}
}

const (
	tailSize     = 256
	indexEvery   = 512
	maxIndex     = 2048
	maxLine      = 4 << 20
	segmentExt   = ".jsonl"
	defaultSeg   = 16 << 20
	defaultTotal = 256 << 20
	defaultAge   = 14 * 24 * time.Hour
)

type tailEntry struct {
	seq  int64
	at   time.Time
	line []byte
}

// indexEntry says where an event starts, so reading from an old Seq can
// seek near it instead of scanning its segment from the start.
type indexEntry struct {
	seq, seg, off int64
}

// OpenJournal opens (or creates) the journal in dir and starts its
// group-commit loop. A segment cut short by a crash loses only its torn
// last line.
func OpenJournal(dir string) (*Journal, error) {
	j := &Journal{Dir: dir}
	if err := j.open(); err != nil {
		return nil, err
	}
	return j, nil
}

func (j *Journal) open() error {
	if j.MaxSegment <= 0 {
		j.MaxSegment = defaultSeg
	}
	if j.MaxTotal <= 0 {
		j.MaxTotal = defaultTotal
	}
	if j.MaxAge <= 0 {
		j.MaxAge = defaultAge
	}
	if j.SyncEvery <= 0 {
		j.SyncEvery = 50 * time.Millisecond
	}
	if err := os.MkdirAll(j.Dir, 0o700); err != nil {
		return err
	}
	segs, err := j.segments()
	if err != nil {
		return err
	}
	if len(segs) == 0 {
		if err := j.startSegment(1); err != nil {
			return err
		}
	} else {
		last := segs[len(segs)-1]
		f, err := os.OpenFile(j.segPath(last), os.O_RDWR|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		seq, size, err := recoverTail(f, last)
		if err != nil {
			f.Close()
			return err
		}
		j.f, j.segStart, j.size, j.seq = f, last, size, seq
	}
	j.stop, j.stopped, j.wake = make(chan struct{}), make(chan struct{}), make(chan struct{}, 1)
	go j.syncLoop()
	return nil
}

// recoverTail finds the last Seq in a segment by reading only its end, and
// cuts off a torn last line.
func recoverTail(f *os.File, start int64) (seq, size int64, err error) {
	info, err := f.Stat()
	if err != nil {
		return 0, 0, err
	}
	size = info.Size()
	if size == 0 {
		return start - 1, 0, nil
	}
	for chunk := int64(64 << 10); ; chunk *= 4 {
		from := max(size-chunk, 0)
		buf := make([]byte, size-from)
		if _, err := f.ReadAt(buf, from); err != nil && err != io.EOF {
			return 0, 0, err
		}
		end := bytes.LastIndexByte(buf, '\n')
		if end < 0 {
			if from == 0 {
				// Not one whole line: the segment is all torn.
				if err := f.Truncate(0); err != nil {
					return 0, 0, err
				}
				return start - 1, 0, nil
			}
			continue
		}
		if int64(end) != int64(len(buf))-1 {
			if err := f.Truncate(from + int64(end) + 1); err != nil {
				return 0, 0, err
			}
			size = from + int64(end) + 1
		}
		body := buf[:end]
		lineStart := bytes.LastIndexByte(body, '\n') + 1
		if lineStart == 0 && from > 0 {
			continue // the last line is longer than this chunk
		}
		var e struct {
			Seq int64 `json:"seq"`
		}
		if json.Unmarshal(body[lineStart:], &e) != nil || e.Seq == 0 {
			return 0, 0, fmt.Errorf("journal %s: unreadable last line", f.Name())
		}
		return e.Seq, size, nil
	}
}

func (j *Journal) segPath(start int64) string {
	return filepath.Join(j.Dir, fmt.Sprintf("%016d%s", start, segmentExt))
}

// segments lists the segments' first Seqs in order.
func (j *Journal) segments() ([]int64, error) {
	ents, err := os.ReadDir(j.Dir)
	if err != nil {
		return nil, err
	}
	var out []int64
	for _, e := range ents {
		name, ok := strings.CutSuffix(e.Name(), segmentExt)
		if !ok {
			continue
		}
		if n, err := strconv.ParseInt(name, 10, 64); err == nil && n > 0 {
			out = append(out, n)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a] < out[b] })
	return out, nil
}

func (j *Journal) startSegment(start int64) error {
	f, err := os.OpenFile(j.segPath(start), os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if j.f != nil {
		j.retired = append(j.retired, j.f)
	}
	j.f, j.segStart, j.size = f, start, 0
	if j.seq < start-1 {
		j.seq = start - 1
	}
	return nil
}

// Append numbers e and writes it. The Seq is assigned even when the write
// fails, so numbering stays monotonic; Errors counts such failures.
func (j *Journal) Append(e *Event) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.seq++
	e.Seq = j.seq
	line, err := json.Marshal(e)
	if err != nil {
		j.errs++
		return err
	}
	line = append(line, '\n')
	if j.closed {
		j.errs++
		return errors.New("journal closed")
	}
	if j.size > 0 && j.size+int64(len(line)) > j.MaxSegment {
		if err := j.startSegment(e.Seq); err != nil {
			j.errs++
			return err
		}
		j.prune()
	}
	off := j.size
	n, err := j.f.Write(line)
	j.size += int64(n)
	if err != nil {
		j.errs++
		return err
	}
	j.dirty = true
	select {
	case j.wake <- struct{}{}:
	default:
	}
	j.tail[j.tailAt] = tailEntry{e.Seq, e.Time, line}
	j.tailAt = (j.tailAt + 1) % tailSize
	j.tailN = min(j.tailN+1, tailSize)
	if e.Seq%indexEvery == 0 {
		j.index = append(j.index, indexEntry{e.Seq, j.segStart, off})
		if len(j.index) > maxIndex {
			j.index = append(j.index[:0], j.index[len(j.index)-maxIndex/2:]...)
		}
	}
	return nil
}

// prune drops segments past MaxAge or beyond MaxTotal, oldest first; the
// caller holds j.mu.
func (j *Journal) prune() {
	segs, err := j.segments()
	if err != nil {
		return
	}
	var total int64
	sizes := make([]int64, len(segs))
	old := make([]bool, len(segs))
	for i, s := range segs {
		if info, err := os.Stat(j.segPath(s)); err == nil {
			sizes[i] = info.Size()
			old[i] = time.Since(info.ModTime()) > j.MaxAge
		}
		total += sizes[i]
	}
	for i, s := range segs {
		if s == j.segStart || (!old[i] && total <= j.MaxTotal) {
			continue
		}
		if os.Remove(j.segPath(s)) == nil {
			total -= sizes[i]
		}
	}
	kept := j.index[:0]
	for _, ie := range j.index {
		if _, err := os.Stat(j.segPath(ie.seg)); err == nil {
			kept = append(kept, ie)
		}
	}
	j.index = kept
}

// syncLoop makes appends durable within SyncEvery of the first of them,
// with one fsync for all that came in between. It sleeps while nothing is
// written: a ticker here woke an idle box twenty times a second.
func (j *Journal) syncLoop() {
	defer close(j.stopped)
	for {
		select {
		case <-j.stop:
			j.Sync()
			return
		case <-j.wake:
		}
		t := time.NewTimer(j.SyncEvery)
		select {
		case <-j.stop:
			t.Stop()
			j.Sync()
			return
		case <-t.C:
			j.Sync()
		}
	}
}

// Sync makes every append so far durable. The fsync runs outside the lock,
// so publishers never wait for the disk.
func (j *Journal) Sync() error {
	j.mu.Lock()
	f, dirty, retired := j.f, j.dirty, j.retired
	j.dirty, j.retired = false, nil
	if dirty {
		j.syncs++
	}
	j.mu.Unlock()
	for _, r := range retired {
		r.Sync()
		r.Close()
	}
	if !dirty || f == nil {
		return nil
	}
	return f.Sync()
}

// Close syncs and closes the journal.
func (j *Journal) Close() error {
	j.mu.Lock()
	if j.closed {
		j.mu.Unlock()
		return nil
	}
	j.closed = true
	j.mu.Unlock()
	close(j.stop)
	<-j.stopped
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.f.Close()
}

// Head is the last Seq assigned.
func (j *Journal) Head() int64 {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.seq
}

// JournalStats is what doctor shows about the journal.
type JournalStats struct {
	Head     int64  `json:"head"`
	Segments int    `json:"segments"`
	Bytes    int64  `json:"bytes"`
	Errors   uint64 `json:"errors"`
	Syncs    uint64 `json:"syncs"`
}

func (j *Journal) Stats() JournalStats {
	j.mu.Lock()
	st := JournalStats{Head: j.seq, Errors: j.errs, Syncs: j.syncs}
	j.mu.Unlock()
	segs, _ := j.segments()
	st.Segments = len(segs)
	for _, s := range segs {
		if info, err := os.Stat(j.segPath(s)); err == nil {
			st.Bytes += info.Size()
		}
	}
	return st
}

// SeqAt is the first Seq at or after t that the in-memory tail can vouch
// for: Head+1 when t is after every event in it, and ok false when t is
// older than the tail.
func (j *Journal) SeqAt(t time.Time) (seq int64, ok bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.tailN == 0 {
		return j.seq + 1, true
	}
	oldest := (j.tailAt - j.tailN + tailSize) % tailSize
	if t.Before(j.tail[oldest].at) {
		return 0, false
	}
	seq = j.seq + 1
	for i := j.tailN - 1; i >= 0; i-- {
		e := j.tail[(oldest+i)%tailSize]
		if e.at.Before(t) {
			break
		}
		seq = e.seq
	}
	return seq, true
}

// Iter reads events with since < Seq <= until in order. It holds at most
// one line in memory and an open segment; Close releases it.
type Iter struct {
	j      *Journal
	since  int64
	until  int64
	mem    [][]byte // from the tail, when it covers since
	segs   []int64
	f      *os.File
	r      *bufio.Reader
	err    error
	closed bool
}

// Iter starts reading after since, up to until (0 means the current head).
func (j *Journal) Iter(since, until int64) *Iter {
	j.mu.Lock()
	defer j.mu.Unlock()
	if until <= 0 || until > j.seq {
		until = j.seq
	}
	it := &Iter{j: j, since: since, until: until}
	if since >= until {
		it.closed = true
		return it
	}
	oldest := (j.tailAt - j.tailN + tailSize) % tailSize
	if j.tailN > 0 && j.tail[oldest].seq <= since+1 {
		for i := 0; i < j.tailN; i++ {
			e := j.tail[(oldest+i)%tailSize]
			if e.seq > since && e.seq <= until {
				it.mem = append(it.mem, e.line)
			}
		}
		return it
	}
	segs, err := j.segments()
	if err != nil {
		it.err = err
		return it
	}
	// Start in the last segment that begins at or before since+1.
	first := 0
	for i, s := range segs {
		if s <= since+1 {
			first = i
		}
	}
	it.segs = segs[first:]
	// The sparse index may let the first segment start part way in.
	var seek int64
	for _, ie := range j.index {
		if len(it.segs) > 0 && ie.seg == it.segs[0] && ie.seq <= since+1 {
			seek = ie.off
		}
	}
	if len(it.segs) > 0 {
		it.openSeg(seek)
	}
	return it
}

func (it *Iter) openSeg(seek int64) {
	if it.f != nil {
		it.f.Close()
		it.f = nil
	}
	if len(it.segs) == 0 {
		return
	}
	f, err := os.Open(it.j.segPath(it.segs[0]))
	it.segs = it.segs[1:]
	if err != nil {
		// Pruned while we read: carry on with the next.
		it.openSeg(0)
		return
	}
	if seek > 0 {
		f.Seek(seek, io.SeekStart)
	}
	it.f = f
	if it.r == nil {
		it.r = bufio.NewReaderSize(f, 64<<10)
	} else {
		it.r.Reset(f)
	}
}

// Next returns the next event, or ok false at the end.
func (it *Iter) Next() (Event, bool) {
	for !it.closed {
		var line []byte
		if it.mem != nil {
			if len(it.mem) == 0 {
				it.Close()
				break
			}
			line, it.mem = it.mem[0], it.mem[1:]
		} else {
			if it.f == nil {
				it.Close()
				break
			}
			l, err := it.r.ReadSlice('\n')
			if err == bufio.ErrBufferFull {
				// A line longer than the buffer: gather it, bounded.
				big := append([]byte(nil), l...)
				for err == bufio.ErrBufferFull && len(big) < maxLine {
					l, err = it.r.ReadSlice('\n')
					big = append(big, l...)
				}
				l = big
			}
			if err != nil && err != bufio.ErrBufferFull {
				if len(l) == 0 || l[len(l)-1] != '\n' {
					it.openSeg(0)
					continue
				}
			}
			line = l
		}
		var e Event
		if json.Unmarshal(line, &e) != nil || e.Seq <= it.since {
			continue
		}
		if e.Seq > it.until {
			it.Close()
			break
		}
		it.since = e.Seq
		return e, true
	}
	return Event{}, false
}

func (it *Iter) Err() error { return it.err }

func (it *Iter) Close() {
	it.closed = true
	it.mem = nil
	if it.f != nil {
		it.f.Close()
		it.f = nil
	}
}
