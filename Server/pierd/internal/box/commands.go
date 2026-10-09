package box

import (
	"strings"
)

// GET /v1/sessions/{name}/commands is what the session's agent takes after
// a "/": its own commands, the person's and the repository's custom
// commands, skills, and plugins' commands and skills, for the chat's
// autocomplete. GET /v1/sessions/{name}/files?q= lists the worktree's files
// for "@" mentions. Both are read from disk, cached per session for a
// minute and capped; nothing is kept.

// Command is one thing the agent takes after a "/".
type Command struct {
	// Name is what is typed, with its slash: "/model", "/vercel:deploy".
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	// Kind is builtin, custom, skill, plugin or mcp.
	Kind string `json:"kind"`
	// Args hints at what follows it ("[model]").
	Args string `json:"args,omitempty"`
	// Aliases are other names the agent takes for it ("/cost" for /usage).
	Aliases []string `json:"aliases,omitempty"`
	// Local commands are handled by the agent's own program (a setting, a
	// screen, a figure) rather than sent to its model as a prompt, so they
	// never start a turn.
	Local bool `json:"local,omitempty"`
	// Screen commands open the agent's own interactive screen (a picker or
	// a dialog), which the chat shows as a live terminal.
	Screen bool `json:"screen,omitempty"`
	// Source is where a custom command or skill was found: user, project
	// or the plugin's name.
	Source string `json:"source,omitempty"`
}

// CommandCatalog is a session's commands and what its prefixes do.
type CommandCatalog struct {
	Agent    string    `json:"agent"`
	Version  string    `json:"version,omitempty"`
	Commands []Command `json:"commands"`
	// Prefixes are the other characters the agent reads at the start of a
	// prompt: "!" (a shell command), "#" when it saves to memory.
	Prefixes map[string]string `json:"prefixes,omitempty"`
	// Notes says what is not listed, and why.
	Notes     []string `json:"notes,omitempty"`
	Truncated bool     `json:"truncated,omitempty"`
}

// builtin is one row of an agent's own command table.
type builtin struct {
	name, desc, args string
	aliases          []string
	// prompt marks the commands that send a prompt to the model (and so
	// start a turn); the rest are local.
	prompt bool
	// screen marks the commands that open an interactive screen.
	screen bool
}

