// Command pierd runs on a box: it holds the box identity, issues pairing
// links, and serves the paired Pier apps: locations, worktrees, agent
// sessions in tmux, their transcripts, events and push notifications.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/boxcmd"
	"pier/pierd/internal/doctor"
	"pier/pierd/internal/events"
	"pier/pierd/internal/hooks"
	"pier/pierd/internal/identity"
	"pier/pierd/internal/integrations"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/push"
	"pier/pierd/internal/statefile"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/version"
	"pier/pierd/internal/wire"
)

const (
	defaultPort = "7444"
	defaultTTL  = 10 * time.Minute
)

const usage = `pierd — the Pier box server

  pierd serve [--listen ADDR]             Serve paired apps (default: the tailnet address only)
  pierd install [--listen ADDR] [--keep-listen] [--name NAME] [--ports FIRST-LAST] [--no-integrations]
                                          Run serve as a user service (systemd; launchd on a Mac)
                                          and install the agent CLIs' hooks. --name and --ports
                                          (kept for later installs) give each user of a shared box
                                          a box name and a range of worktree ports of their own
  pierd uninstall                         Remove that service
  pierd pair [--address HOST[:PORT]] [--ttl 10m] [--json]
                                          Print a single-use pairing link
  pierd clients                           List paired clients
  pierd revoke <name|fingerprint>         Stop trusting a client
  pierd id                                Print this box's fingerprint
  pierd doctor [--json]                   Check this box's setup and how to fix it
  pierd version                           Print this build's version
  pierd client pair LINK [--name N]       Pair this machine with a pierd as a client (tests,
                                          scripts/smoke.sh); kept in $PIER_CLIENT_HOME
  pierd client METHOD PATH [JSON]         Call the paired pierd as that client

PIER_HOME overrides the state directory (~/.config/pier); the box's state is
in $PIER_HOME/box, push.json and AuthKey.p8 in $PIER_HOME. PIER_USER_DIR
overrides ~/.pier (hooks.json, env.json). PIER_TMUX_SOCKET names the tmux
server (default "pier").
`

// helpText is what pierd help prints.
func helpText() string {
	return usage + "\n" + boxcmd.Usage() + "\n" + integrations.Usage
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "pierd:", err)
		os.Exit(1)
	}
}

// boxHome is pierd's state: dir is $PIER_HOME/box.
type boxHome struct {
	dir string
}

func (b boxHome) home() string   { return filepath.Dir(b.dir) }
func (b boxHome) socket() string { return filepath.Join(b.dir, "pierd.sock") }

