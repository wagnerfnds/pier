// Package boxcmd implements the commands that act on this box's locations,
// worktrees, sessions and events: `pierd location add`, `pierd sessions`, and
// so on. They talk to the running pierd over its local socket.
package boxcmd

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/events"
)

// usageColumn is where descriptions start in Usage; a command line too long
// to fit puts its description on the next line, at the same column.
const usageColumn = 50

// usageSections lists the box commands. A description may run to several
// lines.
var usageSections = []struct {
	title string
	lines [][2]string
}{
	{"Locations and worktrees", [][2]string{
		{"pierd locations [--json]", "List locations and their worktrees"},
		{"pierd location add NAME PATH", "Register a repo or directory"},
		{"pierd location rm NAME", "Forget a location (files are untouched)"},
		{"pierd location config NAME [--json] [--set FILE] [--trust HASH|--untrust]", "The repo's, the box's and the effective config; --set\nreplaces the box's own with a JSON file; --trust runs the repo's"},
		{"pierd services [--json]", "Which worktree each running server belongs to"},
		{"pierd service list|start|stop|restart LOC/WORKTREE [SERVICE]", "A worktree's services from its config"},
		{"pierd worktree new LOC/NAME [--branch B] [--base REF]", "Create a git worktree and run its setup"},
		{"pierd worktree rm LOC/NAME [--force]", "Remove a worktree"},
	}},
	{"Agent sessions", [][2]string{
		{"pierd sessions [--json]", "List sessions"},
		{"pierd task new LOC/NAME [--agent ID] [--prompt TEXT] [--title T] [--branch B] [--base REF] [-- COMMAND...]", "A worktree with an agent (or COMMAND) running in it"},
		{"pierd session new LOC[/WORKTREE] [--name N] [--agent ID [--prompt TEXT]] [--title T] [-- COMMAND...]", "Start an agent or COMMAND (default: a shell) there"},
		{"pierd session rename NAME [TITLE]", "Name a session's work (no TITLE clears it)"},
		{"pierd session screen NAME [--history N]", "Print what the session shows"},
		{"pierd session send NAME TEXT [--when now|idle] [--force] [--idem KEY] [--no-enter] [--wait [--timeout 30m]]", "Type a prompt into a session (or hold it until the agent\nis idle), and wait for its turn"},
		{"pierd session wait NAME [--for finished,waiting] [--timeout 30m]", "Wait for its agent's current turn to end"},
		{"pierd session turns NAME [--limit 10] [--json]", "List a session's turns"},
		{"pierd session kill NAME", "Stop a session"},
		{"pierd exec LOC[/WORKTREE] [--timeout 10m] -- COMMAND...", "Run a command there and print its output"},
	}},
	{"Box", [][2]string{
		{"pierd stats [--json]", "Memory, disk, load, and agents running or waiting"},
		{"pierd info", "The box's name, OS, build, tools and agent presets, as JSON"},
		{"pierd emit TYPE [key=value...] [--origin TOOL]", "Announce an event, e.g. agent.finished"},
		{"pierd events [--json]", "Stream the box's events"},
	}},
}

// Usage lists the box commands.
func Usage() string {
	indent := strings.Repeat(" ", usageColumn)
	var s strings.Builder
	for i, sec := range usageSections {
		if i > 0 {
			s.WriteString("\n")
		}
		s.WriteString(sec.title + "\n")
		for _, l := range sec.lines {
			use := "  " + l[0]
			desc := strings.ReplaceAll(l[1], "\n", "\n"+indent)
			if len(use) > usageColumn-2 {
				s.WriteString(use + "\n" + indent + desc + "\n")
			} else {
				s.WriteString(use + strings.Repeat(" ", usageColumn-len(use)) + desc + "\n")
			}
		}
	}
	return s.String()
}

// Commands names every command this package handles and how many words it
// takes before its first argument.
var Commands = map[string]int{
	"locations": 1, "location": 2, "worktree": 2, "services": 1, "service": 2,
	"sessions": 1, "session": 2, "task": 2, "exec": 1,
	"info": 1, "stats": 1, "emit": 1, "events": 1,
}

