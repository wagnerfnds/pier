package groups

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

func fake(db []string, proc []int) Source {
	names := map[string]string{"1000": "dev", "998": "docker", "27": "sudo", "1500": "libvirt"}
	return Source{
		Database: func() (string, []string, error) { return "1000", db, nil },
		Process:  func() ([]int, error) { return proc, nil },
		Name: func(gid string) (string, error) {
			if n, ok := names[gid]; ok {
				return n, nil
			}
			return "", errors.New("no such group")
		},
		SG:   func() string { return "/usr/bin/sg" },
		GOOS: "linux",
		UID:  1000,
	}
}

func TestFind(t *testing.T) {
	// pierd started before the docker step added dev to docker.
	m := fake([]string{"1000", "27", "998"}, []int{1000, 27}).Find()
	if !reflect.DeepEqual(m.Groups, []string{"docker"}) || m.Primary != "dev" || m.SG != "/usr/bin/sg" {
		t.Fatalf("%+v", m)
	}
	for name, s := range map[string]Source{
		"nothing new": fake([]string{"1000", "27", "998"}, []int{1000, 27, 998}),
		"not linux":   func() Source { s := fake([]string{"1000", "998"}, []int{1000}); s.GOOS = "darwin"; return s }(),
		"root":        func() Source { s := fake([]string{"1000", "998"}, []int{1000}); s.UID = 0; return s }(),
		"no sg": func() Source {
			s := fake([]string{"1000", "998"}, []int{1000})
			s.SG = func() string { return "" }
			return s
		}(),
		"unknown group": fake([]string{"1000", "4242"}, []int{1000}),
	} {
		if m := s.Find(); len(m.Groups) != 0 || len(m.Wrap([]string{"x"})) != 1 {
			t.Errorf("%s: %+v", name, m)
		}
	}
}

func TestWrap(t *testing.T) {
	m := Missing{Groups: []string{"docker", "libvirt"}, Primary: "dev", SG: "/usr/bin/sg"}
	got := m.Wrap([]string{"/bin/bash", "-lc", "echo hi"})
	if len(got) != 4 || got[0] != "/usr/bin/sg" || got[1] != "docker" || got[2] != "-c" ||
		!strings.HasPrefix(got[3], "exec '/usr/bin/sg' 'libvirt' -c ") || !strings.Contains(got[3], "dev") {
		t.Fatalf("%q", got)
	}
	if got := (Missing{}).Wrap([]string{"a", "b"}); !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Fatal(got)
	}
}

// TestWrapRunsTheProgram runs the wrapped command with a stand-in sg that
// runs its -c through sh, as the real one does after setting the group:
// the program gets its arguments exactly.
func TestWrapRunsTheProgram(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip()
	}
	dir := t.TempDir()
	sg := dir + "/sg"
	if err := writeExec(sg, "#!/bin/sh\necho \"sg $1\" >>\""+dir+"/log\"\n[ \"$2\" = -c ] || exit 9\nexec /bin/sh -c \"$3\"\n"); err != nil {
		t.Fatal(err)
	}
	m := Missing{Groups: []string{"docker", "libvirt"}, Primary: "dev", SG: sg}
	argv := m.Wrap([]string{"/bin/sh", "-c", `printf '%s|' "$@"`, "sh", "it's", "a $HOME", `"q"`})
	out, err := exec.Command(argv[0], argv[1:]...).Output()
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != `it's|a $HOME|"q"|` {
		t.Fatalf("%q", out)
	}
	log, _ := readFile(dir + "/log")
	if strings.Join(strings.Fields(log), " ") != "sg docker sg libvirt sg dev" {
		t.Fatalf("sg ran as %q", log)
	}
}

func writeExec(p, s string) error { return os.WriteFile(p, []byte(s), 0o755) }
func readFile(p string) (string, error) {
	b, err := os.ReadFile(p)
	return string(b), err
}

// A command that runs out of time goes with everything it started: the
// shell is killed, and so is what it put in the background, which would
// otherwise keep the output open and the caller waiting.
func TestACommandThatTimesOutTakesItsChildrenWithIt(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	cmd := CommandContext(ctx, "/bin/sh", "-c", "sleep 5 & sleep 5")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	start := time.Now()
	if err := cmd.Run(); err == nil {
		t.Fatal("ran to the end")
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("Run took %v after a 300ms deadline: a child kept it waiting", took)
	}
}
