package boxcmd

import (
	"context"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"pier/pierd/internal/box"
)

// `pierd base`: what every new worktree of a project gets that git does not
// bring (base.go in the box package).

func baseCmd(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	switch action {
	case "status":
		usage := "base status LOC [--json]"
		pos, err := parse(fs, args)
		if err != nil || len(pos) != 1 {
			return usageErr(usage)
		}
		v, err := c.Base(ctx, pos[0])
		if err != nil {
			return err
		}
		return show(out, *asJSON, v, func() { printBase(out, v) })
	case "add":
		usage := "base add LOC PATH... [--from WORKTREE]"
		from := fs.String("from", "", "the worktree to take the files from (default: the main checkout)")
		pos, err := parse(fs, args)
		if err != nil || len(pos) < 2 {
			return usageErr(usage)
		}
		var v box.BaseView
		for _, p := range pos[1:] {
			if v, err = c.AddBaseFile(ctx, pos[0], p, *from); err != nil {
				return fmt.Errorf("%s: %w", p, err)
			}
		}
		return show(out, *asJSON, v, func() { printBase(out, v) })
	case "rm":
		usage := "base rm LOC PATH..."
		pos, err := parse(fs, args)
		if err != nil || len(pos) < 2 {
			return usageErr(usage)
		}
		var v box.BaseView
		for _, p := range pos[1:] {
			if v, err = c.RemoveBaseFile(ctx, pos[0], p); err != nil {
				return fmt.Errorf("%s: %w", p, err)
			}
		}
		return show(out, *asJSON, v, func() { printBase(out, v) })
	case "carry":
		usage := "base carry LOC [PATH...|--clear]"
		clear := fs.Bool("clear", false, "carry nothing")
		pos, err := parse(fs, args)
		if err != nil || len(pos) < 1 {
			return usageErr(usage)
		}
		if len(pos) == 1 && !*clear {
			v, err := c.Base(ctx, pos[0])
			if err != nil {
				return err
			}
			return show(out, *asJSON, v.Carry, func() { printCarry(out, v) })
		}
		v, err := c.SetBaseCarry(ctx, pos[0], pos[1:])
		if err != nil {
			return err
		}
		return show(out, *asJSON, v, func() { printCarry(out, v) })
	case "apply":
		usage := "base apply LOC [WORKTREE...]"
		pos, err := parse(fs, args)
		if err != nil || len(pos) < 1 {
			return usageErr(usage)
		}
		res, err := c.ApplyBase(ctx, pos[0], pos[1:])
		if err != nil {
			return err
		}
		return show(out, *asJSON, res, func() {
			tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
			for _, a := range res {
				for _, r := range a.Results {
					fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", a.Worktree, r.Path, r.Action, resultNote(r))
				}
			}
			tw.Flush()
		})
	}
	return fmt.Errorf("unknown command base %s", action)
}

func resultNote(r box.BaseResult) string {
	note := r.Reason
	if len(r.Keys) > 0 {
		note = strings.TrimSpace(note + " (" + strings.Join(r.Keys, ", ") + ")")
	}
	return note
}

func printBase(out io.Writer, v box.BaseView) {
	fmt.Fprintf(out, "base %s\n", v.Key)
	if v.Team != nil {
		at := "not yet copied"
		if v.Team.Published != nil {
			at = "published " + v.Team.Published.Local().Format("2006-01-02 15:04")
		}
		fmt.Fprintf(out, "team: %s (%s)\n", v.Team.Dir, at)
		if v.Team.Error != "" {
			fmt.Fprintf(out, "  %s\n", v.Team.Error)
		}
	}
	tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(out, "files:")
	if len(v.Files) == 0 {
		fmt.Fprintln(tw, "  (none)")
	}
	for _, f := range v.Files {
		desc := fmt.Sprintf("%d bytes", f.Size)
		if f.Kind == "env" {
			desc = fmt.Sprintf("%d keys", len(f.Keys))
		}
		fmt.Fprintf(tw, "  %s\t%s\t%s\n", f.Path, f.From, desc)
	}
	tw.Flush()
	printCarry(out, v)
	if v.Recipe != nil {
		fmt.Fprintf(out, "recipe (%s):\n", v.Recipe.From)
		for _, l := range strings.Split(v.Recipe.Setup, "\n") {
			fmt.Fprintf(out, "  %s\n", l)
		}
		if len(v.Recipe.Services) > 0 {
			fmt.Fprintf(out, "  then: %s\n", strings.Join(v.Recipe.Services, ", "))
		}
	}
	for _, w := range v.Warnings {
		fmt.Fprintf(out, "warning: %s\n", w)
	}
}

func printCarry(out io.Writer, v box.BaseView) {
	fmt.Fprintln(out, "carried from the main checkout:")
	tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	if len(v.Carry) == 0 {
		fmt.Fprintln(tw, "  (none)")
	}
	for _, c := range v.Carry {
		where := "in the main checkout"
		if !c.InMain {
			where = "not in the main checkout yet"
		}
		fmt.Fprintf(tw, "  %s\t%s\t%s\n", c.Path, c.From, where)
	}
	tw.Flush()
	if v.Copy == "reflink" && len(v.Carry) > 0 {
		fmt.Fprintln(out, "  (copies share the main checkout's blocks on this disk)")
	}
}
