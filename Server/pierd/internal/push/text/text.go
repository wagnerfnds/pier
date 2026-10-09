// Package text words notifications the way the app does (PierKit NotificationText + DisplayNames), in English or
// Brazilian Portuguese by device locale, so a push and a phone-generated local notification look the same.
package text

import (
	"fmt"
	"path"
	"strings"

	"pier/pierd/internal/push/boxapi"
)

// Lang is "en" or "pt".
type Lang string

const (
	EN Lang = "en"
	PT Lang = "pt"
)

// LangOf maps a device locale ("pt-BR", "pt_PT", "en-US", "") to a language.
func LangOf(locale string) Lang {
	l := strings.ToLower(strings.TrimSpace(locale))
	if l == "pt" || strings.HasPrefix(l, "pt-") || strings.HasPrefix(l, "pt_") {
		return PT
	}
	return EN
}

var agentLabels = map[string]string{
	"claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "gemini": "Gemini", "pi": "Pi",
	"cursor-agent": "Cursor Agent", "cursor": "Cursor Agent",
}
var knownAgents = []string{"claude", "codex", "opencode", "gemini", "pi", "cursor-agent"}

// AgentLabel: "claude" -> "Claude Code".
func AgentLabel(a string) string {
	if l, ok := agentLabels[a]; ok {
		return l
	}
	if a == "" {
		return ""
	}
	return strings.ToUpper(a[:1]) + a[1:]
}

// AgentOf is the session's agent id, also recognising a bare command (`/usr/bin/claude ...`); "" for shells/services.
func AgentOf(s boxapi.Session) string {
	if s.Service != "" {
		return ""
	}
	if s.Agent != "" {
		return s.Agent
	}
	if f := strings.Fields(s.Command); len(f) > 0 {
		prog := path.Base(f[0])
		for _, k := range knownAgents {
			if k == prog {
				return prog
			}
		}
	}
	return ""
}

// SessionName: the title, else the agent's name, else the service or "Shell"; untitled twins in one folder get " 2", " 3".
func SessionName(s boxapi.Session, among []boxapi.Session) string {
	title := strings.TrimSpace(s.Title)
	agent := AgentOf(s)
	name := title
	if name == "" {
		switch {
		case agent != "":
			name = AgentLabel(agent)
		case s.Service != "":
			name = s.Service
		default:
			name = "Shell"
		}
	}
	if title == "" {
		var same []boxapi.Session
		for _, o := range among {
			if o.Dir == s.Dir && AgentOf(o) == agent && !o.Exited && strings.TrimSpace(o.Title) == "" {
				same = append(same, o)
			}
		}
		if len(same) > 1 {
			// order by (created, name)
			n := 0
			for _, o := range same {
				if o.Created.Before(s.Created) || (o.Created.Equal(s.Created) && o.Name < s.Name) {
					n++
				}
			}
			if n > 0 {
				name += fmt.Sprintf(" %d", n+1)
			}
		}
	}
	return name
}

// Place is "repo" for a main checkout, else "repo / worktree"; falls back to the folder name.
func Place(dir string, locs []boxapi.Location) string {
	if dir == "" {
		return ""
	}
	for _, l := range locs {
		for _, w := range l.Worktrees {
			if w.Path == dir {
				if w.Main {
					return l.Name
				}
				return l.Name + " / " + w.Name
			}
		}
	}
	return path.Base(dir)
}

// PlaceOf is where a session runs, as Place says it; a chat, which belongs to no project, is "Conversa" / "Chat".
// Mirrors PierKit DisplayNames.chatPlace.
func PlaceOf(l Lang, s boxapi.Session, locs []boxapi.Location) string {
	if s.Chat {
		if l == PT {
			return "Conversa"
		}
		return "Chat"
	}
	return Place(s.Dir, locs)
}

// Phase titles of the Live Activity (ActivityPhase.title in the app).
func PhaseTitle(l Lang, phase string) string {
	pt := map[string]string{"starting": "Iniciando", "running": "Trabalhando", "waiting": "Precisa de você", "finished": "Concluído", "ended": "Encerrada"}
	en := map[string]string{"starting": "Starting", "running": "Working", "waiting": "Needs you", "finished": "Done", "ended": "Ended"}
	if l == PT {
		return pt[phase]
	}
	return en[phase]
}

