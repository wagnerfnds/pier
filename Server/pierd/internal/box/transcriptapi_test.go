package box

import "testing"

// A session from before presets is known by its command alone.
func TestTranscriptAgentFromCommand(t *testing.T) {
	if got := agentOf("claude --resume x"); got != "claude" {
		t.Fatalf("agentOf = %q", got)
	}
}