// setting is one of the box's own settings files ("name", "ports"), written
// by pierd install; "" when it is not there.
func (b boxHome) setting(name string) string {
	data, err := os.ReadFile(filepath.Join(b.dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// name is what this box calls itself to the apps: the "name" setting, or the
// hostname. Each user of a shared box names their own pierd.
func (b boxHome) name() string {
	n := b.setting("name")
	if n == "" {
		n, _ = os.Hostname()
	}
	return trust.NameFromHostname(n, "box")
}

// spool holds agent hooks that ran while pierd was down.
func (b boxHome) spool() string { return filepath.Join(b.dir, "spool") }

func (b boxHome) identity() (*identity.Identity, error) {
	return identity.LoadOrCreate(filepath.Join(b.dir, "identity.pem"))
}
func (b boxHome) clients() *trust.Store { return trust.NewStore(filepath.Join(b.dir, "clients.json")) }
func (b boxHome) pending() *pairing.Pending {
	return pairing.NewPending(filepath.Join(b.dir, "pairing.json"))
}

func run(args []string) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Print(helpText())
		return nil
	}
	if args[0] == "version" || args[0] == "--version" {
		fmt.Println(version.Line("pierd"))
		return nil
	}
	home, err := statefile.Home()
	if err != nil {
		return err
	}
	b := boxHome{dir: filepath.Join(home, "box")}
	switch args[0] {
	case "serve":
		return serve(b, args[1:])
	case "pair":
		return pair(b, args[1:])
	case "install":
		return install(b, args[1:])
	case "uninstall":
		return uninstall(b)
	case "clients":
		return listClients(b)
	case "revoke":
		return revoke(b, args[1:])
	case "id":
		id, err := b.identity()
		if err != nil {
			return err
		}
		fmt.Println(id.Fingerprint())
		return nil
	case "doctor":
		return runDoctor(b, args[1:])
	case "client":
		return clientCmd(args[1:], os.Stdout)
	case "hook":
		integrations.Hook(args[1:], os.Stdin, os.Stdout, os.Stderr, func(e events.Event) error { return emitHook(b, e) })
		return nil
	case "integrations":
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		return integrations.Install(args[1:], exe, os.Stdout)
	}
	if _, ok := boxcmd.Commands[args[0]]; ok {
		return runLocal(b, args)
	}
	return fmt.Errorf("unknown command %q; run pierd help", args[0])
}

// emitHook hands an agent's hook to the running pierd. While pierd is down
// (an upgrade, a restart) the hook is kept in the spool and published when
// it is back.
func emitHook(b boxHome, e events.Event) error {
	if _, err := os.Stat(b.socket()); err != nil {
		return integrations.Spool(b.spool(), e)
	}
	c := box.NewClient(box.NewLocal(b.socket()))
	c.Origin = e.Origin
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := c.Emit(ctx, e.Type, e.Data)
	if err != nil && integrations.Unreachable(err) {
		return integrations.Spool(b.spool(), e)
	}
	return err
}

func revoke(b boxHome, args []string) error {
	if len(args) != 1 {
		return errors.New("usage: pierd revoke <name|fingerprint>")
	}
	p, err := b.clients().Remove(args[0])
	if err != nil {
		return err
	}
	// A running pierd closes the streams this client still has open: at
	// once when told, otherwise within a second or two.
	if _, err := os.Stat(b.socket()); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		box.NewClient(box.NewLocal(b.socket())).Call(ctx, http.MethodPost, "/v1/clients/changed", nil, nil)
		cancel()
	}
	fmt.Printf("Revoked %s (%s); its open connections close within a few seconds.\n", p.Name, p.Fingerprint.Short())
	return nil
}

// utf8Locale gives pierd, and so its tmux server and every session, a UTF-8
// locale when it was started with none, as systemd can: agents' screens and
// shells need it. A locale someone set is left alone.
func utf8Locale() {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if os.Getenv(k) != "" {
			return
		}
	}
	if runtime.GOOS == "darwin" {
		os.Setenv("LANG", "en_US.UTF-8")
	} else {
		os.Setenv("LANG", "C.UTF-8")
	}
}

