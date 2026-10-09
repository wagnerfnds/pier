package events

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func openTest(t testing.TB, dir string, maxSeg int64) *Journal {
	t.Helper()
	j := &Journal{Dir: dir, MaxSegment: maxSeg}
	if err := j.open(); err != nil {
		t.Fatal(err)
	}
	return j
}

func readAll(t *testing.T, j *Journal, since int64) []int64 {
	t.Helper()
	it := j.Iter(since, 0)
	defer it.Close()
	var out []int64
	for {
		e, ok := it.Next()
		if !ok {
			break
		}
		out = append(out, e.Seq)
	}
	return out
}

func TestJournalNumbersReplaysAndSurvivesARestart(t *testing.T) {
	dir := t.TempDir()
	j := openTest(t, dir, 0)
	for i := range 10 {
		e := Event{Type: "agent.finished", Time: time.Now(), Data: map[string]any{"i": i}}
		if err := j.Append(&e); err != nil || e.Seq != int64(i+1) {
			t.Fatalf("append %d: seq %d, %v", i, e.Seq, err)
		}
	}
	if got := readAll(t, j, 7); fmt.Sprint(got) != "[8 9 10]" {
		t.Fatalf("since 7 = %v", got)
	}
	j.Close()

	// A torn last line, as a crash mid-write leaves, is cut off.
	segs, _ := os.ReadDir(dir)
	f, _ := os.OpenFile(filepath.Join(dir, segs[0].Name()), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"seq":11,"type":"agent.fin`)
	f.Close()

	j = openTest(t, dir, 0)
	defer j.Close()
	if j.Head() != 10 {
		t.Fatalf("head after restart = %d", j.Head())
	}
	e := Event{Type: "x"}
	j.Append(&e)
	if e.Seq != 11 {
		t.Fatalf("seq after restart = %d", e.Seq)
	}
	// Not in memory any more: read from disk.
	if got := readAll(t, j, 0); len(got) != 11 || got[10] != 11 {
		t.Fatalf("replay from disk = %v", got)
	}
}

func TestJournalRotatesAndCapsItsSize(t *testing.T) {
	dir := t.TempDir()
	j := openTest(t, dir, 2048)
	j.MaxTotal = 8 << 10
	defer j.Close()
	pad := string(make([]byte, 100))
	for range 600 {
		e := Event{Type: "agent.started", Data: map[string]any{"pad": pad}}
		j.Append(&e)
	}
	segs, _ := j.segments()
	if len(segs) < 2 {
		t.Fatalf("no rotation: %v", segs)
	}
	st := j.Stats()
	if st.Bytes > j.MaxTotal+j.MaxSegment {
		t.Fatalf("journal grew to %d bytes past its cap", st.Bytes)
	}
	// Reading from a pruned Seq starts at the oldest kept, in order.
	got := readAll(t, j, 0)
	if len(got) == 0 || got[len(got)-1] != 600 {
		t.Fatalf("replay = %d events ending %v", len(got), got[len(got)-1:])
	}
	for i := 1; i < len(got); i++ {
		if got[i] != got[i-1]+1 {
			t.Fatalf("gap at %d: %d after %d", i, got[i], got[i-1])
		}
	}
	// From a Seq older than the tail but still on disk.
	if got := readAll(t, j, 590); fmt.Sprint(got) != "[591 592 593 594 595 596 597 598 599 600]" {
		t.Fatalf("since 590 = %v", got)
	}
}

func TestJournalSeqAtMapsTimesToSeqs(t *testing.T) {
	j := openTest(t, t.TempDir(), 0)
	defer j.Close()
	base := time.Now()
	for i := range 5 {
		e := Event{Type: "x", Time: base.Add(time.Duration(i) * time.Second)}
		j.Append(&e)
	}
	if s, ok := j.SeqAt(base.Add(2500 * time.Millisecond)); !ok || s != 4 {
		t.Fatalf("SeqAt mid = %d %v", s, ok)
	}
	if s, ok := j.SeqAt(base.Add(time.Hour)); !ok || s != 6 {
		t.Fatalf("SeqAt future = %d %v; want head+1", s, ok)
	}
	if _, ok := j.SeqAt(base.Add(-time.Hour)); ok {
		t.Fatal("SeqAt claimed to know a time older than its tail")
	}
}

// A cursor that falls far behind catches up from the journal: it loses
// nothing, and holds no more than its small buffer meanwhile.
func TestLaggedCursorCatchesUpFromTheJournal(t *testing.T) {
	j := openTest(t, t.TempDir(), 0)
	defer j.Close()
	b := &Bus{Journal: j}
	c := b.SubscribeFrom(-1).Named("slow")
	defer c.Close()
	for range 1000 {
		b.Publish(Event{Type: "agent.finished"})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for want := int64(1); want <= 1000; want++ {
		e, err := c.Next(ctx)
		if err != nil || e.Seq != want {
			t.Fatalf("event %d: got seq %d, %v", want, e.Seq, err)
		}
	}
	st := b.Stats()
	if len(st) != 1 || st[0].Lags == 0 || st[0].Dropped != 0 {
		t.Fatalf("stats = %+v", st)
	}
	// And from an older point, as GET /v1/events?since= does.
	old := b.SubscribeFrom(995)
	defer old.Close()
	for want := int64(996); want <= 1000; want++ {
		if e, err := old.Next(ctx); err != nil || e.Seq != want {
			t.Fatalf("since 995: got %d, %v", e.Seq, err)
		}
	}
}

func TestObserversSeeEveryEventInOrder(t *testing.T) {
	b := &Bus{Sequence: true}
	var mu sync.Mutex
	var got []int64
	stop := b.Observe(func(e Event) { mu.Lock(); got = append(got, e.Seq); mu.Unlock() })
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 10 {
				b.Publish(Event{Type: "x"})
			}
		}()
	}
	wg.Wait()
	stop()
	b.Publish(Event{Type: "x"})
	if len(got) != 640 {
		t.Fatalf("observed %d of 640", len(got))
	}
	for i, s := range got {
		if s != int64(i+1) {
			t.Fatalf("out of order at %d: %d", i, s)
		}
	}
}

