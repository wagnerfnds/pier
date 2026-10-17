package box

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The MCP tests never run the real agent CLIs: claude and codex on PATH are
// this test binary (TestMain sends it to fakeAgentCLI), which keeps each
// account's servers where the real ones do for what pierd reads (Claude
// Code's .claude.json) and records every call.

type fakeCall struct {
	Tool string   `json:"tool"`
	Dir  string   `json:"dir"`
	Args []string `json:"args"`
}

// fakeAgentCLIs puts the stand-in claude and codex first on PATH and
// answers the file their calls are recorded in.
func fakeAgentCLIs(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	for _, tool := range []string{"claude", "codex"} {
		script := fmt.Sprintf("#!/bin/sh\nFAKE_AGENT_CLI=%s exec %s \"$@\"\n", tool, shellQuote(exe))
		if err := os.WriteFile(filepath.Join(bin, tool), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	log := filepath.Join(t.TempDir(), "calls.jsonl")
	t.Setenv("FAKE_AGENT_LOG", log)
	return log
}

func fakeCalls(t *testing.T, log string) []fakeCall {
	t.Helper()
	f, err := os.Open(log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []fakeCall
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var c fakeCall
		json.Unmarshal(sc.Bytes(), &c)
		out = append(out, c)
	}
	return out
}

// fakeAgentCLI answers `mcp add|remove|list` as Claude Code 2.1 and Codex
// 0.160 do, closely enough for pierd.
func fakeAgentCLI(tool string, args []string) int {
	dirVar := map[string]string{"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"}[tool]
	dir := os.Getenv(dirVar)
	if log := os.Getenv("FAKE_AGENT_LOG"); log != "" {
		line, _ := json.Marshal(fakeCall{Tool: tool, Dir: dir, Args: args})
		if f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			f.Write(append(line, '\n'))
			f.Close()
		}
	}
	if os.Getenv("PIER_HOOKS_QUIET") != "1" || os.Getenv("PIER_SESSION") != "" {
		fmt.Fprintln(os.Stderr, "run without quiet hooks or with pierd's variables")
		return 3
	}
	home, _ := os.UserHomeDir()
	if len(args) < 2 || args[0] != "mcp" {
		fmt.Fprintln(os.Stderr, "unexpected", args)
		return 2
	}
	if tool == "claude" {
		return fakeClaude(dir, home, args[1:])
	}
	return fakeCodex(dir, home, args[1:])
}

func fakeClaude(dir, home string, args []string) int {
	path := filepath.Join(home, ".claude.json")
	if dir != "" {
		path = filepath.Join(dir, ".claude.json")
	}
	cfg := map[string]any{}
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &cfg)
	}
	servers, _ := cfg["mcpServers"].(map[string]any)
	if servers == nil {
		servers = map[string]any{}
	}
	save := func() {
		cfg["mcpServers"] = servers
		data, _ := json.MarshalIndent(cfg, "", "  ")
		os.WriteFile(path, data, 0o600)
	}
	switch args[0] {
	case "add":
		var scope, transport string
		headers, env := map[string]any{}, map[string]any{}
		i := 1
		for ; i < len(args) && args[i] != "--"; i++ {
			switch args[i] {
			case "--scope":
				i++
				scope = args[i]
			case "--transport":
				i++
				transport = args[i]
			case "-H":
				i++
				k, v, _ := strings.Cut(args[i], ": ")
				headers[k] = v
			case "-e":
				i++
				k, v, _ := strings.Cut(args[i], "=")
				env[k] = v
			default:
				fmt.Fprintln(os.Stderr, "unknown option", args[i])
				return 2
			}
		}
		rest := args[min(i+1, len(args)):]
		if scope != "user" || len(rest) < 2 {
			fmt.Fprintln(os.Stderr, "bad add", args)
			return 2
		}
		name := rest[0]
		if _, ok := servers[name]; ok {
			fmt.Fprintf(os.Stderr, "MCP server %s already exists in user config\n", name)
			return 1
		}
		if transport == "http" {
			e := map[string]any{"type": "http", "url": rest[1]}
			if len(headers) > 0 {
				e["headers"] = headers
			}
			servers[name] = e
		} else {
			e := map[string]any{"type": "stdio", "command": rest[1], "args": rest[2:]}
			if len(env) > 0 {
				e["env"] = env
			}
			servers[name] = e
		}
		save()
		fmt.Printf("Added MCP server %s to user config\n", name)
	case "remove":
		if len(args) != 4 || args[1] != "--scope" || args[2] != "user" {
			fmt.Fprintln(os.Stderr, "bad remove", args)
			return 2
		}
		if _, ok := servers[args[3]]; !ok {
			fmt.Fprintf(os.Stderr, "No MCP server named %q in user scope\n", args[3])
			return 1
		}
		delete(servers, args[3])
		save()
	case "list":
		if len(servers) == 0 {
			fmt.Println("No MCP servers configured. Use `claude mcp add` to add a server.")
			return 0
		}
		fmt.Print("Checking MCP server health…\n\n")
		names := make([]string, 0, len(servers))
		for n := range servers {
			names = append(names, n)
		}
		slices.Sort(names)
		for _, n := range names {
			e, _ := servers[n].(map[string]any)
			if e["type"] == "http" {
				h, _ := e["headers"].(map[string]any)
				if strings.HasPrefix(fmt.Sprint(h["Authorization"]), "Bearer ") {
					fmt.Printf("%s: %s (HTTP) - ✔ Connected\n", n, e["url"])
				} else {
					fmt.Printf("%s: %s (HTTP) - ✘ Failed to connect — Dynamic Client Registration rejected (HTTP 401):\n", n, e["url"])
				}
				continue
			}
			fmt.Printf("%s: %s - ✘ Failed to connect — CONNECTION_CLOSED: Connection closed\n", n, e["command"])
		}
	default:
		return 2
	}
	return 0
}

