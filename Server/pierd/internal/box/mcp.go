package box

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/agentpath"
	"pier/pierd/internal/groups"
	"pier/pierd/internal/integrations"
	"pier/pierd/internal/statefile"
	"pier/pierd/internal/version"
)

// MCP servers for the box's agents: a server added once in the app (a
// company's API behind a URL and a token, say) reaches every Claude Code
// and Codex account on the box. pierd keeps the list in its own folder
// (mcp.json, mode 0600: the tokens are in it) and writes each server into
// the agents' configuration through their own CLIs (`claude mcp add
// --scope user`, `codex mcp add`), which keep those files whole while the
// agents run.
//
// pierd records each entry it writes (mcp-written.json) the moment the CLI
// is done, and only ever removes or rewrites an entry that is still as it
// wrote it: a server the person added by hand, even one of the same name,
// and an entry of pierd's they changed by hand, are left as they are. An
// entry exactly as pierd would write it is pierd's even when the record
// lacks it (pierd stopped between the write and the record).
//
// Claude Code keeps the token in the Authorization header of its entry, as
// its CLI stores one. Codex reads it from a variable its entry names
// (bearer_token_env_var), which every session pierd starts gets, so the
// token is never written into Codex's configuration.

// MCPServer is one server in the box's list.
type MCPServer struct {
	Name string `json:"name"`
	// Transport is "http" (a streamable HTTP endpoint) or "stdio" (a
	// command the agent starts).
	Transport string            `json:"transport"`
	URL       string            `json:"url,omitempty"`
	Command   string            `json:"command,omitempty"`
	Args      []string          `json:"args,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
	// Token goes out as "Authorization: Bearer <token>" (http only).
	Token   string            `json:"token,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	Agents  []string          `json:"agents"`
	Enabled bool              `json:"enabled"`
}

type mcpFile struct {
	Servers []MCPServer `json:"servers"`
}

