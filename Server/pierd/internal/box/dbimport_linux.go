package box

import (
	"bytes"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// importServerAttr runs an import's server as cred (nil: the caller), and
// kills it if the import dies first (killed, its terminal gone): it would go
// on serving the raw data.
func importServerAttr(cred *syscall.Credential) *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Credential: cred, Pdeathsig: syscall.SIGKILL}
}

// processRuns says pid is a program run with dir in its command line: the
// server of an import cut short, not whatever took its pid since.
func processRuns(pid int, dir string) bool {
	cmdline, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	return err == nil && bytes.Contains(cmdline, []byte(dir))
}

// memAvailable is how much memory the machine has free, in bytes (0 when it
// cannot tell).
func memAvailable() int64 {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, l := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(l, "MemAvailable:"); ok {
			kb, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimSpace(v), " kB"), 10, 64)
			return kb << 10
		}
	}
	return 0
}
