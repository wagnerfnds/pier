package box

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"pier/pierd/internal/events"
	"pier/pierd/internal/hooks"
	"pier/pierd/internal/wire"
)

// filesBox serves a box with one location, cal, whose main checkout has a
// bit of everything the file routes tell apart. out is a folder outside it
// that a link leads to.
func filesBox(t *testing.T, opts ...func(*Box)) (c *wire.Client, bus *events.Bus, repo, out string) {
	t.Helper()
	c, bus = servedBox(t, opts...)
	repo = gitRepo(t)
	out = t.TempDir()
	put := func(rel, content string) {
		t.Helper()
		p := filepath.Join(repo, filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put(".gitignore", "node_modules/\n*.log\n")
	put(".editorconfig", "root = true\n")
	put("src/main.go", "package main\n")
	put("src/lib/util.go", "package lib\n")
	put("docs/guide.md", "# Guide\n")
	put("Zeta.txt", "z\n")
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "commit", "-q", "-m", "files")

	put("README", "hi there\n")                            // modified
	put("src/lib/util.go", "package lib\n\nfunc U() {}\n") // a change two folders down
	put("src/main.go", "package main\n\nfunc main() {}\n")
	gitIn(t, repo, "add", "src/main.go") // staged
	put("notes.txt", "todo\n")           // untracked
	put("debug.log", "trace\n")          // ignored
	put("node_modules/pkg/index.js", "module.exports = 1\n")
	os.WriteFile(filepath.Join(out, "secret.txt"), []byte("not yours\n"), 0o644)
	for link, target := range map[string]string{"shared": "src/lib", "readme-link": "README", "out": out, "gone": "nowhere"} {
		if err := os.Symlink(target, filepath.Join(repo, link)); err != nil {
			t.Fatal(err)
		}
	}
	if st := call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil); st != 200 {
		t.Fatalf("add location: %d", st)
	}
	return c, bus, repo, out
}

// fileRoute is a file route ("files" or "file") of cal's worktree wt, for
// path p.
func fileRoute(route, wt, p string) string {
	return "/v1/locations/cal/worktrees/" + wt + "/" + route + "?path=" + url.QueryEscape(p)
}

