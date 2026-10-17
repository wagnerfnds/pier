// Package agentcli lists the agent CLIs pierd runs, and how each is
// installed, for GET /v1/agents. pierd installs Claude Code and Codex itself
// (`pierd tools install`, POST /v1/tools/install, internal/installer); Install
// is the command for a person who would rather do it by hand.
package agentcli

// Agent is an agent CLI pierd knows.
type Agent struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Command string `json:"command"`
	// Install is how a person installs it, as they would type it.
	Install string `json:"install,omitempty"`
	// Default agents are ticked when nothing was chosen before.
	Default bool `json:"default,omitempty"`
	// Offered says pierd installs it itself (POST /v1/tools/install); Why
	// says how.
	Offered bool   `json:"offered"`
	Why     string `json:"why,omitempty"`
}

const why = "pierd installs it in ~/.local/bin (pierd tools install, or the app); or run the command shown"

// Catalog is every agent CLI pierd has presets and hooks for, in order.
var Catalog = []Agent{
	{ID: "claude", Name: "Claude Code", Command: "claude", Default: true,
		Install: "curl -fsSL https://claude.ai/install.sh | bash", Offered: true, Why: why},
	{ID: "codex", Name: "Codex", Command: "codex",
		Install: "curl -fsSL https://chatgpt.com/codex/install.sh | sh", Offered: true, Why: why},
}
