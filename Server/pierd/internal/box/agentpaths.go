package box

import (
	"context"
	"os"
	"path/filepath"

	"pier/pierd/internal/agentpath"
	"pier/pierd/internal/doctor"
)

// Agent CLIs are found as the person's own terminal finds them
// (internal/agentpath): through their interactive login shell, so an npm
// install under nvm, fnm, volta or a custom prefix counts, then in the
// folders installers use. pierd's own PATH, a service's, sees neither.
// What is found is kept until something may have changed it: doctor, Add
// agents, integrations, a team setup's steps, and the app's Look again
// (POST /v1/agents/refresh).

// agentFinder finds agent CLIs; tests replace it.
var agentFinder = agentpath.Default

// agentFound finds an agent's command.
func agentFound(command string) (agentpath.Found, bool) {
	return agentFinder().Find(command)
}

// AgentPath is one agent CLI as this box has it: where, which version, and
// how it was installed, for Settings › Boxes and doctor.
type AgentPath struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Command string `json:"command"`
	Path    string `json:"path"`
	Version string `json:"version,omitempty"`
	// Install is "npm", "Homebrew", "bun", "volta", "pnpm" or "".
	Install string `json:"install,omitempty"`
	// Via is "shell", "path" or "dir" (agentpath.Found).
	Via string `json:"via,omitempty"`
}

// AgentPaths are the built-in agents this box has.
func AgentPaths() []AgentPath {
	out := []AgentPath{}
	for _, p := range builtinAgents {
		if f, ok := agentFound(p.Command); ok {
			out = append(out, AgentPath{ID: p.ID, Name: p.Name, Command: p.Command, Path: f.Path, Version: f.Version, Install: f.Install, Via: f.Via})
		}
	}
	return out
}

// launchPATH is the PATH an agent session starts with: the folder its CLI
// was found in, then the PATH the person's shell has, so the CLI and the
// tools it runs (node) are found even where the session's login shell
// alone would not find them. "" for anything that is not a built-in agent.
func launchPATH(command, agent string) string {
	id := agent
	if id == "" {
		id = agentOf(command)
	}
	for _, p := range builtinAgents {
		if p.ID == id {
			if f, ok := agentFound(p.Command); ok {
				return f.PATH
			}
			return ""
		}
	}
	return ""
}

// withPATH puts dirs before the session's own PATH, then runs what follows,
// in shell's syntax.
func withPATH(shell, dirs, then string) string {
	if dirs == "" {
		return then
	}
	if filepath.Base(shell) == "fish" {
		args := ""
		for _, d := range filepath.SplitList(dirs) {
			args += " " + shellQuote(d)
		}
		return "set -gx PATH" + args + " $PATH; " + then
	}
	return "PATH=" + shellQuote(dirs) + `:"$PATH"; export PATH; ` + then
}

// refreshAgents looks for the agent CLIs again and, when what is found
// changed, says so (agents.found), so the app reads the box's info again.
func (b *Box) refreshAgents(ctx context.Context) []AgentPath {
	before := AgentPaths()
	agentFinder().Refresh(ctx)
	after := AgentPaths()
	if b != nil && b.Events != nil && !sameAgentPaths(before, after) {
		ids := []string{}
		for _, a := range after {
			ids = append(ids, a.ID)
		}
		b.Events.Publish(eventf(b, "agents.found", map[string]any{"agents": ids}))
	}
	return after
}

func sameAgentPaths(a, b []AgentPath) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// agentChecks are doctor's lines for the agent CLIs: each found, with
// where and how it was installed, and whether the person's shell answered.
func agentChecks() []doctor.Check {
	home, _ := os.UserHomeDir()
	var checks []doctor.Check
	found := 0
	for _, p := range builtinAgents {
		f, ok := agentFound(p.Command)
		if !ok {
			continue
		}
		found++
		checks = append(checks, doctor.Check{Area: "Agents", Name: p.Name, Status: doctor.OK, Detail: agentpath.Describe(f, home)})
	}
	if found == 0 {
		checks = append(checks, doctor.Check{Area: "Agents", Name: "agent CLIs", Status: doctor.Info,
			Detail: "none found (claude, codex, opencode, gemini, cursor-agent), through your shell or where installers put them",
			Fix:    "Install it on the box: curl -fsSL https://claude.ai/install.sh | bash"})
	}
	st := agentFinder().Status()
	if st.Shell != "" && !st.OK {
		checks = append(checks, doctor.Check{Area: "Agents", Name: "shell", Status: doctor.Warn,
			Detail: "could not ask " + st.Shell + " where the agents are (" + st.Error + "), so only the usual install folders were searched",
			Fix:    "Make sure " + filepath.Base(st.Shell) + " -lic 'command -v claude' answers quickly in a terminal on the box"})
	}
	return checks
}
