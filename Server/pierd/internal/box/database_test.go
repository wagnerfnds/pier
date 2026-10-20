package box

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"pier/pierd/internal/events"
	"pier/pierd/internal/service"
)

// fakeDBServer is the mysqld or redis-server of these tests: this binary run
// again. Like the real ones it reads its config, listens where it says,
// greets a client (MySQL's protocol 10, Redis's +PONG), writes its pid, and
// shuts down cleanly on SIGTERM. FAKE_MYSQLD_DENY makes it stop the way a
// server AppArmor confines does.
func fakeDBServer(tool string, args []string) int {
	trace(tool, args)
	switch tool {
	case "mysql":
		return fakeMySQLClient(args)
	case "mysqldump":
		return fakeMySQLDump(args)
	}
	if len(args) == 1 && args[0] == "--version" {
		if tool == "redis-server" {
			fmt.Printf("Redis server v=%s sha=00000000:0 malloc=libc bits=64 build=fake\n", envOr("FAKE_REDIS_VERSION", "7.0.15"))
			return 0
		}
		fmt.Printf("%s  Ver %s for Linux on x86_64 (fake)\n", tool, envOr("FAKE_MYSQLD_VERSION", "8.0.46"))
		return 0
	}
	conf := map[string]string{}
	var path string
	if tool == "mysqld" {
		for _, a := range args {
			if v, ok := strings.CutPrefix(a, "--defaults-file="); ok {
				path = v
			}
		}
	} else if len(args) > 0 {
		path = args[0]
	}
	if raw, err := os.ReadFile(path); err == nil {
		for _, l := range strings.Split(string(raw), "\n") {
			l = strings.TrimSpace(l)
			if k, v, ok := strings.Cut(l, "="); ok && tool == "mysqld" {
				conf[k] = unquoteConf(v)
			} else if k, v, ok := strings.Cut(l, " "); ok && tool != "mysqld" {
				conf[k] = unquoteConf(v)
			}
		}
	}
	logf := func(format string, a ...any) {
		if p := conf["log-error"]; p != "" {
			f, _ := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
			fmt.Fprintf(f, format+"\n", a...)
			f.Close()
		}
	}
	if tool == "mysqld" && len(args) > 1 && args[1] == "--initialize-insecure" {
		os.MkdirAll(conf["datadir"], 0o750)
		os.WriteFile(filepath.Join(conf["datadir"], "mysql.ibd"), []byte("data dictionary"), 0o640)
		os.WriteFile(filepath.Join(conf["datadir"], "auto.cnf"), []byte("[auto]\nserver-uuid=x\n"), 0o640)
		return 0
	}
	if tool == "mysqld" {
		if os.Getenv("FAKE_MYSQLD_DENY") != "" {
			logf("[ERROR] [MY-012592] [InnoDB] Operating system error number 13 in a file operation. Errcode: 13 - Permission denied")
			return 1
		}
		if _, err := os.Stat(filepath.Join(conf["datadir"], "mysql.ibd")); err != nil {
			logf("[ERROR] no data dictionary in %s", conf["datadir"])
			return 1
		}
	}
	if p := os.Getenv("FAKE_CONF_LOG"); p != "" && tool == "mysqld" {
		f, _ := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		fmt.Fprintf(f, "%s innodb_strict_mode=%s\n", conf["datadir"], conf["innodb_strict_mode"])
		f.Close()
	}
	pidFile := conf["pid-file"]
	if tool != "mysqld" {
		pidFile = conf["pidfile"]
	}
	os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600)
	var lns []net.Listener
	if sock := conf["socket"]; sock != "" {
		ln, err := net.Listen("unix", sock)
		if err != nil {
			logf("[ERROR] socket %s: %v", sock, err)
			return 1
		}
		lns = append(lns, ln)
	}
	if port := conf["port"]; port != "" {
		ln, err := net.Listen("tcp", "127.0.0.1:"+port)
		if err != nil {
			logf("[ERROR] port %s: %v", port, err)
			return 1
		}
		lns = append(lns, ln)
	}
	// What the fake client needs to reach this server's data: where it is.
	if sock := conf["socket"]; sock != "" {
		info, _ := json.Marshal(map[string]any{"datadir": conf["datadir"], "pid": os.Getpid()})
		os.WriteFile(sock+".info", info, 0o600)
	}
	for _, l := range lns {
		go func(l net.Listener) {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				go func(c net.Conn) {
					defer c.Close()
					if tool == "mysqld" {
						body := append([]byte{10}, []byte("8.0.46-fake\x00")...)
						c.Write(append([]byte{byte(len(body)), 0, 0, 0}, body...))
						return
					}
					if line, _ := bufio.NewReader(c).ReadString('\n'); strings.HasPrefix(line, "PING") {
						c.Write([]byte("+PONG\r\n"))
					}
				}(c)
			}
		}(l)
	}
	logf("ready for connections")
	// Like MySQL's, it shuts down on SIGTERM alone: a terminal's Ctrl-C or
	// hang-up leaves it running.
	signal.Ignore(syscall.SIGINT, syscall.SIGHUP)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM)
	<-sig
	for _, l := range lns {
		l.Close()
	}
	logf("Shutdown complete")
	return 0
}

