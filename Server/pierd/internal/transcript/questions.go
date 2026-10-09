package transcript

import (
	"encoding/json"
	"regexp"
	"strings"
)

// Questions an agent asks the person with a form of its own: Claude Code's
// AskUserQuestion (one to four questions, each with its options, some
// multiple-choice, each with an "Other" the person types) and Codex's
// request_user_input. Each call is a "question" item carrying the
// questions; its result fills in what was answered, so an answer leaves a
// trace in the conversation. The box drives the agent's own form to
// answer one (box/answer.go).

// Question is one question of the form.
type Question struct {
	Question string   `json:"question"`
	Header   string   `json:"header,omitempty"`
	Multi    bool     `json:"multi,omitempty"`
	Options  []Option `json:"options"`
	// ID is Codex's name for the question, which its answers are keyed by.
	ID string `json:"id,omitempty"`
}

// Option is one of a question's choices.
type Option struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

const (
	maxQuestions = 8
	maxOptions   = 8
	maxQText     = 1000
	maxQLabel    = 200
)

// readQuestions reads a call's questions, capped.
func readQuestions(raw any) []Question {
	qs, _ := raw.([]any)
	var out []Question
	for _, x := range qs {
		m, _ := x.(map[string]any)
		if m == nil {
			continue
		}
		str := func(k string) string { s, _ := m[k].(string); return strings.TrimSpace(s) }
		q := Question{Question: clip(str("question"), maxQText), Header: clip(str("header"), maxQLabel), ID: clip(str("id"), maxQLabel)}
		q.Multi, _ = m["multiSelect"].(bool)
		opts, _ := m["options"].([]any)
		for _, o := range opts {
			om, _ := o.(map[string]any)
			label, _ := om["label"].(string)
			desc, _ := om["description"].(string)
			if label = strings.TrimSpace(label); label != "" {
				q.Options = append(q.Options, Option{Label: clip(label, maxQLabel), Description: clip(strings.TrimSpace(desc), maxQText)})
			}
			if len(q.Options) == maxOptions {
				break
			}
		}
		if q.Question == "" {
			continue
		}
		out = append(out, q)
		if len(out) == maxQuestions {
			break
		}
	}
	return out
}

// asked adds a question item for a call, or reports false when it asks
// nothing readable (it is then an ordinary step).
func (c *conv) asked(toolID string, raw any) bool {
	qs := readQuestions(raw)
	if len(qs) == 0 {
		return false
	}
	i := c.add(Item{Kind: "question", ID: c.id(), Tool: toolID, Questions: qs})
	if toolID != "" {
		if c.askCalls == nil {
			c.askCalls = map[string]int{}
		}
		c.askCalls[toolID] = i
		c.byTool[toolID] = -1
	}
	return true
}

// question is the open question item a call made, if it is still kept.
func (c *conv) question(toolID string) *Item {
	i, ok := c.askCalls[toolID]
	if !ok {
		return nil
	}
	delete(c.askCalls, toolID)
	it := c.at(i)
	if it == nil || it.Kind != "question" || it.Tool != toolID {
		return nil // rewound past it, or dropped off
	}
	return it
}

// settle marks a question item answered (or not), to be sent again.
func (c *conv) settle(it *Item) {
	it.Done = true
	it.resolved = c.base + len(c.items)
}

// answerPair is one "question"="answer" in Claude Code's result text.
var answerPair = regexp.MustCompile(`"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"`)

// claudeAnswered reads an AskUserQuestion's result: the answers Claude Code
// keeps beside it (toolUseResult.answers, by question), else the
// "question"="answer" pairs in its text. A failed call (the person pressed
// Esc) was not answered.
func (c *conv) claudeAnswered(toolID string, line []byte, text string, failed bool) {
	it := c.question(toolID)
	if it == nil {
		return
	}
	defer c.settle(it)
	if failed {
		it.Error = true
		return
	}
	var x struct {
		Result struct {
			Answers map[string]any `json:"answers"`
		} `json:"toolUseResult"`
	}
	byQ := map[string]string{}
	if json.Unmarshal(line, &x) == nil {
		for q, a := range x.Result.Answers {
			byQ[q] = answerString(a)
		}
	}
	if len(byQ) == 0 {
		for _, m := range answerPair.FindAllStringSubmatch(text, -1) {
			byQ[unquote(m[1])] = unquote(m[2])
		}
	}
	it.Answers = make([]string, len(it.Questions))
	got := false
	for i, q := range it.Questions {
		if a, ok := byQ[q.Question]; ok {
			it.Answers[i] = clip(a, maxQText)
			got = got || a != ""
		}
	}
	if !got {
		it.Answers = nil
		it.Error = true
	}
}

// codexAnswered reads request_user_input's output: {"answers": {id:
// {"answers": [...]}}}.
func (c *conv) codexAnswered(toolID, output string) {
	it := c.question(toolID)
	if it == nil {
		return
	}
	defer c.settle(it)
	var r struct {
		Answers map[string]struct {
			Answers []string `json:"answers"`
		} `json:"answers"`
	}
	if json.Unmarshal([]byte(output), &r) != nil || len(r.Answers) == 0 {
		it.Error = true
		return
	}
	it.Answers = make([]string, len(it.Questions))
	for i, q := range it.Questions {
		it.Answers[i] = clip(strings.Join(r.Answers[q.ID].Answers, ", "), maxQText)
	}
}

// closeQuestions settles the questions still open once a prompt arrives
// (the person answered with words, or interrupted): none waits for ever.
func (c *conv) closeQuestions() {
	for id := range c.askCalls {
		if it := c.question(id); it != nil && !it.Done {
			it.Error = true
			c.settle(it)
		}
	}
}

func answerString(a any) string {
	switch v := a.(type) {
	case string:
		return v
	case []any:
		var parts []string
		for _, p := range v {
			if s, ok := p.(string); ok {
				parts = append(parts, s)
			}
		}
		return strings.Join(parts, ", ")
	}
	return ""
}

func unquote(s string) string {
	if u, err := jsonUnquote(`"` + s + `"`); err == nil {
		return u
	}
	return s
}

func jsonUnquote(s string) (string, error) {
	var out string
	err := json.Unmarshal([]byte(s), &out)
	return out, err
}

// OpenQuestion is the question item a call made, while it waits for its
// answer: what the box needs to answer it. ok is false once it is answered
// or when it isn't in the conversation.
func OpenQuestion(r Result, toolID string) (Item, bool) {
	for i := len(r.Items) - 1; i >= 0; i-- {
		it := r.Items[i]
		if it.Kind == "question" && it.Tool == toolID {
			return it, !it.Done
		}
	}
	return Item{}, false
}
