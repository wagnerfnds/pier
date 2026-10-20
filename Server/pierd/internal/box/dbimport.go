package box

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Making a database snapshot: a project's data imported from a MySQL server
// into a server of the import's own (A), its queues emptied, personal data
// taken out (the project's sanitize SQL) and checked (its check SQL, every
// answer 0), then rebuilt into a fresh server (B) from a dump of A, so that
// nothing taken out stays behind in B's files (free pages, undo and redo
// logs keep what an UPDATE replaced). B, shut down cleanly, is the snapshot;
// A is deleted. Root makes a team's (`pierd team base … db import`, the
// servers run as the team's user); a person a box's own (`pierd db import`).

// ImportOptions say where the data comes from and what is done to it.
type ImportOptions struct {
	// Server is the source, host[:port]; User and Password sign in to it
	// (a password goes through a 0600 defaults file, never an argument).
	Server   string
	User     string
	Password string
	SSLMode  string
	// Databases are those taken, or all of the source's but its own.
	Databases    []string
	AllDatabases bool
	// Sanitize are SQL files run on the imported data; Checks SQL files
	// whose every answer must be 0. A source of real data needs Sanitize
	// unless RealData says to keep it as it is.
	Sanitize []string
	Checks   []string
	RealData bool
	// UsersSQL is run on the snapshot after the users made from EnvFiles.
	UsersSQL string
	// ClearTables are emptied besides Laravel's queues (jobs, job_batches,
	// failed_jobs), unless KeepQueues.
	ClearTables []string
	KeepQueues  bool
	// NoRebuild keeps A as the snapshot: what an UPDATE replaced stays in
	// its files, so only for data with nothing taken out (RealData).
	NoRebuild bool
	// SchemaOnly imports the source's tables without their rows and runs
	// the sanitize SQL and the checks on them, publishing nothing: a
	// minute's test of that SQL against the source's own schema before an
	// import of hours.
	SchemaOnly bool
	// Memory is each import server's buffer pool ("8G"); "" picks one from
	// the memory the machine has free (importMemory).
	Memory string
	// Dest is the project's db folder: gen/<id>/ and current in it.
	Dest string
	// RunDir is where the import servers' sockets go (a short path), in a
	// folder of each import's own.
	RunDir string
	// EnvFiles are the base's dotenv files: the app's users and databases.
	EnvFiles map[string][]byte
	// RunAs runs the servers as that user (root makes a team's as the
	// team's user); nil runs them as the caller.
	RunAs *syscall.Credential
	// Shared makes the snapshot readable by RunAs's group (a team's).
	Shared   bool
	Progress io.Writer
}

// importTools are the MySQL programs an import runs; tests replace them.
var importTools = func() (server, client, dump string) {
	server = mysqlServer()
	client, _ = exec.LookPath("mysql")
	dump, _ = exec.LookPath("mysqldump")
	return
}

// laravelQueues are the tables an import empties: a production's jobs would
// run in every worktree, with its credentials, against its customers.
var laravelQueues = []string{"jobs", "job_batches", "failed_jobs"}