// Run executes args, which start with the command words, against c.
func Run(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("missing command")
	}
	words := Commands[args[0]]
	if words == 0 || len(args) < words {
		return fmt.Errorf("unknown command %q", strings.Join(args, " "))
	}
	cmd := strings.Join(args[:words], " ")
	rest := args[words:]
	switch cmd {
	case "locations":
		return locations(ctx, c, rest, out)
	case "location add":
		fs, asJSON := flags(rest)
		pos, err := parse(fs, rest)
		if err != nil || len(pos) != 2 {
			return usageErr("location add NAME PATH")
		}
		loc, err := c.AddLocation(ctx, pos[0], pos[1])
		if err != nil {
			return err
		}
		return show(out, *asJSON, loc, func() {
			kind := "directory"
			if loc.Repo {
				kind = fmt.Sprintf("git repository, %d worktree(s)", len(loc.Worktrees))
			}
			fmt.Fprintf(out, "Added location %s → %s (%s)\n", loc.Name, loc.Path, kind)
		})
	case "location config":
		return locationConfig(ctx, c, rest, out)
	case "service list", "service start", "service stop", "service restart", "service log":
		return service(ctx, c, strings.TrimPrefix(cmd, "service "), rest, out)
	case "services":
		fs, asJSON := flags(rest)
		parse(fs, rest)
		all, err := c.Services(ctx)
		if err != nil {
			return err
		}
		return show(out, *asJSON, all, func() {
			if len(all) == 0 {
				fmt.Fprintln(out, "No servers are running in any location.")
				return
			}
			w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "LOCATION\tWORKTREE\tPORT\tPROCESS")
			for _, s := range all {
				fmt.Fprintf(w, "%s\t%s\t%d\t%s\n", s.Location, s.Worktree, s.Port, s.Process)
			}
			w.Flush()
		})
	case "info":
		fs, _ := flags(rest)
		parse(fs, rest)
		i, err := c.Info(ctx)
		if err != nil {
			return err
		}
		return show(out, true, i, func() {})
	case "stats":
		fs, asJSON := flags(rest)
		parse(fs, rest)
		st, err := c.Stats(ctx)
		if err != nil {
			return err
		}
		return show(out, *asJSON, st, func() {
			fmt.Fprintf(out, "%s  %d CPUs  load %v\n", st.Hostname, st.CPUs, st.Load)
			fmt.Fprintf(out, "memory  %s of %s\n", gib(st.Memory.Used), gib(st.Memory.Total))
			for _, d := range st.Disks {
				fmt.Fprintf(out, "disk %s  %s of %s\n", d.Mount, gib(d.Used), gib(d.Total))
			}
			waiting := 0
			for _, a := range st.Agents {
				if a.State == "waiting" {
					waiting++
				}
			}
			fmt.Fprintf(out, "agents  %d running, %d waiting for you\n", len(st.Agents), waiting)
		})
	case "location rm":
		if len(rest) != 1 {
			return usageErr("location rm NAME")
		}
		if err := c.RemoveLocation(ctx, rest[0]); err != nil {
			return err
		}
		fmt.Fprintf(out, "Removed location %s; its files are untouched.\n", rest[0])
		return nil
	case "worktree new":
		return worktreeNew(ctx, c, rest, out)
	case "worktree rm":
		fs, _ := flags(rest)
		force := fs.Bool("force", false, "remove even with uncommitted changes")
		pos, err := parse(fs, rest)
		if err != nil || len(pos) != 1 {
			return usageErr("worktree rm LOC/NAME [--force]")
		}
		loc, name, ok := strings.Cut(pos[0], "/")
		if !ok {
			return usageErr("worktree rm LOC/NAME [--force]")
		}
		archive, err := c.RemoveWorktree(ctx, loc, name, box.RemoveOptions{Force: *force})
		if err != nil {
			return err
		}
		if archive != "" {
			fmt.Fprintf(out, "Archiving %s/%s: running %s, then removing it if that succeeds. Watch with the events command.\n", loc, name, archive)
			return nil
		}
		fmt.Fprintf(out, "Removed worktree %s/%s\n", loc, name)
		return nil
	case "sessions":
		return sessions(ctx, c, rest, out)
	case "session new":
		return sessionNew(ctx, c, rest, out)
	case "task new":
		return taskNew(ctx, c, rest, out)
	case "session send":
		fs, asJSON := flags(rest)
		noEnter := fs.Bool("no-enter", false, "type the text without pressing Enter")
		wait := fs.Bool("wait", false, "then wait for the turn it starts to end (finished or waiting)")
		timeout := fs.Duration("timeout", 30*time.Minute, "with --wait, give up after this long")
		when := fs.String("when", "now", "now, or idle: hold it on the box until the agent is idle")
		force := fs.Bool("force", false, "type even into an agent that is waiting for someone")
		idem := fs.String("idem", "", "a key that makes a retried send return the turn it already made")
		pos, err := parse(fs, rest)
		if err != nil || len(pos) != 2 {
			return usageErr("session send NAME TEXT [--when now|idle] [--force] [--idem KEY] [--no-enter] [--wait [--timeout 30m]]")
		}
		enter := !*noEnter
		res, err := c.Send(ctx, pos[0], box.SendRequest{Text: pos[1], Enter: &enter, When: *when, Force: *force, IdemKey: *idem})
		if err != nil {
			return err
		}
		if !*wait {
			return show(out, *asJSON, res, func() {
				switch {
				case res.Queued:
					fmt.Fprintf(out, "Held for %s until its agent is idle (turn %s)\n", pos[0], res.Turn)
				case res.Turn != "":
					fmt.Fprintf(out, "Sent to %s (turn %s)\n", pos[0], res.Turn)
				default:
					fmt.Fprintf(out, "Sent to %s\n", pos[0])
				}
			})
		}
		w, err := waitSent(ctx, c, pos[0], res, []string{"finished", "waiting"}, *timeout)
		if err != nil {
			return err
		}
		return show(out, *asJSON, w, func() { printWait(out, w, *timeout) })
	case "session wait":
		fs, asJSON := flags(rest)
		states := fs.String("for", "finished,waiting", "states that end the wait")
		timeout := fs.Duration("timeout", 30*time.Minute, "give up after this long")
		pos, err := parse(fs, rest)
		if err != nil || len(pos) != 1 {
			return usageErr("session wait NAME [--for finished,waiting] [--timeout 30m]")
		}
		// The agent's state now counts: waiting for an agent that is
		// already idle returns at once. To wait for the turn a prompt
		// starts, use session send --wait or --turn.
		res, err := waitFor(ctx, c, pos[0], strings.Split(*states, ","), time.Time{}, *timeout)
		if err != nil {
			return err
		}
		return show(out, *asJSON, res, func() {
			if res.TimedOut {
				fmt.Fprintf(out, "Still %s after %v\n", res.State, *timeout)
				return
			}
			fmt.Fprintln(out, res.State)
		})
	case "session turns":
		fs, asJSON := flags(rest)
		limit := fs.Int("limit", 10, "how many of the latest turns")
		pos, err := parse(fs, rest)
		if err != nil || len(pos) != 1 {
			return usageErr("session turns NAME [--limit 10] [--json]")
		}
		turns, err := c.Turns(ctx, pos[0], *limit)
		if err != nil {
			return err
		}
		return show(out, *asJSON, turns, func() {
			if len(turns) == 0 {
				fmt.Fprintln(out, "No turns yet.")
				return
			}
			w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "TURN\tSTATE\tFROM\tSTARTED\tTOOK\tWAITED")
			for _, t := range turns {
				started, took := "-", "-"
				if !t.Started.IsZero() {
					started = t.Started.Local().Format("15:04:05")
					if !t.Ended.IsZero() {
						took = t.Ended.Sub(t.Started).Round(time.Second).String()
					}
				}
				waited := "-"
				if len(t.Waits) > 0 {
					waited = fmt.Sprintf("%d×", len(t.Waits))
				}
				fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", t.ID, t.State, t.Origin, started, took, waited)
			}
			w.Flush()
		})
	case "exec":
		return execCmd(ctx, c, rest, out)
	case "session screen":
		fs, _ := flags(rest)
		history := fs.Int("history", 0, "earlier lines to include")
		pos, err := parse(fs, rest)
		if err != nil || len(pos) != 1 {
			return usageErr("session screen NAME [--history N]")
		}
		text, err := c.Screen(ctx, pos[0], *history)
		if err != nil {
			return err
		}
		fmt.Fprint(out, text)
		return nil
	case "session rename":
		fs, asJSON := flags(rest)
		pos, err := parse(fs, rest)
		if err != nil || len(pos) < 1 || len(pos) > 2 {
			return usageErr("session rename NAME [TITLE]")
		}
		title := ""
		if len(pos) == 2 {
			title = pos[1]
		}
		sess, err := c.RenameSession(ctx, pos[0], title)
		if err != nil {
			return err
		}
		return show(out, *asJSON, sess, func() {
			if sess.Title == "" {
				fmt.Fprintf(out, "Cleared the title of %s\n", sess.Name)
			} else {
				fmt.Fprintf(out, "Renamed %s to %q\n", sess.Name, sess.Title)
			}
		})
	case "session kill":
		if len(rest) != 1 {
			return usageErr("session kill NAME")
		}
		if err := c.KillSession(ctx, rest[0]); err != nil {
			return err
		}
		fmt.Fprintf(out, "Stopped session %s\n", rest[0])
		return nil
	case "emit":
		return emit(ctx, c, rest, out)
	case "events":
		fs, asJSON := flags(rest)
		parse(fs, rest)
		enc := json.NewEncoder(out)
		return c.Events(ctx, func(e events.Event) {
			if *asJSON {
				enc.Encode(e)
				return
			}
			fmt.Fprintln(out, Describe(e))
		})
	}
	return fmt.Errorf("unknown command %q", cmd)
}

