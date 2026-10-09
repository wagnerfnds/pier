package box

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A fake /proc: what the Linux snapshot reads from each process.
func TestReadProcFSReadsAFixture(t *testing.T) {
	root := t.TempDir()
	write := func(rel, s string) {
		p := filepath.Join(root, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("stat", "cpu  1 2 3\nbtime 1700000000\n")
	// pid (comm with space) state ppid … utime=250 stime=50 … starttime=1000 vsize rss=2560 pages
	stat := "123 (Chrome Helper) S 100 1 1 0 -1 0 0 0 0 0 250 50 0 0 20 0 1 0 1000 1000000 2560 0"
	write("123/stat", stat)
	write("123/status", "Name:\tchrome\nUid:\t1000\t1000\t1000\t1000\n")
	write("123/cmdline", strings.Join([]string{"/opt/acme/chrome", "--type=renderer"}, "\x00")+"\x00")
	write("123/environ", "HOME=/home/acme\x00PIER_SESSION=acme-task\x00SECRET=x\x00TMUX=/tmp/tmux-1000/pier,1,0\x00")
	write("123/cgroup", "0::/user.slice/user-1000.slice/user@1000.service/app.slice/pier-acme-task-x.scope\n")
	write("124/stat", stat)
	write("124/status", "Uid:\t0\t0\t0\t0\n") // someone else's
	write("self/stat", stat)
	got, err := readProcFS(root, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("got %+v", got)
	}
	p := got[0]
	if p.PID != 123 || p.PPID != 100 || p.Name != "Chrome Helper" || p.CPU != 3 || p.StartKey != 1000 ||
		!p.Start.Equal(time.Unix(1700000010, 0)) || p.RSS != 2560*uint64(os.Getpagesize()) {
		t.Fatalf("stat = %+v", p)
	}
	if len(p.Args) != 2 || p.Args[1] != "--type=renderer" {
		t.Fatalf("args = %q", p.Args)
	}
	if p.Env["PIER_SESSION"] != "acme-task" || p.Env["TMUX"] == "" || p.Env["SECRET"] != "" || p.Env["HOME"] != "" {
		t.Fatalf("env keeps only pier's markers: %v", p.Env)
	}
	if !strings.HasSuffix(p.Cgroup, "/pier-acme-task-x.scope") {
		t.Fatalf("cgroup = %q", p.Cgroup)
	}
}
