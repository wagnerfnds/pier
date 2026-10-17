package main

import (
	"strings"
	"testing"
)

// The install script passes PIERD_NO_TOOLS on to setup, as --no-tools.
func TestSkipTools(t *testing.T) {
	for v, want := range map[string]bool{"": false, "0": false, "1": true, "true": true, "YES": true} {
		t.Setenv("PIERD_NO_TOOLS", v)
		if got := skipTools(false); got != want {
			t.Errorf("PIERD_NO_TOOLS=%q: skip = %v", v, got)
		}
	}
	t.Setenv("PIERD_NO_TOOLS", "")
	if !skipTools(true) {
		t.Error("--no-tools did not skip")
	}
}

// An installer's output is indented line by line, however its writes are cut.
func TestLineIndent(t *testing.T) {
	var b strings.Builder
	w := &lineIndent{w: &b, prefix: "  "}
	for _, part := range []string{"Down", "loading…\nSetting", " up\n", "\nDone\n"} {
		w.Write([]byte(part))
	}
	if want := "  Downloading…\n  Setting up\n  \n  Done\n"; b.String() != want {
		t.Fatalf("got %q, want %q", b.String(), want)
	}
}
