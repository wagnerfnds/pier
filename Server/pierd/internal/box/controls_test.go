package box

import "testing"

func TestClaudeControls(t *testing.T) {
	foot := func(lines ...string) string {
		s := "⏺ Done.\n\n                                   ● high · /effort\n────\n❯ \n────\n"
		for _, l := range lines {
			s += l + "\n"
		}
		return s
	}
	for _, tc := range []struct {
		screen, mode string
	}{
		{foot("  Opus 5.5", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"), "auto"},
		{foot("  ⏸ manual mode on · ← for agents"), "default"},
		{foot("  ⏵⏵ accept edits on (shift+tab to cycle)"), "acceptEdits"},
		{foot("  ⏸ plan mode on (shift+tab to cycle)"), "plan"},
		{foot("  ⏵⏵ bypass permissions on (shift+tab to cycle)"), "bypassPermissions"},
		{foot("  ? for shortcuts"), "default"},
	} {
		c := claudeControls(tc.screen)
		if c.Mode != tc.mode || c.Effort != "high" {
			t.Errorf("%q: mode %q effort %q, want %q high", tc.screen, c.Mode, c.Effort, tc.mode)
		}
	}
	c := claudeControls(foot("⎿  You've hit your limit · resets 3pm (Europe/London)", "  ⏸ manual mode on"))
	if c.Limit != "You've hit your limit · resets 3pm (Europe/London)" {
		t.Errorf("limit = %q", c.Limit)
	}
}
