package service

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// A launchd agent starts with launchd's own PATH, /usr/bin:/bin:/usr/sbin:
// /sbin, so a pierd it runs can't see what Homebrew, npm or the user put
// anywhere else: tmux (which every agent runs in), gh, node, op, claude.
// The plist therefore carries a PATH: the user's own, as their login shell
// sets it, and the folders tools install to.

// ToolDirs are the folders tools install to that a service's PATH lacks:
// Homebrew's on Apple silicon and on Intel, and ~/.local/bin.
func ToolDirs(home string) []string {
	dirs := []string{"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"}
	if home != "" {
		dirs = append(dirs, filepath.Join(home, ".local", "bin"))
	}
	return dirs
}

// systemDirs are on every PATH; they end one pierd composes, if missing.
var systemDirs = []string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"}

// ComposePATH is login's folders, then ToolDirs, then the system's, each
// once. Empty and relative entries go: a service has no meaningful ".".
func ComposePATH(login, home string) string {
	var out []string
	seen := map[string]bool{}
	add := func(dirs ...string) {
		for _, d := range dirs {
			d = strings.TrimSpace(d)
			if d == "" || !filepath.IsAbs(d) {
				continue
			}
			d = filepath.Clean(d)
			if !seen[d] {
				seen[d] = true
				out = append(out, d)
			}
		}
	}
	add(filepath.SplitList(login)...)
	add(ToolDirs(home)...)
	add(systemDirs...)
	return strings.Join(out, string(os.PathListSeparator))
}

// ServicePATH is the PATH a pierd service should run with: the user's
// login-shell PATH, when it can be had within a few seconds, with ToolDirs.
func ServicePATH() string {
	home, _ := os.UserHomeDir()
	login, err := LoginShellPATH(5 * time.Second)
	if err != nil || login == "" {
		login = os.Getenv("PATH")
	}
	return ComposePATH(login, home)
}

const pathMark = "__PIER_PATH__"

// LoginShellPATH asks the user's login shell, interactive as a terminal
// would start it, for its PATH. It runs in a session of its own, so an
// interactive shell never takes a terminal over.
func LoginShellPATH(timeout time.Duration) (string, error) {
	shell := UserShell()
	script := `printf '` + pathMark + `%s` + pathMark + `' "$PATH"`
	if filepath.Base(shell) == "fish" {
		script = `printf '` + pathMark + `%s` + pathMark + `' (string join : $PATH)`
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, shell, "-lic", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	if p, ok := markedPATH(out); ok {
		return p, nil
	}
	if err == nil {
		err = errNoPATH
	}
	return "", err
}

var errNoPATH = errors.New("the login shell printed no PATH")

// markedPATH finds the PATH between the marks, past whatever a shell's
// startup files print.
func markedPATH(out []byte) (string, bool) {
	i := bytes.Index(out, []byte(pathMark))
	if i < 0 {
		return "", false
	}
	rest := out[i+len(pathMark):]
	j := bytes.Index(rest, []byte(pathMark))
	if j < 0 {
		return "", false
	}
	return string(rest[:j]), true
}

// UserShell is the user's login shell: $SHELL, else the account's (from
// the directory service on a Mac, /etc/passwd elsewhere), else the
// system's default.
func UserShell() string {
	if s := os.Getenv("SHELL"); filepath.IsAbs(s) {
		return s
	}
	if runtime.GOOS == "darwin" {
		if u, err := user.Current(); err == nil {
			out, err := exec.Command("dscl", ".", "-read", "/Users/"+u.Username, "UserShell").Output()
			if err == nil {
				if f := strings.Fields(string(out)); len(f) == 2 && filepath.IsAbs(f[1]) {
					return f[1]
				}
			}
		}
		return "/bin/zsh"
	}
	if b, err := os.ReadFile("/etc/passwd"); err == nil {
		uid := strconv.Itoa(os.Getuid())
		for _, line := range strings.Split(string(b), "\n") {
			f := strings.Split(line, ":")
			if len(f) >= 7 && f[2] == uid && filepath.IsAbs(f[6]) {
				return f[6]
			}
		}
	}
	return "/bin/sh"
}