// Describe renders an event as one human-readable line.
func Describe(e events.Event) string {
	line := e.Time.Local().Format("15:04:05") + "  " + e.Type
	if e.Box != "" {
		line += "  " + e.Box
	}
	for _, k := range []string{"location", "name", "path", "port", "url", "command", "variable", "ref"} {
		if v, ok := e.Data[k]; ok && fmt.Sprint(v) != "" {
			line += fmt.Sprintf("  %s=%v", k, v)
		}
	}
	if e.Origin != "" && e.Origin != box.DefaultOrigin {
		line += "  via " + e.Origin
	}
	if e.Error != "" {
		line += "  (" + e.Error + ")"
	}
	return line
}

func flags(args []string) (*flag.FlagSet, *bool) {
	fs := flag.NewFlagSet("", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs, fs.Bool("json", false, "print JSON")
}

func usageErr(s string) error { return errors.New("usage: " + s) }

// parse accepts flags before, between, and after positional arguments, so
// the box reference can come first as in "worktree new devl/shop/x --base main".
func parse(fs *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		rest := fs.Args()
		if len(rest) == 0 {
			return positional, nil
		}
		positional = append(positional, rest[0])
		args = rest[1:]
	}
}

func show(out io.Writer, asJSON bool, v any, human func()) error {
	if asJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}
	human()
	return nil
}

