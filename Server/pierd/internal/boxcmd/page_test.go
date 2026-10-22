package boxcmd

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPageURL(t *testing.T) {
	t.Setenv("PIER_PORT", "41010")
	for in, want := range map[string]string{
		"/login":                         "http://127.0.0.1:41010/login",
		"/":                              "http://127.0.0.1:41010/",
		"":                               "http://127.0.0.1:41010/",
		"http://127.0.0.1:8765/a?b=1":    "http://127.0.0.1:8765/a?b=1",
		"https://p-abc.docktopier.com/x": "https://p-abc.docktopier.com/x",
		"localhost:3000/settings":        "http://localhost:3000/settings",
	} {
		if got, err := pageURL(in); err != nil || got != want {
			t.Errorf("pageURL(%q) = %q %v, want %q", in, got, err, want)
		}
	}
	if _, err := pageURL("file:///etc/passwd"); err == nil {
		t.Error("a file address was taken as a page")
	}
	t.Setenv("PIER_PORT", "")
	if _, err := pageURL("/login"); err == nil || !strings.Contains(err.Error(), "whole address") {
		t.Errorf("a path without a worktree port: %v", err)
	}
}

func TestPageName(t *testing.T) {
	for _, tc := range []struct {
		url   string
		phone bool
		want  string
	}{
		{"http://127.0.0.1:41010/login", false, "login.png"},
		{"http://127.0.0.1:41010/", true, "page-phone.png"},
		{"http://127.0.0.1:41010", false, "page.png"},
		{"http://127.0.0.1:41010/admin/users/new?x=1#top", true, "new-phone.png"},
		{"http://127.0.0.1:41010/docs/index.html", false, "index.png"},
		// A name of nothing but unsafe characters is the page's.
		{"http://127.0.0.1:41010/a b/çã", false, "page.png"},
	} {
		if got := pageName(tc.url, tc.phone); got != tc.want {
			t.Errorf("pageName(%q, %v) = %q, want %q", tc.url, tc.phone, got, tc.want)
		}
	}
}

// executable writes a script at path.
func executable(t *testing.T, path, script string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestBrowsersPreferPierBrowserThenPlaywrightsNewest(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PATH", t.TempDir())
	t.Setenv("PLAYWRIGHT_BROWSERS_PATH", "")
	cache := filepath.Join(home, ".cache", "ms-playwright")
	old := filepath.Join(cache, "chromium_headless_shell-1187", "chrome-headless-shell-linux64", "chrome-headless-shell")
	newer := filepath.Join(cache, "chromium_headless_shell-1243", "chrome-headless-shell-linux64", "chrome-headless-shell")
	olderLayout := filepath.Join(cache, "chromium_headless_shell-1100", "chrome-linux", "headless_shell")
	full := filepath.Join(cache, "chromium-1187", "chrome-linux", "chrome")
	for _, p := range []string{old, newer, olderLayout, full} {
		executable(t, p, "#!/bin/sh\n")
	}
	// Not executable: never offered.
	os.WriteFile(filepath.Join(cache, "chromium_headless_shell-1300", "chrome-headless-shell-linux64", "chrome-headless-shell"), nil, 0o644)
	mine := filepath.Join(t.TempDir(), "my-chrome")
	executable(t, mine, "#!/bin/sh\n")
	t.Setenv("PIER_BROWSER", mine)

	got := browsers(home)
	want := []string{mine, newer, old, olderLayout, full}
	if len(got) < len(want) {
		t.Fatalf("browsers = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("browsers = %v, want %v first", got, want)
		}
	}
}

// fakeBrowser is a script that answers as Chromium does: it writes a PNG
// where --screenshot says and keeps its arguments in argsFile.
func fakeBrowser(t *testing.T, name string) (browser, argsFile string) {
	t.Helper()
	dir := t.TempDir()
	var buf bytes.Buffer
	png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 8, 5)))
	shot := filepath.Join(dir, "shot.png")
	os.WriteFile(shot, buf.Bytes(), 0o644)
	argsFile = filepath.Join(dir, "args")
	browser = filepath.Join(dir, name)
	executable(t, browser, "#!/bin/sh\nprintf '%s\\n' \"$@\" > "+argsFile+"\nfor a in \"$@\"; do case \"$a\" in --screenshot=*) cp "+shot+" \"${a#--screenshot=}\";; esac; done\n")
	return browser, argsFile
}

