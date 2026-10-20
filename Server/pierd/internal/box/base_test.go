package box

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"pier/pierd/internal/events"
)

// baseRepo is a repository whose .env, .env.testing, auth.json and vendor/
// are ignored, with them in its main checkout as an install would leave
// them.
func baseRepo(t *testing.T) string {
	t.Helper()
	repo := gitRepo(t)
	run := func(args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
	}
	os.WriteFile(filepath.Join(repo, ".gitignore"), []byte(".env\n.env.testing\nauth.json\n/vendor\n/public/storage\n"), 0o644)
	run("add", ".gitignore")
	run("commit", "-q", "-m", "ignores")
	os.WriteFile(filepath.Join(repo, ".env"), []byte("# dev\nAPP_KEY=base64:main\nDB_HOST=127.0.0.1\nDB_PASSWORD=s3cret-value\n"), 0o644)
	os.WriteFile(filepath.Join(repo, ".env.testing"), []byte("DB_DATABASE=app_test\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "auth.json"), []byte(`{"http-basic":{"packages.example.com":{"username":"u","password":"license"}}}`), 0o644)
	os.MkdirAll(filepath.Join(repo, "vendor", "acme"), 0o755)
	os.WriteFile(filepath.Join(repo, "vendor", "autoload.php"), []byte("<?php // autoload\n"), 0o644)
	os.MkdirAll(filepath.Join(repo, "public"), 0o755)
	os.MkdirAll(filepath.Join(repo, "storage", "app", "public"), 0o755)
	os.Symlink(filepath.Join(repo, "storage", "app", "public"), filepath.Join(repo, "public", "storage"))
	return repo
}

func baseBox(t *testing.T) (*Box, func(method, path string, body, out any) int, <-chan events.Event) {
	t.Helper()
	var bx *Box
	c, bus := servedBox(t, func(b *Box) {
		b.LogDir = t.TempDir()
		b.StateDir = t.TempDir()
		bx = b
	})
	ch, stop := bus.Subscribe()
	t.Cleanup(stop)
	return bx, func(method, path string, body, out any) int { return call(t, c, method, path, "", body, out) }, ch
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Files kept in the project's base go into every new worktree as it is
// made, even one made with only its code, and the base's view never holds a
// file's content.
func TestTheBaseFilesGoIntoEveryNewWorktree(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := baseRepo(t)
	_, do, _ := baseBox(t)
	if do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil) != 200 {
		t.Fatal("add location")
	}
	for _, p := range []string{".env", ".env.testing", "auth.json"} {
		if code := do("POST", "/v1/locations/cal/base/files", map[string]string{"path": p}, nil); code != 200 {
			t.Fatalf("add %s = %d", p, code)
		}
	}
	var view BaseView
	if do("GET", "/v1/locations/cal/base", nil, &view) != 200 || len(view.Files) != 3 {
		t.Fatalf("base = %+v", view)
	}
	raw, _ := json.Marshal(view)
	if strings.Contains(string(raw), "s3cret-value") || strings.Contains(string(raw), "license") {
		t.Fatalf("the base's view holds a secret: %s", raw)
	}
	if env := view.Files[0]; env.Path != ".env" || env.Kind != "env" || strings.Join(env.Keys, ",") != "APP_KEY,DB_HOST,DB_PASSWORD" || env.From != "box" {
		t.Fatalf(".env = %+v", env)
	}

	var wt Worktree
	if code := do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "quick", "prepare": false}, &wt); code != 200 {
		t.Fatalf("create = %d", code)
	}
	if got := readFile(t, filepath.Join(wt.Path, ".env")); got != readFile(t, filepath.Join(repo, ".env")) {
		t.Fatalf("worktree .env = %q", got)
	}
	if info, err := os.Stat(filepath.Join(wt.Path, "auth.json")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("auth.json: %v %v", info, err)
	}
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/quick/prepare", nil, &st)
	if st.Base == nil || len(st.Base.Files) != 3 || st.Base.Files[0].Action != "written" {
		t.Fatalf("prepare's base = %+v", st.Base)
	}
}

