package service

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestComposePATHKeepsTheUsersOrderOnce(t *testing.T) {
	got := ComposePATH("/opt/homebrew/bin::relative:/usr/bin:/opt/homebrew/bin/", "/h")
	want := "/opt/homebrew/bin:/usr/bin:/opt/homebrew/sbin:/usr/local/bin:/h/.local/bin:/bin:/usr/sbin:/sbin"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

// The login shell's PATH is read past whatever its startup files print.
func TestLoginShellPATH(t *testing.T) {
	dir := t.TempDir()
	shell := filepath.Join(dir, "sh")
	os.WriteFile(shell, []byte("#!/bin/sh\necho 'Welcome!'\nPATH=/from/login:/usr/bin\nexport PATH\nshift\neval \"$1\"\necho bye\n"), 0o755)
	t.Setenv("SHELL", shell)
	got, err := LoginShellPATH(5 * time.Second)
	if err != nil || got != "/from/login:/usr/bin" {
		t.Fatalf("got %q, %v", got, err)
	}
	os.WriteFile(shell, []byte("#!/bin/sh\nexec sleep 10\n"), 0o755)
	start := time.Now()
	if _, err := LoginShellPATH(300 * time.Millisecond); err == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("a hung shell: %v after %s", err, time.Since(start))
	}
}
