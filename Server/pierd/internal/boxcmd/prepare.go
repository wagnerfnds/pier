package boxcmd

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"pier/pierd/internal/box"
)

// Commands for a worktree's preparation and its preview, which agents run
// from inside the worktree: there LOC/WORKTREE may be left out, and is the
// session's own ($PIER_LOCATION, $PIER_WORKTREE_NAME).

// stdin is where `location config --merge -` reads; tests replace it.
var stdin io.Reader = os.Stdin

// waitPoll is how often `prepare wait` reads the preparation again.
var waitPoll = 2 * time.Second

// worktreeRef is LOC/WORKTREE from pos, or the session's own worktree.
func worktreeRef(pos []string, usage string) (loc, wt string, err error) {
	switch len(pos) {
	case 0:
		loc, wt = os.Getenv("PIER_LOCATION"), os.Getenv("PIER_WORKTREE_NAME")
		if loc == "" || wt == "" {
			return "", "", fmt.Errorf("say which worktree (LOC/WORKTREE): this shell is in none\nusage: %s", usage)
		}
		return loc, wt, nil
	case 1:
		loc, wt, ok := strings.Cut(pos[0], "/")
		if !ok || loc == "" || wt == "" {
			return "", "", usageErr(usage)
		}
		return loc, wt, nil
	}
	return "", "", usageErr(usage)
}

func previewCmd(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	switch action {
	case "get":
		usage := "preview get [LOC/WORKTREE] [--json]"
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		p, err := c.Preview(ctx, loc, wt)
		if err != nil {
			return err
		}
		return show(out, *asJSON, p, func() { printPreview(out, loc, wt, p) })
	case "set":
		usage := "preview set [LOC/WORKTREE] [--port N] [--path /login] [--url URL] [--user U --password P] [--login-note T] [--note T] [--clear]"
		port := fs.Int("port", 0, "the port the page answers on ($PIER_PORT)")
		path := fs.String("path", "", "the page to open first, such as /login")
		link := fs.String("url", "", "the page's own address, when it is not the box's port")
		userName := fs.String("user", "", "a test login's user (the app's demo user, never a real account)")
		password := fs.String("password", "", "the test login's password")
		loginNote := fs.String("login-note", "", "a note on the test login")
		note := fs.String("note", "", "a note for the person")
		clear := fs.Bool("clear", false, "forget the preview (and its public link)")
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		// What is not given stays as it was.
		given := map[string]bool{}
		fs.Visit(func(f *flag.Flag) { given[f.Name] = true })
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		var p box.Preview
		if !*clear {
			if p, err = c.Preview(ctx, loc, wt); err != nil {
				return err
			}
			p.Share, p.Updated = nil, nil
			set := func(name string, dst *string, v string) {
				if given[name] {
					*dst = v
				}
			}
			if given["port"] {
				p.Port = *port
			}
			set("path", &p.Path, *path)
			set("url", &p.URL, *link)
			set("note", &p.Note, *note)
			if given["user"] || given["password"] || given["login-note"] {
				l := box.PreviewLogin{}
				if p.Login != nil {
					l = *p.Login
				}
				set("user", &l.User, *userName)
				set("password", &l.Password, *password)
				set("login-note", &l.Note, *loginNote)
				p.Login = &l
				if l.User == "" && l.Password == "" {
					p.Login = nil
				}
			}
		}
		saved, err := c.SetPreview(ctx, loc, wt, p)
		if err != nil {
			return err
		}
		return show(out, *asJSON, saved, func() {
			if *clear {
				fmt.Fprintf(out, "Forgot the preview of %s/%s.\n", loc, wt)
				return
			}
			printPreview(out, loc, wt, saved)
		})
	}
	return usageErr("preview get|set [LOC/WORKTREE] …")
}

func printPreview(out io.Writer, loc, wt string, p box.Preview) {
	if p.Port == 0 && p.Path == "" && p.URL == "" && p.Login == nil && p.Note == "" {
		fmt.Fprintf(out, "%s/%s has no preview yet; record one with: preview set %s/%s --port $PIER_PORT\n", loc, wt, loc, wt)
		return
	}
	fmt.Fprintf(out, "Preview of %s/%s\n", loc, wt)
	if p.Port > 0 {
		fmt.Fprintf(out, "  port      %d\n", p.Port)
	}
	if p.Path != "" {
		fmt.Fprintf(out, "  path      %s\n", p.Path)
	}
	if p.URL != "" {
		fmt.Fprintf(out, "  url       %s\n", p.URL)
	}
	if l := p.Login; l != nil {
		fmt.Fprintf(out, "  login     %s / %s\n", l.User, l.Password)
		if l.Note != "" {
			fmt.Fprintf(out, "            %s\n", l.Note)
		}
	}
	if p.Note != "" {
		fmt.Fprintf(out, "  note      %s\n", p.Note)
	}
	if s := p.Share; s != nil {
		fmt.Fprintf(out, "  public    %s (until %s)\n", s.URL, s.Expires.Local().Format("Jan 2 15:04"))
	}
}

