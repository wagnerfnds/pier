package box

// WorktreeRequest asks for a new git worktree at a location.
type WorktreeRequest struct {
	Name   string `json:"name"`
	Branch string `json:"branch,omitempty"`
	Base   string `json:"base,omitempty"`
	// PR and Ref check out a pull or merge request: Ref (by default
	// pull/<PR>/head) is fetched into Branch when origin has no such branch.
	PR  int    `json:"pr,omitempty"`
	Ref string `json:"ref,omitempty"`
}
