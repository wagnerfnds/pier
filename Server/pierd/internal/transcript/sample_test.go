package transcript

import (
	"os"
	"runtime"
	"testing"
	"time"
)

// TestSample reads a real transcript named by PIER_TRANSCRIPT_SAMPLE
// (source:path) and reports sizes and timing only, never content.
func TestSample(t *testing.T) {
	spec := os.Getenv("PIER_TRANSCRIPT_SAMPLE")
	if spec == "" {
		t.Skip("set PIER_TRANSCRIPT_SAMPLE=claude:/path/to/file.jsonl")
	}
	source, path := spec[:5], spec[6:]
	if source == "claud" {
		source, path = "claude", spec[7:]
	}
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	start := time.Now()
	r := NewReader()
	res, err := r.Read(source, path, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	first := time.Since(start)
	start = time.Now()
	again, _ := r.Read(source, path, "", res.Next)
	second := time.Since(start)
	runtime.GC()
	runtime.ReadMemStats(&after)
	counts := map[string]int{}
	for _, it := range res.Items {
		counts[it.Kind]++
	}
	t.Logf("items=%d next=%d truncated=%v kinds=%v crew=%d first=%v again=%v (resent %d) heapKept=%dKB", len(res.Items), res.Next, res.Truncated, counts, len(res.Crew), first, second, len(again.Items), (int64(after.HeapAlloc)-int64(before.HeapAlloc))/1024)
}
