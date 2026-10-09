// Package agentcli lists the agent CLIs pierd runs, and how each is
// installed, for GET /v1/agents. pierd does not install them itself: the
// person runs the install command on the box.
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
	// Offered is always false: pierd leaves installing to the person, and
	// Why says so.
	Offered bool   `json:"offered"`
	Why     string `json:"why,omitempty"`
}

const why = "install it on the box with the command shown; pierd does not install agents"

// Catalog is every agent CLI pierd has presets and hooks for, in order.
var Catalog = []Agent{
	{ID: "claude", Name: "Claude Code", Command: "claude", Default: true,
		Install: "curl -fsSL https://claude.ai/install.sh | bash", Why: why},
	{ID: "codex", Name: "Codex", Command: "codex",
		Install: "npm install -g @openai/codex", Why: why},
}