func locations(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	parse(fs, args)
	all, err := c.Locations(ctx)
	if err != nil {
		return err
	}
	return show(out, *asJSON, all, func() {
		if len(all) == 0 {
			fmt.Fprintln(out, "No locations. Add one with: location add NAME PATH")
			return
		}
		for _, l := range all {
			fmt.Fprintf(out, "%s  %s\n", l.Name, l.Path)
			for _, w := range l.Worktrees {
				if w.Main {
					continue
				}
				branch := w.Branch
				if branch == "" {
					branch = "detached " + w.Head
				}
				fmt.Fprintf(out, "  %s/%s  %s  (%s)\n", l.Name, w.Name, w.Path, branch)
			}
		}
	})
}

func worktreeNew(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	var req box.WorktreeRequest
	fs.StringVar(&req.Branch, "branch", "", "branch to create (default: the worktree name)")
	fs.StringVar(&req.Base, "base", "", "ref to branch from")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return usageErr("worktree new LOC/NAME [--branch B] [--base REF]")
	}
	loc, name, ok := strings.Cut(pos[0], "/")
	if !ok || name == "" {
		return usageErr("worktree new LOC/NAME")
	}
	req.Name = name
	wt, err := c.AddWorktree(ctx, loc, req)
	if err != nil {
		return err
	}
	return show(out, *asJSON, wt, func() {
		fmt.Fprintf(out, "Created %s/%s at %s on %s\n", loc, wt.Name, wt.Path, wt.Branch)
	})
}

