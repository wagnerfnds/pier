package box

import (
	"os"
	"testing"

	"pier/pierd/internal/agentpath"
)

// Rebases and merges make commits, which git refuses without an identity;
// a fresh CI machine has none.
func TestMain(m *testing.M) {
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
	os.Exit(m.Run())
}
