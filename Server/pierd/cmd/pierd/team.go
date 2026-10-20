package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"pier/pierd/internal/box"
)

// `pierd team`, run by root on a machine where several people each run their
// own pierd: the team's folder and its group, the AppArmor lines the box's
// MySQL server needs for the worktrees' databases, and each project's base
// in the team's folder (box/teamadmin.go), which every member's pierd lays
// under their own.

const teamUsage = `usage:
  pierd team init [--dir /srv/pier/team] [--group pier] [--user pier] [--members USER,USER] [--dry-run]
  pierd team status
  pierd team base OWNER/REPO files [ls]
  pierd team base OWNER/REPO files add PATH --from FILE
  pierd team base OWNER/REPO files rm PATH
  pierd team base OWNER/REPO config [show]
  pierd team base OWNER/REPO config set|merge FILE|-
  pierd team base OWNER/REPO config from-user USER LOCATION
  pierd team base OWNER/REPO db enable [--redis] [--option NAME=VALUE]... [--allow-copy]
  pierd team base OWNER/REPO db disable
  pierd team base OWNER/REPO db import --server HOST[:PORT] --user USER --password-file FILE
        (--databases A,B | --all-databases) --sanitize FILE.sql [--sanitize …] [--check FILE.sql]…
        [--users FILE.sql] [--clear-tables A,B] [--keep-queues] [--ssl-mode MODE] [--memory 8G]
        [--real-data] [--no-rebuild] [--keep 2]
  pierd team base OWNER/REPO db ls|prune [--keep 2]|rm ID`

// teamRun runs a system command for team init; tests replace it.
var teamRun = func(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// teamExists says a group or user is in the system's database.
var teamExists = func(db, name string) bool { return exec.Command("getent", db, name).Run() == nil }

var teamIsRoot = func() bool { return os.Geteuid() == 0 }

func teamCmd(args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New(teamUsage)
	}
	switch args[0] {
	case "init":
		return teamInit(args[1:], out)
	case "status":
		return teamStatus(out)
	case "base":
		if len(args) < 3 {
			return errors.New(teamUsage)
		}
		if !teamIsRoot() {
			return errors.New("pierd team runs as root: the team's folder is root's to change")
		}
		return teamBase(args[1], args[2], args[3:], out)
	}
	return errors.New(teamUsage)
}

// teamDirName is what a team's folder may be called: it goes into AppArmor's
// rules as it is.
var teamDirName = regexp.MustCompile(`^(/[A-Za-z0-9._-]+)+$`)

