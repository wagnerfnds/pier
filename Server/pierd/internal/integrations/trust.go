package integrations

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Claude Code and Codex each ask before they work in a folder they have not
// seen ("Quick safety check", "Trust this folder?"), and stop there until
// someone answers in the terminal. pierd makes the folders its agents work
// in, a project's worktrees and chats, and the person registered the
// projects themselves, so pierd answers for them up front, the way each
// agent keeps the answer itself: Claude Code in projects[path].
// hasTrustDialogAccepted of its global config, Codex in a
// [projects."path"] table of its config.toml. Codex also asks once about
// new hooks ("Hooks need review"); pierd's own hooks are trusted the same
// way Codex trusts them, by the hash Codex computes for each.
//
// The writers only add: an answer already there (a folder the person
// marked untrusted in Codex, a hook they disabled) is never changed.

// ClaudeConfigFile is the file Claude Code keeps its global state in, the
// projects and their trust among it, for a settings folder configDir
// ($CLAUDE_CONFIG_DIR, "" for none): .claude.json in that folder, or in
// home without one. A legacy .config.json in the settings folder is read
// instead when it has anything in it, as Claude Code itself does.
func ClaudeConfigFile(configDir, home string) string {
	dir := configDir
	if dir == "" {
		dir = home
	}
	settings := configDir
	if settings == "" {
		settings = filepath.Join(home, ".claude")
	}
	legacy := filepath.Join(settings, ".config.json")
	if st, err := os.Stat(legacy); err == nil && st.Mode().IsRegular() && st.Size() > 0 {
		return legacy
	}
	return filepath.Join(dir, ".claude.json")
}

// Claude Code writes its config under a lock of its own (proper-lockfile):
// a folder next to it, path+".lock", made with mkdir and touched while
// held, which a writer takes over once it has not been touched for 10 s.
// pierd takes the same lock, waits at most claudeLockWait for it, and
// takes over only one that old.
var (
	claudeLockWait  = 2 * time.Second
	claudeLockStale = 10 * time.Second
)

// ErrConfigBusy is a Claude Code config whose lock stayed taken longer than
// pierd waits: Claude Code is writing it, and pierd leaves it alone.
var ErrConfigBusy = errors.New("Claude Code is writing its config")

