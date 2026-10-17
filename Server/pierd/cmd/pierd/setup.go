package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/doctor"
	"pier/pierd/internal/statefile"
)

// setup is the one command a person runs on a new box (the install script and
// the npm and Homebrew packages end with it): Claude Code, Codex and the GitHub
// CLI where they are missing, pierd as a user service on every interface, the
// agents' hooks, the git repositories in the usual folders as projects, and a
// pairing link with its QR code. On a Mac at its own screen
// the link goes straight to the Pier app, which pairs with this Mac; from
// there "Take it to iPhone" brings the phone in. Running it again keeps
// what was chosen before and issues a new link.
func setup(b boxHome, args []string) error {
	fs := flag.NewFlagSet("setup", flag.ContinueOnError)
	listen := fs.String("listen", "", "address to listen on (default: what an earlier setup chose, else every interface, port "+defaultPort+")")
	address := fs.String("address", "", "address apps should dial (default: pierd's best guess)")
	name := fs.String("name", "", "the name the apps show for this box (default: the hostname)")
	ports := fs.String("ports", "", "FIRST-LAST: the ports worktrees get (default 41000-48999)")
	noIntegrations := fs.Bool("no-integrations", false, "don't install hooks for the agent CLIs on this box")
	noTools := fs.Bool("no-tools", false, "don't install Claude Code, Codex and the GitHub CLI where they are missing (also PIERD_NO_TOOLS=1)")
	noProjects := fs.Bool("no-projects", false, "don't add the git repositories found in the usual folders")
	noOpen := fs.Bool("no-open", false, "on a Mac, don't hand the pairing link to the Pier app")
	noService := fs.Bool("no-service", false, "pierd already runs (a container, a supervisor of your own): only add projects and pair")
	relayAddr := fs.String("relay", "", "HOST[:PORT]: reach this box through a relay of your own instead of the Pier tunnel")
	relayToken := fs.String("relay-token", "", "the relay's token")
	noTunnel := fs.Bool("no-tunnel", false, "no tunnel: apps reach this box at its own address only")
	var dirs folderList
	fs.Var(&dirs, "repos", "a folder whose git repositories become projects; repeatable (default: ~/code, ~/Projects, ~/src, …)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return errors.New("usage: pierd setup [--repos DIR]… [--address HOST[:PORT]] [--listen ADDR] [--relay HOST[:PORT] [--relay-token T] | --no-tunnel] [--name NAME] [--ports FIRST-LAST] [--no-projects] [--no-integrations] [--no-tools] [--no-open] [--no-service]")
	}
	fmt.Println("Pier · setting up this box")
	fmt.Println()
	// Before the service starts: pierd serve reads it at start.
	switch {
	case *noTunnel:
		if err := statefile.Write(filepath.Join(b.dir, "relay"), []byte("off\n")); err != nil {
			return err
		}
	case *relayAddr != "":
		if err := saveRelay(b, *relayAddr, *relayToken); err != nil {
			return err
		}
	}
	// Before the service and its hooks: hooks go into the agents found then.
	if !skipTools(*noTools) {
		fmt.Println("Tools (--no-tools leaves them alone):")
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		installTools(ctx, allTools(), false, &lineIndent{w: os.Stdout, prefix: "  "})
		stop()
		fmt.Println()
	}
	if *noService {
		if err := waitServing(b, time.Time{}, 5*time.Second); err != nil {
			return fmt.Errorf("--no-service: pierd serve is not answering here: %w", err)
		}
	} else if err := installService(b, installOptions{listen: *listen, keep: *listen == "", name: *name, ports: *ports,
		integrations: !*noIntegrations}); err != nil {
		return err
	}
	if !*noProjects {
		home, _ := os.UserHomeDir()
		folders := []string(dirs)
		if len(folders) == 0 {
			folders = defaultProjectFolders(home)
		}
		if err := addProjects(b, findRepos(folders, maxFoundRepos), os.Stdout); err != nil {
			fmt.Printf("Projects: %v (add them later with: pierd location add NAME PATH)\n", err)
		}
	}
	fmt.Println()
	// What the first task needs and this machine lacks, said now rather than
	// when a session fails to start.
	if missing := missingTools(); len(missing) > 0 {
		fmt.Println("Before the first task:")
		doctor.Print(os.Stdout, missing)
		fmt.Println()
	}
	if relayConfig(b).Connect != "" {
		// The tunnel connects in a moment; say how it went.
		deadline := time.Now().Add(8 * time.Second)
		for {
			c, ok := relayDoctorCheck(b)
			if ok && (c.Status == doctor.OK || time.Now().After(deadline)) {
				printRelayCheck(b, c)
				fmt.Println()
				break
			}
			if time.Now().After(deadline) {
				break
			}
			time.Sleep(300 * time.Millisecond)
		}
	}
	link, target, err := issuePairing(b, *address, defaultTTL)
	if err != nil {
		return err
	}
	if runtime.GOOS == "darwin" && !*noOpen && !remoteSession() && exec.Command("open", link).Run() == nil {
		fmt.Println("Pier is pairing with this Mac. Nothing to do there: the app opens and pairs by itself.")
		if relayConfig(b).Connect == "" {
			fmt.Println("Away from home, the phone reaches this Mac through a tunnel: pierd relay")
		}
		fmt.Println("For your iPhone or iPad: \"Take it to iPhone\" in Pier on this Mac (its last setup step, or")
		fmt.Println("Settings), then scan the code with the phone.")
		fmt.Println("(If the app was not installed yet, paste this link in it once it is.)")
		fmt.Printf("\n  %s\n\n", link)
		return nil
	}
	printPairing(link, target, defaultTTL)
	fmt.Println("A new link any time: pierd pair")
	if relayConfig(b).Connect == "" && !publicAddress(target) {
		fmt.Println("Away from this network, reach the box through a tunnel: pierd relay")
	}
	return nil
}

