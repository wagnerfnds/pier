package boxcmd

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"

	"pier/pierd/internal/box"
	"pier/pierd/internal/statefile"
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
	case "import":
		return dbImport(ctx, c, fs, args, out)
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

// dbImport makes this box's own snapshot of a project's database, here in
// the command, as the box's user: it takes hours for a big one, and pierd
// reads the new current snapshot from the disk.
func dbImport(ctx context.Context, c *box.Client, fs *flag.FlagSet, args []string, out io.Writer) error {
	usage := "db import LOC --server HOST[:PORT] --user U --password-file F (--databases A,B|--all-databases) --sanitize FILE.sql [--check FILE.sql]… [--users FILE.sql] [--clear-tables A,B] [--keep-queues] [--real-data] [--no-rebuild] [--memory 4G] [--keep 2]"
	server := fs.String("server", "", "")
	dbUser := fs.String("user", "", "")
	passwordFile := fs.String("password-file", "", "")
	databases := fs.String("databases", "", "")
	all := fs.Bool("all-databases", false, "")
	sslMode := fs.String("ssl-mode", "", "")
	var sanitize, checks repeated
	fs.Var(&sanitize, "sanitize", "")
	fs.Var(&checks, "check", "")
	usersSQL := fs.String("users", "", "")
	clear := fs.String("clear-tables", "", "")
	keepQueues := fs.Bool("keep-queues", false, "")
	realData := fs.Bool("real-data", false, "")
	noRebuild := fs.Bool("no-rebuild", false, "")
	memory := fs.String("memory", "", "")
	keep := fs.Int("keep", 2, "")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return usageErr(usage)
	}
	v, err := c.Base(ctx, pos[0])
	if err != nil {
		return err
	}
	password := ""
	if *passwordFile != "" {
		raw, err := os.ReadFile(*passwordFile)
		if err != nil {
			return err
		}
		password = strings.TrimRight(string(raw), "\r\n")
	}
	home, err := statefile.Home()
	if err != nil {
		return err
	}
	o := box.ImportOptions{
		Server: *server, User: *dbUser, Password: password, SSLMode: *sslMode, AllDatabases: *all,
		Sanitize: sanitize, Checks: checks, RealData: *realData, UsersSQL: *usersSQL, KeepQueues: *keepQueues, NoRebuild: *noRebuild,
		Memory: *memory, Dest: filepath.Join(box.DefaultDBRoot(), "base", v.Key), Progress: out, EnvFiles: map[string][]byte{},
		// Where the worktrees' servers' sockets go too, which the AppArmor
		// lines allow.
		RunDir: filepath.Join(os.TempDir(), "pier-"+strconv.Itoa(os.Getuid()), "db", "import"),
	}
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		o.RunDir = filepath.Join(dir, "pier", "db", "import")
	}
	if *databases != "" {
		o.Databases = strings.Split(*databases, ",")
	}
	if *clear != "" {
		o.ClearTables = strings.Split(*clear, ",")
	}
	// The app's users and databases come from the base's own .env files: the
	// box's, else the team's copy.
	for _, dir := range []string{filepath.Join(home, "box", "base", v.Key, "team", "files"), filepath.Join(home, "box", "base", v.Key, "files")} {
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if n := e.Name(); n == ".env" || strings.HasPrefix(n, ".env.") {
				if data, err := os.ReadFile(filepath.Join(dir, n)); err == nil {
					o.EnvFiles[n] = data
				}
			}
		}
	}
	// A write to a terminal that is gone fails instead of killing the
	// import before it deletes its raw data.
	signal.Ignore(syscall.SIGPIPE)
	m, err := box.ImportSnapshot(ctx, o)
	if err != nil {
		return err
	}
	for _, id := range box.PruneSnapshots(o.Dest, *keep) {
		fmt.Fprintln(out, "removed the older snapshot "+id)
	}
	fmt.Fprintf(out, "%s's new worktrees copy snapshot %s; existing ones keep theirs until pierd db reset\n", pos[0], m.ID)
	return nil
}

// repeated is a flag given more than once.
type repeated []string

func (r *repeated) String() string     { return strings.Join(*r, ",") }
func (r *repeated) Set(v string) error { *r = append(*r, v); return nil }