// MCPServerView is a server as GET /v1/mcp shows it: never its token, only
// whether it has one.
type MCPServerView struct {
	Name      string            `json:"name"`
	Transport string            `json:"transport"`
	URL       string            `json:"url,omitempty"`
	Command   string            `json:"command,omitempty"`
	Args      []string          `json:"args,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
	TokenSet  bool              `json:"token_set"`
	// TokenVar is the variable Codex reads the token from.
	TokenVar string            `json:"token_var,omitempty"`
	Env      map[string]string `json:"env,omitempty"`
	Agents   []string          `json:"agents"`
	Enabled  bool              `json:"enabled"`
	// Problems are what the last sync could not do for this server.
	Problems []string `json:"problems,omitempty"`
	// Status, by agent, when asked for (?status=1 or deep).
	Status map[string]MCPAgentStatus `json:"status,omitempty"`
}

// MCPAgentStatus is how one agent's default account sees a server: State is
// connected, failed, needs_auth, configured (a stdio server, which only the
// deep check starts), disabled, missing (not in the account's
// configuration), taken (a server of that name pierd did not add), changed
// (pierd's entry, changed by hand since), unavailable (the agent's CLI is
// not on the box), pending or unknown.
type MCPAgentStatus struct {
	State   string `json:"state"`
	Issue   string `json:"issue,omitempty"`
	Account string `json:"account,omitempty"`
}

// mcpState is the sync's: one at a time, and what the last one could not do.
type mcpState struct {
	mu       sync.Mutex
	pmu      sync.Mutex
	problems map[string][]string
	bg       sync.WaitGroup
}

var (
	mcpName       = regexp.MustCompile(`^[a-z0-9_-]{1,40}$`)
	mcpHeaderName = regexp.MustCompile("^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}$")
	mcpAgents     = []string{"claude", "codex"}
)

const (
	maxMCPServers = 50
	// maxMCPBody fits a server at the limits below: 20 headers and a token
	// of 8 KB each, or 50 arguments and variables of a stdio server.
	maxMCPBody = 1 << 20
	// mcpCLITimeout bounds one add or remove; mcpListTimeout a list (Claude
	// Code's connects to every server the account has).
	mcpCLITimeout  = 30 * time.Second
	mcpListTimeout = 20 * time.Second
	// mcpSyncTimeout bounds a whole sync once the request that asked for it
	// is answered or gone: a sync the app gave up on still finishes.
	mcpSyncTimeout = 3 * time.Minute
)

// mcpTokenVar is the variable a server's token reaches Codex in:
// PIER_MCP_<NAME>_TOKEN, the name upper-cased with - as _.
func mcpTokenVar(name string) string {
	return "PIER_MCP_" + strings.ToUpper(strings.ReplaceAll(name, "-", "_")) + "_TOKEN"
}

func (s MCPServer) wants(agent string) bool { return s.Enabled && slices.Contains(s.Agents, agent) }

func (s MCPServer) view() MCPServerView {
	v := MCPServerView{Name: s.Name, Transport: s.Transport, URL: s.URL, Command: s.Command, Args: s.Args, Headers: s.Headers,
		TokenSet: s.Token != "", Env: s.Env, Agents: s.Agents, Enabled: s.Enabled}
	if s.Transport == "http" {
		v.TokenVar = mcpTokenVar(s.Name)
	}
	if v.Agents == nil {
		v.Agents = []string{}
	}
	return v
}

// mcpSecrets are what must never reach a problem or an answer: the tokens,
// and the values of stdio servers' variables.
func mcpSecrets(servers []MCPServer) []string {
	var out []string
	for _, s := range servers {
		out = append(out, s.Token)
		for _, v := range s.Env {
			out = append(out, v)
		}
	}
	return out
}

// redact takes the secrets out of a CLI's words (one that echoes its
// arguments back when it refuses them).
func redact(msg string, secrets []string) string {
	for _, s := range secrets {
		if len(s) >= 3 {
			msg = strings.ReplaceAll(msg, s, "[redacted]")
		}
	}
	return msg
}

// --- the list ---

func (b *Box) mcpPath() string {
	if b.StateDir == "" {
		return ""
	}
	return filepath.Join(b.StateDir, "mcp.json")
}

func (b *Box) mcpWrittenPath() string { return filepath.Join(b.StateDir, "mcp-written.json") }

func (b *Box) loadMCP() (mcpFile, error) {
	var f mcpFile
	path := b.mcpPath()
	if path == "" {
		return f, nil
	}
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return f, nil
	}
	if err != nil {
		return f, err
	}
	if err := json.Unmarshal(data, &f); err != nil {
		return f, fmt.Errorf("%s: %w", path, err)
	}
	return f, nil
}

func (b *Box) saveMCP(f mcpFile) error {
	sort.Slice(f.Servers, func(i, j int) bool { return f.Servers[i].Name < f.Servers[j].Name })
	if f.Servers == nil {
		f.Servers = []MCPServer{}
	}
	data, _ := json.MarshalIndent(f, "", "  ")
	return statefile.Write(b.mcpPath(), append(data, '\n'))
}

// mcpWritten is what pierd wrote into each account's configuration: by
// account ("claude:" + its folder), each server's name and the fingerprint
// of the entry as written.
type mcpWritten map[string]map[string]string

// loadMCPWritten reads the record. One that cannot be read is set aside
// (mcp-written.json.bad) and said in the log: the entries pierd wrote are
// then recognised by their content again.
func (b *Box) loadMCPWritten() mcpWritten {
	w := mcpWritten{}
	data, err := os.ReadFile(b.mcpWrittenPath())
	if err != nil {
		if !os.IsNotExist(err) {
			b.logf("mcp: cannot read %s: %v", b.mcpWrittenPath(), err)
		}
		return w
	}
	if err := json.Unmarshal(data, &w); err != nil {
		b.logf("mcp: %s is not a record pierd can read (%v); kept as %s.bad, its entries are recognised by their content", b.mcpWrittenPath(), err, b.mcpWrittenPath())
		os.Rename(b.mcpWrittenPath(), b.mcpWrittenPath()+".bad")
		return mcpWritten{}
	}
	return w
}

func (b *Box) saveMCPWritten(w mcpWritten) {
	data, _ := json.MarshalIndent(w, "", "  ")
	if err := statefile.Write(b.mcpWrittenPath(), append(data, '\n')); err != nil {
		b.logf("mcp: cannot record what pierd wrote: %v", err)
	}
}

// mcpHasWork says whether a sync has anything to do: servers in the list,
// or entries pierd wrote that may have to go.
func (b *Box) mcpHasWork() bool {
	if b.mcpPath() == "" {
		return false
	}
	f, _ := b.loadMCP()
	if len(f.Servers) > 0 {
		return true
	}
	_, err := os.Stat(b.mcpWrittenPath())
	return err == nil
}

// mcpSessionEnv is what a session needs for the box's MCP servers: the
// token of each server Codex uses, in the variable its entry names.
func (b *Box) mcpSessionEnv() []string {
	f, err := b.loadMCP()
	if err != nil {
		return nil
	}
	var env []string
	for _, s := range f.Servers {
		if s.Transport == "http" && s.Token != "" && s.wants("codex") {
			env = append(env, mcpTokenVar(s.Name)+"="+s.Token)
		}
	}
	return env
}

// --- checking a server ---

// mcpRequest is the body of PUT /v1/mcp/{name}: the server as it should be.
// Token left out keeps the one the box has; "" removes it.
type mcpRequest struct {
	Transport string            `json:"transport"`
	URL       string            `json:"url"`
	Command   string            `json:"command"`
	Args      []string          `json:"args"`
	Headers   map[string]string `json:"headers"`
	Token     *string           `json:"token"`
	Env       map[string]string `json:"env"`
	Agents    []string          `json:"agents"`
	Enabled   *bool             `json:"enabled"`
}

func (req mcpRequest) server(name string) MCPServer {
	s := MCPServer{Name: name, Transport: strings.ToLower(strings.TrimSpace(req.Transport)), URL: strings.TrimSpace(req.URL),
		Command: strings.TrimSpace(req.Command), Args: req.Args, Env: req.Env, Enabled: req.Enabled == nil || *req.Enabled}
	if s.Transport == "" {
		s.Transport = "http"
		if s.URL == "" && s.Command != "" {
			s.Transport = "stdio"
		}
	}
	if req.Token != nil {
		s.Token = strings.TrimSpace(*req.Token)
	}
	if len(req.Headers) > 0 {
		s.Headers = map[string]string{}
		for k, v := range req.Headers {
			s.Headers[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	// Both agents unless the request names them; always in the same order.
	agents := req.Agents
	if agents == nil {
		agents = mcpAgents
	}
	s.Agents = []string{}
	for _, a := range mcpAgents {
		if slices.Contains(agents, a) {
			s.Agents = append(s.Agents, a)
		}
	}
	if len(s.Args) == 0 {
		s.Args = nil
	}
	if len(s.Env) == 0 {
		s.Env = nil
	}
	return s
}

// printableASCII says s is visible ASCII (and spaces, when allowed): what
// every agent's HTTP stack sends as a header as it is.
func printableASCII(s string, spaces bool) bool {
	for i := 0; i < len(s); i++ {
		if c := s[i]; (c < 0x21 || c > 0x7e) && !(spaces && c == ' ') {
			return false
		}
	}
	return true
}

// check refuses what the agents could not use, or what would carry a secret
// somewhere it shows.
func (s MCPServer) check(agents []string) error {
	for _, a := range agents {
		if !slices.Contains(mcpAgents, a) {
			return badRequest("unknown agent %q: claude or codex", a)
		}
	}
	if len(s.Agents) == 0 {
		return badRequest("pick at least one agent for %s", s.Name)
	}
	if !printableASCII(s.Token, false) || len(s.Token) > 8<<10 {
		return badRequest("the token is printable ASCII without spaces, up to 8 KB")
	}
	switch s.Transport {
	case "http":
		u, err := url.Parse(s.URL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || len(s.URL) > 2048 {
			return badRequest("an http server needs its URL (http:// or https://)")
		}
		if s.Command != "" || len(s.Args) > 0 || len(s.Env) > 0 {
			return badRequest("an http server takes a url, not a command")
		}
		if len(s.Headers) > 20 {
			return badRequest("at most 20 headers")
		}
		for k, v := range s.Headers {
			if !mcpHeaderName.MatchString(k) {
				return badRequest("%q cannot be a header name", k)
			}
			if strings.EqualFold(k, "Authorization") {
				return badRequest("put the token in token: pierd sends it as Authorization: Bearer")
			}
			if !printableASCII(v, true) || len(v) > 8<<10 {
				return badRequest("the value of %s is printable ASCII on one line, up to 8 KB", k)
			}
		}
	case "stdio":
		if s.Command == "" || strings.ContainsRune(s.Command, 0) || len(s.Command) > 4<<10 {
			return badRequest("a stdio server needs its command")
		}
		if s.URL != "" || len(s.Headers) > 0 {
			return badRequest("a stdio server takes a command, not a url or headers")
		}
		if s.Token != "" {
			return badRequest("a stdio server takes its secrets in env, not a token")
		}
		if len(s.Args) > 50 || len(s.Env) > 50 {
			return badRequest("at most 50 arguments and 50 variables")
		}
		for _, a := range s.Args {
			if strings.ContainsRune(a, 0) || len(a) > 4<<10 {
				return badRequest("an argument is too long")
			}
		}
		for k, v := range s.Env {
			if !envVarName.MatchString(k) {
				return badRequest("%q cannot be a variable name", k)
			}
			if strings.ContainsRune(v, 0) || len(v) > 8<<10 {
				return badRequest("%s is too long", k)
			}
		}
	default:
		return badRequest("transport is http or stdio")
	}
	return nil
}

// --- routes ---

// getMCP answers the box's servers. ?status=1 adds how each agent's default
// account sees them: whether its configuration has pierd's entry, and
// pierd's own handshake with each http server, with what that agent sends.
// ?status=deep asks Claude Code's own list instead, which starts every
// server the account has, so it is only for an explicit check.
func (b *Box) getMCP(w http.ResponseWriter, r *http.Request) error {
	f, err := b.loadMCP()
	if err != nil {
		return err
	}
	views := b.mcpViews(f)
	if q := r.URL.Query().Get("status"); q == "1" || q == "deep" {
		status := b.mcpStatus(r.Context(), f.Servers, q == "deep")
		for i := range views {
			views[i].Status = status[views[i].Name]
		}
	}
	writeJSON(w, map[string]any{"servers": views})
	return nil
}

func (b *Box) mcpViews(f mcpFile) []MCPServerView {
	b.mcp.pmu.Lock()
	problems := b.mcp.problems
	b.mcp.pmu.Unlock()
	views := []MCPServerView{}
	for _, s := range f.Servers {
		v := s.view()
		v.Problems = problems[s.Name]
		views = append(views, v)
	}
	return views
}

// putMCP adds a server or replaces one, then writes it into every account.
func (b *Box) putMCP(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	if !mcpName.MatchString(name) {
		return badRequest("a server's name is 1 to 40 of a-z, 0-9, - and _")
	}
	var req mcpRequest
	if err := decodeLimit(r, &req, maxMCPBody); err != nil {
		return err
	}
	if b.mcpPath() == "" {
		return httpError{http.StatusNotImplemented, "this box keeps no state folder"}
	}
	s := req.server(name)
	if err := s.check(req.Agents); err != nil {
		return err
	}
	if err := b.before(r, "mcp.change", map[string]any{"name": name, "enabled": s.Enabled, "agents": s.Agents}); err != nil {
		return err
	}
	b.mcp.mu.Lock()
	f, err := b.loadMCP()
	if err != nil {
		b.mcp.mu.Unlock()
		return err
	}
	i := slices.IndexFunc(f.Servers, func(x MCPServer) bool { return x.Name == name })
	if i >= 0 && req.Token == nil && s.Transport == "http" {
		s.Token = f.Servers[i].Token
	}
	for _, o := range f.Servers {
		if err == nil && o.Name != name && mcpTokenVar(o.Name) == mcpTokenVar(name) {
			err = badRequest("%s and %s would share the variable %s: pick another name", name, o.Name, mcpTokenVar(name))
		}
	}
	if err == nil && i < 0 && len(f.Servers) >= maxMCPServers {
		err = badRequest("a box keeps at most %d MCP servers", maxMCPServers)
	}
	if err != nil {
		b.mcp.mu.Unlock()
		return err
	}
	if i >= 0 {
		f.Servers[i] = s
	} else {
		f.Servers = append(f.Servers, s)
	}
	if err := b.saveMCP(f); err != nil {
		b.mcp.mu.Unlock()
		return err
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), mcpSyncTimeout)
	b.syncMCPLocked(ctx)
	cancel()
	// The answer is this server as saved, with what the sync could not do
	// for it, whatever another request does once the lock is let go.
	v := s.view()
	b.mcp.pmu.Lock()
	v.Problems = b.mcp.problems[name]
	b.mcp.pmu.Unlock()
	b.mcp.mu.Unlock()
	b.publish(r, "mcp.changed", map[string]any{"names": []string{name}})
	writeJSON(w, v)
	return nil
}

// deleteMCP takes a server off the list and out of every account pierd put
// it in.
func (b *Box) deleteMCP(w http.ResponseWriter, r *http.Request) error {
	name := r.PathValue("name")
	if b.mcpPath() == "" {
		return httpError{http.StatusNotImplemented, "this box keeps no state folder"}
	}
	has := func(f mcpFile) int {
		return slices.IndexFunc(f.Servers, func(x MCPServer) bool { return x.Name == name })
	}
	if f, err := b.loadMCP(); err != nil {
		return err
	} else if has(f) < 0 {
		return httpError{http.StatusNotFound, "no MCP server named " + name}
	}
	if err := b.before(r, "mcp.change", map[string]any{"name": name, "removed": true}); err != nil {
		return err
	}
	b.mcp.mu.Lock()
	f, err := b.loadMCP()
	if err != nil {
		b.mcp.mu.Unlock()
		return err
	}
	i := has(f)
	if i < 0 {
		b.mcp.mu.Unlock()
		return httpError{http.StatusNotFound, "no MCP server named " + name}
	}
	f.Servers = slices.Delete(f.Servers, i, i+1)
	if err := b.saveMCP(f); err != nil {
		b.mcp.mu.Unlock()
		return err
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), mcpSyncTimeout)
	b.syncMCPLocked(ctx)
	cancel()
	b.mcp.mu.Unlock()
	b.publish(r, "mcp.changed", map[string]any{"names": []string{name}, "removed": true})
	writeJSON(w, map[string]string{"removed": name})
	return nil
}

// --- writing servers into the accounts ---

// SyncMCP brings every account's servers in line with the box's list once
// pierd starts: an account added while it was down, a server removed by
// hand that should be there.
func (b *Box) SyncMCP() {
	if !b.mcpHasWork() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), mcpSyncTimeout)
	defer cancel()
	b.mcp.mu.Lock()
	defer b.mcp.mu.Unlock()
	b.syncMCPLocked(ctx)
}

// syncMCPSoon syncs in the background (a new account's folder), when there
// is anything to sync.
func (b *Box) syncMCPSoon() {
	if !b.mcpHasWork() {
		return
	}
	b.mcp.bg.Add(1)
	go func() {
		defer b.mcp.bg.Done()
		b.SyncMCP()
	}()
}

// WaitMCP lets a sync that is writing into the accounts finish before pierd
// stops, for at most max: an entry is recorded the moment its CLI is done,
// so stopping in between only costs a CLI call the next sync repeats.
func (b *Box) WaitMCP(max time.Duration) {
	done := make(chan struct{})
	go func() {
		b.mcp.bg.Wait()
		b.mcp.mu.Lock()
		b.mcp.mu.Unlock()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(max):
	}
}

// syncMCPLocked writes the list into every account and takes out what pierd
// wrote that should no longer be there. The caller holds b.mcp.mu.
func (b *Box) syncMCPLocked(ctx context.Context) {
	f, err := b.loadMCP()
	if err != nil {
		b.logf("mcp: %v", err)
		return
	}
	written := b.loadMCPWritten()
	secrets := mcpSecrets(f.Servers)
	problems := map[string][]string{}
	keep := map[string]bool{}
	for _, a := range b.Accounts() {
		if agentDirVar[a.Agent] == "" {
			continue
		}
		key := a.Agent + ":" + a.Dir
		keep[key] = true
		if !a.Builtin {
			if _, err := os.Stat(a.Dir); err != nil {
				continue
			}
		}
		wanted := false
		for _, s := range f.Servers {
			wanted = wanted || s.wants(a.Agent)
		}
		if !wanted && len(written[key]) == 0 {
			continue
		}
		cli, ok := agentFound(a.Agent)
		if !ok {
			// Nothing to write into without the CLI; GET ?status=1 says so.
			continue
		}
		label := mcpAccountLabel(a)
		note := func(name, format string, args ...any) {
			problems[name] = append(problems[name], label+": "+redact(fmt.Sprintf(format, args...), secrets))
		}
		// Each write is recorded the moment the CLI is done with it.
		commit := func(name, fp string) {
			m := written[key]
			if fp == "" {
				delete(m, name)
				if len(m) == 0 {
					delete(written, key)
				}
			} else {
				if m == nil {
					m = map[string]string{}
					written[key] = m
				}
				m[name] = fp
			}
			b.saveMCPWritten(written)
		}
		owned := func(name string) (string, bool) {
			fp, ok := written[key][name]
			return fp, ok
		}
		b.syncAccountMCP(ctx, a, cli, f.Servers, maps.Clone(written[key]), owned, commit, note)
	}
	// An account that is gone took its configuration with it.
	changed := false
	for key := range written {
		if !keep[key] {
			delete(written, key)
			changed = true
		}
	}
	if changed {
		b.saveMCPWritten(written)
	}
	b.mcp.pmu.Lock()
	b.mcp.problems = problems
	b.mcp.pmu.Unlock()
}

// syncAccountMCP brings one account in line: mine is what pierd had written
// there when it began, owned what it has now. An entry is only removed or
// rewritten while it is as pierd wrote it; an entry exactly as pierd would
// write it is taken for pierd's.
func (b *Box) syncAccountMCP(ctx context.Context, a Account, cli agentpath.Found, servers []MCPServer, mine map[string]string,
	owned func(string) (string, bool), commit func(name, fp string), note func(name, format string, args ...any)) {
	live, err := b.mcpLive(ctx, a, cli)
	if err != nil {
		for _, s := range servers {
			if s.wants(a.Agent) {
				note(s.Name, "could not read its servers: %v", err)
			}
		}
		return
	}
	byName := map[string]MCPServer{}
	for _, s := range servers {
		byName[s.Name] = s
	}
	// What pierd wrote and should no longer be there goes first: servers off
	// the list, turned off, or no longer for this agent.
	var gone []string
	for n := range mine {
		if s, listed := byName[n]; !listed || !s.wants(a.Agent) {
			gone = append(gone, n)
		}
	}
	sort.Strings(gone)
	for _, n := range gone {
		fp, _ := owned(n)
		liveFP, there := live[n]
		switch {
		case !there:
			commit(n, "")
		case liveFP != fp:
			// Changed by hand since pierd wrote it: the person's now.
			commit(n, "")
			note(n, "%s was changed by hand since pierd wrote it; it is left as it is", n)
		default:
			if err := b.mcpRemove(ctx, a, cli, n); err != nil {
				note(n, "could not remove it: %v", err)
				continue
			}
			commit(n, "")
		}
	}
	for _, s := range servers {
		if !s.wants(a.Agent) {
			continue
		}
		fp := mcpFingerprint(s, a.Agent)
		liveFP, there := live[s.Name]
		old, mine := owned(s.Name)
		switch {
		case there && liveFP == fp:
			// Already as it should be: pierd's, recorded or not.
			if !mine || old != fp {
				commit(s.Name, fp)
			}
			continue
		case there && !mine:
			note(s.Name, "already has a server named %s that pierd did not add; it is left as it is", s.Name)
			continue
		case there && liveFP != old:
			commit(s.Name, "")
			note(s.Name, "%s was changed by hand since pierd wrote it; it is left as it is", s.Name)
			continue
		}
		// Not there, or pierd's entry as pierd wrote it: (re)write it.
		// Claude Code's add refuses a name it has; Codex's replaces it.
		if there && a.Agent == "claude" {
			if err := b.mcpRemove(ctx, a, cli, s.Name); err != nil {
				note(s.Name, "could not update it: %v", err)
				continue
			}
			commit(s.Name, "")
		}
		if err := b.mcpAdd(ctx, a, cli, s); err != nil {
			// Codex writes the entry, then may wait for a sign-in nobody can
			// give it here (a server that offers OAuth): the entry is there,
			// and pierd's.
			if a.Agent == "codex" {
				if again, lerr := b.mcpLive(ctx, a, cli); lerr == nil && again[s.Name] == fp {
					commit(s.Name, fp)
					note(s.Name, "Codex has it, and wants a sign-in for it too (codex mcp login %s on the box): %v", s.Name, err)
					continue
				}
			}
			note(s.Name, "could not add it: %v", err)
			continue
		}
		commit(s.Name, fp)
	}
}

// mcpAccountLabel names an account in a problem: the agent, and the
// account's name when it is an added one.
func mcpAccountLabel(a Account) string {
	agent := "Claude Code"
	if a.Agent == "codex" {
		agent = "Codex"
	}
	if a.Builtin {
		return agent
	}
	return agent + " (" + a.Name + ")"
}

// mcpFingerprint is what an agent's entry holds of a server: Claude Code's
// holds the token itself, Codex's only the variable's name and no headers.
// It tells an entry as pierd writes it from any other.
func mcpFingerprint(s MCPServer, agent string) string {
	v := struct {
		T, U, C string
		A       []string
		H, E    map[string]string
		Tok     string
		HasTok  bool
	}{s.Transport, s.URL, s.Command, s.Args, s.Headers, s.Env, "", s.Token != ""}
	if len(v.A) == 0 {
		v.A = nil
	}
	if len(v.H) == 0 {
		v.H = nil
	}
	if len(v.E) == 0 {
		v.E = nil
	}
	if agent == "claude" {
		v.Tok = s.Token
	} else {
		v.H = nil // Codex's CLI takes no headers
	}
	data, _ := json.Marshal(v)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:12])
}

// claudeEntryFingerprint is the fingerprint of an entry of Claude Code's
// configuration, read as pierd writes one ("" for any other shape).
func claudeEntryFingerprint(raw json.RawMessage) string {
	var e struct {
		Type    string            `json:"type"`
		URL     string            `json:"url"`
		Headers map[string]string `json:"headers"`
		Command string            `json:"command"`
		Args    []string          `json:"args"`
		Env     map[string]string `json:"env"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return ""
	}
	s := MCPServer{}
	switch {
	case e.Type == "http" && e.Command == "":
		s.Transport, s.URL = "http", e.URL
		for k, v := range e.Headers {
			if strings.EqualFold(k, "Authorization") {
				tok, ok := strings.CutPrefix(v, "Bearer ")
				if !ok || k != "Authorization" {
					return ""
				}
				s.Token = tok
				continue
			}
			if s.Headers == nil {
				s.Headers = map[string]string{}
			}
			s.Headers[k] = v
		}
	case (e.Type == "stdio" || e.Type == "") && e.Command != "" && e.URL == "":
		s.Transport, s.Command, s.Args, s.Env = "stdio", e.Command, e.Args, e.Env
	default:
		return ""
	}
	return mcpFingerprint(s, "claude")
}

