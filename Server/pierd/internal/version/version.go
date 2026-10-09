// Package version says which release a pierd binary is. Release builds stamp
// Version with -ldflags "-X pier/pierd/internal/version.Version=v1.2.3";
// anything built from a checkout is "dev".
//
// The build ID is the other half: a digest of the binary's own bytes. Two
// builds of one release are the same release, but only matching build IDs
// mean the same bytes, which is what `pierd upgrade` compares.
package version

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"runtime"
)

// Version is set at link time by release builds.
var Version = "dev"

// BuildID identifies a build by its bytes.
func BuildID(binary []byte) string {
	sum := sha256.Sum256(binary)
	return hex.EncodeToString(sum[:6])
}

// Line describes the running binary in one line, such as
// "pierd v0.1.0 (build 3f9a1c0b2d4e, linux/amd64)".
func Line(program string) string {
	build := "unknown"
	if exe, err := os.Executable(); err == nil {
		if b, err := os.ReadFile(exe); err == nil {
			build = BuildID(b)
		}
	}
	return fmt.Sprintf("%s %s (build %s, %s/%s)", program, Version, build, runtime.GOOS, runtime.GOARCH)
}
