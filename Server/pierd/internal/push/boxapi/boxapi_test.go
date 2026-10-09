package boxapi

import (
	"context"
	"net/http"
	"testing"
)

func TestGetThroughTheHandlerInProcess(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/sessions", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`[{"name":"s1","agent":"claude","agent_state":"waiting","state_since":"2026-10-07T19:05:12.123456789Z","ask":{"tool":"Bash","input":"rm -rf build"}}]`))
	})
	mux.HandleFunc("GET /v1/sessions/{name}/screen", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":"no session with that name"}`))
	})
	c := New(mux)
	ss, err := c.Sessions(context.Background())
	if err != nil || len(ss) != 1 || ss[0].Ask.Summary() != "Bash  rm -rf build" || ss[0].StateSince.IsZero() {
		t.Fatalf("%+v %v", ss, err)
	}
	if _, err := c.Screen(context.Background(), "gone"); err == nil {
		t.Fatal("a 404 must be an error")
	}
}

func TestOpenQuestion(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/sessions/{name}/transcript", func(w http.ResponseWriter, r *http.Request) {
		switch r.PathValue("name") {
		case "open":
			w.Write([]byte(`{"items":[{"kind":"user","text":"hi"},{"kind":"question","tool":"AskUserQuestion","questions":[{"question":"Which colour?","options":[{"label":"Red"},{"label":" Green "},{"label":""}]}]}]}`))
		case "answered":
			w.Write([]byte(`{"items":[{"kind":"question","done":true,"answers":["Red"],"questions":[{"question":"Which colour?","options":[{"label":"Red"},{"label":"Green"}]}]}]}`))
		case "multi":
			w.Write([]byte(`{"items":[{"kind":"question","questions":[{"question":"Toppings?","multi":true,"options":[{"label":"Cheese"},{"label":"Ham"}]}]}]}`))
		case "form":
			w.Write([]byte(`{"items":[{"kind":"question","questions":[{"question":"A?","options":[{"label":"1"},{"label":"2"}]},{"question":"B?","options":[{"label":"x"},{"label":"y"}]}]}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	c := New(mux)
	ctx := context.Background()
	if got := c.OpenQuestion(ctx, "open"); len(got) != 2 || got[0] != "Red" || got[1] != "Green" {
		t.Fatalf("open question: %v", got)
	}
	for _, name := range []string{"answered", "multi", "form", "gone"} {
		if got := c.OpenQuestion(ctx, name); got != nil {
			t.Fatalf("%s: expected no choices, got %v", name, got)
		}
	}
}

func TestJobTitle(t *testing.T) {
	for in, want := range map[string]string{
		"cd /w/x; scripts/verificar.sh 41710 > /tmp/a.log 2>&1; echo": "scripts/verificar.sh 41710",
		"cd /w/x && pnpm test | tail -5":                              "pnpm test",
		"sleep 30":                                                    "sleep 30",
	} {
		if got := JobTitle(in); got != want {
			t.Errorf("JobTitle(%q) = %q, want %q", in, got, want)
		}
	}
}
