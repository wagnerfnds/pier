package box

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"pier/pierd/internal/doctor"
	"pier/pierd/internal/events"
)

// Doer sends a request to a box: a wire.Client from a laptop, or a Local
// client on the box itself.
type Doer interface {
	DoWithHeader(ctx context.Context, method, path string, body io.Reader, header http.Header) (*http.Response, error)
}

// Client calls a box's API. Origin names the tool the calls are made for;
// it defaults to $PIER_ORIGIN.
type Client struct {
	Doer   Doer
	Origin string
}

func NewClient(d Doer) *Client {
	return &Client{Doer: d, Origin: os.Getenv("PIER_ORIGIN")}
}

// Call makes a request to the box API and decodes its JSON answer into out.
func (c *Client) Call(ctx context.Context, method, path string, in, out any) error {
	return c.call(ctx, method, path, in, out)
}

func (c *Client) call(ctx context.Context, method, path string, in, out any) error {
	return c.callHeader(ctx, method, path, nil, in, out)
}

func (c *Client) callHeader(ctx context.Context, method, path string, extra http.Header, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	header := http.Header{"Content-Type": {"application/json"}}
	for k, v := range extra {
		header[k] = v
	}
	if validOrigin.MatchString(c.Origin) {
		header.Set(OriginHeader, c.Origin)
	}
	resp, err := c.Doer.DoWithHeader(ctx, method, path, body, header)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		var e struct {
			Error string `json:"error"`
		}
		if json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&e) == nil && e.Error != "" {
			return errors.New(e.Error)
		}
		return fmt.Errorf("box replied %s", resp.Status)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) Locations(ctx context.Context) (out []Location, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/locations", nil, &out)
}

func (c *Client) AddLocation(ctx context.Context, name, path string) (out Location, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/locations", map[string]string{"name": name, "path": path}, &out)
}

func (c *Client) RemoveLocation(ctx context.Context, name string) error {
	return c.call(ctx, http.MethodDelete, "/v1/locations/"+url.PathEscape(name), nil, nil)
}

// Send types a prompt into a session and returns the turn it started (or
// queued) and the box's time. An older box returns only its time, which
// callers wait from rather than their own clock.
func (c *Client) Send(ctx context.Context, session string, req SendRequest) (out SendResult, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/sessions/"+url.PathEscape(session)+"/send", req, &out)
}

// Turns lists a session's last turns, oldest first.
func (c *Client) Turns(ctx context.Context, session string, limit int) (out []Turn, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/sessions/"+url.PathEscape(session)+"/turns?limit="+strconv.Itoa(limit), nil, &out)
}

// Wait blocks until the session's agent reports one of states after after.
func (c *Client) Wait(ctx context.Context, session string, states []string, after time.Time, timeout time.Duration) (out WaitResult, err error) {
	q := url.Values{"for": {strings.Join(states, ",")}, "timeout": {timeout.String()}}
	if !after.IsZero() {
		q.Set("after", after.UTC().Format(time.RFC3339Nano))
	}
	return out, c.call(ctx, http.MethodGet, "/v1/sessions/"+url.PathEscape(session)+"/wait?"+q.Encode(), nil, &out)
}

func (c *Client) Exec(ctx context.Context, req ExecRequest) (out ExecResult, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/exec", req, &out)
}

func (c *Client) AddTask(ctx context.Context, req TaskRequest) (out Task, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/tasks", req, &out)
}

func (c *Client) AddWorktree(ctx context.Context, location string, req WorktreeRequest) (out Worktree, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/locations/"+url.PathEscape(location)+"/worktrees", req, &out)
}

// RemoveOptions change how a worktree is removed. DeleteBranch is for
// throwaway worktrees only; a person's branch outlives its worktree.
type RemoveOptions struct {
	Force        bool
	DeleteBranch bool
}

// RemoveWorktree removes a worktree, or starts archiving it: archive is the
// script the box runs first, removing the worktree only if it succeeds.
func (c *Client) RemoveWorktree(ctx context.Context, location, name string, opts RemoveOptions) (archive string, err error) {
	path := "/v1/locations/" + url.PathEscape(location) + "/worktrees/" + url.PathEscape(name)
	q := url.Values{}
	if opts.Force {
		q.Set("force", "1")
	}
	if opts.DeleteBranch {
		q.Set("delete_branch", "1")
	}
	if len(q) > 0 {
		path += "?" + q.Encode()
	}
	var out struct {
		Archive string `json:"archive"`
	}
	err = c.call(ctx, http.MethodDelete, path, nil, &out)
	return out.Archive, err
}

func (c *Client) Sessions(ctx context.Context) (out []Session, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/sessions", nil, &out)
}