func prepareCmd(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	switch action {
	case "status":
		usage := "prepare status [LOC/WORKTREE] [--json]"
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		st, err := c.PrepareStatus(ctx, loc, wt)
		if err != nil {
			return err
		}
		return show(out, *asJSON, st, func() { printPrepare(out, st) })
	case "wait":
		usage := "prepare wait [LOC/WORKTREE] [--timeout 30m] [--json]"
		timeout := fs.Duration("timeout", 30*time.Minute, "give up after this long")
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		if ownPreparation(loc, wt) {
			fmt.Fprintln(out, "You are this worktree's preparation (PIER_SETUP): there is nothing to wait for.")
			return nil
		}
		st, err := waitPrepared(ctx, c, loc, wt, *timeout)
		if err != nil {
			return err
		}
		if err := show(out, *asJSON, st, func() { printPrepare(out, st) }); err != nil {
			return err
		}
		if st.State == "failed" {
			return errors.New("its preparation failed")
		}
		return nil
	case "start":
		usage := "prepare start [LOC/WORKTREE] [--with agent|script] [--json]"
		with := fs.String("with", "", "agent or script (default: the project's)")
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		if ownPreparation(loc, wt) {
			return errors.New("you are this worktree's preparation (PIER_SETUP): another one would replace you")
		}
		st, err := c.Prepare(ctx, loc, wt, *with)
		if err != nil {
			return err
		}
		return show(out, *asJSON, st, func() {
			how := "its setup script"
			if st.Kind == "agent" {
				how = "a setup agent (session " + st.Session + ")"
			}
			fmt.Fprintf(out, "Preparing %s/%s with %s. Follow it with: prepare wait %s/%s\n", loc, wt, how, loc, wt)
		})
	case "done":
		usage := "prepare done [LOC/WORKTREE] [--failed REASON]"
		failed := fs.String("failed", "", "it could not be prepared: what is missing and why")
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		st, err := c.PrepareDone(ctx, loc, wt, strings.TrimSpace(*failed))
		if err != nil {
			return err
		}
		return show(out, *asJSON, st, func() { printPrepare(out, st) })
	}
	return usageErr("prepare status|wait|start|done [LOC/WORKTREE] …")
}

// ownPreparation says this shell is loc/wt's setup agent (pierd marks its
// session with PIER_SETUP=1): its preparation is the one running.
func ownPreparation(loc, wt string) bool {
	return os.Getenv("PIER_SETUP") == "1" && os.Getenv("PIER_LOCATION") == loc && os.Getenv("PIER_WORKTREE_NAME") == wt
}

// waitPrepared reads a worktree's preparation until it is no longer
// running, or timeout passes.
func waitPrepared(ctx context.Context, c *box.Client, loc, wt string, timeout time.Duration) (box.PrepareStatus, error) {
	deadline := time.Now().Add(timeout)
	for {
		st, err := c.PrepareStatus(ctx, loc, wt)
		if err != nil || st.State != "running" {
			return st, err
		}
		if time.Now().After(deadline) {
			return st, fmt.Errorf("%s/%s is still being prepared after %v", loc, wt, timeout)
		}
		select {
		case <-ctx.Done():
			return st, ctx.Err()
		case <-time.After(waitPoll):
		}
	}
}

func printPrepare(out io.Writer, st box.PrepareStatus) {
	switch st.State {
	case "ready":
		fmt.Fprintln(out, "ready")
	case "failed":
		fmt.Fprintf(out, "failed: %s\n", st.Error)
	case "running":
		line := "running"
		if st.Kind == "agent" {
			line += ": a setup agent prepares it (session " + st.Session + ")"
			if st.Waiting {
				line += ", and waits for someone"
			}
		} else if st.Setup != "" {
			line += ": " + st.Setup
		}
		fmt.Fprintln(out, line)
	case "skipped":
		fmt.Fprintln(out, "skipped: it was made with only the code, nothing was prepared")
	default:
		fmt.Fprintln(out, "unknown: nothing was recorded about its preparation")
	}
}

// readMerge reads the config a --merge names: a JSON file, or stdin ("-").
func readMerge(name string) (box.RepoConfig, error) {
	var data []byte
	var err error
	if name == "-" {
		data, err = io.ReadAll(io.LimitReader(stdin, 1<<20))
	} else {
		data, err = os.ReadFile(name)
	}
	if err != nil {
		return box.RepoConfig{}, err
	}
	var c box.RepoConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return box.RepoConfig{}, fmt.Errorf("%s: %w", name, err)
	}
	return c, nil
}
