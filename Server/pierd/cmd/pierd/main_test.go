package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"pier/pierd/internal/trust"
)

func TestPushListen(t *testing.T) {
	for _, tc := range []struct {
		cfg  string
		want []string
	}{
		{"", nil},
		{"off", nil},
		{"10.0.0.1:7446, 100.64.0.2:7446", []string{"10.0.0.1:7446", "100.64.0.2:7446"}},
	} {
		got := pushListen(tc.cfg)
		if b, _ := json.Marshal(got); string(b) != func() string { b, _ := json.Marshal(tc.want); return string(b) }() {
			t.Errorf("pushListen(%q) = %v, want %v", tc.cfg, got, tc.want)
		}
	}
}

// install --name / --ports leave settings files that serve reads: a shared box's users each name their own pierd.
func TestBoxNameSetting(t *testing.T) {
	b := boxHome{dir: t.TempDir()}
	host, _ := os.Hostname()
	if got := b.name(); got != trust.NameFromHostname(host, "box") {
		t.Fatalf("default name %q", got)
	}
	if err := os.WriteFile(filepath.Join(b.dir, "name"), []byte("Pier Maria\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := b.name(); got != "pier-maria" {
		t.Fatalf("name %q", got)
	}
}

// A socket the command may not reach (an agent's sandbox: Codex's says
// EPERM; a socket without permission, EACCES, stands in for it here) says
// what to do, not only the dial's words.
func TestBoxCommandSaysWhenItCannotReachTheSocket(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reaches any socket")
	}
	dir, err := os.MkdirTemp("/tmp", "pbs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	b := boxHome{dir: dir}
	ln, err := net.Listen("unix", b.socket())
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	os.Chmod(b.socket(), 0)
	err = runLocal(b, []string{"capture", "ls", "--session", "s"})
	if err == nil || !strings.Contains(err.Error(), "A sandbox keeps this command from pierd's socket") || !strings.Contains(err.Error(), b.socket()) {
		t.Fatalf("err = %v", err)
	}
}
