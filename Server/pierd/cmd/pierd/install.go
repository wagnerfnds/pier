package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/integrations"
	"pier/pierd/internal/service"
	"pier/pierd/internal/statefile"
)

// serviceName is pierd's unit: pierd.service under systemd, the launchd
// label app.pier.pierd on a Mac.
func serviceName() string {
	if runtime.GOOS == "darwin" {
		return "app.pier.pierd"
	}
	return "pierd"
}

func daemonService(b boxHome, listen string) service.Spec {
	exe, _ := os.Executable()
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	args := []string{"serve"}
	if listen != "" {
		args = append(args, "--listen", listen)
	}
	return service.Spec{
		Name:        serviceName(),
		Description: "Pier box server",
		Program:     exe,
		Args:        args,
		Env:         map[string]string{"PIER_HOME": b.home()},
		LogPath:     filepath.Join(b.dir, "pierd.log"),
		// Agent sessions (tmux) and worktree services (their own units)
		// must survive pierd restarting or being upgraded.
		KeepChildren: true,
	}
}

// install runs pierd serve as a user service (a systemd user unit; a
// launchd agent on a Mac), then installs the agent CLIs' hooks.
func install(b boxHome, args []string) error {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	listen := fs.String("listen", "", "address to listen on (default: this box's tailnet address only)")
	keep := fs.Bool("keep-listen", false, "keep the address an installed pierd listens on, unless it was a tailnet address")
	noIntegrations := fs.Bool("no-integrations", false, "don't install hooks for the agent CLIs on this box")
	name := fs.String("name", "", "the name the apps show for this box (default: the hostname); kept for later installs")
	ports := fs.String("ports", "", "FIRST-LAST: the ports worktrees get (default 41000-48999); kept for later installs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return errors.New("usage: pierd install [--listen ADDR] [--keep-listen] [--name NAME] [--ports FIRST-LAST] [--no-integrations]")
	}
	if *ports != "" {
		if _, _, err := box.ParsePortRange(*ports); err != nil {
			return err
		}
	}
	for file, v := range map[string]string{"name": *name, "ports": *ports} {
		if v == "" {
			continue
		}
		if err := statefile.Write(filepath.Join(b.dir, file), []byte(strings.TrimSpace(v)+"\n")); err != nil {
			return err
		}
	}
	if err := service.Preflight(); err != nil {
		return err
	}
	current := ""
	if path, err := service.UnitPath(daemonService(b, "")); err == nil {
		if unit, err := os.ReadFile(path); err == nil {
			current = unitListen(unit)
		}
	}
	addr, err := chooseListen(*listen, *keep, current, interfaceIPs())
	if err != nil {
		return err
	}
	spec := daemonService(b, addr)
	// systemd's user manager has a PATH without ~/.local/bin, where agent
	// CLIs install themselves: the unit carries the user's own PATH, as
	// their login shell sets it now.
	spec.Env["PATH"] = service.ServicePATH()
	started := time.Now()
	path, err := service.Install(spec)
	if err != nil {
		return err
	}
	if err := waitServing(b, started, 20*time.Second); err != nil {
		return fmt.Errorf("installed %s, but pierd did not start: %w%s", path, err, logTail(spec.LogPath, 8))
	}
	fmt.Printf("Installed %s; pierd is serving on %s.\n", path, addr)
	if !*noIntegrations {
		if home, err := os.UserHomeDir(); err == nil {
			fmt.Println("Agent hooks:")
			if err := integrations.InstallPresent(home, spec.Program, indented{os.Stdout}); err != nil {
				fmt.Printf("  not installed: %v\n", err)
			}
		}
	}
	if runtime.GOOS == "linux" && !lingering() {
		fmt.Println("Warning: user lingering is off, so pierd stops when you log out.")
		fmt.Println("Enable it once with: sudo loginctl enable-linger " + currentUser())
	}
	fmt.Println("Next: pierd pair")
	return nil
}

// uninstall removes the service; pierd's state stays.
func uninstall(b boxHome) error {
	path, err := service.Uninstall(daemonService(b, ""))
	if err != nil {
		return err
	}
	if path == "" {
		fmt.Println("pierd is not installed as a service.")
	} else {
		fmt.Println("Removed " + path + " (pierd's state in " + b.home() + " is kept)")
	}
	return nil
}

// indented writes each line with two spaces in front.
type indented struct{ w io.Writer }

func (i indented) Write(p []byte) (int, error) {
	s := strings.TrimSuffix(string(p), "\n")
	_, err := fmt.Fprint(i.w, "  "+strings.ReplaceAll(s, "\n", "\n  ")+"\n")
	return len(p), err
}

// chooseListen is where the service will listen: --listen when given; with
// --keep-listen, the address an installed unit already names, unless that is
// a tailnet address (the box may have a new one); otherwise the tailnet
// address. An address on every interface is only ever used when asked for.
func chooseListen(flagListen string, keep bool, current string, ips []net.IP) (string, error) {
	if flagListen != "" {
		return flagListen, nil
	}
	if keep && current != "" && !onTailnet(current) {
		return current, nil
	}
	return defaultListen(ips)
}

func onTailnet(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		return false
	}
	addr, err := netip.ParseAddr(host)
	return err == nil && carrierGradeNAT.Contains(addr.Unmap())
}

// unitListen reads the --listen an installed systemd unit or launchd plist
// starts pierd with.
var listenArg = regexp.MustCompile(`--listen(?:</string>\s*<string>|\s+)"?([^\s<"]+)`)

func unitListen(unit []byte) string {
	if m := listenArg.FindSubmatch(unit); m != nil {
		return string(m[1])
	}
	return ""
}

// waitServing waits for the service to answer on its local socket, started
// after the install began: a socket left by the build it replaced does not
// count. `pierd pair` straight after then advertises where it listens.
func waitServing(b boxHome, since time.Time, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if st, err := os.Stat(filepath.Join(b.dir, "listen")); err == nil && !st.ModTime().Before(since.Truncate(time.Second)) {
			if c, err := net.DialTimeout("unix", b.socket(), time.Second); err == nil {
				c.Close()
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("it did not answer within %s", timeout)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// logTail is the end of the daemon's log, to show why it did not start.
func logTail(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return "\nThe end of " + path + ":\n  " + strings.Join(lines, "\n  ")
}

func lingering() bool {
	out, err := exec.Command("loginctl", "show-user", currentUser(), "-p", "Linger").Output()
	return err == nil && strings.TrimSpace(string(out)) == "Linger=yes"
}

func currentUser() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return os.Getenv("USER")
}
