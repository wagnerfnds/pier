package box

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, path, s string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

// The CPU is the busy share of the ticks between two samples (iowait counts as
// idle); memory follows the cgroup's limit; the temperature is the CPU
// package's hwmon sensor, else a CPU thermal zone, and none on a box without.
func TestSamplerMeasuresCPUMemoryAndTemperature(t *testing.T) {
	dir := t.TempDir()
	proc, sys := filepath.Join(dir, "proc"), filepath.Join(dir, "sys")
	write(t, filepath.Join(proc, "meminfo"), "MemTotal: 1000 kB\nMemAvailable: 750 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n")
	write(t, filepath.Join(proc, "stat"), "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3\n")
	write(t, filepath.Join(sys, "class", "thermal", "thermal_zone0", "type"), "acpitz\n")
	write(t, filepath.Join(sys, "class", "thermal", "thermal_zone0", "temp"), "41000\n")
	write(t, filepath.Join(sys, "class", "thermal", "thermal_zone1", "type"), "iwlwifi_1\n")
	write(t, filepath.Join(sys, "class", "thermal", "thermal_zone1", "temp"), "90000\n")
	s := &Sampler{Proc: proc, Sys: sys, Cgroup: filepath.Join(dir, "nocgroup")}

	s.Sample()
	h, cpu, temp := s.Snapshot()
	if cpu != nil || len(h.CPU) != 1 || h.CPU[0] != nil {
		t.Fatalf("the first sample has no CPU share yet: %v %v", cpu, h.CPU)
	}
	if temp == nil || *temp != 41 {
		t.Fatalf("temp %v (the Wi-Fi zone is not the CPU)", temp)
	}
	if h.Memory[0] == nil || *h.Memory[0] != 25 {
		t.Fatalf("memory %v", h.Memory)
	}

	// 1000 more ticks, 300 of them busy (user 200 + system 100), 700 idle or iowait.
	write(t, filepath.Join(proc, "stat"), "cpu  300 0 200 1200 300 0 0 0 0 0\n")
	write(t, filepath.Join(sys, "class", "hwmon", "hwmon3", "name"), "coretemp\n")
	write(t, filepath.Join(sys, "class", "hwmon", "hwmon3", "temp1_input"), "55500\n")
	write(t, filepath.Join(sys, "class", "hwmon", "hwmon3", "temp2_input"), "52000\n")
	s.Sample()
	h, cpu, temp = s.Snapshot()
	if cpu == nil || *cpu != 30 || len(h.CPU) != 2 || *h.CPU[1] != 30 {
		t.Fatalf("cpu %v %v", cpu, h.CPU)
	}
	if temp == nil || *temp != 55.5 {
		t.Fatalf("temp %v: the package sensor wins", temp)
	}
	if h.IntervalS != 15 {
		t.Fatal(h.IntervalS)
	}

	for range sampleKeep + 10 {
		s.Sample()
	}
	if h, _, _ := s.Snapshot(); len(h.CPU) != sampleKeep || len(h.Temp) != sampleKeep || len(h.Memory) != sampleKeep {
		t.Fatalf("kept %d", len(h.CPU))
	}

	none := &Sampler{Proc: proc, Sys: filepath.Join(dir, "empty"), Cgroup: filepath.Join(dir, "nocgroup")}
	none.Sample()
	if _, _, temp := none.Snapshot(); temp != nil {
		t.Fatalf("a box with no sensor reads %v", *temp)
	}
}
