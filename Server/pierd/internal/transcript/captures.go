package transcript

import (
	"regexp"
	"strings"
)

// Captures are the pictures and recordings an agent hands the person to
// show its work, with `pierd capture add`: the box keeps the file
// (internal/box/captures.go) and the command prints "[pier capture ID]",
// which the call's result carries into the agent's own record. A result
// that names captures becomes a "capture" item where it happened, so the
// app shows them in that turn. The record holds only their IDs: the box
// fills in what each is when it sends the item, and leaves out an ID it
// never kept (a marker some other output happened to print).

// CaptureRef is one capture a capture item names: its ID from the record,
// the rest from the box.
type CaptureRef struct {
	ID string `json:"id"`
	// Kind is "before", "after" or empty; Caption what the agent said it
	// shows.
	Kind    string `json:"kind,omitempty"`
	Caption string `json:"caption,omitempty"`
	// Type is the file's media type (image/png, video/mp4); Width and
	// Height a picture's pixels, when the box could read them.
	Type   string `json:"type,omitempty"`
	Width  int    `json:"width,omitempty"`
	Height int    `json:"height,omitempty"`
	Size   int    `json:"size,omitempty"`
	At     int64  `json:"at,omitempty"`
	// Thumb says the box keeps a small copy (…/captures/{id}?thumb=1).
	Thumb bool `json:"thumb,omitempty"`
}

// captureMarker is what `pierd capture add` prints for each capture it
// kept: an ID of 12 hex digits, in words no other output prints.
var captureMarker = regexp.MustCompile(`\[pier capture ([0-9a-f]{12})\]`)

// CaptureMarker is the mark pierd prints for the capture id.
func CaptureMarker(id string) string { return "[pier capture " + id + "]" }

// captured adds a capture item for the captures a call's result names,
// each once in a conversation: an output read again (a log printed twice)
// names them again.
func (c *conv) captured(text string) {
	if !strings.Contains(text, "[pier capture ") {
		return
	}
	var refs []CaptureRef
	for _, m := range captureMarker.FindAllStringSubmatch(text, -1) {
		if c.captures[m[1]] {
			continue
		}
		if c.captures == nil {
			c.captures = map[string]bool{}
		}
		c.captures[m[1]] = true
		refs = append(refs, CaptureRef{ID: m[1]})
	}
	if len(refs) > 0 {
		c.add(Item{Kind: "capture", ID: c.id(), Captures: refs})
	}
}