// When the base changes, a checkout gets the new version of what it still
// has as pierd wrote it; what someone changed there stays, key by key in a
// dotenv file.
func TestWhatSomeoneChangedInACheckoutStaysWhenTheBaseChanges(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := baseRepo(t)
	_, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	for _, p := range []string{".env", "auth.json"} {
		do("POST", "/v1/locations/cal/base/files", map[string]string{"path": p}, nil)
	}
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "fix", "prepare": false}, &wt)
	// Someone points this worktree's app elsewhere and edits its auth.json.
	env := filepath.Join(wt.Path, ".env")
	os.WriteFile(env, []byte(strings.Replace(readFile(t, env), "DB_HOST=127.0.0.1", "DB_HOST=10.0.0.9", 1)), 0o600)
	os.WriteFile(filepath.Join(wt.Path, "auth.json"), []byte(`{"mine":true}`), 0o600)
	// The base moves on: a new key, a new APP_KEY and DB_HOST, a new auth.json.
	os.WriteFile(filepath.Join(repo, ".env"), []byte("# dev\nAPP_KEY=base64:new\nDB_HOST=192.0.2.1\nDB_PASSWORD=s3cret-value\nMAIL_MAILER=log\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "auth.json"), []byte(`{"v":2}`), 0o644)
	for _, p := range []string{".env", "auth.json"} {
		do("POST", "/v1/locations/cal/base/files", map[string]string{"path": p}, nil)
	}
	var applied struct{ Results []BaseApplied }
	if code := do("POST", "/v1/locations/cal/base/apply", map[string]any{"worktrees": []string{"fix"}}, &applied); code != 200 || len(applied.Results) != 1 {
		t.Fatalf("apply = %d %+v", code, applied)
	}
	got := parseEnvFile([]byte(readFile(t, env)))
	for k, want := range map[string]string{"APP_KEY": "base64:new", "DB_HOST": "10.0.0.9", "MAIL_MAILER": "log"} {
		if v, _, _ := got.get(k); v != want {
			t.Errorf("%s = %q, want %q", k, v, want)
		}
	}
	var envRes, authRes BaseResult
	for _, r := range applied.Results[0].Results {
		switch r.Path {
		case ".env":
			envRes = r
		case "auth.json":
			authRes = r
		}
	}
	if envRes.Action != "updated" || strings.Join(envRes.Keys, ",") != "DB_HOST" {
		t.Fatalf(".env result = %+v", envRes)
	}
	if authRes.Action != "kept" || readFile(t, filepath.Join(wt.Path, "auth.json")) != `{"mine":true}` {
		t.Fatalf("auth.json someone changed = %+v", authRes)
	}
}

// The base never writes over what git tracks in a checkout, nor through a
// link someone made there, and a file the repository does not ignore is
// kept out of commits through the repository's local excludes.
func TestTheBaseLeavesTrackedFilesAndLinksAlone(t *testing.T) {
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	os.WriteFile(filepath.Join(repo, "local.php"), []byte("<?php return [];\n"), 0o644)
	for _, p := range []string{".env", "local.php"} {
		if code := do("POST", "/v1/locations/cal/base/files", map[string]string{"path": p}, nil); code != 200 {
			t.Fatalf("add %s = %d", p, code)
		}
	}
	ctx := context.Background()
	wt, err := bx.Locations.CreateWorktree(ctx, "cal", "links", "", "")
	if err != nil {
		t.Fatal(err)
	}
	// Someone links .env to a file of their own.
	other := filepath.Join(t.TempDir(), "my.env")
	os.WriteFile(other, []byte("MINE=1\n"), 0o600)
	os.Symlink(other, filepath.Join(wt.Path, ".env"))
	loc, _ := bx.Locations.Get(ctx, "cal")
	res := bx.applyBaseFiles(ctx, loc, wt, nil)
	byPath := map[string]BaseResult{}
	for _, r := range res {
		byPath[r.Path] = r
	}
	if byPath[".env"].Action != "kept" || readFile(t, other) != "MINE=1\n" {
		t.Fatalf(".env behind a link = %+v", byPath[".env"])
	}
	if byPath["local.php"].Action != "written" {
		t.Fatalf("local.php = %+v", byPath["local.php"])
	}
	if out, _ := exec.Command("git", "-C", wt.Path, "status", "--porcelain").CombinedOutput(); strings.Contains(string(out), "local.php") {
		t.Fatalf("an untracked base file is offered for a commit: %s", out)
	}
	// Committed in the repository later: the base leaves the tracked file.
	os.WriteFile(filepath.Join(wt.Path, "local.php"), []byte("<?php // tracked\n"), 0o644)
	exec.Command("git", "-C", wt.Path, "add", "-f", "local.php").Run()
	exec.Command("git", "-C", wt.Path, "commit", "-q", "-m", "track").Run()
	for _, r := range bx.applyBaseFiles(ctx, loc, wt, nil) {
		if r.Path == "local.php" && r.Action != "skipped" {
			t.Fatalf("a tracked file = %+v", r)
		}
	}
	if got := readFile(t, filepath.Join(wt.Path, "local.php")); got != "<?php // tracked\n" {
		t.Fatalf("the tracked file was written: %q", got)
	}
}

func TestABaseFileMustBeASmallUntrackedFileInsideTheProject(t *testing.T) {
	repo := baseRepo(t)
	_, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	os.WriteFile(filepath.Join(repo, "huge.sql"), make([]byte, maxBaseFileBytes+1), 0o644)
	for path, want := range map[string]int{
		"../etc/passwd": 400, "/etc/passwd": 400, ".git/config": 400, "README": 400,
		"huge.sql": 400, "vendor": 400, "missing.env": 404,
	} {
		if code := do("POST", "/v1/locations/cal/base/files", map[string]string{"path": path}, nil); code != want {
			t.Errorf("adding %s = %d, want %d", path, code, want)
		}
	}
	if code := do("DELETE", "/v1/locations/cal/base/files?path=.env", nil, nil); code != 404 {
		t.Errorf("removing a file the base lacks = %d", code)
	}
}

// Ignored folders of the main checkout are copied into a new worktree
// before its recipe runs; a link into the main checkout is pointed at the
// worktree's own place, and what holds the main checkout's state is never
// copied.
func TestCarriedFoldersAreThereBeforeTheRecipeRuns(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := baseRepo(t)
	bx, do, ch := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	var view BaseView
	if code := do("PUT", "/v1/locations/cal/base", map[string]any{"carry": []string{"vendor", "public/storage", "storage", "bootstrap/cache"}}, &view); code != 200 {
		t.Fatalf("carry = %d", code)
	}
	if code := do("PUT", "/v1/locations/cal/base", map[string]any{"carry": []string{"../outside"}}, nil); code != 400 {
		t.Fatalf("carrying a path outside the project = %d", code)
	}
	bx.Locations.MergeLocalConfig("cal", RepoConfig{Setup: "test -f vendor/autoload.php && echo found > carried.txt"})
	var wt Worktree
	if code := do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "feature"}, &wt); code != 200 {
		t.Fatalf("create = %d", code)
	}
	waitFor(t, ch, "worktree.prepare.finished")
	if got := readFile(t, filepath.Join(wt.Path, "carried.txt")); got != "found\n" {
		t.Fatalf("the recipe did not find vendor: %q", got)
	}
	link, err := os.Readlink(filepath.Join(wt.Path, "public", "storage"))
	if err != nil || link != filepath.Join(wt.Path, "storage", "app", "public") {
		t.Fatalf("public/storage -> %q (%v)", link, err)
	}
	if _, err := os.Stat(filepath.Join(wt.Path, "storage")); err == nil {
		t.Fatal("storage was carried")
	}
	var st PrepareStatus
	do("GET", "/v1/locations/cal/worktrees/feature/prepare", nil, &st)
	carried := map[string]string{}
	for _, r := range st.Base.Carried {
		carried[r.Path] = r.Action
	}
	if carried["vendor"] != "carried" || carried["public/storage"] != "carried" || len(carried) != 2 {
		t.Fatalf("carried = %+v", st.Base.Carried)
	}
}

