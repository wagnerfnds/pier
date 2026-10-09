package recap

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Warm runs recaps on a claude started ahead of time. Most of a `claude -p` is the CLI starting (measured on a box:
// 2.46s cold, 0.98s for one already waiting on stdin), so a process is started when an agent starts working, waits
// for the prompt, answers it and exits: one per recap, never a conversation carried from one turn to the next. One
// left unused is stopped after Idle. When the CLI cannot run this way, Warm runs cold, like Claude.
type Warm struct {
	Bin  string        // empty: FindClaude
	Idle time.Duration // an unused process is stopped after this; default 10m

	mu     sync.Mutex
	ready  *warmProc
	broken bool // the CLI did not answer as a waiting process: cold from now on
}

type warmProc struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	out   *bufio.Reader
	timer *time.Timer
}

// streamFlags make claude read one user message as JSON on stdin and write its result as JSON lines.
var streamFlags = []string{"--input-format", "stream-json", "--output-format", "stream-json", "--verbose"}

func (w *Warm) bin() string {
	if w.Bin != "" {
		return w.Bin
	}
	return FindClaude()
}

// Prewarm starts a process for the next recap, unless one is waiting (whose idle time starts over).
func (w *Warm) Prewarm() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.broken {
		return
	}
	if w.ready != nil {
		w.ready.timer.Reset(w.idle())
		return
	}
	bin := w.bin()
	if bin == "" {
		return
	}
	args := append(append([]string{"-p", "--model", "haiku"}, streamFlags...), leanFlags...)
	cmd := exec.Command(bin, args...)
	if h, err := os.UserHomeDir(); err == nil {
		cmd.Dir = h
	}
	cmd.Env = cleanEnv()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	p := &warmProc{cmd: cmd, stdin: stdin, out: bufio.NewReaderSize(stdout, 64<<10)}
	p.timer = time.AfterFunc(w.idle(), func() {
		w.mu.Lock()
		if w.ready == p {
			w.ready = nil
		}
		w.mu.Unlock()
		p.stop()
	})
	w.ready = p
}

func (w *Warm) idle() time.Duration {
	if w.Idle > 0 {
		return w.Idle
	}
	return 10 * time.Minute
}

func (p *warmProc) stop() {
	p.timer.Stop()
	if p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
	go p.cmd.Wait()
}

var errNoResult = errors.New("claude gave no result")

// Run answers prompt on the waiting process (and starts the next one), or cold when none is waiting.
func (w *Warm) Run(ctx context.Context, prompt string) (string, error) {
	w.mu.Lock()
	p := w.ready
	w.ready = nil
	w.mu.Unlock()
	if p == nil {
		w.Prewarm() // for the turn after this one
		return Claude{Bin: w.Bin}.Run(ctx, prompt)
	}
	p.timer.Stop()
	out, err := p.ask(ctx, prompt)
	if err != nil && ctx.Err() == nil {
		w.mu.Lock()
		w.broken = true
		w.mu.Unlock()
		return Claude{Bin: w.Bin}.Run(ctx, prompt)
	}
	w.Prewarm()
	return out, err
}

func (p *warmProc) ask(ctx context.Context, prompt string) (string, error) {
	type result struct {
		text string
		err  error
	}
	done := make(chan result, 1)
	go func() {
		msg, _ := json.Marshal(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": prompt}})
		if _, err := p.stdin.Write(append(msg, '\n')); err != nil {
			done <- result{err: err}
			return
		}
		p.stdin.Close()
		for {
			line, err := p.out.ReadBytes('\n')
			var m struct {
				Type    string `json:"type"`
				IsError bool   `json:"is_error"`
				Result  string `json:"result"`
			}
			if json.Unmarshal(line, &m) == nil && m.Type == "result" {
				if m.IsError {
					done <- result{err: errNoResult}
				} else {
					done <- result{text: m.Result}
				}
				return
			}
			if err != nil {
				done <- result{err: errNoResult}
				return
			}
		}
	}()
	select {
	case r := <-done:
		go p.cmd.Wait()
		return r.text, r.err
	case <-ctx.Done():
		p.stop()
		return "", ctx.Err()
	}
}
