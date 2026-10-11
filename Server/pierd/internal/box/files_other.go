//go:build !unix

package box

import (
	"io/fs"
	"os"
)

func hardLinks(fs.FileInfo) uint64 { return 1 }

func keepOwner(*os.File, fs.FileInfo) {}
