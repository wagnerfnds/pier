package box

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"pier/pierd/internal/doctor"
)

// Each worktree of a project whose base has a database gets a MySQL server
// of its own, started as the box's user on a copy of the project's snapshot
// that shares the snapshot's blocks (btrfs, XFS): its databases, users and
// passwords are the snapshot's, so the project's .env serves every worktree
// and only the host and port change. A Redis of its own, empty, keeps queues,
// caches and Horizon apart. Both run as managed units that stay down when
// stopped, and go with their worktree.

// BaseDB is a base's database: the engine every worktree runs a server of,
// and the server options the project needs.
type BaseDB struct {
	Engine  string            `json:"engine"`
	Options map[string]string `json:"options,omitempty"`
	// AllowCopy lets a worktree's copy of the snapshot be a full one where
	// the disk cannot share blocks: slow and as big as the snapshot.
	AllowCopy bool `json:"allow_copy,omitempty"`
}

func (d *BaseDB) validate() error {
	if d == nil {
		return nil
	}
	if d.Engine != engineMySQL {
		return fmt.Errorf("base.db.engine is %s", engineMySQL)
	}
	return validateMySQLOptions(d.Options)
}

const (
	engineMySQL = "mysql"
	engineRedis = "redis"
	// The last two ports of a worktree's block are its servers'.
	redisPortOffset = portBlock - 2
	mysqlPortOffset = portBlock - 1
	// maxPortsWithServers is how many ports ($PIER_PORT, $PIER_PORT_1…) a
	// worktree with servers of its own may ask for.
	maxPortsWithServers = portBlock - 2
)

var (
	// dbStartTimeout is how long a server may take to answer the first time
	// (a newer server upgrades a copy's data dictionary as it starts).
	dbStartTimeout = 5 * time.Minute
	// A copy is refused below this much free space on the disk, the larger
	// of an amount and a share: copies grow as worktrees change their data.
	dbFreeFloor int64 = 50 << 30
	dbFreeShare       = 0.10
)

// dbInstance is one worktree's server.
type dbInstance struct {
	ID       string `json:"id"`
	Engine   string `json:"engine"`
	Location string `json:"location"`
	Worktree string `json:"worktree"`
	Path     string `json:"path"`
	Key      string `json:"key"`
	Port     int    `json:"port"`
	Unit     string `json:"unit"`
	// Snapshot is the snapshot's id it was copied from, Layer whose ("box",
	// "team"), Version the server's.
	Snapshot string    `json:"snapshot,omitempty"`
	Layer    string    `json:"layer,omitempty"`
	Version  string    `json:"version,omitempty"`
	Created  time.Time `json:"created"`
	CloneMS  int64     `json:"clone_ms,omitempty"`
	StartMS  int64     `json:"start_ms,omitempty"`
	// State is "pending" (reserved, not made yet), "running" or "failed".
	State string `json:"state"`
	Error string `json:"error,omitempty"`
}

// InstanceReport is how a worktree's server came up, kept with its
// preparation.
type InstanceReport struct {
	Engine string `json:"engine"`
	Port   int    `json:"port"`
	// Action is "copied" (a new copy of the snapshot), "created" (an empty
	// server), "started", "running" (it already was) or "failed".
	Action          string     `json:"action"`
	Snapshot        string     `json:"snapshot,omitempty"`
	SnapshotCreated *time.Time `json:"snapshot_created,omitempty"`
	Layer           string     `json:"layer,omitempty"`
	Reason          string     `json:"reason,omitempty"`
	MS              int64      `json:"ms,omitempty"`
}

// dbSupported says this box can run worktrees' servers: Linux, where pierd
// manages them as systemd units.
func dbSupported() bool { return runtime.GOOS == "linux" || dbForceSupported }

// dbForceSupported lets tests run them anywhere.
var dbForceSupported = false

// dbRegistry keeps one change to the box's servers' records at a time.
type dbRegistry struct {
	mu sync.Mutex
}

func (b *Box) instancesPath() string { return filepath.Join(b.baseRoot(), "instances.json") }

func (b *Box) loadInstances() map[string]dbInstance {
	m := map[string]dbInstance{}
	loadJSON(b.instancesPath(), &m)
	return m
}

func (b *Box) instancesFor(path string) []dbInstance {
	b.dbs.mu.Lock()
	defer b.dbs.mu.Unlock()
	var out []dbInstance
	for _, inst := range b.loadInstances() {
		if inst.Path == path {
			out = append(out, inst)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Engine < out[j].Engine })
	return out
}

// updateInstances changes the registry with change and saves it.
func (b *Box) updateInstances(change func(m map[string]dbInstance)) {
	b.dbs.mu.Lock()
	defer b.dbs.mu.Unlock()
	m := b.loadInstances()
	change(m)
	saveJSON(b.instancesPath(), m)
}