func sessions(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	parse(fs, args)
	all, err := c.Sessions(ctx)
	if err != nil {
		return err
	}
	return show(out, *asJSON, all, func() {
		if len(all) == 0 {
			fmt.Fprintln(out, "No sessions. Start one with: session new LOC[/WORKTREE] -- COMMAND")
			return
		}
		w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tTITLE\tLOCATION\tCOMMAND\tSTATE\tSTARTED")
		for _, s := range all {
			state := "running"
			if s.Exited {
				state = "exited"
			} else if s.AgentState != "" {
				state = s.Agent + " " + s.AgentState
			}
			if s.Attached > 0 {
				state += ", attached"
			}
			cmd := s.Command
			if cmd == "" {
				cmd = "(shell)"
			}
			title := s.Title
			if title == "" {
				title = "-"
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", s.Name, title, s.Location, cmd, state, s.Created.Local().Format("Jan 2 15:04"))
		}
		w.Flush()
	})
}

func sessionNew(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	var command []string
	for i, a := range args {
		if a == "--" {
			command = args[i+1:]
			args = args[:i]
			break
		}
	}
	fs, asJSON := flags(args)
	var req box.SessionRequest
	fs.StringVar(&req.Name, "name", "", "session name (default: location, command, and a suffix)")
	fs.StringVar(&req.Agent, "agent", "", "start this agent (see: agents) instead of a command")
	fs.StringVar(&req.Prompt, "prompt", "", "the agent's first prompt")
	fs.StringVar(&req.Title, "title", "", "name the work (default: the prompt's first line)")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return usageErr("session new LOC[/WORKTREE] [--name N] [--agent ID [--prompt TEXT]] [--title T] [--open split|tab] [-- COMMAND...]")
	}
	req.Location, req.Command = pos[0], commandLine(command)
	sess, err := c.StartSession(ctx, req)
	if err != nil {
		return err
	}
	return show(out, *asJSON, sess, func() {
		fmt.Fprintf(out, "Started session %s in %s\n", sess.Name, sess.Dir)
	})
}

// commandLine turns the words after -- back into one shell command. A
// single word is taken as a command line already, so `-- "a && b"` works;
// several are quoted one by one, so `-- claude "fix it, don't stop"` gives
// claude one argument, apostrophe and all.
func commandLine(words []string) string {
	if len(words) == 1 {
		return words[0]
	}
	quoted := make([]string, len(words))
	for i, w := range words {
		quoted[i] = shellWord(w)
	}
	return strings.Join(quoted, " ")
}

func shellWord(w string) string {
	if w != "" && strings.Trim(w, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@%+,") == "" {
		return w
	}
	return "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
}

// waitSent waits for the turn a send started, from the box's own time of
// the send (never this machine's clock, which may differ).
func waitSent(ctx context.Context, c *box.Client, session string, res box.SendResult, states []string, timeout time.Duration) (box.WaitResult, error) {
	after := res.At
	if after.IsZero() {
		after = time.Now()
	}
	return waitFor(ctx, c, session, states, after, timeout)
}