// lockClaudeConfig takes Claude Code's lock on its config at path.
func lockClaudeConfig(path string) (unlock func(), err error) {
	lock := path + ".lock"
	deadline := time.Now().Add(claudeLockWait)
	for {
		err := os.Mkdir(lock, 0o755)
		if err == nil {
			return func() { os.Remove(lock) }, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return nil, err
		}
		if st, err := os.Stat(lock); err == nil && time.Since(st.ModTime()) > claudeLockStale {
			// Left by a writer that is gone: nothing touches it any more.
			os.Remove(lock)
			continue
		}
		if time.Now().After(deadline) {
			return nil, ErrConfigBusy
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// EditClaudeConfig applies change to Claude Code's global config at path,
// under Claude Code's own lock, and writes it back only when change says it
// changed something: atomically, keeping the file's mode (0600 for a new
// one, as Claude Code makes it) and every key change does not touch.
// Numbers keep their exact digits. A file that is not a JSON object is left
// alone.
func EditClaudeConfig(path string, change func(map[string]any) bool) (bool, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return false, err
	}
	// A link (dotfiles kept elsewhere) is written through, not replaced.
	if target, err := filepath.EvalSymlinks(path); err == nil {
		path = target
	}
	unlock, err := lockClaudeConfig(path)
	if err != nil {
		return false, err
	}
	defer unlock()
	root := map[string]any{}
	mode := fs.FileMode(0o600)
	before, err := os.ReadFile(path)
	switch {
	case err == nil:
		if len(bytes.TrimSpace(before)) > 0 {
			if root, err = decodeObject(before); err != nil {
				return false, fmt.Errorf("%s is not valid JSON, so pierd left it alone: %w", path, err)
			}
		}
		if st, err := os.Stat(path); err == nil {
			mode = st.Mode().Perm()
		}
	case !os.IsNotExist(err):
		return false, err
	}
	if !change(root) {
		return false, nil
	}
	out, err := encodeIndented(root)
	if err != nil {
		return false, err
	}
	return true, writeAtomic(path, out, mode)
}

// decodeObject reads a JSON object, numbers as their own digits.
func decodeObject(data []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var root map[string]any
	if err := dec.Decode(&root); err != nil {
		return nil, err
	}
	if root == nil {
		return nil, errors.New("not a JSON object")
	}
	return root, nil
}

// encodeIndented writes v as the agents write their JSON: two spaces, a
// newline at the end, "<" and "&" as themselves.
func encodeIndented(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// writeAtomic replaces path with data through a file beside it, so a reader
// never sees half of it, with the given mode.
func writeAtomic(path string, data []byte, mode fs.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".pier-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err = tmp.Chmod(mode); err == nil {
		_, err = tmp.Write(data)
	}
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// claudeProjectDefaults is what Claude Code puts in a project's entry it
// makes when its trust dialog is accepted, so code that reads one finds
// every field it expects.
func claudeProjectDefaults() map[string]any {
	return map[string]any{
		"allowedTools": []any{}, "mcpContextUris": []any{}, "mcpServers": map[string]any{},
		"enabledMcpjsonServers": []any{}, "disabledMcpjsonServers": []any{},
		"hasClaudeMdExternalIncludesApproved": false, "hasClaudeMdExternalIncludesWarningShown": false,
	}
}

// TrustClaudeProject records in Claude Code's global config at path that
// the folders dirs are trusted, so it does not ask before working in them.
// Claude Code keys a folder by its path as the agent sees it (the real
// one, which TrustPaths gives) and reads the entry of the folder it starts
// in and of each folder above it up to its repository's root. Only folders
// not trusted yet are written; every other key stays.
func TrustClaudeProject(path string, dirs ...string) (bool, error) {
	return EditClaudeConfig(path, func(root map[string]any) bool {
		projects, ok := root["projects"].(map[string]any)
		if !ok {
			if _, there := root["projects"]; there {
				return false // not an object: not a shape pierd knows
			}
			projects = map[string]any{}
		}
		changed := false
		for _, dir := range dirs {
			if dir == "" {
				continue
			}
			entry, ok := projects[dir].(map[string]any)
			if !ok {
				entry = claudeProjectDefaults()
			}
			if entry["hasTrustDialogAccepted"] == true {
				continue
			}
			entry["hasTrustDialogAccepted"] = true
			projects[dir] = entry
			changed = true
		}
		if changed {
			root["projects"] = projects
		}
		return changed
	})
}

// CarryClaudeMcpChoice gives each folder in dirs that has no answer yet to
// Claude Code's question about its repository's MCP servers (.mcp.json:
// enabledMcpjsonServers and disabledMcpjsonServers both empty or missing)
// the answer the first folder of from with one gave (the project's main
// checkout, another of its worktrees). Claude Code asks it in every new
// folder before anything else, so a new worktree of a project whose person
// answered once would wait on it again, an unattended agent forever. A
// folder with no entry yet is left to TrustClaudeProject.
func CarryClaudeMcpChoice(path string, dirs, from []string) (bool, error) {
	return EditClaudeConfig(path, func(root map[string]any) bool {
		projects, ok := root["projects"].(map[string]any)
		if !ok {
			return false
		}
		var enabled, disabled []any
		for _, dir := range from {
			entry, ok := projects[dir].(map[string]any)
			if !ok || !mcpChoiceMade(entry) {
				continue
			}
			enabled, _ = entry["enabledMcpjsonServers"].([]any)
			disabled, _ = entry["disabledMcpjsonServers"].([]any)
			break
		}
		if enabled == nil && disabled == nil {
			return false
		}
		changed := false
		for _, dir := range dirs {
			entry, ok := projects[dir].(map[string]any)
			if !ok || mcpChoiceMade(entry) {
				continue
			}
			entry["enabledMcpjsonServers"] = append([]any{}, enabled...)
			entry["disabledMcpjsonServers"] = append([]any{}, disabled...)
			changed = true
		}
		return changed
	})
}

// CarryClaudeLocalMcpChoice does what CarryClaudeMcpChoice does for the
// place Claude Code 2.1.30x keeps the answer: the folder's own
// .claude/settings.local.json (enabledMcpjsonServers,
// disabledMcpjsonServers, enableAllProjectMcpServers). The first folder of
// from that answered gives it to dir, unless dir answered already; the
// file's other settings stay as they are.
func CarryClaudeLocalMcpChoice(dir string, from []string) (bool, error) {
	if dir == "" {
		return false, nil
	}
	target := filepath.Join(dir, ".claude", "settings.local.json")
	have, err := readJSONObject(target)
	if err != nil {
		return false, err
	}
	if localMcpChoiceMade(have) {
		return false, nil
	}
	for _, f := range from {
		if f == "" || filepath.Clean(f) == filepath.Clean(dir) {
			continue
		}
		src, err := readJSONObject(filepath.Join(f, ".claude", "settings.local.json"))
		if err != nil || !localMcpChoiceMade(src) {
			continue
		}
		for _, k := range []string{"enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers"} {
			if v, ok := src[k]; ok {
				have[k] = v
			}
		}
		data, err := json.MarshalIndent(have, "", "  ")
		if err != nil {
			return false, err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return false, err
		}
		return true, os.WriteFile(target, append(data, '\n'), 0o644)
	}
	return false, nil
}

// readJSONObject reads a JSON object file; a missing one is empty.
func readJSONObject(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if len(bytes.TrimSpace(data)) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return out, nil
}

// localMcpChoiceMade says a folder's settings hold an answer about its
// repository's MCP servers.
func localMcpChoiceMade(m map[string]any) bool {
	if m["enableAllProjectMcpServers"] == true {
		return true
	}
	en, _ := m["enabledMcpjsonServers"].([]any)
	dis, _ := m["disabledMcpjsonServers"].([]any)
	return len(en) > 0 || len(dis) > 0
}

// mcpChoiceMade says a project's entry holds an answer to the question
// about its repository's MCP servers: one of them enabled or turned down.
func mcpChoiceMade(entry map[string]any) bool {
	en, _ := entry["enabledMcpjsonServers"].([]any)
	dis, _ := entry["disabledMcpjsonServers"].([]any)
	return len(en) > 0 || len(dis) > 0
}

// MarkClaudeOnboarded records in Claude Code's global config at path that
// its first-run screens were seen (the theme, the sign-in method, the
// security notes), so an agent started on that config goes straight to its
// prompt. Signing in is then /login.
func MarkClaudeOnboarded(path string) (bool, error) {
	return EditClaudeConfig(path, func(root map[string]any) bool {
		if root["hasCompletedOnboarding"] == true {
			return false
		}
		root["hasCompletedOnboarding"] = true
		return true
	})
}

// PrepareClaudeSettings sets what a Claude Code account pierd runs agents
// on needs in its settings.json, when missing: skipDangerousModePermission
// Prompt (the bypass mode's warning, which pierd's agents can reach from
// the app's mode menu, accepted, so switching to it never stops at a
// dialog) and, with theme, the theme its first-run screens would have
// asked for.
func PrepareClaudeSettings(settingsPath, theme string) (bool, error) {
	f, rel := fileAt(settingsPath)
	return editJSON(f, rel, func(root map[string]any) bool {
		changed := false
		if _, ok := root["skipDangerousModePermissionPrompt"]; !ok {
			root["skipDangerousModePermissionPrompt"] = true
			changed = true
		}
		if _, ok := root["theme"]; !ok && theme != "" {
			root["theme"] = theme
			changed = true
		}
		return changed
	})
}

// --- Codex -------------------------------------------------------------

// TrustCodexProject adds a [projects."<dir>"] table with trust_level =
// "trusted" to Codex's config.toml at path for each folder in dirs that
// has no entry there yet, in whatever form (a table, a dotted key, quoted
// or not). A second table for the same folder would make Codex refuse to
// start, so a file it cannot read safely (projects as an inline table) is
// left alone. The previous contents are kept beside it, as pierd does for
// its notify line.
func TrustCodexProject(path string, dirs ...string) (bool, error) {
	f, rel := fileAt(path)
	before, err := f.read(rel)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	doc := scanTOML(string(before))
	if doc.inline["projects"] {
		return false, nil
	}
	var add strings.Builder
	seen := map[string]bool{}
	for _, dir := range dirs {
		if dir == "" || seen[dir] || doc.defines("projects", dir) {
			continue
		}
		seen[dir] = true
		fmt.Fprintf(&add, "\n[projects.%s]\ntrust_level = \"trusted\"\n", tomlString(dir))
	}
	if add.Len() == 0 {
		return false, nil
	}
	return true, f.writeTOML(rel, before, appendTOML(before, add.String()))
}

// codexHookTimeout is how long Codex gives a hook that names no timeout,
// part of the identity it trusts a hook by.
const codexHookTimeout = 600

// TrustCodexHooks marks pierd's own hooks in Codex's hooks.json at
// hooksPath as trusted in its config.toml at configPath, so Codex runs them
// without stopping a new session at its "Hooks need review" screen. Codex
// keeps, per hook, [hooks.state."<hooks.json>:<event>:<group>:<handler>"]
// with trusted_hash, the sha256 of a normalized form of the hook (see
// CodexHookHash); only handlers that run pierd's hook command for bin are
// written, and a state the person set (a hook they disabled) keeps its
// other keys.
func TrustCodexHooks(configPath, hooksPath, bin string) (bool, error) {
	raw, err := os.ReadFile(hooksPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	var file struct {
		Hooks map[string][]struct {
			Matcher *string           `json:"matcher"`
			Hooks   []json.RawMessage `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		return false, fmt.Errorf("%s is not valid JSON: %w", hooksPath, err)
	}
	want := map[string]string{} // state key → hash
	for event, groups := range file.Hooks {
		label, ok := codexEventLabel(event)
		if !ok {
			continue
		}
		for g, group := range groups {
			if group.Matcher != nil && *group.Matcher != "" {
				continue // pierd's groups have none
			}
			for h, rawHandler := range group.Hooks {
				var handler map[string]any
				if json.Unmarshal(rawHandler, &handler) != nil {
					continue
				}
				command, _ := handler["command"].(string)
				if handler["type"] != "command" || !pierdHook(command, bin, "codex", event) {
					continue
				}
				hash, ok := CodexHookHash(label, handler)
				if !ok {
					continue
				}
				want[fmt.Sprintf("%s:%s:%d:%d", filepath.Clean(hooksPath), label, g, h)] = hash
			}
		}
	}
	if len(want) == 0 {
		return false, nil
	}
	f, rel := fileAt(configPath)
	before, err := f.read(rel)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	text := string(before)
	doc := scanTOML(text)
	if doc.inline["hooks"] || doc.inline["hooks.state"] {
		return false, nil
	}
	keys := make([]string, 0, len(want))
	for k := range want {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var add strings.Builder
	for _, key := range keys {
		hash := want[key]
		t, ok := doc.table("hooks", "state", key)
		switch {
		case !ok && doc.defines("hooks", "state", key):
			continue // written as a dotted key or inline: not touched
		case !ok:
			fmt.Fprintf(&add, "\n[hooks.state.%s]\ntrusted_hash = %s\n", tomlString(key), tomlString(hash))
		case tableValue(text, t, "trusted_hash") == hash:
		default:
			text = setTOMLKey(text, t, "trusted_hash", tomlString(hash))
			doc = scanTOML(text)
		}
	}
	after := appendTOML([]byte(text), add.String())
	if bytes.Equal(after, before) {
		return false, nil
	}
	return true, f.writeTOML(rel, before, after)
}

// pierdHook says whether command is pierd's hook for tool's event: the one
// bin installs, or one an install at another path (a link to it, an older
// copy) put there, `<…/pierd> hook codex Stop`.
func pierdHook(command, bin, tool, event string) bool {
	if command == hookCommand(bin, tool, event) {
		return true
	}
	path, ok := strings.CutSuffix(command, " hook "+tool+" "+event)
	if !ok {
		return false
	}
	if len(path) >= 2 && path[0] == '\'' && path[len(path)-1] == '\'' {
		path = strings.ReplaceAll(path[1:len(path)-1], `'\''`, "'")
	}
	return filepath.IsAbs(path) && filepath.Base(path) == "pierd"
}

// codexEventLabel is the name Codex keys a hook event by in its state.
func codexEventLabel(event string) (string, bool) {
	labels := map[string]string{
		"PreToolUse": "pre_tool_use", "PermissionRequest": "permission_request", "PostToolUse": "post_tool_use",
		"PreCompact": "pre_compact", "PostCompact": "post_compact", "SessionStart": "session_start",
		"SessionEnd": "session_end", "UserPromptSubmit": "user_prompt_submit", "SubagentStart": "subagent_start",
		"SubagentStop": "subagent_stop", "Stop": "stop", "Interrupt": "interrupt",
	}
	l, ok := labels[event]
	return l, ok
}

// CodexHookHash is the hash Codex trusts a command hook by (codex-rs hooks'
// hook_hash): sha256 of the JSON, keys sorted and nothing between tokens,
// of {"event_name": label, "hooks": [the handler normalized]}, where the
// normalized handler has its type, command, timeout (600 when it names
// none), async and statusMessage, and nothing else. ok is false for a
// handler that is not a plain command hook of an event with a fixed
// timeout.
func CodexHookHash(label string, handler map[string]any) (string, bool) {
	if label == "session_end" || label == "interrupt" {
		return "", false // their timeouts are clamped: not worth guessing
	}
	command, _ := handler["command"].(string)
	if handler["type"] != "command" || strings.TrimSpace(command) == "" {
		return "", false
	}
	if _, ok := handler["additionalContextLimit"]; ok {
		return "", false // hashed only when it differs from Codex's default: not worth guessing
	}
	timeout := int64(codexHookTimeout)
	if t, ok := handler["timeout"]; ok && t != nil {
		f, ok := t.(float64)
		if !ok || f < 0 || f != float64(int64(f)) {
			return "", false
		}
		timeout = max(int64(f), 1)
	}
	async := false
	if a, ok := handler["async"]; ok && a != nil {
		if async, ok = a.(bool); !ok {
			return "", false
		}
	}
	norm := []string{
		`"async":` + strconv.FormatBool(async),
		`"command":` + serdeString(command),
	}
	if m, ok := handler["statusMessage"]; ok && m != nil {
		s, ok := m.(string)
		if !ok {
			return "", false
		}
		norm = append(norm, `"statusMessage":`+serdeString(s))
	}
	norm = append(norm, `"timeout":`+strconv.FormatInt(timeout, 10), `"type":"command"`)
	identity := `{"event_name":` + serdeString(label) + `,"hooks":[{` + strings.Join(norm, ",") + `}]}`
	sum := sha256.Sum256([]byte(identity))
	return "sha256:" + hex.EncodeToString(sum[:]), true
}

// serdeString quotes s as serde_json writes a string: only '"', '\\' and
// control characters escaped, the short forms where JSON has them, the
// rest as \u00XX in lowercase hex; everything else as it is.
func serdeString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// --- a little TOML: enough to find what a config.toml already says -------

// tomlDoc is what scanTOML found in a config.toml: every key path a table
// header or a key defines, the tables by their line, and the paths given
// an inline table or another value.
type tomlDoc struct {
	lines   []string
	defined map[string]bool // joinPath(path) of every prefix defined
	tables  map[string]int  // joinPath(header path) → its header's line
	inline  map[string]bool // joinPath(path) assigned a value (dotted: "a.b")
}

func joinPath(p []string) string { return strings.Join(p, "\x00") }

// defines says whether the document defines the path, or anything under it.
func (d tomlDoc) defines(path ...string) bool { return d.defined[joinPath(path)] }

// table is the line of the header of the table at path, if it is one.
func (d tomlDoc) table(path ...string) (int, bool) {
	l, ok := d.tables[joinPath(path)]
	return l, ok
}

var (
	tomlHeader = regexp.MustCompile(`^\s*\[\s*([^\[\]].*?)\s*\]\s*(?:#.*)?$`)
	tomlArray  = regexp.MustCompile(`^\s*\[\[`)
)

// scanTOML reads the keys and tables of a TOML document, line by line.
// Values are not read, except to step over multi-line strings.
func scanTOML(text string) tomlDoc {
	d := tomlDoc{lines: strings.Split(text, "\n"), defined: map[string]bool{}, tables: map[string]int{}, inline: map[string]bool{}}
	mark := func(path []string) {
		for i := 1; i <= len(path); i++ {
			d.defined[joinPath(path[:i])] = true
		}
	}
	var table []string
	inString := ""
	for i, line := range d.lines {
		if inString != "" {
			if strings.Contains(line, inString) {
				inString = ""
			}
			continue
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if tomlArray.MatchString(line) {
			// An array of tables: what follows belongs to an element of it.
			table = []string{"\x00array"}
			continue
		}
		if m := tomlHeader.FindStringSubmatch(line); m != nil && strings.HasPrefix(trimmed, "[") {
			if p, ok := parseTOMLKey(m[1]); ok {
				table = p
				mark(p)
				d.tables[joinPath(p)] = i
			}
			continue
		}
		key, rest, ok := splitTOMLKey(trimmed)
		if !ok {
			continue
		}
		full := append(append([]string{}, table...), key...)
		mark(full)
		value := strings.TrimSpace(rest)
		d.inline[strings.Join(full, ".")] = true
		for _, q := range []string{`"""`, `'''`} {
			if strings.HasPrefix(value, q) && !strings.Contains(value[3:], q) {
				inString = q
			}
		}
	}
	return d
}

// splitTOMLKey splits a key/value line into its key path and what follows
// the "=".
func splitTOMLKey(line string) ([]string, string, bool) {
	for i := 0; i < len(line); i++ {
		switch line[i] {
		case '"', '\'':
			end := closingQuote(line, i)
			if end < 0 {
				return nil, "", false
			}
			i = end
		case '=':
			p, ok := parseTOMLKey(line[:i])
			return p, line[i+1:], ok
		}
	}
	return nil, "", false
}

// closingQuote is the index of the quote that closes the string opening at
// i, or -1.
func closingQuote(s string, i int) int {
	q := s[i]
	for j := i + 1; j < len(s); j++ {
		if q == '"' && s[j] == '\\' {
			j++
			continue
		}
		if s[j] == q {
			return j
		}
	}
	return -1
}

var bareKey = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// parseTOMLKey reads a dotted key ("projects.\"/a b\"", 'x'.y) into its parts.
func parseTOMLKey(s string) ([]string, bool) {
	var parts []string
	s = strings.TrimSpace(s)
	for len(s) > 0 {
		var part string
		switch s[0] {
		case '"':
			end := closingQuote(s, 0)
			if end < 0 {
				return nil, false
			}
			v, err := strconv.Unquote(s[:end+1])
			if err != nil {
				v, err = unquoteTOML(s[1:end])
				if err != nil {
					return nil, false
				}
			}
			part, s = v, s[end+1:]
		case '\'':
			end := strings.IndexByte(s[1:], '\'')
			if end < 0 {
				return nil, false
			}
			part, s = s[1:end+1], s[end+2:]
		default:
			end := strings.IndexAny(s, ". \t")
			if end < 0 {
				end = len(s)
			}
			if !bareKey.MatchString(s[:end]) {
				return nil, false
			}
			part, s = s[:end], s[end:]
		}
		parts = append(parts, part)
		s = strings.TrimSpace(s)
		if s == "" {
			break
		}
		if s[0] != '.' {
			return nil, false
		}
		s = strings.TrimSpace(s[1:])
		if s == "" {
			return nil, false
		}
	}
	return parts, len(parts) > 0
}

// unquoteTOML reads the escapes of a TOML basic string that Go's own
// unquoting does not take (\e, \U with 8 digits, a lone "\x" is not TOML).
func unquoteTOML(s string) (string, error) {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c != '\\' {
			b.WriteByte(c)
			continue
		}
		i++
		if i >= len(s) {
			return "", errors.New("a lone backslash")
		}
		switch s[i] {
		case 'b':
			b.WriteByte('\b')
		case 't':
			b.WriteByte('\t')
		case 'n':
			b.WriteByte('\n')
		case 'f':
			b.WriteByte('\f')
		case 'r':
			b.WriteByte('\r')
		case 'e':
			b.WriteByte(0x1b)
		case '"':
			b.WriteByte('"')
		case '\\':
			b.WriteByte('\\')
		case 'u', 'U':
			n := 4
			if s[i] == 'U' {
				n = 8
			}
			if i+1+n > len(s) {
				return "", errors.New("a short unicode escape")
			}
			v, err := strconv.ParseUint(s[i+1:i+1+n], 16, 32)
			if err != nil || !utf8.ValidRune(rune(v)) {
				return "", errors.New("a bad unicode escape")
			}
			b.WriteRune(rune(v))
			i += n
		default:
			return "", fmt.Errorf("an unknown escape \\%c", s[i])
		}
	}
	return b.String(), nil
}

// tomlString quotes s as a TOML basic string.
func tomlString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\u%04X`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// appendTOML adds tables at the end of a document, after a newline when it
// does not end in one.
func appendTOML(before []byte, add string) []byte {
	if add == "" {
		return before
	}
	out := append([]byte{}, before...)
	if len(out) > 0 && out[len(out)-1] != '\n' {
		out = append(out, '\n')
	}
	if len(out) == 0 {
		add = strings.TrimPrefix(add, "\n")
	}
	return append(out, add...)
}

// tableEnd is the line after the last of the table whose header is at line
// header: the next header's, or the end.
func tableEnd(lines []string, header int) int {
	for i := header + 1; i < len(lines); i++ {
		if t := strings.TrimSpace(lines[i]); strings.HasPrefix(t, "[") {
			return i
		}
	}
	return len(lines)
}

// tableValue is the string key holds in the table whose header is at line
// header, "" when it holds none.
func tableValue(text string, header int, key string) string {
	lines := strings.Split(text, "\n")
	for i := header + 1; i < tableEnd(lines, header); i++ {
		k, rest, ok := splitTOMLKey(strings.TrimSpace(lines[i]))
		if !ok || len(k) != 1 || k[0] != key {
			continue
		}
		v := strings.TrimSpace(rest)
		if c := closingQuote(v, 0); strings.HasPrefix(v, `"`) && c > 0 {
			if s, err := unquoteTOML(v[1:c]); err == nil {
				return s
			}
		} else if strings.HasPrefix(v, "'") {
			if end := strings.IndexByte(v[1:], '\''); end >= 0 {
				return v[1 : end+1]
			}
		}
		return ""
	}
	return ""
}

// setTOMLKey sets key = value in the table whose header is at line header:
// the line where the table already has the key, else a new line right
// under the header.
func setTOMLKey(text string, header int, key, value string) string {
	lines := strings.Split(text, "\n")
	for i := header + 1; i < tableEnd(lines, header); i++ {
		k, _, ok := splitTOMLKey(strings.TrimSpace(lines[i]))
		if ok && len(k) == 1 && k[0] == key {
			lines[i] = key + " = " + value
			return strings.Join(lines, "\n")
		}
	}
	lines = append(lines[:header+1], append([]string{key + " = " + value}, lines[header+1:]...)...)
	return strings.Join(lines, "\n")
}

// writeTOML keeps the previous contents beside the file (when it had any)
// and writes the new ones, a new file private to its owner.
func (f files) writeTOML(rel string, before, after []byte) error {
	if len(before) > 0 {
		if err := f.backup(rel, before); err != nil {
			return err
		}
	}
	return f.write(rel, after, 0o600)
}
