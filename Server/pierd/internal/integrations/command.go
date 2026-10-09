package integrations

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"pier/pierd/internal/events"
)

// Usage documents the commands this package handles, for pierd help.
const Usage = `Agent hooks
  pierd integrations [status]
                         Which agent CLIs have pierd's hooks
  pierd integrations install claude|codex|all
                         Install pierd's hooks for an agent CLI
  pierd hook TOOL EVENT [PAYLOAD]
                         What those hooks run: turns a tool's hook into a
                         pierd event (agent.finished, agent.waiting)
`

// Emit publishes an event on this box's pierd.
type Emit func(events.Event) error

// Hook handles `hook TOOL EVENT [PAYLOAD]`. It never fails the calling tool:
// problems are reported on stderr.
func Hook(args []string, stdin *os.File, stdout, stderr io.Writer, emit Emit) {
	if len(args) < 2 {
		fmt.Fprintln(stderr, "usage: hook TOOL EVENT [PAYLOAD]")
		return
	}
	tool, event := args[0], args[1]
	// pierd's own one-shot model runs (recaps, titles, next steps) are not
	// agents anyone follows: their hooks would land on the session that
	// shares their folder.
	if os.Getenv(QuietEnv) == "1" {
		return
	}
	var payload []byte
	if len(args) >= 3 {
		payload = []byte(args[2])
	} else if info, err := stdin.Stat(); err == nil && info.Mode()&os.ModeCharDevice == 0 {
		// Read stdin only when something is piped in: a terminal would block.
		payload, _ = io.ReadAll(io.LimitReader(stdin, 1<<20))
	}
	e, ok := Translate(tool, event, payload)
	if !ok {
		return
	}
	// The session the agent runs in, so the box knows which of the agents
	// in a worktree this is.
	if name := hookSession(); name != "" {
		e.Data["session"] = name
	}
	// Stamped now: a hook spooled while pierd is down keeps its time.
	e.Time = time.Now().UTC()
	if err := emit(e); err != nil {
		fmt.Fprintf(stderr, "pierd hook: %v\n", err)
	}
}

var validSession = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$`)

// SessionEnv names the variable pierd sets in every session it starts.
const SessionEnv = "PIER_SESSION"

// QuietEnv, set to 1, silences the hooks of an agent run: pierd sets it for
// its own `claude -p` runs, and the app's do too.
const QuietEnv = "PIER_HOOKS_QUIET"

// hookSession is the pierd session this hook runs in: $PIER_SESSION, or, for a session started without them, the tmux
// session when the pane is on pierd's own tmux server.
func hookSession() string {
	if s := os.Getenv(SessionEnv); validSession.MatchString(s) {
		return s
	}
	tmux, pane := os.Getenv("TMUX"), os.Getenv("TMUX_PANE")
	sock, _, _ := strings.Cut(tmux, ",")
	if sock == "" || pane == "" || filepath.Base(sock) != TmuxSocket() {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "tmux", "-S", sock, "display-message", "-p", "-t", pane, "#S").Output()
	if s := strings.TrimSpace(string(out)); err == nil && validSession.MatchString(s) {
		return s
	}
	return ""
}

// TmuxSocket is the name of pierd's tmux server (tmux -L): "pier", or
// $PIER_TMUX_SOCKET, which lets a second pierd on one box (a test) use
// another.
func TmuxSocket() string {
	if s := os.Getenv("PIER_TMUX_SOCKET"); validSession.MatchString(s) {
		return s
	}
	return "pier"
}