type fakeCodexEntry struct {
	URL     string            `json:"url,omitempty"`
	Bearer  string            `json:"bearer,omitempty"`
	Command string            `json:"command,omitempty"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	Enabled bool              `json:"enabled"`
}

func fakeCodexStore(dir, home string) string {
	if dir == "" {
		dir = filepath.Join(home, ".codex")
	}
	return filepath.Join(dir, "fake-mcp.json")
}

func fakeCodex(dir, home string, args []string) int {
	path := fakeCodexStore(dir, home)
	servers := map[string]fakeCodexEntry{}
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &servers)
	}
	save := func() {
		os.MkdirAll(filepath.Dir(path), 0o700)
		data, _ := json.Marshal(servers)
		os.WriteFile(path, data, 0o600)
	}
	switch args[0] {
	case "add":
		name := args[1]
		e := fakeCodexEntry{Enabled: true}
		for i := 2; i < len(args); i++ {
			switch args[i] {
			case "--url":
				i++
				e.URL = args[i]
			case "--bearer-token-env-var":
				i++
				e.Bearer = args[i]
			case "--env":
				i++
				k, v, _ := strings.Cut(args[i], "=")
				if e.Env == nil {
					e.Env = map[string]string{}
				}
				e.Env[k] = v
			case "--":
				e.Command, e.Args = args[i+1], args[i+2:]
				i = len(args)
			default:
				fmt.Fprintln(os.Stderr, "unknown option", args[i])
				return 2
			}
		}
		servers[name] = e
		save()
		fmt.Printf("Added global MCP server '%s'.\n", name)
	case "remove":
		if _, ok := servers[args[1]]; !ok {
			fmt.Printf("No MCP server named '%s' found.\n", args[1])
			return 0
		}
		delete(servers, args[1])
		save()
		fmt.Printf("Removed global MCP server '%s'.\n", args[1])
	case "list":
		if len(args) < 2 || args[1] != "--json" {
			return 2
		}
		var out []map[string]any
		names := make([]string, 0, len(servers))
		for n := range servers {
			names = append(names, n)
		}
		slices.Sort(names)
		for _, n := range names {
			e := servers[n]
			transport := map[string]any{"type": "stdio", "command": e.Command, "args": e.Args, "env": e.Env}
			if e.URL != "" {
				var bearer any
				if e.Bearer != "" {
					bearer = e.Bearer
				}
				transport = map[string]any{"type": "streamable_http", "url": e.URL, "bearer_token_env_var": bearer}
			}
			out = append(out, map[string]any{"name": n, "enabled": e.Enabled, "transport": transport, "auth_status": "bearer_token"})
		}
		if out == nil {
			out = []map[string]any{}
		}
		data, _ := json.MarshalIndent(out, "", "  ")
		fmt.Println(string(data))
	default:
		return 2
	}
	return 0
}

// mcpTestHome gives a test a home of its own (the built-in accounts'
// folders and .claude.json are there) and the stand-in CLIs, and answers
// the home and the file their calls are recorded in.
func mcpTestHome(t *testing.T) (home, log string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("CODEX_HOME", "")
	return home, fakeAgentCLIs(t)
}

func readJSONFile(t *testing.T, path string) map[string]any {
	t.Helper()
	out := map[string]any{}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func claudeServers(t *testing.T, path string) map[string]any {
	t.Helper()
	s, _ := readJSONFile(t, path)["mcpServers"].(map[string]any)
	return s
}

func codexServers(t *testing.T, dir string) map[string]fakeCodexEntry {
	t.Helper()
	out := map[string]fakeCodexEntry{}
	if data, err := os.ReadFile(filepath.Join(dir, "fake-mcp.json")); err == nil {
		json.Unmarshal(data, &out)
	}
	return out
}

// A server saved in the app reaches every Claude Code and Codex account
// through their CLIs, its token never shown back, and pierd only ever
// takes out what it wrote: a server the person added by hand stays, even
// one of the same name.
func TestMCPServersReachEveryAccountAndOnlyPierdsEntriesGo(t *testing.T) {
	home, log := mcpTestHome(t)
	state := t.TempDir()
	var bx *Box
	c, bus := servedBox(t, func(b *Box) { b.StateDir = state; bx = b })
	t.Cleanup(func() { bx.mcp.bg.Wait() })
	seen, stop := bus.Subscribe()
	defer stop()

	// The person's own servers in the built-in Claude Code account.
	mine := `{"numStartups":3,"mcpServers":{"mine":{"type":"http","url":"https://example.com/mine"},"docs":{"type":"stdio","command":"their-docs"}}}`
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(mine), 0o600); err != nil {
		t.Fatal(err)
	}

	put := func(name string, body map[string]any) (int, MCPServerView) {
		var v MCPServerView
		return call(t, c, "PUT", "/v1/mcp/"+name, "", body, &v), v
	}
	status, v := put("crm", map[string]any{"url": "https://mcp.example.com/mcp", "token": "tok-123", "headers": map[string]string{"X-Team": "blue"}})
	if status != 200 || !v.TokenSet || v.TokenVar != "PIER_MCP_CRM_TOKEN" || v.Transport != "http" || !v.Enabled || strings.Join(v.Agents, ",") != "claude,codex" {
		t.Fatalf("put = %d %+v", status, v)
	}
	claude := claudeServers(t, filepath.Join(home, ".claude.json"))
	want := `{"headers":{"Authorization":"Bearer tok-123","X-Team":"blue"},"type":"http","url":"https://mcp.example.com/mcp"}`
	if got, _ := json.Marshal(claude["crm"]); string(got) != want {
		t.Fatalf("claude's entry = %s", got)
	}
	if _, ok := claude["mine"]; !ok {
		t.Fatal("the person's own server is gone")
	}
	if cfg := readJSONFile(t, filepath.Join(home, ".claude.json")); cfg["numStartups"] != 3.0 {
		t.Errorf("the rest of .claude.json changed: %v", cfg)
	}
	var argv []string
	for _, cl := range fakeCalls(t, log) {
		argv = append(argv, cl.Tool+" "+strings.Join(cl.Args, " "))
	}
	for _, want := range []string{
		"claude mcp add --scope user --transport http -H Authorization: Bearer tok-123 -H X-Team: blue -- crm https://mcp.example.com/mcp",
		"codex mcp list --json",
		"codex mcp add crm --url https://mcp.example.com/mcp --bearer-token-env-var PIER_MCP_CRM_TOKEN",
	} {
		if !slices.Contains(argv, want) {
			t.Errorf("no call %q in %q", want, argv)
		}
	}
	codex := codexServers(t, filepath.Join(home, ".codex"))
	if e := codex["crm"]; e.URL != "https://mcp.example.com/mcp" || e.Bearer != "PIER_MCP_CRM_TOKEN" {
		t.Fatalf("codex's entry = %+v", e)
	}
	// The token is in pierd's own file, private, and never in an answer.
	if info, err := os.Stat(filepath.Join(state, "mcp.json")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mcp.json: %v %v", info, err)
	}
	resp, err := c.DoWithHeader(context.Background(), "GET", "/v1/mcp", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if strings.Contains(string(raw), "tok-123") || !strings.Contains(string(raw), `"token_set":true`) {
		t.Fatalf("GET /v1/mcp = %s", raw)
	}

	// Saved again without a token: the box keeps it; a new URL is written.
	if status, v = put("crm", map[string]any{"url": "https://mcp.example.com/v2", "headers": map[string]string{"X-Team": "blue"}}); status != 200 || !v.TokenSet {
		t.Fatalf("put without a token = %d %+v", status, v)
	}
	claude = claudeServers(t, filepath.Join(home, ".claude.json"))
	if e, _ := claude["crm"].(map[string]any); e["url"] != "https://mcp.example.com/v2" || fmt.Sprint(e["headers"]) != "map[Authorization:Bearer tok-123 X-Team:blue]" {
		t.Fatalf("claude's entry after the new URL = %v", e)
	}
	calls := len(fakeCalls(t, log))
	// Saved unchanged: nothing to write.
	put("crm", map[string]any{"url": "https://mcp.example.com/v2", "headers": map[string]string{"X-Team": "blue"}})
	for _, cl := range fakeCalls(t, log)[calls:] {
		if cl.Args[1] != "list" {
			t.Errorf("an unchanged server was written again: %v", cl.Args)
		}
	}

	// A name the person already uses in one account: theirs stays there.
	status, v = put("docs", map[string]any{"transport": "stdio", "command": "docs-mcp", "args": []string{"--stdio"}, "env": map[string]string{"DOCS_KEY": "k"}})
	if status != 200 || len(v.Problems) != 1 || !strings.Contains(v.Problems[0], "Claude Code: already has a server named docs") {
		t.Fatalf("put docs = %d %+v", status, v)
	}
	if e, _ := claudeServers(t, filepath.Join(home, ".claude.json"))["docs"].(map[string]any); e["command"] != "their-docs" {
		t.Fatalf("the person's docs was replaced: %v", e)
	}
	if e := codexServers(t, filepath.Join(home, ".codex"))["docs"]; e.Command != "docs-mcp" || strings.Join(e.Args, " ") != "--stdio" || e.Env["DOCS_KEY"] != "k" {
		t.Fatalf("codex's docs = %+v", e)
	}

	// A new account gets them too.
	var a AccountView
	if status := call(t, c, "POST", "/v1/accounts", "", map[string]string{"agent": "claude", "name": "Trabalho"}, &a); status != 200 {
		t.Fatalf("add account = %d", status)
	}
	bx.mcp.bg.Wait()
	added := claudeServers(t, filepath.Join(a.Dir, ".claude.json"))
	if _, ok := added["crm"]; !ok {
		t.Fatalf("the new account's servers = %v", added)
	}
	if _, ok := added["docs"]; !ok {
		t.Fatalf("docs is not the person's in the new account, so it goes there: %v", added)
	}
	for _, cl := range fakeCalls(t, log) {
		if cl.Tool == "claude" && cl.Dir != "" && cl.Dir != a.Dir {
			t.Errorf("claude ran on %s", cl.Dir)
		}
	}

	// Every session gets the token Codex reads: chats, home terminals and
	// worktrees alike.
	if env := strings.Join(bx.sessionEnv(context.Background(), home), "\n"); !strings.Contains(env, "PIER_MCP_CRM_TOKEN=tok-123") {
		t.Errorf("a home session's env lacks the token: %s", env)
	}
	repo := gitRepo(t)
	call(t, c, "POST", "/v1/locations", "", map[string]string{"name": "cal", "path": repo}, nil)
	if env := strings.Join(bx.sessionEnv(context.Background(), repo), "\n"); !strings.Contains(env, "PIER_MCP_CRM_TOKEN=tok-123") || !strings.Contains(env, "PIER_WORKTREE_PATH=") {
		t.Errorf("a worktree session's env = %s", env)
	}

	// Turned off: out of every account, the person's servers untouched.
	if status, v = put("crm", map[string]any{"url": "https://mcp.example.com/v2", "enabled": false}); status != 200 || v.Enabled || !v.TokenSet {
		t.Fatalf("turn off = %d %+v", status, v)
	}
	if _, ok := claudeServers(t, filepath.Join(home, ".claude.json"))["crm"]; ok {
		t.Error("a server turned off is still in the built-in account")
	}
	if _, ok := claudeServers(t, filepath.Join(a.Dir, ".claude.json"))["crm"]; ok {
		t.Error("a server turned off is still in the added account")
	}
	if _, ok := codexServers(t, filepath.Join(home, ".codex"))["crm"]; ok {
		t.Error("a server turned off is still in Codex")
	}
	if strings.Contains(strings.Join(bx.mcpSessionEnv(), " "), "CRM") {
		t.Error("sessions still get the token of a server turned off")
	}

	// Removed: gone from where pierd put it, the person's own docs stays.
	if status := call(t, c, "DELETE", "/v1/mcp/docs", "", nil, nil); status != 200 {
		t.Fatalf("delete = %d", status)
	}
	if status := call(t, c, "DELETE", "/v1/mcp/docs", "", nil, nil); status != 404 {
		t.Fatalf("delete again = %d", status)
	}
	if e, _ := claudeServers(t, filepath.Join(home, ".claude.json"))["docs"].(map[string]any); e["command"] != "their-docs" {
		t.Fatalf("the person's docs went with pierd's: %v", e)
	}
	if _, ok := claudeServers(t, filepath.Join(a.Dir, ".claude.json"))["docs"]; ok {
		t.Error("docs is still in the added account")
	}
	if _, ok := codexServers(t, filepath.Join(home, ".codex"))["docs"]; ok {
		t.Error("docs is still in Codex")
	}
	for _, cl := range fakeCalls(t, log) {
		joined := strings.Join(cl.Args, " ")
		if strings.Contains(joined, "mine") {
			t.Errorf("pierd touched the person's server: %v", cl.Args)
		}
		if cl.Tool == "claude" && cl.Dir == "" && strings.Contains(joined, "remove") && strings.HasSuffix(joined, " docs") {
			t.Errorf("pierd removed the person's docs: %v", cl.Args)
		}
	}
	if w := bx.loadMCPWritten(); len(w) != 0 {
		t.Errorf("pierd still records entries: %v", w)
	}

	// Events name the server, never its token or URL.
	deadline := time.After(5 * time.Second)
	var types []string
	for len(types) < 6 {
		select {
		case e := <-seen:
			if e.Type != "mcp.changed" {
				continue
			}
			data, _ := json.Marshal(e.Data)
			if strings.Contains(string(data), "tok-123") || strings.Contains(string(data), "example.com") {
				t.Errorf("event %s carries a secret: %s", e.Type, data)
			}
			types = append(types, string(data))
		case <-deadline:
			t.Fatalf("mcp.changed events = %v", types)
		}
	}
}

// What the app cannot save: names the variables or the CLIs would not
// take, an Authorization header (that is the token), a token where it
// would show, two names that share a token variable.
func TestMCPRefusesWhatTheAgentsCannotUse(t *testing.T) {
	mcpTestHome(t)
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })
	for _, tc := range []struct {
		name string
		body map[string]any
	}{
		{"Crm", map[string]any{"url": "https://x.example.com"}},
		{"a.b", map[string]any{"url": "https://x.example.com"}},
		{strings.Repeat("a", 41), map[string]any{"url": "https://x.example.com"}},
		{"ftp", map[string]any{"url": "ftp://x.example.com"}},
		{"nohost", map[string]any{"url": "https:///mcp"}},
		{"auth", map[string]any{"url": "https://x.example.com", "headers": map[string]string{"authorization": "Bearer x"}}},
		{"badheader", map[string]any{"url": "https://x.example.com", "headers": map[string]string{"X Team": "1"}}},
		{"newline", map[string]any{"url": "https://x.example.com", "headers": map[string]string{"X-Team": "a\nb"}}},
		{"spaces", map[string]any{"url": "https://x.example.com", "token": "two words"}},
		{"stdiotoken", map[string]any{"transport": "stdio", "command": "x", "token": "t"}},
		{"nocommand", map[string]any{"transport": "stdio"}},
		{"badenv", map[string]any{"transport": "stdio", "command": "x", "env": map[string]string{"1X": "y"}}},
		{"mixed", map[string]any{"url": "https://x.example.com", "command": "x"}},
		{"noagent", map[string]any{"url": "https://x.example.com", "agents": []string{}}},
		{"other", map[string]any{"url": "https://x.example.com", "agents": []string{"gemini"}}},
		{"transport", map[string]any{"transport": "sse", "url": "https://x.example.com"}},
	} {
		if status := call(t, c, "PUT", "/v1/mcp/"+tc.name, "", tc.body, nil); status != 400 {
			t.Errorf("%s %v = %d", tc.name, tc.body, status)
		}
	}
	if status := call(t, c, "PUT", "/v1/mcp/my-server", "", map[string]any{"url": "https://x.example.com", "agents": []string{"claude"}}, nil); status != 200 {
		t.Fatalf("my-server = %d", status)
	}
	if status := call(t, c, "PUT", "/v1/mcp/my_server", "", map[string]any{"url": "https://x.example.com"}, nil); status != 400 {
		t.Errorf("my_server, sharing PIER_MCP_MY_SERVER_TOKEN = %d", status)
	}
	var list struct{ Servers []MCPServerView }
	call(t, c, "GET", "/v1/mcp", "", nil, &list)
	if len(list.Servers) != 1 || list.Servers[0].Name != "my-server" || list.Servers[0].TokenSet || strings.Join(list.Servers[0].Agents, ",") != "claude" {
		t.Fatalf("servers = %+v", list.Servers)
	}
}

// Claude Code's list as it prints it (captured from Claude Code 2.1.302,
// with servers that answer, refuse, are not there and exit at once).
func TestMCPStatusReadsClaudeCodesList(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "mcp", "claude-list.txt"))
	if err != nil {
		t.Fatal(err)
	}
	got := parseClaudeMCPList(string(data))
	for name, want := range map[string]MCPAgentStatus{
		"stub":      {State: "connected"},
		"dashed":    {State: "connected"},
		"broken":    {State: "failed", Issue: "ECONNREFUSED: ECONNREFUSED: Unable to connect. Is the computer able to access the url?"},
		"noauth":    {State: "failed", Issue: "Dynamic Client Registration rejected (HTTP 401):"},
		"stdio-one": {State: "failed", Issue: "CONNECTION_CLOSED: Connection closed"},
	} {
		if got[name] != want {
			t.Errorf("%s = %+v, want %+v", name, got[name], want)
		}
	}
	if len(got) != 5 {
		t.Errorf("parsed %d servers: %v", len(got), got)
	}
	empty, _ := os.ReadFile(filepath.Join("testdata", "mcp", "claude-list-empty.txt"))
	if got := parseClaudeMCPList(string(empty)); len(got) != 0 {
		t.Errorf("an empty list = %v", got)
	}
	// The other marks Claude Code 2.1 prints.
	more := "a: https://a.example.com (HTTP) - ! Needs authentication\n" +
		"b: https://b.example.com (HTTP) - ! Connected · tools fetch failed\n" +
		"c: https://c.example.com (HTTP) - ⏸ Pending approval (run `claude` to approve)\n" +
		"d: npx d - ⊘ Disabled for this project (re-enable via /mcp)\n" +
		"claude.ai Gmail: https://gmail.example.com - ✔ Connected\n"
	got = parseClaudeMCPList(more)
	if got["a"].State != "needs_auth" || got["b"].State != "failed" || got["c"].State != "pending" || got["d"].State != "disabled" || len(got) != 4 {
		t.Errorf("marks = %+v", got)
	}
}

// Codex's list as it prints it with --json (captured from Codex 0.160.1).
func TestMCPStatusReadsCodexsList(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "mcp", "codex-list.json"))
	if err != nil {
		t.Fatal(err)
	}
	list, err := parseCodexMCPList(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 3 || !list["stub"].Enabled || list["stub"].Transport.Type != "streamable_http" || *list["stub"].Transport.BearerTokenEnvVar != "PIER_MCP_STUB_TOKEN" ||
		list["falser"].Transport.Type != "stdio" || list["broken"].Transport.BearerTokenEnvVar != nil {
		t.Fatalf("list = %+v", list)
	}
	data, _ = os.ReadFile(filepath.Join("testdata", "mcp", "codex-list-disabled.json"))
	if list, err = parseCodexMCPList(data); err != nil || list["broken"].Enabled || !list["stub"].Enabled {
		t.Fatalf("disabled list = %+v %v", list, err)
	}
	if list, err := parseCodexMCPList([]byte("[]\n")); err != nil || len(list) != 0 {
		t.Fatalf("empty = %v %v", list, err)
	}
	if _, err := parseCodexMCPList([]byte("Error: oops")); err == nil {
		t.Fatal("text read as a list")
	}
}

// mcpServerStub is an MCP server that wants a bearer token and answers its
// initialize as an event stream, as many do.
func mcpServerStub(t *testing.T, token string) (*httptest.Server, *atomic.Int32) {
	var closed atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.Method == http.MethodDelete {
			closed.Add(1)
			return
		}
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"initialize"`) {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Mcp-Session-Id", "s-1")
		fmt.Fprint(w, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"stub\"}}}\n\n")
		w.(http.Flusher).Flush()
		// The stream stays open, as a server's may.
		select {
		case <-r.Context().Done():
		case <-time.After(5 * time.Second):
		}
	}))
	t.Cleanup(srv.Close)
	return srv, &closed
}