// claudeBuiltins is Claude Code's own commands, as v2.1.289 lists them.
//
// How it was captured (do it again on an upgrade): start `claude` in a
// throwaway tmux (tmux -L capture new-session -d -x 200 -y 60 claude), type
// "/", then press Down through the whole menu, capturing the pane each time
// (tmux capture-pane -p) and keeping the "/name  description" lines; type
// each candidate alias (/cost, /quit, /reset…) to read "/usage (cost)".
// Skills and plugins in that menu come from disk and are left out here;
// bundled skills (simplify, loop…) stay, as every install has them. prompt
// is set for the ones that send a prompt to the model; screen for the ones
// that open their own picker or dialog.
var claudeBuiltins = []builtin{
	{name: "add-dir", desc: "Add a new working directory", args: "<path>"},
	{name: "advisor", desc: "Let Claude consult a stronger model at key moments", screen: true},
	{name: "artifacts", desc: "Browse your published and shared artifacts", screen: true},
	{name: "autocompact", desc: "Set how full the context gets before auto-summarizing", screen: true},
	{name: "background", desc: "Send this session to the background and free the terminal"},
	{name: "batch", desc: "Research and plan a large-scale change, then execute it in parallel across isolated worktrees", args: "<instruction>", prompt: true},
	{name: "branch", desc: "Create a branch of the current conversation at this point"},
	{name: "btw", desc: "Ask a quick side question without interrupting the main conversation", args: "<question>", screen: true},
	{name: "bug", desc: "Report a bug or share your conversation", screen: true},
	{name: "cd", desc: "Move this session to a new working directory", args: "<path>"},
	{name: "claude-api", desc: "Reference for the Claude API and Anthropic SDK", prompt: true},
	{name: "clear", desc: "Start a new session with empty context; the previous one stays resumable", aliases: []string{"reset", "new"}},
	{name: "code-review", desc: "Review the current diff for correctness bugs", args: "[target]", aliases: []string{"review"}, prompt: true},
	{name: "color", desc: "Set the prompt bar color for this session", args: "[color]"},
	{name: "compact", desc: "Free up context by summarizing the conversation so far", args: "[instructions]"},
	{name: "config", desc: "Open settings", aliases: []string{"settings"}, screen: true},
	{name: "context", desc: "Visualize current context usage"},
	{name: "copy", desc: "Copy Claude's last response to clipboard", args: "[N]"},
	{name: "debug", desc: "Enable debug logging for this session and help diagnose issues", prompt: true},
	{name: "desktop", desc: "Continue the current session in Claude Desktop", aliases: []string{"app"}},
	{name: "diff", desc: "Toggle the diff panel showing uncommitted changes", screen: true},
	{name: "doctor", desc: "Health-check the Claude Code setup and fix issues", screen: true},
	{name: "effort", desc: "Set effort level for model usage", args: "[low|medium|high|max]", screen: true},
	{name: "exit", desc: "Exit the CLI", aliases: []string{"quit"}},
	{name: "export", desc: "Export the current conversation to a file or clipboard", args: "[file]", screen: true},
	{name: "fast", desc: "Toggle fast mode"},
	{name: "feedback", desc: "Send feedback to Anthropic or report a bug", screen: true},
	{name: "fewer-permission-prompts", desc: "Add an allowlist for common read-only tool calls", prompt: true},
	{name: "focus", desc: "Toggle focus view: just your prompt, summary, and response"},
	{name: "fork", desc: "Copy this conversation into a new background session"},
	{name: "goal", desc: "Set a goal Claude checks before stopping", args: "<condition>"},
	{name: "help", desc: "Show help and available commands", screen: true},
	{name: "hooks", desc: "View hook configurations for tool events", screen: true},
	{name: "ide", desc: "Manage IDE integrations and show status", screen: true},
	{name: "import", desc: "Import config from another AI coding agent", screen: true},
	{name: "init", desc: "Initialize a new CLAUDE.md file with codebase documentation", prompt: true},
	{name: "insights", desc: "Generate a report analyzing your Claude Code sessions", prompt: true},
	{name: "install-github-app", desc: "Set up Claude GitHub Actions for a repository", screen: true},
	{name: "install-slack-app", desc: "Install the Claude Slack app"},
	{name: "keybindings", desc: "Open your keyboard shortcuts file"},
	{name: "list-agents", desc: "List subagents, teammates, and other Claude sessions you can message"},
	{name: "login", desc: "Sign in with your Anthropic account", screen: true},
	{name: "logout", desc: "Sign out from your Anthropic account"},
	{name: "loop", desc: "Run a prompt or slash command on a recurring interval", args: "[interval] <prompt>", prompt: true},
	{name: "mcp", desc: "Manage MCP servers", screen: true},
	{name: "memory", desc: "Edit CLAUDE.md files and memory settings", screen: true},
	{name: "mobile", desc: "Show QR code to download the Claude mobile app", screen: true},
	{name: "model", desc: "Set the AI model for Claude Code", args: "[model]", screen: true},
	{name: "output-style", desc: "List output styles or switch to one", args: "[style]", screen: true},
	{name: "permissions", desc: "Manage allow and deny tool permission rules", aliases: []string{"allowed-tools"}, screen: true},
	{name: "plan", desc: "Enable plan mode or view the current session plan"},
	{name: "plugin", desc: "Manage Claude Code plugins", screen: true},
	{name: "powerup", desc: "Discover Claude Code features through quick interactive lessons", screen: true},
	{name: "privacy-settings", desc: "View and update your privacy settings", screen: true},
	{name: "rate-limit-options", desc: "Manage usage limits and upgrade options", screen: true},
	{name: "recap", desc: "Generate a one-line session recap now"},
	{name: "release-notes", desc: "View release notes"},
	{name: "reload-plugins", desc: "Activate pending plugin changes in the current session"},
	{name: "reload-skills", desc: "Pick up skills added or changed on disk during this session"},
	{name: "remote-control", desc: "Control this session from your phone or claude.ai/code", aliases: []string{"rc"}, screen: true},
	{name: "remote-env", desc: "Choose the default environment for cloud agents", screen: true},
	{name: "rename", desc: "Rename the current conversation", args: "[name]"},
	{name: "resume", desc: "Resume a previous conversation", args: "[conversation]", aliases: []string{"continue"}, screen: true},
	{name: "rewind", desc: "Restore the code and/or conversation to a previous point", aliases: []string{"checkpoint"}, screen: true},
	{name: "run", desc: "Launch and drive this project's app to see a change working", prompt: true},
	{name: "sandbox", desc: "Configure the sandbox", screen: true},
	{name: "schedule", desc: "Create, update, list, or run scheduled cloud agents", prompt: true},
	{name: "security-review", desc: "Complete a security review of the pending changes on the current branch", prompt: true},
	{name: "simplify", desc: "Review the changed code for reuse, simplification and efficiency, then fix it", prompt: true},
	{name: "skills", desc: "List available skills", screen: true},
	{name: "status", desc: "Show version, model, account, API connectivity, and tool statuses", screen: true},
	{name: "statusline", desc: "Set up Claude Code's status line UI", prompt: true},
	{name: "tasks", desc: "View and manage everything running in the background", aliases: []string{"bashes"}, screen: true},
	{name: "team-onboarding", desc: "Help teammates ramp on Claude Code with a guide from your usage", prompt: true},
	{name: "terminal-setup", desc: "Install Shift+Enter key binding for newlines"},
	{name: "theme", desc: "Change the theme", screen: true},
	{name: "tui", desc: "Set the terminal UI renderer", args: "[default|fullscreen]"},
	{name: "update-config", desc: "Configure the Claude Code harness via settings.json", prompt: true},
	{name: "usage", desc: "Show session cost, plan usage, and activity stats", aliases: []string{"cost", "stats"}, screen: true},
	{name: "verify", desc: "Verify that a code change does what it should, end to end", prompt: true},
	{name: "voice", desc: "Toggle voice mode"},
}