// The repository's .worktreeinclude (Claude Code's) names ignored files to
// copy too, only those git ignores.
func TestWorktreeIncludeNamesIgnoredFilesOnly(t *testing.T) {
	repo := baseRepo(t)
	os.WriteFile(filepath.Join(repo, ".worktreeinclude"), []byte(".env.testing\nREADME\nnotes.txt\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "notes.txt"), []byte("untracked, not ignored"), 0o644)
	got := worktreeIncludes(context.Background(), repo, repo)
	if strings.Join(got, ",") != ".env.testing" {
		t.Fatalf("worktreeIncludes = %v", got)
	}
}

// On a machine with a team, root's base for the project lies under the
// box's own: its recipe and files apply unless the box has its own.
func TestTheTeamsBaseLiesUnderTheBoxsOwn(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	repo := baseRepo(t)
	bx, do, ch := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	key, err := bx.Locations.BaseKey(context.Background(), "cal")
	if err != nil || !strings.HasPrefix(key, "local-") {
		t.Fatalf("key = %q %v", key, err)
	}
	team := t.TempDir()
	settings := filepath.Join(t.TempDir(), "team.json")
	os.WriteFile(settings, []byte(`{"dir":"`+team+`","group":"pier"}`), 0o644)
	old := teamSettingsPath
	teamSettingsPath = settings
	t.Cleanup(func() { teamSettingsPath = old })
	proj := filepath.Join(team, "projects", key)
	publish := func(files map[string]string, cfg string) {
		os.RemoveAll(proj)
		os.MkdirAll(filepath.Join(proj, "files"), 0o755)
		pub := teamPublished{At: time.Now().UTC().Truncate(time.Second), Files: map[string]teamFileMeta{}}
		for p, content := range files {
			os.MkdirAll(filepath.Dir(filepath.Join(proj, "files", p)), 0o755)
			os.WriteFile(filepath.Join(proj, "files", p), []byte(content), 0o640)
			pub.Files[p] = teamFileMeta{SHA: sha256Hex([]byte(content)), Size: int64(len(content))}
		}
		if cfg != "" {
			os.WriteFile(filepath.Join(proj, "config.json"), []byte(cfg), 0o640)
			pub.Config = sha256Hex([]byte(cfg))
		}
		data, _ := json.Marshal(pub)
		os.WriteFile(filepath.Join(proj, "published.json"), data, 0o640)
		bx.teamSynced.Delete(key)
	}
	publish(map[string]string{".env": "APP_KEY=team\n", "storage/oauth-private.key": "KEY"},
		`{"setup": "echo team > recipe.txt", "base": {"carry": ["vendor"]}, "prepare_with": "agent", "hooks": [{"on": "worktree.created", "run": "touch /tmp/x"}]}`)
	var view BaseView
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Team == nil || view.Team.Published == nil || view.Recipe == nil || view.Recipe.From != "team" || len(view.Files) != 2 || view.Files[0].From != "team" {
		t.Fatalf("base with the team's = %+v (team %+v)", view, view.Team)
	}
	cfg, _ := bx.Locations.Config(context.Background(), "cal")
	if cfg.Effective.PrepareWith != "" || len(cfg.Effective.Hooks) != 0 {
		t.Fatalf("the team gave a person's consent or a hook: %+v", cfg.Effective)
	}
	var wt Worktree
	do("POST", "/v1/locations/cal/worktrees", map[string]any{"name": "team-made"}, &wt)
	waitFor(t, ch, "worktree.prepare.finished")
	if readFile(t, filepath.Join(wt.Path, "recipe.txt")) != "team\n" || readFile(t, filepath.Join(wt.Path, ".env")) != "APP_KEY=team\n" {
		t.Fatal("the team's recipe or files did not apply")
	}
	if _, err := os.Stat(filepath.Join(wt.Path, "vendor", "autoload.php")); err != nil {
		t.Fatalf("the team's carry did not apply: %v", err)
	}
	// The box's own file and recipe win over the team's.
	do("POST", "/v1/locations/cal/base/files", map[string]string{"path": ".env"}, nil)
	bx.Locations.MergeLocalConfig("cal", RepoConfig{Setup: "echo mine > recipe.txt"})
	view = BaseView{}
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Recipe.From != "box" || view.Files[0].From != "box" || len(view.Warnings) == 0 {
		t.Fatalf("base with the box's own = %+v", view)
	}
	if code := do("DELETE", "/v1/locations/cal/base/files?path=storage/oauth-private.key", nil, nil); code != 409 {
		t.Fatalf("removing the team's file = %d", code)
	}
	// Root takes the project's base away: the box forgets it.
	os.RemoveAll(proj)
	bx.teamSynced.Delete(key)
	view = BaseView{}
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Team != nil || len(view.Files) != 1 {
		t.Fatalf("after the team's base went = %+v", view)
	}
	if cfg, _ := bx.Locations.Config(context.Background(), "cal"); cfg.Team != nil {
		t.Fatal("the team's config stayed")
	}
}

// A published file that is not the one root published (a copy caught half
// way) is not taken: the last copy stays.
func TestATeamFileThatIsNotThePublishedOneIsNotTaken(t *testing.T) {
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	key, _ := bx.Locations.BaseKey(context.Background(), "cal")
	team := t.TempDir()
	settings := filepath.Join(t.TempDir(), "team.json")
	os.WriteFile(settings, []byte(`{"dir":"`+team+`"}`), 0o644)
	old := teamSettingsPath
	teamSettingsPath = settings
	t.Cleanup(func() { teamSettingsPath = old })
	proj := filepath.Join(team, "projects", key)
	os.MkdirAll(filepath.Join(proj, "files"), 0o755)
	os.WriteFile(filepath.Join(proj, "files", ".env"), []byte("HALF"), 0o640)
	pub, _ := json.Marshal(teamPublished{At: time.Now(), Files: map[string]teamFileMeta{".env": {SHA: sha256Hex([]byte("WHOLE")), Size: 5}}})
	os.WriteFile(filepath.Join(proj, "published.json"), pub, 0o640)
	var view BaseView
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Team == nil || !strings.Contains(view.Team.Error, "not the one published") || len(view.Files) != 0 {
		t.Fatalf("a half-copied team file = %+v %+v", view, view.Team)
	}
}

// A setup agent's run that is still putting the base in place has no
// session yet: it is not taken for one whose session vanished.
func TestASetupAgentPuttingTheBaseInPlaceIsNotTakenForAVanishedOne(t *testing.T) {
	bx, _, _ := baseBox(t)
	key := prepKey("cal", "slow")
	old := time.Now().Add(-time.Hour)
	bx.preps().update(key, func(r *prepRecord) {
		r.State, r.Kind, r.Session, r.Since, r.Step = "running", "agent", "cal-slow-setup", &old, "carry"
	})
	bx.settleVanished(context.Background(), key)
	if r, _ := bx.preps().get(key); r.State != "running" {
		t.Fatalf("a run carrying folders was settled: %+v", r)
	}
}

func TestABaseKeyIsTheRepositorysOwnerAndName(t *testing.T) {
	for slug, want := range map[string]string{
		"Acme-Corp/Sales42":    "acme-corp__sales42",
		"octo-org/shop.api":    "octo-org__shop.api",
		"":                     "local-" + envKey("shop"),
		"weird/name/with/more": "local-" + envKey("shop"),
	} {
		if got := baseKeyFor(slug, "shop"); got != want {
			t.Errorf("baseKeyFor(%q) = %q, want %q", slug, got, want)
		}
	}
}

// A clone of a project the team has a recipe for runs the team's recipe:
// pierd's guess from the files is not saved over it.
func TestACloneOfATeamProjectRunsTheTeamsRecipe(t *testing.T) {
	repo := baseRepo(t)
	os.WriteFile(filepath.Join(repo, "package-lock.json"), []byte("{}"), 0o644)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	bx.Locations.SetTeam("cal", &RepoConfig{Setup: "make team-setup"}, nil)
	how, err := bx.prepareLocation(context.Background(), "cal")
	if err != nil || how != "team" {
		t.Fatalf("prepareLocation = %q %v", how, err)
	}
	if cfg, _ := bx.Locations.Config(context.Background(), "cal"); cfg.Local.Setup != "" || cfg.Effective.Setup != "make team-setup" {
		t.Fatalf("config = %+v", cfg)
	}
}

// The setup agent hears what the base put in place, and that its recipe
// only brings that up to date.
func TestTheSetupAgentHearsWhatTheBasePutInPlace(t *testing.T) {
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	ctx := context.Background()
	wt, _ := bx.Locations.CreateWorktree(ctx, "cal", "agent", "", "")
	loc, _ := bx.Locations.Get(ctx, "cal")
	bx.recordBase("cal", "agent", func(r *BaseReport) {
		r.Files = []BaseResult{{Path: ".env", Action: "written"}, {Path: "auth.json", Action: "skipped"}}
		r.Carried = []BaseResult{{Path: "vendor", Action: "carried"}}
	})
	s, err := bx.setupPrompt(ctx, loc, wt, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"put these untracked files here: `.env`.", "copied from the main checkout: `vendor`.", "no npm ci", "the script only brings what is there up to date"} {
		if !strings.Contains(s, want) {
			t.Errorf("prompt lacks %q", want)
		}
	}
}

// useTeam points the box at a team folder of its own and returns what
// publishes a project's base in it as root does: files, a config, then
// published.json last.
func useTeam(t *testing.T) (dir string, publish func(key string, files map[string]string, cfg string)) {
	t.Helper()
	dir = t.TempDir()
	settings := filepath.Join(t.TempDir(), "team.json")
	os.WriteFile(settings, []byte(`{"dir":"`+dir+`","group":"pier"}`), 0o644)
	old := teamSettingsPath
	teamSettingsPath = settings
	t.Cleanup(func() { teamSettingsPath = old })
	return dir, func(key string, files map[string]string, cfg string) {
		proj := filepath.Join(dir, "projects", key)
		os.RemoveAll(proj)
		os.MkdirAll(filepath.Join(proj, "files"), 0o755)
		pub := teamPublished{At: time.Now().UTC(), Files: map[string]teamFileMeta{}}
		for p, content := range files {
			os.MkdirAll(filepath.Dir(filepath.Join(proj, "files", p)), 0o755)
			os.WriteFile(filepath.Join(proj, "files", p), []byte(content), 0o640)
			pub.Files[p] = teamFileMeta{SHA: sha256Hex([]byte(content)), Size: int64(len(content))}
		}
		if cfg != "" {
			os.WriteFile(filepath.Join(proj, "config.json"), []byte(cfg), 0o640)
			pub.Config = sha256Hex([]byte(cfg))
		}
		data, _ := json.Marshal(pub)
		os.WriteFile(filepath.Join(proj, "published.json"), data, 0o640)
	}
}

// Two clones of one repository share its base and the box's copy of the
// team's: each takes the team's config, not only the first to copy it.
func TestTwoClonesOfOneRepositoryBothTakeTheTeamsBase(t *testing.T) {
	repo := baseRepo(t)
	other := filepath.Join(filepath.Dir(repo), "cal-clone")
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
	do("POST", "/v1/locations", map[string]string{"name": "cal2", "path": other}, nil)
	ctx := context.Background()
	k1, _ := bx.Locations.BaseKey(ctx, "cal")
	k2, _ := bx.Locations.BaseKey(ctx, "cal2")
	if k1 != "acme__cal" || k2 != k1 {
		t.Fatalf("keys = %q, %q", k1, k2)
	}
	_, publish := useTeam(t)
	publish(k1, map[string]string{".env": "APP_KEY=team\n"}, `{"setup": "echo team"}`)
	for _, loc := range []string{"cal", "cal2"} {
		var view BaseView
		do("GET", "/v1/locations/"+loc+"/base", nil, &view)
		cfg, _ := bx.Locations.Config(ctx, loc)
		if view.Team == nil || cfg.Team == nil || cfg.Effective.Setup != "echo team" {
			t.Fatalf("%s did not take the team's base: %+v, config %+v", loc, view.Team, cfg.Team)
		}
	}
}

// Syncs of one base that run at once (a worktree made while the app reads
// the base) never leave the copy missing a file.
func TestSyncsOfOneBaseAtOnceLeaveAWholeCopy(t *testing.T) {
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	ctx := context.Background()
	key, _ := bx.Locations.BaseKey(ctx, "cal")
	_, publish := useTeam(t)
	files := map[string]string{}
	for i := range 30 {
		files[fmt.Sprintf("storage/keys/k%02d.key", i)] = strings.Repeat("k", 2000+i)
	}
	for round := range 5 {
		files[".env"] = fmt.Sprintf("ROUND=%d\n", round)
		publish(key, files, "")
		var wg sync.WaitGroup
		for range 8 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				bx.teamSynced.Delete(key)
				bx.syncTeam(ctx, "cal")
			}()
		}
		wg.Wait()
		got := bx.lockedBaseFiles(key)
		if len(got) != len(files) {
			t.Fatalf("round %d: the copy has %d files, want %d", round, len(got), len(files))
		}
		for _, f := range got {
			if data, err := os.ReadFile(f.Source); err != nil || string(data) != files[f.Path] {
				t.Fatalf("round %d: %s = %q, %v", round, f.Path, data, err)
			}
		}
	}
	if stale, _ := filepath.Glob(filepath.Join(bx.baseDir(key), "team.*")); len(stale) > 0 {
		t.Fatalf("copies left behind: %v", stale)
	}
}

