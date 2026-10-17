package adapters

import "testing"

// A question that waits for a person reads as waiting, never as a quiet,
// finished screen.
func TestScreenStateSeesQuestionsThatWait(t *testing.T) {
	for name, screen := range map[string]string{
		"trust": " Quick safety check: Is this a project you created or one you trust?\n ❯ 1. Yes, I trust this folder\n   2. No, exit\n Enter to confirm · Esc to cancel\n",
		"bypass": "  WARNING: Claude Code running in Bypass Permissions mode\n  By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode.\n" +
			"  ❯ No, exit\n    Yes, I accept\n  Enter to confirm · Esc to cancel\n",
		"tool": " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n",
	} {
		if got := ScreenState(screen); got != "waiting" {
			t.Errorf("%s: %q", name, got)
		}
	}
	if got := ScreenState("❯ Try \"fix typecheck errors\"\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"); got != "" {
		t.Errorf("an idle prompt reads %q", got)
	}
}
