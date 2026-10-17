package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"

	"pier/pierd/internal/agentpath"
	"pier/pierd/internal/installer"
)

// toolsCmd handles `pierd tools` (where Claude Code, Codex and the GitHub CLI are) and `pierd tools install
// [claude] [codex] [gh] [--force]` (the missing ones, or the named ones, into ~/.local/bin; internal/installer).
func toolsCmd(args []string) error {
	if len(args) == 0 || args[0] == "status" {
		return printTools(os.Stdout)
	}
	if args[0] != "install" {
		return errors.New("usage: pierd tools [install [claude] [codex] [gh] [--force]]")
	}
	fs := flag.NewFlagSet("tools install", flag.ContinueOnError)
	force := fs.Bool("force", false, "install again where it is already found (an update)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	ids := fs.Args()
	for _, id := range ids {
		if _, ok := installer.Lookup(id); !ok {
			return fmt.Errorf("pierd does not install %q; it installs claude, codex and gh", id)
		}
	}
	if len(ids) == 0 {
		ids = allTools()
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if failed := installTools(ctx, ids, *force, os.Stdout); failed > 0 {
		return fmt.Errorf("%d of them not installed", failed)
	}
	return nil
}

func allTools() []string {
	var ids []string
	for _, t := range installer.Tools {
		ids = append(ids, t.ID)
	}
	return ids
}

// skipTools says whether setup leaves the tools alone: --no-tools, or PIERD_NO_TOOLS=1 (which the install script
// passes on to setup).
func skipTools(flagged bool) bool {
	switch strings.ToLower(os.Getenv("PIERD_NO_TOOLS")) {
	case "1", "true", "yes":
		return true
	}
	return flagged
}

// installTools installs the tools named by ids that this user's shell does not find (all of them with force), saying
// how each went on out, and returns how many failed. Then it looks for the agents again, so what runs next in this
// process (setup's hooks) sees the new ones.
func installTools(ctx context.Context, ids []string, force bool, out io.Writer) (failed int) {
	finder := agentpath.Default()
	in := &installer.Installer{Out: &lineIndent{w: out, prefix: "    "}}
	for _, id := range ids {
		t, _ := installer.Lookup(id)
		if f, ok := finder.Find(t.Command); ok && !force {
			fmt.Fprintf(out, "%s: already here (%s)\n", t.Name, f.Path)
			continue
		}
		fmt.Fprintf(out, "%s: installing into %s…\n", t.Name, in.BinDir())
		p, err := in.Install(ctx, id)
		if err != nil {
			fmt.Fprintf(out, "%s: not installed: %v\n", t.Name, err)
			fmt.Fprintf(out, "    Try again later with: pierd tools install %s\n", id)
			failed++
			continue
		}
		fmt.Fprintf(out, "%s: installed (%s)\n", t.Name, p)
	}
	finder.Refresh(ctx)
	return failed
}

// printTools says where each tool is, and how to install the missing ones.
func printTools(out io.Writer) error {
	finder := agentpath.Default()
	finder.Refresh(context.Background())
	w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	for _, t := range installer.Tools {
		if f, ok := finder.Find(t.Command); ok {
			fmt.Fprintf(w, "%s\t%s\t%s\n", t.Name, f.Path, f.Version)
		} else {
			fmt.Fprintf(w, "%s\tnot installed\tpierd tools install %s\n", t.Name, t.ID)
		}
	}
	return w.Flush()
}

// lineIndent writes what an installer prints with prefix at the start of each line, however its writes are cut.
type lineIndent struct {
	w      io.Writer
	prefix string
	mid    bool // the last write did not end a line
}

func (l *lineIndent) Write(p []byte) (int, error) {
	// Byte by byte: a write may end inside a character, and only '\n' matters here.
	b := make([]byte, 0, len(p)+len(l.prefix))
	for _, c := range p {
		if !l.mid {
			b = append(b, l.prefix...)
			l.mid = true
		}
		b = append(b, c)
		if c == '\n' {
			l.mid = false
		}
	}
	if _, err := l.w.Write(b); err != nil {
		return 0, err
	}
	return len(p), nil
}