// Team settings that cannot be read (root writing them, a typo) keep what
// was copied: only a machine with no settings has no team.
func TestUnreadableTeamSettingsKeepTheCopy(t *testing.T) {
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	ctx := context.Background()
	key, _ := bx.Locations.BaseKey(ctx, "cal")
	_, publish := useTeam(t)
	publish(key, map[string]string{".env": "APP_KEY=team\n"}, `{"setup": "echo team"}`)
	var view BaseView
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Team == nil || len(view.Files) != 1 {
		t.Fatalf("before = %+v", view)
	}
	os.WriteFile(teamSettingsPath, []byte(`{"dir": `), 0o644)
	bx.teamSynced.Delete(key)
	view = BaseView{}
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Team == nil || !strings.Contains(view.Team.Error, "settings cannot be read") || len(view.Files) != 1 {
		t.Fatalf("with unreadable settings = %+v (team %+v)", view, view.Team)
	}
	if cfg, _ := bx.Locations.Config(ctx, "cal"); cfg.Team == nil {
		t.Fatal("the team's config was dropped")
	}
	os.Remove(teamSettingsPath)
	view = BaseView{}
	do("GET", "/v1/locations/cal/base", nil, &view)
	if view.Team != nil || len(view.Files) != 0 {
		t.Fatalf("with no settings = %+v", view)
	}
}