// codexBuiltins is Codex's own commands, as codex-cli 0.153.2 lists them,
// captured the same way ("/" in a throwaway tmux, Down through the menu).
var codexBuiltins = []builtin{
	{name: "agents", desc: "View and switch between all active agent sessions", screen: true},
	{name: "app", desc: "Continue this session in the Desktop app"},
	{name: "approve", desc: "Approve one retry of a recent auto-review denial"},
	{name: "archive", desc: "Archive this session and exit"},
	{name: "cd", desc: "Change the current working directory", args: "<path>"},
	{name: "clear", desc: "Clear the terminal and start a new chat"},
	{name: "compact", desc: "Summarize conversation to prevent hitting the context limit"},
	{name: "copy", desc: "Copy the last response, code block, or quote"},
	{name: "delete", desc: "Permanently delete this session and exit"},
	{name: "diff", desc: "Show git diff (including untracked files)"},
	{name: "exit", desc: "Exit Codex", aliases: []string{"quit"}},
	{name: "experimental", desc: "Toggle experimental features", screen: true},
	{name: "export", desc: "Export the conversation as markdown"},
	{name: "fast", desc: "2x speed, increased usage"},
	{name: "feedback", desc: "Send logs to maintainers", screen: true},
	{name: "fork", desc: "Fork the current chat"},
	{name: "goal", desc: "Set or view the goal for a long-running task", args: "[goal]"},
	{name: "hooks", desc: "View and manage lifecycle hooks", screen: true},
	{name: "ide", desc: "Include current selection, open files, and other context from your IDE"},
	{name: "import", desc: "Import setup, this project, and recent chats from Claude Code", screen: true},
	{name: "init", desc: "Create an AGENTS.md file with instructions for Codex", prompt: true},
	{name: "keymap", desc: "Remap TUI shortcuts", screen: true},
	{name: "logout", desc: "Log out of Codex"},
	{name: "mcp", desc: "List configured MCP tools", args: "[verbose]"},
	{name: "memories", desc: "Configure memory use and generation", screen: true},
	{name: "mention", desc: "Mention a file", screen: true},
	{name: "model", desc: "Choose what model and reasoning effort to use", screen: true},
	{name: "new", desc: "Start a new chat during a conversation"},
	{name: "permissions", desc: "Choose what Codex is allowed to do", screen: true},
	{name: "personality", desc: "Choose a communication style for Codex", screen: true},
	{name: "pets", desc: "Choose or hide the terminal pet", screen: true},
	{name: "plan", desc: "Switch to Plan mode"},
	{name: "plugins", desc: "Browse plugins", screen: true},
	{name: "ps", desc: "List background terminals"},
	{name: "pwd", desc: "Show the current working directory"},
	{name: "raw", desc: "Toggle raw scrollback mode for copy-friendly terminal selection"},
	{name: "recap", desc: "Summarize the current conversation now"},
	{name: "rename", desc: "Rename the current thread", args: "[name]"},
	{name: "resume", desc: "Resume a saved chat", screen: true},
	{name: "review", desc: "Review my current changes and find issues", prompt: true, screen: true},
	{name: "side", desc: "Start a side conversation in an ephemeral fork"},
	{name: "skills", desc: "Use skills to improve how Codex performs specific tasks", screen: true},
	{name: "status", desc: "Show current session configuration and token usage"},
	{name: "statusline", desc: "Configure which items appear in the status line", screen: true},
	{name: "stop", desc: "Stop all background terminals"},
	{name: "subagents", desc: "Switch between this session's subagents", screen: true},
	{name: "theme", desc: "Choose a syntax highlighting theme", screen: true},
	{name: "title", desc: "Configure which items appear in the terminal title", screen: true},
	{name: "usage", desc: "View account usage or use a usage limit reset", screen: true},
	{name: "vim", desc: "Toggle Vim mode for the composer"},
}

