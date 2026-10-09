package box

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"pier/pierd/internal/groups"
	"pier/pierd/internal/hooks"
)

// Scripts are a location's worktree lifecycle commands. They get
// PIER_ROOT_PATH, PIER_WORKTREE_PATH and PIER_WORKTREE_NAME, and the same
// under Orca's ORCA_* names, so a script written for Orca runs unchanged.
type Scripts struct {
	Setup   string `json:"setup,omitempty"`
	Archive string `json:"archive,omitempty"`
	// From says where the scripts came from: "pierd" when set on the
	// location (the app reads it), "repo" from the
	// repository's config file.
	From string `json:"from,omitempty"`
}

// RepoConfigFile is where a repository describes how pierd sets up its
// worktrees, committed alongside the code so every box does the same.
const RepoConfigFile = ".pier/config.json"

// repoConfigPath is repo's config file, RepoConfigFile.
func repoConfigPath(repo string) string {
	return filepath.Join(repo, RepoConfigFile)
}

// RepoConfig is a repository's .pier/config.json.
type RepoConfig struct {
	Setup   string `json:"setup,omitempty"`
	Archive string `json:"archive,omitempty"`
	// Agents adds ways to start agents here, or replaces built-ins by ID,
	// e.g. {"id": "claude", "command": "claude --model opus"}.
	Agents []AgentPreset `json:"agents,omitempty"`
	// Ports is how many ports each worktree needs ($PIER_PORT,
	// $PIER_PORT_1, …). Every worktree has at least one.
	Ports int `json:"ports,omitempty"`
	// Env is added to everything run in a worktree, with $PIER_* expanded:
	// {"DATABASE_URL": "postgres://localhost/$PIER_WORKTREE_SLUG"}.
	Env map[string]string `json:"env,omitempty"`
	// Services run in every worktree, such as its dev server.
	Services []WorktreeService `json:"services,omitempty"`
	// Hooks run for this repository's events only, in the worktree.
	Hooks []hooks.Hook `json:"hooks,omitempty"`
}

// scriptsFor is the location's own scripts if set, otherwise the
// repository's.
func scriptsFor(saved savedLocation) Scripts {
	repo, _, _ := repoLayer(saved)
	local := RepoConfig{Setup: saved.Setup, Archive: saved.Archive}
	if saved.Config != nil {
		local = merge(local, *saved.Config)
	}
	c := merge(repo, local)
	from := ""
	switch {
	case local.Setup != "" || local.Archive != "":
		from = "box"
	case repo.Setup != "" || repo.Archive != "":
		from = "repo"
	}
	return Scripts{Setup: c.Setup, Archive: c.Archive, From: from}
}

// runScript runs a lifecycle script in the worktree through a login shell, so
// tools the user installed are on PATH, logging to logPath.
// quietEnv keeps setup that runs unattended (a team project's init, a
// worktree's setup script) from stopping at a question nobody sees:
// corepack asks before it downloads the yarn or pnpm a repository pins.
var quietEnv = []string{"COREPACK_ENABLE_DOWNLOAD_PROMPT=0"}

func runScript(ctx context.Context, script, repo, dir, name, logPath string, timeout time.Duration, extra []string) error {
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		return err
	}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer log.Close()
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	cmd := groups.CommandContext(ctx, shell, "-lc", script)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"PIER_ROOT_PATH="+repo, "PIER_WORKTREE_PATH="+dir, "PIER_WORKTREE_NAME="+name,
		"ORCA_ROOT_PATH="+repo, "ORCA_WORKTREE_PATH="+dir, "ORCA_WORKSPACE_NAME="+name)
	// A script has no terminal to answer a question in: corepack fetches
	// the yarn or pnpm a repository pins without asking. The repository's
	// own env (extra) can say otherwise.
	cmd.Env = append(cmd.Env, quietEnv...)
	cmd.Env = append(cmd.Env, extra...)
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Run(); err != nil {
		// What the script said last is why it failed: the error carries it,
		// so the app's Details can show it without a trip to the box.
		if tail := logTail(logPath, 40, 4096); tail != "" {
			return fmt.Errorf("%v (log: %s)\n%s", err, logPath, tail)
		}
		return fmt.Errorf("%v (log: %s)", err, logPath)
	}
	return nil
}

// logTail is the last lines of a log, at most max bytes of them.
func logTail(path string, lines, max int) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	if len(b) > max {
		b = b[len(b)-max:]
	}
	all := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	return strings.TrimSpace(strings.Join(all, "\n"))
}
