package text

import (
	"testing"

	"pier/pierd/internal/push/boxapi"
)

func TestLangOf(t *testing.T) {
	for in, want := range map[string]Lang{"pt-BR": PT, "pt_BR": PT, "pt": PT, "PT-br": PT, "en-US": EN, "": EN, "de": EN} {
		if LangOf(in) != want {
			t.Errorf("%q", in)
		}
	}
}

func TestTitlesMirrorTheApp(t *testing.T) {
	cases := []struct {
		l          Lang
		kind, name string
		want       string
	}{
		{EN, "waiting", "Claude Code", "✋ Needs you · Claude Code"},
		{EN, "finished", "Fix login", "✅ Done · Fix login"},
		{EN, "failed", "Codex", "⚠️ Failed · Codex"},
		{EN, "waiting", "", "✋ Needs you"},
		{PT, "waiting", "Claude Code", "✋ Precisa de você · Claude Code"},
		{PT, "finished", "Corrigir login", "✅ Concluído · Corrigir login"},
		{PT, "failed", "Codex", "⚠️ Falhou · Codex"},
		{PT, "finished", "", "✅ Concluído"},
	}
	for _, c := range cases {
		if got := Title(c.l, c.kind, c.name); got != c.want {
			t.Errorf("got %q want %q", got, c.want)
		}
	}
}

func TestPhaseTitles(t *testing.T) {
	if PhaseTitle(PT, "waiting") != "Precisa de você" || PhaseTitle(EN, "finished") != "Done" {
		t.Fatal()
	}
}

func TestClip(t *testing.T) {
	if Clip("abcdef", 4) != "abc…" || Clip("ab", 4) != "ab" {
		t.Fatal()
	}
}

func TestSummaryAndBodies(t *testing.T) {
	if got := Summary("**Pronto!** Adicionei `mul` em calc.py. Depois rodei o lint.\nMais texto", 140); got != "Pronto! Adicionei mul em calc.py." {
		t.Fatalf("summary %q", got)
	}
	a, r := 3, 1
	if got := FinishedBody(PT, "", &a, &r); got != "+3 −1" {
		t.Fatalf("finished %q", got)
	}
	if got := FinishedBody(EN, "", nil, nil); got != "Finished." {
		t.Fatalf("finished empty %q", got)
	}
	if got := WaitingBody(PT, ""); got != "O agente está esperando sua resposta." {
		t.Fatalf("waiting %q", got)
	}
	if got := Subtitle("sandbox / x", "Codex", "devbox", true); got != "sandbox / x · Codex · devbox" {
		t.Fatalf("subtitle %q", got)
	}
}

// A chat belongs to no project: its place is the word for one, never its
// folder's generated name.
func TestAChatsPlaceIsAChat(t *testing.T) {
	locs := []boxapi.Location{{Name: "shop", Worktrees: []boxapi.Worktree{{Name: "fix", Path: "/w/shop-fix"}}}}
	chat := boxapi.Session{Dir: "/home/u/pier/chats/chat-claude-1x2y", Chat: true}
	if got := PlaceOf(PT, chat, locs); got != "Conversa" {
		t.Errorf("PT = %q", got)
	}
	if got := PlaceOf(EN, chat, locs); got != "Chat" {
		t.Errorf("EN = %q", got)
	}
	if got := PlaceOf(EN, boxapi.Session{Dir: "/w/shop-fix"}, locs); got != "shop / fix" {
		t.Errorf("a worktree's = %q", got)
	}
}