func printWait(out io.Writer, w box.WaitResult, timeout time.Duration) {
	if w.TimedOut {
		fmt.Fprintf(out, "Still %s after %v\n", w.State, timeout)
		return
	}
	fmt.Fprintln(out, w.State)
}

// waitFor waits in steps of at most five minutes, each one long request.
func waitFor(ctx context.Context, c *box.Client, session string, states []string, after time.Time, timeout time.Duration) (box.WaitResult, error) {
	deadline := time.Now().Add(timeout)
	for {
		step := min(time.Until(deadline), 5*time.Minute)
		res, err := c.Wait(ctx, session, states, after, max(step, time.Second))
		if err != nil || !res.TimedOut || time.Now().After(deadline) {
			return res, err
		}
	}
}

func execCmd(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	var command []string
	for i, a := range args {
		if a == "--" {
			command, args = args[i+1:], args[:i]
			break
		}
	}
	fs, asJSON := flags(args)
	timeout := fs.String("timeout", "10m", "stop the command after this long")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 || len(command) == 0 {
		return usageErr("exec LOC[/WORKTREE] [--timeout 10m] -- COMMAND...")
	}
	res, err := c.Exec(ctx, box.ExecRequest{Location: pos[0], Command: commandLine(command), Timeout: *timeout})
	if err != nil {
		return err
	}
	if *asJSON {
		return show(out, true, res, nil)
	}
	fmt.Fprint(out, res.Output)
	if res.ExitCode != 0 {
		return fmt.Errorf("exited with %d", res.ExitCode)
	}
	return nil
}

func taskNew(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	var req box.TaskRequest
	for i, a := range args {
		if a == "--" {
			req.Command = commandLine(args[i+1:])
			args = args[:i]
			break
		}
	}
	fs, asJSON := flags(args)
	fs.StringVar(&req.Agent, "agent", "", "agent to start (see: agents)")
	fs.StringVar(&req.Prompt, "prompt", "", "the agent's first prompt")
	fs.StringVar(&req.Open, "open", "", "ask the app to show it: split or tab")
	fs.StringVar(&req.Branch, "branch", "", "branch to create (default: the worktree name)")
	fs.StringVar(&req.Base, "base", "", "ref to branch from")
	fs.StringVar(&req.Title, "title", "", "name the work (default: the prompt's first line)")
	pos, err := parse(fs, args)
	usage := "task new LOC/NAME [--agent ID] [--prompt TEXT] [--title T] [--branch B] [--base REF] [-- COMMAND...]"
	if err != nil || len(pos) != 1 {
		return usageErr(usage)
	}
	loc, name, ok := strings.Cut(pos[0], "/")
	if !ok || name == "" {
		return usageErr(usage)
	}
	req.Location, req.Name = loc, name
	task, err := c.AddTask(ctx, req)
	if err != nil {
		return err
	}
	return show(out, *asJSON, task, func() {
		fmt.Fprintf(out, "Created %s/%s at %s on %s\n", loc, task.Worktree.Name, task.Worktree.Path, task.Worktree.Branch)
		fmt.Fprintf(out, "Started session %s\n", task.Session.Name)
	})
}

func emit(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	fs := flag.NewFlagSet("", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	origin := fs.String("origin", "", "tool the event comes from")
	positional, err := parse(fs, args)
	if err != nil || len(positional) == 0 {
		return usageErr("emit TYPE [key=value...] [--origin TOOL]")
	}
	data := map[string]any{}
	for _, kv := range positional[1:] {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			return fmt.Errorf("expected key=value, got %q", kv)
		}
		data[k] = v
	}
	if *origin != "" {
		c.Origin = *origin
	}
	if err := c.Emit(ctx, positional[0], data); err != nil {
		return err
	}
	fmt.Fprintf(out, "Emitted %s at %s\n", positional[0], time.Now().Format("15:04:05"))
	return nil
}

func gib(b uint64) string { return fmt.Sprintf("%.1f GiB", float64(b)/(1<<30)) }
