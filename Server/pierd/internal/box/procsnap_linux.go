package box

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// userHZ is the clock tick /proc counts processor time in.
const userHZ = 100

func snapshotProcs() ([]procStat, error) {
	return readProcFS("/proc", os.Getuid())
}

// readProcFS reads uid's processes from a /proc at root (a fixture, in
// tests). A process that ends while it is read is left out.
func readProcFS(root string, uid int) ([]procStat, error) {
	ents, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	boot := bootTime(root)
	page := uint64(os.Getpagesize())
	var out []procStat
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 {
			continue
		}
		dir := filepath.Join(root, e.Name())
		if procUID(dir) != uid {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, "stat"))
		if err != nil {
			continue
		}
		p, ok := parseProcStat(raw, boot, page)
		if !ok {
			continue
		}
		p.PID = pid
		if b, err := os.ReadFile(filepath.Join(dir, "cmdline")); err == nil {
			p.Args = splitNul(b)
		}
		if b, err := os.ReadFile(filepath.Join(dir, "environ")); err == nil {
			p.Env = keepEnv(splitNul(b))
		}
		p.Exe, _ = os.Readlink(filepath.Join(dir, "exe"))
		p.Exe = strings.TrimSuffix(p.Exe, " (deleted)")
		if b, err := os.ReadFile(filepath.Join(dir, "cgroup")); err == nil {
			for _, l := range strings.Split(string(b), "\n") {
				if rest, ok := strings.CutPrefix(l, "0::"); ok {
					p.Cgroup = rest
				}
			}
		}
		out = append(out, p)
	}
	return out, nil
}

// procUID is whose process the folder is: the owner of /proc/PID, or in a
// fixture its status file's Uid line.
func procUID(dir string) int {
	if b, err := os.ReadFile(filepath.Join(dir, "status")); err == nil {
		sc := bufio.NewScanner(bytes.NewReader(b))
		for sc.Scan() {
			if rest, ok := strings.CutPrefix(sc.Text(), "Uid:"); ok {
				if f := strings.Fields(rest); len(f) > 0 {
					if n, err := strconv.Atoi(f[0]); err == nil {
						return n
					}
				}
			}
		}
	}
	fi, err := os.Stat(dir)
	if err != nil {
		return -1
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int(st.Uid)
	}
	return -1
}

// parseProcStat reads /proc/PID/stat: pid (comm) state ppid … utime stime
// … starttime vsize rss. comm may hold spaces and parentheses.
func parseProcStat(b []byte, boot time.Time, page uint64) (procStat, bool) {
	open, close := bytes.IndexByte(b, '('), bytes.LastIndexByte(b, ')')
	if open < 0 || close < open {
		return procStat{}, false
	}
	f := strings.Fields(string(b[close+1:]))
	if len(f) < 22 {
		return procStat{}, false
	}
	num := func(i int) uint64 { n, _ := strconv.ParseUint(f[i], 10, 64); return n }
	ppid, _ := strconv.Atoi(f[1])
	start := num(19)
	return procStat{
		PPID:     ppid,
		Name:     string(b[open+1 : close]),
		CPU:      float64(num(11)+num(12)) / userHZ,
		StartKey: start,
		Start:    boot.Add(time.Duration(start) * time.Second / userHZ),
		RSS:      num(21) * page,
	}, true
}

// bootTime is when the machine started, from /proc/stat's btime.
func bootTime(root string) time.Time {
	b, err := os.ReadFile(filepath.Join(root, "stat"))
	if err != nil {
		return time.Time{}
	}
	for _, l := range strings.Split(string(b), "\n") {
		if rest, ok := strings.CutPrefix(l, "btime "); ok {
			n, _ := strconv.ParseInt(strings.TrimSpace(rest), 10, 64)
			return time.Unix(n, 0)
		}
	}
	return time.Time{}
}

// procEnvKeys are the environment variables a snapshot keeps: they say
// which pierd session a process belongs to, and on which tmux server.
var procEnvKeys = map[string]bool{"PIER_SESSION": true, "TMUX": true}

// keepEnv is the procEnvKeys entries of a list of KEY=VALUE entries.
func keepEnv(entries []string) map[string]string {
	var env map[string]string
	for _, kv := range entries {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || !procEnvKeys[k] {
			continue
		}
		if env == nil {
			env = map[string]string{}
		}
		if _, dup := env[k]; !dup {
			env[k] = v
		}
	}
	return env
}

// splitNul splits a NUL-separated block, dropping empty entries.
func splitNul(b []byte) []string {
	var out []string
	for _, s := range strings.Split(string(b), "\x00") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}