func sha256Of(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func entriesByName(l DirListing) (names []string, byName map[string]FileEntry) {
	byName = map[string]FileEntry{}
	for _, e := range l.Entries {
		names = append(names, e.Name)
		byName[e.Name] = e
	}
	return names, byName
}

func TestListingAWorktreesRootGivesGitsWordOnEachEntry(t *testing.T) {
	c, _, _, _ := filesBox(t)
	var l DirListing
	if st := call(t, c, "GET", "/v1/locations/cal/worktrees/cal/files", "", nil, &l); st != 200 {
		t.Fatalf("list the root: %d", st)
	}
	names, e := entriesByName(l)
	// Folders and links to folders first, then the rest, each whatever the
	// case of their names; .git never, dotfiles always.
	want := []string{"docs", "node_modules", "shared", "src", ".editorconfig", ".gitignore", "debug.log", "gone", "notes.txt", "out", "README", "readme-link", "Zeta.txt"}
	if l.Path != "" || l.Truncated || !slices.Equal(names, want) {
		t.Fatalf("root = %q (truncated %v) %v, want %v", l.Path, l.Truncated, names, want)
	}
	for name, want := range map[string]FileEntry{
		"README":        {Name: "README", Type: "file", Size: 9, Status: " M"},
		"notes.txt":     {Name: "notes.txt", Type: "file", Size: 5, Status: "??"},
		"debug.log":     {Name: "debug.log", Type: "file", Size: 6, Ignored: true},
		".gitignore":    {Name: ".gitignore", Type: "file", Size: 20},
		"Zeta.txt":      {Name: "Zeta.txt", Type: "file", Size: 2},
		"src":           {Name: "src", Type: "dir", Changed: true},
		"docs":          {Name: "docs", Type: "dir"},
		"node_modules":  {Name: "node_modules", Type: "dir", Ignored: true},
		"shared":        {Name: "shared", Type: "link", Status: "??", Target: "src/lib", Points: "dir"},
		"readme-link":   {Name: "readme-link", Type: "link", Status: "??", Target: "README", Points: "file"},
		"gone":          {Name: "gone", Type: "link", Status: "??", Target: "nowhere"},
		".editorconfig": {Name: ".editorconfig", Type: "file", Size: 12},
	} {
		if e[name] != want {
			t.Errorf("%s = %+v, want %+v", name, e[name], want)
		}
	}
	if out := e["out"]; out.Type != "link" || out.Points != "" || out.Target == "" {
		t.Errorf("a link out of the worktree = %+v, want no points", out)
	}
}

func TestListingAFolderBelowTheRoot(t *testing.T) {
	c, _, _, _ := filesBox(t)
	for _, p := range []string{"src", "src/", "./src"} {
		var l DirListing
		if st := call(t, c, "GET", fileRoute("files", "cal", p), "", nil, &l); st != 200 {
			t.Fatalf("list %q: %d", p, st)
		}
		names, e := entriesByName(l)
		if l.Path != "src" || !slices.Equal(names, []string{"lib", "main.go"}) {
			t.Fatalf("%q = %q %v", p, l.Path, names)
		}
		if lib, main := e["lib"], e["main.go"]; !lib.Changed || lib.Status != "" || main.Status != "M " || main.Size != int64(len("package main\n\nfunc main() {}\n")) {
			t.Fatalf("%q: lib %+v, main.go %+v", p, lib, main)
		}
	}
	// Through a link, git is asked about where the folder really is.
	var l DirListing
	if st := call(t, c, "GET", fileRoute("files", "cal", "shared"), "", nil, &l); st != 200 {
		t.Fatalf("list through a link: %d", st)
	}
	if _, e := entriesByName(l); l.Path != "shared" || e["util.go"].Status != " M" {
		t.Fatalf("shared = %q %+v", l.Path, l.Entries)
	}
	// Inside an ignored folder, everything is.
	for _, p := range []string{"node_modules", "node_modules/pkg"} {
		l = DirListing{}
		call(t, c, "GET", fileRoute("files", "cal", p), "", nil, &l)
		if len(l.Entries) != 1 || !l.Entries[0].Ignored {
			t.Fatalf("%s = %+v, want its one entry ignored", p, l.Entries)
		}
	}
}

func TestAnUntrackedFolderIsNewThroughout(t *testing.T) {
	c, _, repo, _ := filesBox(t)
	os.MkdirAll(filepath.Join(repo, "draft", "deep"), 0o755)
	os.WriteFile(filepath.Join(repo, "draft", "plan.md"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(repo, "draft", "run.log"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(repo, "draft", "deep", "a.txt"), []byte("x"), 0o644)
	var root DirListing
	call(t, c, "GET", fileRoute("files", "cal", ""), "", nil, &root)
	if _, e := entriesByName(root); !e["draft"].Changed {
		t.Fatalf("draft = %+v, want changed", e["draft"])
	}
	var l DirListing
	call(t, c, "GET", fileRoute("files", "cal", "draft"), "", nil, &l)
	_, e := entriesByName(l)
	if !e["deep"].Changed || e["plan.md"].Status != "??" || !e["run.log"].Ignored || e["run.log"].Status != "" {
		t.Fatalf("draft's entries = %+v", l.Entries)
	}
}

func TestAListingStopsAtItsLimit(t *testing.T) {
	c, _, _, _ := filesBox(t)
	defer func(n int) { maxDirEntries = n }(maxDirEntries)
	maxDirEntries = 2
	var l DirListing
	call(t, c, "GET", fileRoute("files", "cal", ""), "", nil, &l)
	if names, _ := entriesByName(l); !l.Truncated || !slices.Equal(names, []string{"docs", "node_modules"}) {
		t.Fatalf("listing = %v (truncated %v), want the first two and truncated", names, l.Truncated)
	}
}

func TestEntriesSortFoldersFirstThenByNameWhateverItsCase(t *testing.T) {
	entries := []FileEntry{
		{Name: "b", Type: "file"}, {Name: "B", Type: "file"}, {Name: "x", Type: "link", Points: "file"},
		{Name: "a", Type: "other"}, {Name: "Z", Type: "dir"}, {Name: "y", Type: "link", Points: "dir"},
		{Name: "w", Type: "link"},
	}
	sortEntries(entries)
	var names []string
	for _, e := range entries {
		names = append(names, e.Name)
	}
	if want := []string{"y", "Z", "a", "B", "b", "w", "x"}; !slices.Equal(names, want) {
		t.Fatalf("order = %v, want %v", names, want)
	}
}

func TestPathsStayInsideTheWorktreeAndOutOfGit(t *testing.T) {
	c, _, repo, out := filesBox(t)
	os.Symlink(".git", filepath.Join(repo, "gitdir"))
	for _, p := range []string{"../cal", "src/../README", "/etc", ".git", ".git/config", "src/.GIT/HEAD", "out", "out/secret.txt", "gitdir", "gitdir/config", "a\x00b"} {
		for _, route := range []string{"files", "file"} {
			var e struct{ Error, Code string }
			if st := call(t, c, "GET", fileRoute(route, "cal", p), "", nil, &e); st != 400 || e.Code != CodeBadRequest {
				t.Errorf("%s %q = %d %+v, want a 400", route, p, st, e)
			}
		}
		var e struct{ Error, Code string }
		if st := call(t, c, "PUT", fileRoute("file", "cal", p), "", FileWrite{Content: "x", Create: true, Force: true}, &e); st != 400 {
			t.Errorf("write %q = %d %+v, want a 400", p, st, e)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(out, "secret.txt")); string(b) != "not yours\n" {
		t.Fatalf("a write reached outside the worktree: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, ".git", "config")); strings.TrimSpace(string(b)) == "x" {
		t.Fatal("a write reached .git")
	}
}

func TestMissingPathsAndTheWrongKindOfEntry(t *testing.T) {
	c, _, _, _ := filesBox(t)
	for _, tc := range []struct {
		route, path string
		status      int
		code        string
	}{
		{"files", "nope", 404, CodeNotFound},
		{"file", "nope.txt", 404, CodeNotFound},
		{"file", "src/nope.go", 404, CodeNotFound},
		{"file", "gone", 404, CodeNotFound},
		{"files", "README", 400, CodeBadRequest},
		{"file", "src", 400, CodeBadRequest},
		{"file", "", 400, CodeBadRequest},
		{"file", "README/x", 400, CodeBadRequest},
	} {
		var e struct{ Error, Code string }
		if st := call(t, c, "GET", fileRoute(tc.route, "cal", tc.path), "", nil, &e); st != tc.status || e.Code != tc.code || e.Error == "" {
			t.Errorf("%s %q = %d %+v, want %d %s", tc.route, tc.path, st, e, tc.status, tc.code)
		}
	}
	if st := call(t, c, "GET", "/v1/locations/cal/worktrees/nope/files", "", nil, nil); st != 404 {
		t.Errorf("an unknown worktree = %d", st)
	}
	if st := call(t, c, "GET", "/v1/locations/nope/worktrees/cal/file?path=README", "", nil, nil); st != 404 {
		t.Errorf("an unknown location = %d", st)
	}
}

func TestReadingTextBinaryAndJustTheMetadata(t *testing.T) {
	c, _, repo, _ := filesBox(t)
	os.WriteFile(filepath.Join(repo, "logo.bin"), []byte{0, 1, 2, 0xff}, 0o644)
	os.WriteFile(filepath.Join(repo, "latin1.txt"), []byte{'c', 'a', 'f', 0xe9}, 0o644)
	os.WriteFile(filepath.Join(repo, "empty.txt"), nil, 0o644)
	os.WriteFile(filepath.Join(repo, "run.sh"), []byte("#!/bin/sh\n"), 0o755)

	var f WorktreeFile
	if st := call(t, c, "GET", fileRoute("file", "cal", "src/main.go"), "", nil, &f); st != 200 {
		t.Fatalf("read: %d", st)
	}
	text := "package main\n\nfunc main() {}\n"
	st, _ := os.Stat(filepath.Join(repo, "src", "main.go"))
	if f.Path != "src/main.go" || f.Size != int64(len(text)) || f.SHA != sha256Of(text) || f.Binary || f.Executable || f.TooLarge ||
		f.Encoding != "utf8" || f.Content == nil || *f.Content != text || !f.Modified.Equal(st.ModTime()) {
		t.Fatalf("text file = %+v", f)
	}

	f = WorktreeFile{}
	call(t, c, "GET", fileRoute("file", "cal", "logo.bin"), "", nil, &f)
	if !f.Binary || f.Encoding != "base64" || f.Content == nil || *f.Content != base64.StdEncoding.EncodeToString([]byte{0, 1, 2, 0xff}) {
		t.Fatalf("binary file = %+v", f)
	}
	f = WorktreeFile{}
	call(t, c, "GET", fileRoute("file", "cal", "latin1.txt"), "", nil, &f)
	if !f.Binary || f.Encoding != "base64" {
		t.Fatalf("a file that isn't UTF-8 = %+v, want it as binary", f)
	}
	f = WorktreeFile{}
	call(t, c, "GET", fileRoute("file", "cal", "empty.txt"), "", nil, &f)
	if f.Encoding != "utf8" || f.Content == nil || *f.Content != "" || f.SHA != sha256Of("") {
		t.Fatalf("empty file = %+v, want an empty content", f)
	}
	f = WorktreeFile{}
	call(t, c, "GET", fileRoute("file", "cal", "run.sh"), "", nil, &f)
	if !f.Executable {
		t.Fatalf("script = %+v, want executable", f)
	}
	// A link to a file in the worktree reads as that file.
	f = WorktreeFile{}
	call(t, c, "GET", fileRoute("file", "cal", "readme-link"), "", nil, &f)
	if f.Path != "readme-link" || f.Content == nil || *f.Content != "hi there\n" {
		t.Fatalf("through a link = %+v", f)
	}

	// stat=1: everything but the content.
	f = WorktreeFile{}
	call(t, c, "GET", fileRoute("file", "cal", "src/main.go")+"&stat=1", "", nil, &f)
	if f.SHA != sha256Of(text) || f.Size != int64(len(text)) || f.Content != nil || f.Encoding != "" || f.Modified.IsZero() {
		t.Fatalf("stat = %+v, want the metadata without content", f)
	}
}

func TestAFileTheBoxsUserMayNotReadIsRefused(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads anything")
	}
	c, _, repo, _ := filesBox(t)
	locked := filepath.Join(repo, "locked.txt")
	os.WriteFile(locked, []byte("x"), 0o000)
	defer os.Chmod(locked, 0o644)
	var e struct{ Error, Code string }
	if st := call(t, c, "GET", fileRoute("file", "cal", "locked.txt"), "", nil, &e); st != 403 || e.Code != CodeRefused {
		t.Fatalf("an unreadable file = %d %+v, want a 403", st, e)
	}
}

func TestATooLargeFileComesWithoutItsContent(t *testing.T) {
	c, _, repo, _ := filesBox(t)
	defer func(n int64) { maxFileContent = n }(maxFileContent)
	maxFileContent = 16
	big := strings.Repeat("0123456789", 10)
	os.WriteFile(filepath.Join(repo, "big.txt"), []byte(big), 0o644)
	for _, q := range []string{"", "&stat=1"} {
		var f WorktreeFile
		if st := call(t, c, "GET", fileRoute("file", "cal", "big.txt")+q, "", nil, &f); st != 200 {
			t.Fatalf("read%s: %d", q, st)
		}
		// The sha is still the whole file's: a save can name it.
		if !f.TooLarge || f.Size != 100 || f.SHA != sha256Of(big) || f.Content != nil || f.Encoding != "" {
			t.Fatalf("too large%s = %+v", q, f)
		}
	}
}

func TestSavingAFileTheEditStartedFrom(t *testing.T) {
	c, bus, repo, _ := filesBox(t)
	seen, stop := bus.Subscribe()
	defer stop()
	readme := filepath.Join(repo, "README")
	os.Chmod(readme, 0o755)
	var before WorktreeFile
	call(t, c, "GET", fileRoute("file", "cal", "README"), "", nil, &before)

	var f WorktreeFile
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "ios", FileWrite{Content: "hello\n", SHA: before.SHA}, &f); st != 200 {
		t.Fatalf("save: %d", st)
	}
	if f.Path != "README" || f.SHA != sha256Of("hello\n") || f.Size != 6 || f.Content != nil || !f.Executable {
		t.Fatalf("save answered %+v", f)
	}
	if b, _ := os.ReadFile(readme); string(b) != "hello\n" {
		t.Fatalf("README = %q", b)
	}
	if st, _ := os.Stat(readme); st.Mode().Perm() != 0o755 {
		t.Fatalf("mode = %v, want the file's own 0755", st.Mode().Perm())
	}
	e := waitFor(t, seen, "file.written")
	// "path" is the worktree's folder, as in every event; "file" the file in it.
	if e.Origin != "ios" || e.Data["location"] != "cal" || e.Data["worktree"] != "cal" || e.Data["file"] != "README" || e.Data["size"] != 6 {
		t.Fatalf("event = %+v", e)
	}
	if p, _ := e.Data["path"].(string); p == "" || !filepath.IsAbs(p) {
		t.Fatalf("event path = %v, want the worktree's folder", e.Data["path"])
	}
	// Nothing but the file itself is left in its folder.
	if left, _ := filepath.Glob(filepath.Join(repo, ".README.pier-*")); len(left) != 0 {
		t.Fatalf("temp files left: %v", left)
	}

	// The old sha is stale now: an agent's save in between would be lost.
	var conflict struct{ Error, Code string }
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: "mine\n", SHA: before.SHA}, &conflict); st != 409 || conflict.Code != CodeFileChanged {
		t.Fatalf("a stale save = %d %+v", st, conflict)
	}
	if b, _ := os.ReadFile(readme); string(b) != "hello\n" {
		t.Fatalf("a refused save wrote %q", b)
	}
	// Unless the person chose to overwrite it.
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: "mine\n", SHA: before.SHA, Force: true}, &f); st != 200 || f.SHA != sha256Of("mine\n") {
		t.Fatalf("a forced save = %d %+v", st, f)
	}

	// A file deleted since it was opened is a change too.
	os.Remove(readme)
	conflict.Code = ""
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: "back\n", SHA: f.SHA}, &conflict); st != 409 || conflict.Code != CodeFileChanged || !strings.Contains(conflict.Error, "deleted") {
		t.Fatalf("a save of a deleted file = %d %+v", st, conflict)
	}
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: "back\n"}, nil); st != 404 {
		t.Fatalf("a save of a missing file without create = %d, want 404", st)
	}
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: "back\n", SHA: f.SHA, Force: true}, nil); st != 200 {
		t.Fatalf("a forced save of a deleted file = %d", st)
	}
	if b, _ := os.ReadFile(readme); string(b) != "back\n" {
		t.Fatalf("README = %q", b)
	}
}