// StartSession starts a session: a command, or an agent with its prompt.
func (c *Client) StartSession(ctx context.Context, req SessionRequest) (out Session, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/sessions", req, &out)
}

func (c *Client) Screen(ctx context.Context, name string, history int) (string, error) {
	var out struct{ Screen string }
	err := c.call(ctx, http.MethodGet, "/v1/sessions/"+url.PathEscape(name)+"/screen?history="+strconv.Itoa(history), nil, &out)
	return out.Screen, err
}

func (c *Client) RenameSession(ctx context.Context, name, title string) (out Session, err error) {
	return out, c.call(ctx, http.MethodPatch, "/v1/sessions/"+url.PathEscape(name), map[string]string{"title": title}, &out)
}

func (c *Client) KillSession(ctx context.Context, name string) error {
	return c.call(ctx, http.MethodDelete, "/v1/sessions/"+url.PathEscape(name), nil, nil)
}

func (c *Client) Stats(ctx context.Context) (out Stats, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/stats", nil, &out)
}

func (c *Client) Services(ctx context.Context) (out []Service, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/services", nil, &out)
}

func (c *Client) Doctor(ctx context.Context) (out []doctor.Check, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/doctor", nil, &out)
}

func (c *Client) Info(ctx context.Context) (out Info, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/info", nil, &out)
}

func (c *Client) LocationConfig(ctx context.Context, location string) (out Config, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/locations/"+url.PathEscape(location)+"/config", nil, &out)
}

// SetLocationConfig replaces this box's own config for a location.
func (c *Client) SetLocationConfig(ctx context.Context, location string, local RepoConfig) (out Config, err error) {
	return out, c.call(ctx, http.MethodPut, "/v1/locations/"+url.PathEscape(location)+"/config", map[string]RepoConfig{"local": local}, &out)
}

// TrustRepoConfig lets the box run a location's repository config, as long
// as the file still has the hash that was reviewed.
func (c *Client) TrustRepoConfig(ctx context.Context, location, hash string) (out Config, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/locations/"+url.PathEscape(location)+"/config/trust", map[string]string{"hash": hash}, &out)
}

// UntrustRepoConfig stops the box running a location's repository config.
func (c *Client) UntrustRepoConfig(ctx context.Context, location string) (out Config, err error) {
	return out, c.call(ctx, http.MethodDelete, "/v1/locations/"+url.PathEscape(location)+"/config/trust", nil, &out)
}

func (c *Client) WorktreeServices(ctx context.Context, location, worktree string) (out []ServiceStatus, err error) {
	return out, c.call(ctx, http.MethodGet, "/v1/locations/"+url.PathEscape(location)+"/worktrees/"+url.PathEscape(worktree)+"/services", nil, &out)
}

// ServiceAction starts, stops or restarts one of a worktree's services.
func (c *Client) ServiceAction(ctx context.Context, location, worktree, service, action string) (out ServiceStatus, err error) {
	return out, c.call(ctx, http.MethodPost, "/v1/locations/"+url.PathEscape(location)+"/worktrees/"+url.PathEscape(worktree)+"/services/"+url.PathEscape(service)+"/"+url.PathEscape(action), nil, &out)
}

func (c *Client) Emit(ctx context.Context, typ string, data map[string]any) error {
	return c.call(ctx, http.MethodPost, "/v1/events", map[string]any{"type": typ, "data": data}, nil)
}

// Events calls fn for each box event until ctx ends or the stream breaks.
func (c *Client) Events(ctx context.Context, fn func(events.Event)) error {
	return c.EventsSince(ctx, -1, fn)
}

// EventsSince is Events starting after the event numbered since, so a
// reconnecting caller misses nothing the box's journal still holds (a
// negative since starts from now; an older box ignores it).
func (c *Client) EventsSince(ctx context.Context, since int64, fn func(events.Event)) error {
	path := "/v1/events"
	if since >= 0 {
		path += "?since=" + strconv.FormatInt(since, 10)
	}
	resp, err := c.Doer.DoWithHeader(ctx, http.MethodGet, path, nil, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("box replied %s", resp.Status)
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		var e events.Event
		if line := bytes.TrimSpace(scanner.Bytes()); len(line) > 0 && json.Unmarshal(line, &e) == nil {
			fn(e)
		}
	}
	if ctx.Err() != nil {
		return nil
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return io.ErrUnexpectedEOF
}

// Local reaches pierd on the box through its Unix socket.
type Local struct{ http *http.Client }

func NewLocal(socket string) *Local {
	return &Local{http: &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		},
	}}}
}

func (l *Local) DoWithHeader(ctx context.Context, method, path string, body io.Reader, header http.Header) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://pierd"+path, body)
	if err != nil {
		return nil, err
	}
	for k, v := range header {
		req.Header[k] = v
	}
	return l.http.Do(req)
}