// unquoteConf reads a config value the way MySQL and Redis do: one in
// double quotes, escapes and all.
func unquoteConf(v string) string {
	if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
		if u, err := strconv.Unquote(v); err == nil {
			return u
		}
	}
	return v
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// fakeDBTools puts this test binary in as the box's mysqld and redis-server.
func fakeDBTools(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range []string{"mysqld", "redis-server"} {
		script := "#!/bin/sh\nFAKE_DB_SERVER=" + tool + " exec " + self + " \"$@\"\n"
		if err := os.WriteFile(filepath.Join(bin, tool), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	oldM, oldR, oldForce, oldFloor, oldShare, oldTimeout := mysqlServer, redisServer, dbForceSupported, dbFreeFloor, dbFreeShare, dbStartTimeout
	mysqlServer = func() string { return filepath.Join(bin, "mysqld") }
	redisServer = func() string { return filepath.Join(bin, "redis-server") }
	dbForceSupported, dbFreeFloor, dbFreeShare, dbStartTimeout = true, 0, 0, 20*time.Second
	t.Cleanup(func() {
		mysqlServer, redisServer, dbForceSupported, dbFreeFloor, dbFreeShare, dbStartTimeout = oldM, oldR, oldForce, oldFloor, oldShare, oldTimeout
	})
	// A socket's path is short on every system: the runtime folder is not
	// under the test's long temporary one.
	run, err := os.MkdirTemp("/tmp", "pdb")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_RUNTIME_DIR", run)
	t.Cleanup(func() { os.RemoveAll(run) })
}

// runningService is a service manager whose units really run their program,
// as systemd would: what the worktrees' servers need to be reached.
func runningService(t *testing.T) *serviceOps {
	t.Helper()
	var mu sync.Mutex
	specs := map[string]service.Spec{}
	procs := map[string]*exec.Cmd{}
	done := map[string]chan struct{}{}
	alive := func(name string) bool {
		ch, ok := done[name]
		if !ok {
			return false
		}
		select {
		case <-ch:
			return false
		default:
			return true
		}
	}
	stop := func(name string) {
		cmd, ok := procs[name]
		if !ok || !alive(name) {
			return
		}
		cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done[name]:
		case <-time.After(5 * time.Second):
			cmd.Process.Kill()
			<-done[name]
		}
	}
	t.Cleanup(func() {
		mu.Lock()
		defer mu.Unlock()
		for name := range procs {
			stop(name)
		}
	})
	return &serviceOps{
		install: func(s service.Spec) (string, error) {
			mu.Lock()
			defer mu.Unlock()
			stop(s.Name)
			specs[s.Name] = s
			return "/fake/" + s.Name, nil
		},
		start: func(s service.Spec) error {
			mu.Lock()
			defer mu.Unlock()
			if alive(s.Name) {
				return nil
			}
			spec, ok := specs[s.Name]
			if !ok {
				return fmt.Errorf("no unit %s", s.Name)
			}
			cmd := exec.Command(spec.Program, spec.Args...)
			cmd.Env = os.Environ()
			for k, v := range spec.Env {
				cmd.Env = append(cmd.Env, k+"="+v)
			}
			if err := cmd.Start(); err != nil {
				return err
			}
			ch := make(chan struct{})
			go func() { cmd.Wait(); close(ch) }()
			procs[s.Name], done[s.Name] = cmd, ch
			return nil
		},
		uninstall: func(s service.Spec) (string, error) {
			mu.Lock()
			defer mu.Unlock()
			stop(s.Name)
			delete(specs, s.Name)
			return "/fake/" + s.Name, nil
		},
		installed: func(s service.Spec) bool {
			mu.Lock()
			defer mu.Unlock()
			have, ok := specs[s.Name]
			return ok && reflect.DeepEqual(have, s)
		},
		installedByName: func(name string) bool {
			mu.Lock()
			defer mu.Unlock()
			_, ok := specs[name]
			return ok
		},
		running: func(s service.Spec) bool {
			mu.Lock()
			defer mu.Unlock()
			return alive(s.Name)
		},
	}
}

// snapshotFor makes the box's own snapshot for a project: a datadir with
// what a cleanly shut down server leaves, including what a copy must lose.
func snapshotFor(t *testing.T, bx *Box, key, version string) string {
	t.Helper()
	dir := filepath.Join(bx.dbRoot(), "base", key)
	gen := filepath.Join(dir, "gen", "20261020-100000")
	data := filepath.Join(gen, "data")
	for _, p := range []string{"mysql.ibd", "ibdata1", "undo_001", "auto.cnf", "ib_buffer_pool", "server-key.pem", "shop/orders.ibd"} {
		os.MkdirAll(filepath.Dir(filepath.Join(data, p)), 0o750)
		os.WriteFile(filepath.Join(data, p), []byte("page of "+p), 0o640)
	}
	m := snapshotManifest{ID: "20261020-100000", Engine: "mysql", Version: version, Databases: []string{"shop", "shop_test"},
		Created: time.Now().UTC().Truncate(time.Second), Sanitized: true}
	raw, _ := json.Marshal(m)
	os.WriteFile(filepath.Join(gen, "manifest.json"), raw, 0o600)
	os.Symlink(filepath.Join("gen", "20261020-100000"), filepath.Join(dir, "current"))
	return data
}

// dbBox is a box whose units run, with this test binary as its servers, and
// the project cal (baseRepo) with a .env and .env.testing in its base.
func dbBox(t *testing.T) (*Box, func(method, path string, body, out any) int, <-chan events.Event, string) {
	t.Helper()
	t.Setenv("SHELL", "/bin/sh")
	fakeDBTools(t)
	repo := baseRepo(t)
	os.WriteFile(filepath.Join(repo, ".env"), []byte("APP_KEY=base64:x\nDB_HOST=localhost\nDB_PORT=3306\nDB_DATABASE=shop\nDB_USERNAME=app\nDB_PASSWORD=s3cret\nDB_SOCKET=/var/run/mysqld/mysqld.sock\nREDIS_HOST=127.0.0.1\nREDIS_PORT=6379\n"), 0o644)
	os.WriteFile(filepath.Join(repo, ".env.testing"), []byte("DB_HOST=localhost\nDB_DATABASE=shop_test\n"), 0o644)
	var bx *Box
	c, bus := servedBox(t, func(b *Box) {
		b.LogDir, b.StateDir, b.DBDir = t.TempDir(), t.TempDir(), t.TempDir()
		b.Units.svc = runningService(t)
		bx = b
	})
	ch, stop := bus.Subscribe()
	t.Cleanup(stop)
	do := func(method, path string, body, out any) int { return call(t, c, method, path, "", body, out) }
	if do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil) != 200 {
		t.Fatal("add location")
	}
	for _, p := range []string{".env", ".env.testing"} {
		if code := do("POST", "/v1/locations/cal/base/files", map[string]string{"path": p}, nil); code != 200 {
			t.Fatalf("add %s = %d", p, code)
		}
	}
	return bx, do, ch, repo
}

