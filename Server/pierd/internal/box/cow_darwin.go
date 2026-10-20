package box

import "syscall"

// copyKind says how a copy on the disk holding path goes: "reflink" on APFS,
// where cp -c clones files, else "copy".
func copyKind(path string) string {
	var st syscall.Statfs_t
	if syscall.Statfs(path, &st) != nil {
		return ""
	}
	var name []byte
	for _, c := range st.Fstypename {
		if c == 0 {
			break
		}
		name = append(name, byte(c))
	}
	if string(name) == "apfs" {
		return "reflink"
	}
	return "copy"
}