// publicAddress says whether apps anywhere can dial host:port (a public IP;
// a name may well be, so it counts too, unless it is a .local one).
func publicAddress(hostport string) bool {
	host, _, err := net.SplitHostPort(hostport)
	if err != nil {
		host = hostport
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return !strings.HasSuffix(strings.ToLower(host), ".local")
	}
	return !(ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || carrierGradeNAT.Contains(netipAddr(ip)))
}

// missingTools are the checks of what every session needs (git, tmux) that
// fail on this machine.
func missingTools() []doctor.Check {
	var out []doctor.Check
	for _, c := range []doctor.Check{
		doctor.ToolCheck("Worktrees and sessions", "git", "projects and worktrees",
			"Install git with your package manager (on a Mac: xcode-select --install)", true),
		box.TmuxCheck(),
	} {
		if c.Status != doctor.OK {
			out = append(out, c)
		}
	}
	return out
}

// remoteSession says whether this runs over SSH, where `open` would act on a
// screen nobody here is looking at.
func remoteSession() bool {
	return os.Getenv("SSH_CONNECTION") != "" || os.Getenv("SSH_TTY") != ""
}

// folderList is a repeatable flag.
type folderList []string

func (f *folderList) String() string { return strings.Join(*f, ",") }
func (f *folderList) Set(v string) error {
	*f = append(*f, v)
	return nil
}

// projectFolders are where people keep their repositories, under the home
// folder; setup looks in the ones that exist.
var projectFolders = []string{"code", "Code", "Projects", "projects", "src", "dev", "Developer", "workspace", "repos", "git", "github", "GitHub"}

const maxFoundRepos = 40

func defaultProjectFolders(home string) []string {
	out := make([]string, 0, len(projectFolders))
	for _, f := range projectFolders {
		out = append(out, filepath.Join(home, f))
	}
	return out
}

type foundRepo struct{ name, path string }

// findRepos lists the git repositories in folders: each folder itself when it
// is one, else the ones right inside it; each repository once (a folder named
// twice, or twice by a case-insensitive disk), by name, at most max.
func findRepos(folders []string, max int) []foundRepo {
	var out []foundRepo
	var seen []os.FileInfo
	add := func(path string) {
		fi, err := os.Stat(path)
		if err != nil {
			return
		}
		for _, s := range seen {
			if os.SameFile(s, fi) {
				return
			}
		}
		seen = append(seen, fi)
		out = append(out, foundRepo{name: filepath.Base(path), path: path})
	}
	isRepo := func(dir string) bool {
		_, err := os.Stat(filepath.Join(dir, ".git"))
		return err == nil
	}
	for _, f := range folders {
		if fi, err := os.Stat(f); err != nil || !fi.IsDir() {
			continue
		}
		if isRepo(f) {
			add(f)
			continue
		}
		entries, err := os.ReadDir(f)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() && !strings.HasPrefix(e.Name(), ".") && isRepo(filepath.Join(f, e.Name())) {
				add(filepath.Join(f, e.Name()))
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return strings.ToLower(out[i].name) < strings.ToLower(out[j].name) })
	if len(out) > max {
		out = out[:max]
	}
	return out
}

// uniqueName is name, or name-2, name-3… when taken.
func uniqueName(name string, taken map[string]bool) string {
	n := name
	for i := 2; taken[n]; i++ {
		n = fmt.Sprintf("%s-%d", name, i)
	}
	return n
}

// addProjects registers the repositories the running pierd does not know yet.
func addProjects(b boxHome, repos []foundRepo, out *os.File) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := box.NewClient(box.NewLocal(b.socket()))
	have, err := c.Locations(ctx)
	if err != nil {
		return err
	}
	taken := map[string]bool{}
	paths := map[string]bool{}
	for _, l := range have {
		taken[l.Name] = true
		if p, err := filepath.EvalSymlinks(expandHome(l.Path)); err == nil {
			paths[p] = true
		}
	}
	var added []string
	for _, r := range repos {
		if p, err := filepath.EvalSymlinks(r.path); err == nil && paths[p] {
			continue
		}
		name := uniqueName(r.name, taken)
		if _, err := c.AddLocation(ctx, name, r.path); err != nil {
			fmt.Fprintf(out, "Projects: %s not added: %v\n", r.path, err)
			continue
		}
		taken[name] = true
		added = append(added, name)
	}
	switch {
	case len(added) > 0:
		fmt.Fprintf(out, "Projects: %s\n", strings.Join(added, ", "))
	case len(have) > 0:
		fmt.Fprintf(out, "Projects: %d already here\n", len(have))
	default:
		fmt.Fprintln(out, "Projects: none found yet; add one with: pierd location add NAME PATH")
	}
	return nil
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}