func (b *Box) instanceDir(id string) string { return filepath.Join(b.dbRoot(), "i", id) }

// instanceRun is where a server's socket and pid go: a short path (a socket's
// is at most 108 bytes) in the user's runtime folder, gone after a reboot,
// so the unit makes it again before it starts.
func instanceRun(id string) string {
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "pier", "db", id)
	}
	return filepath.Join(os.TempDir(), "pier-"+strconv.Itoa(os.Getuid()), "db", id)
}

// wantedServers are the engines loc's worktrees get servers of, from its
// base, and the database's settings.
func (b *Box) wantedServers(ctx context.Context, loc Location) ([]string, *BaseDB) {
	if !dbSupported() {
		return nil, nil
	}
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil || cfg.Effective.Base == nil {
		return nil, nil
	}
	var engines []string
	db := cfg.Effective.Base.DB
	if db != nil && db.Engine == engineMySQL {
		engines = append(engines, engineMySQL)
	}
	if cfg.Effective.Base.Redis {
		engines = append(engines, engineRedis)
	}
	return engines, db
}

func instanceUnit(engine string, loc, wt, id string) string {
	prefix := "db-"
	if engine == engineRedis {
		prefix = "redis-"
	}
	name := prefix + slug(loc, 30) + "-" + slug(wt, 40) + "-" + id[:6]
	return strings.TrimRight(name, "-")
}

// reserveInstances records the servers a worktree will get before they run,
// so what starts in it meanwhile (a task's agent) has their addresses
// already. A database needs a snapshot to copy.
func (b *Box) reserveInstances(ctx context.Context, loc Location, wt Worktree) {
	engines, _ := b.wantedServers(ctx, loc)
	if len(engines) == 0 {
		return
	}
	key, err := b.Locations.BaseKey(ctx, loc.Name)
	if err != nil {
		return
	}
	start, err := b.Locations.Ports.For(wt.Path)
	if err != nil || start == 0 {
		return
	}
	have := map[string]bool{}
	for _, inst := range b.instancesFor(wt.Path) {
		have[inst.Engine] = true
	}
	snap := b.currentSnapshot(key)
	b.updateInstances(func(m map[string]dbInstance) {
		for _, e := range engines {
			if have[e] || e == engineMySQL && snap == nil {
				continue
			}
			id := newSecret()[:12]
			port := start + redisPortOffset
			if e == engineMySQL {
				port = start + mysqlPortOffset
			}
			m[id] = dbInstance{ID: id, Engine: e, Location: loc.Name, Worktree: wt.Name, Path: wt.Path, Key: key, Port: port,
				Unit: instanceUnit(e, loc.Name, wt.Name, id), Created: time.Now().UTC(), State: "pending"}
		}
	})
}

// ensureInstances brings a worktree's servers up, making each the first
// time (a copy of the project's snapshot, an empty Redis). A server that
// cannot come up fails the worktree's preparation, with why.
func (b *Box) ensureInstances(ctx context.Context, loc Location, wt Worktree) ([]InstanceReport, error) {
	engines, db := b.wantedServers(ctx, loc)
	if len(engines) == 0 {
		return nil, nil
	}
	if b.Units == nil {
		return nil, errors.New("this box cannot run managed units, which a worktree's database needs")
	}
	b.reserveInstances(ctx, loc, wt)
	var reports []InstanceReport
	for _, inst := range b.instancesFor(wt.Path) {
		var rep InstanceReport
		var err error
		switch inst.Engine {
		case engineMySQL:
			rep, err = b.upMySQL(ctx, inst, db)
		case engineRedis:
			rep, err = b.upRedis(ctx, inst)
		}
		reports = append(reports, rep)
		if err != nil {
			b.updateInstances(func(m map[string]dbInstance) {
				if cur, ok := m[inst.ID]; ok {
					cur.State, cur.Error = "failed", err.Error()
					m[inst.ID] = cur
				}
			})
			return reports, err
		}
	}
	for _, e := range engines {
		if e == engineMySQL && !hasEngine(reports, engineMySQL) {
			return reports, errors.New("the project's base has no database snapshot yet: root makes the team's with `pierd team base … db import`, or `pierd db import` this box's")
		}
	}
	return reports, nil
}

func hasEngine(rs []InstanceReport, engine string) bool {
	for _, r := range rs {
		if r.Engine == engine {
			return true
		}
	}
	return false
}