func serve(b boxHome, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := fs.String("listen", "", "address to listen on (default: this box's tailnet address only)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	utf8Locale()
	if *listen == "" {
		addr, err := defaultListen(interfaceIPs())
		if err != nil {
			return err
		}
		*listen = addr
	}
	id, err := b.identity()
	if err != nil {
		return err
	}
	hostname := b.name()
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	defer ln.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// pair reads this to advertise the address that actually answers.
	if err := statefile.Write(filepath.Join(b.dir, "listen"), []byte(ln.Addr().String())); err != nil {
		return err
	}
	logger := log.New(os.Stderr, "", log.LstdFlags)
	clients := b.clients()
	s := &wire.Server{Identity: id, Clients: clients, Pending: b.pending(), Name: hostname, Log: logger}
	sessions, err := box.NewSessions(b.dir)
	if err != nil {
		return err
	}
	// Agents' hooks find this pierd through PIER_HOME.
	sessions.Env = []string{"PIER_HOME=" + b.home()}
	if sock := os.Getenv("PIER_TMUX_SOCKET"); sock != "" {
		sessions.Env = append(sessions.Env, "PIER_TMUX_SOCKET="+sock)
	}
	// Each new session runs in a systemd scope of its own where the box has
	// a user manager, so ending it stops all it started.
	sessions.Scopes = box.NewSystemdScopes()
	journal, err := events.OpenJournal(filepath.Join(b.dir, "journal"))
	if err != nil {
		return fmt.Errorf("event journal: %w", err)
	}
	defer journal.Close()
	bus := &events.Bus{Journal: journal}
	// A new client, by the name it gave and its key.
	s.OnPaired = func(p trust.Peer) {
		bus.Publish(events.Event{Type: "client.paired", Box: hostname, Origin: box.DefaultOrigin, Data: map[string]any{"name": p.Name, "fingerprint": p.Fingerprint.String()}})
	}
	locations := box.NewLocations(filepath.Join(b.dir, "locations.json"))
	if r := b.setting("ports"); r != "" {
		first, last, err := box.ParsePortRange(r)
		if err != nil {
			return fmt.Errorf("%s: %w", filepath.Join(b.dir, "ports"), err)
		}
		locations.Ports.First, locations.Ports.Last = first, last
	}
	watcher := &box.Watcher{Locations: locations, Events: bus, Box: hostname}
	go watcher.Run(ctx)
	turns := &box.Turns{
		Path:        filepath.Join(b.dir, "turns.json"),
		InboxPath:   filepath.Join(b.dir, "inbox.json"),
		ArchivePath: filepath.Join(b.dir, "turns-archive.jsonl"),
	}
	turns.Attach(bus)
	userDir, err := statefile.UserDir()
	if err != nil {
		return err
	}
	hookRunner := &hooks.Runner{Path: filepath.Join(userDir, "hooks.json"), Log: logger}
	bx := &box.Box{
		Name:         hostname,
		Locations:    locations,
		Sessions:     sessions,
		Events:       bus,
		Watcher:      watcher,
		DaemonChecks: func() []doctor.Check { return daemonChecks(b, ln.Addr().String()) },
		LogDir:       filepath.Join(b.dir, "logs"),
		Units:        &box.Units{Dir: filepath.Join(b.dir, "units")},
		Turns:        turns,
		Hooks:        hookRunner,
		EnvFile:      filepath.Join(userDir, "env.json"),
		Socket:       b.socket(),
		Invites:      &box.Invites{Address: func() string { return pairAddress(b) }, TTL: defaultTTL},
	}
	bx.Mount(s)
	if err := startPush(ctx, b, s, bx, bus, logger); err != nil {
		// Push is an extra: pierd serves without it, and says why.
		logger.Printf("push notifications are off: %v", err)
	}
	// Hooks that ran while pierd was down, in order, before anything new.
	if n := integrations.DrainSpool(b.spool(), func(e events.Event) { bus.Publish(e) }); n > 0 {
		logger.Printf("published %d agent hooks spooled while pierd was down", n)
	}
	go turns.Run(ctx, bx)
	go bx.RunRepoHooks(ctx, logger)

	os.Remove(b.socket())
	// The socket is the box user's alone from the moment it exists: made
	// under a private umask, not opened up and then narrowed.
	umask := syscall.Umask(0o077)
	local, err := net.Listen("unix", b.socket())
	syscall.Umask(umask)
	if err != nil {
		return err
	}
	defer os.Remove(b.socket())
	if err := os.Chmod(b.socket(), 0o600); err != nil {
		local.Close()
		return err
	}
	// Hooks that spooled while the socket was being made, and any that
	// spool later (a hook that could not connect in time).
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			integrations.DrainSpool(b.spool(), func(e events.Event) { bus.Publish(e) })
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	}()
	go s.ServeLocal(ctx, local)
	go hookRunner.Run(ctx, bus)

	logger.Printf("pierd %s serving %s as %q (%s); local API %s", version.Version, ln.Addr(), hostname, id.Fingerprint().Short(), b.socket())
	return s.Serve(ctx, ln)
}

// startPush turns push notifications on when $PIER_HOME/push.json is there:
// the /v1/push routes on pierd's own listener, and on any extra addresses
// push.json lists.
func startPush(ctx context.Context, b boxHome, s *wire.Server, bx *box.Box, bus *events.Bus, logger *log.Logger) error {
	cfg, ok, err := push.LoadConfig(b.home())
	if err != nil || !ok {
		if err == nil {
			err = fmt.Errorf("no %s", filepath.Join(b.home(), push.ConfigFile))
		}
		return err
	}
	slogger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	svc, err := push.Open(b.home(), cfg, s.Clients, s.LocalHandler(), slogger)
	if err != nil {
		return err
	}
	svc.Mount(s)
	go svc.Run(ctx, bus)
	for _, addr := range pushListen(cfg.Listen) {
		// The same TLS, identity and paired clients as pierd's own
		// listener, with only the push routes on it: pairing stays on
		// pierd's own port, behind its one rate limit.
		legacy := &wire.Server{Identity: s.Identity, Clients: s.Clients, Pending: s.Pending, Name: s.Name, Log: logger, NoPairing: true}
		svc.Mount(legacy)
		go serveRetrying(ctx, legacy, addr, logger)
	}
	return nil
}