// A folder carried into a worktree never lands outside it through a link
// someone made there.
func TestACarriedFolderNeverFollowsALinkOutOfTheWorktree(t *testing.T) {
	repo := baseRepo(t)
	wt := filepath.Join(filepath.Dir(repo), "cal-linked")
	if out, err := exec.Command("git", "-C", repo, "worktree", "add", "-q", "-b", "linked", wt).CombinedOutput(); err != nil {
		t.Fatalf("git worktree add: %s", out)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(wt, "vendor")); err != nil {
		t.Fatal(err)
	}
	res := carryOne(context.Background(), repo, wt, "vendor/acme")
	if res.Action != "skipped" || !strings.Contains(res.Reason, "leads out of this worktree") {
		t.Fatalf("carried through a link: %+v", res)
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Fatalf("written outside the worktree: %v", entries)
	}
}

// A file pierd was writing when it stopped is never offered for a commit,
// and a checkout git cannot read gets no base file.
func TestPierdsTemporaryFilesStayOutOfCommits(t *testing.T) {
	repo := baseRepo(t)
	bx, do, _ := baseBox(t)
	do("POST", "/v1/locations", map[string]string{"name": "cal", "path": repo}, nil)
	do("POST", "/v1/locations/cal/base/files", map[string]string{"path": ".env"}, nil)
	os.Remove(filepath.Join(repo, ".env"))
	loc, _ := bx.Locations.Get(context.Background(), "cal")
	main := loc.Worktrees[0]
	for _, r := range bx.applyBaseFiles(context.Background(), loc, main, nil) {
		if r.Action != "written" {
			t.Fatalf("applied = %+v", r)
		}
	}
	os.MkdirAll(filepath.Join(repo, "config"), 0o755)
	os.WriteFile(filepath.Join(repo, "config", tempPrefix+"0badf00d"), []byte("SECRET=1"), 0o600)
	out, err := exec.Command("git", "-C", repo, "status", "--porcelain", "--untracked-files=all").CombinedOutput()
	if err != nil || strings.Contains(string(out), tempPrefix) {
		t.Fatalf("git status = %s %v", out, err)
	}
	if _, err := gitTracks(context.Background(), t.TempDir(), ".env"); err == nil {
		t.Fatal("git answered outside a repository")
	}
}