func envOf(t *testing.T, path string) map[string]string {
	t.Helper()
	f := parseEnvFile([]byte(readFile(t, path)))
	out := map[string]string{}
	for _, k := range f.keys() {
		out[k], _, _ = f.get(k)
	}
	return out
}

// A new worktree of a project whose base has a database gets a MySQL server
// of its own on a copy of the snapshot and an empty Redis, on the last two
// ports of its block: its .env and its environment point at them, the test
// database stays the test database, and the servers go with the worktree.
func TestAWorktreeGetsItsOwnDatabaseCopiedFromTheSnapshot(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	var view BaseView
	if code := do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}, "redis": true}, &view); code != 200 {
		t.Fatalf("turning servers on = %d", code)
	}
	if view.DB == nil || view.DB.Engine != "mysql" || !view.DB.Redis || view.DB.Snapshot == nil || !view.DB.Snapshot.Sanitized {
		t.Fatalf("base's db = %+v", view.DB)
	}
	bx.Locations.MergeLocalConfig("cal", RepoConfig{Setup: `echo "$DB_HOST:$DB_PORT:$REDIS_PORT:$PIER_DB_PORT:$DB_SOCKET:$PIER_PORT_9" > seen.txt`})
	var wt Worktree
	if code := do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "feature"}, &wt); code != 200 {
		t.Fatalf("create = %d", code)
	}
	waitFor(t, events, "worktree.prepare.finished")
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/feature/prepare", nil, &st)
	if st.State != "ready" || st.Base == nil || len(st.Base.Servers) != 2 {
		t.Fatalf("prepare = %+v (base %+v)", st, st.Base)
	}
	if !slicesContains(st.Base.Connections, ".env: DB_PORT") || !slicesContains(st.Base.Connections, ".env.testing: DB_HOST") {
		t.Fatalf("the preparation lost what it pointed at the servers: %v", st.Base.Connections)
	}
	dbPort, redisPort := wt.Port+mysqlPortOffset, wt.Port+redisPortOffset
	if got := strings.TrimSpace(readFile(t, filepath.Join(wt.Path, "seen.txt"))); got != fmt.Sprintf("127.0.0.1:%d:%d:%d::", dbPort, redisPort, dbPort) {
		t.Fatalf("the recipe saw %q", got)
	}
	env := envOf(t, filepath.Join(wt.Path, ".env"))
	if env["DB_HOST"] != "127.0.0.1" || env["DB_PORT"] != strconv.Itoa(dbPort) || env["DB_SOCKET"] != "" || env["REDIS_PORT"] != strconv.Itoa(redisPort) ||
		env["DB_DATABASE"] != "shop" || env["DB_PASSWORD"] != "s3cret" {
		t.Fatalf(".env = %v", env)
	}
	testEnv := envOf(t, filepath.Join(wt.Path, ".env.testing"))
	if testEnv["DB_DATABASE"] != "shop_test" || testEnv["DB_HOST"] != "127.0.0.1" || testEnv["DB_PORT"] != strconv.Itoa(dbPort) {
		t.Fatalf(".env.testing = %v", testEnv)
	}
	insts := bx.instancesFor(wt.Path)
	if len(insts) != 2 || insts[0].Engine != engineMySQL || insts[0].State != "running" || insts[0].Snapshot != "20261020-100000" {
		t.Fatalf("instances = %+v", insts)
	}
	data := filepath.Join(bx.instanceDir(insts[0].ID), "data")
	for _, gone := range []string{"auto.cnf", "ib_buffer_pool", "server-key.pem"} {
		if _, err := os.Stat(filepath.Join(data, gone)); err == nil {
			t.Errorf("the copy kept %s", gone)
		}
	}
	if info, err := os.Stat(filepath.Join(data, "shop", "orders.ibd")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the copy's table: %v %v", info, err)
	}
	cnf := readFile(t, filepath.Join(bx.instanceDir(insts[0].ID), "my.cnf"))
	for _, want := range []string{"port=" + strconv.Itoa(dbPort), "bind-address=127.0.0.1", "mysqlx=OFF", "secure-file-priv=NULL", "innodb_use_native_aio=OFF", "skip-log-bin"} {
		if !strings.Contains(cnf, want) {
			t.Errorf("my.cnf lacks %s", want)
		}
	}
	// The app's services list the servers; the box's dev servers leave them out.
	var svcs []ServiceStatus
	do("GET", "/v1/locations/cal/worktrees/feature/services", nil, &svcs)
	kinds := map[string]string{}
	for _, s := range svcs {
		kinds[s.Name] = s.Kind + ":" + s.State
	}
	if kinds["db"] != "mysql:running" || kinds["redis"] != "redis:running" {
		t.Fatalf("services = %+v", svcs)
	}
	var running []Service
	do("GET", "/v1/services", nil, &running)
	for _, s := range running {
		if s.Port == dbPort || s.Port == redisPort {
			t.Fatalf("a worktree's own server reads as a dev server: %+v", s)
		}
	}
	// Its environment, as a terminal or an agent there gets it.
	full, _ := bx.WorktreeEnv(context.Background(), "cal", wt)
	got := map[string]string{}
	for _, kv := range full {
		k, v, _ := strings.Cut(kv, "=")
		got[k] = v
	}
	if got["DB_PORT"] != strconv.Itoa(dbPort) || got["MYSQL_TCP_PORT"] != strconv.Itoa(dbPort) || got["DB_PASSWORD"] != "" {
		t.Fatalf("env = %v", got)
	}
	// Removing the worktree takes its servers and their data with it.
	if code := do("DELETE", "/v1/locations/cal/worktrees/feature?force=1", nil, nil); code != 200 {
		t.Fatalf("remove = %d", code)
	}
	if len(bx.instancesFor(wt.Path)) != 0 {
		t.Fatal("the servers outlived their worktree")
	}
	if _, err := os.Stat(bx.instanceDir(insts[0].ID)); err == nil {
		t.Fatal("the database's copy outlived its worktree")
	}
	if err := portFree(dbPort); err != nil {
		t.Fatalf("the database still listens: %v", err)
	}
}