func teamInit(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("team init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dir := fs.String("dir", box.DefaultTeamDir, "the team's folder")
	group := fs.String("group", "pier", "the team's group: its members read the team's folder")
	name := fs.String("user", "pier", "the team's system user: it owns the team's folder and runs the imports' servers")
	members := fs.String("members", "", "the people's users to put in the group")
	dry := fs.Bool("dry-run", false, "say what it would do")
	if err := fs.Parse(args); err != nil || fs.NArg() > 0 {
		return errors.New(teamUsage)
	}
	*dir = filepath.Clean(*dir)
	if !teamDirName.MatchString(*dir) || filepath.Dir(*dir) == *dir {
		return fmt.Errorf("--dir %q: the team's folder is an absolute path of letters, digits, '.', '_' and '-'", *dir)
	}
	if !*dry && !teamIsRoot() {
		return errors.New("pierd team init runs as root (or with --dry-run)")
	}
	// A folder that is there already is the team's (made by an earlier
	// init) or empty: init never takes over /srv, /home or a folder with
	// someone's files.
	if entries, err := os.ReadDir(*dir); err == nil && len(entries) > 0 {
		if info, err := os.Stat(filepath.Join(*dir, "projects")); err != nil || !info.IsDir() {
			return fmt.Errorf("%s has files in it and is not a team's folder: name a new or empty one with --dir", *dir)
		}
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	step := func(what string, do func() error) error {
		fmt.Fprintln(out, "- "+what)
		if *dry {
			return nil
		}
		return do()
	}
	if !teamExists("group", *group) {
		if err := step("make the group "+*group, func() error { return teamRun("groupadd", "--system", *group) }); err != nil {
			return err
		}
	}
	if !teamExists("passwd", *name) {
		if err := step("make the system user "+*name, func() error {
			return teamRun("useradd", "--system", "--gid", *group, "--home-dir", *dir, "--no-create-home", "--shell", "/usr/sbin/nologin", *name)
		}); err != nil {
			return err
		}
	}
	// The folders above it are made if missing (0755) and otherwise left as
	// they are: what they hold is not the team's.
	if err := step(fmt.Sprintf("folder %s (%s, group %s, read by the group only)", *dir, *name, *group), func() error {
		uid, gid, err := teamLookup(*name, *group)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(*dir), 0o755); err != nil {
			return err
		}
		for _, d := range []string{*dir, filepath.Join(*dir, "projects")} {
			if err := os.Mkdir(d, 0o750); err != nil && !errors.Is(err, os.ErrExist) {
				return err
			}
			if err := teamChown(d, uid, gid); err != nil {
				return err
			}
			if err := os.Chmod(d, 0o750|os.ModeSetgid); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return err
	}
	settings := teamSettingsFile()
	if err := step("write "+settings, func() error {
		data, _ := json.MarshalIndent(box.TeamSettings{Dir: *dir, Group: *group, User: *name}, "", "  ")
		return writeReadable(settings, append(data, '\n'))
	}); err != nil {
		return err
	}
	if _, err := os.Stat(teamAppArmorProfile); err == nil {
		have, _ := os.ReadFile(teamAppArmorLocal)
		want := box.AppArmorRuleFor(*dir)
		if !strings.Contains(string(have), want) {
			if err := step("allow the box's MySQL server the worktrees' databases in "+teamAppArmorLocal+" (AppArmor), and reload its profile", func() error {
				if err := writeReadable(teamAppArmorLocal, withAppArmorRule(have, want)); err != nil {
					return err
				}
				return teamRun("apparmor_parser", "-r", teamAppArmorProfile)
			}); err != nil {
				return err
			}
		}
	}
	for _, m := range strings.Split(*members, ",") {
		if m = strings.TrimSpace(m); m == "" {
			continue
		}
		if err := step("put "+m+" in "+*group, func() error { return teamRun("usermod", "-aG", *group, m) }); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "\nEvery member of %s, and every member's agents, can read what the team publishes: its .env, its keys, its database snapshots. Publish development keys, and data with personal data taken out.\n", *group)
	return nil
}

// The MySQL server's AppArmor profile and its local additions; tests
// replace them.
var (
	teamAppArmorProfile = "/etc/apparmor.d/usr.sbin.mysqld"
	teamAppArmorLocal   = "/etc/apparmor.d/local/usr.sbin.mysqld"
)

// withAppArmorRule is a local profile with pierd's lines as rule says,
// replacing those an earlier init wrote (another team folder).
func withAppArmorRule(have []byte, rule string) []byte {
	var kept []string
	lines := strings.Split(strings.TrimRight(string(have), "\n"), "\n")
	for i := 0; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == box.AppArmorMarker {
			for i+1 < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i+1]), "owner ") {
				i++
			}
			continue
		}
		if lines[i] != "" || len(kept) > 0 {
			kept = append(kept, lines[i])
		}
	}
	out := strings.Join(kept, "\n")
	if out != "" {
		out += "\n"
	}
	return []byte(out + rule)
}

