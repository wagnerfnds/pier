package transcript

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
)

// A conversation's history beyond what is followed live: older items a
// page at a time, the helpers' (subagents') own conversations, and a copy
// of Claude Code's record up to a point, which a fork resumes.

const (
	// maxSpan is the most of a file read back for one page of older items.
	maxSpan = 64 << 20
)

func parserFor(source string) parser {
	if source == "codex" {
		return &codexParser{}
	}
	return &claudeParser{}
}

// Before reads a page of older items: at most limit, made by lines that
// start before the offset before, newest last. Each is named by where its
// line starts, so pages never repeat one, and none are kept. More says
// earlier ones remain.
func Before(source, path, dir string, before int64, limit int) (Result, error) {
	f, err := os.Open(path)
	if err != nil {
		return Result{}, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return Result{}, err
	}
	if before <= 0 || before > st.Size() {
		before = st.Size()
	}
	if limit <= 0 || limit > keep {
		limit = keep
	}
	for span := int64(1 << 20); ; span *= 4 {
		start := max(0, before-span)
		// One more than asked: read from the middle of a file, the first
		// item may be the tail of a group begun before it.
		c := &conv{source: source, dir: dir, side: isHelper(path), paged: true, limit: limit + 1, p: parserFor(source), byTool: map[string]int{}, crewByID: map[string]int{}}
		if err := c.scan(f, start, before); err != nil {
			return Result{}, err
		}
		if len(c.items) > limit || start == 0 || span >= maxSpan {
			items := c.items
			more := start > 0 || c.base > 0
			if len(items) > limit || (start > 0 && len(items) > 0) {
				items = items[1:]
			}
			// Every older item has one after it, so its calls are done.
			for i := range items {
				if items[i].Kind == "tools" || items[i].Kind == "artifact" {
					items[i].Done, items[i].pending = true, nil
				}
			}
			return Result{Source: source, Items: append([]Item{}, items...), Crew: []CrewMember{}, More: more}, nil
		}
	}
}

// scan parses the lines that start in [from, to): from the first whole
// line at or after from.
func (c *conv) scan(f *os.File, from, to int64) error {
	if _, err := f.Seek(from, io.SeekStart); err != nil {
		return err
	}
	r := bufio.NewReaderSize(f, 64<<10)
	off := from
	if from > 0 { // the middle of a line: skip to the next
		n, err := skipLine(r)
		off += n
		if err != nil {
			return nil
		}
	}
	var line []byte
	for off < to {
		c.lineOff = off
		line = line[:0]
		over := false
		for {
			chunk, err := r.ReadSlice('\n')
			off += int64(len(chunk))
			if !over && len(line)+len(chunk) <= maxLine {
				line = append(line, chunk...)
			} else {
				over, line = true, line[:0]
			}
			if err == bufio.ErrBufferFull {
				continue
			}
			if err != nil {
				return nil // EOF: a line still being written is left for later
			}
			break
		}
		if t := bytes.TrimSpace(line); !over && len(t) > 0 && t[0] == '{' {
			c.p.line(c, t)
		}
	}
	return nil
}

func skipLine(r *bufio.Reader) (int64, error) {
	var n int64
	for {
		chunk, err := r.ReadSlice('\n')
		n += int64(len(chunk))
		if err == bufio.ErrBufferFull {
			continue
		}
		return n, err
	}
}

// Helper is one of a session's helpers (a subagent): its own conversation
// is the file agent-<ID>.jsonl beside the session's.
type Helper struct {
	ID string `json:"id"`
	// Tool is the call that started it (Task or Agent), when known.
	Tool   string `json:"tool,omitempty"`
	Type   string `json:"type,omitempty"`
	Name   string `json:"name"`
	Prompt string `json:"prompt,omitempty"`
	// Started and Updated are when it began and last wrote, in ms.
	Started int64 `json:"started"`
	Updated int64 `json:"updated"`
	// Depth is 1 for the session's own helpers, 2 for theirs.
	Depth      int  `json:"depth,omitempty"`
	Background bool `json:"background,omitempty"`
	// State is running or finished.
	State string `json:"state"`
}

// isHelper says a file is a helper's own record.
func isHelper(path string) bool { return filepath.Base(filepath.Dir(path)) == "subagents" }

// ErrNoEntry is a fork point the record doesn't hold.
var ErrNoEntry = errors.New("that message is no longer in the agent's record")

// rewound drops what a rewind took back: a prompt that picks up where an
// earlier one did (Claude Code's /rewind, or Esc Esc) replaces it and
// everything after it, as the agent's own conversation now does.
func (c *conv) rewound() {
	k, ok := c.prompts[c.lineParent]
	if c.lineParent == "" || !ok || k < c.base || k >= c.base+len(c.items) {
		return
	}
	c.items = c.items[:k-c.base]
	// What was sent is no longer the conversation: the app reads it afresh.
	c.rev++
	for id, i := range c.byTool {
		if i >= k {
			delete(c.byTool, id)
		}
	}
	for p, i := range c.prompts {
		if i >= k {
			delete(c.prompts, p)
		}
	}
	for id, call := range c.artCalls {
		if call.item >= k {
			delete(c.artCalls, id)
		}
	}
}

// prompted notes where the prompt at index i picked up.
func (c *conv) prompted(i int) {
	if c.lineParent == "" {
		return
	}
	if c.prompts == nil {
		c.prompts = map[string]int{}
	}
	for p, j := range c.prompts {
		if j < c.base { // dropped off: forget it
			delete(c.prompts, p)
		}
	}
	c.prompts[c.lineParent] = i
}
