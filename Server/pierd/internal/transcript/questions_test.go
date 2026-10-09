package transcript

import (
	"os"
	"path/filepath"
	"testing"
)

func questionItems(items []Item) []Item {
	var out []Item
	for _, it := range items {
		if it.Kind == "question" {
			out = append(out, it)
		}
	}
	return out
}

// The three questions of a real AskUserQuestion call (Claude Code 2.1):
// single choice, multiple choice, and one answered in the person's words.
var threeQuestions = []m{
	{"question": "Pick a colour:", "header": "Colour", "multiSelect": false, "options": []m{{"label": "Red", "description": "The colour red"}, {"label": "Green", "description": "The colour green"}, {"label": "Blue", "description": "The colour blue"}}},
	{"question": "Pick your toppings:", "header": "Toppings", "multiSelect": true, "options": []m{{"label": "Cheese", "description": "Add cheese"}, {"label": "Ham", "description": "Add ham"}, {"label": "Olives", "description": "Add olives"}, {"label": "Mushrooms", "description": "Add mushrooms"}}},
	{"question": "What's your pet's name?", "header": "Pet name", "multiSelect": false, "options": []m{{"label": "Biscuit", "description": "Suggestion: Biscuit"}, {"label": "Pepper", "description": "Suggestion: Pepper"}}},
}

func TestQuestionsAsked(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	write(t, p,
		user("Ask me three questions"),
		assistant(tool("q1", "AskUserQuestion", m{"questions": threeQuestions})),
	)
	r := NewReader()
	res, _ := r.Read("claude", p, dir, 0)
	qs := questionItems(res.Items)
	if len(qs) != 1 || qs[0].Done || qs[0].Tool != "q1" || len(qs[0].Questions) != 3 {
		t.Fatalf("asked: %+v", qs)
	}
	q := qs[0].Questions
	if q[0].Header != "Colour" || q[0].Multi || !q[1].Multi || len(q[1].Options) != 4 || q[1].Options[2].Label != "Olives" || q[2].Options[0].Description != "Suggestion: Biscuit" {
		t.Fatalf("questions = %+v", q)
	}
	if it, open := OpenQuestion(res, "q1"); !open || it.ID != qs[0].ID {
		t.Fatalf("OpenQuestion = %+v %v", it, open)
	}
	// Waiting: it comes again.
	again, _ := r.Read("claude", p, dir, res.Next)
	if len(questionItems(again.Items)) != 1 {
		t.Fatalf("an open question isn't sent again: %s", kinds(again.Items))
	}
	// Answered: the answers by question, as Claude Code keeps them.
	res2 := user([]m{{"type": "tool_result", "tool_use_id": "q1", "content": `The user answered: "Pick a colour:"="Green", "Pick your toppings:"="Cheese, Olives, anchovies", "What's your pet's name?"="Captain Whiskers". Read the answers carefully.`}})
	res2["toolUseResult"] = m{"questions": threeQuestions, "answers": m{"Pick a colour:": "Green", "Pick your toppings:": "Cheese, Olives, anchovies", "What's your pet's name?": "Captain Whiskers"}, "annotations": m{}}
	write(t, p, res2)
	settled, _ := r.Read("claude", p, dir, res.Next)
	qs = questionItems(settled.Items)
	if len(qs) != 1 || !qs[0].Done || qs[0].Error || len(qs[0].Answers) != 3 || qs[0].Answers[1] != "Cheese, Olives, anchovies" || qs[0].Answers[2] != "Captain Whiskers" {
		t.Fatalf("answered: %+v", qs)
	}
	if _, open := OpenQuestion(settled, "q1"); open {
		t.Fatal("an answered question is still open")
	}
	// Once the conversation moves on, it isn't sent again.
	write(t, p, assistant(m{"type": "text", "text": "You picked Green."}))
	moved, _ := r.Read("claude", p, dir, settled.Next)
	moved2, _ := r.Read("claude", p, dir, moved.Next)
	if n := len(questionItems(moved2.Items)); n != 0 {
		t.Fatalf("sent again after the conversation moved on: %s", kinds(moved2.Items))
	}
}

// Without the structured result, the answers are read from the text; a
// call the person cancelled (Esc) and one a prompt overtook are not
// answered.
func TestQuestionsAnsweredFromText(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	write(t, p,
		user("Ask me"),
		assistant(tool("q1", "AskUserQuestion", m{"questions": []m{{"question": "Should I say \"hi\" or bye?", "header": "Greeting", "options": []m{{"label": "hi"}, {"label": "bye"}}}}})),
		user([]m{{"type": "tool_result", "tool_use_id": "q1", "content": `Your questions have been answered: "Should I say \"hi\" or bye?"="bye". You can now continue.`}}),
		assistant(tool("q2", "AskUserQuestion", m{"questions": []m{{"question": "Again?", "options": []m{{"label": "yes"}, {"label": "no"}}}}})),
		user([]m{{"type": "tool_result", "tool_use_id": "q2", "is_error": true, "content": "The user doesn't want to proceed with this tool use."}}),
		assistant(tool("q3", "AskUserQuestion", m{"questions": []m{{"question": "Third?", "options": []m{{"label": "a"}, {"label": "b"}}}}})),
		user("never mind, just carry on"),
		// Nothing readable: an ordinary step.
		assistant(tool("q4", "AskUserQuestion", m{"questions": "garbled"})),
	)
	res, _ := NewReader().Read("claude", p, dir, 0)
	qs := questionItems(res.Items)
	if len(qs) != 3 {
		t.Fatalf("items: %s", kinds(res.Items))
	}
	if !qs[0].Done || len(qs[0].Answers) != 1 || qs[0].Answers[0] != "bye" {
		t.Errorf("from text: %+v", qs[0])
	}
	if !qs[1].Done || !qs[1].Error || qs[1].Answers != nil {
		t.Errorf("cancelled: %+v", qs[1])
	}
	if !qs[2].Done || !qs[2].Error {
		t.Errorf("overtaken: %+v", qs[2])
	}
	if last := res.Items[len(res.Items)-1]; last.Kind != "tools" || last.Items[0].Target != "AskUserQuestion" {
		t.Errorf("unreadable call = %+v", last)
	}
}

// Codex's request_user_input: questions by id, answered by id.
func TestCodexQuestions(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "rollout.jsonl")
	call := `{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"c1","arguments":"{\"questions\":[{\"id\":\"shape\",\"header\":\"Format\",\"question\":\"What first?\",\"options\":[{\"label\":\"Web app (Recommended)\",\"description\":\"Best balance\"},{\"label\":\"Spreadsheet\",\"description\":\"Fastest\"}]},{\"id\":\"scope\",\"header\":\"Records\",\"question\":\"How formal?\",\"options\":[{\"label\":\"Accountant-ready\"},{\"label\":\"Planning only\"}]}]}"}}`
	out := `{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"{\"answers\":{\"scope\":{\"answers\":[\"Planning only\"]},\"shape\":{\"answers\":[\"Web app (Recommended)\"]}}}"}}`
	if err := os.WriteFile(p, []byte(call+"\n"+out+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, _ := NewReader().Read("codex", p, dir, 0)
	qs := questionItems(res.Items)
	if len(qs) != 1 || !qs[0].Done || len(qs[0].Questions) != 2 || qs[0].Questions[1].ID != "scope" || qs[0].Answers[0] != "Web app (Recommended)" || qs[0].Answers[1] != "Planning only" {
		t.Fatalf("codex: %+v", qs)
	}
}
