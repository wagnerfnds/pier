package main

import (
	"encoding/json"
	"os"
	"path/filepath"
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
