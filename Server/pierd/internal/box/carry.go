package box

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"pier/pierd/internal/groups"
)

// Carrying: the ignored folders a project's installs make in its main
// checkout (vendor, node_modules, a downloaded server binary) are copied into
// each new worktree before its recipe runs, so the recipe's install finds
// them and only reconciles what its branch changed. The copy shares the
// main checkout's blocks where the disk can (btrfs, XFS, APFS) and is a
// plain copy elsewhere.

// carryDenied are paths never carried: they hold the main checkout's own
// state or absolute paths (Laravel's caches and logs, a Python virtualenv,
// Vite's hot file), which in a worktree would point back at the main one.
var carryDenied = []string{".git", "bootstrap/cache", "storage/framework", "storage/logs", "public/hot", ".venv", "venv"}

func carryAllowed(p string) bool {
	if p == "storage" {
		return false
	}
	for _, d := range carryDenied {
		if p == d || strings.HasPrefix(p, d+"/") {
			return false
		}
	}
	return true
}

// cloneTree copies src to dst, which must not exist, the cheapest way the
// disk allows: reflinks with GNU cp on Linux, clonefile on macOS. always
// refuses a plain copy instead of falling back to one. Tests replace it.
var cloneTree = func(ctx context.Context, src, dst string, always bool) error {
	var args []string
	if runtime.GOOS == "darwin" {
		args = []string{"-a", "-c", src, dst}
	} else {
		mode := "auto"
		if always {
			mode = "always"
		}
		args = []string{"-a", "--reflink=" + mode, "--", src, dst}
	}
	cmd := groups.CommandContext(ctx, "cp", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("cp: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// worktreeIncludes are the ignored files and folders of the main checkout
// that the repository's .worktreeinclude names (gitignore patterns; the
// file Claude Code and Conductor read for the same thing): only what git
// itself ignores, so nothing it tracks is ever copied. The worktree's own
// .worktreeinclude goes first, its branch's.
func worktreeIncludes(ctx context.Context, main, wt string) []string {
	file := filepath.Join(wt, ".worktreeinclude")
	if _, err := os.Stat(file); err != nil {
		file = filepath.Join(main, ".worktreeinclude")
		if _, err := os.Stat(file); err != nil {
			return nil
		}
	}
	out, err := git(ctx, "-C", main, "ls-files", "-z", "--others", "--ignored", "--exclude-from="+file, "--directory")
	if err != nil {
		return nil
	}
	var cands []string
	for _, p := range strings.Split(string(out), "\x00") {
		if p = strings.TrimSuffix(p, "/"); p != "" {
			cands = append(cands, p)
		}
	}
	if len(cands) == 0 {
		return nil
	}
	// Of those, what the repository's own rules ignore.
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	cmd := groups.CommandContext(ctx, "git", "-C", main, "check-ignore", "-z", "--stdin")
	cmd.Stdin = strings.NewReader(strings.Join(cands, "\x00") + "\x00")
	ignored, _ := cmd.Output()
	var res []string
	for _, p := range strings.Split(string(ignored), "\x00") {
		if clean, err := cleanBasePath(p); err == nil {
			res = append(res, clean)
		}
	}
	sort.Strings(res)
	return res
}

// carryEntries are what a new worktree of loc takes from its main checkout:
// the config's base.carry and the repository's .worktreeinclude, less the
// base's own files (those come from the base) and what is never carried.
func (b *Box) carryEntries(ctx context.Context, loc Location, wt Worktree) []string {
	cfg, err := b.Locations.Config(ctx, loc.Name)
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	add := func(p string) {
		if clean, err := cleanBasePath(p); err == nil && !seen[clean] && carryAllowed(clean) {
			seen[clean] = true
			out = append(out, clean)
		}
	}
	if cfg.Effective.Base != nil {
		for _, p := range cfg.Effective.Base.Carry {
			add(p)
		}
	}
	for _, p := range worktreeIncludes(ctx, loc.Path, wt.Path) {
		add(p)
	}
	if key, err := b.Locations.BaseKey(ctx, loc.Name); err == nil {
		files := map[string]bool{}
		for _, f := range b.lockedBaseFiles(key) {
			files[f.Path] = true
		}
		kept := out[:0]
		for _, p := range out {
			if !files[p] {
				kept = append(kept, p)
			}
		}
		out = kept
	}
	return out
}

// carryOne copies p from the main checkout into the worktree. A failure is
// reported, never fatal: the recipe can still install from scratch.
func carryOne(ctx context.Context, main, wt, p string) BaseResult {
	res := BaseResult{Path: p}
	src := filepath.Join(main, filepath.FromSlash(p))
	dst := filepath.Join(wt, filepath.FromSlash(p))
	info, err := os.Lstat(src)
	if err != nil {
		res.Action, res.Reason = "skipped", "not in the main checkout"
		return res
	}
	if _, err := os.Lstat(dst); err == nil {
		res.Action, res.Reason = "skipped", "already in this worktree"
		return res
	}
	if !gitIgnores(ctx, main, p) {
		res.Action, res.Reason = "skipped", "git does not ignore it"
		return res
	}
	if info.IsDir() {
		if tracked, err := gitTracks(ctx, main, p); err != nil {
			res.Action, res.Reason = "skipped", "git could not say whether it tracks files in it: "+err.Error()
			return res
		} else if tracked {
			res.Action, res.Reason = "skipped", "git tracks files in it"
			return res
		}
	}
	// A link on the way (a folder of the worktree that is a link to
	// somewhere else) would take the copy out of the worktree.
	if !staysIn(wt, filepath.Dir(dst)) {
		res.Action, res.Reason = "skipped", "a link on its way leads out of this worktree"
		return res
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		res.Action, res.Reason = "failed", err.Error()
		return res
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	if err := cloneTree(ctx, src, dst, false); err != nil {
		os.RemoveAll(dst)
		res.Action, res.Reason = "failed", err.Error()
		return res
	}
	relinkInto(dst, main, wt)
	res.Action, res.MS = "carried", time.Since(start).Milliseconds()
	return res
}

// staysIn says dir, once its links are followed, is root or inside it. A
// folder still to be made counts by the deepest part of it already there.
func staysIn(root, dir string) bool {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return false
	}
	for {
		if _, err := os.Lstat(dir); err == nil {
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return false
	}
	_, inside := relInside(realRoot, real)
	return real == realRoot || inside
}

// relinkInto points links copied from the main checkout that lead into it
// (Laravel's public/storage, an absolute link a tool made) at the same place
// in the worktree instead, so the worktree never writes into the main one.
func relinkInto(dir, main, wt string) {
	fix := func(p string) {
		target, err := os.Readlink(p)
		if err != nil || !filepath.IsAbs(target) {
			return
		}
		if target != main && !strings.HasPrefix(target, main+string(filepath.Separator)) {
			return
		}
		moved := wt + strings.TrimPrefix(target, main)
		if os.Remove(p) == nil {
			os.Symlink(moved, p)
		}
	}
	if info, err := os.Lstat(dir); err == nil && info.Mode()&fs.ModeSymlink != 0 {
		fix(dir)
		return
	}
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type()&fs.ModeSymlink != 0 {
			fix(p)
		}
		return nil
	})
}

// carriedPaths are the paths a report says were carried.
func carriedPaths(rs []BaseResult) []string {
	var out []string
	for _, r := range rs {
		if r.Action == "carried" {
			out = append(out, r.Path)
		}
	}
	return out
}

// writtenPaths are the base files a report says are in the checkout.
func writtenPaths(rs []BaseResult) []string {
	var out []string
	for _, r := range rs {
		switch r.Action {
		case "written", "updated", "unchanged", "kept":
			out = append(out, r.Path)
		}
	}
	return out
}