// Starting a worktree's database over copies the snapshot afresh and
// prepares it again, its recipe and all.
func TestAWorktreesDatabaseStartsOverFromTheSnapshot(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "dirty"}, &wt)
	waitFor(t, events, "worktree.prepare.finished")
	inst := bx.instancesFor(wt.Path)[0]
	os.WriteFile(filepath.Join(bx.instanceDir(inst.ID), "data", "shop", "scratch.ibd"), []byte("a test's table"), 0o600)
	var st PrepareStatus
	if code := do("PUT", "/v1/locations/cal/worktrees/dirty/db", map[string]string{"from": "base"}, &st); code != 202 || st.State != "running" {
		t.Fatalf("reset = %d %+v", code, st)
	}
	waitFor(t, events, "worktree.prepare.finished")
	again := bx.instancesFor(wt.Path)
	if len(again) != 1 || again[0].ID == inst.ID || again[0].State != "running" {
		t.Fatalf("after the reset = %+v", again)
	}
	if _, err := os.Stat(filepath.Join(bx.instanceDir(again[0].ID), "data", "shop", "scratch.ibd")); err == nil {
		t.Fatal("the reset kept what the worktree wrote")
	}
	if _, err := os.Stat(bx.instanceDir(inst.ID)); err == nil {
		t.Fatal("the old copy is still there")
	}
}

// A new worktree waits for nothing it cannot have: with no snapshot, its
// preparation fails and says how to make one.
func TestAWorktreeWithoutASnapshotSaysHowToMakeOne(t *testing.T) {
	_, do, events, _ := dbBox(t)
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql"}}, nil)
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "early"}, nil)
	waitFor(t, events, "worktree.prepare.failed")
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/early/prepare", nil, &st)
	if st.State != "failed" || !strings.Contains(st.Error, "pierd team base") {
		t.Fatalf("prepare = %+v", st)
	}
}

// An older server cannot start a newer one's data: the copy is refused and
// says both versions.
func TestAnOlderServerRefusesANewerSnapshot(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.4.2")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "old"}, nil)
	waitFor(t, events, "worktree.prepare.failed")
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/old/prepare", nil, &st)
	if !strings.Contains(st.Error, "8.4.2") || !strings.Contains(st.Error, "8.0.46") {
		t.Fatalf("prepare = %+v", st)
	}
}

// AppArmor keeping the box's MySQL server from its files reads as what root
// does once, with the lines to add.
func TestAServerAppArmorStoppedSaysWhatRootDoesOnce(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	aa := t.TempDir()
	os.WriteFile(filepath.Join(aa, "enabled"), []byte("Y\n"), 0o644)
	os.WriteFile(filepath.Join(aa, "profile"), []byte("/usr/sbin/mysqld {}\n"), 0o644)
	oldE, oldP, oldL := apparmorEnabled, apparmorProfile, apparmorLocal
	apparmorEnabled, apparmorProfile, apparmorLocal = filepath.Join(aa, "enabled"), filepath.Join(aa, "profile"), filepath.Join(aa, "local")
	t.Cleanup(func() { apparmorEnabled, apparmorProfile, apparmorLocal = oldE, oldP, oldL })
	t.Setenv("FAKE_MYSQLD_DENY", "1")
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "confined"}, nil)
	waitFor(t, events, "worktree.prepare.failed")
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/confined/prepare", nil, &st)
	if !strings.Contains(st.Error, "AppArmor") || !strings.Contains(st.Error, "owner @{HOME}/.local/share/pier/db/** rwk,") {
		t.Fatalf("prepare = %+v", st.Error)
	}
	var view BaseView
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.DB == nil || view.DB.Server == nil || view.DB.Server.AppArmor != "needs_rule" || view.DB.Server.Fix == "" {
		t.Fatalf("base's db = %+v", view.DB)
	}
	os.WriteFile(apparmorLocal, []byte(AppArmorRule()), 0o644)
	if apparmorMySQL() != "ok" {
		t.Fatal("the rule did not count")
	}
}

