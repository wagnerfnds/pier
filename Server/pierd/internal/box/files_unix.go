//go:build unix

package box

import (
	"io/fs"
	"os"
	"syscall"
)

// hardLinks is how many names a file has.
func hardLinks(st fs.FileInfo) uint64 {
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		return uint64(s.Nlink)
	}
	return 1
}

// keepOwner gives f the owner and group old had, as far as the box's user
// may: a group the user belongs to (a file a web server reads), the user's
// own uid. Failing is fine: the save goes on with the user's own.
func keepOwner(f *os.File, old fs.FileInfo) {
	if s, ok := old.Sys().(*syscall.Stat_t); ok {
		_ = f.Chown(int(s.Uid), int(s.Gid))
	}
}
