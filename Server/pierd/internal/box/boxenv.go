package box

import (
	"encoding/json"
	"fmt"
	"os"
)

// The box's own environment, ~/.pier/env.json: variables every worktree on
// the box gets, under the project's own. It is how a box picks a default,
// such as which Claude Code or Codex account new sessions use.

// BoxEnv is ~/.pier/env.json.
type BoxEnv struct {
	Env map[string]string `json:"env"`
}

func loadBoxEnv(path string) (BoxEnv, error) {
	var e BoxEnv
	if path == "" {
		return e, nil
	}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return e, nil
	}
	if err != nil {
		return e, err
	}
	if err := json.Unmarshal(b, &e); err != nil {
		return e, fmt.Errorf("%s: %w", path, err)
	}
	return e, nil
}
