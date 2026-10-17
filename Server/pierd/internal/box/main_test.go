package box

import (
	"context"
	"os"
	"testing"

	"pier/pierd/internal/agentpath"
)

// Rebases and merges make commits, which git refuses without an identity;
// a fresh CI machine has none.
func TestMain(m *testing.M) {
	// The stand-in claude and codex of the MCP tests are this binary run
	// again (mcp_test.go).
	if tool := os.Getenv("FAKE_AGENT_CLI"); tool != "" {
		os.Exit(fakeAgentCLI(tool, os.Args[1:]))
	}
	for k, v := range map[string]string{
		"GIT_AUTHOR_NAME": "pier test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "pier test", "GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		if os.Getenv(k) == "" {
			os.Setenv(k, v)
		}
	}
	// Agent CLIs are looked for on the test's PATH and HOME each time, never
	// through the developer's own shell.
	for _, k := range []string{"NVM_DIR", "FNM_DIR", "VOLTA_HOME", "BUN_INSTALL", "PNPM_HOME", "XDG_DATA_HOME"} {
		os.Unsetenv(k)
	}
	testFinder := &agentpath.Finder{NoCache: true, NoVersion: true, NoNPM: true, SystemDirs: []string{}}
	agentFinder = func() *agentpath.Finder { return testFinder }
	// The agents' configs pierd writes trust into (trust.go) are a scratch
	// home's, never the developer's own.
	os.Unsetenv("CLAUDE_CONFIG_DIR")
	os.Unsetenv("CODEX_HOME")
	home, err := os.MkdirTemp("", "pierd-agents-home-")
	if err != nil {
		panic(err)
	}
	agentHome = func() (string, error) { return home, nil }
	logf = func(string, ...any) {}
	// A worktree a test makes is never handed to the Claude Code of the
	// machine running it, nor are its settings or sudo touched: tests that
	// want a setup agent ask for one, with a fake claude first on PATH.
	autoSetupAgents = false
	allowBypass = func([]string) error { return nil }
	canSudo = func(context.Context) bool { return false }
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}