// writeReadable writes a file everyone may read, whole: a temporary file
// renamed over it, so a member's pierd never reads half of it.
func writeReadable(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// teamLookup, teamChown and teamSettingsFile are the system's, which tests
// replace.
var (
	teamLookup       = lookupOwner
	teamChown        = os.Chown
	teamSettingsFile = box.TeamSettingsPath
)

func lookupOwner(name, group string) (uid, gid int, err error) {
	u, err := user.Lookup(name)
	if err != nil {
		return 0, 0, err
	}
	g, err := user.LookupGroup(group)
	if err != nil {
		return 0, 0, err
	}
	uid, _ = strconv.Atoi(u.Uid)
	gid, _ = strconv.Atoi(g.Gid)
	return uid, gid, nil
}

func teamSettings() (box.TeamSettings, error) {
	s, ok, err := box.ReadTeamSettings()
	if err != nil {
		return s, err
	}
	if !ok {
		return s, errors.New("this machine has no team yet: sudo pierd team init")
	}
	return s, nil
}

// teamOwner is the team's user and group, which own what root writes in the
// team's folder and run the imports' servers.
func teamOwner(s box.TeamSettings) (box.TeamOwner, error) {
	if !teamIsRoot() {
		return box.TeamOwner{}, nil
	}
	uid, gid, err := teamLookup(orDefault(s.User, "pier"), orDefault(s.Group, "pier"))
	if err != nil {
		return box.TeamOwner{}, fmt.Errorf("the team's user and group: %w (sudo pierd team init)", err)
	}
	if uid == 0 {
		return box.TeamOwner{}, errors.New("the team's user is root: the imports' servers would run as root, which MySQL refuses")
	}
	return box.TeamOwner{UID: uid, GID: gid}, nil
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func teamStatus(out io.Writer) error {
	s, err := teamSettings()
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "team folder %s, user %s, group %s\n", s.Dir, orDefault(s.User, "pier"), orDefault(s.Group, "pier"))
	entries, _ := os.ReadDir(filepath.Join(s.Dir, "projects"))
	if len(entries) == 0 {
		fmt.Fprintln(out, "no project bases yet: sudo pierd team base OWNER/REPO …")
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p := &box.TeamProject{Dir: filepath.Join(s.Dir, "projects", e.Name()), Key: e.Name()}
		pub := p.Published()
		fmt.Fprintf(out, "\n%s\n", e.Name())
		if !pub.At.IsZero() {
			fmt.Fprintf(out, "  published %s\n", pub.At.Local().Format("2006-01-02 15:04"))
		}
		fmt.Fprintf(out, "  files: %s\n", orDefault(strings.Join(p.FilePaths(), ", "), "none"))
		if c, err := p.Config(); err == nil && (c.Setup != "" || c.Base != nil) {
			if c.Setup != "" {
				fmt.Fprintf(out, "  recipe: %s\n", firstLine(c.Setup))
			}
			if c.Base != nil && c.Base.DB != nil {
				fmt.Fprintf(out, "  worktrees get their own %s%s\n", c.Base.DB.Engine, map[bool]string{true: " and redis", false: ""}[c.Base.Redis])
			}
		}
		gens, current := box.SnapshotGens(p.DBDir())
		for _, g := range gens {
			mark := " "
			if g.ID == current {
				mark = "*"
			}
			fmt.Fprintf(out, "  %s snapshot %s  MySQL %s  %.1f GB  %s\n", mark, g.ID, g.Version, float64(g.Bytes)/(1<<30), map[bool]string{true: "anonymized", false: "REAL DATA"}[g.Sanitized])
		}
	}
	return nil
}

func firstLine(s string) string {
	l, _, _ := strings.Cut(s, "\n")
	return l
}

func teamBase(slug, what string, args []string, out io.Writer) error {
	s, err := teamSettings()
	if err != nil {
		return err
	}
	owner, err := teamOwner(s)
	if err != nil {
		return err
	}
	p, err := box.OpenTeamProject(s.Dir, slug, owner)
	if err != nil {
		return err
	}
	switch what {
	case "files":
		return teamFiles(p, args, out)
	case "config":
		return teamConfig(p, args, out)
	case "db":
		return teamDB(p, owner, args, out)
	}
	return errors.New(teamUsage)
}

func teamFiles(p *box.TeamProject, args []string, out io.Writer) error {
	if len(args) == 0 || args[0] == "ls" {
		for _, f := range p.FilePaths() {
			fmt.Fprintln(out, f)
		}
		return nil
	}
	switch args[0] {
	case "add":
		fs := flag.NewFlagSet("files add", flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		from := fs.String("from", "", "the file to publish")
		if err := fs.Parse(reorder(args[1:])); err != nil || fs.NArg() != 1 || *from == "" {
			return errors.New(teamUsage)
		}
		data, err := os.ReadFile(*from)
		if err != nil {
			return err
		}
		if err := p.AddFile(fs.Arg(0), data); err != nil {
			return err
		}
		fmt.Fprintf(out, "published %s (%d bytes) for every member's new worktrees\n", fs.Arg(0), len(data))
		return nil
	case "rm":
		if len(args) != 2 {
			return errors.New(teamUsage)
		}
		return p.RemoveFile(args[1])
	}
	return errors.New(teamUsage)
}

// reorder puts flags before positional arguments, as flag wants them.
func reorder(args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") && a != "-" {
			flags = append(flags, a)
			if !strings.Contains(a, "=") && i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") && !boolFlag(a) {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		pos = append(pos, a)
	}
	return append(flags, pos...)
}

func boolFlag(a string) bool {
	switch strings.TrimLeft(a, "-") {
	case "redis", "allow-copy", "all-databases", "keep-queues", "real-data", "no-rebuild", "dry-run":
		return true
	}
	return false
}

func readConfigArg(arg string) (box.RepoConfig, error) {
	var data []byte
	var err error
	if arg == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(arg)
	}
	if err != nil {
		return box.RepoConfig{}, err
	}
	var c box.RepoConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("%s: %w", arg, err)
	}
	return c, nil
}