// Only the team and the box itself give worktrees servers: a repository's
// file or a recipe a setup agent saves cannot.
func TestOnlyTheTeamOrTheBoxGiveWorktreesServers(t *testing.T) {
	repo := baseRepo(t)
	writeRepoConfig(t, repo, RepoConfig{Setup: "true", Base: &BaseConfig{Carry: []string{"vendor"}, DB: &BaseDB{Engine: "mysql"}, Redis: true}})
	l := NewLocations(filepath.Join(t.TempDir(), "locations.json"))
	ctx := context.Background()
	l.Add(ctx, "cal", repo)
	trustRepo(t, l, "cal")
	cfg, _ := l.Config(ctx, "cal")
	if b := cfg.Effective.Base; b == nil || len(b.Carry) != 1 || b.DB != nil || b.Redis {
		t.Fatalf("a repository's base = %+v", cfg.Effective.Base)
	}
	l.MergeLocalConfig("cal", RepoConfig{Setup: "make", Base: &BaseConfig{DB: &BaseDB{Engine: "mysql"}, Redis: true}, By: "setup"})
	if cfg, _ := l.Config(ctx, "cal"); cfg.Effective.Base.DB != nil || cfg.Effective.Base.Redis {
		t.Fatalf("a recipe turned servers on: %+v", cfg.Effective.Base)
	}
	l.SetTeam("cal", &RepoConfig{Base: &BaseConfig{DB: &BaseDB{Engine: "mysql"}}}, nil)
	if cfg, _ := l.Config(ctx, "cal"); cfg.Effective.Base.DB == nil {
		t.Fatal("the team's database did not apply")
	}
}

// The worktrees' servers take the last two of a worktree's ten ports: a
// project that asks for them all cannot have servers too.
func TestServersNeedTheLastTwoPortsOfTheBlock(t *testing.T) {
	bx, do, _, repo := dbBox(t)
	writeRepoConfig(t, repo, RepoConfig{Ports: 10})
	trustRepo(t, bx.Locations, "cal")
	if code := do("PUT", "/v1/locations/cal/base", map[string]any{"redis": true}, nil); code != 400 {
		t.Fatalf("servers for a project using every port = %d", code)
	}
}

func TestAProjectSetsOnlyTheServerOptionsItMay(t *testing.T) {
	if err := validateMySQLOptions(map[string]string{"sql_mode": "STRICT_TRANS_TABLES,NO_ZERO_DATE", "max-connections": "200"}); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []map[string]string{{"init_file": "/tmp/x.sql"}, {"plugin_load_add": "x.so"}, {"sql_mode": "A;B\n[client]"}} {
		if validateMySQLOptions(bad) == nil {
			t.Errorf("%v was taken", bad)
		}
	}
	cnf := string(mysqlConfig("/d", "/r", 41009, "8.0.46", snapshotManifest{}, map[string]string{"innodb_buffer_pool_size": "1G"}))
	if strings.Contains(cnf, "innodb_buffer_pool_size=256M") || !strings.Contains(cnf, "innodb_buffer_pool_size=1G") {
		t.Fatalf("the project's buffer pool did not replace pierd's default:\n%s", cnf)
	}
	if strings.Contains(string(mysqlConfig("/d", "/r", 1, "8.0.28", snapshotManifest{}, nil)), "innodb_redo_log_capacity") {
		t.Fatal("an 8.0.28 server would not start with innodb_redo_log_capacity")
	}
}

// A copy where the disk cannot share blocks is refused unless allowed: it
// would be as big as the snapshot.
func TestAFullCopyOfASnapshotIsOnlyMadeWhenAllowed(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	old := cloneTree
	cloneTree = func(ctx context.Context, src, dst string, always bool) error {
		if always {
			return fmt.Errorf("cp: failed to clone %s: Operation not supported", dst)
		}
		return old(ctx, src, dst, always)
	}
	t.Cleanup(func() { cloneTree = old })
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql"}}, nil)
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "ext4"}, nil)
	waitFor(t, events, "worktree.prepare.failed")
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/ext4/prepare", nil, &st)
	if !strings.Contains(st.Error, "allow_copy") {
		t.Fatalf("prepare = %+v", st.Error)
	}
}

// A worktree's servers whose worktree went away while pierd was not looking
// are collected as it starts.
func TestServersOfAWorktreeThatWentAreCollected(t *testing.T) {
	bx, _, _, _ := dbBox(t)
	gone := filepath.Join(t.TempDir(), "cal-gone")
	id := "abcdef012345"
	os.MkdirAll(filepath.Join(bx.instanceDir(id), "data"), 0o700)
	bx.updateInstances(func(m map[string]dbInstance) {
		m[id] = dbInstance{ID: id, Engine: engineMySQL, Location: "cal", Worktree: "gone", Path: gone, Unit: "db-cal-gone-abcdef", State: "running"}
	})
	bx.CollectInstances()
	if len(bx.instancesFor(gone)) != 0 {
		t.Fatal("the record stayed")
	}
	if _, err := os.Stat(bx.instanceDir(id)); err == nil {
		t.Fatal("the data stayed")
	}
}