// diskRoom refuses a copy when the disk holding dir is nearly full.
func diskRoom(dir string) error {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return nil
	}
	free := int64(st.Bavail) * int64(st.Bsize)
	total := int64(st.Blocks) * int64(st.Bsize)
	need := max(dbFreeFloor, int64(float64(total)*dbFreeShare))
	if free < need {
		return fmt.Errorf("the disk has %s free and a worktree's database needs at least %s left over: free some space first", gib(free), gib(need))
	}
	return nil
}

func gib(n int64) string { return fmt.Sprintf("%.1f GB", float64(n)/(1<<30)) }

func (b *Box) upMySQL(ctx context.Context, inst dbInstance, db *BaseDB) (InstanceReport, error) {
	rep := InstanceReport{Engine: inst.Engine, Port: inst.Port}
	fail := func(err error) (InstanceReport, error) {
		rep.Action, rep.Reason = "failed", err.Error()
		return rep, err
	}
	program := mysqlServer()
	if program == "" {
		return fail(errors.New("this box has no MySQL server (mysqld) for the worktree's database: install the same version the project's snapshot was made with"))
	}
	version, err := mysqldVersion(ctx, program)
	if err != nil {
		return fail(err)
	}
	dir, run := b.instanceDir(inst.ID), instanceRun(inst.ID)
	data := filepath.Join(dir, "data")
	snap := b.currentSnapshot(inst.Key)
	if _, err := os.Stat(data); err != nil {
		if snap == nil {
			return fail(errors.New("the project's base has no database snapshot yet"))
		}
		if compareVersions(version, snap.Manifest.Version) < 0 {
			return fail(fmt.Errorf("the project's snapshot was made with MySQL %s and this box's server is %s: a server cannot start a newer one's data", snap.Manifest.Version, version))
		}
		if err := os.MkdirAll(filepath.Join(b.dbRoot(), "i"), 0o700); err != nil {
			return fail(err)
		}
		if err := diskRoom(b.dbRoot()); err != nil {
			return fail(err)
		}
		start := time.Now()
		if err := b.copySnapshot(ctx, inst.Key, snap, dir, db != nil && db.AllowCopy); err != nil {
			return fail(err)
		}
		rep.Action, rep.MS = "copied", time.Since(start).Milliseconds()
		inst.CloneMS, inst.Snapshot, inst.Layer = rep.MS, snap.Manifest.ID, snap.Layer
	}
	if snap != nil && inst.Snapshot == "" {
		inst.Snapshot, inst.Layer = snap.Manifest.ID, snap.Layer
	}
	if snap != nil {
		rep.Snapshot, rep.Layer = snap.Manifest.ID, snap.Layer
		created := snap.Manifest.Created
		rep.SnapshotCreated = &created
	}
	// The settings are written again each time: a project's options change,
	// and so does the server's version.
	var manifest snapshotManifest
	if snap != nil {
		manifest = snap.Manifest
	}
	password := ""
	if secret, err := os.ReadFile(filepath.Join(dir, "root.secret")); err == nil {
		password = strings.TrimSpace(string(secret))
	} else {
		password = newSecret()
	}
	opts := map[string]string{}
	if db != nil {
		opts = db.Options
	}
	sock := filepath.Join(run, "mysqld.sock")
	for name, content := range map[string][]byte{
		"my.cnf":      mysqlConfig(dir, run, inst.Port, version, manifest, opts),
		"init.sql":    mysqlInit(password),
		"client.cnf":  mysqlClient(sock, password),
		"root.secret": []byte(password + "\n"),
	} {
		if err := os.WriteFile(filepath.Join(dir, name), content, 0o600); err != nil {
			return fail(err)
		}
	}
	os.MkdirAll(filepath.Join(dir, "tmp"), 0o700)
	if rep.Action == "" {
		rep.Action = "started"
		if u, err := b.Units.Get(inst.Unit); err == nil && u.State == "running" && mysqlReady(ctx, sock) == nil {
			rep.Action = "running"
		}
	}
	if rep.Action != "running" {
		// A lock a server killed in the middle left behind would stop the
		// new one.
		os.Remove(sock + ".lock")
		start := time.Now()
		if err := b.startUnit(ctx, inst, program, "--defaults-file="+filepath.Join(dir, "my.cnf")); err != nil {
			return fail(err)
		}
		if err := b.waitServer(ctx, inst, func(ctx context.Context) error { return mysqlReady(ctx, sock) }); err != nil {
			log, _ := os.ReadFile(filepath.Join(dir, "error.log"))
			tail := lastLines(string(log), 12)
			b.Units.Remove(inst.Unit)
			if deniedByAppArmor(tail) {
				return fail(httpError{http.StatusConflict, "the worktree's database could not open its files. " + apparmorFix()})
			}
			if tail != "" {
				err = fmt.Errorf("%v; its log ends:\n%s", err, tail)
			}
			return fail(err)
		}
		inst.StartMS = time.Since(start).Milliseconds()
		if rep.MS == 0 {
			rep.MS = inst.StartMS
		}
	}
	inst.Version, inst.State, inst.Error = version, "running", ""
	b.updateInstances(func(m map[string]dbInstance) { m[inst.ID] = inst })
	return rep, nil
}

