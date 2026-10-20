package box

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The database servers a worktree runs of its own (database.go): the box's
// MySQL server program, started as the box's user on a copy of the
// project's snapshot, and an empty Redis. Both listen on 127.0.0.1 alone, on
// the last two ports of the worktree's block.

// A database snapshot is a cleanly shut down MySQL datadir the project's
// worktrees start their own server on. The box keeps its own in
// <db root>/base/<key>/gen/<id>/ (data/ and manifest.json), current a link to
// the one in use; a team's lives in the team's folder and its current one is
// published with it (team.go).
type snapshotManifest struct {
	ID     string `json:"id"`
	Engine string `json:"engine"`
	// Version is the MySQL server's that made it: an older one cannot
	// start it.
	Version             string    `json:"version"`
	LowerCaseTableNames int       `json:"lower_case_table_names"`
	Databases           []string  `json:"databases,omitempty"`
	Bytes               int64     `json:"bytes,omitempty"`
	Created             time.Time `json:"created"`
	// Sanitized says personal data was taken out of it as it was made.
	Sanitized bool `json:"sanitized"`
	Checks    int  `json:"checks,omitempty"`
	// Source says where it came from, never with a password.
	Source string `json:"source,omitempty"`
}

// snapshot is the one a project's worktrees start from.
type snapshot struct {
	Manifest snapshotManifest
	// Data is the datadir copied from.
	Data string
	// Layer is "box" or "team".
	Layer string
}

// dbRoot is where pierd keeps databases: big data, never in its config
// folder ($XDG_DATA_HOME/pier/db, ~/.local/share/pier/db).
func (b *Box) dbRoot() string {
	if b.DBDir != "" {
		return b.DBDir
	}
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "pier", "db")
}

// DefaultDBRoot is where a pierd that sets no DBDir keeps databases.
func DefaultDBRoot() string { return (&Box{}).dbRoot() }

// currentSnapshot is the snapshot a project's new worktrees start their
// database from: the box's own when it has one, else the team's (as the
// box's copy of the team's base names it: refreshTeam first for the one
// published last).
func (b *Box) currentSnapshot(key string) *snapshot {
	dir := filepath.Join(b.dbRoot(), "base", key)
	if target, err := os.Readlink(filepath.Join(dir, "current")); err == nil {
		if !filepath.IsAbs(target) {
			target = filepath.Join(dir, target)
		}
		var m snapshotManifest
		if loadJSON(filepath.Join(target, "manifest.json"), &m) == nil {
			return &snapshot{Manifest: m, Data: filepath.Join(target, "data"), Layer: "box"}
		}
	}
	var pub teamPublished
	mu := b.baseLock(key)
	mu.Lock()
	err := loadJSON(filepath.Join(b.baseDir(key), "team", "published.json"), &pub)
	mu.Unlock()
	if err == nil && pub.DB != nil && pub.DB.ID != "" {
		if set, ok, _ := readTeamSettings(); ok {
			return &snapshot{Manifest: pub.DB.Manifest, Data: filepath.Join(set.Dir, "projects", key, "db", "gen", pub.DB.ID, "data"), Layer: "team"}
		}
	}
	return nil
}

// The MySQL server.

// mysqlServer finds the box's MySQL server program; tests replace it.
var mysqlServer = func() string {
	if p, err := exec.LookPath("mysqld"); err == nil {
		return p
	}
	for _, p := range []string{"/usr/sbin/mysqld", "/usr/local/mysql/bin/mysqld"} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

var mysqldVersionRE = regexp.MustCompile(`Ver (\d+\.\d+\.\d+)`)

// mysqldVersion is a server program's version ("8.0.46").
func mysqldVersion(ctx context.Context, program string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, program, "--version").CombinedOutput()
	if m := mysqldVersionRE.FindSubmatch(out); m != nil {
		return string(m[1]), nil
	}
	if err == nil {
		err = errors.New("no version in its output")
	}
	return "", fmt.Errorf("%s --version: %v", program, err)
}

