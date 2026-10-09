// Package boxapi is what the push engine reads from pierd: the same routes the app calls, served in-process by
// pierd's local handler (no socket, no TLS).
package boxapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Ask struct {
	Tool    string `json:"tool,omitempty"`
	Input   string `json:"input,omitempty"`
	Why     string `json:"why,omitempty"`
	Message string `json:"message,omitempty"`
}

// Summary is "Bash  rm -rf build".
func (a *Ask) Summary() string {
	if a == nil {
		return ""
	}
	var p []string
	for _, s := range []string{a.Tool, a.Input} {
		if s != "" {
			p = append(p, s)
		}
	}
	return strings.Join(p, "  ")
}

type Session struct {
	Name       string    `json:"name"`
	Location   string    `json:"location"`
	Dir        string    `json:"dir"`
	Command    string    `json:"command"`
	Created    time.Time `json:"created"`
	Exited     bool      `json:"exited"`
	Agent      string    `json:"agent"`
	AgentState string    `json:"agent_state"`
	StateSince time.Time `json:"state_since"`
	StateSeq   uint64    `json:"state_seq"`
	Title      string    `json:"title"`
	Service    string    `json:"service"`
	Ask        *Ask      `json:"ask,omitempty"`
	// Chat: a conversation that belongs to no project (no location).
	Chat bool `json:"chat,omitempty"`
}

type Worktree struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Main bool   `json:"main"`
}

type Location struct {
	Name      string     `json:"name"`
	Path      string     `json:"path"`
	Worktrees []Worktree `json:"worktrees"`
}

type ReviewItem struct {
	Location string `json:"location"`
	Worktree string `json:"worktree"`
	Path     string `json:"path"`
	Session  string `json:"session"`
	Added    int    `json:"added"`
	Removed  int    `json:"removed"`
}

type Draft struct {
	Agent  string `json:"agent"`
	Status *struct {
		Word    string `json:"word"`
		Elapsed string `json:"elapsed"`
	} `json:"status,omitempty"`
}

type Info struct {
	Name string `json:"name"`
}

// Event is pierd's event envelope (docs/API.md 7.2).
type Event struct {
	Seq    uint64         `json:"seq"`
	Type   string         `json:"type"`
	Time   time.Time      `json:"time"`
	Origin string         `json:"origin"`
	Error  string         `json:"error,omitempty"`
	Data   map[string]any `json:"data"`
}

func (e Event) Str(k string) string {
	s, _ := e.Data[k].(string)
	return s
}

// API is what the engine needs from the box (an interface so tests can fake it).
type API interface {
	Info(ctx context.Context) (Info, error)
	Sessions(ctx context.Context) ([]Session, error)
	Locations(ctx context.Context) ([]Location, error)
	Screen(ctx context.Context, session string) (string, error)
	Review(ctx context.Context) ([]ReviewItem, error)
	Draft(ctx context.Context, session string) (Draft, error)
	LastMessage(ctx context.Context, session string) string
	Background(ctx context.Context, session string) []string
	OpenQuestion(ctx context.Context, session string) []string
}

type Client struct {
	http *http.Client
}

// New reads from h, pierd's local API handler, in-process.
func New(h http.Handler) *Client {
	return &Client{http: &http.Client{Transport: handlerTransport{h}}}
}

// handlerTransport answers a request by calling a handler directly.
type handlerTransport struct{ h http.Handler }

func (t handlerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	w := &memResponse{header: http.Header{}, status: http.StatusOK}
	t.h.ServeHTTP(w, req)
	return &http.Response{
		StatusCode: w.status, Status: http.StatusText(w.status), Header: w.header,
		Body: io.NopCloser(&w.body), ContentLength: int64(w.body.Len()), Request: req,
		Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1,
	}, nil
}

// memResponse is an http.ResponseWriter that keeps what is written.
type memResponse struct {
	header http.Header
	body   bytes.Buffer
	status int
	wrote  bool
}

func (m *memResponse) Header() http.Header { return m.header }

func (m *memResponse) WriteHeader(status int) {
	if !m.wrote {
		m.status, m.wrote = status, true
	}
}

func (m *memResponse) Write(p []byte) (int, error) {
	m.wrote = true
	return m.body.Write(p)
}

func (c *Client) get(ctx context.Context, path string, out any, timeout time.Duration) error {
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://pierd"+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("pierd %s: %d %s", path, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return json.Unmarshal(b, out)
}

func (c *Client) Info(ctx context.Context) (i Info, err error) {
	err = c.get(ctx, "/v1/info", &i, 5*time.Second)
	return
}

func (c *Client) Sessions(ctx context.Context) (s []Session, err error) {
	err = c.get(ctx, "/v1/sessions", &s, 10*time.Second)
	return
}