// copySnapshot copies a snapshot's datadir into a new instance folder, whole
// or not at all, sharing blocks: a plain copy only where allowed.
func (b *Box) copySnapshot(ctx context.Context, key string, snap *snapshot, dir string, allowCopy bool) error {
	tmp := dir + ".tmp"
	os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	var err error
	// A snapshot removed while it was being copied (root published another)
	// is copied again from the current one.
	for attempt := 0; attempt < 2; attempt++ {
		err = cloneTree(ctx, snap.Data, filepath.Join(tmp, "data"), !allowCopy)
		if err == nil {
			break
		}
		os.RemoveAll(filepath.Join(tmp, "data"))
		if next := b.currentSnapshot(key); next != nil && next.Data != snap.Data {
			snap = next
			continue
		}
		break
	}
	if err != nil {
		os.RemoveAll(tmp)
		if !allowCopy && (strings.Contains(err.Error(), "reflink") || strings.Contains(err.Error(), "Operation not supported")) {
			return fmt.Errorf("this disk cannot copy the snapshot sharing its blocks, and a full copy is as big as the snapshot: set base.db.allow_copy to copy it anyway (%v)", err)
		}
		return err
	}
	if err := cleanDatadir(filepath.Join(tmp, "data")); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	if err := os.Rename(tmp, dir); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	return nil
}

func (b *Box) upRedis(ctx context.Context, inst dbInstance) (InstanceReport, error) {
	rep := InstanceReport{Engine: inst.Engine, Port: inst.Port}
	fail := func(err error) (InstanceReport, error) {
		rep.Action, rep.Reason = "failed", err.Error()
		return rep, err
	}
	program := redisServer()
	if program == "" {
		return fail(errors.New("this box has no Redis server (redis-server) for the worktree's own Redis"))
	}
	dir, run := b.instanceDir(inst.ID), instanceRun(inst.ID)
	if err := os.MkdirAll(filepath.Join(dir, "data"), 0o700); err != nil {
		return fail(err)
	}
	conf := append(redisConfig(dir, inst.Port, b.redisPassword(inst.Key)), []byte("pidfile "+filepath.Join(run, "redis.pid")+"\n")...)
	if err := os.WriteFile(filepath.Join(dir, "redis.conf"), conf, 0o600); err != nil {
		return fail(err)
	}
	if u, err := b.Units.Get(inst.Unit); err == nil && u.State == "running" && redisReady(ctx, inst.Port) == nil {
		rep.Action = "running"
	} else {
		rep.Action = "created"
		if inst.State == "running" {
			rep.Action = "started"
		}
		start := time.Now()
		if err := b.startUnit(ctx, inst, program, filepath.Join(dir, "redis.conf")); err != nil {
			return fail(err)
		}
		if err := b.waitServer(ctx, inst, func(ctx context.Context) error { return redisReady(ctx, inst.Port) }); err != nil {
			b.Units.Remove(inst.Unit)
			return fail(err)
		}
		rep.MS = time.Since(start).Milliseconds()
	}
	inst.State, inst.Error = "running", ""
	b.updateInstances(func(m map[string]dbInstance) { m[inst.ID] = inst })
	return rep, nil
}

// startUnit installs and starts a server's unit: it makes its runtime folder
// (gone after a reboot) and runs program with args, stays down when stopped
// cleanly, and gets minutes to shut down.
func (b *Box) startUnit(ctx context.Context, inst dbInstance, program string, args ...string) error {
	if err := portFree(inst.Port); err != nil {
		if u, uerr := b.Units.Get(inst.Unit); uerr != nil || u.State != "running" {
			return err
		}
	}
	argv := append([]string{"-c", `mkdir -p "$0" && exec "$@"`, instanceRun(inst.ID), program}, args...)
	_, err := b.Units.Install(ctx, UnitRequest{Name: inst.Unit, Program: "/bin/sh", Args: argv, KeepStopped: true, StopTimeout: 5 * time.Minute})
	return err
}

// portFree says nothing listens on 127.0.0.1:port yet.
func portFree(port int) error {
	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return fmt.Errorf("port %d, a worktree's own, is taken by another program", port)
	}
	ln.Close()
	return nil
}

