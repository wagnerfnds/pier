// Package installer puts the command-line tools a box needs for the Pier app on it: Claude Code and Codex, the agents,
// and the GitHub CLI the app's pull requests and GitHub list run through. Each goes to the person's ~/.local/bin, with
// no sudo: the user a box runs pierd as often has none. `pierd setup` installs what is missing (`pierd tools
// install`), and the app asks for the rest through POST /v1/tools/install.
//
// Claude Code and Codex come from their own installers, the documented way to get their native builds: Claude Code's
// https://claude.ai/install.sh (bash), and Codex's standalone https://chatgpt.com/codex/install.sh run with
// CODEX_NON_INTERACTIVE=1, falling back to the binary of Codex's latest GitHub release for this system (musl on Linux),
// checked against the SHA-256 GitHub publishes with it. The GitHub CLI has no installer for a user's own folder: the
// archive of its latest release for this system is downloaded with the release's checksums file, checked, and its
// bin/gh copied. Nothing is installed whose checksum does not match.
package installer

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// Tool is a command-line tool pierd can install.
type Tool struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Command string `json:"command"`
}

// Tools are the ones pierd installs, in the order setup goes through them: the agents, then the GitHub CLI.
var Tools = []Tool{
	{ID: "claude", Name: "Claude Code", Command: "claude"},
	{ID: "codex", Name: "Codex", Command: "codex"},
	{ID: "gh", Name: "GitHub CLI", Command: "gh"},
}

// Lookup is the tool with that id.
func Lookup(id string) (Tool, bool) {
	for _, t := range Tools {
		if t.ID == id {
			return t, true
		}
	}
	return Tool{}, false
}

// Where each tool comes from.
const (
	// ClaudeScript is Claude Code's native installer: the claude launcher in ~/.local/bin, its versions under
	// ~/.local/share/claude.
	ClaudeScript = "https://claude.ai/install.sh"
	// CodexScript is Codex's standalone installer: ~/.local/bin/codex, a link into ~/.codex/packages/standalone. With
	// CODEX_NON_INTERACTIVE=1 it asks nothing and does not start Codex at the end.
	CodexScript = "https://chatgpt.com/codex/install.sh"
	// CodexRelease is Codex's latest release on GitHub, whose assets carry their SHA-256 (the fallback).
	CodexRelease = "https://api.github.com/repos/openai/codex/releases/latest"
	// GHReleases is the GitHub CLI's releases: /latest redirects to the newest tag, /download/vX.Y.Z/ holds its
	// archives and gh_X.Y.Z_checksums.txt.
	GHReleases = "https://github.com/cli/cli/releases"
)

// Installer installs the tools for one user.
type Installer struct {
	// Home is the user's home folder; the tools go to Home/.local/bin. Default: this user's.
	Home string
	// GOOS and GOARCH say which build to fetch. Default: this machine's.
	GOOS, GOARCH string
	// Env is what the installer scripts run with, HOME set to Home. Default: this process's environment.
	Env []string
	// Out gets what the installers print as they go; nil drops it (errors still carry its last lines).
	Out io.Writer
	// Client fetches scripts and archives. Default: one that gives up after 15 minutes.
	Client *http.Client
	// Where the tools come from; empty means the real places (tests serve their own).
	ClaudeScript, CodexScript, CodexRelease, GHReleases string
}

// maxDownload bounds a script, an archive and a binary taken out of one.
const maxDownload = 1 << 30

func (in *Installer) home() string {
	if in.Home != "" {
		return in.Home
	}
	h, _ := os.UserHomeDir()
	return h
}

// BinDir is where the tools go: ~/.local/bin, which pierd's service has on its PATH and where it looks for agents first.
func (in *Installer) BinDir() string { return filepath.Join(in.home(), ".local", "bin") }

func (in *Installer) goos() string {
	if in.GOOS != "" {
		return in.GOOS
	}
	return runtime.GOOS
}

func (in *Installer) goarch() string {
	if in.GOARCH != "" {
		return in.GOARCH
	}
	return runtime.GOARCH
}

func (in *Installer) client() *http.Client {
	if in.Client != nil {
		return in.Client
	}
	return &http.Client{Timeout: 15 * time.Minute}
}

func (in *Installer) out() io.Writer {
	if in.Out != nil {
		return in.Out
	}
	return io.Discard
}

func (in *Installer) say(format string, args ...any) { fmt.Fprintf(in.out(), format+"\n", args...) }