// Turning a base's servers on never moves a worktree that already exists
// off its database: preparing it again leaves it as it was, until someone
// asks for the base's (PUT …/db).
func TestAnExistingWorktreeKeepsItsDatabaseUntilAsked(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "older"}, &wt)
	waitFor(t, events, "worktree.prepare.finished")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	do("POST", "/v1/locations/cal/worktrees/older/prepare", nil, nil)
	waitFor(t, events, "worktree.prepare.finished")
	if n := len(bx.instancesFor(wt.Path)); n != 0 {
		t.Fatalf("preparing an existing worktree again gave it %d servers", n)
	}
	if env := envOf(t, filepath.Join(wt.Path, ".env")); env["DB_PORT"] != "3306" {
		t.Fatalf("its .env moved: %v", env)
	}
	if code := do("PUT", "/v1/locations/cal/worktrees/older/db", map[string]string{"from": "base"}, nil); code != 202 {
		t.Fatalf("asking for the base's database = %d", code)
	}
	waitFor(t, events, "worktree.prepare.finished")
	if insts := bx.instancesFor(wt.Path); len(insts) != 1 || insts[0].State != "running" {
		t.Fatalf("after asking = %+v", insts)
	}
}

// A worktree's Redis asks for a password of its own, which its env files and
// environment carry, and nothing that reaches it can change where it writes
// or load code: Redis 7 has settings for that, an older one the commands
// renamed away.
func TestAWorktreesRedisIsItsOwnAlone(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	do("PUT", "/v1/locations/cal/base", map[string]any{"redis": true}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "queue"}, &wt)
	waitFor(t, events, "worktree.prepare.finished")
	insts := bx.instancesFor(wt.Path)
	if len(insts) != 1 || insts[0].Secret == "" {
		t.Fatalf("instances = %+v", insts)
	}
	secret := insts[0].Secret
	conf := readFile(t, filepath.Join(bx.instanceDir(insts[0].ID), "redis.conf"))
	for _, want := range []string{`requirepass "` + secret + `"`, "enable-protected-configs no", "enable-module-command no", "enable-debug-command no", "bind 127.0.0.1"} {
		if !strings.Contains(conf, want) {
			t.Errorf("redis.conf lacks %s:\n%s", want, conf)
		}
	}
	if env := envOf(t, filepath.Join(wt.Path, ".env")); env["REDIS_PASSWORD"] != secret || env["REDIS_PORT"] != strconv.Itoa(insts[0].Port) {
		t.Fatalf(".env = %v", env)
	}
	full, _ := bx.WorktreeEnv(context.Background(), "cal", wt)
	if !slicesContains(full, "REDIS_PASSWORD="+secret) {
		t.Fatalf("env = %v", full)
	}
	var db WorktreeDB
	do("GET", "/v1/locations/cal/worktrees/queue/db", nil, &db)
	if raw, _ := json.Marshal(db); strings.Contains(string(raw), secret) {
		t.Fatalf("GET …/db shows the password: %s", raw)
	}
	old := string(redisConfig("/d", "/r", 41008, `pa"ss\word`, "6.0.16"))
	for _, want := range []string{`rename-command CONFIG ""`, `rename-command MODULE ""`, `rename-command DEBUG ""`, `requirepass "pa\"ss\\word"`} {
		if !strings.Contains(old, want) {
			t.Errorf("Redis 6's config lacks %s:\n%s", want, old)
		}
	}
	if strings.Contains(old, "enable-protected-configs") {
		t.Error("Redis 6 would refuse a setting it does not know")
	}
}

func slicesContains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// The box's and the project's database names, users and passwords were set
// for another server: a worktree with its own takes those from its env
// files, whose users its server has.
func TestAWorktreesOwnServersTakeTheirUsersFromItsEnvFiles(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	bx.EnvFile = filepath.Join(t.TempDir(), "env.json")
	os.WriteFile(bx.EnvFile, []byte(`{"env": {"DB_USERNAME": "root", "DB_PASSWORD": "system", "REDIS_PASSWORD": "shared", "MYSQL_PWD": "system", "APP_DEBUG": "true"}}`), 0o600)
	bx.Locations.MergeLocalConfig("cal", RepoConfig{Env: map[string]string{"DB_DATABASE": "cal_$PIER_WORKTREE_SLUG"}})
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}, "redis": true}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "own"}, &wt)
	waitFor(t, events, "worktree.prepare.finished")
	full, _ := bx.WorktreeEnv(context.Background(), "cal", wt)
	got := map[string]string{}
	for _, kv := range full {
		k, v, _ := strings.Cut(kv, "=")
		got[k] = v
	}
	for _, k := range []string{"DB_USERNAME", "DB_PASSWORD", "DB_DATABASE", "MYSQL_PWD"} {
		if v, ok := got[k]; ok {
			t.Errorf("%s=%s reaches a worktree with its own server", k, v)
		}
	}
	if got["REDIS_PASSWORD"] == "shared" || got["REDIS_PASSWORD"] == "" || got["APP_DEBUG"] != "true" {
		t.Fatalf("env = %v", got)
	}
	// A worktree without servers keeps them.
	plain, _ := bx.WorktreeEnv(context.Background(), "cal", Worktree{Name: "plain", Path: filepath.Join(t.TempDir(), "cal-plain")})
	if !slicesContains(plain, "DB_USERNAME=root") {
		t.Fatalf("a worktree without servers lost the box's user: %v", plain)
	}
}

// An env file the repository tracks (.env.ci) is never rewritten: a commit
// would take this worktree's ports.
func TestTrackedEnvFilesStayAsTheRepositoryHasThem(t *testing.T) {
	bx, do, events, repo := dbBox(t)
	ci := "DB_HOST=127.0.0.1\nDB_PORT=3306\nREDIS_PORT=6379\n"
	os.WriteFile(filepath.Join(repo, ".env.ci"), []byte(ci), 0o644)
	for _, args := range [][]string{{"add", ".env.ci"}, {"commit", "-q", "-m", "ci env"}} {
		if out, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
	}
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}, "redis": true}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "ci"}, &wt)
	waitFor(t, events, "worktree.prepare.finished")
	if got := readFile(t, filepath.Join(wt.Path, ".env.ci")); got != ci {
		t.Fatalf(".env.ci = %q", got)
	}
	if out, _ := exec.Command("git", "-C", wt.Path, "status", "--porcelain").CombinedOutput(); len(strings.TrimSpace(string(out))) > 0 {
		t.Fatalf("the worktree has changes to commit: %s", out)
	}
}

