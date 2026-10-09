package recap

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type fakeRunner struct {
	calls  atomic.Int32
	out    string
	err    error
	delay  time.Duration
	prompt atomic.Value
}

func (f *fakeRunner) Run(ctx context.Context, prompt string) (string, error) {
	f.calls.Add(1)
	f.prompt.Store(prompt)
	if f.delay > 0 {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(f.delay):
		}
	}
	return f.out, f.err
}

func TestRecapRunsOncePerTurn(t *testing.T) {
	f := &fakeRunner{out: "Adicionei mul() em calc.py e os testes passam.\n"}
	c := New(f)
	since := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	for i := 0; i < 3; i++ {
		if got := c.Recap(context.Background(), "s1", since, long+"long reply"); got != "Adicionei mul() em calc.py e os testes passam." {
			t.Fatalf("recap %q", got)
		}
	}
	if f.calls.Load() != 1 {
		t.Fatalf("ran %d times for one turn", f.calls.Load())
	}
	c.Recap(context.Background(), "s1", since.Add(time.Minute), long+"next turn")
	c.Recap(context.Background(), "s2", since, long+"other session")
	if f.calls.Load() != 3 {
		t.Fatalf("a new turn or session must run again: %d", f.calls.Load())
	}
	if p, _ := f.prompt.Load().(string); !strings.HasSuffix(p, long+"other session") || !strings.Contains(p, "the language the report is written in") {
		t.Fatalf("prompt %q", p)
	}
}

func TestRecapFailureIsEmptyAndNotRetried(t *testing.T) {
	f := &fakeRunner{err: errors.New("exit status 1")}
	c := New(f)
	since := time.Now()
	if got := c.Recap(context.Background(), "s1", since, long+"reply"); got != "" {
		t.Fatalf("failure gave %q", got)
	}
	c.Recap(context.Background(), "s1", since, long+"reply")
	if f.calls.Load() != 1 {
		t.Fatalf("a failed turn was retried: %d", f.calls.Load())
	}
}

func TestRecapTimesOut(t *testing.T) {
	f := &fakeRunner{out: "late", delay: time.Second}
	c := &Recapper{Run: f, Timeout: 30 * time.Millisecond}
	start := time.Now()
	if got := c.Recap(context.Background(), "s1", time.Now(), long+"reply"); got != "" {
		t.Fatalf("timed out recap gave %q", got)
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatalf("the deadline was not applied: %v", time.Since(start))
	}
}

func TestRecapSkipsEmptyReplyAndNil(t *testing.T) {
	f := &fakeRunner{out: "x"}
	if New(f).Recap(context.Background(), "s", time.Now(), "  \n") != "" || f.calls.Load() != 0 {
		t.Fatal("an empty reply must not run the model")
	}
	var c *Recapper
	if c.Recap(context.Background(), "s", time.Now(), long+"reply") != "" {
		t.Fatal("nil recapper")
	}
}

func TestClean(t *testing.T) {
	cases := map[string]string{
		"\n\n  \"Fixed the **login** bug.\"  \nmore": "Fixed the login bug.",
		"Resumo: Adicionei `mul` e testes.":          "Adicionei mul e testes.",
		"“Corrigi o cálculo do frete.”":              "Corrigi o cálculo do frete.",
		"Error: Invalid API key · Please run /login": "",
		"Fixed the error: handling in the parser.":   "Fixed the error: handling in the parser.",
		"": "",
	}
	for in, want := range cases {
		if got := Clean(in); got != want {
			t.Errorf("Clean(%q) = %q, want %q", in, got, want)
		}
	}
	if got := []rune(Clean(strings.Repeat("palavra ", 40))); len(got) != MaxLen || got[MaxLen-1] != '…' {
		t.Errorf("long recap not clipped to %d: %d", MaxLen, len(got))
	}
}

func TestPromptCapsAHugeReply(t *testing.T) {
	p := Prompt(strings.Repeat("a", 5000) + "MIDDLE" + strings.Repeat("b", 5000))
	if strings.Contains(p, "MIDDLE") || !strings.Contains(p, "…") || len([]rune(p)) > 7000 {
		t.Fatalf("prompt not capped (%d runes)", len([]rune(p)))
	}
}

// The real runner against a stand-in script (never the real claude): flags, stdin, home directory, no PIER_* env.
func TestClaudeRunnerUsesStdinHomeAndCleanEnv(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "claude")
	script := "#!/bin/sh\necho \"args=$*\"\necho \"pwd=$(pwd)\"\necho \"session=${PIER_SESSION:-none}\"\nprintf 'stdin='; cat\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PIER_SESSION", "sandbox-claude-1")
	out, err := Claude{Bin: bin}.Run(context.Background(), "hello")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"args=-p --model haiku --strict-mcp-config --no-session-persistence --disable-slash-commands --tools ", "session=none", "stdin=hello"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in %q", want, out)
		}
	}
	real, _ := filepath.EvalSymlinks(home)
	if !strings.Contains(out, "pwd="+home) && !strings.Contains(out, "pwd="+real) {
		t.Fatalf("not run from home %q: %q", home, out)
	}
}

// A CLI that does not know the lean flags still answers: the runner retries plain.
func TestClaudeRunnerFallsBackForAnOlderCLI(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\ncase \"$*\" in *--tools*) echo \"error: unknown option '--tools'\" >&2; exit 1;; esac\necho \"args=$*\"\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := Claude{Bin: bin}.Run(context.Background(), "hello")
	if err != nil || strings.TrimSpace(out) != "args=-p --model haiku" {
		t.Fatalf("out %q err %v", out, err)
	}
}

func TestClaudeRunnerWithoutBinary(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	if FindClaude() != "" {
		t.Skip("a system-wide claude is installed")
	}
	if _, err := (Claude{}).Run(context.Background(), "x"); !errors.Is(err, ErrNoCLI) {
		t.Fatalf("err %v", err)
	}
}

// long is a reply that does not fit a notification: the model is asked.
const long = "Adicionei mul() em calc.py.\n\nTambém escrevi test_mul em test_calc.py e rodei a suíte inteira; os 14 testes passam. "

// A reply that already fits is shown as it is: the model is not asked.
func TestAShortReplyIsNotRecapped(t *testing.T) {
	calls := 0
	c := New(runnerFunc(func(context.Context, string) (string, error) { calls++; return "Resumo.", nil }))
	if got := c.Recap(context.Background(), "s1", time.Now(), "Pronto: subtract em calc.py, testes passam."); got != "" || calls != 0 {
		t.Fatalf("recap %q after %d calls", got, calls)
	}
	if got := c.Recap(context.Background(), "s1", time.Now(), long); got != "Resumo." || calls != 1 {
		t.Fatalf("recap %q after %d calls", got, calls)
	}
}

type runnerFunc func(context.Context, string) (string, error)

func (f runnerFunc) Run(ctx context.Context, p string) (string, error) { return f(ctx, p) }
