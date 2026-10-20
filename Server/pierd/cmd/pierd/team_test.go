package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"pier/pierd/internal/box"
)

// team init says what it would do and does nothing with --dry-run: the
// group, the team's user, the folders, the settings file, each member.
func TestTeamInitDryRunSaysWhatItWouldDo(t *testing.T) {
	ran := []string{}
	oldRun, oldExists := teamRun, teamExists
	teamRun = func(name string, args ...string) error { ran = append(ran, name); return nil }
	teamExists = func(db, name string) bool { return false }
	t.Cleanup(func() { teamRun, teamExists = oldRun, oldExists })
	var out bytes.Buffer
	if err := teamCmd([]string{"init", "--dry-run", "--members", "alice,bob"}, &out); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"make the group pier", "make the system user pier", "/srv/pier/team (pier, group pier", "write /etc/pier/team.json",
		"put alice in pier", "put bob in pier", "can read what the team publishes"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("dry run lacks %q:\n%s", want, out.String())
		}
	}
	if len(ran) > 0 {
		t.Fatalf("a dry run ran %v", ran)
	}
}

func TestTeamCommandsNeedRoot(t *testing.T) {
	old := teamIsRoot
	teamIsRoot = func() bool { return false }
	t.Cleanup(func() { teamIsRoot = old })
	if err := teamCmd([]string{"init"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "root") {
		t.Fatalf("init as a user = %v", err)
	}
	if err := teamCmd([]string{"base", "octocat/shop", "files"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "root") {
		t.Fatalf("base as a user = %v", err)
	}
}

func TestFlagsMayFollowWhatTheyNameAfter(t *testing.T) {
	got := strings.Join(reorder([]string{".env", "--from", "/root/shop.env"}), " ")
	if got != "--from /root/shop.env .env" {
		t.Fatalf("reorder = %q", got)
	}
	if got := strings.Join(reorder([]string{"--redis", "x"}), " "); got != "--redis x" {
		t.Fatalf("a bool flag took a value: %q", got)
	}
}

// fakeTeamSystem makes team init's system changes a test's own: no group or
// user is made, owners are set to nobody, the settings go to a temporary
// file and the MySQL server has an AppArmor profile in a temporary folder.
func fakeTeamSystem(t *testing.T) (settings, local string) {
	t.Helper()
	aa := t.TempDir()
	settings, local = filepath.Join(t.TempDir(), "team.json"), filepath.Join(aa, "local")
	os.WriteFile(filepath.Join(aa, "profile"), []byte("/usr/sbin/mysqld {}\n"), 0o644)
	oldRun, oldExists, oldRoot, oldLookup, oldChown, oldSettings := teamRun, teamExists, teamIsRoot, teamLookup, teamChown, teamSettingsFile
	oldProfile, oldLocal := teamAppArmorProfile, teamAppArmorLocal
	teamRun = func(name string, args ...string) error { return nil }
	teamExists = func(db, name string) bool { return true }
	teamIsRoot = func() bool { return true }
	teamLookup = func(user, group string) (int, int, error) { return 1500, 1500, nil }
	teamChown = func(string, int, int) error { return nil }
	teamSettingsFile = func() string { return settings }
	teamAppArmorProfile, teamAppArmorLocal = filepath.Join(aa, "profile"), local
	t.Cleanup(func() {
		teamRun, teamExists, teamIsRoot, teamLookup, teamChown, teamSettingsFile = oldRun, oldExists, oldRoot, oldLookup, oldChown, oldSettings
		teamAppArmorProfile, teamAppArmorLocal = oldProfile, oldLocal
	})
	return settings, local
}

// team init makes the team's folder and nothing above it changes: /srv,
// /opt or /home keep their owner and mode. A folder already holding someone
// else's files is never taken over.
func TestTeamInitLeavesTheFoldersAboveAlone(t *testing.T) {
	settings, local := fakeTeamSystem(t)
	parent := t.TempDir()
	os.Chmod(parent, 0o755)
	os.WriteFile(filepath.Join(parent, "someones.txt"), []byte("x"), 0o644)
	dir := filepath.Join(parent, "team")
	if err := teamCmd([]string{"init", "--dir", dir, "--user", "shopteam"}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(parent); info.Mode().Perm() != 0o755 {
		t.Fatalf("the folder above became %v", info.Mode())
	}
	if info, _ := os.Stat(dir); info.Mode().Perm() != 0o750 || info.Mode()&os.ModeSetgid == 0 {
		t.Fatalf("the team's folder is %v", info.Mode())
	}
	var s box.TeamSettings
	raw, _ := os.ReadFile(settings)
	json.Unmarshal(raw, &s)
	if s.Dir != dir || s.User != "shopteam" {
		t.Fatalf("settings = %s", raw)
	}
	if info, _ := os.Stat(settings); info.Mode().Perm() != 0o644 {
		t.Fatalf("the settings members read are %v", info.Mode())
	}
	if rule, _ := os.ReadFile(local); !strings.Contains(string(rule), "owner "+dir+"/projects/*/db/build/** rwk,") {
		t.Fatalf("AppArmor lines = %s", rule)
	}
	// Again: nothing changes, it is the team's folder.
	if err := teamCmd([]string{"init", "--dir", dir, "--user", "shopteam"}, &bytes.Buffer{}); err != nil {
		t.Fatalf("init again = %v", err)
	}
	for _, bad := range []string{parent, "/", "/srv/my team", "relative"} {
		if err := teamCmd([]string{"init", "--dir", bad}, &bytes.Buffer{}); err == nil {
			t.Errorf("init --dir %s was taken", bad)
		}
	}
}

// A second init with another folder replaces pierd's AppArmor lines rather
// than adding a second set, and keeps the profile's other lines.
func TestAppArmorLinesAreReplacedNotDoubled(t *testing.T) {
	have := []byte("# a rule of the box's own\n/data/mysql/** rwk,\n\n" + box.AppArmorRuleFor("/srv/pier/team"))
	got := string(withAppArmorRule(have, box.AppArmorRuleFor("/opt/team")))
	if strings.Count(got, box.AppArmorMarker) != 1 || strings.Contains(got, "/srv/pier/team") || !strings.Contains(got, "/opt/team/projects") ||
		!strings.Contains(got, "/data/mysql/** rwk,") {
		t.Fatalf("local profile =\n%s", got)
	}
}

// db rm takes a snapshot's id, never a path.
func TestDBRmTakesOnlyASnapshotsID(t *testing.T) {
	p, err := box.OpenTeamProject(t.TempDir(), "acme/shop", box.TeamOwner{})
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(p.DBDir(), "gen", "20261020-120000"), 0o750)
	for _, bad := range []string{"", "..", ".", "../../files", "gen"} {
		if err := teamDB(p, box.TeamOwner{}, []string{"rm", bad}, &bytes.Buffer{}); err == nil {
			t.Errorf("db rm %q was taken", bad)
		}
	}
	if _, err := os.Stat(filepath.Join(p.DBDir(), "gen", "20261020-120000")); err != nil {
		t.Fatal("a snapshot went")
	}
}

// The imports' servers run as the team's own user, the one init made.
func TestTheTeamsOwnUserRunsItsImports(t *testing.T) {
	fakeTeamSystem(t)
	var asked []string
	teamLookup = func(user, group string) (int, int, error) {
		asked = append(asked, user+":"+group)
		return 1501, 1502, nil
	}
	owner, err := teamOwner(box.TeamSettings{Dir: "/srv/shopteam", Group: "shop", User: "shopteam"})
	if err != nil || owner.UID != 1501 || owner.GID != 1502 || strings.Join(asked, ",") != "shopteam:shop" {
		t.Fatalf("owner = %+v %v (asked %v)", owner, err, asked)
	}
	teamLookup = func(string, string) (int, int, error) { return 0, 0, nil }
	if _, err := teamOwner(box.TeamSettings{Dir: "/srv/shopteam", User: "root"}); err == nil {
		t.Fatal("root may not run the imports' servers")
	}
}
