// Package doctor describes what is set up, what is missing, and how to fix
// it, for a laptop or a box. Checks never change anything.
package doctor

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

type Status string

const (
	OK   Status = "ok"
	Warn Status = "warn"
	Fail Status = "fail"
	// Info marks an optional tool that is simply not in use.
	Info Status = "info"
)

type Check struct {
	Area   string `json:"area"`
	Name   string `json:"name"`
	Status Status `json:"status"`
	Detail string `json:"detail,omitempty"`
	// Fix is a command, or one plain sentence, that resolves the problem.
	Fix string `json:"fix,omitempty"`
}

// extraToolDirs are searched after PATH. macOS GUI apps inherit a minimal
// PATH, so a Homebrew install is invisible to a check that trusts PATH alone.
// A variable so tests can redirect it.
var extraToolDirs = []string{"/opt/homebrew/bin", "/usr/local/bin"}

// Tool finds an executable on PATH, in ~/.local/bin, or in a Homebrew
// prefix, where cloudflared and agent CLIs install themselves.
func Tool(name string) (string, bool) {
	if p, err := exec.LookPath(name); err == nil {
		return p, true
	}
	dirs := extraToolDirs
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append([]string{filepath.Join(home, ".local", "bin")}, dirs...)
	}
	for _, dir := range dirs {
		p := filepath.Join(dir, name)
		if info, err := os.Stat(p); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return p, true
		}
	}
	return "", false
}

// ToolCheck reports a tool's presence. required marks tools pierd cannot
// work without; the rest are optional features.
func ToolCheck(area, name, purpose, install string, required bool) Check {
	if path, ok := Tool(name); ok {
		return Check{Area: area, Name: name, Status: OK, Detail: path}
	}
	c := Check{Area: area, Name: name, Status: Info, Detail: "not installed; needed for " + purpose, Fix: install}
	if required {
		c.Status = Fail
	}
	return c
}

// Print writes checks for a person, grouped by area, with fixes indented.
func Print(w io.Writer, checks []Check) (problems int) {
	area := ""
	for _, c := range checks {
		if c.Area != area {
			if area != "" {
				fmt.Fprintln(w)
			}
			area = c.Area
			fmt.Fprintln(w, area)
		}
		mark := map[Status]string{OK: "✓", Warn: "!", Fail: "✗", Info: "·"}[c.Status]
		line := fmt.Sprintf("  %s %s", mark, c.Name)
		if c.Detail != "" {
			line += "  " + c.Detail
		}
		fmt.Fprintln(w, line)
		if c.Fix != "" && c.Status != OK {
			fmt.Fprintf(w, "      → %s\n", c.Fix)
		}
		if c.Status == Warn || c.Status == Fail {
			problems++
		}
	}
	return problems
}
