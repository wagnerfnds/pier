package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"runtime"

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
		checks = append(checks, doctor.Check{Area: area, Name: "listening", Status: doctor.Warn,
			Detail: listening + " answers on every interface, including the internet",
			Fix:    "pierd install  (listens on the tailnet address only)"})
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
		if lingering() {
			checks = append(checks, doctor.Check{Area: area, Name: "survives logout", Status: doctor.OK, Detail: "user lingering is on"})
		} else {
			checks = append(checks, doctor.Check{Area: area, Name: "survives logout", Status: doctor.Warn, Detail: "pierd stops when you log out", Fix: "sudo loginctl enable-linger " + currentUser()})
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