// waitServer waits for a server to answer, giving up when its unit died.
func (b *Box) waitServer(ctx context.Context, inst dbInstance, ready func(context.Context) error) error {
	deadline := time.Now().Add(dbStartTimeout)
	var last error
	for time.Now().Before(deadline) {
		if last = ready(ctx); last == nil {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
		if u, err := b.Units.Get(inst.Unit); err == nil && u.State != "running" {
			// One more look: it may have answered just before going.
			if last = ready(ctx); last == nil {
				return nil
			}
			return fmt.Errorf("the worktree's %s server stopped as it started", inst.Engine)
		}
	}
	return fmt.Errorf("the worktree's %s server did not answer within %s: %v", inst.Engine, dbStartTimeout, last)
}

// dropInstances ends a worktree's servers and deletes their data: the
// worktree is going away, or its database starts over. Nothing waits for a
// clean shutdown of data about to be deleted.
func (b *Box) dropInstances(path string) {
	for _, inst := range b.instancesFor(path) {
		b.killInstance(inst)
		os.RemoveAll(b.instanceDir(inst.ID))
		os.RemoveAll(b.instanceDir(inst.ID) + ".tmp")
		os.RemoveAll(instanceRun(inst.ID))
		b.updateInstances(func(m map[string]dbInstance) { delete(m, inst.ID) })
	}
}

func (b *Box) killInstance(inst dbInstance) {
	pidFile := filepath.Join(instanceRun(inst.ID), "mysqld.pid")
	if inst.Engine == engineRedis {
		pidFile = filepath.Join(instanceRun(inst.ID), "redis.pid")
	}
	if raw, err := os.ReadFile(pidFile); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil && pid > 1 {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	if b.Units != nil {
		b.Units.Remove(inst.Unit)
	}
}

// stopInstances stops a location's servers and keeps their data: the
// location is forgotten, not deleted.
func (b *Box) stopInstances(location string) {
	if b.Units == nil {
		return
	}
	for _, inst := range b.loadInstancesLocked() {
		if inst.Location == location {
			b.Units.Remove(inst.Unit)
		}
	}
}

func (b *Box) loadInstancesLocked() map[string]dbInstance {
	b.dbs.mu.Lock()
	defer b.dbs.mu.Unlock()
	return b.loadInstances()
}

// CollectInstances drops the servers of worktrees that went away while pierd
// was not looking (a folder removed by hand, pierd stopped halfway through a
// removal); pierd runs it as it starts.
func (b *Box) CollectInstances() {
	for _, inst := range b.loadInstancesLocked() {
		if _, err := os.Stat(inst.Path); errors.Is(err, fs.ErrNotExist) {
			b.dropInstances(inst.Path)
		}
	}
}

// instancePorts are the ports worktrees' servers listen on: not dev servers.
func (b *Box) instancePorts() map[int]bool {
	out := map[int]bool{}
	for _, inst := range b.loadInstancesLocked() {
		out[inst.Port] = true
	}
	return out
}

// instanceEnv is what everything run in a checkout with servers of its own
// gets: pierd's variables for them (vars), and the app's connection
// variables pointed at them (over), which win over the box's and the
// project's. Never a password.
func (b *Box) instanceEnv(path string) (vars, over map[string]string) {
	insts := b.instancesFor(path)
	if len(insts) == 0 {
		return nil, nil
	}
	vars, over = map[string]string{}, map[string]string{}
	for _, inst := range insts {
		port := strconv.Itoa(inst.Port)
		switch inst.Engine {
		case engineMySQL:
			sock := filepath.Join(instanceRun(inst.ID), "mysqld.sock")
			vars["PIER_DB_ENGINE"], vars["PIER_DB_HOST"], vars["PIER_DB_PORT"], vars["PIER_DB_SOCKET"] = engineMySQL, "127.0.0.1", port, sock
			over["DB_HOST"], over["DB_PORT"] = "127.0.0.1", port
			// A socket or a URL would take the app past host and port.
			over["DB_SOCKET"], over["DB_URL"], over["DATABASE_URL"] = "", "", ""
			// The mysql client in a worktree's shell reaches its own server.
			over["MYSQL_UNIX_PORT"], over["MYSQL_TCP_PORT"] = sock, port
		case engineRedis:
			vars["PIER_REDIS_PORT"] = port
			over["REDIS_HOST"], over["REDIS_PORT"], over["REDIS_URL"] = "127.0.0.1", port, ""
		}
	}
	return vars, over
}

// connectionKeys are the env-file keys a checkout's servers decide.
var connectionKeys = map[string]bool{
	"DB_HOST": true, "DB_PORT": true, "DB_SOCKET": true, "DB_URL": true, "DATABASE_URL": true, "MYSQL_ATTR_SSL_CA": true,
	"REDIS_HOST": true, "REDIS_PORT": true, "REDIS_URL": true,
}

// rewriteConnections points a checkout's env files (.env, .env.*) at its own
// servers: host and port, a socket, URL or TLS authority emptied so they
// cannot lead elsewhere, and the project's env keys that name pierd's
// variables ($PIER_DB_PORT). Never a database name, user or password: the
// test database of .env.testing stays the test database, in the worktree's
// own server. Laravel's cached config goes, so it reads them again. Says
// which keys it changed.
func (b *Box) rewriteConnections(ctx context.Context, loc Location, wt Worktree) []string {
	vars, over := b.instanceEnv(wt.Path)
	if len(over) == 0 {
		return nil
	}
	set := map[string]string{}
	always := map[string]bool{}
	if _, ok := vars["PIER_DB_PORT"]; ok {
		set["DB_HOST"], set["DB_PORT"] = "127.0.0.1", vars["PIER_DB_PORT"]
		always["DB_HOST"], always["DB_PORT"] = true, true
		for _, k := range []string{"DB_SOCKET", "DB_URL", "DATABASE_URL", "MYSQL_ATTR_SSL_CA"} {
			set[k] = ""
		}
	}
	if _, ok := vars["PIER_REDIS_PORT"]; ok {
		set["REDIS_HOST"], set["REDIS_PORT"], set["REDIS_URL"] = "127.0.0.1", vars["PIER_REDIS_PORT"], ""
		always["REDIS_HOST"], always["REDIS_PORT"] = true, true
	}
	if cfg, err := b.Locations.Config(ctx, loc.Name); err == nil {
		for k, v := range cfg.Effective.Env {
			if strings.Contains(v, "PIER_DB_") || strings.Contains(v, "PIER_REDIS_") {
				set[k] = expandPier(v, vars)
			}
		}
	}
	root, err := os.OpenRoot(wt.Path)
	if err != nil {
		return nil
	}
	defer root.Close()
	entries, _ := os.ReadDir(wt.Path)
	var changed []string
	for _, e := range entries {
		name := e.Name()
		if !isEnvFile(name) || name == ".env.example" || !e.Type().IsRegular() {
			continue
		}
		data, err := root.ReadFile(name)
		if err != nil {
			continue
		}
		f := parseEnvFile(data)
		touched := false
		keys := make([]string, 0, len(set))
		for k := range set {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if _, _, ok := f.get(k); !ok && !always[k] {
				continue
			}
			if f.set(k, set[k]) {
				touched = true
				changed = append(changed, name+": "+k)
			}
		}
		if touched {
			writeInRoot(root, name, f.bytes())
		}
	}
	if len(changed) > 0 {
		root.Remove(filepath.Join("bootstrap", "cache", "config.php"))
	}
	return changed
}

// The API.

// WorktreeDB answers GET …/worktrees/{wt}/db: the checkout's servers.
type WorktreeDB struct {
	Servers []ServerView `json:"servers"`
}

type ServerView struct {
	Engine   string     `json:"engine"`
	State    string     `json:"state"`
	Port     int        `json:"port"`
	Socket   string     `json:"socket,omitempty"`
	Unit     string     `json:"unit"`
	Snapshot string     `json:"snapshot,omitempty"`
	Layer    string     `json:"layer,omitempty"`
	Version  string     `json:"version,omitempty"`
	Created  *time.Time `json:"created,omitempty"`
	Error    string     `json:"error,omitempty"`
	Log      string     `json:"log,omitempty"`
}

func (b *Box) serverViews(path string) []ServerView {
	out := []ServerView{}
	for _, inst := range b.instancesFor(path) {
		v := ServerView{Engine: inst.Engine, State: inst.State, Port: inst.Port, Unit: inst.Unit, Snapshot: inst.Snapshot,
			Layer: inst.Layer, Version: inst.Version, Error: inst.Error}
		created := inst.Created
		v.Created = &created
		if inst.Engine == engineMySQL {
			v.Socket = filepath.Join(instanceRun(inst.ID), "mysqld.sock")
			v.Log = filepath.Join(b.instanceDir(inst.ID), "error.log")
		}
		if inst.State == "running" && b.Units != nil {
			if u, err := b.Units.Get(inst.Unit); err != nil || u.State != "running" {
				v.State = "stopped"
			}
		}
		out = append(out, v)
	}
	return out
}

// GET /v1/locations/{name}/worktrees/{worktree}/db
func (b *Box) getWorktreeDB(w http.ResponseWriter, r *http.Request) error {
	_, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	writeJSON(w, WorktreeDB{Servers: b.serverViews(wt.Path)})
	return nil
}

// PUT /v1/locations/{name}/worktrees/{worktree}/db {"from": "base"}: start the
// checkout's database over from the project's snapshot (or give one to a
// checkout that has none, the main checkout's): its servers go, and it is
// prepared again by script, which copies the snapshot afresh and runs the
// recipe (its pending migrations). 202 with the preparation; 409 while one
// runs.
func (b *Box) putWorktreeDB(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	var req struct {
		From string `json:"from"`
	}
	if err := decodeOptional(r, &req, 64<<10); err != nil {
		return err
	}
	if req.From != "" && req.From != "base" {
		return badRequest("from is base")
	}
	if engines, _ := b.wantedServers(r.Context(), loc); len(engines) == 0 {
		return httpError{http.StatusConflict, "the project's base gives its worktrees no servers: turn base.db or base.redis on first"}
	}
	if cur, ok := b.preps().get(prepKey(loc.Name, wt.Name)); ok && cur.State == "running" {
		return httpError{http.StatusConflict, "this worktree is being prepared"}
	}
	if err := b.before(r, "db.reset", map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path}); err != nil {
		return err
	}
	b.stopServices(loc.Name, wt.Name)
	b.dropInstances(wt.Path)
	b.reserveInstances(r.Context(), loc, wt)
	b.placeBaseFiles(r.Context(), loc, wt)
	if !b.beginPrepare(r, loc, wt, "script", false) {
		return httpError{http.StatusConflict, "this worktree is being prepared"}
	}
	b.publish(r, "worktree.db.reset", map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path})
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	writeJSON(w, b.prepareStatus(r.Context(), loc, wt))
	return nil
}