func TestCreatingFilesAndWhatASaveRefuses(t *testing.T) {
	c, _, repo, _ := filesBox(t)
	var f WorktreeFile
	if st := call(t, c, "PUT", fileRoute("file", "cal", "new/deeper/idea.md"), "", FileWrite{Content: "# Idea\n", Create: true}, &f); st != 200 {
		t.Fatalf("create: %d", st)
	}
	path := filepath.Join(repo, "new", "deeper", "idea.md")
	if st, err := os.Stat(path); err != nil || st.Mode().Perm() != 0o644 || f.SHA != sha256Of("# Idea\n") {
		t.Fatalf("created %+v: %v %+v", st, err, f)
	}
	var e struct{ Error, Code string }
	if st := call(t, c, "PUT", fileRoute("file", "cal", "new/deeper/idea.md"), "", FileWrite{Content: "again\n", Create: true}, &e); st != 409 || e.Code != CodeFileExists {
		t.Fatalf("create over a file = %d %+v", st, e)
	}
	if st := call(t, c, "PUT", fileRoute("file", "cal", "new/deeper/idea.md"), "", FileWrite{Content: "again\n", Create: true, Force: true}, nil); st != 200 {
		t.Fatalf("a forced create over a file = %d", st)
	}

	// Bytes as base64, read back the same.
	if st := call(t, c, "PUT", fileRoute("file", "cal", "blob.bin"), "", FileWrite{Content: "AAEC", Encoding: "base64", Create: true}, &f); st != 200 || !f.Binary {
		t.Fatalf("a binary save = %d %+v", st, f)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "blob.bin")); string(b) != "\x00\x01\x02" {
		t.Fatalf("blob.bin = %q", b)
	}

	// Through a link to a file in the worktree, the file it leads to
	// changes and the link stays one.
	var readme WorktreeFile
	call(t, c, "GET", fileRoute("file", "cal", "readme-link"), "", nil, &readme)
	if st := call(t, c, "PUT", fileRoute("file", "cal", "readme-link"), "", FileWrite{Content: "via the link\n", SHA: readme.SHA}, nil); st != 200 {
		t.Fatalf("save through a link: %d", st)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "README")); string(b) != "via the link\n" {
		t.Fatalf("README = %q", b)
	}
	if st, err := os.Lstat(filepath.Join(repo, "readme-link")); err != nil || st.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the save replaced the link with a file")
	}
	// A new file through a link to a folder lands in that folder.
	if st := call(t, c, "PUT", fileRoute("file", "cal", "shared/extra.go"), "", FileWrite{Content: "package lib\n", Create: true}, nil); st != 200 {
		t.Fatalf("create through a link: %d", st)
	}
	if _, err := os.Stat(filepath.Join(repo, "src", "lib", "extra.go")); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		path string
		req  FileWrite
	}{
		{"src", FileWrite{Content: "x", Force: true}},
		{"src/main.go/x", FileWrite{Content: "x", Create: true}},
		{"x.txt", FileWrite{Content: "x", Encoding: "latin1", Create: true}},
		{"x.txt", FileWrite{Content: "not base64!", Encoding: "base64", Create: true}},
		{"", FileWrite{Content: "x", Create: true}},
	} {
		e = struct{ Error, Code string }{}
		if st := call(t, c, "PUT", fileRoute("file", "cal", tc.path), "", tc.req, &e); st != 400 || e.Code != CodeBadRequest {
			t.Errorf("save %q %+v = %d %+v, want a 400", tc.path, tc.req, st, e)
		}
	}
	if _, err := os.Stat(filepath.Join(repo, "x.txt")); err == nil {
		t.Fatal("a refused save made x.txt")
	}
	if st := call(t, c, "PUT", fileRoute("file", "cal", "huge.txt"), "", FileWrite{Content: strings.Repeat("x", maxFileWrite), Create: true}, nil); st != 413 {
		t.Fatalf("a body over the limit = %d, want 413", st)
	}
}

