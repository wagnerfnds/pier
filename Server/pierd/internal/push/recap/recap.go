// Package recap writes the one-sentence summary of a finished turn that the alert body and the Live Activity show
// ("Adicionei mul() em calc.py; os testes passam."), by running a small model on the box: `claude -p --model haiku`,
// the subscription already there (pierd runs as the same user as the agents). It runs once per turn
// (cached by session + state_since) with a deadline; on any failure the caller keeps the reply excerpt it had.
package recap

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// MaxLen is the recap's length limit in runes.
const MaxLen = 120

// Runner runs the model with a prompt on stdin and returns what it printed (an interface so tests never call claude).
type Runner interface {
	Run(ctx context.Context, prompt string) (string, error)
}

// Short says the reply already fits a notification (one line, at most MaxLen runes): it is shown as it is. A
// summary of "Pronto, ok." only says less, in more words, seconds later.
func Short(reply string) bool {
	r := strings.TrimSpace(reply)
	return !strings.Contains(r, "\n") && len([]rune(r)) <= MaxLen
}

// Prompt is what the model is asked, with the agent's last reply (capped) at the end.
func Prompt(reply string) string {
	r := []rune(strings.TrimSpace(reply))
	if len(r) > 6000 {
		r = append(r[:3000:3000], append([]rune("\n…\n"), r[len(r)-3000:]...)...)
	}
	return `You summarise what a coding agent just reported at the end of its turn, for a phone notification.
Write ONE short sentence of at most 90 characters (one idea; drop details) saying what was done or what the agent needs.
Write it in the language the report is written in (an English report gets an English sentence, a Portuguese report a Portuguese one), whatever other instructions say about language.
Plain text only: no quotes, no Markdown, no emoji, no preamble like "Summary:". Answer with the sentence and nothing else.

The agent's report:
` + string(r)
}

// Clean turns the model's answer into the recap: the first non-empty line, markup and wrapping quotes removed, clipped
// to MaxLen. "" when nothing usable came back.
func Clean(out string) string {
	line := ""
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			line = l
			break
		}
	}
	for _, m := range []string{"**", "__", "`"} {
		line = strings.ReplaceAll(line, m, "")
	}
	for _, p := range []string{"Summary:", "Resumo:", "Recap:"} {
		if strings.HasPrefix(line, p) {
			line = strings.TrimSpace(line[len(p):])
		}
	}
	line = strings.Trim(line, `"'“”‘’«» `)
	line = strings.Join(strings.Fields(line), " ")
	if line == "" || isRefusal(line) {
		return ""
	}
	r := []rune(line)
	if len(r) > MaxLen {
		return string(r[:MaxLen-1]) + "…"
	}
	return line
}

// isRefusal spots CLI errors printed instead of an answer (not logged in, rate limited, ...).
func isRefusal(s string) bool {
	l := strings.ToLower(s)
	if strings.HasPrefix(l, "error") || strings.HasPrefix(l, "api error") {
		return true
	}
	for _, p := range []string{"invalid api key", "please run /login", "not logged in", "usage limit reached", "credit balance is too low"} {
		if strings.Contains(l, p) {
			return true
		}
	}
	return false
}

// Recapper runs the model once per turn and remembers the answer (or the failure, so a broken CLI is not retried
// for every alert of the same turn).
type Recapper struct {
	Run     Runner
	Timeout time.Duration // default 20s

	mu    sync.Mutex
	cache map[string]entry
}

type entry struct {
	text string
	at   time.Time
}

// New returns a Recapper over r with the default timeout.
func New(r Runner) *Recapper { return &Recapper{Run: r, Timeout: 20 * time.Second} }

// Recap is the recap for the turn of session that ended at since, or "" when it cannot be had in time.
func (c *Recapper) Recap(ctx context.Context, session string, since time.Time, reply string) string {
	if c == nil || c.Run == nil || strings.TrimSpace(reply) == "" || Short(reply) {
		return ""
	}
	key := session + "|" + since.UTC().Format(time.RFC3339Nano)
	c.mu.Lock()
	if c.cache == nil {
		c.cache = map[string]entry{}
	}
	if e, ok := c.cache[key]; ok {
		c.mu.Unlock()
		return e.text
	}
	c.mu.Unlock()

	timeout := c.Timeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	rctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	out, err := c.Run.Run(rctx, Prompt(reply))
	text := ""
	if err == nil {
		text = Clean(out)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	for k, e := range c.cache { // a turn is recapped once, and only while it is fresh: keep the map small
		if now.Sub(e.at) > time.Hour {
			delete(c.cache, k)
		}
	}
	c.cache[key] = entry{text: text, at: now}
	return text
}

// ErrNoCLI is returned when no claude binary is found.
var ErrNoCLI = errors.New("claude CLI not found")

// Claude runs `claude -p --model haiku` with the prompt on stdin, from the home directory (not a worktree: no project
// CLAUDE.md, nothing for pierd to attribute to a session), without the PIER_* variables of the service and
// with its hooks silenced.
type Claude struct {
	Bin string // empty: looked up like the app's AIDraft does (PATH, ~/.local/bin/claude, ...)
}

// FindClaude is the claude binary: $PATH first (a systemd user unit has a short one), then the usual install places.
func FindClaude() string {
	if p, err := exec.LookPath("claude"); err == nil {
		return p
	}
	h, _ := os.UserHomeDir()
	for _, c := range []string{
		filepath.Join(h, ".local/bin/claude"), filepath.Join(h, ".claude/local/claude"), "/usr/local/bin/claude",
		"/opt/homebrew/bin/claude", filepath.Join(h, ".npm-global/bin/claude"),
	} {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return c
		}
	}
	return ""
}

// leanFlags strip what a one-sentence answer never uses (tools, MCP servers, skills, a saved session): measured on a
// box, the median run went from 2.59s to 2.42s with the same sentences. A CLI too old to know them gets a plain run.
var leanFlags = []string{"--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands", "--tools", ""}

func (c Claude) Run(ctx context.Context, prompt string) (string, error) {
	bin := c.Bin
	if bin == "" {
		bin = FindClaude()
	}
	if bin == "" {
		return "", ErrNoCLI
	}
	out, err := c.run(ctx, bin, append([]string{"-p", "--model", "haiku"}, leanFlags...), prompt)
	if err != nil && ctx.Err() == nil {
		out, err = c.run(ctx, bin, []string{"-p", "--model", "haiku"}, prompt)
	}
	return out, err
}

// cleanEnv is the service's environment without its PIER_* variables, and with the run's hooks silenced:
// they are not a session's (integrations.QuietEnv).
func cleanEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "PIER_") {
			env = append(env, kv)
		}
	}
	return append(env, "PIER_HOOKS_QUIET=1")
}

func (c Claude) run(ctx context.Context, bin string, args []string, prompt string) (string, error) {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stdin = strings.NewReader(prompt)
	if h, err := os.UserHomeDir(); err == nil {
		cmd.Dir = h
	}
	cmd.Env = cleanEnv()
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return out.String(), nil
}
