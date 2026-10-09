package sched

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDebounceCoalescesABurst(t *testing.T) {
	d := NewDebouncer()
	defer d.Stop()
	var n, last int32
	var wg sync.WaitGroup
	wg.Add(1)
	for i := 1; i <= 10; i++ {
		i := i
		d.Do("s", 40*time.Millisecond, func() { atomic.AddInt32(&n, 1); atomic.StoreInt32(&last, int32(i)); wg.Done() })
		time.Sleep(5 * time.Millisecond)
	}
	wg.Wait()
	time.Sleep(80 * time.Millisecond)
	if atomic.LoadInt32(&n) != 1 || atomic.LoadInt32(&last) != 10 {
		t.Fatalf("ran %d times, last=%d; want once with the newest", n, last)
	}
}

func TestDebounceKeysAreIndependentAndCancel(t *testing.T) {
	d := NewDebouncer()
	defer d.Stop()
	var a, b int32
	d.Do("a", 20*time.Millisecond, func() { atomic.AddInt32(&a, 1) })
	d.Do("b", 20*time.Millisecond, func() { atomic.AddInt32(&b, 1) })
	d.Cancel("a")
	time.Sleep(80 * time.Millisecond)
	if atomic.LoadInt32(&a) != 0 || atomic.LoadInt32(&b) != 1 {
		t.Fatalf("a=%d b=%d", a, b)
	}
}

func TestThrottleLeadingThenTrailingLatestWins(t *testing.T) {
	th := NewThrottle(100 * time.Millisecond)
	var mu sync.Mutex
	var got []string
	rec := func(s string) func() { return func() { mu.Lock(); got = append(got, s); mu.Unlock() } }
	th.Do("s", false, rec("first"))  // leading edge: immediately
	th.Do("s", false, rec("second")) // held
	th.Do("s", false, rec("third"))  // replaces second
	mu.Lock()
	if len(got) != 1 || got[0] != "first" {
		t.Fatalf("leading edge: %v", got)
	}
	mu.Unlock()
	time.Sleep(200 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 2 || got[1] != "third" {
		t.Fatalf("trailing: %v", got)
	}
}

func TestThrottleUrgentBypasses(t *testing.T) {
	th := NewThrottle(time.Hour)
	var n int32
	th.Do("s", false, func() { atomic.AddInt32(&n, 1) })
	th.Do("s", false, func() { atomic.AddInt32(&n, 10) }) // held for an hour
	th.Do("s", true, func() { atomic.AddInt32(&n, 100) }) // runs now, and cancels the held one
	if atomic.LoadInt32(&n) != 101 {
		t.Fatalf("n=%d", n)
	}
}

func TestThrottleKeysIndependent(t *testing.T) {
	th := NewThrottle(time.Hour)
	var n int32
	th.Do("a", false, func() { atomic.AddInt32(&n, 1) })
	th.Do("b", false, func() { atomic.AddInt32(&n, 1) })
	if atomic.LoadInt32(&n) != 2 {
		t.Fatal(n)
	}
	th.Forget("a")
	th.Do("a", false, func() { atomic.AddInt32(&n, 1) })
	if atomic.LoadInt32(&n) != 3 {
		t.Fatal(n)
	}
}
