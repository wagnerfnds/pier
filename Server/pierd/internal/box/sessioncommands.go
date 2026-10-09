package box

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// A session's command lives in a file, Sessions.Commands/NAME.cmd, which
// the pane's login shell reads (`$SHELL -lc '. FILE'`), so the command can
// be as long as its prompt is: tmux refuses a command line or an option
// over about 16 KB, and Linux one argument over 128 KB. The shell is the
// same login shell as ever, so PATH, $PIER_* and the exit status are too.
// The file stays as long as the session, which reads its command back from
// it, and goes when the session is killed, or at the next sweep once the
// session is gone some other way.

// maxCommandFile is the longest command file pierd reads back.
const maxCommandFile = 8 << 20

func (s *Sessions) commandPath(name string) string {
	return filepath.Join(s.Commands, name+".cmd")
}

// writeCommand keeps command for session name, readable by its owner only
// (a prompt can say anything), and returns its path.
func (s *Sessions) writeCommand(name, command string) (string, error) {
	if s.Commands == "" {
		return "", errors.New("sessions have no folder for their commands")
	}
	if err := os.MkdirAll(s.Commands, 0o700); err != nil {
		return "", fmt.Errorf("keeping the session's command: %w", err)
	}
	path := s.commandPath(name)
	tmp, err := os.CreateTemp(s.Commands, "."+name+"-*")
	if err != nil {
		return "", fmt.Errorf("keeping the session's command: %w", err)
	}
	_, werr := io.WriteString(tmp, command+"\n")
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr, os.Chmod(tmp.Name(), 0o600)); err != nil {
		os.Remove(tmp.Name())
		return "", fmt.Errorf("keeping the session's command: %w", err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return "", fmt.Errorf("keeping the session's command: %w", err)
	}
	commandCache.Delete(path)
	return path, nil
}

func (s *Sessions) removeCommand(name string) {
	if s.Commands == "" {
		return
	}
	path := s.commandPath(name)
	os.Remove(path)
	commandCache.Delete(path)
}

// sourceCommand is what the login shell runs to run the command in file.
func sourceCommand(shell, file string) string {
	if filepath.Base(shell) == "fish" {
		return "source " + shellQuote(file)
	}
	return ". " + shellQuote(file)
}

type cachedCommand struct {
	size    int64
	modTime time.Time
	command string
}

// commandCache keeps commands read back, by path, while their file is
// unchanged: every session list reads them.
var commandCache sync.Map

// readCommand is the command kept at path. Only a pierd command file is
// read: an absolute path to a NAME.cmd regular file.
func readCommand(path string) (string, error) {
	if !filepath.IsAbs(path) || filepath.Ext(path) != ".cmd" {
		return "", fmt.Errorf("not a command file: %s", path)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() > maxCommandFile {
		return "", fmt.Errorf("not a command file: %s", path)
	}
	if c, ok := commandCache.Load(path); ok {
		c := c.(cachedCommand)
		if c.size == info.Size() && c.modTime.Equal(info.ModTime()) {
			return c.command, nil
		}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	command := strings.TrimSuffix(string(b), "\n")
	commandCache.Store(path, cachedCommand{size: info.Size(), modTime: info.ModTime(), command: command})
	return command, nil
}

// maybeSweep sweeps the command files at most once every minute.
func (s *Sessions) maybeSweep(ctx context.Context) {
	s.sweepMu.Lock()
	due := time.Since(s.lastSweep) >= time.Minute
	if due {
		s.lastSweep = time.Now()
	}
	s.sweepMu.Unlock()
	if due {
		go s.sweepCommands(context.WithoutCancel(ctx), time.Minute)
	}
}

// sweepCommands removes the command files of sessions that are gone, when
// older than minAge (a session being made has its file before tmux lists
// it).
func (s *Sessions) sweepCommands(ctx context.Context, minAge time.Duration) {
	if s.Commands == "" {
		return
	}
	entries, err := os.ReadDir(s.Commands)
	if err != nil || len(entries) == 0 {
		return
	}
	all, err := s.list(ctx)
	if err != nil {
		return
	}
	live := map[string]bool{}
	for _, sess := range all {
		live[sess.Name] = true
	}
	for _, e := range entries {
		name, ok := strings.CutSuffix(e.Name(), ".cmd")
		if !ok && !strings.HasPrefix(e.Name(), ".") {
			continue
		}
		if ok && live[name] {
			continue
		}
		info, err := e.Info()
		if err != nil || time.Since(info.ModTime()) < minAge {
			continue
		}
		path := filepath.Join(s.Commands, e.Name())
		os.Remove(path)
		commandCache.Delete(path)
	}
}