// DELETE /v1/locations/{name}/worktrees/{worktree}/db: end the checkout's
// servers and delete their data; it goes back to whatever its env says.
func (b *Box) deleteWorktreeDB(w http.ResponseWriter, r *http.Request) error {
	loc, wt, err := b.worktreeRef(r.Context(), r.PathValue("name"), r.PathValue("worktree"))
	if err != nil {
		return err
	}
	if err := b.before(r, "db.drop", map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path}); err != nil {
		return err
	}
	b.dropInstances(wt.Path)
	b.publish(r, "worktree.db.dropped", map[string]any{"location": loc.Name, "name": wt.Name, "path": wt.Path})
	writeJSON(w, WorktreeDB{Servers: b.serverViews(wt.Path)})
	return nil
}

// BaseDBView is the database part of GET …/base.
type BaseDBView struct {
	// Engine is the engine the base gives every worktree, "" for none.
	Engine string `json:"engine,omitempty"`
	Redis  bool   `json:"redis,omitempty"`
	// Server is the box's MySQL server, and how AppArmor stands for it.
	Server *DBServerView `json:"server,omitempty"`
	// Snapshot is the one new worktrees copy.
	Snapshot *SnapshotView `json:"snapshot,omitempty"`
	// Instances is how many worktrees of the project have servers.
	Instances int      `json:"instances"`
	Problems  []string `json:"problems,omitempty"`
}