var (
	sqlIdent   = regexp.MustCompile(`^[A-Za-z0-9_$-]{1,64}$`)
	memorySize = regexp.MustCompile(`^[0-9]{1,6}[KMG]?$`)
	snapshotID = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}(-[0-9a-f]{4})?$`)
)

// ValidSnapshotID says id names a snapshot (20261020-153045-a1b2), not a
// path.
func ValidSnapshotID(id string) bool { return snapshotID.MatchString(id) }

// mysqlTools are the client programs an import runs and what they run with:
// only the import's own option file (--defaults-file) says where they
// connect, never the caller's ~/.my.cnf, ~/.mylogin.cnf or MYSQL_*
// variables, which could send a TRUNCATE to the box's own server.
type mysqlTools struct {
	client, dump string
	env          []string
}

func newMySQLTools(client, dump, build string) mysqlTools {
	env := []string{}
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "MYSQL_") {
			env = append(env, kv)
		}
	}
	// A login-path file that is not there: none is read.
	env = append(env, "MYSQL_TEST_LOGIN_FILE="+filepath.Join(build, "no-login-paths"))
	return mysqlTools{client: client, dump: dump, env: env}
}

// sql runs sql with the client and returns what it printed, rows a line
// each, no headers.
func (t mysqlTools) sql(ctx context.Context, cnf, sql string) (string, error) {
	cmd := exec.CommandContext(ctx, t.client, "--defaults-file="+cnf, "-N", "-B")
	cmd.Env = t.env
	cmd.Stdin = strings.NewReader(sql)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("%v %s", err, lastLines(errOut.String(), 6))
	}
	return out.String(), nil
}

func (t mysqlTools) file(ctx context.Context, cnf, file string) error {
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	_, err = t.sql(ctx, cnf, string(data))
	return err
}

// ImportSnapshot makes a snapshot as o says and makes it the project's
// current one. It returns its manifest. One import of a project runs at a
// time; what one cut short left (its raw data, the source's password, a
// server still serving them) goes first.
func ImportSnapshot(ctx context.Context, o ImportOptions) (snapshotManifest, error) {
	var m snapshotManifest
	if len(o.Sanitize) == 0 && !o.RealData {
		return m, errors.New("a snapshot of real data needs --sanitize (the SQL that takes personal data out), or --real-data to keep it as it is")
	}
	if o.NoRebuild && len(o.Sanitize) > 0 && !o.RealData {
		return m, errors.New("--no-rebuild keeps what --sanitize takes out in the server's files (free pages, undo and redo logs): leave it out, or add --real-data to publish the snapshot as real data")
	}
	if o.Server == "" || o.User == "" {
		return m, errors.New("say the source: --server HOST[:PORT] and --user")
	}
	if !o.AllDatabases && len(o.Databases) == 0 {
		return m, errors.New("say which databases (--databases a,b) or --all-databases")
	}
	for _, d := range append(append([]string{}, o.Databases...), o.ClearTables...) {
		if !sqlIdent.MatchString(d) {
			return m, fmt.Errorf("%q is not a database or table name", d)
		}
	}
	if o.Memory != "" && !memorySize.MatchString(o.Memory) {
		return m, fmt.Errorf("--memory %q is not a size (8G, 512M)", o.Memory)
	}
	say := func(format string, a ...any) {
		if o.Progress != nil {
			fmt.Fprintf(o.Progress, format+"\n", a...)
		}
	}
	users, err := appUsers(o.EnvFiles)
	if err != nil {
		return m, err
	}
	for name, raw := range o.EnvFiles {
		f := parseEnvFile(raw)
		if _, _, hasDB := f.get("DB_DATABASE"); hasDB {
			if _, _, hasUser := f.get("DB_USERNAME"); !hasUser {
				say("warning: %s names a database but no DB_USERNAME: Laravel then signs in as root, which a worktree's database keeps for pierd", name)
			}
		}
	}
	server, client, dump := importTools()
	if server == "" || client == "" || dump == "" {
		return m, errors.New("the import needs the box's MySQL server, client and mysqldump (sudo apt install mysql-server)")
	}
	version, err := mysqldVersion(ctx, server)
	if err != nil {
		return m, err
	}
	unlock, err := lockImport(o.Dest)
	if err != nil {
		return m, err
	}
	defer unlock()
	sweepBuilds(o.Dest, o.RunDir)
	id := newSnapshotID()
	build := filepath.Join(o.Dest, "build", id)
	run := filepath.Join(o.RunDir, id)
	for _, d := range []string{build, run} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return m, err
		}
	}
	// The servers run as RunAs: theirs to reach their sockets through, and
	// nobody else's (a server's root signs in by its socket alone).
	if o.RunAs != nil {
		for _, d := range []string{o.RunDir, filepath.Join(o.Dest, "build"), build, run} {
			os.Chown(d, int(o.RunAs.Uid), int(o.RunAs.Gid))
		}
	}
	// Whatever happens, the build goes: the raw import holds real data.
	defer os.RemoveAll(build)
	defer os.RemoveAll(run)
	tools := newMySQLTools(client, dump, build)
	src := filepath.Join(build, "source.cnf")
	host, port, _ := strings.Cut(o.Server, ":")
	if port == "" {
		port = "3306"
	}
	srcCnf := "[client]\nhost=" + cnfValue(host) + "\nport=" + cnfValue(port) + "\nuser=" + cnfValue(o.User) + "\npassword=" + cnfValue(o.Password) + "\nprotocol=TCP\n"
	if o.SSLMode != "" {
		srcCnf += "ssl-mode=" + cnfValue(o.SSLMode) + "\n"
	}
	if err := os.WriteFile(src, []byte(srcCnf), 0o600); err != nil {
		return m, err
	}
	dbs := o.Databases
	if o.AllDatabases {
		out, err := tools.sql(ctx, src, "SHOW DATABASES")
		if err != nil {
			return m, fmt.Errorf("listing the source's databases: %w", err)
		}
		dbs = nil
		for _, d := range strings.Fields(out) {
			switch d {
			case "mysql", "sys", "information_schema", "performance_schema":
			default:
				if !sqlIdent.MatchString(d) {
					return m, fmt.Errorf("the source's database %q has a name the import cannot take: name the others with --databases", d)
				}
				dbs = append(dbs, d)
			}
		}
		if len(dbs) == 0 {
			return m, errors.New("the source has no databases of its own")
		}
	}
	sort.Strings(dbs)
	grantOn := grantDatabases(dbs, o.EnvFiles)

	say("importing %s from %s into a server of the import's own…", strings.Join(dbs, ", "), o.Server)
	a, err := startImportServer(ctx, o, tools, server, version, build, run, "raw", "a")
	if err != nil {
		return m, err
	}
	defer a.stop()
	start := time.Now()
	n, err := tools.pipe(ctx, src, a.cnf, dbs, o.SchemaOnly, o.Progress)
	if err != nil {
		return m, fmt.Errorf("importing: %w", err)
	}
	if o.SchemaOnly {
		say("imported the tables of %s, without their rows", strings.Join(dbs, ", "))
	} else {
		say("imported %s in %s", gib(n), time.Since(start).Round(time.Second))
	}
	// The accounts the data's triggers run as, or every UPDATE on a table
	// with one fails.
	if err := makeDefiners(ctx, tools, a.cnf, dbs, grantOn); err != nil {
		return m, err
	}
	if !o.KeepQueues || len(o.ClearTables) > 0 {
		tables := append([]string{}, o.ClearTables...)
		if !o.KeepQueues {
			tables = append(tables, laravelQueues...)
		}
		emptied, err := clearTables(ctx, tools, a.cnf, dbs, tables)
		if err != nil {
			return m, fmt.Errorf("emptying %s: %w", strings.Join(tables, ", "), err)
		}
		if len(emptied) > 0 {
			say("emptied %s", strings.Join(emptied, ", "))
		}
	}
	for _, f := range o.Sanitize {
		say("taking personal data out: %s", filepath.Base(f))
		if err := tools.file(ctx, a.cnf, f); err != nil {
			return m, fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
	}
	checks := 0
	for _, f := range o.Checks {
		n, err := runChecks(ctx, tools, a.cnf, f)
		checks += n
		if err != nil {
			return m, fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
	}
	if checks > 0 {
		say("%d checks answered 0", checks)
	}
	if o.SchemaOnly {
		say("the sanitize SQL and the checks ran on the source's schema: nothing was published")
		return m, nil
	}
	final := a
	if !o.NoRebuild {
		say("rebuilding it from a dump, so nothing taken out stays in its files…")
		b, err := startImportServer(ctx, o, tools, server, version, build, run, "data", "b")
		if err != nil {
			return m, err
		}
		defer b.stop()
		if _, err := tools.pipe(ctx, a.cnf, b.cnf, dbs, false, nil); err != nil {
			return m, fmt.Errorf("rebuilding: %w", err)
		}
		a.stop()
		os.RemoveAll(filepath.Join(build, "raw"))
		final = b
	}
	if err := finishSnapshot(ctx, tools, final, o, users, dbs, grantOn, version); err != nil {
		return m, err
	}
	if err := final.shutdown(ctx, tools); err != nil {
		return m, err
	}
	data := final.data
	if err := cleanDatadir(data); err != nil {
		return m, err
	}
	gen := filepath.Join(o.Dest, "gen", id)
	if err := os.MkdirAll(filepath.Dir(gen), 0o755); err != nil {
		return m, err
	}
	if err := os.MkdirAll(gen, 0o700); err != nil {
		return m, err
	}
	if err := os.Rename(data, filepath.Join(gen, "data")); err != nil {
		return m, err
	}
	m = snapshotManifest{ID: id, Engine: engineMySQL, Version: version, Databases: dbs, Created: time.Now().UTC(),
		Sanitized: len(o.Sanitize) > 0 && !o.RealData && !o.NoRebuild, Checks: checks, Source: "mysqldump of " + strings.Join(dbs, ", ") + " from " + host,
		Bytes: treeBytes(filepath.Join(gen, "data"))}
	if err := saveJSON(filepath.Join(gen, "manifest.json"), m); err != nil {
		return m, err
	}
	if o.Shared && o.RunAs != nil {
		if err := shareTree(gen, int(o.RunAs.Uid), int(o.RunAs.Gid)); err != nil {
			return m, err
		}
	}
	if err := swapCurrent(o.Dest, id); err != nil {
		return m, err
	}
	say("snapshot %s: %s, MySQL %s", id, gib(m.Bytes), version)
	return m, nil
}

// newSnapshotID names a snapshot by when it was made, with a few random
// characters so two made in one second differ.
func newSnapshotID() string {
	var b [2]byte
	rand.Read(b[:])
	return time.Now().UTC().Format("20060102-150405") + "-" + hex.EncodeToString(b[:])
}

// appUsers are the users the base's env files sign the app in as, with
// their passwords. root is refused: a worktree's server keeps root for
// pierd (each start gives it a password of its own), so an app signing in
// as root could not. So is one user with two passwords.
func appUsers(files map[string][]byte) (map[string]string, error) {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	users, from := map[string]string{}, map[string]string{}
	for _, name := range names {
		f := parseEnvFile(files[name])
		u, _, ok := f.get("DB_USERNAME")
		if !ok || u == "" {
			continue
		}
		if u == "root" {
			return nil, fmt.Errorf("%s signs the app in as root (DB_USERNAME=root): a worktree's database keeps root for pierd, so give the app a user of its own (DB_USERNAME=app and a password) in the base's env files", name)
		}
		if !sqlIdent.MatchString(u) {
			return nil, fmt.Errorf("%s: DB_USERNAME %q is not a user name the import can make", name, u)
		}
		p, _, _ := f.get("DB_PASSWORD")
		if had, ok := users[u]; ok && had != p {
			return nil, fmt.Errorf("%s and %s give the user %s two passwords: one server cannot have both", from[u], name, u)
		}
		users[u], from[u] = p, name
	}
	return users, nil
}

// grantDatabases are the databases the app's users get every privilege
// on: the imported ones and those the env files name.
func grantDatabases(dbs []string, files map[string][]byte) []string {
	seen := map[string]bool{}
	var out []string
	add := func(d string) {
		if sqlIdent.MatchString(d) && !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	for _, d := range dbs {
		add(d)
	}
	for _, raw := range files {
		if d, _, ok := parseEnvFile(raw).get("DB_DATABASE"); ok {
			add(d)
		}
	}
	sort.Strings(out)
	return out
}

// grantsOn gives who every privilege on each database and on any whose name
// starts with one of theirs and "_" (the databases Laravel's parallel tests
// make): never the server's own administration (FILE, SUPER, setting its
// variables), which would let anyone who knows the password write files as
// the worktree's user, nor the mysql schema.
func grantsOn(who string, dbs []string) string {
	var b strings.Builder
	for _, d := range dbs {
		exact := strings.NewReplacer(`_`, `\_`, `%`, `\%`).Replace(d)
		fmt.Fprintf(&b, "GRANT ALL PRIVILEGES ON `%s`.* TO %s;\nGRANT ALL PRIVILEGES ON `%s\\_%%`.* TO %s;\n", exact, who, exact, who)
	}
	return b.String()
}

// sqlString is s as an SQL string literal.
func sqlString(s string) string {
	return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'"
}

// makeDefiners makes the accounts the data's triggers, views, routines and
// events name as their DEFINER, locked (nobody signs in as them) and with the
// databases' privileges: missing, every trigger fails (error 1449), the
// sanitize's UPDATEs and the app's own writes with them.
func makeDefiners(ctx context.Context, t mysqlTools, cnf string, dbs, grantOn []string) error {
	in := quoteList(dbs)
	q := "SELECT DISTINCT DEFINER FROM (" +
		"SELECT DEFINER FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA IN (" + in + ")" +
		" UNION SELECT DEFINER FROM information_schema.VIEWS WHERE TABLE_SCHEMA IN (" + in + ")" +
		" UNION SELECT DEFINER FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA IN (" + in + ")" +
		" UNION SELECT DEFINER FROM information_schema.EVENTS WHERE EVENT_SCHEMA IN (" + in + ")) d"
	out, err := t.sql(ctx, cnf, q)
	if err != nil {
		return fmt.Errorf("finding the data's definers: %w", err)
	}
	var sql strings.Builder
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		at := strings.LastIndexByte(line, '@')
		if at <= 0 || strings.HasPrefix(line, "mysql.") {
			continue
		}
		who := sqlString(line[:at]) + "@" + sqlString(line[at+1:])
		fmt.Fprintf(&sql, "CREATE USER IF NOT EXISTS %s ACCOUNT LOCK;\n", who)
		sql.WriteString(grantsOn(who, grantOn))
	}
	if sql.Len() == 0 {
		return nil
	}
	if _, err := t.sql(ctx, cnf, sql.String()); err != nil {
		return fmt.Errorf("making the data's definers: %w", err)
	}
	return nil
}

// lockImport keeps one import of a project at a time.
func lockImport(dest string) (func(), error) {
	if err := os.MkdirAll(dest, 0o750); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dest, "import.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("another import of this project is running")
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

// sweepBuilds clears what imports cut short left (killed, the machine
// rebooted): their raw data, the source's password, and a server still
// serving them. The caller holds the project's import lock.
func sweepBuilds(dest, runDir string) {
	entries, _ := os.ReadDir(filepath.Join(dest, "build"))
	for _, e := range entries {
		dir := filepath.Join(dest, "build", e.Name())
		for _, name := range []string{"raw", "data"} {
			if raw, err := os.ReadFile(filepath.Join(dir, name+".pid")); err == nil {
				if pid, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil && pid > 1 && processRuns(pid, dir) {
					syscall.Kill(pid, syscall.SIGKILL)
				}
			}
		}
		os.RemoveAll(dir)
		if runDir != "" && ValidSnapshotID(e.Name()) {
			os.RemoveAll(filepath.Join(runDir, e.Name()))
		}
	}
}

// importMemory is each import server's buffer pool: what o says, else an
// eighth of the memory the machine has free, between 512 MB and 8 GB (two
// servers run at once while the data is rebuilt, beside whatever else the
// machine serves).
func importMemory(o ImportOptions) string {
	if o.Memory != "" {
		return o.Memory
	}
	pool := int64(2 << 30)
	if avail := memAvailable(); avail > 0 {
		pool = min(max(avail/8, 512<<20), 8<<30)
	}
	return strconv.FormatInt(pool>>20, 10) + "M"
}

// importServer is a server an import runs as a child of its own.
type importServer struct {
	cmd  *exec.Cmd
	data string
	cnf  string
	sock string
	log  string
	done chan struct{}
}

func startImportServer(ctx context.Context, o ImportOptions, t mysqlTools, program, version, build, run, name, sockName string) (*importServer, error) {
	s := &importServer{data: filepath.Join(build, name), cnf: filepath.Join(build, name+".cnf"), sock: filepath.Join(run, sockName+".sock"),
		log: filepath.Join(build, name+".err"), done: make(chan struct{})}
	if _, err := os.Lstat(s.sock); err == nil {
		return nil, fmt.Errorf("%s is already there: another server would answer for the import's", s.sock)
	}
	var c strings.Builder
	fmt.Fprintf(&c, "[mysqld]\ndatadir=%s\nsocket=%s\npid-file=%s\nlog-error=%s\ntmpdir=%s\n", cnfValue(s.data), cnfValue(s.sock),
		cnfValue(filepath.Join(build, name+".pid")), cnfValue(s.log), cnfValue(build))
	c.WriteString("skip-networking\nmysqlx=OFF\nsecure-file-priv=NULL\nskip-log-bin\nperformance_schema=OFF\nevent_scheduler=OFF\n")
	fmt.Fprintf(&c, "innodb_buffer_pool_size=%s\ninnodb_doublewrite=OFF\ninnodb_flush_log_at_trx_commit=0\n", importMemory(o))
	c.WriteString("innodb_change_buffering=none\nmax_allowed_packet=1G\ninnodb_use_native_aio=OFF\n")
	if compareVersions(version, "8.0.30") >= 0 {
		c.WriteString("innodb_redo_log_capacity=4294967296\n")
	}
	c.WriteString("[client]\nuser=root\nsocket=" + cnfValue(s.sock) + "\nprotocol=SOCKET\n")
	if err := os.WriteFile(s.cnf, []byte(c.String()), 0o600); err != nil {
		return nil, err
	}
	if o.RunAs != nil {
		os.Chown(s.cnf, int(o.RunAs.Uid), int(o.RunAs.Gid))
	}
	server := func(args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, program, append([]string{"--defaults-file=" + s.cnf}, args...)...)
		cmd.SysProcAttr = importServerAttr(o.RunAs)
		return cmd
	}
	if out, err := server("--initialize-insecure").CombinedOutput(); err != nil {
		tail, _ := os.ReadFile(s.log)
		return nil, fmt.Errorf("initializing a server for the import: %v %s %s", err, strings.TrimSpace(string(out)), lastLines(string(tail), 8))
	}
	s.cmd = server()
	if err := s.cmd.Start(); err != nil {
		return nil, err
	}
	go func() { s.cmd.Wait(); close(s.done) }()
	deadline := time.Now().Add(dbStartTimeout)
	for {
		// Ours answers on our socket only while it runs.
		select {
		case <-s.done:
			tail, _ := os.ReadFile(s.log)
			if deniedByAppArmor(string(tail)) {
				return nil, errors.New("AppArmor kept the import's server from its files. " + apparmorFix())
			}
			return nil, fmt.Errorf("the import's server stopped as it started: %s", lastLines(string(tail), 8))
		default:
		}
		if mysqlReady(ctx, s.sock) == nil {
			return s, nil
		}
		select {
		case <-ctx.Done():
			s.stop()
			return nil, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			s.stop()
			return nil, errors.New("the import's server did not answer")
		}
	}
}

// shutdown stops the server slowly and cleanly (innodb_fast_shutdown=0):
// a copy of its files then starts with nothing to recover or merge.
func (s *importServer) shutdown(ctx context.Context, t mysqlTools) error {
	if _, err := t.sql(ctx, s.cnf, "SET GLOBAL innodb_fast_shutdown=0; SHUTDOWN;"); err != nil {
		select {
		case <-s.done:
		default:
			return fmt.Errorf("shutting the snapshot's server down: %w", err)
		}
	}
	select {
	case <-s.done:
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(30 * time.Minute):
		return errors.New("the snapshot's server did not shut down")
	}
	tail, _ := os.ReadFile(s.log)
	if !strings.Contains(string(tail), "Shutdown complete") {
		return fmt.Errorf("the snapshot's server did not shut down cleanly: %s", lastLines(string(tail), 6))
	}
	return nil
}

// stop ends a server the import no longer needs.
func (s *importServer) stop() {
	if s == nil || s.cmd == nil || s.cmd.Process == nil {
		return
	}
	select {
	case <-s.done:
		return
	default:
	}
	s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(2 * time.Minute):
		s.cmd.Process.Kill()
		<-s.done
	}
}

// pipe streams a dump of dbs (their tables alone with noData) from the
// server fromCnf names into the one toCnf names, never through a file; it
// says how many bytes went. A load that stops (an SQL error) stops the dump
// too, which would otherwise wait forever to write.
func (t mysqlTools) pipe(ctx context.Context, fromCnf, toCnf string, dbs []string, noData bool, progress io.Writer) (int64, error) {
	args := []string{"--defaults-file=" + fromCnf, "--single-transaction", "--quick", "--routines", "--triggers", "--events",
		"--hex-blob", "--set-gtid-purged=OFF", "--no-tablespaces", "--column-statistics=0"}
	if noData {
		args = append(args, "--no-data")
	}
	args = append(args, "--databases")
	dumpCmd := exec.CommandContext(ctx, t.dump, append(args, dbs...)...)
	loadCmd := exec.CommandContext(ctx, t.client, "--defaults-file="+toCnf, "--max-allowed-packet=1G")
	dumpCmd.Env, loadCmd.Env = t.env, t.env
	out, err := dumpCmd.StdoutPipe()
	if err != nil {
		return 0, err
	}
	var dumpErr, loadErr bytes.Buffer
	dumpCmd.Stderr, loadCmd.Stderr = &dumpErr, &loadErr
	in, err := loadCmd.StdinPipe()
	if err != nil {
		return 0, err
	}
	if err := loadCmd.Start(); err != nil {
		return 0, err
	}
	if err := dumpCmd.Start(); err != nil {
		in.Close()
		loadCmd.Wait()
		return 0, err
	}
	counter := &countingWriter{w: in, progress: progress, every: 1 << 30}
	n, copyErr := io.Copy(counter, out)
	in.Close()
	if copyErr != nil {
		dumpCmd.Process.Kill()
	}
	lErr := loadCmd.Wait()
	if lErr != nil {
		dumpCmd.Process.Kill()
	}
	dErr := dumpCmd.Wait()
	switch {
	case lErr != nil:
		return n, fmt.Errorf("mysql: %v %s", lErr, lastLines(loadErr.String(), 6))
	case dErr != nil:
		return n, fmt.Errorf("mysqldump: %v %s", dErr, lastLines(dumpErr.String(), 6))
	case copyErr != nil:
		return n, copyErr
	}
	return n, nil
}

type countingWriter struct {
	w        io.Writer
	n, next  int64
	every    int64
	progress io.Writer
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	if c.progress != nil && c.n >= c.next {
		fmt.Fprintf(c.progress, "  %s…\n", gib(c.n))
		c.next = c.n + c.every
	}
	return n, err
}

// runChecks runs a check file: every answer must be 0.
func runChecks(ctx context.Context, t mysqlTools, cnf, file string) (int, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return 0, err
	}
	out, err := t.sql(ctx, cnf, string(data))
	if err != nil {
		return 0, err
	}
	n := 0
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		v := strings.TrimSpace(sc.Text())
		if v == "" {
			continue
		}
		n++
		if v != "0" {
			return n, fmt.Errorf("check %d answered %s, not 0: nothing became the snapshot", n, v)
		}
	}
	if n == 0 {
		return 0, errors.New("its checks answered nothing: each statement should give one number, 0 when all is well")
	}
	return n, nil
}

// clearTables empties the named tables wherever the imported databases
// have them, and says which.
func clearTables(ctx context.Context, t mysqlTools, cnf string, dbs, tables []string) ([]string, error) {
	q := "SELECT CONCAT(table_schema, '.', table_name) FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema IN (" +
		quoteList(dbs) + ") AND table_name IN (" + quoteList(tables) + ")"
	out, err := t.sql(ctx, cnf, q)
	if err != nil {
		return nil, err
	}
	var found []string
	var sql strings.Builder
	sql.WriteString("SET FOREIGN_KEY_CHECKS=0;\n")
	for _, tbl := range strings.Fields(out) {
		db, table, ok := strings.Cut(tbl, ".")
		if !ok || !sqlIdent.MatchString(db) || !sqlIdent.MatchString(table) {
			continue
		}
		found = append(found, tbl)
		fmt.Fprintf(&sql, "TRUNCATE TABLE `%s`.`%s`;\n", db, table)
	}
	if len(found) == 0 {
		return nil, nil
	}
	_, err = t.sql(ctx, cnf, sql.String())
	return found, err
}

func quoteList(xs []string) string {
	q := make([]string, len(xs))
	for i, x := range xs {
		q[i] = "'" + strings.ReplaceAll(x, "'", "") + "'"
	}
	return strings.Join(q, ", ")
}

// finishSnapshot makes the server ready to be copied: the app's users from
// the base's .env (and --users), with every privilege on the project's
// databases and none on the server's administration, the databases its env
// files name, the data's definers, no tablespace outside the datadir, a
// small redo log.
func finishSnapshot(ctx context.Context, t mysqlTools, s *importServer, o ImportOptions, users map[string]string, dbs, grantOn []string, version string) error {
	var sql strings.Builder
	for _, d := range grantOn {
		fmt.Fprintf(&sql, "CREATE DATABASE IF NOT EXISTS `%s`;\n", d)
	}
	names := make([]string, 0, len(users))
	for u := range users {
		names = append(names, u)
	}
	sort.Strings(names)
	for _, u := range names {
		who, p := sqlString(u)+"@'%'", sqlString(users[u])
		fmt.Fprintf(&sql, "CREATE USER IF NOT EXISTS %s IDENTIFIED BY %s;\nALTER USER %s IDENTIFIED BY %s ACCOUNT UNLOCK;\n", who, p, who, p)
		sql.WriteString(grantsOn(who, grantOn))
	}
	if sql.Len() > 0 {
		if _, err := t.sql(ctx, s.cnf, sql.String()); err != nil {
			return fmt.Errorf("making the app's users: %w", err)
		}
	}
	if err := makeDefiners(ctx, t, s.cnf, dbs, grantOn); err != nil {
		return err
	}
	if o.UsersSQL != "" {
		if err := t.file(ctx, s.cnf, o.UsersSQL); err != nil {
			return fmt.Errorf("%s: %w", filepath.Base(o.UsersSQL), err)
		}
	}
	if out, err := t.sql(ctx, s.cnf, "SELECT COUNT(*) FROM information_schema.FILES WHERE FILE_NAME LIKE '/%'"); err == nil {
		if n, _ := strconv.Atoi(strings.TrimSpace(out)); n > 0 {
			return fmt.Errorf("%d tablespaces live outside the datadir (DATA DIRECTORY): a copy could not carry them", n)
		}
	}
	if compareVersions(version, "8.0.30") >= 0 {
		t.sql(ctx, s.cnf, "SET GLOBAL innodb_redo_log_capacity=104857600")
	}
	return nil
}

func treeBytes(dir string) int64 {
	var n int64
	filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			if info, err := d.Info(); err == nil {
				n += info.Size()
			}
		}
		return nil
	})
	return n
}

// shareTree makes a team's snapshot its group's to read: folders 2750,
// files 0640, owned by the team's user.
func shareTree(dir string, uid, gid int) error {
	return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		os.Lchown(p, uid, gid)
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if d.IsDir() {
			return os.Chmod(p, 0o750|fs.ModeSetgid)
		}
		return os.Chmod(p, 0o640)
	})
}

// swapCurrent points the project's current snapshot at id, at once: a new
// link renamed over the old one.
func swapCurrent(dest, id string) error {
	tmp := filepath.Join(dest, ".current-"+id)
	os.Remove(tmp)
	if err := os.Symlink(filepath.Join("gen", id), tmp); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dest, "current"))
}

// SnapshotGens are a project's snapshots in dest, newest first, and which is
// current.
func SnapshotGens(dest string) (gens []snapshotManifest, current string) {
	if target, err := os.Readlink(filepath.Join(dest, "current")); err == nil {
		current = filepath.Base(target)
	}
	entries, _ := os.ReadDir(filepath.Join(dest, "gen"))
	for _, e := range entries {
		var m snapshotManifest
		if loadJSON(filepath.Join(dest, "gen", e.Name(), "manifest.json"), &m) == nil {
			gens = append(gens, m)
		}
	}
	sort.Slice(gens, func(i, j int) bool { return gens[i].ID > gens[j].ID })
	return gens, current
}

// PruneSnapshots keeps keep snapshots: the current one and the newest
// others. Worktrees' copies never depend on them: their blocks are counted by
// the disk.
func PruneSnapshots(dest string, keep int) []string {
	gens, current := SnapshotGens(dest)
	var removed []string
	kept := 0
	for _, g := range gens {
		if g.ID == current {
			continue
		}
		if kept < keep-1 {
			kept++
			continue
		}
		if os.RemoveAll(filepath.Join(dest, "gen", g.ID)) == nil {
			removed = append(removed, g.ID)
		}
	}
	return removed
}