func TestABeforeHookGatesSaves(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), "hooks.json")
	os.WriteFile(cfg, []byte(`{"hooks":[{"on":"before:file.write","run":"[ \"$PIER_FILE\" != secret.txt ] || { echo no secrets here; exit 1; }"}]}`), 0o600)
	c, _, repo, _ := filesBox(t, func(b *Box) { b.Hooks = &hooks.Runner{Path: cfg} })
	var e struct{ Error, Code string }
	if st := call(t, c, "PUT", fileRoute("file", "cal", "secret.txt"), "", FileWrite{Content: "x", Create: true}, &e); st != 403 || e.Code != CodeRefused || !strings.Contains(e.Error, "no secrets here") {
		t.Fatalf("a refused save = %d %+v", st, e)
	}
	if _, err := os.Stat(filepath.Join(repo, "secret.txt")); err == nil {
		t.Fatal("the refused file was written")
	}
	if st := call(t, c, "PUT", fileRoute("file", "cal", "public.txt"), "", FileWrite{Content: "x", Create: true}, nil); st != 200 {
		t.Fatalf("an allowed save = %d", st)
	}
	// A link can't take a save around the gate: the gate sees where it lands.
	if err := os.WriteFile(filepath.Join(repo, "secret.txt"), []byte("keep\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("secret.txt", filepath.Join(repo, "innocent.txt")); err != nil {
		t.Fatal(err)
	}
	if st := call(t, c, "PUT", fileRoute("file", "cal", "innocent.txt"), "", FileWrite{Content: "x", Force: true}, &e); st != 403 || e.Code != CodeRefused {
		t.Fatalf("a save through a link to a refused file = %d %+v", st, e)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "secret.txt")); string(b) != "keep\n" {
		t.Fatalf("the gate was gone around: secret.txt = %q", b)
	}
}