// Reservations at once (a worktree made while it is prepared again) give a
// checkout one server of each.
func TestReservationsAtOnceGiveOneServerOfEach(t *testing.T) {
	bx, do, _, repo := dbBox(t)
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql"}, "redis": true}, nil)
	loc, _ := bx.Locations.Get(context.Background(), "cal")
	wt := Worktree{Name: "cal", Path: repo, Main: true}
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			bx.reserveInstances(context.Background(), loc, wt)
		}()
	}
	wg.Wait()
	if insts := bx.instancesFor(repo); len(insts) != 2 || insts[0].Engine == insts[1].Engine {
		t.Fatalf("instances = %+v", insts)
	}
}

// A worktree removed while its database is being copied leaves nothing
// behind: the copy stops, no server starts, its port is free.
func TestAWorktreeRemovedWhileItsDatabaseComesUpLeavesNothingRunning(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	copying, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	old := cloneTree
	cloneTree = func(ctx context.Context, src, dst string, always bool) error {
		if strings.HasSuffix(dst, filepath.Join(".tmp", "data")) {
			once.Do(func() { close(copying) })
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-release:
			}
		}
		return old(ctx, src, dst, always)
	}
	t.Cleanup(func() { cloneTree = old })
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "brief"}, &wt)
	select {
	case <-copying:
	case <-time.After(20 * time.Second):
		t.Fatal("the copy never started")
	}
	inst := bx.instancesFor(wt.Path)[0]
	if code := do("DELETE", "/v1/locations/cal/worktrees/brief?force=1", nil, nil); code != 200 {
		t.Fatalf("remove = %d", code)
	}
	close(release)
	deadline := time.Now().Add(10 * time.Second)
	for {
		_, starting := bx.dbs.cancels.Load(inst.ID)
		if !starting {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the bring-up never ended")
		}
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond)
	if _, ok := bx.loadInstancesLocked()[inst.ID]; ok {
		t.Fatal("the record came back")
	}
	if _, err := os.Stat(bx.instanceDir(inst.ID)); err == nil {
		t.Fatal("the copy came back")
	}
	if err := portFree(inst.Port); err != nil {
		t.Fatalf("a server listens for a removed worktree: %v", err)
	}
	if u, err := bx.Units.Get(inst.Unit); err == nil && u.State == "running" {
		t.Fatalf("its unit runs: %+v", u)
	}
	select {
	case e := <-events:
		if e.Type == "worktree.prepare.finished" {
			t.Fatalf("a removed worktree's preparation finished: %+v", e)
		}
	default:
	}
}

// A worktree's archive script runs with its own database still up: only its
// recipe's services stop first.
func TestAnArchiveScriptStillReachesTheWorktreesDatabase(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "archived"}, &wt)
	waitFor(t, events, "worktree.prepare.finished")
	inst := bx.instancesFor(wt.Path)[0]
	bx.stopServices("cal", "archived")
	if u, err := bx.Units.Get(inst.Unit); err != nil || u.State != "running" {
		t.Fatalf("the database stopped before the archive script: %+v %v", u, err)
	}
}

// A copy starts from the snapshot root published last, even one the box's
// copy of the team's base has not seen yet (the one it knew pruned).
func TestStartingOverCopiesTheTeamsLatestSnapshot(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	ctx := context.Background()
	key, _ := bx.Locations.BaseKey(ctx, "cal")
	team, publish := useTeam(t)
	publishDB := func(id string) {
		// publish starts the project's folder over: the older snapshot is
		// kept aside and put back, as root's prune would leave it.
		gens := filepath.Join(team, "projects", key, "db", "gen")
		kept := filepath.Join(t.TempDir(), "gen")
		os.Rename(gens, kept)
		publish(key, nil, `{"base": {"db": {"engine": "mysql", "allow_copy": true}}}`)
		os.MkdirAll(filepath.Dir(gens), 0o750)
		os.Rename(kept, gens)
		data := filepath.Join(gens, id, "data")
		for _, p := range []string{"mysql.ibd", "shop/orders.ibd"} {
			os.MkdirAll(filepath.Dir(filepath.Join(data, p)), 0o750)
			os.WriteFile(filepath.Join(data, p), []byte(id), 0o640)
		}
		pubPath := filepath.Join(team, "projects", key, "published.json")
		var pub teamPublished
		loadJSON(pubPath, &pub)
		pub.DB = &teamSnapshot{ID: id, Manifest: snapshotManifest{ID: id, Engine: "mysql", Version: "8.0.46", Created: time.Now().UTC(), Sanitized: true}}
		raw, _ := json.Marshal(pub)
		os.WriteFile(pubPath, raw, 0o640)
	}
	publishDB("gen-a")
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "fresh"}, &wt)
	if e := waitForEither(t, events, "worktree.prepare.finished", "worktree.prepare.failed"); e.Type != "worktree.prepare.finished" {
		t.Fatalf("prepare failed: %s", e.Error)
	}
	if insts := bx.instancesFor(wt.Path); len(insts) != 1 || insts[0].Snapshot != "gen-a" {
		t.Fatalf("first copy = %+v", insts)
	}
	// Root imports again and prunes the old one, a moment later.
	os.RemoveAll(filepath.Join(team, "projects", key, "db", "gen", "gen-a"))
	publishDB("gen-b")
	if code := do("PUT", "/v1/locations/cal/worktrees/fresh/db", map[string]string{"from": "base"}, nil); code != 202 {
		t.Fatalf("reset = %d", code)
	}
	waitFor(t, events, "worktree.prepare.finished")
	if insts := bx.instancesFor(wt.Path); len(insts) != 1 || insts[0].Snapshot != "gen-b" {
		t.Fatalf("after the reset = %+v", insts)
	}
}