func (c *Client) Locations(ctx context.Context) (l []Location, err error) {
	err = c.get(ctx, "/v1/locations", &l, 10*time.Second)
	return
}

func (c *Client) Screen(ctx context.Context, session string) (string, error) {
	var v struct {
		Screen string `json:"screen"`
	}
	err := c.get(ctx, "/v1/sessions/"+url.PathEscape(session)+"/screen", &v, 5*time.Second)
	return v.Screen, err
}

func (c *Client) Review(ctx context.Context) (r []ReviewItem, err error) {
	err = c.get(ctx, "/v1/review", &r, 15*time.Second)
	return
}

func (c *Client) Draft(ctx context.Context, session string) (d Draft, err error) {
	err = c.get(ctx, "/v1/sessions/"+url.PathEscape(session)+"/draft", &d, 5*time.Second)
	return
}

// LastMessage is the agent's last plain-text reply in the session's transcript ("" when none or unreadable).
func (c *Client) LastMessage(ctx context.Context, session string) string {
	var page struct {
		Items []struct {
			Kind string `json:"kind"`
			Text string `json:"text"`
		} `json:"items"`
	}
	if err := c.get(ctx, "/v1/sessions/"+url.PathEscape(session)+"/transcript?since=0", &page, 4*time.Second); err != nil {
		return ""
	}
	for i := len(page.Items) - 1; i >= 0; i-- {
		if it := page.Items[i]; it.Kind == "text" && strings.TrimSpace(it.Text) != "" {
			return it.Text
		}
		if page.Items[i].Kind == "user" {
			break // only this turn's reply
		}
	}
	return ""
}

// Background lists what the agent still runs after its turn (background shells, monitors, subagents): the transcript's
// signals and crew only (`since` past the end returns no items). nil when none or unreadable.
func (c *Client) Background(ctx context.Context, session string) []string {
	var page struct {
		Crew []struct {
			Name, Doing, State string
		} `json:"crew"`
		Signals struct {
			Background []struct {
				Kind, Command, Label, State string
			} `json:"background"`
		} `json:"signals"`
	}
	if err := c.get(ctx, "/v1/sessions/"+url.PathEscape(session)+"/transcript?since=2000000000", &page, 4*time.Second); err != nil {
		return nil
	}
	var out []string
	for _, m := range page.Crew {
		if m.State == "running" {
			out = append(out, strings.TrimSpace(m.Name+" "+m.Doing))
		}
	}
	for _, j := range page.Signals.Background {
		if j.State == "running" {
			if j.Label != "" {
				out = append(out, j.Label)
			} else {
				out = append(out, JobTitle(j.Command))
			}
		}
	}
	return out
}

// OpenQuestion is what the agent asks right now: the choices of the transcript's last "question" item while it is
// unanswered, when the form is one question with a single pick (the labels, in order). nil when there is no open
// question, the form has several questions or several picks, or the transcript is unreadable. The phone shows these as
// the notification's buttons (docs/PUSH.md 4.3).
func (c *Client) OpenQuestion(ctx context.Context, session string) []string {
	var page struct {
		Items []struct {
			Kind      string   `json:"kind"`
			Done      bool     `json:"done"`
			Answers   []string `json:"answers"`
			Questions []struct {
				Multi   bool `json:"multi"`
				Options []struct {
					Label string `json:"label"`
				} `json:"options"`
			} `json:"questions"`
		} `json:"items"`
	}
	if err := c.get(ctx, "/v1/sessions/"+url.PathEscape(session)+"/transcript?since=0", &page, 4*time.Second); err != nil {
		return nil
	}
	for i := len(page.Items) - 1; i >= 0; i-- {
		it := page.Items[i]
		if it.Kind != "question" {
			continue
		}
		if it.Done || it.Answers != nil || len(it.Questions) != 1 || it.Questions[0].Multi {
			return nil
		}
		var out []string
		for _, o := range it.Questions[0].Options {
			if l := strings.TrimSpace(o.Label); l != "" {
				out = append(out, l)
			}
		}
		return out
	}
	return nil
}

// JobTitle is a background command without its `cd <dir>;` prefix and output redirections, first line.
func JobTitle(cmd string) string {
	c := strings.TrimSpace(strings.SplitN(cmd, "\n", 2)[0])
	if strings.HasPrefix(c, "cd ") {
		if i := strings.IndexAny(c, ";&"); i > 0 {
			c = strings.TrimLeft(c[i:], ";& ")
		}
	}
	for _, sep := range []string{" > ", " 2> ", " >> ", " | "} {
		if i := strings.Index(c, sep); i > 0 {
			c = c[:i]
		}
	}
	return strings.TrimSpace(c)
}