// Two saves of the same version take turns: the second is told the file changed.
func TestConcurrentSavesOfOneVersion(t *testing.T) {
	c, _, _, _ := filesBox(t)
	var before WorktreeFile
	call(t, c, "GET", fileRoute("file", "cal", "README"), "", nil, &before)
	codes := make(chan int, 2)
	for _, text := range []string{"one\n", "two\n"} {
		go func() {
			codes <- call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: text, SHA: before.SHA}, nil)
		}()
	}
	a, b := <-codes, <-codes
	if !(a == 200 && b == 409) && !(a == 409 && b == 200) {
		t.Fatalf("two saves of one version = %d and %d, want one 200 and one 409", a, b)
	}
}

// A file with other hard links is written in place, so they keep sharing it.
func TestSavingAHardLinkedFileKeepsTheLink(t *testing.T) {
	c, _, repo, _ := filesBox(t)
	if err := os.Link(filepath.Join(repo, "README"), filepath.Join(repo, "README-too")); err != nil {
		t.Fatal(err)
	}
	var before WorktreeFile
	call(t, c, "GET", fileRoute("file", "cal", "README"), "", nil, &before)
	if st := call(t, c, "PUT", fileRoute("file", "cal", "README"), "", FileWrite{Content: "shared\n", SHA: before.SHA}, nil); st != 200 {
		t.Fatalf("save: %d", st)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "README-too")); string(b) != "shared\n" {
		t.Fatalf("the other link = %q, want the saved text", b)
	}
}

