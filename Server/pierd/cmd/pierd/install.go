package main

import (
	"context"
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

// installOptions are what install and setup ask of installService.
type installOptions struct {
	listen       string // "" chooses (chooseListen)
	keep         bool   // keep the address an installed unit already names
	name, ports  string // kept in the box's settings when given
	integrations bool   // the agent CLIs' hooks
	next         string // the line printed last ("Next: pierd pair"), "" for none
}

// install runs pierd serve as a user service (a systemd user unit; a
// launchd agent on a Mac), then installs the agent CLIs' hooks.
func install(b boxHome, args []string) error {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	listen := fs.String("listen", "", "address to listen on (default: every interface, port "+defaultPort+")")
	keep := fs.Bool("keep-listen", false, "keep the address an installed pierd listens on (a tailnet address only while the box still has it)")
	noIntegrations := fs.Bool("no-integrations", false, "don't install hooks for the agent CLIs on this box")
	name := fs.String("name", "", "the name the apps show for this box (default: the hostname); kept for later installs")
	ports := fs.String("ports", "", "FIRST-LAST: the ports worktrees get (default 41000-48999); kept for later installs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return errors.New("usage: pierd install [--listen ADDR] [--keep-listen] [--name NAME] [--ports FIRST-LAST] [--no-integrations]")
	}
	return installService(b, installOptions{listen: *listen, keep: *keep, name: *name, ports: *ports,
		integrations: !*noIntegrations, next: "Next: pierd pair"})
}

// installService installs and starts the service and waits for it to answer.
func installService(b boxHome, o installOptions) error {
	if o.ports != "" {
		if _, _, err := box.ParsePortRange(o.ports); err != nil {
			return err
		}
	}
	for file, v := range map[string]string{"name": o.name, "ports": o.ports} {
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
	addr, err := chooseListen(o.listen, o.keep, current, interfaceIPs())
	if err != nil {
		return err
	}
	spec := daemonService(b, addr)
	if spec.Program, err = stableExecutable(spec.Program); err != nil {
		return err
	}
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
	if o.integrations {
		if home, err := os.UserHomeDir(); err == nil {
			fmt.Println("Agent hooks:")
			if err := integrations.InstallPresent(home, spec.Program, indented{os.Stdout}); err != nil {
				fmt.Printf("  not installed: %v\n", err)
			}
		}
	}
	if runtime.GOOS == "linux" && !lingering() {
		if enableLinger() {
			fmt.Println("Turned on user lingering: pierd keeps running after you log out.")
		} else {
			fmt.Println("Warning: user lingering is off, so pierd stops when you log out, and this system does not let")
			fmt.Println("your user turn it on. Ask an admin of this machine to run once: sudo loginctl enable-linger " + currentUser())
		}
	}
	if o.next != "" {
		fmt.Println(o.next)
	}
	return nil
}

// stableExecutable is the pierd the service and the hooks run: exe, unless it
// lives where it will not stay. A Homebrew keg (Cellar/pierd/1.2.3) goes away
// after an upgrade, so the formula's opt link, which follows upgrades, is used
// instead; npx's cache may be cleared, so its copy is first copied to
// ~/.local/bin.
func stableExecutable(exe string) (string, error) {
	sep := string(filepath.Separator)
	if opt, ok := homebrewOpt(exe); ok {
		return opt, nil
	}
	if !strings.Contains(exe, sep+"_npx"+sep) {
		return exe, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dst := filepath.Join(home, ".local", "bin", "pierd")
	data, err := os.ReadFile(exe)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	tmp := dst + ".new"
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, dst); err != nil {
		return "", err
	}
	fmt.Println("Copied pierd to " + dst + " (npx's copy may be cleared).")
	return dst, nil
}

// homebrewOpt maps a binary in a Homebrew keg, PREFIX/Cellar/FORMULA/VERSION/
// bin/pierd, to PREFIX/opt/FORMULA/bin/pierd, when that link exists.
func homebrewOpt(exe string) (string, bool) {
	sep := string(filepath.Separator)
	i := strings.LastIndex(exe, sep+"Cellar"+sep)
	if i < 0 {
		return "", false
	}
	rest := strings.Split(exe[i+len(sep+"Cellar"+sep):], sep) // FORMULA, VERSION, bin, pierd
	if len(rest) < 3 || rest[0] == "" {
		return "", false
	}
	opt := filepath.Join(append([]string{exe[:i], "opt", rest[0]}, rest[2:]...)...)
	if _, err := os.Stat(opt); err != nil {
		return "", false
	}
	return opt, true
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
// --keep-listen, the address an installed unit already names, unless it is a
// tailnet address this box no longer has; otherwise every interface
// (defaultListen).
func chooseListen(flagListen string, keep bool, current string, ips []net.IP) (string, error) {
	if flagListen != "" {
		return flagListen, nil
	}
	if keep && current != "" && (!onTailnet(current) || hasAddress(current, ips)) {
		return current, nil
	}
	return defaultListen(ips)
}

// hasAddress says whether host:port names one of ips.
func hasAddress(hostport string, ips []net.IP) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		return false
	}
	want := net.ParseIP(host)
	for _, ip := range ips {
		if want != nil && ip.Equal(want) {
			return true
		}
	}
	return false
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

// enableLinger turns lingering on for this user without sudo, and says whether it is on now. systemd's own polkit
// rule lets users do it for themselves (org.freedesktop.login1.set-self-linger), but not everywhere: a system without
// polkit, which many containers are, leaves it to root.
func enableLinger() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	exec.CommandContext(ctx, "loginctl", "enable-linger", "--no-ask-password", currentUser()).Run()
	return lingering()
}

func currentUser() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return os.Getenv("USER")
}
