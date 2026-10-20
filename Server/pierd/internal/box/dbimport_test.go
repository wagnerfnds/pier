package box

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The import's MySQL client and mysqldump in these tests: this binary again.
// The client runs SQL on the fake server its defaults file names (appending
// it to sql.log in that server's datadir, as if it had run), answers the
// few questions the import asks, and stops the server on SHUTDOWN; mysqldump
// dumps a source's canned rows, or another fake server's sql.log.

// trace notes each run of a fake tool and its arguments, so a test can tell
// the order and that no password was ever an argument.
func trace(tool string, args []string) {
	if p := os.Getenv("FAKE_TRACE"); p != "" {
		f, _ := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		fmt.Fprintf(f, "%s %s\n", tool, strings.Join(args, " "))
		f.Close()
	}
}

// clientConf is a [client] section's keys from --defaults-file, which
// must be the first argument (as MySQL's programs want it). A run that would
// read the caller's own option files or MySQL variables (which could send it
// to another server) is an error.
func clientConf(args []string) (map[string]string, error) {
	conf := map[string]string{}
	if len(args) == 0 || !strings.HasPrefix(args[0], "--defaults-file=") {
		return nil, fmt.Errorf("--defaults-file is not the first argument: %v", args)
	}
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "MYSQL_") && !strings.HasPrefix(kv, "MYSQL_TEST_LOGIN_FILE=") {
			return nil, fmt.Errorf("%s reached the client", kv)
		}
	}
	if os.Getenv("MYSQL_TEST_LOGIN_FILE") == "" {
		return nil, errors.New("the client would read ~/.mylogin.cnf")
	}
	for _, a := range args {
		path, ok := strings.CutPrefix(a, "--defaults-file=")
		if !ok {
			continue
		}
		raw, _ := os.ReadFile(path)
		in := false
		for _, l := range strings.Split(string(raw), "\n") {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "[") {
				in = l == "[client]"
				continue
			}
			if k, v, ok := strings.Cut(l, "="); ok && in {
				// As MySQL reads it: a value not in quotes ends at a #.
				if !strings.HasPrefix(v, `"`) {
					v, _, _ = strings.Cut(v, "#")
					v = strings.TrimSpace(v)
				}
				conf[k] = unquoteConf(v)
			}
		}
	}
	return conf, nil
}

func serverInfo(sock string) (datadir string, pid int) {
	var info struct {
		Datadir string `json:"datadir"`
		Pid     int    `json:"pid"`
	}
	raw, _ := os.ReadFile(sock + ".info")
	json.Unmarshal(raw, &info)
	return info.Datadir, info.Pid
}