// Two worktrees with one name (one added outside pier) can't be told apart: the
// file routes refuse the name rather than reach the wrong checkout.
func TestAWorktreeNameTwoCheckoutsShareIsRefused(t *testing.T) {
	c, _, repo, _ := filesBox(t)
	twin := filepath.Join(t.TempDir(), filepath.Base(repo))
	gitIn(t, repo, "worktree", "add", "-q", "-b", "twin", twin)
	name := filepath.Base(repo)
	var e struct{ Error, Code string }
	if st := call(t, c, "GET", "/v1/locations/cal/worktrees/"+url.PathEscape(name)+"/files", "", nil, &e); st != 400 || !strings.Contains(e.Error, "are called") {
		t.Fatalf("listing a shared name = %d %+v", st, e)
	}
	if st := call(t, c, "PUT", "/v1/locations/cal/worktrees/"+url.PathEscape(name)+"/file?path=README", "", FileWrite{Content: "x", Force: true}, &e); st != 400 {
		t.Fatalf("saving through a shared name = %d %+v", st, e)
	}
}

// A linked worktree's files are its own, its .git file stays out of sight,
// and a repository's own gate on saves runs in the worktree saved to.
func TestALinkedWorktreesFilesAndTheRepositorysGate(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	marker := filepath.Join(t.TempDir(), "gate-ran-in")
	var bx *Box
	c, _, repo, _ := filesBox(t, func(b *Box) { bx = b })
	writeRepoConfig(t, repo, RepoConfig{Hooks: []hooks.Hook{{On: "before:file.write", Run: "pwd > " + marker}}})
	trustRepo(t, bx.Locations, "cal")
	var wt Worktree
	if st := call(t, c, "POST", "/v1/locations/cal/worktrees", "", WorktreeRequest{Name: "billing"}, &wt); st != 200 {
		t.Fatalf("add worktree: %d", st)
	}
	var l DirListing
	if st := call(t, c, "GET", fileRoute("files", "billing", ""), "", nil, &l); st != 200 {
		t.Fatalf("list billing: %d", st)
	}
	names, _ := entriesByName(l)
	if slices.Contains(names, ".git") || !slices.Contains(names, "src") || slices.Contains(names, "notes.txt") {
		t.Fatalf("billing's root = %v", names)
	}
	if st := call(t, c, "PUT", fileRoute("file", "billing", "src/main.go"), "", FileWrite{Content: "package main\n", Force: true}, nil); st != 200 {
		t.Fatalf("save in billing: %d", st)
	}
	if b, _ := os.ReadFile(filepath.Join(wt.Path, "src", "main.go")); string(b) != "package main\n" {
		t.Fatalf("billing's main.go = %q", b)
	}
	if b, _ := os.ReadFile(marker); strings.TrimSpace(string(b)) != wt.Path {
		t.Fatalf("the repository's gate ran in %q, want %s", b, wt.Path)
	}
}

