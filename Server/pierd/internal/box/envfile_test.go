package box

import "testing"

func TestEnvFileReadsValuesTheWayDotenvDoes(t *testing.T) {
	f := parseEnvFile([]byte("# app\nAPP_NAME=\"Acme CRM\"\nexport DB_HOST=127.0.0.1 # the box's\n" +
		"DB_PASSWORD='p$ss#word'\nEMPTY=\nDB_PORT=3306\nDB_PORT=3307\nPRIVATE_KEY=\"-----BEGIN\nabc\n-----END\"\nnot a line\n"))
	for key, want := range map[string]string{
		"APP_NAME":    "Acme CRM",
		"DB_HOST":     "127.0.0.1",
		"DB_PASSWORD": "p$ss#word",
		"EMPTY":       "",
		"DB_PORT":     "3307", // the last of two wins
		"PRIVATE_KEY": "-----BEGIN\nabc\n-----END",
	} {
		if got, _, ok := f.get(key); !ok || got != want {
			t.Errorf("%s = %q (%v), want %q", key, got, ok, want)
		}
	}
	keys := f.keys()
	want := []string{"APP_NAME", "DB_HOST", "DB_PASSWORD", "EMPTY", "DB_PORT", "PRIVATE_KEY"}
	if len(keys) != len(want) {
		t.Fatalf("keys = %v", keys)
	}
	for i := range want {
		if keys[i] != want[i] {
			t.Fatalf("keys = %v", keys)
		}
	}
}

// Changing a key leaves every other byte as someone wrote it: comments,
// `export`, quotes, a value over several lines, CRLF.
func TestEnvFileChangesOnlyTheKeyItSets(t *testing.T) {
	in := "# dev\r\nexport DB_HOST=localhost\r\nDB_PORT=3306\r\nKEY=\"multi\r\nline\"\r\nDB_PORT=3306\r\n"
	f := parseEnvFile([]byte(in))
	if !f.set("DB_PORT", "41009") || !f.set("DB_HOST", "127.0.0.1") || !f.set("REDIS_PORT", "41008") {
		t.Fatal("nothing changed")
	}
	if f.set("DB_PORT", "41009") {
		t.Fatal("setting the same value again changed the file")
	}
	got := string(f.bytes())
	want := "# dev\r\nexport DB_HOST=127.0.0.1\r\nDB_PORT=41009\r\nKEY=\"multi\r\nline\"\r\nDB_PORT=41009\r\nREDIS_PORT=41008\r\n"
	if got != want {
		t.Fatalf("file =\n%q\nwant\n%q", got, want)
	}
	if v, _, _ := parseEnvFile([]byte(got)).get("KEY"); v != "multi\nline" {
		t.Fatalf("multi-line value = %q", v)
	}
}

func TestOnlyDotenvFilesAreMergedKeyByKey(t *testing.T) {
	for path, want := range map[string]bool{
		".env": true, ".env.testing": true, "api/.env.local": true,
		"auth.json": false, "storage/oauth-private.key": false, "env": false, ".envrc": false,
	} {
		if isEnvFile(path) != want {
			t.Errorf("isEnvFile(%q) = %v", path, !want)
		}
	}
}
