package recap

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// standIn writes a fake claude. In stream-json mode it records its pid, reads one line and answers with a result
// that quotes it; otherwise (a cold run) it answers "cold". With old set, stream-json is an unknown option.
func standIn(t *testing.T, old bool) (bin, dir string) {
	t.Helper()
	dir = t.TempDir()
	bin = filepath.Join(dir, "claude")
	stream := `echo $$ >> "` + dir + `/pids"; read line; echo '{"type":"system"}'; echo "{\"type\":\"result\",\"is_error\":false,\"result\":\"warm $(echo "$line" | wc -c | tr -d ' ')\"}"`
	if old {
		stream = `echo "error: unknown option '--input-format'" >&2; exit 1`
	}
	script := "#!/bin/sh\ncase \"$*\" in *stream-json*) " + stream + ";; *) cat >/dev/null; echo cold;; esac\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, dir
}

func pids(dir string) int {
	b, _ := os.ReadFile(filepath.Join(dir, "pids"))
	return len(strings.Fields(string(b)))
}

func TestWarmAnswersOnTheWaitingProcessOncePerRecap(t *testing.T) {
	bin, dir := standIn(t, false)
	w := &Warm{Bin: bin}
	w.Prewarm()
	w.Prewarm() // one waiting is enough
	time.Sleep(200 * time.Millisecond)
	if n := pids(dir); n != 1 {
		t.Fatalf("%d processes waiting", n)
	}
	out, err := w.Run(context.Background(), "summarise this")
	if err != nil || !strings.HasPrefix(out, "warm ") {
		t.Fatalf("out %q err %v", out, err)
	}
	// The next recap gets a fresh process (started after this one answered), not this one again.
	out, _ = w.Run(context.Background(), "and this")
	time.Sleep(200 * time.Millisecond)
	if !strings.HasPrefix(out, "warm ") || pids(dir) != 3 {
		t.Fatalf("out %q, %d processes", out, pids(dir))
	}
	w.mu.Lock()
	if w.ready != nil {
		w.ready.stop()
	}
	w.mu.Unlock()
}

func TestWarmStopsAnUnusedProcess(t *testing.T) {
	bin, dir := standIn(t, false)
	w := &Warm{Bin: bin, Idle: 400 * time.Millisecond}
	w.Prewarm()
	time.Sleep(1200 * time.Millisecond)
	w.mu.Lock()
	waiting := w.ready != nil
	w.mu.Unlock()
	if waiting {
		t.Fatal("the idle process is still waiting")
	}
	b, _ := os.ReadFile(filepath.Join(dir, "pids"))
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	if pid == 0 {
		t.Fatal("the process never started")
	}
	if err := syscall.Kill(pid, 0); err == nil {
		t.Fatalf("the idle process %d still runs", pid)
	}
}

func TestWarmFallsBackToColdForAnOlderCLI(t *testing.T) {
	bin, _ := standIn(t, true)
	w := &Warm{Bin: bin}
	w.Prewarm()
	time.Sleep(100 * time.Millisecond)
	out, err := w.Run(context.Background(), "x")
	if err != nil || strings.TrimSpace(out) != "cold" {
		t.Fatalf("out %q err %v", out, err)
	}
	w.Prewarm()
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.broken || w.ready != nil {
		t.Fatal("kept starting processes the CLI cannot run")
	}
}
