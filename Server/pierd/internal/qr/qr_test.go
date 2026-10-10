package qr

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/pairing_link.golden.txt comes from another encoder:
// qrencode -l L -8 -m 0 -t ASCII, with "##" → "#" and "  " → ".".
func TestEncodeMatchesQrencode(t *testing.T) {
	link := "pier://192.0.2.10:7444?code=abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst&fp=765432zyxwvutsrqponmlkjihgfedcba765432zyxwvutsrqponm"
	m, err := Encode([]byte(link))
	if err != nil {
		t.Fatal(err)
	}
	var got bytes.Buffer
	for _, row := range m {
		for _, dark := range row {
			if dark {
				got.WriteByte('#')
			} else {
				got.WriteByte('.')
			}
		}
		got.WriteByte('\n')
	}
	want, err := os.ReadFile(filepath.Join("testdata", "pairing_link.golden.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Bytes(), want) {
		t.Fatalf("differs from qrencode\n--- got\n%s--- want\n%s", got.Bytes(), want)
	}
}

func TestVersionFitsTheData(t *testing.T) {
	for _, c := range []struct{ n, size int }{{0, 21}, {17, 21}, {18, 25}, {2953, 177}} {
		m, err := Encode(bytes.Repeat([]byte("a"), c.n))
		if err != nil || len(m) != c.size || len(m[0]) != c.size {
			t.Errorf("%d bytes: %d modules (%v), want %d", c.n, len(m), err, c.size)
		}
	}
	if _, err := Encode(bytes.Repeat([]byte("a"), 2954)); err == nil {
		t.Error("2954 bytes fit in version 40-L")
	}
}

// The "HELLO WORLD" 1-M example from thonky.com's QR code tutorial.
func TestReedSolomon(t *testing.T) {
	data := []byte{32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17}
	want := []byte{196, 35, 39, 119, 235, 215, 231, 226, 93, 23}
	if got := rsRemainder(data, rsDivisor(10)); !bytes.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestFormatAndVersionBits(t *testing.T) {
	for mask, want := range []int{0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976} {
		if got := formatBits(mask); got != want {
			t.Errorf("mask %d: %015b, want %015b", mask, got, want)
		}
	}
	for v, want := range map[int]int{7: 0x07C94, 21: 0x15683, 40: 0x28C69} {
		if got := versionBits(v); got != want {
			t.Errorf("version %d: %018b, want %018b", v, got, want)
		}
	}
}

func TestTerminalDrawsTwoRowsPerLine(t *testing.T) {
	lines := strings.Split(strings.TrimSuffix(Terminal([][]bool{{true, false}, {false, true}}), "\n"), "\n")
	if len(lines) != 3 || !strings.Contains(lines[1], "  ▀▄  ") {
		t.Fatalf("%q", lines)
	}
}