// codexEntryFingerprint is the fingerprint of an entry of Codex's list,
// read as pierd writes one ("" for any other shape: another token variable,
// headers, an entry turned off).
func codexEntryFingerprint(name string, e codexMCPEntry) string {
	if !e.Enabled || len(e.Transport.HTTPHeaders) > 0 || len(e.Transport.EnvHTTPHeaders) > 0 {
		return ""
	}
	s := MCPServer{}
	switch e.Transport.Type {
	case "streamable_http":
		s.Transport, s.URL = "http", e.Transport.URL
		if v := e.Transport.BearerTokenEnvVar; v != nil {
			if *v != mcpTokenVar(name) {
				return ""
			}
			// Codex's entry holds the variable's name, never the token.
			s.Token = "set"
		}
	case "stdio":
		s.Transport, s.Command, s.Args, s.Env = "stdio", e.Transport.Command, e.Transport.Args, e.Transport.Env
	default:
		return ""
	}
	return mcpFingerprint(s, "codex")
}

// mcpAdd writes one server into an account through the agent's CLI.
func (b *Box) mcpAdd(ctx context.Context, a Account, cli agentpath.Found, s MCPServer) error {
	var args []string
	switch a.Agent {
	case "claude":
		args = []string{"mcp", "add", "--scope", "user"}
		if s.Transport == "http" {
			args = append(args, "--transport", "http")
			if s.Token != "" {
				args = append(args, "-H", "Authorization: Bearer "+s.Token)
			}
			for _, k := range sortedKeys(s.Headers) {
				args = append(args, "-H", k+": "+s.Headers[k])
			}
			// The options end before the name: -H takes every value up to
			// the next option.
			args = append(args, "--", s.Name, s.URL)
		} else {
			for _, k := range sortedKeys(s.Env) {
				args = append(args, "-e", k+"="+s.Env[k])
			}
			args = append(append(args, "--", s.Name, s.Command), s.Args...)
		}
	case "codex":
		args = []string{"mcp", "add", s.Name}
		if s.Transport == "http" {
			args = append(args, "--url", s.URL)
			if s.Token != "" {
				args = append(args, "--bearer-token-env-var", mcpTokenVar(s.Name))
			}
		} else {
			for _, k := range sortedKeys(s.Env) {
				args = append(args, "--env", k+"="+s.Env[k])
			}
			args = append(append(args, "--", s.Command), s.Args...)
		}
	}
	_, err := b.mcpCLI(ctx, a, cli, mcpCLITimeout, args...)
	return err
}

