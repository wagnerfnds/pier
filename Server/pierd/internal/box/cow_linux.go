package box

import "syscall"

// copyKind says how a copy on the disk holding path goes: "reflink" where
// the file system shares blocks between copies (btrfs), else "copy". XFS
// shares them only when made with reflink=1, which its magic number does
// not tell, so it reads "copy" here and its copies may still be quick.
func copyKind(path string) string {
	var st syscall.Statfs_t
	if syscall.Statfs(path, &st) != nil {
		return ""
	}
	const btrfsMagic = 0x9123683e
	if uint64(st.Type) == btrfsMagic {
		return "reflink"
	}
	return "copy"
}