// pierd shakes hands with an http server for Codex, whose own list cannot
// tell whether it answers.
func TestMCPProbe(t *testing.T) {
	srv, closed := mcpServerStub(t, "good")
	ctx := context.Background()
	start := time.Now()
	if st := probeMCP(ctx, MCPServer{URL: srv.URL, Token: "good"}); st.State != "connected" {
		t.Fatalf("right token = %+v", st)
	}
	if time.Since(start) > 3*time.Second {
		t.Error("the probe waited for the stream to end")
	}
	deadline := time.Now().Add(3 * time.Second)
	for closed.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if closed.Load() != 1 {
		t.Error("the probe left its session open")
	}
	if st := probeMCP(ctx, MCPServer{URL: srv.URL, Token: "bad"}); st.State != "needs_auth" || !strings.Contains(st.Issue, "refused the token") {
		t.Errorf("wrong token = %+v", st)
	}
	if st := probeMCP(ctx, MCPServer{URL: srv.URL}); st.State != "needs_auth" || !strings.Contains(st.Issue, "asks for a token") {
		t.Errorf("no token = %+v", st)
	}
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "<html>hello</html>") }))
	defer page.Close()
	if st := probeMCP(ctx, MCPServer{URL: page.URL}); st.State != "failed" || !strings.Contains(st.Issue, "not answer as an MCP server") {
		t.Errorf("a web page = %+v", st)
	}
	if st := probeMCP(ctx, MCPServer{URL: "http://127.0.0.1:1/mcp"}); st.State != "failed" || st.Issue == "" {
		t.Errorf("nothing listening = %+v", st)
	}
}