func TestGitsWordGoesToTheRightEntries(t *testing.T) {
	for _, tc := range []struct {
		name, out, prefix, base string
		entries, want           []FileEntry
	}{{
		name:    "a folder untracked as a whole, with ignored things in it",
		out:     "?? draft/\x00!! draft/build/\x00!! draft/run.log\x00",
		base:    "draft/",
		entries: []FileEntry{{Name: "build", Type: "dir"}, {Name: "deep", Type: "dir"}, {Name: "plan.md", Type: "file"}, {Name: "run.log", Type: "file"}},
		want:    []FileEntry{{Name: "build", Type: "dir", Ignored: true}, {Name: "deep", Type: "dir", Changed: true}, {Name: "plan.md", Type: "file", Status: "??"}, {Name: "run.log", Type: "file", Ignored: true}},
	}, {
		name:    "a rename between folders, an ignored file far down, a submodule",
		out:     "R  b/moved.go\x00a/moved.go\x00!! c/deep/x.log\x00 M sub\x00?? new/\x00",
		entries: []FileEntry{{Name: "a", Type: "dir"}, {Name: "b", Type: "dir"}, {Name: "c", Type: "dir"}, {Name: "new", Type: "dir"}, {Name: "sub", Type: "dir"}},
		want:    []FileEntry{{Name: "a", Type: "dir", Changed: true}, {Name: "b", Type: "dir", Changed: true}, {Name: "c", Type: "dir"}, {Name: "new", Type: "dir", Changed: true}, {Name: "sub", Type: "dir", Changed: true}},
	}, {
		name:    "inside an ignored folder, a file git tracks is not ignored",
		out:     "!! vendor/\x00 M vendor/kept.go\x00",
		base:    "vendor/",
		entries: []FileEntry{{Name: "kept.go", Type: "file"}, {Name: "lib.o", Type: "file"}, {Name: "x", Type: "dir"}},
		want:    []FileEntry{{Name: "kept.go", Type: "file", Status: " M"}, {Name: "lib.o", Type: "file", Ignored: true}, {Name: "x", Type: "dir", Ignored: true}},
	}, {
		name:    "from a folder inside the repository",
		out:     " M pkg/a.go\x00?? pkg/new.go\x00 M other/b.go\x00",
		prefix:  "pkg/",
		entries: []FileEntry{{Name: "a.go", Type: "file"}, {Name: "b.go", Type: "file"}, {Name: "new.go", Type: "file"}},
		want:    []FileEntry{{Name: "a.go", Type: "file", Status: " M"}, {Name: "b.go", Type: "file"}, {Name: "new.go", Type: "file", Status: "??"}},
	}} {
		viewOf([]byte(tc.out), tc.prefix, tc.base).apply(tc.entries)
		if !slices.Equal(tc.entries, tc.want) {
			t.Errorf("%s:\n got %+v\nwant %+v", tc.name, tc.entries, tc.want)
		}
	}
}

