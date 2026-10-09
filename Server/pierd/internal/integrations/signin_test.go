package integrations

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSignedInReadsTheCredentialFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("CODEX_HOME", "")
	t.Setenv("ANTHROPIC_API_KEY", "")
	t.Setenv("OPENAI_API_KEY", "")
	claude, codex := Tools[0], Tools[1]

	// Nothing on disk: signed out, and said so, except where the tokens live in a place a file cannot show.
	if in, known := codex.SignedIn(home); in || !known {
		t.Fatalf("codex without auth.json: signedIn=%v known=%v", in, known)
	}
	if in, known := claude.SignedIn(home); runtime.GOOS == "darwin" {
		if !in || known {
			t.Fatalf("claude on macOS keeps tokens in the Keychain: signedIn=%v known=%v", in, known)
		}
	} else if in || !known {
		t.Fatalf("claude without .credentials.json: signedIn=%v known=%v", in, known)
	}

	// The files the CLIs write once signed in.
	os.MkdirAll(filepath.Join(home, ".codex"), 0o755)
	os.WriteFile(filepath.Join(home, ".codex", "auth.json"), []byte(`{"tokens":{}}`), 0o600)
	if in, known := codex.SignedIn(home); !in || !known {
		t.Fatalf("codex with auth.json: signedIn=%v known=%v", in, known)
	}
	os.MkdirAll(filepath.Join(home, ".claude"), 0o755)
	os.WriteFile(filepath.Join(home, ".claude", ".credentials.json"), []byte(`{"claudeAiOauth":{}}`), 0o600)
	if in, known := claude.SignedIn(home); !in || !known {
		t.Fatalf("claude with .credentials.json: signedIn=%v known=%v", in, known)
	}

	// An empty file is not a sign-in; an API key in the environment is.
	os.WriteFile(filepath.Join(home, ".codex", "auth.json"), nil, 0o600)
	if in, _ := codex.SignedIn(home); in {
		t.Fatal("an empty auth.json counted as signed in")
	}
	t.Setenv("OPENAI_API_KEY", "sk-test")
	if in, known := codex.SignedIn(home); !in || !known {
		t.Fatalf("codex with an API key: signedIn=%v known=%v", in, known)
	}
	if Tools[0].LoginFix == "" || Tools[1].LoginFix == "" {
		t.Fatal("every tool needs the command that signs it in")
	}
}