func or(v, def string) string {
	if v != "" {
		return v
	}
	return def
}

// Install puts the tool with that id in BinDir, replacing what is there, and says where it is.
func (in *Installer) Install(ctx context.Context, id string) (string, error) {
	switch id {
	case "claude":
		return in.claude(ctx)
	case "codex":
		return in.codex(ctx)
	case "gh":
		return in.gh(ctx)
	}
	return "", fmt.Errorf("pierd does not install %q (claude, codex or gh)", id)
}

func (in *Installer) claude(ctx context.Context) (string, error) {
	bash, err := findShell("bash")
	if err != nil {
		return "", errors.New("Claude Code's installer needs bash, which this machine does not have")
	}
	if err := in.runScript(ctx, or(in.ClaudeScript, ClaudeScript), bash); err != nil {
		return "", fmt.Errorf("Claude Code's installer: %w", err)
	}
	return in.installed("claude")
}

func (in *Installer) codex(ctx context.Context) (string, error) {
	sh, err := findShell("sh")
	if err == nil {
		err = in.runScript(ctx, or(in.CodexScript, CodexScript), sh, "CODEX_NON_INTERACTIVE=1", "CODEX_INSTALL_DIR="+in.BinDir())
	}
	if err == nil {
		var p string
		if p, err = in.installed("codex"); err == nil {
			return p, nil
		}
	}
	in.say("Codex's installer did not work (%v); trying Codex's latest release on GitHub.", err)
	p, rerr := in.codexRelease(ctx)
	if rerr != nil {
		return "", fmt.Errorf("%w (and Codex's installer: %v)", rerr, err)
	}
	return p, nil
}

// installed is where the tool command is in BinDir, once an installer said it was done.
func (in *Installer) installed(command string) (string, error) {
	p := filepath.Join(in.BinDir(), command)
	if st, err := os.Stat(p); err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
		return "", fmt.Errorf("the installer finished, but there is no %s", p)
	}
	return p, nil
}

// findShell is the shell an installer script runs in.
func findShell(name string) (string, error) {
	if p, err := exec.LookPath(name); err == nil {
		return p, nil
	}
	for _, dir := range []string{"/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"} {
		p := filepath.Join(dir, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", exec.ErrNotFound
}

// runScript fetches an installer script and runs it with shell, as `curl -fsSL url | shell` would, except that it
// reads nothing from a terminal: its standard input is empty.
func (in *Installer) runScript(ctx context.Context, url, shell string, env ...string) error {
	script, err := in.fetch(ctx, url, 4<<20)
	if err != nil {
		return err
	}
	// A captive portal or an error page answers 200 too: only a script runs.
	if !bytes.HasPrefix(script, []byte("#!")) {
		return fmt.Errorf("%s did not answer with a script", url)
	}
	dir, err := os.MkdirTemp("", "pierd-install-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, "install.sh")
	if err := os.WriteFile(file, script, 0o700); err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, shell, file)
	cmd.Dir = in.home()
	cmd.Env = append(in.env(), env...)
	tail := &tailWriter{max: 4 << 10}
	cmd.Stdout = io.MultiWriter(tail, in.out())
	cmd.Stderr = cmd.Stdout
	cmd.WaitDelay = 5 * time.Second
	if err := cmd.Run(); err != nil {
		if t := tail.lines(6); t != "" {
			return fmt.Errorf("%w: %s", err, t)
		}
		return err
	}
	return nil
}

// env is what scripts run with: Env (or this process's), with HOME set to the home folder the tools go to.
func (in *Installer) env() []string {
	base := in.Env
	if base == nil {
		base = os.Environ()
	}
	out := make([]string, 0, len(base)+1)
	for _, kv := range base {
		if !strings.HasPrefix(kv, "HOME=") {
			out = append(out, kv)
		}
	}
	return append(out, "HOME="+in.home())
}

// fetch reads a small file whole.
func (in *Installer) fetch(ctx context.Context, url string, max int64) ([]byte, error) {
	resp, err := in.get(ctx, url, in.client())
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", url, err)
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("%s is larger than expected", url)
	}
	return data, nil
}

func (in *Installer) get(ctx context.Context, url string, c *http.Client) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "pierd")
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 && resp.StatusCode/100 != 3 {
		resp.Body.Close()
		return nil, fmt.Errorf("%s answered %s", url, resp.Status)
	}
	return resp, nil
}