func fakeMySQLClient(args []string) int {
	conf, err := clientConf(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 3
	}
	// A load that stops on an SQL error, reading no more of its input.
	if os.Getenv("FAKE_LOAD_FAIL") != "" && conf["host"] == "" && strings.Contains(strings.Join(args, " "), "--max-allowed-packet") {
		fmt.Fprintln(os.Stderr, "ERROR 1064 (42000) at line 2: You have an error in your SQL syntax")
		return 1
	}
	sql, _ := io.ReadAll(os.Stdin)
	text := string(sql)
	if conf["host"] != "" {
		// The source: only asked which databases it has.
		if strings.Contains(text, "SHOW DATABASES") {
			fmt.Println("information_schema\nmysql\napp\nperformance_schema\nsys")
		}
		return 0
	}
	datadir, pid := serverInfo(conf["socket"])
	if datadir == "" {
		fmt.Fprintln(os.Stderr, "ERROR 2002: can't connect through socket "+conf["socket"])
		return 1
	}
	f, _ := os.OpenFile(filepath.Join(datadir, "sql.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	f.WriteString(text)
	if !strings.HasSuffix(text, "\n") {
		f.WriteString("\n")
	}
	f.Close()
	switch {
	case strings.Contains(text, "SHUTDOWN"):
		syscall.Kill(pid, syscall.SIGTERM)
	case strings.Contains(text, "SELECT CONCAT(table_schema"):
		fmt.Println("app.jobs\napp.failed_jobs")
	case strings.Contains(text, "information_schema.FILES"):
		fmt.Println("0")
	case strings.Contains(text, "information_schema.TRIGGERS"):
		if d := os.Getenv("FAKE_DEFINER"); d != "" {
			fmt.Println(d)
		}
	case strings.Contains(text, "-- checks"):
		sc := bufio.NewScanner(strings.NewReader(text))
		for sc.Scan() {
			if l := sc.Text(); strings.HasPrefix(strings.ToUpper(strings.TrimSpace(l)), "SELECT") {
				if strings.Contains(l, "real.example") {
					fmt.Println("3")
				} else {
					fmt.Println("0")
				}
			}
		}
	}
	return 0
}

func fakeMySQLDump(args []string) int {
	conf, err := clientConf(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 3
	}
	if conf["host"] != "" {
		if conf["password"] != envOr("FAKE_SOURCE_PASSWORD", "source-pass") {
			fmt.Fprintln(os.Stderr, "Access denied")
			return 2
		}
		if strings.Contains(strings.Join(args, " "), "--no-data") {
			fmt.Println("-- the source's tables\nCREATE TABLE app.leads (id INT, name TEXT, email TEXT, phone TEXT);")
			return 0
		}
		fmt.Println("-- dump from the source\nINSERT INTO app.leads VALUES ('Maria Souza','maria@real.example','+55 11 99999-0000');")
		if os.Getenv("FAKE_DUMP_BIG") != "" {
			// More than a pipe holds: a load that stopped reading leaves
			// this waiting to write.
			line := "-- " + strings.Repeat("x", 1020) + "\n"
			for range 8 << 10 {
				if _, err := os.Stdout.WriteString(line); err != nil {
					return 2
				}
			}
		}
		if os.Getenv("FAKE_DUMP_SLOW") != "" {
			time.Sleep(time.Minute)
		}
		return 0
	}
	datadir, _ := serverInfo(conf["socket"])
	raw, err := os.ReadFile(filepath.Join(datadir, "sql.log"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	fmt.Println("-- dump of the import's own server")
	os.Stdout.Write(raw)
	return 0
}

// importBox has fake MySQL tools, a source with real data, and the
// project's db folder.
func importOptions(t *testing.T) (ImportOptions, string) {
	t.Helper()
	fakeDBTools(t)
	bin := filepath.Dir(mysqlServer())
	self, _ := os.Executable()
	for _, tool := range []string{"mysql", "mysqldump"} {
		os.WriteFile(filepath.Join(bin, tool), []byte("#!/bin/sh\nFAKE_DB_SERVER="+tool+" exec "+self+" \"$@\"\n"), 0o755)
	}
	old := importTools
	importTools = func() (string, string, string) {
		return mysqlServer(), filepath.Join(bin, "mysql"), filepath.Join(bin, "mysqldump")
	}
	t.Cleanup(func() { importTools = old })
	tracePath := filepath.Join(t.TempDir(), "trace")
	t.Setenv("FAKE_TRACE", tracePath)
	sql := t.TempDir()
	anon := filepath.Join(sql, "anon.sql")
	os.WriteFile(anon, []byte("UPDATE app.leads SET name = CONCAT('Lead ', id), email = CONCAT('lead', id, '@example.invalid');\n"), 0o600)
	checks := filepath.Join(sql, "checks.sql")
	os.WriteFile(checks, []byte("-- checks\nSELECT COUNT(*) FROM app.leads WHERE email NOT LIKE '%@example.invalid';\nSELECT COUNT(*) FROM app.leads WHERE phone LIKE '+55%';\n"), 0o600)
	run, _ := os.MkdirTemp("/tmp", "pimp")
	t.Cleanup(func() { os.RemoveAll(run) })
	return ImportOptions{
		Server: "db.example.internal:3306", User: "ro", Password: "source-pass", Databases: []string{"app"},
		Sanitize: []string{anon}, Checks: []string{checks}, Dest: filepath.Join(t.TempDir(), "db"), RunDir: run,
		EnvFiles: map[string][]byte{".env": []byte("DB_DATABASE=app\nDB_USERNAME=app\nDB_PASSWORD=dev-pass\n"), ".env.testing": []byte("DB_DATABASE=app_test\n")},
	}, tracePath
}

// An import takes the source's data into a server of its own, empties its
// queues, takes personal data out and checks it, then rebuilds it into a
// fresh server from a dump, makes the app's users and databases, shuts it
// down cleanly and makes it the current snapshot; the raw import is gone and
// no password was ever an argument.
func TestAnImportIsAnonymizedRebuiltAndBecomesTheSnapshot(t *testing.T) {
	o, tracePath := importOptions(t)
	m, err := ImportSnapshot(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	if !m.Sanitized || m.Version != "8.0.46" || strings.Join(m.Databases, ",") != "app" || m.Checks != 2 {
		t.Fatalf("manifest = %+v", m)
	}
	gens, current := SnapshotGens(o.Dest)
	if len(gens) != 1 || current != m.ID {
		t.Fatalf("gens %+v current %s", gens, current)
	}
	data := filepath.Join(o.Dest, "gen", m.ID, "data")
	log := readFile(t, filepath.Join(data, "sql.log"))
	for _, want := range []string{"maria@real.example", "TRUNCATE TABLE `app`.`jobs`", "UPDATE app.leads SET name", "CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'dev-pass'",
		"CREATE DATABASE IF NOT EXISTS `app_test`", "innodb_fast_shutdown=0"} {
		if !strings.Contains(log, want) {
			t.Errorf("the snapshot's server never got %q", want)
		}
	}
	// The snapshot is the rebuilt server: it got the import's own dump (with
	// its update after the real row), never the source's directly.
	if !strings.HasPrefix(log, "-- dump of the import's own server") {
		t.Fatalf("the snapshot was not rebuilt from a dump:\n%s", log)
	}
	if _, err := os.Stat(filepath.Join(data, "auto.cnf")); err == nil {
		t.Fatal("the snapshot kept its server's identity")
	}
	if _, err := os.Stat(filepath.Join(o.Dest, "build")); err == nil {
		entries, _ := os.ReadDir(filepath.Join(o.Dest, "build"))
		if len(entries) > 0 {
			t.Fatalf("the build stayed: %v", entries)
		}
	}
	trace := readFile(t, tracePath)
	if strings.Contains(trace, "source-pass") || strings.Contains(trace, "dev-pass") {
		t.Fatal("a password was an argument")
	}
	order := []string{"mysqld --defaults-file=", "--initialize-insecure", "mysqldump --defaults-file=", "mysql --defaults-file="}
	at := 0
	for _, w := range order {
		i := strings.Index(trace[at:], w)
		if i < 0 {
			t.Fatalf("%q not after position %d in:\n%s", w, at, trace)
		}
		at += i
	}
}

// A check that answers anything but 0 stops the import: nothing becomes the
// snapshot, and the current one stays.
func TestAFailingCheckLeavesTheCurrentSnapshot(t *testing.T) {
	o, _ := importOptions(t)
	first, err := ImportSnapshot(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	// The sanitize SQL forgets the email.
	os.WriteFile(o.Sanitize[0], []byte("UPDATE app.leads SET name = 'x';\n"), 0o600)
	os.WriteFile(o.Checks[0], []byte("-- checks\nSELECT COUNT(*) FROM app.leads WHERE email LIKE '%real.example';\n"), 0o600)
	if _, err := ImportSnapshot(context.Background(), o); err == nil || !strings.Contains(err.Error(), "answered 3") {
		t.Fatalf("a failing check gave %v", err)
	}
	if _, current := SnapshotGens(o.Dest); current != first.ID {
		t.Fatalf("current = %s, want the first %s", current, first.ID)
	}
	if gens, _ := SnapshotGens(o.Dest); len(gens) != 1 {
		t.Fatalf("the failed import left a snapshot: %+v", gens)
	}
	if entries, _ := os.ReadDir(filepath.Join(o.Dest, "build")); len(entries) > 0 {
		t.Fatalf("the failed import left its build: %v", entries)
	}
}

func TestRealDataNeedsSanitizingOrSayingSo(t *testing.T) {
	o, _ := importOptions(t)
	o.Sanitize = nil
	if _, err := ImportSnapshot(context.Background(), o); err == nil || !strings.Contains(err.Error(), "--sanitize") {
		t.Fatalf("an import without sanitizing gave %v", err)
	}
	o.RealData, o.Checks = true, nil
	m, err := ImportSnapshot(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	if m.Sanitized {
		t.Fatal("real data reads as anonymized")
	}
}

// Root publishes a project's base in the team's folder: its files, its
// config (never a person's say), its current snapshot; a member's pierd
// copies them and its worktrees copy the team's snapshot.
func TestRootPublishesATeamBaseThatMembersUse(t *testing.T) {
	team := t.TempDir()
	p, err := OpenTeamProject(team, "OctoCat/Shop", TeamOwner{})
	if err != nil {
		t.Fatal(err)
	}
	if p.Key != "octocat__shop" {
		t.Fatalf("key = %s", p.Key)
	}
	if err := p.AddFile(".env", []byte("DB_DATABASE=shop\n")); err != nil {
		t.Fatal(err)
	}
	if err := p.AddFile("../escape", []byte("x")); err == nil {
		t.Fatal("a path outside the project was taken")
	}
	if err := p.SetConfig(RepoConfig{Setup: "make", Hooks: nil, PrepareWith: "agent"}); err == nil {
		t.Fatal("the team's config took a person's consent")
	}
	if err := p.SetConfig(RepoConfig{Setup: "composer install", Base: &BaseConfig{DB: &BaseDB{Engine: "mysql"}, Redis: true}}); err != nil {
		t.Fatal(err)
	}
	gen := filepath.Join(p.DBDir(), "gen", "20261020-120000")
	os.MkdirAll(filepath.Join(gen, "data"), 0o750)
	saveJSON(filepath.Join(gen, "manifest.json"), snapshotManifest{ID: "20261020-120000", Engine: "mysql", Version: "8.0.46", Sanitized: true})
	swapCurrent(p.DBDir(), "20261020-120000")
	if err := p.PublishDB(); err != nil {
		t.Fatal(err)
	}
	pub := p.Published()
	if pub.DB == nil || pub.DB.ID != "20261020-120000" || pub.Config == "" || pub.Files[".env"].SHA == "" {
		t.Fatalf("published = %+v", pub)
	}
	// A member's box whose project's origin is octocat/shop.
	settings := filepath.Join(t.TempDir(), "team.json")
	os.WriteFile(settings, []byte(`{"dir":"`+team+`"}`), 0o644)
	old := teamSettingsPath
	teamSettingsPath = settings
	t.Cleanup(func() { teamSettingsPath = old })
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "shop", "path": repo}, nil)
	bx.Locations.update(func(all []savedLocation) ([]savedLocation, error) {
		for i := range all {
			all[i].BaseKey = "octocat__shop"
		}
		return all, nil
	})
	if bx.syncTeam(context.Background(), "shop") == nil {
		t.Fatal("the member's box found no team base")
	}
	snap := bx.currentSnapshot("octocat__shop")
	if snap == nil || snap.Layer != "team" || snap.Data != filepath.Join(gen, "data") || !snap.Manifest.Sanitized {
		t.Fatalf("snapshot = %+v", snap)
	}
	cfg, _ := bx.Locations.Config(context.Background(), "shop")
	if cfg.Effective.Setup != "composer install" || cfg.Effective.Base == nil || cfg.Effective.Base.DB == nil || !cfg.Effective.Base.Redis {
		t.Fatalf("the member's config = %+v", cfg.Effective)
	}
	// The member's own snapshot, when it makes one, comes first.
	snapshotFor(t, bx, "octocat__shop", "8.0.46")
	if s := bx.currentSnapshot("octocat__shop"); s.Layer != "box" {
		t.Fatalf("the box's own snapshot did not win: %+v", s)
	}
}

func TestOldSnapshotsArePrunedButNeverTheCurrentOne(t *testing.T) {
	dest := t.TempDir()
	for _, id := range []string{"20261001-000000", "20261010-000000", "20261020-000000"} {
		os.MkdirAll(filepath.Join(dest, "gen", id), 0o700)
		saveJSON(filepath.Join(dest, "gen", id, "manifest.json"), snapshotManifest{ID: id})
	}
	swapCurrent(dest, "20261010-000000")
	removed := PruneSnapshots(dest, 2)
	if strings.Join(removed, ",") != "20261001-000000" {
		t.Fatalf("removed %v", removed)
	}
	gens, current := SnapshotGens(dest)
	if len(gens) != 2 || current != "20261010-000000" {
		t.Fatalf("kept %+v current %s", gens, current)
	}
}

// The import's clients connect only where its own option file says: the
// caller's MySQL variables and login paths never reach them (a socket or
// host there would send its TRUNCATEs to another server).
func TestTheImportsClientsReadOnlyItsOwnOptionFile(t *testing.T) {
	o, tracePath := importOptions(t)
	t.Setenv("MYSQL_HOST", "prod.example.internal")
	t.Setenv("MYSQL_UNIX_PORT", "/var/run/mysqld/mysqld.sock")
	t.Setenv("MYSQL_PWD", "production")
	// A password with what an option file would otherwise cut it at.
	o.Password = `pa#ss\word"x; y`
	t.Setenv("FAKE_SOURCE_PASSWORD", o.Password)
	if _, err := ImportSnapshot(context.Background(), o); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(readFile(t, tracePath), "--defaults-extra-file") {
		t.Fatal("a client read the caller's option files")
	}
}

// A load that stops on an SQL error ends the import with it: the dump it
// stopped reading does not keep it waiting.
func TestAFailedLoadEndsTheImport(t *testing.T) {
	o, _ := importOptions(t)
	t.Setenv("FAKE_LOAD_FAIL", "1")
	t.Setenv("FAKE_DUMP_BIG", "1")
	done := make(chan error, 1)
	go func() {
		_, err := ImportSnapshot(context.Background(), o)
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "ERROR 1064") {
			t.Fatalf("import = %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("the import hangs on a failed load")
	}
}

// An import stopped halfway (Ctrl-C, the terminal gone) ends its server and
// deletes its raw data and the source's password on the way out.
func TestAnInterruptedImportLeavesNothingBehind(t *testing.T) {
	o, tracePath := importOptions(t)
	t.Setenv("FAKE_DUMP_SLOW", "1")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := ImportSnapshot(ctx, o)
		done <- err
	}()
	var pidFile string
	deadline := time.Now().Add(30 * time.Second)
	for pidFile == "" || !strings.Contains(readFileOr(tracePath), "mysqldump") {
		if time.Now().After(deadline) {
			t.Fatal("the import never got to its dump")
		}
		time.Sleep(50 * time.Millisecond)
		matches, _ := filepath.Glob(filepath.Join(o.Dest, "build", "*", "raw.pid"))
		if len(matches) > 0 {
			pidFile = matches[0]
		}
	}
	raw, _ := os.ReadFile(pidFile)
	var pid int
	fmt.Sscan(string(raw), &pid)
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("an interrupted import succeeded")
		}
	case <-time.After(30 * time.Second):
		t.Fatal("the interrupted import did not end")
	}
	if entries, _ := os.ReadDir(filepath.Join(o.Dest, "build")); len(entries) > 0 {
		t.Fatalf("the raw import stayed: %v", entries)
	}
	if entries, _ := os.ReadDir(o.RunDir); len(entries) > 0 {
		t.Fatalf("its sockets stayed: %v", entries)
	}
	if pid > 0 {
		deadline := time.Now().Add(5 * time.Second)
		for syscall.Kill(pid, 0) == nil {
			if time.Now().After(deadline) {
				t.Fatalf("its server (pid %d) still runs", pid)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
}

func readFileOr(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}

// What an import cut short left (pierd killed, the machine rebooted) goes
// before the next one starts.
func TestAnImportCutShortIsSweptByTheNext(t *testing.T) {
	o, _ := importOptions(t)
	stale := filepath.Join(o.Dest, "build", "20200101-000000-dead")
	os.MkdirAll(filepath.Join(stale, "raw"), 0o700)
	os.WriteFile(filepath.Join(stale, "raw", "leads.ibd"), []byte("maria@real.example"), 0o600)
	os.WriteFile(filepath.Join(stale, "source.cnf"), []byte("[client]\npassword=source-pass\n"), 0o600)
	os.MkdirAll(filepath.Join(o.RunDir, "20200101-000000-dead"), 0o700)
	if _, err := ImportSnapshot(context.Background(), o); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); err == nil {
		t.Fatal("the raw data of an import cut short stayed")
	}
	if _, err := os.Stat(filepath.Join(o.RunDir, "20200101-000000-dead")); err == nil {
		t.Fatal("its run folder stayed")
	}
}

// The app's user signs in as itself: root (which a worktree's server keeps
// for pierd) and one user with two passwords are refused before anything
// starts.
func TestTheAppsUserIsNeverRootNorTwoPasswords(t *testing.T) {
	o, tracePath := importOptions(t)
	o.EnvFiles = map[string][]byte{".env": []byte("DB_DATABASE=app\nDB_USERNAME=root\nDB_PASSWORD=\n")}
	if _, err := ImportSnapshot(context.Background(), o); err == nil || !strings.Contains(err.Error(), "DB_USERNAME=root") {
		t.Fatalf("root = %v", err)
	}
	o.EnvFiles = map[string][]byte{".env": []byte("DB_USERNAME=app\nDB_PASSWORD=one\n"), ".env.testing": []byte("DB_USERNAME=app\nDB_PASSWORD=two\n")}
	if _, err := ImportSnapshot(context.Background(), o); err == nil || !strings.Contains(err.Error(), "two passwords") {
		t.Fatalf("two passwords = %v", err)
	}
	if strings.Contains(readFileOr(tracePath), "mysqld") {
		t.Fatal("a server started for an import that could not succeed")
	}
}

// Rebuilding is what leaves nothing taken out in the snapshot's files: one
// kept without it is real data.
func TestASnapshotNotRebuiltIsRealData(t *testing.T) {
	o, _ := importOptions(t)
	o.NoRebuild = true
	if _, err := ImportSnapshot(context.Background(), o); err == nil || !strings.Contains(err.Error(), "--no-rebuild") {
		t.Fatalf("no rebuild with sanitize = %v", err)
	}
	o.RealData = true
	m, err := ImportSnapshot(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	if m.Sanitized {
		t.Fatal("a snapshot not rebuilt reads as anonymized")
	}
}

// The app's users get every privilege on the project's databases (and those
// its parallel tests make), never on the server's administration, which
// would let anyone who knows the password write files as the worktree's
// user; the data's definers exist, locked.
func TestTheAppsUserGetsItsDatabasesAlone(t *testing.T) {
	o, _ := importOptions(t)
	t.Setenv("FAKE_DEFINER", "trigger_owner@%")
	m, err := ImportSnapshot(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	log := readFile(t, filepath.Join(o.Dest, "gen", m.ID, "data", "sql.log"))
	for _, want := range []string{"GRANT ALL PRIVILEGES ON `app`.* TO 'app'@'%'", "GRANT ALL PRIVILEGES ON `app\\_%`.* TO 'app'@'%'",
		"GRANT ALL PRIVILEGES ON `app\\_test`.* TO 'app'@'%'", "ALTER USER 'app'@'%' IDENTIFIED BY 'dev-pass' ACCOUNT UNLOCK",
		"CREATE USER IF NOT EXISTS 'trigger_owner'@'%' ACCOUNT LOCK"} {
		if !strings.Contains(log, want) {
			t.Errorf("the snapshot's server never got %q", want)
		}
	}
	if strings.Contains(log, "ON *.*") {
		t.Fatal("a user got the whole server")
	}
	if !ValidSnapshotID(m.ID) || strings.Count(m.ID, "-") != 2 {
		t.Fatalf("snapshot id %q", m.ID)
	}
	for _, bad := range []string{"", "..", "../x", "20261020-153045/..", "current"} {
		if ValidSnapshotID(bad) {
			t.Errorf("%q passed for a snapshot's id", bad)
		}
	}
}

// Each import server's buffer pool fits the machine: an eighth of what it
// has free, up to 8 GB, or what --memory says.
func TestAnImportsMemoryFitsTheMachine(t *testing.T) {
	got := importMemory(ImportOptions{})
	mb, err := strconv.Atoi(strings.TrimSuffix(got, "M"))
	if err != nil || mb < 512 || mb > 8<<10 {
		t.Fatalf("pool = %s", got)
	}
	if got := importMemory(ImportOptions{Memory: "3G"}); got != "3G" {
		t.Fatalf("--memory 3G = %s", got)
	}
	o, _ := importOptions(t)
	o.Memory = "1G\n[mysqld]\ninit-file=/tmp/x.sql"
	if _, err := ImportSnapshot(context.Background(), o); err == nil || !strings.Contains(err.Error(), "--memory") {
		t.Fatalf("a memory with a config in it = %v", err)
	}
}

// --schema-only runs the sanitize SQL and the checks on the source's tables
// without their rows, in a minute, and publishes nothing: what an import of
// hours would find wrong with that SQL, found first.
func TestASchemaOnlyImportTestsTheSQLAndPublishesNothing(t *testing.T) {
	o, tracePath := importOptions(t)
	var progress strings.Builder
	o.SchemaOnly, o.Progress = true, &progress
	m, err := ImportSnapshot(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	if m.ID != "" {
		t.Fatalf("a schema-only run made a snapshot: %+v", m)
	}
	if !strings.Contains(readFile(t, tracePath), "--no-data") {
		t.Fatal("the source's rows were dumped")
	}
	if !strings.Contains(progress.String(), "2 checks answered 0") || !strings.Contains(progress.String(), "nothing was published") {
		t.Fatalf("progress:\n%s", progress.String())
	}
	if gens, current := SnapshotGens(o.Dest); len(gens) != 0 || current != "" {
		t.Fatalf("published %+v (current %q)", gens, current)
	}
	if entries, _ := os.ReadDir(filepath.Join(o.Dest, "build")); len(entries) > 0 {
		t.Fatalf("its build stayed: %v", entries)
	}
}
