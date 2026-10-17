package integrations

// Claude Code started in bypassPermissions mode first shows a warning and
// waits for someone to accept it, unless its settings say not to
// (skipDangerousModePermissionPrompt). An agent pierd starts to work
// unattended, a setup agent, must not stop there.

// skipBypassKey is Claude Code's settings key for that warning.
const skipBypassKey = "skipDangerousModePermissionPrompt"

// SkipBypassWarning sets skipDangerousModePermissionPrompt in a Claude Code
// settings file, keeping every other setting (the file before is kept
// beside it, as for the hooks). It reports whether it changed anything;
// running it again is a no-op.
func SkipBypassWarning(settingsPath string) (bool, error) {
	f, rel := fileAt(settingsPath)
	return editJSON(f, rel, func(root map[string]any) bool {
		if on, _ := root[skipBypassKey].(bool); on {
			return false
		}
		root[skipBypassKey] = true
		return true
	})
}
