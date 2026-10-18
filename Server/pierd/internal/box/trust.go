package box

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"

	"pier/pierd/internal/integrations"
)

// Claude Code and Codex stop at "trust this folder?" the first time they
// run in a folder, and Codex at its new hooks too. For the folders pierd
// makes and the projects the person registered, pierd gives the answer up
// front, in the agent's own config (integrations/trust.go): before an
// agent starts, when a worktree or a project is made, and when an account
// is added (for every project already there). The startup watch still
// answers the question from the screen when it comes anyway (startup.go).
// None of this ever stops what it runs for: a config pierd cannot write is
// left as it is, and logged.

// logf is where pierd says what it could not do on the side; tests quiet it.
var logf = log.Printf

// agentHome is the folder the agents' default configs are in; tests point
// it at a scratch folder.
var agentHome = os.UserHomeDir

// trustAgents are the agents pierd answers the question for.
var trustAgents = []string{"claude", "codex"}

// trustPaths are the folders an agent started in dir is asked about, as it
// keys them: the real path of dir's repository top folder (a linked
// worktree's own), and, for a linked worktree, its repository's main
// checkout too: Claude Code records the trust it is given there, and Codex
// looks there after the folder itself. A folder in no repository is its
// own.
func trustPaths(dir string) []string {
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		real = filepath.Clean(dir)
	}
	top := ""
	for d := real; ; d = filepath.Dir(d) {
		if _, err := os.Lstat(filepath.Join(d, ".git")); err == nil {
			top = d
			break
		}
		if filepath.Dir(d) == d {
			break
		}
	}
	if top == "" {
		return []string{real}
	}
	out := []string{top}
	if main := mainCheckout(top); main != "" && main != top {
		out = append(out, main)
	}
	return out
}

// mainCheckout is the main checkout of the repository whose linked
// worktree is top (its .git a file naming a gitdir under the repository's
// .git/worktrees), as git records it; top itself for a main checkout, ""
// for one it cannot tell (a bare repository's worktree).
func mainCheckout(top string) string {
	dotGit := filepath.Join(top, ".git")
	st, err := os.Stat(dotGit)
	if err != nil {
		return ""
	}
	if st.IsDir() {
		return top
	}
	raw, err := os.ReadFile(dotGit)
	if err != nil {
		return ""
	}
	gitdir, ok := strings.CutPrefix(strings.TrimSpace(string(raw)), "gitdir:")
	if !ok {
		return ""
	}
	gitdir = strings.TrimSpace(gitdir)
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(top, gitdir)
	}
	common := filepath.Dir(filepath.Dir(gitdir)) // .git/worktrees/<name> → .git
	if raw, err := os.ReadFile(filepath.Join(gitdir, "commondir")); err == nil {
		c := strings.TrimSpace(string(raw))
		if !filepath.IsAbs(c) {
			c = filepath.Join(gitdir, c)
		}
		common = filepath.Clean(c)
	}
	if filepath.Base(common) != ".git" {
		return ""
	}
	main := filepath.Dir(common)
	if r, err := filepath.EvalSymlinks(main); err == nil {
		main = r
	}
	return main
}

// envValue is key's value in env (KEY=VALUE lines), the last one winning.
func envValue(env []string, key string) string {
	v := ""
	for _, kv := range env {
		if k, val, ok := strings.Cut(kv, "="); ok && k == key {
			v = val
		}
	}
	return v
}

// agentConfigDir is the settings folder an agent started with env uses:
// the account's (CLAUDE_CONFIG_DIR, CODEX_HOME) in env or pierd's own
// environment, else "" for the agent's default.
func agentConfigDir(env []string, agent string) string {
	key := agentDirVar[agent]
	if v := envValue(env, key); v != "" && filepath.IsAbs(v) {
		return v
	}
	if v := os.Getenv(key); v != "" && filepath.IsAbs(v) {
		return v
	}
	return ""
}

// pretrust answers, for each agent, its question about dir before it is
// asked: in the account env points the agent at.
func (b *Box) pretrust(dir string, env []string, agents ...string) {
	home, err := agentHome()
	if err != nil || dir == "" {
		return
	}
	paths := trustPaths(dir)
	for _, agent := range agents {
		b.trustIn(home, agent, agentConfigDir(env, agent), paths)
	}
}