func (b *Box) mcpRemove(ctx context.Context, a Account, cli agentpath.Found, name string) error {
	args := []string{"mcp", "remove", name}
	if a.Agent == "claude" {
		args = []string{"mcp", "remove", "--scope", "user", name}
	}
	_, err := b.mcpCLI(ctx, a, cli, mcpCLITimeout, args...)
	return err
}

// mcpLive is an account's own list as it is now: each name, and the
// fingerprint its entry would have had pierd written it ("" for an entry
// pierd never writes in that shape). Claude Code's user scope is read from
// its .claude.json (read, never written; reading starts no server), Codex's
// from its CLI's list.
func (b *Box) mcpLive(ctx context.Context, a Account, cli agentpath.Found) (map[string]string, error) {
	out := map[string]string{}
	switch a.Agent {
	case "claude":
		data, err := os.ReadFile(claudeGlobalConfig(a))
		if os.IsNotExist(err) {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		var cfg struct {
			MCPServers map[string]json.RawMessage `json:"mcpServers"`
		}
		if err := json.Unmarshal(data, &cfg); err != nil {
			return nil, err
		}
		for n, raw := range cfg.MCPServers {
			out[n] = claudeEntryFingerprint(raw)
		}
	case "codex":
		raw, err := b.mcpCLI(ctx, a, cli, mcpListTimeout, "mcp", "list", "--json")
		if err != nil {
			return nil, err
		}
		list, err := parseCodexMCPList(raw)
		if err != nil {
			return nil, err
		}
		for n, e := range list {
			out[n] = codexEntryFingerprint(n, e)
		}
	}
	return out, nil
}

// claudeGlobalConfig is the file Claude Code keeps an account's user-scope
// servers in: .claude.json in the folder CLAUDE_CONFIG_DIR names, or in the
// home folder for the built-in account (not inside ~/.claude).
func claudeGlobalConfig(a Account) string {
	if a.Builtin && os.Getenv("CLAUDE_CONFIG_DIR") == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".claude.json")
	}
	return filepath.Join(a.Dir, ".claude.json")
}

