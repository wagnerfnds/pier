package box

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
)

// Chats are agent sessions that belong to no project: a conversation to ask
// something, talk an idea through or plan what does not exist yet. Each runs
// in an empty folder of its own, named after its session, under
// ~/pier/chats, never in the home folder itself: an agent there would take
// the whole home for its project, and the turn ledger, which places a hook
// that names no session by its folder, would mix up two chats sharing one.
//
// A session is a chat when it has no location and its folder is one of
// these, so the list says so (Session.Chat) with nothing more kept in tmux.
// Ending one removes its folder when the agent left nothing there but the
// app's attachments; what it wrote stays, for the user to find.

// chatsDir is the folder that holds every chat's own.
func chatsDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("this box has no home folder for its user: %w", err)
	}
	return filepath.Join(home, "pier", "chats"), nil
}

// isChatDir says dir is a chat's own folder: directly under chatsDir.
func isChatDir(dir string) bool {
	root, err := chatsDir()
	if err != nil || dir == "" {
		return false
	}
	return sameDir(filepath.Dir(filepath.Clean(dir)), root)
}

// makeChatDir makes the empty folder for a chat named name. A folder an
// earlier chat of that name left behind is never shared: a name the request
// gave is refused (409), a default one gets a "-2", "-3", ... suffix. It
// answers the name the session takes and its folder.
func makeChatDir(name string, given bool) (string, string, error) {
	if !sessionName.MatchString(name) {
		return "", "", badRequest("invalid session name %q: use letters, digits, - and _", name)
	}
	root, err := chatsDir()
	if err != nil {
		return "", "", err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", "", err
	}
	base := name
	for i := 2; ; i++ {
		dir := filepath.Join(root, name)
		err := os.Mkdir(dir, 0o700)
		if err == nil {
			return name, dir, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return "", "", err
		}
		if given {
			return "", "", httpError{http.StatusConflict, fmt.Sprintf("%s is taken by an earlier chat's folder: pick another name", dir)}
		}
		if i > 99 {
			return "", "", fmt.Errorf("no free folder for a chat in %s", root)
		}
		suffix := "-" + strconv.Itoa(i)
		name = base[:min(len(base), 63-len(suffix))] + suffix
	}
}

// removeChatDir removes an ended chat's folder when the agent left nothing
// in it: an empty one, or one with only the app's attachments (.pier).
func removeChatDir(dir string) {
	if !isChatDir(dir) {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.Name() != ".pier" {
			return
		}
	}
	os.RemoveAll(filepath.Join(dir, ".pier"))
	os.Remove(dir)
}
