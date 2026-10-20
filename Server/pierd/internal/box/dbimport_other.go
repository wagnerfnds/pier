//go:build !linux

package box

import "syscall"

// importServerAttr runs an import's server as cred (nil: the caller).
func importServerAttr(cred *syscall.Credential) *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Credential: cred}
}

// processRuns cannot tell here: a server left behind is not killed.
func processRuns(pid int, dir string) bool { return false }

func memAvailable() int64 { return 0 }