// GET /v1/mcp?status=1: Claude Code's own list for Claude, the CLI's list
// and pierd's handshake for Codex, and a name the person uses by hand said
// so.
func TestMCPStatusPerAgent(t *testing.T) {
	home, _ := mcpTestHome(t)
	srv, _ := mcpServerStub(t, "good")
	c, _ := servedBox(t, func(b *Box) { b.StateDir = t.TempDir() })
	os.WriteFile(filepath.Join(home, ".claude.json"), []byte(`{"mcpServers":{"docs":{"type":"stdio","command":"their-docs"}}}`), 0o600)
	call(t, c, "PUT", "/v1/mcp/crm", "", map[string]any{"url": srv.URL + "/mcp", "token": "good"}, nil)
	call(t, c, "PUT", "/v1/mcp/docs", "", map[string]any{"transport": "stdio", "command": "docs-mcp"}, nil)
	call(t, c, "PUT", "/v1/mcp/off", "", map[string]any{"url": srv.URL, "enabled": false, "agents": []string{"codex"}}, nil)

	status := func() map[string]map[string]MCPAgentStatus {
		var list struct{ Servers []MCPServerView }
		if code := call(t, c, "GET", "/v1/mcp?status=1", "", nil, &list); code != 200 {
			t.Fatalf("status = %d", code)
		}
		out := map[string]map[string]MCPAgentStatus{}
		for _, s := range list.Servers {
			out[s.Name] = s.Status
		}
		return out
	}
	got := status()
	if st := got["crm"]["claude"]; st.State != "connected" || st.Account != "Claude Code" {
		t.Errorf("crm for claude = %+v", st)
	}
	if st := got["crm"]["codex"]; st.State != "connected" || st.Account != "Codex" {
		t.Errorf("crm for codex = %+v", st)
	}
	if st := got["docs"]["claude"]; st.State != "taken" {
		t.Errorf("the person's docs for claude = %+v", st)
	}
	if st := got["docs"]["codex"]; st.State != "configured" {
		t.Errorf("docs for codex = %+v", st)
	}
	if st := got["off"]; len(st) != 1 || st["codex"].State != "disabled" {
		t.Errorf("off = %+v", st)
	}

	// A token the server refuses shows for Codex.
	call(t, c, "PUT", "/v1/mcp/crm", "", map[string]any{"url": srv.URL + "/mcp", "token": "stale"}, nil)
	if st := status()["crm"]["codex"]; st.State != "needs_auth" {
		t.Errorf("a refused token for codex = %+v", st)
	}
}
