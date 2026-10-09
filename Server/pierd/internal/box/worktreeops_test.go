package box

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"pier/pierd/internal/events"
)

// cloneWithWorktree makes an origin, a clone of it as a location, and a
// worktree with one commit of its own.
func cloneWithWorktree(t *testing.T) (*Box, string, Worktree) {
	t.Helper()
	ctx := context.Background()
	origin := gitRepo(t)
	clone := filepath.Join(t.TempDir(), "app")
	gitIn(t, filepath.Dir(clone), "clone", "-q", origin, clone)
	dir := t.TempDir()
	b := &Box{Name: "devbox", Locations: NewLocations(filepath.Join(dir, "locations.json")), Events: &events.Bus{},
		Sessions: testSessions(t)}
	if _, err := b.Locations.Add(ctx, "app", clone); err != nil {
		t.Fatal(err)
	}
	wt, err := b.Locations.CreateWorktree(ctx, "app", "feature", "", "")
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(wt.Path, "feature.txt"), []byte("mine"), 0o644)
	gitIn(t, wt.Path, "add", ".")
	gitIn(t, wt.Path, "commit", "-q", "-m", "Add the feature")
	return b, origin, wt
}

func TestWorktreeStatusAndHistoryCompareWithTheBase(t *testing.T) {
	ctx := context.Background()
	b, origin, wt := cloneWithWorktree(t)
	// main moves on upstream.
	os.WriteFile(filepath.Join(origin, "upstream.txt"), []byte("theirs"), 0o644)
	gitIn(t, origin, "add", ".")
	gitIn(t, origin, "commit", "-q", "-m", "Upstream change")
	gitIn(t, wt.Path, "fetch", "-q", "origin")
	os.WriteFile(filepath.Join(wt.Path, "scratch.txt"), []byte("x"), 0o644)

	loc, _ := b.Locations.Get(ctx, "app")
	st := b.worktreeStatus(ctx, loc, Worktree{Name: "feature", Path: wt.Path, Branch: "feature"}, nil)
	if st.Base != "origin/main" || st.Ahead != 1 || st.Behind != 1 || st.Untrack != 1 || st.Last == nil || st.Last.Subject != "Add the feature" {
		t.Fatalf("status = %+v", st)
	}
	commits, err := gitLog(ctx, wt.Path, st.Base, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(commits) != 2 || commits[0].OnBase || !commits[1].OnBase || commits[0].Author != "t" {
		t.Fatalf("log = %+v", commits)
	}
}
