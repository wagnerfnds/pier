package integrations

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"

	"pier/pierd/internal/agentpath"
)

// Tool is an agent CLI pierd has hooks for.
type Tool struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Command string `json:"command"`
	// dirVar names the variable that moves the tool's settings folder
	// (CLAUDE_CONFIG_DIR, CODEX_HOME); dir is the folder under home
	// otherwise.
	dirVar, dir string
	// hookFile is where the hooks live, in that folder.
	hookFile string
	// credentials is the file the tool writes once signed in, in that folder; keyVar an API key variable that
	// stands in for a sign-in. LoginFix is the command to run on the box when neither is there (a shell line: the
	// app shows it as one and copies it).
	credentials, keyVar string
	LoginFix            string
}

// Tools are the agent CLIs `integrations install` knows.
var Tools = []Tool{
	{ID: "claude", Name: "Claude Code", Command: "claude", dirVar: "CLAUDE_CONFIG_DIR", dir: ".claude", hookFile: "settings.json",
		credentials: ".credentials.json", keyVar: "ANTHROPIC_API_KEY", LoginFix: "claude   # then type /login"},
	{ID: "codex", Name: "Codex", Command: "codex", dirVar: "CODEX_HOME", dir: ".codex", hookFile: "hooks.json",
		credentials: "auth.json", keyVar: "OPENAI_API_KEY", LoginFix: "codex login --device-auth"},
}

// SignedIn reports whether t has credentials on this box, as far as a file can tell: Claude Code keeps its OAuth tokens
// in <config>/.credentials.json on Linux and Codex in <config>/auth.json; an API key in pierd's environment counts too.
// known is false where the tokens live somewhere a file check cannot see (Claude Code on macOS uses the Keychain), so
// nobody is told to sign in on a hunch. A signed-out agent stops at its login prompt the moment a session starts, and
// nothing in the app says why: doctor does (docs/ARCHITECTURE.md, "The box needs you too").
func (t Tool) SignedIn(home string) (signedIn, known bool) {
	if t.keyVar != "" && os.Getenv(t.keyVar) != "" {
		return true, true
	}
	if t.credentials == "" {
		return true, false
	}
	if st, err := os.Stat(filepath.Join(t.ConfigDir(home), t.credentials)); err == nil && !st.IsDir() && st.Size() > 0 {
		return true, true
	}
	if t.ID == "claude" && runtime.GOOS == "darwin" {
		return true, false
	}
	return false, true
}

// ConfigDir is where t keeps its settings for the user whose home is home.
func (t Tool) ConfigDir(home string) string {
	if d := os.Getenv(t.dirVar); d != "" && filepath.IsAbs(d) {
		return d
	}
	return filepath.Join(home, t.dir)
}

// Present reports whether t is on this machine: its command found as the
// person's terminal finds it (internal/agentpath), or its settings folder.
func (t Tool) Present(home string) bool {
	if _, ok := finderFor(home).Find(t.Command); ok {
		return true
	}
	st, err := os.Stat(t.ConfigDir(home))
	return err == nil && st.IsDir()
}

// Hooked reports whether pierd's hooks are in t's settings.
func (t Tool) Hooked(home string) bool {
	b, err := os.ReadFile(filepath.Join(t.ConfigDir(home), t.hookFile))
	if err != nil {
		return false
	}
	return bytes.Contains(b, []byte("pierd hook "+t.ID)) || bytes.Contains(b, []byte("pierd' hook "+t.ID))
}

// InstallTool installs pierd's hooks for one tool, for the binary at bin,
// and says what it did on out. Running it again changes nothing.
func InstallTool(home, tool, bin string, out io.Writer) error {
	t, ok := toolByID(tool)
	if !ok {
		return fmt.Errorf("unknown tool %q; use claude, codex or all", tool)
	}
	dir := t.ConfigDir(home)
	switch t.ID {
	case "claude":
		settings := filepath.Join(dir, "settings.json")
		changed, err := InstallClaudeHooks(settings, bin)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "Claude Code: hooks %s in %s\n", verb(changed), settings)
	case "codex":
		hooks := filepath.Join(dir, "hooks.json")
		changed, err := InstallCodexHooks(hooks, bin)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "Codex: hooks %s in %s (trust them once in Codex with /hooks)\n", verb(changed), hooks)
		config := filepath.Join(dir, "config.toml")
		changed, err = InstallCodexNotify(config, bin)
		switch {
		case errors.Is(err, ErrNotifyTaken):
			fmt.Fprintf(out, "Codex: %s already runs another notify program; left it alone (the hooks still report turns)\n", config)
		case err != nil:
			return err
		default:
			fmt.Fprintf(out, "Codex: notify %s in %s\n", verb(changed), config)
		}
	}
	return nil
}

// Install handles `integrations install TOOL...` (claude, codex, all) and
// `integrations [status]`, for the binary at bin.
func Install(args []string, bin string, out io.Writer) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	if len(args) == 0 || (len(args) == 1 && args[0] == "status") {
		Status(home, out)
		return nil
	}
	if len(args) < 2 || args[0] != "install" {
		return errors.New("usage: integrations [status] | integrations install claude|codex|all")
	}
	tools := args[1:]
	if len(tools) == 1 && tools[0] == "all" {
		return InstallPresent(home, bin, out)
	}
	for _, tool := range tools {
		if err := InstallTool(home, tool, bin, out); err != nil {
			return err
		}
	}
	return nil
}

// InstallPresent installs hooks for every tool present in home.
func InstallPresent(home, bin string, out io.Writer) error {
	for _, t := range Tools {
		if !t.Present(home) {
			fmt.Fprintf(out, "%s: not found, skipped\n", t.Name)
			continue
		}
		if err := InstallTool(home, t.ID, bin, out); err != nil {
			return fmt.Errorf("%s: %w", t.Name, err)
		}
	}
	return nil
}

// Status says, for each agent CLI on this machine, whether it has pierd's hooks.
func Status(home string, out io.Writer) {
	for _, t := range Tools {
		if !t.Present(home) {
			fmt.Fprintf(out, "%s: not found\n", t.Name)
			continue
		}
		if t.Hooked(home) {
			fmt.Fprintf(out, "%s: hooks in %s\n", t.Name, filepath.Join(t.ConfigDir(home), t.hookFile))
		} else {
			fmt.Fprintf(out, "%s: no hooks. To fix: pierd integrations install %s\n", t.Name, t.ID)
		}
	}
}

func toolByID(id string) (Tool, bool) {
	for _, t := range Tools {
		if t.ID == id {
			return t, true
		}
	}
	return Tool{}, false
}

func verb(changed bool) string {
	if changed {
		return "installed"
	}
	return "already present"
}

// finderFor finds agent CLIs for home: this user's through their shell
// (agentpath.Default), another's in its folders alone.
func finderFor(home string) *agentpath.Finder {
	if d := agentpath.Default(); filepath.Clean(d.Home) == filepath.Clean(home) {
		return d
	}
	return &agentpath.Finder{Home: home, Env: []string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}, NoVersion: true, NoNPM: true, NoCache: true}
}