// compareVersions orders two dotted versions, 8.0.9 before 8.0.46.
func compareVersions(a, b string) int {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < max(len(as), len(bs)); i++ {
		var x, y int
		if i < len(as) {
			x, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			y, _ = strconv.Atoi(bs[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

// mysqlOptions are the server options a project may set for its worktrees'
// servers. Anything else (an init file, a plugin) would run what it names.
var mysqlOptions = map[string]bool{
	"character_set_server": true, "collation_server": true, "default_time_zone": true, "event_scheduler": true,
	"explicit_defaults_for_timestamp": true, "group_concat_max_len": true, "innodb_buffer_pool_size": true,
	"innodb_lock_wait_timeout": true, "innodb_strict_mode": true, "log_bin_trust_function_creators": true,
	"max_allowed_packet": true, "max_connections": true, "max_heap_table_size": true, "sort_buffer_size": true,
	"sql_mode": true, "table_open_cache": true, "temptable_max_ram": true, "tmp_table_size": true,
	"transaction_isolation": true, "wait_timeout": true,
}

var mysqlOptionValue = regexp.MustCompile(`^[A-Za-z0-9_.,:+/' -]{1,200}$`)

func validateMySQLOptions(opts map[string]string) error {
	for k, v := range opts {
		name := strings.ReplaceAll(k, "-", "_")
		if !mysqlOptions[name] {
			return fmt.Errorf("base.db.options: %s is not an option a project may set", k)
		}
		if !mysqlOptionValue.MatchString(v) {
			return fmt.Errorf("base.db.options: %s's value has characters it may not", k)
		}
	}
	return nil
}

// mysqlConfig is a worktree's server's my.cnf: pierd's own settings, which
// a project's options cannot change, then those options.
func mysqlConfig(dir, run string, port int, version string, m snapshotManifest, opts map[string]string) []byte {
	var b bytes.Buffer
	b.WriteString("[mysqld]\n")
	set := func(k, v string) { fmt.Fprintf(&b, "%s=%s\n", k, v) }
	setPath := func(k, v string) { set(k, cnfValue(v)) }
	setPath("datadir", filepath.Join(dir, "data"))
	setPath("tmpdir", filepath.Join(dir, "tmp"))
	setPath("log-error", filepath.Join(dir, "error.log"))
	setPath("socket", filepath.Join(run, "mysqld.sock"))
	setPath("pid-file", filepath.Join(run, "mysqld.pid"))
	set("port", strconv.Itoa(port))
	set("bind-address", "127.0.0.1")
	// Every worktree's server would want X Protocol's port 33060.
	set("mysqlx", "OFF")
	// The default folder is the system server's, which the box's user
	// cannot read: the server would not start.
	set("secure-file-priv", "NULL")
	setPath("init-file", filepath.Join(dir, "init.sql"))
	set("lower_case_table_names", strconv.Itoa(m.LowerCaseTableNames))
	// What one server of many needs: a modest buffer pool, no binary log,
	// no statistics schema, settings the snapshot persisted ignored, and no
	// native AIO, whose budget the whole host shares.
	defaults := map[string]string{
		"innodb_buffer_pool_size": "256M", "max_connections": "100", "temptable_max_ram": "64M",
	}
	for k, v := range defaults {
		if _, ok := opts[k]; !ok {
			set(k, v)
		}
	}
	b.WriteString("skip-log-bin\n")
	// A production's scheduled events would run in every worktree.
	if _, ok := opts["event_scheduler"]; !ok {
		set("event_scheduler", "OFF")
	}
	set("performance_schema", "OFF")
	set("persisted_globals_load", "OFF")
	// The redo log's size took one setting from 8.0.30 on.
	if compareVersions(version, "8.0.30") >= 0 {
		set("innodb_redo_log_capacity", "104857600")
	}
	set("innodb_flush_method", "fsync")
	set("innodb_flush_log_at_trx_commit", "2")
	set("innodb_doublewrite", "OFF")
	set("innodb_use_native_aio", "OFF")
	set("innodb_change_buffering", "none")
	set("innodb_buffer_pool_load_at_startup", "OFF")
	set("innodb_buffer_pool_dump_at_shutdown", "OFF")
	keys := make([]string, 0, len(opts))
	for k := range opts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		set(strings.ReplaceAll(k, "-", "_"), opts[k])
	}
	return b.Bytes()
}

// mysqlInit is what the server runs each time it starts: root gets this
// server's own password, so nobody else on the box reaches it as root (a
// snapshot's root may have none, and loopback TCP counts as localhost).
func mysqlInit(password string) []byte {
	return []byte("ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '" + password + "';\n")
}

// mysqlClient is the client options pierd itself connects with (read with
// --defaults-file, so nothing in the user's own ~/.my.cnf changes them).
func mysqlClient(sock, password string) []byte {
	return []byte("[client]\nuser=root\npassword=" + cnfValue(password) + "\nsocket=" + cnfValue(sock) + "\nprotocol=SOCKET\n")
}

// cnfValue puts a value in a MySQL option file whole: in double quotes, with
// its backslashes, quotes and line breaks escaped, so a # or a space in it
// (a password, a folder's name) stays part of it.
func cnfValue(v string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\r", `\r`, "\t", `\t`)
	return `"` + r.Replace(v) + `"`
}

func newSecret() string {
	var b [18]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// datadirLeftovers are what a copied datadir must not keep: the server's
// identity, its warm-up list, temporary and persisted settings, binary logs,
// a pid and the keys it makes again by itself.
var datadirLeftovers = []string{"auto.cnf", "ib_buffer_pool", "ibtmp1", "#innodb_temp", "mysqld-auto.cnf", "*.pid", "*.pem", "binlog.*", "*.sock", "*.sock.lock", "mysql.sock*"}

// cleanDatadir takes a copied datadir's leftovers out and makes it the
// box user's alone.
func cleanDatadir(dir string) error {
	for _, pat := range datadirLeftovers {
		matches, _ := filepath.Glob(filepath.Join(dir, pat))
		for _, m := range matches {
			if err := os.RemoveAll(m); err != nil {
				return err
			}
		}
	}
	return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		mode := info.Mode().Perm() &^ 0o077
		if d.IsDir() {
			mode |= 0o700
		} else {
			mode |= 0o600
		}
		return os.Chmod(p, mode)
	})
}

// mysqlReady says a MySQL server answers on sock: its first packet, the
// handshake, comes before any login.
func mysqlReady(ctx context.Context, sock string) error {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", sock)
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	head := make([]byte, 5)
	if _, err := conn.Read(head); err != nil {
		return err
	}
	// Protocol 10, or an error packet (0xff): either way a server is there.
	if head[4] != 10 && head[4] != 0xff {
		return fmt.Errorf("not a MySQL server's greeting")
	}
	return nil
}

// apparmorMySQL says how AppArmor stands for the box's MySQL server: "none"
// (no profile confines it), "ok" (the box's rule for pier's folders is
// there) or "needs_rule".
func apparmorMySQL() string {
	if b, err := os.ReadFile(apparmorEnabled); err != nil || strings.TrimSpace(string(b)) != "Y" {
		return "none"
	}
	if _, err := os.Stat(apparmorProfile); err != nil {
		return "none"
	}
	if b, err := os.ReadFile(apparmorLocal); err == nil && bytes.Contains(b, []byte(apparmorMarker)) {
		return "ok"
	}
	return "needs_rule"
}

// Where AppArmor's state and the MySQL server's profile are; tests replace
// them.
var (
	apparmorEnabled = "/sys/module/apparmor/parameters/enabled"
	apparmorProfile = "/etc/apparmor.d/usr.sbin.mysqld"
	apparmorLocal   = "/etc/apparmor.d/local/usr.sbin.mysqld"
)

const apparmorMarker = "# pier: per-worktree MySQL servers"

// apparmorRule is what root adds to the MySQL server's local AppArmor rules
// once, so the box's users can run it on their own folders: the worktrees'
// copies (~/.local/share/pier/db), their sockets (the runtime folder, or
// /tmp/pier-<uid> without one) and the team's imports in teamDir.
func apparmorRule(teamDir string) string {
	return apparmorMarker + "\n" +
		"owner @{HOME}/.local/share/pier/db/ r,\n" +
		"owner @{HOME}/.local/share/pier/db/** rwk,\n" +
		"owner /run/user/[0-9]*/pier/ r,\n" +
		"owner /run/user/[0-9]*/pier/** rwk,\n" +
		"owner /tmp/pier-[0-9]*/db/ r,\n" +
		"owner /tmp/pier-[0-9]*/db/** rwk,\n" +
		"owner " + teamDir + "/projects/*/db/build/** rwk,\n" +
		"owner /run/pier-team/ r,\n" +
		"owner /run/pier-team/** rwk,\n"
}

// DefaultTeamDir is the team's folder `pierd team init` makes unless told
// another.
const DefaultTeamDir = "/srv/pier/team"

// AppArmorRule is apparmorRule for this machine's team folder, for `pierd db
// apparmor`.
func AppArmorRule() string {
	dir := DefaultTeamDir
	if set, ok, _ := readTeamSettings(); ok {
		dir = set.Dir
	}
	return apparmorRule(dir)
}

// apparmorFix is the root-once fix for a server AppArmor stopped.
func apparmorFix() string {
	return "AppArmor confines the box's MySQL server to its own folders. Once, as root: sudo pierd team init, " +
		"or add these lines to " + apparmorLocal + " and run apparmor_parser -r " + apparmorProfile + ":\n" + AppArmorRule()
}

// deniedByAppArmor says a server's log reads like AppArmor kept it from its
// files.
func deniedByAppArmor(log string) bool {
	return (strings.Contains(log, "Errcode: 13") || strings.Contains(log, "Permission denied")) && apparmorMySQL() == "needs_rule"
}

// The Redis server.

var redisServer = func() string {
	if p, err := exec.LookPath("redis-server"); err == nil {
		return p
	}
	return ""
}

var redisVersionRE = regexp.MustCompile(`v=(\d+\.\d+\.\d+)`)

// redisVersion is a Redis server program's version ("7.0.15").
func redisVersion(ctx context.Context, program string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, program, "--version").CombinedOutput()
	if m := redisVersionRE.FindSubmatch(out); m != nil {
		return string(m[1]), nil
	}
	if err == nil {
		err = errors.New("no version in its output")
	}
	return "", fmt.Errorf("%s --version: %v", program, err)
}

// redisConfig is a worktree's Redis's config: on 127.0.0.1 alone, with a
// password of its own, keeping nothing on disk. Nothing that reaches it can
// change where it writes or load code: CONFIG, MODULE and DEBUG are off
// (Redis 7 has settings for that; an older one, where CONFIG SET dir would
// let it write a file anywhere its user can, has them renamed away).
func redisConfig(dir, run string, port int, password, version string) []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "port %d\nbind 127.0.0.1\ndir %s\npidfile %s\n", port, redisQuote(filepath.Join(dir, "data")), redisQuote(filepath.Join(run, "redis.pid")))
	b.WriteString("save \"\"\nappendonly no\ndaemonize no\nprotected-mode yes\nmaxmemory 256mb\nmaxmemory-policy noeviction\n")
	if password != "" {
		fmt.Fprintf(&b, "requirepass %s\n", redisQuote(password))
	}
	if version != "" && compareVersions(version, "7.0.0") >= 0 {
		b.WriteString("enable-protected-configs no\nenable-debug-command no\nenable-module-command no\n")
	} else {
		b.WriteString("rename-command CONFIG \"\"\nrename-command DEBUG \"\"\nrename-command MODULE \"\"\n")
	}
	return b.Bytes()
}

// redisQuote puts a value in a Redis config file whole: in double quotes,
// with its backslashes and quotes escaped.
func redisQuote(v string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\r", `\r`)
	return `"` + r.Replace(v) + `"`
}

// redisReady says a Redis server answers PING on port (or asks for its
// password: it is up all the same).
func redisReady(ctx context.Context, port int) error {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write([]byte("PING\r\n")); err != nil {
		return err
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(line, "+PONG") && !strings.HasPrefix(line, "-NOAUTH") {
		return fmt.Errorf("not a Redis server: %q", strings.TrimSpace(line))
	}
	return nil
}
