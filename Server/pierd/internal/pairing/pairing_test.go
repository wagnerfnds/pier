package pairing

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"pier/pierd/internal/identity"
)

func testToken(t *testing.T, address string) Token {
	t.Helper()
	var tok Token
	tok.Address = address
	rand.Read(tok.Fingerprint[:])
	rand.Read(tok.Code[:])
	return tok
}

func TestTokenRoundTrip(t *testing.T) {
	for _, address := range []string{"203.0.113.5:7444", "[2001:db8::1]:7444", "dev-alex.example:9000"} {
		tok := testToken(t, address)
		parsed, err := ParseToken("  " + tok.String() + "\n")
		if err != nil {
			t.Fatalf("%s: %v", address, err)
		}
		if parsed != tok {
			t.Fatalf("%s: round trip changed the token:\n got %+v\nwant %+v", address, parsed, tok)
		}
	}
}

func TestParseTokenRejectsMalformedLinks(t *testing.T) {
	good := testToken(t, "203.0.113.5:7444").String()
	fp := identity.Fingerprint{}.String()
	code := Code{}.String()
	for _, bad := range []string{
		"",
		"https://203.0.113.5:7444?code=" + code + "&fp=" + fp,
		"pier://203.0.113.5?code=" + code + "&fp=" + fp,
		"pier://203.0.113.5:0?code=" + code + "&fp=" + fp,
		"pier://203.0.113.5:70000?code=" + code + "&fp=" + fp,
		"pier://:7444?code=" + code + "&fp=" + fp,
		"pier://user@203.0.113.5:7444?code=" + code + "&fp=" + fp,
		"pier://203.0.113.5:7444/extra?code=" + code + "&fp=" + fp,
		"pier://203.0.113.5:7444?fp=" + fp,
		"pier://203.0.113.5:7444?code=" + code,
		"pier://203.0.113.5:7444?code=" + code[:10] + "&fp=" + fp,
		strings.Replace(good, "pier://", "pier:", 1),
	} {
		if _, err := ParseToken(bad); err == nil {
			t.Errorf("accepted malformed link %q", bad)
		}
	}
}

// pierd prints pier:// links, and reads nothing else.
func TestTokenLinksArePierLinks(t *testing.T) {
	tok := testToken(t, "203.0.113.5:7444")
	if !strings.HasPrefix(tok.String(), "pier://") {
		t.Fatalf("link %q is not a pier:// link", tok.String())
	}
	if _, err := ParseToken(strings.Replace(tok.String(), "pier://", "other://", 1)); err == nil {
		t.Fatal("accepted a link with another scheme")
	}
}

// The same vector as PierKit's proofVector test (PierKitTests.swift), so the
// app and pierd agree on the proof: HMAC-SHA256 with key 01*32 over
// "pier pair v1" || exporter 02*32 || the fingerprint of RFC 8032 test 1's key.
// python3: hmac.new(b"\x01"*32, b"pier pair v1" + b"\x02"*32 + fp, sha256).
func TestProofVector(t *testing.T) {
	if ExporterLabel != "EXPORTER-pier-pair-v1" || proofContext != "pier pair v1" {
		t.Fatalf("labels changed: %q %q; PierKit's Pairing.swift and Identity.swift must change with them", ExporterLabel, proofContext)
	}
	seed, _ := hex.DecodeString("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	spki, err := x509.MarshalPKIXPublicKey(ed25519.NewKeyFromSeed(seed).Public())
	if err != nil {
		t.Fatal(err)
	}
	client := identity.Fingerprint(sha256.Sum256(spki))
	var code Code
	for i := range code {
		code[i] = 1
	}
	got := hex.EncodeToString(Proof(code, bytes.Repeat([]byte{2}, ExporterSize), client))
	if want := "31031d35b2ec1c3ba97454b216cafb666943195fb24ffd064218a61c8da3caba"; got != want {
		t.Fatalf("proof = %s, want %s", got, want)
	}
}

func TestProofIsBoundToSessionClientAndCode(t *testing.T) {
	var code, otherCode Code
	rand.Read(code[:])
	rand.Read(otherCode[:])
	exporter := bytes.Repeat([]byte{1}, ExporterSize)
	otherExporter := bytes.Repeat([]byte{2}, ExporterSize)
	var client, otherClient identity.Fingerprint
	rand.Read(client[:])
	rand.Read(otherClient[:])

	proof := Proof(code, exporter, client)
	if !bytes.Equal(proof, Proof(code, exporter, client)) {
		t.Fatal("proof is not deterministic")
	}
	for name, other := range map[string][]byte{
		"another session": Proof(code, otherExporter, client),
		"another client":  Proof(code, exporter, otherClient),
		"another code":    Proof(otherCode, exporter, client),
	} {
		if bytes.Equal(proof, other) {
			t.Fatalf("proof for %s matches the original", name)
		}
	}
}

func TestPendingCodeIsSingleUse(t *testing.T) {
	p := NewPending(filepath.Join(t.TempDir(), "pairing.json"))
	now := time.Now()
	code, err := p.Issue(10*time.Minute, now)
	if err != nil {
		t.Fatal(err)
	}
	is := func(c Code) bool { return c == code }
	if ok, err := p.Consume(now, is); err != nil || !ok {
		t.Fatalf("first use: ok=%v err=%v", ok, err)
	}
	if ok, err := p.Consume(now, is); err != nil || ok {
		t.Fatalf("second use succeeded: ok=%v err=%v", ok, err)
	}
}

func TestPendingCodeExpires(t *testing.T) {
	p := NewPending(filepath.Join(t.TempDir(), "pairing.json"))
	now := time.Now()
	code, err := p.Issue(10*time.Minute, now)
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := p.Consume(now.Add(10*time.Minute), func(c Code) bool { return c == code }); err != nil || ok {
		t.Fatalf("expired code accepted: ok=%v err=%v", ok, err)
	}
}

func TestPendingCodeCannotBeConsumedTwiceConcurrently(t *testing.T) {
	p := NewPending(filepath.Join(t.TempDir(), "pairing.json"))
	now := time.Now()
	code, err := p.Issue(10*time.Minute, now)
	if err != nil {
		t.Fatal(err)
	}
	var wins atomic.Int32
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := p.Consume(now, func(c Code) bool { return c == code })
			if err != nil {
				t.Error(err)
			}
			if ok {
				wins.Add(1)
			}
		}()
	}
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("code consumed %d times, want exactly 1", wins.Load())
	}
}

func TestIssuingKeepsOtherLiveCodes(t *testing.T) {
	p := NewPending(filepath.Join(t.TempDir(), "pairing.json"))
	now := time.Now()
	first, _ := p.Issue(10*time.Minute, now)
	second, _ := p.Issue(10*time.Minute, now)
	for _, code := range []Code{first, second} {
		if ok, err := p.Consume(now, func(c Code) bool { return c == code }); err != nil || !ok {
			t.Fatalf("code issued alongside another was lost: ok=%v err=%v", ok, err)
		}
	}
}