func TestScreenshotRunsTheBrowserAtAPhonesWidth(t *testing.T) {
	browser, argsFile := fakeBrowser(t, "chromium")
	data, err := screenshot(context.Background(), browser, "http://127.0.0.1:41010/login", phonePage, 1500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := png.Decode(bytes.NewReader(data)); err != nil {
		t.Fatalf("not the browser's picture: %v", err)
	}
	raw, _ := os.ReadFile(argsFile)
	args := strings.Split(strings.TrimSpace(string(raw)), "\n")
	for _, want := range []string{"--headless=new", "--no-sandbox", "--hide-scrollbars", "--window-size=390,844", "--force-device-scale-factor=2", "--virtual-time-budget=1500"} {
		if !strings.Contains(string(raw), want+"\n") {
			t.Errorf("no %s in %v", want, args)
		}
	}
	if !strings.Contains(string(raw), "--user-agent=Mozilla/5.0 (iPhone;") {
		t.Errorf("no phone's user agent: %v", args)
	}
	if args[len(args)-1] != "http://127.0.0.1:41010/login" {
		t.Errorf("the page is not the last argument: %v", args)
	}

	// The headless shell is headless already, and a desktop's has no phone's agent.
	shell, shellArgs := fakeBrowser(t, "chrome-headless-shell")
	if _, err := screenshot(context.Background(), shell, "http://127.0.0.1:41010/", desktopPage, time.Second); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(shellArgs)
	if strings.Contains(string(raw), "--headless") || strings.Contains(string(raw), "--user-agent") || !strings.Contains(string(raw), "--window-size=1280,800\n") {
		t.Errorf("headless shell args: %s", raw)
	}
}

func TestScreenshotSaysWhatTheBrowserLacks(t *testing.T) {
	dir := t.TempDir()
	broken := filepath.Join(dir, "chrome-headless-shell")
	executable(t, broken, "#!/bin/sh\necho \"$0: error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file: No such file or directory\" >&2\nexit 127\n")
	_, err := screenshot(context.Background(), broken, "http://127.0.0.1:41010/", desktopPage, time.Second)
	if err == nil || !strings.Contains(err.Error(), "libatk-1.0.so.0") || !strings.Contains(err.Error(), "install-deps chromium") || !strings.Contains(err.Error(), "ask the person") {
		t.Fatalf("missing libraries: %v", err)
	}
	silent := filepath.Join(dir, "chromium")
	executable(t, silent, "#!/bin/sh\necho 'something else went wrong' >&2\nexit 1\n")
	if _, err := screenshot(context.Background(), silent, "http://127.0.0.1:41010/", desktopPage, time.Second); err == nil || !strings.Contains(err.Error(), "something else went wrong") {
		t.Fatalf("another failure: %v", err)
	}
}

// A real browser, when the machine has one and PIER_TEST_BROWSER=1 asks for
// it: a page served here, at a desktop's and a phone's size.
func TestScreenshotWithARealBrowser(t *testing.T) {
	if os.Getenv("PIER_TEST_BROWSER") != "1" {
		t.Skip("PIER_TEST_BROWSER=1 runs a real Chromium")
	}
	home, _ := os.UserHomeDir()
	found := browsers(home)
	if len(found) == 0 {
		t.Skip("no Chromium on this machine")
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(`<!doctype html><meta name=viewport content="width=device-width"><body style="margin:0;background:#2563eb"><h1>Entrar</h1>`))
	}))
	defer srv.Close()
	for _, tc := range []struct {
		size pageSize
		w, h int
	}{{desktopPage, 1280, 800}, {phonePage, 780, 1688}} {
		data, err := screenshot(context.Background(), found[0], srv.URL, tc.size, time.Second)
		if err != nil {
			t.Fatalf("%s: %v", found[0], err)
		}
		cfg, err := png.DecodeConfig(bytes.NewReader(data))
		if err != nil || cfg.Width != tc.w || cfg.Height != tc.h {
			t.Errorf("%s at %d×%d: %+v %v", found[0], tc.size.w, tc.size.h, cfg, err)
		}
	}
}