type DBServerView struct {
	Program  string `json:"program,omitempty"`
	Version  string `json:"version,omitempty"`
	AppArmor string `json:"apparmor,omitempty"`
	Fix      string `json:"fix,omitempty"`
}

type SnapshotView struct {
	ID        string    `json:"id"`
	Created   time.Time `json:"created"`
	Version   string    `json:"version"`
	Databases []string  `json:"databases,omitempty"`
	Bytes     int64     `json:"bytes,omitempty"`
	Sanitized bool      `json:"sanitized"`
	Layer     string    `json:"layer"`
}

func (b *Box) baseDBView(ctx context.Context, loc Location, key string, cfg Config) *BaseDBView {
	if !dbSupported() {
		return nil
	}
	v := &BaseDBView{}
	if cfg.Effective.Base != nil {
		if cfg.Effective.Base.DB != nil {
			v.Engine = cfg.Effective.Base.DB.Engine
		}
		v.Redis = cfg.Effective.Base.Redis
	}
	if snap := b.currentSnapshot(key); snap != nil {
		m := snap.Manifest
		v.Snapshot = &SnapshotView{ID: m.ID, Created: m.Created, Version: m.Version, Databases: m.Databases, Bytes: m.Bytes, Sanitized: m.Sanitized, Layer: snap.Layer}
	}
	if v.Engine == "" && !v.Redis && v.Snapshot == nil {
		return nil
	}
	for _, inst := range b.loadInstancesLocked() {
		if inst.Location == loc.Name && inst.Engine == engineMySQL {
			v.Instances++
		}
	}
	if v.Engine != "" {
		srv := &DBServerView{Program: mysqlServer()}
		if srv.Program == "" {
			v.Problems = append(v.Problems, "this box has no MySQL server (mysqld)")
		} else if version, err := mysqldVersion(ctx, srv.Program); err == nil {
			srv.Version = version
			if v.Snapshot != nil && compareVersions(version, v.Snapshot.Version) < 0 {
				v.Problems = append(v.Problems, fmt.Sprintf("the snapshot was made with MySQL %s and this box's server is %s, older: it cannot start it", v.Snapshot.Version, version))
			}
		}
		srv.AppArmor = apparmorMySQL()
		if srv.AppArmor == "needs_rule" {
			srv.Fix = apparmorFix()
			v.Problems = append(v.Problems, "AppArmor keeps the box's MySQL server from the worktrees' databases until root allows them once")
		}
		v.Server = srv
		if v.Snapshot == nil {
			v.Problems = append(v.Problems, "no database snapshot yet: new worktrees cannot get their database")
		}
	}
	if v.Redis && redisServer() == "" {
		v.Problems = append(v.Problems, "this box has no Redis server (redis-server)")
	}
	return v
}

