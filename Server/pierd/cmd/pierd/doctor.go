package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"runtime"
	"sync"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/doctor"
	"pier/pierd/internal/service"
)

// daemonChecks describes the running daemon; listening is the bound address.
func daemonChecks(b boxHome, listening string) []doctor.Check {
	const area = "pierd"
	checks := []doctor.Check{}
	host, _, _ := net.SplitHostPort(listening)
	switch ip := net.ParseIP(host); {
	case ip != nil && ip.IsUnspecified():
		// The default: only paired devices (mutual TLS) and single-use pairing codes get in.
		checks = append(checks, doctor.Check{Area: area, Name: "listening", Status: doctor.OK,
			Detail: listening + " (every interface; pairing links say " + pairAddress(b) + ")"})
	case ip != nil && ip.IsLoopback():
		checks = append(checks, doctor.Check{Area: area, Name: "listening", Status: doctor.OK, Detail: listening + " (this box only; reach it through a tunnel)"})
	default:
		checks = append(checks, doctor.Check{Area: area, Name: "listening", Status: doctor.OK, Detail: listening})
	}
	if service.InstalledByName(serviceName()) {
		checks = append(checks, doctor.Check{Area: area, Name: "starts at boot", Status: doctor.OK, Detail: "installed as a user service"})
	} else {
		checks = append(checks, doctor.Check{Area: area, Name: "starts at boot", Status: doctor.Warn, Detail: "pierd runs, but not as a service", Fix: "pierd install"})
	}
	if runtime.GOOS == "linux" {
		switch {
		case lingering():
			checks = append(checks, doctor.Check{Area: area, Name: "survives logout", Status: doctor.OK, Detail: "user lingering is on"})
		case tryLinger():
			checks = append(checks, doctor.Check{Area: area, Name: "survives logout", Status: doctor.OK, Detail: "user lingering is on (pierd turned it on)"})
		default:
			checks = append(checks, doctor.Check{Area: area, Name: "survives logout", Status: doctor.Warn,
				Detail: "pierd stops when you log out, and this system does not let your user turn lingering on (loginctl enable-linger was refused): an admin of the machine has to",
				Fix:    "sudo loginctl enable-linger " + currentUser()})
		}
	}
	peers, err := b.clients().List()
	switch {
	case err != nil:
		checks = append(checks, doctor.Check{Area: area, Name: "paired clients", Status: doctor.Fail, Detail: err.Error()})
	case len(peers) == 0:
		checks = append(checks, doctor.Check{Area: area, Name: "paired clients", Status: doctor.Warn, Detail: "none yet", Fix: "pierd pair"})
	default:
		checks = append(checks, doctor.Check{Area: area, Name: "paired clients", Status: doctor.OK, Detail: fmt.Sprintf("%d", len(peers))})
	}
	return checks
}

// lingerTried is when the report last tried to turn lingering on.
var lingerTried struct {
	sync.Mutex
	at time.Time
}

// tryLinger turns lingering on when the system lets this user do it, at most once an hour: unlike the rest of the
// report, this check fixes what it can, since it is the one fix pierd can make for itself, without sudo.
func tryLinger() bool {
	lingerTried.Lock()
	defer lingerTried.Unlock()
	if time.Since(lingerTried.at) < time.Hour {
		return false
	}
	lingerTried.at = time.Now()
	return enableLinger()
}

// runDoctor asks the running daemon for its report; without one, it reports
// that first and still checks the tools on this box.
func runDoctor(b boxHome, args []string) error {
	asJSON := len(args) > 0 && args[0] == "--json"
	var checks []doctor.Check
	if _, err := os.Stat(b.socket()); err == nil {
		checks, err = box.NewClient(box.NewLocal(b.socket())).Doctor(context.Background())
		if err != nil {
			return err
		}
	} else {
		checks = append(checks, doctor.Check{Area: "pierd", Name: "running", Status: doctor.Fail, Detail: "pierd serve is not running", Fix: "pierd install"})
		checks = append(checks, doctor.ToolCheck("Worktrees and sessions", "git", "git", "Install git with your package manager", true), box.TmuxCheck())
	}
	if asJSON {
		return json.NewEncoder(os.Stdout).Encode(checks)
	}
	if problems := doctor.Print(os.Stdout, checks); problems > 0 {
		fmt.Printf("\n%d thing(s) to fix.\n", problems)
	} else {
		fmt.Println("\nAll good.")
	}
	return nil
}
