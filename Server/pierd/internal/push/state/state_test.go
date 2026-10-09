package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPersistAndReload(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	s, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	s.PutDevice(Device{Client: "c1", Token: "aabb", Env: "development", Locale: "pt-BR", Events: DefaultEvents, Updated: time.Now()})
	s.PutActivity(Activity{Client: "c1", Box: "casa", Session: "s1", Token: "ccdd", Env: "development"})
	s.SetSeen("s1", Seen{State: "waiting", Since: time.Unix(1790000000, 0)})
	s.SetLastSeq(42)
	s.Flush()
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode().Perm())
	}
	r, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	if d, ok := r.Device("c1"); !ok || d.Locale != "pt-BR" {
		t.Fatal("device lost")
	}
	if got := r.ActivitiesFor("s1"); len(got) != 1 || got[0].Token != "ccdd" {
		t.Fatal("activity lost")
	}
	if r.LastSeq() != 42 {
		t.Fatal("seq lost")
	}
	if v, ok := r.Seen("s1"); !ok || v.State != "waiting" {
		t.Fatal("seen lost")
	}
}

func TestDropDeviceTokenRemovesEmptyDevice(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "s.json"))
	s.PutDevice(Device{Client: "c", Token: "aabb", WidgetToken: "ccdd"})
	s.DropDeviceToken("c", "device")
	if d, ok := s.Device("c"); !ok || d.Token != "" || d.WidgetToken == "" {
		t.Fatal("only the dead token should go")
	}
	s.DropDeviceToken("c", "widget")
	if _, ok := s.Device("c"); ok {
		t.Fatal("empty device should be removed")
	}
}

func TestDeleteDeviceRemovesActivities(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "s.json"))
	s.PutDevice(Device{Client: "c", Token: "aabb"})
	s.PutActivity(Activity{Client: "c", Box: "b", Session: "s", Token: "aabb"})
	s.PutActivity(Activity{Client: "other", Box: "b", Session: "s", Token: "aabb"})
	s.DeleteDevice("c")
	if len(s.Activities()) != 1 {
		t.Fatal("activities of the deleted device remain")
	}
}

func TestPruneClients(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "s.json"))
	s.PutDevice(Device{Client: "keep", Token: "aabb"})
	s.PutDevice(Device{Client: "gone", Token: "aabb"})
	s.PutActivity(Activity{Client: "gone", Box: "b", Session: "s", Token: "aabb"})
	if n := s.PruneClients(func(c string) bool { return c == "keep" }); n != 2 {
		t.Fatalf("removed %d", n)
	}
}

func TestValidToken(t *testing.T) {
	for tok, ok := range map[string]bool{"00112233aabbccdd": true, "0g": false, "abc": false, "": false, "AABBCCDD": true} {
		if ValidToken(tok) != ok {
			t.Fatalf("%q", tok)
		}
	}
}