// E15: 400 events at 64-way all reach the journal and a cursor.
func TestBurstOf400At64WayIsAllRecorded(t *testing.T) {
	j := openTest(t, t.TempDir(), 0)
	defer j.Close()
	b := &Bus{Journal: j}
	c := b.SubscribeFrom(-1)
	defer c.Close()
	observed := 0
	b.Observe(func(Event) { observed++ })
	var wg sync.WaitGroup
	for w := range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 400 / 64 {
				b.Publish(Event{Type: "agent.finished", Data: map[string]any{"path": fmt.Sprintf("/w/%d-%d", w, i)}})
			}
		}()
	}
	for i := range 400 % 64 {
		b.Publish(Event{Type: "agent.finished", Data: map[string]any{"path": fmt.Sprintf("/w/x-%d", i)}})
	}
	wg.Wait()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	n := 0
	for n < 400 {
		if _, err := c.Next(ctx); err != nil {
			break
		}
		n++
	}
	if observed != 400 || n != 400 || j.Head() != 400 {
		t.Fatalf("observed %d, cursor %d, journal %d of 400", observed, n, j.Head())
	}
}

func BenchmarkPublishJournaled(b *testing.B) {
	j := openTest(b, b.TempDir(), 0)
	defer j.Close()
	bus := &Bus{Journal: j}
	bus.Observe(func(Event) {})
	c := bus.SubscribeFrom(-1)
	defer c.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		for {
			if _, err := c.Next(ctx); err != nil {
				return
			}
		}
	}()
	data := map[string]any{"path": "/srv/acme/shop/.worktrees/feat-a", "agent": "claude", "session": "shop-feat-a-claude"}
	b.ReportAllocs()
	b.SetParallelism(16) // 16 × GOMAXPROCS publishers, as a burst of hooks
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			bus.Publish(Event{Type: "agent.finished", Origin: "claude", Data: data})
		}
	})
}