func teamConfig(p *box.TeamProject, args []string, out io.Writer) error {
	if len(args) == 0 || args[0] == "show" {
		c, err := p.Config()
		if err != nil {
			return err
		}
		data, _ := json.MarshalIndent(c, "", "  ")
		fmt.Fprintln(out, string(data))
		return nil
	}
	var c box.RepoConfig
	switch args[0] {
	case "set", "merge":
		if len(args) != 2 {
			return errors.New(teamUsage)
		}
		over, err := readConfigArg(args[1])
		if err != nil {
			return err
		}
		c = over
		if args[0] == "merge" {
			cur, err := p.Config()
			if err != nil {
				return err
			}
			c = box.MergeConfig(cur, over)
		}
	case "from-user":
		if len(args) != 3 {
			return errors.New(teamUsage)
		}
		u, err := user.Lookup(args[1])
		if err != nil {
			return err
		}
		recipe, err := box.LocalRecipe(filepath.Join(u.HomeDir, ".config", "pier", "box", "locations.json"), args[2])
		if err != nil {
			return err
		}
		cur, err := p.Config()
		if err != nil {
			return err
		}
		c = box.MergeConfig(cur, recipe)
	default:
		return errors.New(teamUsage)
	}
	if err := p.SetConfig(c); err != nil {
		return err
	}
	fmt.Fprintln(out, "published the team's config; members' pierds take it within seconds")
	return nil
}

// optionsFlag is a repeatable NAME=VALUE.
type optionsFlag map[string]string

func (o optionsFlag) String() string { return "" }
func (o optionsFlag) Set(v string) error {
	k, val, ok := strings.Cut(v, "=")
	if !ok || k == "" {
		return fmt.Errorf("%q is not NAME=VALUE", v)
	}
	o[k] = val
	return nil
}

// listFlag is a repeatable value.
type listFlag []string

func (l *listFlag) String() string     { return strings.Join(*l, ",") }
func (l *listFlag) Set(v string) error { *l = append(*l, v); return nil }

func teamDB(p *box.TeamProject, owner box.TeamOwner, args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New(teamUsage)
	}
	fs := flag.NewFlagSet("db", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	switch args[0] {
	case "enable", "disable":
		redis := fs.Bool("redis", false, "")
		allowCopy := fs.Bool("allow-copy", false, "")
		opts := optionsFlag{}
		fs.Var(opts, "option", "")
		if err := fs.Parse(args[1:]); err != nil || fs.NArg() > 0 {
			return errors.New(teamUsage)
		}
		c, err := p.Config()
		if err != nil {
			return err
		}
		if c.Base == nil {
			c.Base = &box.BaseConfig{}
		}
		c.Base.DB, c.Base.Redis = nil, false
		if args[0] == "enable" {
			c.Base.DB = &box.BaseDB{Engine: "mysql", AllowCopy: *allowCopy}
			if len(opts) > 0 {
				c.Base.DB.Options = opts
			}
			c.Base.Redis = *redis
		}
		if err := p.SetConfig(c); err != nil {
			return err
		}
		fmt.Fprintf(out, "published: new worktrees %s\n", map[bool]string{true: "get their own database", false: "get no servers of their own"}[args[0] == "enable"])
		return nil
	case "ls":
		gens, current := box.SnapshotGens(p.DBDir())
		for _, g := range gens {
			mark := " "
			if g.ID == current {
				mark = "*"
			}
			fmt.Fprintf(out, "%s %s  MySQL %s  %.1f GB  %s  %s\n", mark, g.ID, g.Version, float64(g.Bytes)/(1<<30), strings.Join(g.Databases, ","),
				map[bool]string{true: "anonymized", false: "REAL DATA"}[g.Sanitized])
		}
		return nil
	case "prune":
		keep := fs.Int("keep", 2, "")
		if err := fs.Parse(args[1:]); err != nil {
			return errors.New(teamUsage)
		}
		for _, id := range box.PruneSnapshots(p.DBDir(), *keep) {
			fmt.Fprintln(out, "removed "+id)
		}
		return nil
	case "rm":
		if len(args) != 2 || !box.ValidSnapshotID(args[1]) {
			return errors.New("name a snapshot by its id, as db ls shows it")
		}
		gen := filepath.Join(p.DBDir(), "gen", args[1])
		if _, err := os.Stat(gen); err != nil {
			return fmt.Errorf("no snapshot %s", args[1])
		}
		if _, current := box.SnapshotGens(p.DBDir()); current == args[1] {
			return errors.New("that is the current snapshot: import another first")
		}
		return os.RemoveAll(gen)
	case "import":
		return teamImport(p, owner, fs, args[1:], out)
	}
	return errors.New(teamUsage)
}

