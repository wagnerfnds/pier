package integrations

import (
	"os"
	"path/filepath"
	"testing"
)

// The bypass-mode warning is turned off with every other setting kept, once;
// a folder without settings gets a file holding only that.
func TestSkipBypassWarningKeepsTheRest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	os.WriteFile(path, []byte(`{"model":"opus","skipDangerousModePermissionPrompt":false}`), 0o644)
	if changed, err := SkipBypassWarning(path); err != nil || !changed {
		t.Fatalf("first = %v %v", changed, err)
	}
	root := readJSON(t, path)
	if root["model"] != "opus" || root[skipBypassKey] != true {
		t.Fatalf("settings = %v", root)
	}
	if changed, _ := SkipBypassWarning(path); changed {
		t.Fatal("a second call changed the file again")
	}
	fresh := filepath.Join(t.TempDir(), "account", "settings.json")
	if changed, err := SkipBypassWarning(fresh); err != nil || !changed || readJSON(t, fresh)[skipBypassKey] != true {
		t.Fatalf("a new account's settings = %v %v", changed, err)
	}
	broken := filepath.Join(t.TempDir(), "settings.json")
	os.WriteFile(broken, []byte(`{"model":`), 0o644)
	if _, err := SkipBypassWarning(broken); err == nil {
		t.Fatal("a broken settings file was written over")
	}
}