// Title is the alert's title, led by the state so a glance says what happened: "✋ Needs you · <name>",
// "✅ Done · <name>", "⚠️ Failed · <name>", "⚙️ Working · <name>". name is the session's (shortened) title, "" when no
// session could be matched. Mirrors PierKit NotificationText.
func Title(l Lang, kind, name string) string {
	var head string
	if l == PT {
		switch kind {
		case "waiting":
			head = "✋ Precisa de você"
		case "failed":
			head = "⚠️ Falhou"
		case "working":
			head = "⚙️ Trabalhando"
		case "background":
			head = "⏳ Em segundo plano"
		default:
			head = "✅ Concluído"
		}
	} else {
		switch kind {
		case "waiting":
			head = "✋ Needs you"
		case "failed":
			head = "⚠️ Failed"
		case "working":
			head = "⚙️ Working"
		case "background":
			head = "⏳ In background"
		default:
			head = "✅ Done"
		}
	}
	short := Clip(name, 48)
	if short == "" {
		return head
	}
	return head + " · " + short
}

// Subtitle is "<place> · <agent>" (e.g. "sandbox / push-live · Claude Code"); the box name only when there are several.
func Subtitle(place, agent, box string, manyBoxes bool) string {
	var p []string
	for _, v := range []string{place, agent} {
		if v != "" {
			p = append(p, v)
		}
	}
	if manyBoxes && box != "" {
		p = append(p, box)
	}
	return strings.Join(p, " · ")
}

// Summary turns an agent reply into one notification-sized sentence: markdown stripped, first sentence/line, clipped.
func Summary(reply string, n int) string {
	r := strings.TrimSpace(reply)
	for _, m := range []string{"**", "__", "`", "#"} {
		r = strings.ReplaceAll(r, m, "")
	}
	if i := strings.IndexAny(r, "\n"); i > 0 {
		r = r[:i]
	}
	r = strings.Join(strings.Fields(r), " ")
	for _, sep := range []string{". ", "! ", "? "} {
		if i := strings.Index(r, sep); i > 20 {
			r = r[:i+1]
			break
		}
	}
	return Clip(r, n)
}

// Excerpt is a reply for the Live Activity: markdown marks stripped, lines joined, clipped to n runes.
func Excerpt(reply string, n int) string {
	r := strings.TrimSpace(reply)
	for _, m := range []string{"**", "__", "`", "#"} {
		r = strings.ReplaceAll(r, m, "")
	}
	return Clip(strings.Join(strings.Fields(r), " "), n)
}

// FinishedBody: the agent's last sentence, then the change count on its own line.
func FinishedBody(l Lang, reply string, added, removed *int) string {
	var lines []string
	if s := Summary(reply, 140); s != "" {
		lines = append(lines, s)
	}
	if added != nil && removed != nil && (*added > 0 || *removed > 0) {
		files := fmt.Sprintf("+%d −%d", *added, *removed)
		lines = append(lines, files)
	}
	if len(lines) == 0 {
		if l == PT {
			return "Terminou."
		}
		return "Finished."
	}
	return strings.Join(lines, "\n")
}

// BackgroundBody: the agent's last sentence, then what still runs.
func BackgroundBody(l Lang, reply string, jobs []string) string {
	var lines []string
	if s := Summary(reply, 120); s != "" {
		lines = append(lines, s)
	}
	more := ""
	if len(jobs) > 1 {
		more = fmt.Sprintf(" (+%d)", len(jobs)-1)
	}
	if len(jobs) > 0 {
		lines = append(lines, "⏳ "+Clip(jobs[0], 60)+more)
	}
	return strings.Join(lines, "\n")
}

// WaitingBody: what the agent asks for, else a nudge.
func WaitingBody(l Lang, ask string) string {
	if a := Clip(ask, 160); a != "" {
		return a
	}
	if l == PT {
		return "O agente está esperando sua resposta."
	}
	return "The agent is waiting for your answer."
}

// ChoicesLine numbers a waiting agent's choices the way the alert's buttons are numbered: "1 Three tiers · 2 One plan".
func ChoicesLine(options []string) string {
	parts := make([]string, 0, len(options))
	for i, o := range options {
		parts = append(parts, fmt.Sprintf("%d %s", i+1, Clip(o, 40)))
	}
	return strings.Join(parts, " · ")
}

// Clip shortens to n runes with an ellipsis.
func Clip(s string, n int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= n {
		return string(r)
	}
	return string(r[:n-1]) + "…"
}

// TestAlert is the text of POST /v1/push/test.
func TestAlert(l Lang, box string) (title, body string) {
	if l == PT {
		return "Pier: teste de push", "Funcionando. Caixa: " + box
	}
	return "Pier push test", "It works. Box: " + box
}
