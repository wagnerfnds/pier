package main

import (
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"

	"pier/pierd/internal/pairing"
)

// The laptop agent pairs with this computer's own pierd (Use this Mac)
// through pair --json: a link for exactly the address it was given.
func TestPairPrintsJSONForTheAgent(t *testing.T) {
	b := boxHome{dir: t.TempDir()}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	err = pair(b, []string{"--json", "--ttl", "2m", "--address", "127.0.0.1:7445"})
	os.Stdout = stdout
	w.Close()
	if err != nil {
		t.Fatal(err)
	}
	out, _ := io.ReadAll(r)
	var got struct{ Link, Address, Fingerprint, Expires string }
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("not JSON: %q", out)
	}
	tok, err := pairing.ParseToken(got.Link)
	if err != nil || tok.Address != "127.0.0.1:7445" || got.Address != tok.Address || tok.Fingerprint.String() != got.Fingerprint || got.Expires == "" {
		t.Fatalf("pair --json = %s (%+v, %v)", out, tok, err)
	}
	if strings.Contains(string(out), "On your laptop") {
		t.Fatal("pair --json printed the instructions too")
	}
}