// agentPrefixes is what each agent reads at the start of a prompt, checked
// the same way. Claude Code 2.1 no longer saves "#" lines to memory: they
// go to the model as a prompt.
var agentPrefixes = map[string]map[string]string{
	"claude": {"!": "Runs in the shell", "#": "Sent as a prompt: Claude Code 2.1 has no # memory (use /memory)"},
	"codex":  {"!": "Runs in the shell"},
}

func builtinsFor(agent string) []builtin {
	switch agent {
	case "claude":
		return claudeBuiltins
	case "codex":
		return codexBuiltins
	}
	return nil
}

// commandName is the command a prompt starts with ("/model" in "/model
// opus"), or "" when it doesn't start with one. A path ("/etc/hosts is
// wrong") is not a command.
func commandName(text string) string {
	text = strings.TrimSpace(text)
	if !strings.HasPrefix(text, "/") || strings.Contains(text[:min(len(text), 2)], "//") {
		return ""
	}
	name := text[1:]
	if i := strings.IndexAny(name, " \t\n"); i >= 0 {
		name = name[:i]
	}
	if name == "" || strings.Contains(name, "/") {
		return ""
	}
	return name
}

// localCommand is the agent's own command a prompt runs, when it is one
// handled by the agent's program rather than sent to its model: such a send
// starts no turn.
func localCommand(agent, text string) (string, bool) {
	// A shell command ("!ls") runs in the agent's program too: no hook says
	// a turn started, even when the agent then answers it.
	if t := strings.TrimSpace(text); strings.HasPrefix(t, "!") && len(t) > 1 && agentPrefixes[agent]["!"] != "" {
		return "!", true
	}
	name := commandName(text)
	if name == "" {
		return "", false
	}
	for _, c := range builtinsFor(agent) {
		if c.name == name || containsStr(c.aliases, name) {
			return "/" + c.name, !c.prompt
		}
	}
	return "", false
}

func containsStr(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// sessionAgent is the agent a session runs: its preset, else what the list
// knows, else its command's first word.
func sessionAgent(sess Session) string {
	return firstNonEmpty(sess.Preset, firstNonEmpty(sess.Agent, agentOf(sess.Command)))
}

// session name → commandsEntry

// ---- Files for "@" --------------------------------------------------------

// FileList is the worktree's files matching a query, for "@" mentions.
type FileList struct {
	Files     []string `json:"files"`
	Truncated bool     `json:"truncated,omitempty"`
}