// mcpCLI runs an agent's CLI on one account: its folder for an added
// account (CLAUDE_CONFIG_DIR, CODEX_HOME), the agent's own for the built-in
// one; with the PATH the CLI was found with, never with pierd's PIER_*
// variables, its hooks quiet, from pierd's own folder (no project's
// .mcp.json there). A command that outlives its time is stopped with
// everything it started (servers a list connects to). Its output comes
// back even when it fails.
func (b *Box) mcpCLI(ctx context.Context, a Account, cli agentpath.Found, timeout time.Duration, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := groups.CommandContext(ctx, cli.Path, args...)
	cmd.Env = mcpCLIEnv(a, cli)
	cmd.Dir = b.StateDir
	if cmd.Dir == "" {
		cmd.Dir = os.TempDir()
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &limitedBuffer{buf: &stdout, max: 1 << 20}
	cmd.Stderr = &limitedBuffer{buf: &stderr, max: 64 << 10}
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return stdout.Bytes(), fmt.Errorf("%s %s did not finish within %s", a.Agent, strings.Join(args[:2], " "), timeout)
	}
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		if line, _, _ := strings.Cut(msg, "\n"); line != "" {
			return stdout.Bytes(), errors.New(line)
		}
		return stdout.Bytes(), err
	}
	return stdout.Bytes(), nil
}

