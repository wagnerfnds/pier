package box

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The box over the last half hour, for the app's charts: how busy its CPU
// was (a percentage measured from /proc/stat, not the load average), how
// full its memory, and how hot it runs, sampled every 15 s while pierd runs.
// `GET /v1/stats` carries the samples (`history`) and the latest of each.

const (
	sampleEvery = 15 * time.Second
	sampleKeep  = 120 // half an hour
)

// History is the samples, oldest first, one every IntervalS seconds; a
// value is null where it could not be read (no sensor, the first CPU tick).
type History struct {
	IntervalS int        `json:"interval_s"`
	CPU       []*float64 `json:"cpu"`
	Memory    []*float64 `json:"memory"`
	Temp      []*float64 `json:"temp"`
}

// Sampler keeps the samples. Its zero value works; Run fills it.
type Sampler struct {
	Proc, Sys, Cgroup string

	mu         sync.Mutex
	cpu, mem   []*float64
	temp       []*float64
	prevBusy   uint64
	prevTotal  uint64
	cpuNow     *float64
	tempNow    *float64
	sampledNow bool
}

// Run samples until ctx ends.
func (s *Sampler) Run(ctx context.Context) {
	s.Sample()
	t := time.NewTicker(sampleEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Sample()
		}
	}
}

func (s *Sampler) paths() (proc, sys, cgroup string) {
	proc, sys, cgroup = s.Proc, s.Sys, s.Cgroup
	if proc == "" {
		proc = "/proc"
	}
	if sys == "" {
		sys = "/sys"
	}
	if cgroup == "" {
		cgroup = "/sys/fs/cgroup"
	}
	return
}

// Sample takes one sample of each.
func (s *Sampler) Sample() {
	proc, sys, cgroup := s.paths()
	busy, total, ok := cpuTimes(filepath.Join(proc, "stat"))
	mem, _ := memInfo(filepath.Join(proc, "meminfo"))
	if limit, used, ok := cgroupMemory(cgroup); ok && limit < mem.Total {
		mem = Usage{Total: limit, Used: used}
	}
	temp := temperature(sys)

	s.mu.Lock()
	defer s.mu.Unlock()
	var cpu *float64
	if ok && s.prevTotal > 0 && total > s.prevTotal && busy >= s.prevBusy {
		v := round1(100 * float64(busy-s.prevBusy) / float64(total-s.prevTotal))
		cpu = &v
	}
	if ok {
		s.prevBusy, s.prevTotal = busy, total
	}
	var m *float64
	if mem.Total > 0 {
		v := round1(100 * float64(mem.Used) / float64(mem.Total))
		m = &v
	}
	s.cpu = keep(s.cpu, cpu)
	s.mem = keep(s.mem, m)
	s.temp = keep(s.temp, temp)
	s.cpuNow, s.tempNow, s.sampledNow = cpu, temp, true
}

// Snapshot is a copy of the samples, and the latest CPU and temperature.
func (s *Sampler) Snapshot() (h History, cpu, temp *float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	h = History{IntervalS: int(sampleEvery / time.Second),
		CPU: append([]*float64{}, s.cpu...), Memory: append([]*float64{}, s.mem...), Temp: append([]*float64{}, s.temp...)}
	return h, s.cpuNow, s.tempNow
}

func keep(xs []*float64, v *float64) []*float64 {
	xs = append(xs, v)
	if len(xs) > sampleKeep {
		xs = xs[len(xs)-sampleKeep:]
	}
	return xs
}

func round1(v float64) float64 { return math.Round(v*10) / 10 }

// cpuTimes reads the first line of /proc/stat: the time the CPUs were busy
// and the time in all, in ticks (iowait counts as idle).
func cpuTimes(path string) (busy, total uint64, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, false
	}
	line, _, _ := strings.Cut(string(b), "\n")
	f := strings.Fields(line)
	if len(f) < 5 || f[0] != "cpu" {
		return 0, 0, false
	}
	var idle uint64
	for i, x := range f[1:] {
		v, err := strconv.ParseUint(x, 10, 64)
		if err != nil {
			return 0, 0, false
		}
		// user nice system idle iowait irq softirq steal (guest is in user).
		if i >= 8 {
			break
		}
		total += v
		if i == 3 || i == 4 {
			idle += v
		}
	}
	return total - idle, total, true
}

// temperature is the CPU's, in °C: the package sensor of hwmon's coretemp,
// k10temp or zenpower when there is one, else the hottest thermal zone of a
// CPU-like type. nil on a box with no sensor (most VMs and containers).
func temperature(sys string) *float64 {
	best := math.NaN()
	consider := func(milli string) {
		v, err := strconv.ParseFloat(strings.TrimSpace(milli), 64)
		if err != nil || v <= 0 {
			return
		}
		c := v / 1000
		if c > 0 && c < 150 && (math.IsNaN(best) || c > best) {
			best = c
		}
	}
	mons, _ := filepath.Glob(filepath.Join(sys, "class", "hwmon", "hwmon*"))
	for _, m := range mons {
		name, _ := os.ReadFile(filepath.Join(m, "name"))
		switch strings.TrimSpace(string(name)) {
		case "coretemp", "k10temp", "zenpower", "cpu_thermal":
		default:
			continue
		}
		inputs, _ := filepath.Glob(filepath.Join(m, "temp*_input"))
		for _, in := range inputs {
			if b, err := os.ReadFile(in); err == nil {
				consider(string(b))
			}
		}
	}
	if math.IsNaN(best) {
		zones, _ := filepath.Glob(filepath.Join(sys, "class", "thermal", "thermal_zone*"))
		for _, z := range zones {
			typ, _ := os.ReadFile(filepath.Join(z, "type"))
			t := strings.ToLower(strings.TrimSpace(string(typ)))
			if !strings.Contains(t, "cpu") && !strings.Contains(t, "pkg") && !strings.Contains(t, "soc") && t != "acpitz" {
				continue
			}
			if b, err := os.ReadFile(filepath.Join(z, "temp")); err == nil {
				consider(string(b))
			}
		}
	}
	if math.IsNaN(best) {
		return nil
	}
	v := round1(best)
	return &v
}
