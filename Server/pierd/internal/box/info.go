package box

import (
	"net/http"
	"os"
	"os/user"
	"runtime"
	"sync"

	"pier/pierd/internal/agentcli"
	"pier/pierd/internal/integrations/adapters"
	"pier/pierd/internal/version"
)

// Info describes the running daemon: GET /v1/info.
type Info struct {
	Name  string `json:"name"`
	OS    string `json:"os"`
	Arch  string `json:"arch"`
	Build string `json:"build"`
	// Version is the release (version.Version), "dev" from a checkout.
	Version string `json:"version"`
	// User and Home are the account pierd runs as.
	User  string   `json:"user,omitempty"`
	Home  string   `json:"home,omitempty"`
	Tools []string `json:"tools"`
	// Agents are the agent presets this box can start.
	Agents []AgentPreset `json:"agents"`
	// AgentPaths say where each built-in agent's CLI was found.
	AgentPaths []AgentPath `json:"agent_paths,omitempty"`
	// Capabilities name the API features this box has (Capabilities).
	Capabilities []string `json:"capabilities"`
	// Adapters say what each agent can report, for the app.
	Adapters map[string]adapters.Caps `json:"adapters,omitempty"`
}

// buildID is a digest of the running binary, computed once: two pierd with
// the same Version but another build ID are different bytes.
var buildID = sync.OnceValue(func() string {
	exe, err := os.Executable()
	if err != nil {
		return "unknown"
	}
	b, err := os.ReadFile(exe)
	if err != nil {
		return "unknown"
	}
	return version.BuildID(b)
})

func (b *Box) handleInfo(w http.ResponseWriter, r *http.Request) error {
	i := Info{
		Name: b.Name, OS: runtime.GOOS, Arch: runtime.GOARCH, Build: buildID(), Version: version.Version,
		Tools: Tools(), Agents: Presets(nil), AgentPaths: AgentPaths(), Capabilities: b.Capabilities(),
		Adapters: map[string]adapters.Caps{},
	}
	if u, err := user.Current(); err == nil {
		i.User = u.Username
	}
	i.Home, _ = os.UserHomeDir()
	if i.Tools == nil {
		i.Tools = []string{}
	}
	if i.Agents == nil {
		i.Agents = []AgentPreset{}
	}
	for _, a := range adapters.All() {
		i.Adapters[a.Name] = a.Caps
	}
	writeJSON(w, i)
	return nil
}

// Capabilities name the API features this box has, so clients can use them
// when present. transcript: GET …/transcript (and ?before= pages, the
// "history" capability); diff: GET …/diff; titles: sessions carry a title
// (PATCH /v1/sessions/{name}); answer: POST …/answer fills in Claude Code's
// question form; session.home: POST /v1/sessions takes "home": true;
// session.chat: it takes "chat": true, and sessions say "chat"; draft:
// GET …/draft; journal: GET /v1/events?since=SEQ; turns, queue, ask and
// controls come with the turn ledger; pair.invite: POST /v1/pair/invite;
// push: the /v1/push routes (when push is configured).
func (b *Box) Capabilities() []string {
	caps := []string{"transcript", "history", "diff", "titles", "answer", "session.home", "session.chat", "draft", "journal", "touched"}
	if b.Turns != nil {
		caps = append(caps, "turns", "queue", "ask", "controls")
	}
	if b.Invites != nil {
		caps = append(caps, "pair.invite")
	}
	return caps
}

// agentState is one agent CLI as GET /v1/agents reports it.
type agentState struct {
	agentcli.Agent
	Installed bool   `json:"installed"`
	Path      string `json:"path,omitempty"`
}

// listAgentCLIs answers GET /v1/agents: which known agent CLIs this box has.
func (b *Box) listAgentCLIs(w http.ResponseWriter, r *http.Request) error {
	out := []agentState{}
	for _, a := range agentcli.Catalog {
		s := agentState{Agent: a}
		if f, ok := agentFound(a.Command); ok {
			s.Installed, s.Path = true, f.Path
		}
		out = append(out, s)
	}
	writeJSON(w, out)
	return nil
}