// Purging a project with its base keeps a base another project of the box
// (a second clone of the repository) shares.
func TestPurgingWithTheBaseKeepsOneAnotherProjectShares(t *testing.T) {
	repo := baseRepo(t)
	other := filepath.Join(filepath.Dir(repo), "cal-two")
	for _, args := range [][]string{
		{"-C", repo, "remote", "add", "origin", "https://github.com/acme/cal.git"},
		{"clone", "-q", repo, other},
		{"-C", other, "remote", "set-url", "origin", "https://github.com/acme/cal.git"},
	} {
		if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
	}
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	do("POST", "/v1/locations", map[string]string{"name": "two", "path": other}, nil)
	do("POST", "/v1/locations/cal/base/files", map[string]string{"path": ".env"}, nil)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	if code := do("DELETE", "/v1/locations/two?purge=1&base=1&force=1", nil, nil); code != 200 {
		t.Fatalf("purge = %d", code)
	}
	if _, err := os.Stat(filepath.Join(bx.baseDir(key), "base.json")); err != nil {
		t.Fatalf("the shared base went: %v", err)
	}
}

// waitForEither is waitFor for whichever of two events comes first.
func waitForEither(t *testing.T, ch <-chan events.Event, one, other string) events.Event {
	t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case e := <-ch:
			if e.Type == one || e.Type == other {
				return e
			}
		case <-deadline:
			t.Fatalf("saw neither %s nor %s", one, other)
		}
	}
}

// Worktrees on a copy of real data get no public link by themselves.
func TestRealDataGetsNoPublicLinkByItself(t *testing.T) {
	bx, do, _, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	data := snapshotFor(t, bx, key, "8.0.46")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql"}}, nil)
	if !bx.autoShareFor(context.Background(), "cal") {
		t.Fatal("an anonymized snapshot's worktrees lost their links")
	}
	var m snapshotManifest
	loadJSON(filepath.Join(filepath.Dir(data), "manifest.json"), &m)
	m.Sanitized = false
	saveJSON(filepath.Join(filepath.Dir(data), "manifest.json"), m)
	if bx.autoShareFor(context.Background(), "cal") {
		t.Fatal("worktrees on real data get public links by themselves")
	}
}

// A checkout without servers of its own in a project whose base gives them
// (one from before the base, one made with only its code) gets none of the
// base's dotenv files, whose database settings are its servers'; when it gets
// its servers it takes the base's users and databases, whatever its env file
// said before.
func TestACheckoutFromBeforeTheBaseTakesItsUsersWithItsServers(t *testing.T) {
	bx, do, events, _ := dbBox(t)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	snapshotFor(t, bx, key, "8.0.46")
	do("PUT", "/v1/locations/cal/base", map[string]any{"db": map[string]any{"engine": "mysql", "allow_copy": true}}, nil)
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "older", "prepare_with": "none"}, &wt)
	if _, err := os.Stat(filepath.Join(wt.Path, ".env")); err == nil {
		t.Fatal("a checkout without servers got the base's .env")
	}
	// Its own .env from before, on the box's database.
	os.WriteFile(filepath.Join(wt.Path, ".env"), []byte("APP_KEY=base64:mine\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_DATABASE=cal_older\nDB_USERNAME=me\nDB_PASSWORD=mine\n"), 0o600)
	do("POST", "/v1/locations/cal/worktrees/older/prepare", nil, nil)
	waitFor(t, events, "worktree.prepare.finished")
	if _, err := os.Stat(filepath.Join(wt.Path, ".env.testing")); err == nil {
		t.Fatal("preparing it again added the base's .env.testing")
	}
	if env := envOf(t, filepath.Join(wt.Path, ".env")); env["DB_DATABASE"] != "cal_older" || env["DB_USERNAME"] != "me" {
		t.Fatalf("its .env changed: %v", env)
	}
	if code := do("PUT", "/v1/locations/cal/worktrees/older/db", map[string]string{"from": "base"}, nil); code != 202 {
		t.Fatalf("asking for the base's database = %d", code)
	}
	waitFor(t, events, "worktree.prepare.finished")
	env := envOf(t, filepath.Join(wt.Path, ".env"))
	if env["DB_DATABASE"] != "shop" || env["DB_USERNAME"] != "app" || env["DB_PASSWORD"] != "s3cret" || env["APP_KEY"] != "base64:mine" {
		t.Fatalf("with its servers, .env = %v", env)
	}
	if inst := bx.instancesFor(wt.Path); len(inst) != 1 || env["DB_PORT"] != strconv.Itoa(inst[0].Port) {
		t.Fatalf("its server: %+v, .env port %s", inst, env["DB_PORT"])
	}
	if testEnv := envOf(t, filepath.Join(wt.Path, ".env.testing")); testEnv["DB_DATABASE"] != "shop_test" {
		t.Fatalf(".env.testing = %v", testEnv)
	}
}
