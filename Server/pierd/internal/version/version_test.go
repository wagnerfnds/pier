package version

import (
	"strings"
	"testing"
)

func TestLineNamesTheReleaseAndTheBuild(t *testing.T) {
	old := Version
	t.Cleanup(func() { Version = old })
	Version = "v1.2.3"
	line := Line("pierd")
	if !strings.HasPrefix(line, "pierd v1.2.3 (build ") || strings.Contains(line, "build unknown") {
		t.Errorf("Line = %q", line)
	}
	if BuildID([]byte("a")) == BuildID([]byte("b")) || len(BuildID(nil)) != 12 {
		t.Error("build IDs must tell builds apart, in 12 hex digits")
	}
}
