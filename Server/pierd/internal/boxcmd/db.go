package boxcmd

import (
	"context"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"pier/pierd/internal/box"
)

// `pierd db`: a worktree's own database and Redis servers (database.go in
// the box package).

// options is a repeatable NAME=VALUE flag.
type options map[string]string

func (o options) String() string { return fmt.Sprint(map[string]string(o)) }
func (o options) Set(v string) error {
	k, val, ok := strings.Cut(v, "=")
	if !ok || k == "" {
		return fmt.Errorf("%q is not NAME=VALUE", v)
	}
	o[k] = val
	return nil
}

func dbCmd(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	switch action {
	case "status", "reset", "drop":
		usage := "db " + action + " [LOC/WORKTREE]"
		pos, err := parse(fs, args)
		if err != nil {
			return usageErr(usage)
		}
		loc, wt, err := worktreeRef(pos, usage)
		if err != nil {
			return err
		}
		switch action {
		case "reset":
			st, err := c.ResetWorktreeDB(ctx, loc, wt)
			if err != nil {
				return err
			}
			return show(out, *asJSON, st, func() {
				fmt.Fprintf(out, "%s/%s: its database starts over from the project's snapshot; follow it with pierd prepare wait\n", loc, wt)
			})
		case "drop":
			v, err := c.DropWorktreeDB(ctx, loc, wt)
			if err != nil {
				return err
			}
			return show(out, *asJSON, v, func() { fmt.Fprintf(out, "%s/%s has no servers of its own now\n", loc, wt) })
		}
		v, err := c.WorktreeDB(ctx, loc, wt)
		if err != nil {
			return err
		}
		return show(out, *asJSON, v, func() {
			if len(v.Servers) == 0 {
				fmt.Fprintln(out, "no servers of its own")
				return
			}
			tw := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
			for _, s := range v.Servers {
				from := ""
				if s.Snapshot != "" {
					from = "copy of " + s.Snapshot + " (" + s.Layer + ")"
				}
				fmt.Fprintf(tw, "%s\t%s\t127.0.0.1:%d\t%s\t%s\n", s.Engine, s.State, s.Port, s.Version, from)
				if s.Error != "" {
					fmt.Fprintf(tw, "\t%s\n", s.Error)
				}
			}
			tw.Flush()
		})
	case "enable":
		usage := "db enable LOC [--redis] [--option NAME=VALUE]... [--allow-copy]"
		redis := fs.Bool("redis", false, "an empty Redis of its own too")
		allowCopy := fs.Bool("allow-copy", false, "copy the snapshot whole where the disk cannot share blocks")
		opts := options{}
		fs.Var(opts, "option", "a MySQL server option the project needs")
		pos, err := parse(fs, args)
		if err != nil || len(pos) != 1 {
			return usageErr(usage)
		}
		db := &box.BaseDB{Engine: "mysql", AllowCopy: *allowCopy}
		if len(opts) > 0 {
			db.Options = opts
		}
		v, err := c.SetBaseServers(ctx, pos[0], db, *redis)
		if err != nil {
			return err
		}
		return show(out, *asJSON, v, func() { printServers(out, v) })
	case "disable":
		usage := "db disable LOC"
		pos, err := parse(fs, args)
		if err != nil || len(pos) != 1 {
			return usageErr(usage)
		}
		v, err := c.SetBaseServers(ctx, pos[0], nil, false)
		if err != nil {
			return err
		}
		return show(out, *asJSON, v, func() { printServers(out, v) })
	case "apparmor":
		fmt.Fprint(out, box.AppArmorRule())
		return nil
	}
	return fmt.Errorf("unknown command db %s", action)
}

func printServers(out io.Writer, v box.BaseView) {
	if v.DB == nil || v.DB.Engine == "" && !v.DB.Redis {
		fmt.Fprintln(out, "new worktrees get no servers of their own")
		return
	}
	what := []string{}
	if v.DB.Engine != "" {
		what = append(what, v.DB.Engine)
	}
	if v.DB.Redis {
		what = append(what, "redis")
	}
	fmt.Fprintf(out, "new worktrees get their own %s\n", strings.Join(what, " and "))
	if s := v.DB.Snapshot; s != nil {
		fmt.Fprintf(out, "snapshot: %s (%s, MySQL %s, %s)\n", s.ID, s.Layer, s.Version, s.Created.Local().Format("2006-01-02 15:04"))
	}
	for _, p := range v.DB.Problems {
		fmt.Fprintf(out, "problem: %s\n", p)
	}
}