// A folder inside a repository is not the top of its checkout: what git
// says of it starts with the folder's own path, which comes off.
func TestGitsWordOnAFolderInsideARepository(t *testing.T) {
	repo := gitRepo(t)
	sub := filepath.Join(repo, "sub")
	os.MkdirAll(filepath.Join(sub, "inner"), 0o755)
	os.WriteFile(filepath.Join(sub, "a.txt"), []byte("a\n"), 0o644)
	os.WriteFile(filepath.Join(sub, "inner", "b.txt"), []byte("b\n"), 0o644)
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "commit", "-q", "-m", "sub")
	os.WriteFile(filepath.Join(sub, "a.txt"), []byte("changed\n"), 0o644)
	os.WriteFile(filepath.Join(sub, "inner", "b.txt"), []byte("changed\n"), 0o644)
	os.WriteFile(filepath.Join(sub, "new.txt"), []byte("new\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "README"), []byte("outside the folder\n"), 0o644)

	v, ok := gitView(context.Background(), sub, "")
	if !ok {
		t.Fatal("git said nothing")
	}
	if v.marks["a.txt"].status != " M" || v.marks["new.txt"].status != "??" || !v.marks["inner"].changed || len(v.marks) != 3 {
		t.Fatalf("sub = %+v", v.marks)
	}
	v, _ = gitView(context.Background(), sub, "inner")
	if v.marks["b.txt"].status != " M" || len(v.marks) != 1 {
		t.Fatalf("sub/inner = %+v", v.marks)
	}
	if _, ok := gitView(context.Background(), t.TempDir(), ""); ok {
		t.Fatal("git spoke of a folder outside any repository")
	}
}

// A folder outside any repository lists all the same, without git's word.
func TestAFolderOutsideARepositoryStillLists(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a"), 0o644)
	tg, err := resolveIn(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	l, err := listDir(context.Background(), tg)
	if err != nil || len(l.Entries) != 1 || l.Entries[0] != (FileEntry{Name: "a.txt", Type: "file", Size: 1}) {
		t.Fatalf("listing = %+v, %v", l, err)
	}
}
