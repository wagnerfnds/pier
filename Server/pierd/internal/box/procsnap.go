package box

import (
	"time"
)

// procStat is one of the box user's processes as the processes list needs
// it: its place in the tree, what it runs, what it costs and the few
// environment variables that say who started it.
type procStat struct {
	PID, PPID int
	// Name is the kernel's short name for it (comm), Exe its program's
	// path when the system says, Args its argv.
	Name string
	Exe  string
	Args []string
	// Start is when it started; StartKey is the same as the system keeps
	// it, so a process id the system gave to something else is never taken
	// for this process.
	Start    time.Time
	StartKey uint64
	// CPU is the processor time it has used, in seconds; CPUPercent its
	// current use (100 is one core), when known.
	CPU        float64
	CPUPercent float64
	RSS        uint64
	// Env holds only the variables in procEnvKeys.
	Env map[string]string
	// Cgroup is its cgroup v2 path, on Linux.
	Cgroup string
}

type procKey struct {
	pid   int
	start uint64
}