// download saves url to a temporary file and says its SHA-256; the caller removes the file.
func (in *Installer) download(ctx context.Context, url string) (string, string, error) {
	resp, err := in.get(ctx, url, in.client())
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	f, err := os.CreateTemp("", "pierd-download-")
	if err != nil {
		return "", "", err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, maxDownload+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n > maxDownload {
		err = fmt.Errorf("%s is larger than expected", url)
	}
	if err != nil {
		os.Remove(f.Name())
		return "", "", fmt.Errorf("%s: %w", url, err)
	}
	return f.Name(), hex.EncodeToString(h.Sum(nil)), nil
}

// --- Codex from its GitHub release ---

// codexTarget is the Rust target of Codex's build for an OS and CPU (musl on Linux: no glibc version to match).
func codexTarget(goos, goarch string) (string, error) {
	arch := map[string]string{"amd64": "x86_64", "arm64": "aarch64"}[goarch]
	switch {
	case arch == "":
	case goos == "linux":
		return arch + "-unknown-linux-musl", nil
	case goos == "darwin":
		return arch + "-apple-darwin", nil
	}
	return "", fmt.Errorf("Codex has no build for %s/%s", goos, goarch)
}

// release is the part of GitHub's release answer used here.
type release struct {
	Tag    string `json:"tag_name"`
	Assets []struct {
		Name   string `json:"name"`
		Digest string `json:"digest"`
		URL    string `json:"browser_download_url"`
	} `json:"assets"`
}

// codexRelease installs the codex binary of Codex's latest GitHub release, checked against the digest GitHub keeps
// with each asset.
func (in *Installer) codexRelease(ctx context.Context) (string, error) {
	target, err := codexTarget(in.goos(), in.goarch())
	if err != nil {
		return "", err
	}
	src := or(in.CodexRelease, CodexRelease)
	data, err := in.fetch(ctx, src, 16<<20)
	if err != nil {
		return "", err
	}
	var rel release
	if err := json.Unmarshal(data, &rel); err != nil {
		return "", fmt.Errorf("%s: %w", src, err)
	}
	name := "codex-" + target + ".tar.gz"
	for _, a := range rel.Assets {
		if a.Name != name {
			continue
		}
		want, ok := strings.CutPrefix(a.Digest, "sha256:")
		if !ok || !sha256Hex.MatchString(want) {
			return "", fmt.Errorf("%s of Codex %s has no SHA-256 to check it against, so it was not installed", name, rel.Tag)
		}
		in.say("Downloading %s (Codex %s)…", name, strings.TrimPrefix(rel.Tag, "rust-v"))
		file, got, err := in.download(ctx, a.URL)
		if err != nil {
			return "", err
		}
		defer os.Remove(file)
		if got != want {
			return "", fmt.Errorf("checksum mismatch for %s (%s, the release says %s), so it was not installed", name, got, want)
		}
		dst := filepath.Join(in.BinDir(), "codex")
		// The archive holds the binary named after its target (codex-x86_64-unknown-linux-musl).
		match := func(p string) bool { b := path.Base(p); return b == "codex-"+target || b == "codex" }
		if err := extract(file, false, match, dst); err != nil {
			return "", fmt.Errorf("%s: %w", name, err)
		}
		return dst, nil
	}
	return "", fmt.Errorf("Codex %s has no %s", rel.Tag, name)
}

var sha256Hex = regexp.MustCompile(`^[0-9a-f]{64}$`)

// --- the GitHub CLI ---

var ghVersion = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

// ghLatest is the newest GitHub CLI release, read from where /releases/latest redirects (GitHub's API would count
// against its hourly limit for this address).
func (in *Installer) ghLatest(ctx context.Context) (string, error) {
	c := *in.client()
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	url := or(in.GHReleases, GHReleases) + "/latest"
	resp, err := in.get(ctx, url, &c)
	if err != nil {
		return "", err
	}
	resp.Body.Close()
	loc := resp.Header.Get("Location")
	_, v, ok := strings.Cut(loc, "/tag/v")
	if !ok || !ghVersion.MatchString(v) {
		return "", fmt.Errorf("%s did not lead to a release (%q)", url, loc)
	}
	return v, nil
}

// ghArchive is the name of the GitHub CLI's archive for an OS and CPU, without its extension, and whether it is a zip
// (macOS) rather than a .tar.gz (Linux).
func ghArchive(version, goos, goarch string) (string, bool, error) {
	arch := map[string]string{"amd64": "amd64", "arm64": "arm64", "386": "386", "arm": "armv6"}[goarch]
	switch {
	case arch == "":
	case goos == "linux":
		return "gh_" + version + "_linux_" + arch, false, nil
	case goos == "darwin" && (arch == "amd64" || arch == "arm64"):
		return "gh_" + version + "_macOS_" + arch, true, nil
	}
	return "", false, fmt.Errorf("the GitHub CLI has no build for %s/%s", goos, goarch)
}

func (in *Installer) gh(ctx context.Context) (string, error) {
	version, err := in.ghLatest(ctx)
	if err != nil {
		return "", err
	}
	name, isZip, err := ghArchive(version, in.goos(), in.goarch())
	if err != nil {
		return "", err
	}
	file := name + ".tar.gz"
	if isZip {
		file = name + ".zip"
	}
	base := or(in.GHReleases, GHReleases) + "/download/v" + version + "/"
	sums, err := in.fetch(ctx, base+"gh_"+version+"_checksums.txt", 1<<20)
	if err != nil {
		return "", err
	}
	want, ok := checksumOf(sums, file)
	if !ok {
		return "", fmt.Errorf("%s is not in the release's checksums, so it was not installed", file)
	}
	in.say("Downloading %s…", file)
	tmp, got, err := in.download(ctx, base+file)
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp)
	if got != want {
		return "", fmt.Errorf("checksum mismatch for %s (%s, the release says %s), so it was not installed", file, got, want)
	}
	dst := filepath.Join(in.BinDir(), "gh")
	if err := extract(tmp, isZip, func(p string) bool { return p == name+"/bin/gh" }, dst); err != nil {
		return "", fmt.Errorf("%s: %w", file, err)
	}
	return dst, nil
}

