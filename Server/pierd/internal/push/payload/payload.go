// Package payload builds the JSON bodies sent to APNs. Field names and shapes are the contract in docs/PUSH.md and
// must match the app (category ids, custom keys) and ActivityKit's decoding of SessionActivityAttributes.ContentState.
package payload

import (
	"encoding/json"
	"fmt"
	"math"
	"time"
)

// Alert categories registered by the app.
const (
	CategoryNeedsYou         = "NEEDS_YOU"
	CategoryNeedsYouQuestion = "NEEDS_YOU_QUESTION"
	CategoryFinished         = "FINISHED"
)

// CategoryNeedsYouChoice is the category of a waiting alert that carries n choices (2 to 4): the app registers one per
// count, with buttons "1" … "n" and "Abrir", so the choices can be picked even where the service extension (which
// swaps in a category whose buttons carry the choices' words) does not run. See docs/PUSH.md 4.3.
func CategoryNeedsYouChoice(n int) string { return fmt.Sprintf("NEEDS_YOU_CHOICE_%d", n) }

// referenceDate is Foundation's reference date, 2001-01-01T00:00:00Z, as a Unix time.
const referenceDate = 978307200

// EncodeDate is how a Date inside the content-state is written. The app's ContentState has a custom Codable that
// reads Unix seconds (docs/PUSH.md "iOS expectations"), so "unix" is the default; "reference" (seconds since
// 2001-01-01, Swift's default Date coding) stays available through config for a build without it. Millisecond precision.
func EncodeDate(t time.Time, epoch string) float64 {
	secs := float64(t.UnixMilli()) / 1000
	if epoch == "reference" {
		secs -= referenceDate
	}
	return math.Round(secs*1000) / 1000
}

type AlertText struct {
	Title    string `json:"title"`
	Subtitle string `json:"subtitle,omitempty"`
	Body     string `json:"body"`
}

type AlertAPS struct {
	Alert             AlertText `json:"alert"`
	Category          string    `json:"category,omitempty"`
	ThreadID          string    `json:"thread-id"`
	Sound             string    `json:"sound,omitempty"`
	InterruptionLevel string    `json:"interruption-level,omitempty"`
	MutableContent    int       `json:"mutable-content,omitempty"`
}

// Alert is a visible push: `aps` plus the custom keys the app reads (box, session, location, hasMenu, options).
type Alert struct {
	APS      AlertAPS `json:"aps"`
	Box      string   `json:"box"`
	Session  string   `json:"session"`
	Location string   `json:"location"`
	HasMenu  *bool    `json:"hasMenu,omitempty"`
	// Options are the choices a waiting agent offers, in order, for the phone to show as the notification's buttons
	// (its service extension turns them into a category); OptionsKind says where they come from: "question" (the
	// transcript's form, answered by label) or "menu" (numbered rows on screen, answered by digit). See docs/PUSH.md 4.3.
	Options     []string `json:"options,omitempty"`
	OptionsKind string   `json:"optionsKind,omitempty"`
}

type AlertParams struct {
	Box, Session, Location string
	Title, Subtitle, Body  string
	Category               string
	HasMenu                *bool
	Options                []string
	OptionsKind            string
	// Level is "time-sensitive" (waiting), "active" (finished) or "passive" (working).
	Level string
	Sound bool
}

func BuildAlert(p AlertParams) ([]byte, error) {
	a := Alert{
		APS: AlertAPS{
			Alert: AlertText{Title: p.Title, Subtitle: p.Subtitle, Body: p.Body}, Category: p.Category, ThreadID: p.Box + "/" + p.Session,
			InterruptionLevel: p.Level, MutableContent: 1,
		},
		Box: p.Box, Session: p.Session, Location: p.Location, HasMenu: p.HasMenu, Options: p.Options, OptionsKind: p.OptionsKind,
	}
	if p.Sound {
		a.APS.Sound = "default"
	}
	return json.Marshal(a)
}

// BuildTest is the payload of POST /v1/push/test.
func BuildTest(box, title, body string) ([]byte, error) {
	return json.Marshal(map[string]any{
		"aps": AlertAPS{Alert: AlertText{Title: title, Body: body}, ThreadID: box + "/test", Sound: "default"},
		"box": box,
	})
}

// ContentState mirrors SessionActivityAttributes.ContentState (App/Shared/LiveActivities). All keys are always
// present (nil optionals are JSON null) so the synthesized Codable decoding sees what it expects.
type ContentState struct {
	Phase   string  `json:"phase"` // starting | running | waiting | finished | ended
	Since   float64 `json:"since"` // Swift Date: see EncodeDate
	Step    *string `json:"step"`
	Ask     *string `json:"ask"`
	HasMenu bool    `json:"hasMenu"`
	Added   *int    `json:"added"`
	Removed *int    `json:"removed"`
	Reply   *string `json:"reply"` // the agent's last reply, a few lines (finished)
}

// Attributes mirrors SessionActivityAttributes (only used to start an activity by push).
type Attributes struct {
	Box     string  `json:"box"`
	Session string  `json:"session"`
	Title   string  `json:"title"`
	Project string  `json:"project"`
	Agent   *string `json:"agent"`
}

type ActivityAPS struct {
	Timestamp      int64        `json:"timestamp"`
	Event          string       `json:"event"` // start | update | end
	ContentState   ContentState `json:"content-state"`
	StaleDate      *int64       `json:"stale-date,omitempty"`
	DismissalDate  *int64       `json:"dismissal-date,omitempty"`
	AttributesType string       `json:"attributes-type,omitempty"`
	Attributes     *Attributes  `json:"attributes,omitempty"`
	Alert          *AlertText   `json:"alert,omitempty"`
}

type Activity struct {
	APS ActivityAPS `json:"aps"`
}

type ActivityParams struct {
	Event         string // start | update | end
	Now           time.Time
	State         ContentState
	Alert         *AlertText
	StaleAfter    time.Duration // 0 = none
	DismissAt     *time.Time    // end only
	Attributes    *Attributes   // start only
	AttributeType string
}

func BuildActivity(p ActivityParams) ([]byte, error) {
	a := Activity{APS: ActivityAPS{Timestamp: p.Now.Unix(), Event: p.Event, ContentState: p.State, Alert: p.Alert}}
	if p.StaleAfter > 0 {
		v := p.Now.Add(p.StaleAfter).Unix()
		a.APS.StaleDate = &v
	}
	if p.DismissAt != nil {
		v := p.DismissAt.Unix()
		a.APS.DismissalDate = &v
	}
	if p.Event == "start" {
		a.APS.Attributes = p.Attributes
		a.APS.AttributesType = p.AttributeType
	}
	return json.Marshal(a)
}

// BuildWidget asks WidgetKit to reload the widget's timelines (apns-push-type: widgets).
func BuildWidget() []byte { return []byte(`{"aps":{"content-changed":true}}`) }
