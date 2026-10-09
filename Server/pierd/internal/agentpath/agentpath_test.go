package agentpath

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// write makes an executable script at home/rel.
func write(t *testing.T, path, body string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// fakeAgent is an agent CLI that, like an npm one, needs the node beside it.
func fakeAgent(t *testing.T, dir, name string) string {
	write(t, filepath.Join(dir, "node"), "#!/bin/sh\nexit 0\n")
	return write(t, filepath.Join(dir, name), "#!/bin/sh\nnode || exit 7\necho '2.1.3 (Claude Code)'\n")
}

// finder looks only in home: no shell, no pierd PATH, no system folders.
func finder(home string) *Finder {
	return &Finder{
		Home:       home,
		Env:        []string{"HOME=" + home, "PATH=/usr/bin:/bin"},
		LookPath:   func(string) (string, error) { return "", exec.ErrNotFound },
		SystemDirs: []string{},
	}
}

func TestLayouts(t *testing.T) {
	cases := []struct {
		name    string
		make    func(t *testing.T, home string) string // returns the agent's dir
		install string
		sys     func(home string) []string
	}{
		{"local bin (Shipyard's installer)", func(t *testing.T, h string) string { return filepath.Join(h, ".local", "bin") }, "", nil},
		{"nvm default alias", func(t *testing.T, h string) string {
			root := filepath.Join(h, ".nvm", "versions", "node")
			os.MkdirAll(filepath.Join(root, "v18.20.0", "bin"), 0o755)
			os.MkdirAll(filepath.Join(root, "v22.9.0", "bin"), 0o755)
			os.MkdirAll(filepath.Join(h, ".nvm", "alias", "lts"), 0o755)
			os.WriteFile(filepath.Join(h, ".nvm", "alias", "default"), []byte("lts/hydrogen\n"), 0o644)
			os.WriteFile(filepath.Join(h, ".nvm", "alias", "lts", "hydrogen"), []byte("v18.20.0\n"), 0o644)
			// The newer version has it too; the default alias wins.
			fakeAgent(t, filepath.Join(root, "v22.9.0", "bin"), "claude")
			return filepath.Join(root, "v18.20.0", "bin")
		}, "npm", nil},
		{"nvm without a default", func(t *testing.T, h string) string {
			root := filepath.Join(h, ".nvm", "versions", "node")
			os.MkdirAll(filepath.Join(root, "v9.0.0", "bin"), 0o755)
			return filepath.Join(root, "v20.1.0", "bin")
		}, "npm", nil},
		{"fnm default", func(t *testing.T, h string) string {
			inst := filepath.Join(h, ".local", "share", "fnm", "node-versions", "v22.1.0", "installation")
			os.MkdirAll(filepath.Join(inst, "bin"), 0o755)
			os.MkdirAll(filepath.Join(h, ".local", "share", "fnm", "aliases"), 0o755)
			os.Symlink(inst, filepath.Join(h, ".local", "share", "fnm", "aliases", "default"))
			return filepath.Join(h, ".local", "share", "fnm", "aliases", "default", "bin")
		}, "npm", nil},
		{"volta", func(t *testing.T, h string) string { return filepath.Join(h, ".volta", "bin") }, "volta", nil},
		{"bun", func(t *testing.T, h string) string { return filepath.Join(h, ".bun", "bin") }, "bun", nil},
		{"npm-global prefix", func(t *testing.T, h string) string { return filepath.Join(h, ".npm-global", "bin") }, "npm", nil},
		{"Homebrew", func(t *testing.T, h string) string { return filepath.Join(h, "brew", "bin") }, "", func(h string) []string { return []string{filepath.Join(h, "brew", "bin")} }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			home := t.TempDir()
			dir := c.make(t, home)
			want := fakeAgent(t, dir, "claude")
			f := finder(home)
			if c.sys != nil {
				f.SystemDirs = c.sys(home)
			}
			got, ok := f.Find("claude")
			if !ok {
				t.Fatalf("not found; want %s", want)
			}
			if filepath.Clean(got.Path) != filepath.Clean(want) {
				t.Fatalf("path = %s, want %s", got.Path, want)
			}
			if got.Install != c.install {
				t.Errorf("install = %q, want %q", got.Install, c.install)
			}
			if got.Via != "dir" {
				t.Errorf("via = %q", got.Via)
			}
			// It ran with node beside it on its PATH.
			if got.Version != "2.1.3 (Claude Code)" {
				t.Errorf("version = %q (PATH %s)", got.Version, got.PATH)
			}
			if !strings.HasPrefix(got.PATH, filepath.Dir(want)+":") {
				t.Errorf("PATH = %s, want its folder first", got.PATH)
			}
			if _, ok := f.Find("codex"); ok {
				t.Errorf("codex found in an empty home")
			}
		})
	}
}

