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
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func tarGz(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, body := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		tw.Write([]byte(body))
	}
	tw.Close()
	gz.Close()
	return buf.Bytes()
}

func zipOf(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		h := &zip.FileHeader{Name: name, Method: zip.Deflate}
		h.SetMode(0o755)
		w, err := zw.CreateHeader(h)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(body))
	}
	zw.Close()
	return buf.Bytes()
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// ghServer serves the GitHub CLI's releases as github.com does: /latest redirects to the tag, the archive and the
// checksums file under /download/v<version>/.
func ghServer(t *testing.T, version, file string, archive []byte, sums string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/cli/cli/releases/latest":
			http.Redirect(w, r, "/cli/cli/releases/tag/v"+version, http.StatusFound)
		case "/cli/cli/releases/download/v" + version + "/gh_" + version + "_checksums.txt":
			w.Write([]byte(sums))
		case "/cli/cli/releases/download/v" + version + "/" + file:
			w.Write(archive)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestGHComesFromItsReleaseCheckedAgainstTheChecksums(t *testing.T) {
	home := t.TempDir()
	archive := tarGz(t, map[string]string{
		"gh_9.8.7_linux_amd64/bin/gh":         "#!/bin/sh\necho gh version 9.8.7\n",
		"gh_9.8.7_linux_amd64/share/man/gh.1": "not this",
		"gh_9.8.7_linux_amd64/LICENSE":        "MIT",
	})
	sums := sum([]byte("other")) + "  gh_9.8.7_linux_arm64.tar.gz\n" + sum(archive) + "  gh_9.8.7_linux_amd64.tar.gz\n"
	srv := ghServer(t, "9.8.7", "gh_9.8.7_linux_amd64.tar.gz", archive, sums)
	in := &Installer{Home: home, GOOS: "linux", GOARCH: "amd64", GHReleases: srv.URL + "/cli/cli/releases"}
	p, err := in.Install(context.Background(), "gh")
	if err != nil {
		t.Fatal(err)
	}
	if p != filepath.Join(home, ".local", "bin", "gh") {
		t.Fatalf("installed at %s", p)
	}
	data, _ := os.ReadFile(p)
	st, _ := os.Stat(p)
	if string(data) != "#!/bin/sh\necho gh version 9.8.7\n" || st.Mode()&0o111 == 0 {
		t.Fatalf("gh = %q, mode %v", data, st.Mode())
	}
	if entries, _ := os.ReadDir(filepath.Join(home, ".local", "bin")); len(entries) != 1 {
		t.Fatalf("more than gh in ~/.local/bin: %v", entries)
	}
}

func TestGHOnAMacComesFromItsZip(t *testing.T) {
	home := t.TempDir()
	archive := zipOf(t, map[string]string{"gh_9.8.7_macOS_arm64/bin/gh": "mac gh"})
	srv := ghServer(t, "9.8.7", "gh_9.8.7_macOS_arm64.zip", archive, sum(archive)+"  gh_9.8.7_macOS_arm64.zip\n")
	in := &Installer{Home: home, GOOS: "darwin", GOARCH: "arm64", GHReleases: srv.URL + "/cli/cli/releases"}
	p, err := in.Install(context.Background(), "gh")
	if err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(p); string(data) != "mac gh" {
		t.Fatalf("gh = %q", data)
	}
}

// An archive whose checksum is not the release's is never installed, and neither is one the checksums do not name.
func TestGHWithAWrongChecksumIsRefused(t *testing.T) {
	archive := tarGz(t, map[string]string{"gh_9.8.7_linux_amd64/bin/gh": "tampered"})
	for name, sums := range map[string]string{
		"mismatch": sum([]byte("the real one")) + "  gh_9.8.7_linux_amd64.tar.gz\n",
		"missing":  sum(archive) + "  gh_9.8.7_linux_arm64.tar.gz\n",
	} {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			srv := ghServer(t, "9.8.7", "gh_9.8.7_linux_amd64.tar.gz", archive, sums)
			in := &Installer{Home: home, GOOS: "linux", GOARCH: "amd64", GHReleases: srv.URL + "/cli/cli/releases"}
			_, err := in.Install(context.Background(), "gh")
			if err == nil || !strings.Contains(err.Error(), "not installed") {
				t.Fatalf("err = %v", err)
			}
			if _, err := os.Stat(filepath.Join(home, ".local", "bin", "gh")); err == nil {
				t.Fatal("gh was installed anyway")
			}
		})
	}
}