// trustIn records, in one agent account's config, that it trusts paths;
// configDir "" is the agent's default account.
func (b *Box) trustIn(home, agent, configDir string, paths []string) {
	switch agent {
	case "claude":
		config := integrations.ClaudeConfigFile(configDir, home)
		if changed, err := integrations.TrustClaudeProject(config, paths...); err != nil {
			logf("pierd: Claude Code will ask whether to trust %s: %v", strings.Join(paths, ", "), err)
		} else if changed {
			logf("pierd: Claude Code trusts %s (%s)", strings.Join(paths, ", "), config)
		}
	case "codex":
		dir := configDir
		if dir == "" {
			dir = filepath.Join(home, ".codex")
		}
		config := filepath.Join(dir, "config.toml")
		if changed, err := integrations.TrustCodexProject(config, paths...); err != nil {
			logf("pierd: Codex will ask whether to trust %s: %v", strings.Join(paths, ", "), err)
		} else if changed {
			logf("pierd: Codex trusts %s (%s)", strings.Join(paths, ", "), config)
		}
		bin := b.Exe
		if bin == "" {
			bin = "pierd"
		}
		if _, err := integrations.TrustCodexHooks(config, filepath.Join(dir, "hooks.json"), bin); err != nil {
			logf("pierd: Codex will ask to review pierd's hooks: %v", err)
		}
	}
}

// trustLocationDir answers the agents' question about a folder of the
// project location (a worktree just made, the project itself): for every
// agent this box has, in the accounts the project's agents use.
func (b *Box) trustLocationDir(location, dir string) {
	var env []string
	for k, v := range b.accountVars(location) {
		env = append(env, k+"="+v)
	}
	b.pretrust(dir, env, b.agentsHere()...)
	b.carryMcpChoice(location, dir, env)
}

// carryMcpChoice gives a new folder of the project location the answer its
// person gave Claude Code about the repository's MCP servers in another of
// its folders (the main checkout first, then the worktrees), in the account
// env points the project's agents at.
func (b *Box) carryMcpChoice(location, dir string, env []string) {
	home, err := agentHome()
	if err != nil || dir == "" {
		return
	}
	if _, ok := agentFound("claude"); !ok {
		return
	}
	locs, err := b.Locations.List(context.Background())
	if err != nil {
		return
	}
	var from []string
	for _, l := range locs {
		if l.Name != location {
			continue
		}
		from = append(from, trustPaths(l.Path)...)
		for _, wt := range l.Worktrees {
			from = append(from, trustPaths(wt.Path)...)
		}
	}
	config := integrations.ClaudeConfigFile(agentConfigDir(env, "claude"), home)
	if changed, err := integrations.CarryClaudeMcpChoice(config, trustPaths(dir), from); err != nil {
		logf("pierd: Claude Code will ask about the MCP servers of %s: %v", dir, err)
	} else if changed {
		logf("pierd: Claude Code keeps the project's answer about its MCP servers in %s", dir)
	}
}

// agentsHere are the agents pierd answers for that this box has.
func (b *Box) agentsHere() []string {
	var out []string
	for _, a := range trustAgents {
		for _, p := range builtinAgents {
			if p.ID == a {
				if _, ok := agentFound(p.Command); ok {
					out = append(out, a)
				}
			}
		}
	}
	return out
}

// trustProjectsFor answers, in one account, the question about every
// project already on the box: its folder and every worktree's. A new
// account would otherwise ask about each of them again.
func (b *Box) trustProjectsFor(a Account) {
	home, err := agentHome()
	if err != nil {
		return
	}
	locs, err := b.Locations.List(context.Background())
	if err != nil {
		return
	}
	var paths []string
	for _, l := range locs {
		paths = append(paths, trustPaths(l.Path)...)
		for _, wt := range l.Worktrees {
			paths = append(paths, trustPaths(wt.Path)...)
		}
	}
	if len(paths) == 0 {
		return
	}
	configDir := a.Dir
	if a.Builtin {
		configDir = os.Getenv(agentDirVar[a.Agent])
	}
	b.trustIn(home, a.Agent, configDir, paths)
}

// projectFolder says dir is in one of the box's projects: a location's
// folder, or one of its worktrees'.
func (b *Box) projectFolder(ctx context.Context, dir string) bool {
	if dir == "" {
		return false
	}
	locs, err := b.Locations.List(ctx)
	if err != nil {
		return false
	}
	in := func(root string) bool {
		return root != "" && (dir == root || strings.HasPrefix(dir, root+string(filepath.Separator)))
	}
	for _, l := range locs {
		if in(l.Path) {
			return true
		}
		for _, wt := range l.Worktrees {
			if in(wt.Path) {
				return true
			}
		}
	}
	return false
}