// npm's own global prefix, as `npm prefix -g` says (a custom prefix in
// ~/.npmrc, say).
func TestNPMPrefix(t *testing.T) {
	home := t.TempDir()
	prefix := filepath.Join(home, "custom-prefix")
	want := fakeAgent(t, filepath.Join(prefix, "bin"), "codex")
	// npm itself lives in nvm's default Node.
	nvmBin := filepath.Join(home, ".nvm", "versions", "node", "v22.0.0", "bin")
	write(t, filepath.Join(nvmBin, "npm"), "#!/bin/sh\n[ \"$1 $2\" = 'prefix -g' ] && echo '"+prefix+"'\n")
	got, ok := finder(home).Find("codex")
	if !ok || got.Path != want {
		t.Fatalf("got %+v, want %s", got, want)
	}
}

// The person's shell is asked as a terminal starts it: bash, login and
// interactive, which reads ~/.bashrc past Ubuntu's "not interactive:
// return", where nvm lives; its banner is not taken for a path.
func TestShellInteractiveRC(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	home := t.TempDir()
	nvm := filepath.Join(home, "nvm-like", "bin")
	want := fakeAgent(t, nvm, "claude")
	local := fakeAgent(t, filepath.Join(home, ".local", "bin"), "claude")
	write(t, filepath.Join(home, ".bash_profile"), "[ -f ~/.bashrc ] && . ~/.bashrc\n")
	write(t, filepath.Join(home, ".bashrc"), `case $- in *i*) ;; *) return;; esac
echo "Welcome to the box! claude=/not/this"
printf '/usr/bin/claude\n'
export PATH="$HOME/nvm-like/bin:$PATH:$HOME/.local/bin"
alias claude='claude --dangerously-skip-permissions'
`)
	f := finder(home)
	f.Shell = bash
	got, ok := f.Find("claude")
	if !ok {
		t.Fatalf("not found: %+v", f.Status())
	}
	if got.Path != want || got.Via != "shell" {
		t.Fatalf("got %s via %s, want %s via shell (not %s)", got.Path, got.Via, want, local)
	}
	if !strings.Contains(got.PATH, nvm) {
		t.Errorf("PATH %s lacks the shell's %s", got.PATH, nvm)
	}
	if st := f.Status(); !st.OK {
		t.Errorf("status: %+v", st)
	}
}

// Without the shell's answer, pierd's own install is found all the same.
func TestShellTimeout(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	home := t.TempDir()
	want := fakeAgent(t, filepath.Join(home, ".local", "bin"), "claude")
	write(t, filepath.Join(home, ".bash_profile"), "sleep 30 & sleep 30\n")
	f := finder(home)
	f.Shell = bash
	f.Timeout = 500 * time.Millisecond
	t0 := time.Now()
	got, ok := f.Find("claude")
	if took := time.Since(t0); took > 8*time.Second {
		t.Fatalf("took %s", took)
	}
	if !ok || got.Path != want {
		t.Fatalf("got %+v, want %s", got, want)
	}
	if st := f.Status(); st.OK || !strings.Contains(st.Error, "did not answer") {
		t.Errorf("status: %+v", st)
	}
}

func TestParseShell(t *testing.T) {
	out := []byte("motd\x1b[0m\n" + markPATH + "/a:/b" + markPATH + "\nnoise " + markCmd + "claude=/bin/sh" + markCmd + "\n" + markCmd + "codex=" + markCmd + "\n" + markCmd + "gemini=alias gemini=x" + markCmd + "\nbye\n")
	a := ParseShell(out)
	if a.PATH != "/a:/b" {
		t.Errorf("PATH = %q", a.PATH)
	}
	if a.Commands["claude"] != "/bin/sh" || a.Commands["codex"] != "" || a.Commands["gemini"] != "" {
		t.Errorf("commands = %v", a.Commands)
	}
}

func TestDescribe(t *testing.T) {
	r := Found{Path: "/home/dev/.nvm/versions/node/v22.9.0/bin/claude", Install: "npm", Version: "2.1.3 (Claude Code)"}
	if got := Describe(r, "/home/dev"); got != "2.1.3 (Claude Code) · ~/.nvm/versions/node/v22.9.0/bin/claude (npm)" {
		t.Errorf("Describe = %q", got)
	}
}