func TestCodexInstallerRunsWithoutQuestions(t *testing.T) {
	home := t.TempDir()
	// The script writes codex where it is told, with what it was run with: the settings, and what its input held.
	script := "#!/bin/sh\nset -eu\nmkdir -p \"$CODEX_INSTALL_DIR\"\nin=$(cat)\nprintf '#!/bin/sh\\n# %s %s [%s]\\n' \"$CODEX_NON_INTERACTIVE\" \"$HOME\" \"$in\" > \"$CODEX_INSTALL_DIR/codex\"\nchmod 755 \"$CODEX_INSTALL_DIR/codex\"\necho installed\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(script)) }))
	defer srv.Close()
	var out bytes.Buffer
	in := &Installer{Home: home, CodexScript: srv.URL + "/codex/install.sh", CodexRelease: srv.URL + "/never", Out: &out}
	p, err := in.Install(context.Background(), "codex")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(p)
	if want := "# 1 " + home + " []"; !strings.Contains(string(data), want) {
		t.Fatalf("codex = %q, want %q", data, want)
	}
	if !strings.Contains(out.String(), "installed") {
		t.Fatalf("the installer's words did not reach Out: %q", out.String())
	}
}

// codexReleaseServer answers Codex's installer with a failure and GitHub's release with an asset and its digest.
func codexReleaseServer(t *testing.T, target string, archive []byte, digest string, scriptHits *atomic.Int32) *httptest.Server {
	t.Helper()
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/codex/install.sh":
			scriptHits.Add(1)
			w.Write([]byte("#!/bin/sh\necho 'Could not fetch release metadata' >&2\nexit 1\n"))
		case "/repos/openai/codex/releases/latest":
			json.NewEncoder(w).Encode(map[string]any{"tag_name": "rust-v1.2.3", "assets": []map[string]string{
				{"name": "codex-" + target + ".zst", "digest": "sha256:" + sum([]byte("zst")), "browser_download_url": srv.URL + "/dl/zst"},
				{"name": "codex-" + target + ".tar.gz", "digest": digest, "browser_download_url": srv.URL + "/dl/codex.tar.gz"},
			}})
		case "/dl/codex.tar.gz":
			w.Write(archive)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestCodexFallsBackToItsGitHubRelease(t *testing.T) {
	home := t.TempDir()
	archive := tarGz(t, map[string]string{"codex-x86_64-unknown-linux-musl": "codex binary"})
	var hits atomic.Int32
	srv := codexReleaseServer(t, "x86_64-unknown-linux-musl", archive, "sha256:"+sum(archive), &hits)
	in := &Installer{Home: home, GOOS: "linux", GOARCH: "amd64", CodexScript: srv.URL + "/codex/install.sh",
		CodexRelease: srv.URL + "/repos/openai/codex/releases/latest"}
	p, err := in.Install(context.Background(), "codex")
	if err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(p); string(data) != "codex binary" || p != filepath.Join(home, ".local", "bin", "codex") || hits.Load() != 1 {
		t.Fatalf("codex at %s = %q (installer ran %d times)", p, data, hits.Load())
	}
}

func TestCodexReleaseWithAWrongDigestIsRefused(t *testing.T) {
	home := t.TempDir()
	archive := tarGz(t, map[string]string{"codex-aarch64-apple-darwin": "tampered"})
	for name, digest := range map[string]string{"mismatch": "sha256:" + sum([]byte("the real one")), "none": ""} {
		t.Run(name, func(t *testing.T) {
			var hits atomic.Int32
			srv := codexReleaseServer(t, "aarch64-apple-darwin", archive, digest, &hits)
			in := &Installer{Home: home, GOOS: "darwin", GOARCH: "arm64", CodexScript: srv.URL + "/codex/install.sh",
				CodexRelease: srv.URL + "/repos/openai/codex/releases/latest"}
			if _, err := in.Install(context.Background(), "codex"); err == nil || !strings.Contains(err.Error(), "not installed") {
				t.Fatalf("err = %v", err)
			}
			if _, err := os.Stat(filepath.Join(home, ".local", "bin", "codex")); err == nil {
				t.Fatal("codex was installed anyway")
			}
		})
	}
}

func TestClaudeCodeFromItsInstaller(t *testing.T) {
	home := t.TempDir()
	script := "#!/bin/bash\nmkdir -p \"$HOME/.local/bin\" && printf '#!/bin/sh\\necho 9.9.9\\n' > \"$HOME/.local/bin/claude\" && chmod +x \"$HOME/.local/bin/claude\"\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(script)) }))
	defer srv.Close()
	in := &Installer{Home: home, ClaudeScript: srv.URL}
	p, err := in.Install(context.Background(), "claude")
	if err != nil {
		t.Fatal(err)
	}
	if p != filepath.Join(home, ".local", "bin", "claude") {
		t.Fatalf("claude at %s", p)
	}
}

// An installer that fails says why in its own last words; a page that is not a script never runs.
func TestFailedInstallersSayWhy(t *testing.T) {
	home := t.TempDir()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/fails" {
			w.Write([]byte("#!/bin/bash\necho 'Downloading…'\necho 'Platform linux-x64 not found in manifest' >&2\nexit 1\n"))
			return
		}
		w.Write([]byte("<html><body>Sign in to the Wi-Fi</body></html>"))
	}))
	defer srv.Close()
	in := &Installer{Home: home, ClaudeScript: srv.URL + "/fails"}
	if _, err := in.Install(context.Background(), "claude"); err == nil || !strings.Contains(err.Error(), "Platform linux-x64 not found in manifest") {
		t.Fatalf("err = %v", err)
	}
	in.ClaudeScript = srv.URL + "/portal"
	if _, err := in.Install(context.Background(), "claude"); err == nil || !strings.Contains(err.Error(), "did not answer with a script") {
		t.Fatalf("err = %v", err)
	}
	if _, err := in.Install(context.Background(), "node"); err == nil {
		t.Fatal("installed a tool pierd does not know")
	}
}

func TestBuildNames(t *testing.T) {
	for _, c := range []struct{ goos, goarch, target string }{
		{"linux", "amd64", "x86_64-unknown-linux-musl"}, {"linux", "arm64", "aarch64-unknown-linux-musl"},
		{"darwin", "arm64", "aarch64-apple-darwin"}, {"darwin", "amd64", "x86_64-apple-darwin"},
	} {
		if got, err := codexTarget(c.goos, c.goarch); err != nil || got != c.target {
			t.Errorf("codexTarget(%s, %s) = %q, %v", c.goos, c.goarch, got, err)
		}
	}
	if _, err := codexTarget("linux", "riscv64"); err == nil {
		t.Error("a target for riscv64")
	}
	if name, isZip, _ := ghArchive("2.102.0", "darwin", "amd64"); name != "gh_2.102.0_macOS_amd64" || !isZip {
		t.Errorf("gh on an Intel Mac = %s, %v", name, isZip)
	}
	if name, isZip, _ := ghArchive("2.102.0", "linux", "arm64"); name != "gh_2.102.0_linux_arm64" || isZip {
		t.Errorf("gh on arm64 Linux = %s, %v", name, isZip)
	}
}