// pushListen is where else push is served: cfg's addresses ("" or "off":
// nowhere else).
func pushListen(cfg string) []string {
	switch strings.TrimSpace(cfg) {
	case "", "off":
		return nil
	}
	var out []string
	for _, a := range strings.Split(cfg, ",") {
		if a = strings.TrimSpace(a); a != "" {
			out = append(out, a)
		}
	}
	return out
}

// serveRetrying serves s on addr, retrying an address that cannot be bound
// yet (a tailnet address before tailscaled is up, a port another process
// still holds), until ctx ends.
func serveRetrying(ctx context.Context, s *wire.Server, addr string, logger *log.Logger) {
	for ctx.Err() == nil {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			logger.Printf("push: cannot listen on %s yet (%v); retrying", addr, err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}
		logger.Printf("push: also serving /v1/push on %s", ln.Addr())
		if err := s.Serve(ctx, ln); err != nil && ctx.Err() == nil {
			logger.Printf("push: %s stopped (%v); restarting", addr, err)
			time.Sleep(time.Second)
		}
	}
}

// runLocal runs a box command against this box's own pierd.
func runLocal(b boxHome, args []string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if _, err := os.Stat(b.socket()); err != nil {
		return errors.New("pierd serve is not running on this box; start it with pierd install")
	}
	return boxcmd.Run(ctx, box.NewClient(box.NewLocal(b.socket())), args, os.Stdout)
}

func pair(b boxHome, args []string) error {
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	address := fs.String("address", "", "address apps should dial (default: where serve listens, port "+defaultPort+")")
	ttl := fs.Duration("ttl", defaultTTL, "how long the link stays valid")
	asJSON := fs.Bool("json", false, "print the link and where apps will dial as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *ttl <= 0 || *ttl > time.Hour {
		return errors.New("--ttl must be between 0 and 1h")
	}
	target := *address
	if target == "" {
		target = pairAddress(b)
	}
	if _, _, err := net.SplitHostPort(target); err != nil {
		target = net.JoinHostPort(target, defaultPort)
	}
	id, err := b.identity()
	if err != nil {
		return err
	}
	code, err := b.pending().Issue(*ttl, time.Now())
	if err != nil {
		return err
	}
	link := pairing.Token{Address: target, Fingerprint: id.Fingerprint(), Code: code}.String()
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(map[string]string{
			"link":        link,
			"address":     target,
			"fingerprint": id.Fingerprint().String(),
			"expires":     time.Now().Add(*ttl).UTC().Format(time.RFC3339),
		})
	}
	fmt.Printf("Pairing link (single use, valid for %s):\n\n  %s\n\n", ttl, link)
	fmt.Println("Scan it as a QR code or paste it in the Pier app.")
	fmt.Println("Apps will dial " + target + "; pass --address if that is not reachable.")
	fmt.Println("pierd serve must be running on this box to accept the pairing.")
	return nil
}

// pairAddress is the address a pairing link tells apps to dial: where
// serve listens, or its best guess.
func pairAddress(b boxHome) string {
	hostname, _ := os.Hostname()
	ips := interfaceIPs()
	listening, _ := os.ReadFile(filepath.Join(b.dir, "listen"))
	if len(listening) == 0 {
		// serve may not have recorded its address yet, right after an
		// install; it will listen where defaultListen says.
		if addr, err := defaultListen(ips); err == nil {
			listening = []byte(addr)
		}
	}
	return advertise(string(listening), ips, hostname)
}

func listClients(b boxHome) error {
	peers, err := b.clients().List()
	if err != nil {
		return err
	}
	if len(peers) == 0 {
		fmt.Println("No paired clients. Run pierd pair to add one.")
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tFINGERPRINT\tPAIRED")
	for _, p := range peers {
		fmt.Fprintf(w, "%s\t%s\t%s\n", p.Name, p.Fingerprint.Short(), p.PairedAt.Local().Format("2006-01-02 15:04"))
	}
	return w.Flush()
}
