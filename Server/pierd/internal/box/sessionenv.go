package box

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// A session's variables that may hold secrets (the box's variables, a
// project's env, MCP tokens) never go on tmux's command line: every user of
// a shared box can read a process's arguments in /proc while it runs. pierd
// writes them to a file only its user reads, and the pane's program starts
// behind `pierd env-exec FILE --`, which reads them, deletes the file and
// replaces itself with the program. tmux keeps the others (pierd's own
// PIER_*, the account folders), which pierd reads back from the session.

// splitSessionEnv sorts a session's KEY=VALUE pairs into those tmux may
// keep and those that go through the file.
func splitSessionEnv(env []string) (public, secret []string) {
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if publicSessionVar(k) {
			public = append(public, kv)
		} else {
			secret = append(secret, kv)
		}
	}
	return public, secret
}

func publicSessionVar(k string) bool {
	switch k {
	case "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PATH", "PORT", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS":
		return true
	}
	return strings.HasPrefix(k, "PIER_") && !strings.HasPrefix(k, "PIER_MCP_")
}

// writeEnvFile keeps a session's secret variables for env-exec, readable by
// pierd's user alone; the sweep takes one a session never read.
func (s *Sessions) writeEnvFile(name string, env []string) (string, error) {
	if err := os.MkdirAll(s.Commands, 0o700); err != nil {
		return "", err
	}
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	data, err := json.Marshal(m)
	if err != nil {
		return "", err
	}
	f, err := os.CreateTemp(s.Commands, "."+name+".env-*")
	if err != nil {
		return "", fmt.Errorf("keeping the session's variables: %w", err)
	}
	_, werr := f.Write(data)
	cerr := f.Close()
	if err := errors.Join(werr, cerr, os.Chmod(f.Name(), 0o600)); err != nil {
		os.Remove(f.Name())
		return "", fmt.Errorf("keeping the session's variables: %w", err)
	}
	return f.Name(), nil
}

// EnvExec is `pierd env-exec FILE -- PROGRAM [ARGS…]`: it sets the
// variables FILE holds, deletes it, and replaces itself with PROGRAM.
func EnvExec(args []string) error {
	if len(args) < 3 || args[1] != "--" {
		return errors.New("usage: pierd env-exec FILE -- PROGRAM [ARGS...]")
	}
	file, argv := args[0], args[2:]
	data, err := os.ReadFile(file)
	os.Remove(file)
	if err != nil {
		return err
	}
	var env map[string]string
	if err := json.Unmarshal(data, &env); err != nil {
		return fmt.Errorf("%s: %w", file, err)
	}
	for k, v := range env {
		os.Setenv(k, v)
	}
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return err
	}
	return syscall.Exec(path, argv, os.Environ())
}