func teamImport(p *box.TeamProject, owner box.TeamOwner, fs *flag.FlagSet, args []string, out io.Writer) error {
	server := fs.String("server", "", "")
	dbUser := fs.String("user", "", "")
	passwordFile := fs.String("password-file", "", "")
	databases := fs.String("databases", "", "")
	all := fs.Bool("all-databases", false, "")
	sslMode := fs.String("ssl-mode", "", "")
	var sanitize, checks listFlag
	fs.Var(&sanitize, "sanitize", "")
	fs.Var(&checks, "check", "")
	usersSQL := fs.String("users", "", "")
	clear := fs.String("clear-tables", "", "")
	keepQueues := fs.Bool("keep-queues", false, "")
	realData := fs.Bool("real-data", false, "")
	noRebuild := fs.Bool("no-rebuild", false, "")
	memory := fs.String("memory", "", "")
	keep := fs.Int("keep", 2, "")
	if err := fs.Parse(args); err != nil || fs.NArg() > 0 {
		return errors.New(teamUsage)
	}
	password := ""
	if *passwordFile != "" {
		info, err := os.Stat(*passwordFile)
		if err != nil {
			return err
		}
		if info.Mode().Perm()&0o077 != 0 {
			fmt.Fprintf(out, "warning: %s can be read by others than its owner (chmod 600 it)\n", *passwordFile)
		}
		raw, err := os.ReadFile(*passwordFile)
		if err != nil {
			return err
		}
		password = strings.TrimRight(string(raw), "\r\n")
	}
	o := box.ImportOptions{
		Server: *server, User: *dbUser, Password: password, SSLMode: *sslMode, AllDatabases: *all,
		Sanitize: sanitize, Checks: checks, RealData: *realData, UsersSQL: *usersSQL, KeepQueues: *keepQueues,
		NoRebuild: *noRebuild, Memory: *memory, Dest: p.DBDir(), RunDir: "/run/pier-team", Shared: true, Progress: out,
		EnvFiles: map[string][]byte{},
	}
	if *databases != "" {
		o.Databases = splitList(*databases)
	}
	if *clear != "" {
		o.ClearTables = splitList(*clear)
	}
	if owner.UID != 0 {
		o.RunAs = &syscall.Credential{Uid: uint32(owner.UID), Gid: uint32(owner.GID)}
	}
	for _, f := range p.FilePaths() {
		base := filepath.Base(f)
		if base == ".env" || strings.HasPrefix(base, ".env.") {
			if data, err := p.File(f); err == nil {
				o.EnvFiles[f] = data
			}
		}
	}
	if _, ok := o.EnvFiles[".env"]; !ok {
		fmt.Fprintln(out, "warning: the team's base has no .env yet, so the snapshot gets no app user: publish it first (files add .env --from …), or give --users")
	}
	// An import stopped (Ctrl-C, the terminal gone) still deletes its raw
	// data and ends its servers on the way out; a write to a terminal that
	// is gone fails instead of killing it first.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	signal.Ignore(syscall.SIGPIPE)
	if _, err := box.ImportSnapshot(ctx, o); err != nil {
		return err
	}
	if err := p.PublishDB(); err != nil {
		return err
	}
	for _, id := range box.PruneSnapshots(p.DBDir(), *keep) {
		fmt.Fprintln(out, "removed the older snapshot "+id)
	}
	fmt.Fprintln(out, "published: members' new worktrees copy it; existing ones keep theirs until pierd db reset")
	return nil
}

func splitList(s string) []string {
	var out []string
	for _, x := range strings.Split(s, ",") {
		if x = strings.TrimSpace(x); x != "" {
			out = append(out, x)
		}
	}
	return out
}