// checksumOf finds file's SHA-256 in a checksums file of "<hex>  <name>" lines.
func checksumOf(sums []byte, file string) (string, bool) {
	for _, line := range strings.Split(string(sums), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == file && sha256Hex.MatchString(strings.ToLower(f[0])) {
			return strings.ToLower(f[0]), true
		}
	}
	return "", false
}

// --- archives ---

// extract copies the archive's one regular file match picks to dst, executable. Nothing else in the archive is
// written anywhere, so its paths cannot reach outside dst.
func extract(archive string, isZip bool, match func(string) bool, dst string) error {
	if isZip {
		zr, err := zip.OpenReader(archive)
		if err != nil {
			return err
		}
		defer zr.Close()
		for _, f := range zr.File {
			if !f.Mode().IsRegular() || !match(strings.TrimPrefix(f.Name, "./")) {
				continue
			}
			r, err := f.Open()
			if err != nil {
				return err
			}
			defer r.Close()
			return writeExecutable(dst, r)
		}
		return errors.New("the binary is not in it")
	}
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return errors.New("the binary is not in it")
		}
		if err != nil {
			return err
		}
		if h.Typeflag == tar.TypeReg && match(strings.TrimPrefix(h.Name, "./")) {
			return writeExecutable(dst, tr)
		}
	}
}

// writeExecutable writes r to dst through a file of its own beside it, renamed over dst once whole: a running copy of
// the old one is never cut short, and two installs at once (the app's and `pierd tools install`) never write into the
// same file.
func writeExecutable(dst string, r io.Reader) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".pierd-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	n, err := io.Copy(f, io.LimitReader(r, maxDownload+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n > maxDownload {
		err = errors.New("the binary is larger than expected")
	}
	if err == nil {
		err = os.Chmod(tmp, 0o755)
	}
	if err == nil {
		err = os.Rename(tmp, dst)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// tailWriter keeps the end of what was written, for an error to quote.
type tailWriter struct {
	max int
	buf []byte
}

func (t *tailWriter) Write(p []byte) (int, error) {
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.max {
		t.buf = append([]byte(nil), t.buf[len(t.buf)-t.max:]...)
	}
	return len(p), nil
}

// lines is the last n non-empty lines, joined with " · ".
func (t *tailWriter) lines(n int) string {
	var out []string
	for _, l := range strings.Split(strings.ReplaceAll(string(t.buf), "\r", "\n"), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	if len(out) > n {
		out = out[len(out)-n:]
	}
	return strings.Join(out, " · ")
}