// mcpCLIEnv is the environment of an agent CLI pierd runs for an account.
func mcpCLIEnv(a Account, cli agentpath.Found) []string {
	dirVar := agentDirVar[a.Agent]
	var env []string
	for _, kv := range os.Environ() {
		k, v, _ := strings.Cut(kv, "=")
		switch {
		case strings.HasPrefix(k, "PIER_"), k == "PATH":
			continue
		case k == dirVar && (!a.Builtin || v == ""):
			continue
		}
		env = append(env, kv)
	}
	if !a.Builtin {
		env = append(env, dirVar+"="+a.Dir)
	}
	path := cli.PATH
	if path == "" {
		path = os.Getenv("PATH")
	}
	// MCP_TIMEOUT keeps Claude Code's wait for each server of a list under
	// pierd's own for the whole list.
	return append(env, "PATH="+path, integrations.QuietEnv+"=1", "NO_COLOR=1", "MCP_TIMEOUT=15000")
}

// limitedBuffer keeps the first max bytes of a command's output and drops
// the rest, so a chatty CLI cannot grow pierd.
type limitedBuffer struct {
	buf *bytes.Buffer
	max int
}

func (l *limitedBuffer) Write(p []byte) (int, error) {
	if room := l.max - l.buf.Len(); room > 0 {
		l.buf.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// --- how the agents see the servers ---

// mcpStatus asks each agent's default account how it sees the servers:
// whether its configuration has pierd's entry, and pierd's own handshake
// with each http server, sending what that agent sends (Claude Code the
// token and the headers, Codex the token). Nothing of the account's starts.
// deep asks Claude Code's own list instead, which starts every server the
// account has.
func (b *Box) mcpStatus(ctx context.Context, servers []MCPServer, deep bool) map[string]map[string]MCPAgentStatus {
	out := map[string]map[string]MCPAgentStatus{}
	set := func(name, agent string, st MCPAgentStatus) {
		if out[name] == nil {
			out[name] = map[string]MCPAgentStatus{}
		}
		out[name][agent] = st
	}
	secrets := mcpSecrets(servers)
	written := b.loadMCPWritten()
	var mu sync.Mutex
	var wg sync.WaitGroup
	probes := map[string]MCPAgentStatus{} // "agent/name"
	for _, s := range servers {
		if s.Transport != "http" {
			continue
		}
		for _, agent := range mcpAgents {
			if !s.wants(agent) || agent == "claude" && deep {
				continue
			}
			wg.Add(1)
			go func(s MCPServer, agent string) {
				defer wg.Done()
				st := probeMCP(ctx, s, agent == "claude")
				mu.Lock()
				probes[agent+"/"+s.Name] = st
				mu.Unlock()
			}(s, agent)
		}
	}
	lives := map[string]map[string]string{}
	lists := map[string]map[string]MCPAgentStatus{}
	accounts := map[string]Account{}
	failures := map[string]MCPAgentStatus{}
	for _, agent := range mcpAgents {
		wanted := false
		for _, s := range servers {
			wanted = wanted || s.wants(agent)
		}
		if !wanted {
			continue
		}
		a, _ := b.defaultAccount(agent)
		accounts[agent] = a
		cli, ok := agentFound(agent)
		if !ok {
			mu.Lock()
			failures[agent] = MCPAgentStatus{State: "unavailable", Issue: mcpAccountLabel(Account{Agent: agent, Builtin: true}) + " is not installed on this box"}
			mu.Unlock()
			continue
		}
		wg.Add(1)
		go func(agent string, a Account, cli agentpath.Found) {
			defer wg.Done()
			live, err := b.mcpLive(ctx, a, cli)
			var list map[string]MCPAgentStatus
			if err == nil && agent == "claude" && deep {
				// Its output says what it saw even when it ends badly.
				raw, lerr := b.mcpCLI(ctx, a, cli, mcpListTimeout, "mcp", "list")
				if list = parseClaudeMCPList(string(raw)); len(list) == 0 && lerr != nil {
					err = lerr
				}
			}
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failures[agent] = MCPAgentStatus{State: "unknown", Issue: redact(err.Error(), secrets)}
				return
			}
			lives[agent], lists[agent] = live, list
		}(agent, a, cli)
	}
	wg.Wait()
	for _, s := range servers {
		for _, agent := range s.Agents {
			if !s.Enabled {
				set(s.Name, agent, MCPAgentStatus{State: "disabled"})
				continue
			}
			label := mcpAccountLabel(accounts[agent])
			if f, ok := failures[agent]; ok {
				f.Account = label
				set(s.Name, agent, f)
				continue
			}
			liveFP, present := lives[agent][s.Name]
			ownFP, mine := written[agent+":"+accounts[agent].Dir][s.Name]
			desired := mcpFingerprint(s, agent)
			var st MCPAgentStatus
			switch {
			case !present:
				st = MCPAgentStatus{State: "missing", Issue: "not in this account's configuration yet"}
			case liveFP != desired && !mine:
				st = MCPAgentStatus{State: "taken", Issue: "a server of this name that pierd did not add"}
			case liveFP != desired && liveFP != ownFP:
				st = MCPAgentStatus{State: "changed", Issue: "changed by hand since pierd wrote it"}
			case agent == "claude" && deep:
				var ok bool
				if st, ok = lists[agent][s.Name]; !ok {
					st = MCPAgentStatus{State: "unknown", Issue: "not in claude mcp list"}
				}
			case s.Transport == "http":
				st = probes[agent+"/"+s.Name]
			default:
				st = MCPAgentStatus{State: "configured"}
			}
			st.Account = label
			set(s.Name, agent, st)
		}
	}
	return out
}

// claudeMCPLine is the status at the end of a line of `claude mcp list`
// ("name: url (HTTP) - ✔ Connected", "… - ✘ Failed to connect — why"),
// after the mark Claude Code puts before it.
var claudeMCPLine = regexp.MustCompile(` - \S+ (Connected · tools fetch failed|Connected|Needs authentication|Failed to connect|Connection error|Not configured|Pending approval|Rejected|Disabled)(.*)$`)

// parseClaudeMCPList reads `claude mcp list` (Claude Code 2.1: "name:
// target - mark status[ — issue]", one server a line).
func parseClaudeMCPList(out string) map[string]MCPAgentStatus {
	res := map[string]MCPAgentStatus{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r ")
		name, rest, ok := strings.Cut(line, ": ")
		if !ok || !mcpName.MatchString(name) {
			continue
		}
		m := claudeMCPLine.FindStringSubmatch(rest)
		if m == nil {
			continue
		}
		st := MCPAgentStatus{}
		switch m[1] {
		case "Connected":
			st.State = "connected"
		case "Needs authentication":
			st.State = "needs_auth"
		case "Pending approval":
			st.State = "pending"
		case "Disabled":
			st.State = "disabled"
		default:
			st.State = "failed"
			if m[1] == "Connected · tools fetch failed" {
				st.Issue = "connected, but its tools could not be read"
			}
		}
		if _, issue, ok := strings.Cut(m[2], " — "); ok && strings.TrimSpace(issue) != "" {
			st.Issue = strings.TrimSpace(issue)
		}
		res[name] = st
	}
	return res
}

// codexMCPEntry is one server of `codex mcp list --json`.
type codexMCPEntry struct {
	Name      string `json:"name"`
	Enabled   bool   `json:"enabled"`
	Transport struct {
		Type              string            `json:"type"`
		URL               string            `json:"url"`
		BearerTokenEnvVar *string           `json:"bearer_token_env_var"`
		HTTPHeaders       map[string]string `json:"http_headers"`
		EnvHTTPHeaders    map[string]string `json:"env_http_headers"`
		Command           string            `json:"command"`
		Args              []string          `json:"args"`
		Env               map[string]string `json:"env"`
	} `json:"transport"`
	AuthStatus string `json:"auth_status"`
}

// parseCodexMCPList reads `codex mcp list --json` (Codex 0.160: an array
// of {name, enabled, transport, auth_status}).
func parseCodexMCPList(raw []byte) (map[string]codexMCPEntry, error) {
	if i := bytes.IndexByte(raw, '['); i > 0 {
		raw = raw[i:]
	}
	var list []codexMCPEntry
	if err := json.Unmarshal(bytes.TrimSpace(raw), &list); err != nil {
		return nil, fmt.Errorf("codex mcp list: %w", err)
	}
	out := map[string]codexMCPEntry{}
	for _, e := range list {
		out[e.Name] = e
	}
	return out, nil
}

var mcpHTTP = &http.Client{Timeout: 10 * time.Second}

// probeMCP opens an MCP session with an http server the way an agent does
// first (initialize), with the bearer token and, for Claude Code, the
// extra headers, and closes it again.
func probeMCP(ctx context.Context, s MCPServer, withHeaders bool) MCPAgentStatus {
	body := fmt.Sprintf(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pierd","version":%q}}}`, version.Version)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.URL, strings.NewReader(body))
	if err != nil {
		return MCPAgentStatus{State: "failed", Issue: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	if withHeaders {
		for k, v := range s.Headers {
			req.Header.Set(k, v)
		}
	}
	if s.Token != "" {
		req.Header.Set("Authorization", "Bearer "+s.Token)
	}
	resp, err := mcpHTTP.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return MCPAgentStatus{State: "failed", Issue: redact(err.Error(), []string{s.Token})}
	}
	defer resp.Body.Close()
	if id := resp.Header.Get("Mcp-Session-Id"); id != "" {
		defer closeMCPSession(s, id, withHeaders)
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		if s.Token == "" {
			return MCPAgentStatus{State: "needs_auth", Issue: fmt.Sprintf("the server asks for a token (HTTP %d)", resp.StatusCode)}
		}
		return MCPAgentStatus{State: "needs_auth", Issue: fmt.Sprintf("the server refused the token (HTTP %d)", resp.StatusCode)}
	case resp.StatusCode/100 != 2:
		return MCPAgentStatus{State: "failed", Issue: "HTTP " + resp.Status}
	}
	// The answer is JSON, or an event stream that may stay open: read until
	// the first JSON-RPC message.
	sc := bufio.NewScanner(io.LimitReader(resp.Body, 256<<10))
	sc.Buffer(make([]byte, 64<<10), 256<<10)
	for sc.Scan() {
		line := strings.TrimSpace(strings.TrimPrefix(sc.Text(), "data:"))
		if !strings.Contains(line, `"jsonrpc"`) {
			continue
		}
		var msg struct {
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal([]byte(line), &msg) != nil {
			continue
		}
		if msg.Error != nil {
			return MCPAgentStatus{State: "failed", Issue: redact(msg.Error.Message, []string{s.Token})}
		}
		if msg.Result != nil {
			return MCPAgentStatus{State: "connected"}
		}
	}
	return MCPAgentStatus{State: "failed", Issue: "the server did not answer as an MCP server"}
}

// closeMCPSession ends the session a probe opened, as the protocol asks of a
// client that is done.
func closeMCPSession(s MCPServer, id string, withHeaders bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, s.URL, nil)
	if err != nil {
		return
	}
	req.Header.Set("Mcp-Session-Id", id)
	if withHeaders {
		for k, v := range s.Headers {
			req.Header.Set(k, v)
		}
	}
	if s.Token != "" {
		req.Header.Set("Authorization", "Bearer "+s.Token)
	}
	if resp, err := mcpHTTP.Do(req); err == nil {
		resp.Body.Close()
	}
}
