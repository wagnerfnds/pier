package boxcmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// `pierd capture page` takes a page's screenshot for the person in one go:
// the worktree's own page (a path is on its $PIER_PORT) in a headless
// Chromium the box already has (Playwright's download, or a Chromium or
// Chrome on the system), at a desktop's width or a phone's, handed over as
// a capture. An agent left to work it out took several tries on a real box
// (Playwright's newest version wanted a browser not downloaded, its iPhone
// device wanted WebKit); this is the one command the pier-prove skill
// names. The browser runs here, in the agent's session: pierd itself never
// starts one.

// pageSize is the window a screenshot is taken at, in CSS pixels, and how
// many device pixels each is.
type pageSize struct {
	w, h, scale int
	ua          string
}

var (
	desktopPage = pageSize{w: 1280, h: 800, scale: 1}
	// A phone's: an iPhone's width at its density, and its user agent, for
	// a site that picks its layout by it.
	phonePage = pageSize{w: 390, h: 844, scale: 2, ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"}
)

// pageURL is the address a page argument names: a whole address as it is,
// a path on this worktree's port, or host:port/… as http.
func pageURL(arg string) (string, error) {
	switch {
	case strings.HasPrefix(arg, "http://"), strings.HasPrefix(arg, "https://"):
		return arg, nil
	case strings.Contains(arg, "://"):
		return "", fmt.Errorf("%q is not a web page: give an http or https address", arg)
	case arg == "" || strings.HasPrefix(arg, "/"):
		port := os.Getenv("PIER_PORT")
		if port == "" {
			return "", errors.New("this session has no worktree port ($PIER_PORT): give the page's whole address, such as http://127.0.0.1:8000/login")
		}
		if arg == "" {
			arg = "/"
		}
		return "http://127.0.0.1:" + port + arg, nil
	}
	return "http://" + arg, nil
}

// pageName is the file name a page's capture goes by: the last part of its
// path ("login.png"), "page.png" for a site's root, "-phone" at a phone's.
func pageName(url string, phone bool) string {
	path := url
	if i := strings.Index(path, "://"); i >= 0 {
		path = path[i+3:]
	}
	path, _, _ = strings.Cut(path, "?")
	path, _, _ = strings.Cut(path, "#")
	name := "page"
	if i := strings.IndexByte(path, '/'); i >= 0 {
		parts := strings.FieldsFunc(path[i:], func(r rune) bool { return r == '/' })
		if len(parts) > 0 {
			name = parts[len(parts)-1]
		}
	}
	name = strings.Trim(unsafeName.ReplaceAllString(strings.TrimSuffix(name, filepath.Ext(name)), "-"), "-.")
	if name == "" {
		name = "page"
	}
	if phone {
		name += "-phone"
	}
	return name + ".png"
}

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// playwrightGlobs are where Playwright keeps its Chromium builds in its
// cache, a revision per folder: the headless shell first (newer and older
// layouts), then the full browser.
var playwrightGlobs = []string{
	"chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell",
	"chromium_headless_shell-*/chrome-*/headless_shell",
	"chromium-*/chrome-linux*/chrome",
	"chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium",
	"chromium-*/chrome-mac*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
}

// browsers are the headless Chromiums this box has, the one to use first:
// $PIER_BROWSER, Playwright's (its newest revision first), then a system
// one.
func browsers(home string) []string {
	var out []string
	add := func(p string) {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0 {
			out = append(out, p)
		}
	}
	if p := os.Getenv("PIER_BROWSER"); p != "" {
		add(p)
	}
	caches := []string{filepath.Join(home, ".cache", "ms-playwright"), filepath.Join(home, "Library", "Caches", "ms-playwright")}
	if p := os.Getenv("PLAYWRIGHT_BROWSERS_PATH"); p != "" && p != "0" {
		caches = append([]string{p}, caches...)
	}
	for _, cache := range caches {
		for _, g := range playwrightGlobs {
			found, _ := filepath.Glob(filepath.Join(cache, g))
			sort.SliceStable(found, func(i, j int) bool { return revision(found[i]) > revision(found[j]) })
			for _, p := range found {
				add(p)
			}
		}
	}
	for _, name := range []string{"chrome-headless-shell", "chromium", "chromium-browser", "google-chrome", "google-chrome-stable"} {
		if p, err := exec.LookPath(name); err == nil {
			add(p)
		}
	}
	add("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
	add("/Applications/Chromium.app/Contents/MacOS/Chromium")
	return out
}

var revisionRe = regexp.MustCompile(`(?:chromium|chromium_headless_shell)-(\d+)`)

// revision is the Playwright revision a browser's path names, 0 for none.
func revision(path string) int {
	m := revisionRe.FindStringSubmatch(path)
	if m == nil {
		return 0
	}
	n, _ := strconv.Atoi(m[1])
	return n
}

// noBrowser says how to get one.
var errNoBrowser = errors.New("this box has no headless Chromium for page screenshots: `npx -y playwright install chromium` downloads one (or set PIER_BROWSER to a Chromium or Chrome)")

// screenshot loads url in browser and returns its PNG.
func screenshot(ctx context.Context, browser, url string, size pageSize, settle time.Duration) ([]byte, error) {
	dir, err := os.MkdirTemp("", "pier-page-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	out := filepath.Join(dir, "page.png")
	args := []string{
		// Playwright starts Chromium without its sandbox too: Ubuntu's
		// AppArmor keeps it from making the namespaces it needs, and the
		// page is the worktree's own.
		"--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
		"--user-data-dir=" + filepath.Join(dir, "profile"),
		fmt.Sprintf("--window-size=%d,%d", size.w, size.h),
		fmt.Sprintf("--force-device-scale-factor=%d", size.scale),
		fmt.Sprintf("--virtual-time-budget=%d", settle.Milliseconds()),
		"--screenshot=" + out,
	}
	if base := filepath.Base(browser); base != "chrome-headless-shell" && base != "headless_shell" {
		args = append([]string{"--headless=new"}, args...)
	}
	if size.ua != "" {
		args = append(args, "--user-agent="+size.ua)
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, browser, append(args, url)...)
	var stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stderr, &stderr
	runErr := cmd.Run()
	data, err := os.ReadFile(out)
	if err == nil && len(data) > 0 {
		return data, nil
	}
	return nil, browserError(browser, stderr.String(), runErr, ctx.Err())
}

var missingLib = regexp.MustCompile(`error while loading shared libraries: (\S+?):`)

// browserError says why a browser made no screenshot, and what helps.
func browserError(browser, output string, runErr, ctxErr error) error {
	if m := missingLib.FindStringSubmatch(output); m != nil {
		return fmt.Errorf("Chromium can't start here: the system lacks %s and the libraries beside it. `sudo npx -y playwright install-deps chromium` installs them; that changes the system, so ask the person first", m[1])
	}
	if errors.Is(ctxErr, context.DeadlineExceeded) {
		return errors.New("the page took over a minute and the browser gave up: is its server answering? (curl the address)")
	}
	last := strings.TrimSpace(output)
	if i := strings.LastIndexByte(last, '\n'); i >= 0 {
		last = strings.TrimSpace(last[i+1:])
	}
	if len(last) > 300 {
		last = last[:300]
	}
	if runErr != nil {
		return fmt.Errorf("%s made no screenshot (%v): %s", filepath.Base(browser), runErr, last)
	}
	return fmt.Errorf("%s made no screenshot: %s", filepath.Base(browser), last)
}
