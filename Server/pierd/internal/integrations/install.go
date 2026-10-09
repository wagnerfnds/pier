package integrations

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// Agents report their turns through hooks in their own settings: Claude
// Code's settings.json, Codex's hooks.json and its notify program. Each
// hook runs `pierd hook TOOL EVENT`, which hands the event to the running
// pierd (command.go).

// ClaudeHookEvents are the Claude Code hooks pierd installs.
var ClaudeHookEvents = []string{"SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"}

// CodexHookEvents are the Codex hooks pierd installs.
var CodexHookEvents = []string{"SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"}

// InstallClaudeHooks adds pierd's hooks to a Claude Code settings file,
// keeping every other setting and hook. It reports
// whether it changed anything; running it again is a no-op.
func InstallClaudeHooks(settingsPath, bin string) (bool, error) {
	f, rel := fileAt(settingsPath)
	return editJSON(f, rel, func(root map[string]any) bool {
		return installNested(object(root, "hooks"), "claude", ClaudeHookEvents, bin)
	})
}

// InstallCodexHooks adds pierd's hooks to Codex's hooks.json. Codex runs them only once they are trusted in Codex (/hooks);
// until then notify still reports finished turns.
func InstallCodexHooks(path, bin string) (bool, error) {
	f, rel := fileAt(path)
	return editJSON(f, rel, func(root map[string]any) bool {
		return installNested(object(root, "hooks"), "codex", CodexHookEvents, bin)
	})
}

// installNested puts tool's hook for each event in Claude's nested hook
// shape (which Codex shares).
func installNested(hooks map[string]any, tool string, events []string, bin string) bool {
	changed := false
	for _, event := range events {
		command := hookCommand(bin, tool, event)
		list, _ := hooks[event].([]any)
		if containsCommand(list, command) {
			continue
		}
		hooks[event] = append(list, map[string]any{
			"hooks": []any{map[string]any{"type": "command", "command": command}},
		})
		changed = true
	}
	return changed
}

// ErrNotifyTaken means Codex's config already sets notify to a program
// other than pierd's hook. Codex runs a single notify program,
// so pierd does not replace it.
var ErrNotifyTaken = errors.New("codex already has a notify program")

// notifyLine finds a notify setting anywhere in a config.toml.
var notifyLine = regexp.MustCompile(`(?m)^[ \t]*notify[ \t]*=.*$`)

// InstallCodexNotify makes Codex run pierd's hook when a turn finishes, by
// adding a notify setting to its config.toml or replacing pierd's own from
// another path.
func InstallCodexNotify(configPath, bin string) (bool, error) {
	f, rel := fileAt(configPath)
	before, err := f.read(rel)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	want := codexNotify(bin)
	var after string
	switch line := notifyLine.Find(before); {
	case line == nil:
		// Top-level keys come before the first table, so the line goes first.
		after = want + "\n" + string(before)
	case strings.TrimSpace(string(line)) == want:
		return false, nil
	case strings.Contains(string(line), `"hook", "codex"`):
		// pierd's, from another path.
		after = notifyLine.ReplaceAllLiteralString(string(before), want)
	default:
		return false, ErrNotifyTaken
	}
	if len(before) > 0 {
		if err := f.backup(rel, before); err != nil {
			return false, err
		}
	}
	return true, f.write(rel, []byte(after), 0o644)
}

func codexNotify(bin string) string {
	return fmt.Sprintf(`notify = [%q, "hook", "codex", "notify"]`, bin)
}

func hookCommand(bin, tool, event string) string {
	return fmt.Sprintf("%s hook %s %s", shellQuote(bin), tool, event)
}

func shellQuote(s string) string {
	if !strings.ContainsAny(s, " '\"$`\\") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func object(root map[string]any, key string) map[string]any {
	if m, ok := root[key].(map[string]any); ok {
		return m
	}
	m := map[string]any{}
	root[key] = m
	return m
}

// containsCommand looks for command in Claude's nested hook shape,
// {"hooks": [{"command": …}]}.
func containsCommand(list []any, command string) bool {
	for _, item := range list {
		m, _ := item.(map[string]any)
		inner, _ := m["hooks"].([]any)
		for _, h := range inner {
			if hm, _ := h.(map[string]any); hm["command"] == command {
				return true
			}
		}
	}
	return false
}

// editJSON applies change to a JSON object file, rel below f, and writes
// it back only when something changed, keeping the previous contents at
// rel+".pier-backup" and the file's mode. A file that is not a JSON object
// is left untouched. A missing file counts as {} only when change adds to
// it.
func editJSON(f files, rel string, change func(map[string]any) bool) (bool, error) {
	root := map[string]any{}
	before, err := f.read(rel)
	switch {
	case err == nil:
		if err := json.Unmarshal(before, &root); err != nil {
			return false, fmt.Errorf("%s is not valid JSON, so pierd left it alone: %w", f.path(rel), err)
		}
	case !os.IsNotExist(err):
		return false, err
	}
	if !change(root) {
		return false, nil
	}
	out, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return false, err
	}
	if len(before) > 0 {
		if err := f.backup(rel, before); err != nil {
			return false, err
		}
	}
	return true, f.write(rel, append(out, '\n'), 0o644)
}