// SetLocalServers sets the box's own base.db and base.redis (PUT …/base).
func (l *Locations) SetLocalServers(name string, db *BaseDB, redis bool) error {
	return l.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			if all[i].Name != name {
				continue
			}
			c := RepoConfig{}
			if all[i].Config != nil {
				c = *all[i].Config
			}
			if c.Base == nil {
				c.Base = &BaseConfig{}
			}
			c.Base.DB, c.Base.Redis = db, redis
			if len(c.Base.Carry) == 0 && c.Base.DB == nil && !c.Base.Redis {
				c.Base = nil
			}
			all[i].Config = &c
			return all, nil
		}
		return nil, ErrUnknownLocation
	})
}

// dbChecks are pierd doctor's for the worktrees' own servers, on a box where
// a project's base asks for them.
func (b *Box) dbChecks(ctx context.Context) []doctor.Check {
	if !dbSupported() {
		return nil
	}
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return nil
	}
	mysql, redis := false, false
	for _, l := range locs {
		if cfg, err := b.Locations.Config(ctx, l.Name); err == nil && cfg.Effective.Base != nil {
			mysql = mysql || cfg.Effective.Base.DB != nil
			redis = redis || cfg.Effective.Base.Redis
		}
	}
	if !mysql && !redis {
		return nil
	}
	const area = "Worktree databases"
	var checks []doctor.Check
	if mysql {
		c := doctor.Check{Area: area, Name: "mysqld", Status: doctor.Fail, Detail: "not installed: worktrees cannot get their own database",
			Fix: "Install the MySQL server the project's snapshot was made with (sudo apt install mysql-server)"}
		if program := mysqlServer(); program != "" {
			if version, err := mysqldVersion(ctx, program); err == nil {
				c = doctor.Check{Area: area, Name: "mysqld", Status: doctor.OK, Detail: program + " " + version}
			}
		}
		checks = append(checks, c)
		switch apparmorMySQL() {
		case "needs_rule":
			checks = append(checks, doctor.Check{Area: area, Name: "AppArmor", Status: doctor.Fail,
				Detail: "the box's MySQL server may only use its own folders, not the worktrees' copies", Fix: apparmorFix()})
		case "ok":
			checks = append(checks, doctor.Check{Area: area, Name: "AppArmor", Status: doctor.OK, Detail: "the worktrees' folders are allowed"})
		}
		if nr, err1 := os.ReadFile("/proc/sys/fs/aio-nr"); err1 == nil {
			if mx, err2 := os.ReadFile("/proc/sys/fs/aio-max-nr"); err2 == nil {
				checks = append(checks, doctor.Check{Area: area, Name: "AIO", Status: doctor.Info,
					Detail: "worktrees' servers use no native AIO; the host uses " + strings.TrimSpace(string(nr)) + " of " + strings.TrimSpace(string(mx))})
			}
		}
	}
	if redis {
		c := doctor.Check{Area: area, Name: "redis-server", Status: doctor.Fail, Detail: "not installed: worktrees cannot get their own Redis", Fix: "sudo apt install redis-server"}
		if program := redisServer(); program != "" {
			c = doctor.Check{Area: area, Name: "redis-server", Status: doctor.OK, Detail: program}
		}
		checks = append(checks, c)
	}
	os.MkdirAll(b.dbRoot(), 0o700)
	if err := diskRoom(b.dbRoot()); err != nil {
		checks = append(checks, doctor.Check{Area: area, Name: "disk", Status: doctor.Warn, Detail: err.Error()})
	} else {
		checks = append(checks, doctor.Check{Area: area, Name: "disk", Status: doctor.OK, Detail: b.dbRoot() + kindNote(copyKind(b.dbRoot()))})
	}
	return checks
}

func kindNote(kind string) string {
	if kind == "reflink" {
		return " (copies share blocks: instant)"
	}
	return " (copies are whole: only with base.db.allow_copy)"
}
