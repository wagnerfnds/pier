package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"pier/pierd/internal/groups"
)

// GitHub, through the box's own gh: the repositories of the account gh is
// signed in to, to bring one onto the box. Nothing here holds a token; gh
// does, as the box's user set it up (`gh auth login`).

// GitHubRepo is one repository of GET /v1/github/repos.
type GitHubRepo struct {
	Slug        string    `json:"slug"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitempty"`
	URL         string    `json:"url"`
	Private     bool      `json:"private,omitempty"`
	Fork        bool      `json:"fork,omitempty"`
	Archived    bool      `json:"archived,omitempty"`
	Language    string    `json:"language,omitempty"`
	UpdatedAt   time.Time `json:"updated_at"`
	// Location names the location this repository already is on the box.
	Location string `json:"location,omitempty"`
}

// GitHubRepos is the answer of GET /v1/github/repos.
type GitHubRepos struct {
	// Login is the account gh is signed in to; Owner whose repositories
	// these are (Login unless ?owner= named an organisation).
	Login string `json:"login"`
	Owner string `json:"owner"`
	// Owners are the login and its organisations, to choose from.
	Owners []string     `json:"owners"`
	Repos  []GitHubRepo `json:"repos"`
}

var (
	errGHMissing = errors.New("gh (GitHub CLI) is not installed on this box; install it and run `gh auth login` there")
	errGHAuth    = errors.New("gh is not signed in on this box; run `gh auth login` there")
	ghOwner      = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`)
)

// gh runs the GitHub CLI and returns its standard output: the gh pierd finds
// as the person's terminal would (agentpath: ~/.local/bin, where pierd
// installs it, included), else the one the user's login shell has on PATH.
// The same gh doctor and the sign-in see, so one installed from the app
// works here at once.
func gh(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	quiet := []string{"GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "NO_COLOR=1"}
	var cmd *exec.Cmd
	if f, ok := agentFound("gh"); ok {
		cmd = groups.CommandContext(ctx, f.Path, args...)
		cmd.Env = append(os.Environ(), quiet...)
		if f.PATH != "" {
			cmd.Env = append(cmd.Env, "PATH="+f.PATH)
		}
	} else {
		quoted := make([]string, len(args))
		for i, a := range args {
			quoted[i] = shellQuote(a)
		}
		script := "command -v gh >/dev/null 2>&1 || exit 127; exec gh " + strings.Join(quoted, " ")
		shArgs, shVar := shInLogin(script)
		cmd = groups.CommandContext(ctx, loginShell(), shArgs...)
		cmd.Env = append(append(os.Environ(), shVar), quiet...)
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		msg := strings.TrimSpace(stderr.String())
		switch {
		case errors.As(err, &ee) && ee.ExitCode() == 127:
			return nil, httpError{http.StatusNotImplemented, errGHMissing.Error()}
		case strings.Contains(msg, "gh auth login") || strings.Contains(msg, "not logged"):
			return nil, httpError{http.StatusPreconditionRequired, errGHAuth.Error()}
		case msg != "":
			return nil, fmt.Errorf("gh: %s", msg)
		}
		return nil, fmt.Errorf("gh: %w", err)
	}
	return out, nil
}

func (b *Box) listGitHubRepos(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	owner := r.URL.Query().Get("owner")
	if owner != "" && !ghOwner.MatchString(owner) {
		return badRequest("%q is not a GitHub account", owner)
	}
	out := GitHubRepos{Owners: []string{}, Repos: []GitHubRepo{}}
	login, err := gh(ctx, "api", "user", "--jq", ".login")
	if err != nil {
		return err
	}
	out.Login = strings.TrimSpace(string(login))
	out.Owner = owner
	if owner == "" {
		out.Owner = out.Login
	}
	var (
		wg      sync.WaitGroup
		orgs    []byte
		list    []byte
		listErr error
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		orgs, _ = gh(ctx, "api", "user/orgs", "--jq", ".[].login")
	}()
	go func() {
		defer wg.Done()
		args := []string{"repo", "list"}
		if owner != "" {
			args = append(args, owner)
		}
		args = append(args, "--limit", "400", "--json", "nameWithOwner,name,description,url,isPrivate,isFork,isArchived,primaryLanguage,updatedAt")
		list, listErr = gh(ctx, args...)
	}()
	wg.Wait()
	if listErr != nil {
		return listErr
	}
	out.Owners = append(out.Owners, out.Login)
	for _, o := range strings.Fields(string(orgs)) {
		out.Owners = append(out.Owners, o)
	}
	repos, err := parseGHRepos(list)
	if err != nil {
		return err
	}
	// Which are on the box already, by their origin's owner/repo.
	have := map[string]string{}
	if locs, err := b.Locations.List(ctx); err == nil {
		for _, l := range locs {
			if l.Slug != "" {
				have[strings.ToLower(l.Slug)] = l.Name
			}
		}
	}
	for i := range repos {
		repos[i].Location = have[strings.ToLower(repos[i].Slug)]
	}
	out.Repos = repos
	writeJSON(w, out)
	return nil
}

// parseGHRepos reads `gh repo list --json …`, most recently updated first.
func parseGHRepos(b []byte) ([]GitHubRepo, error) {
	var raw []struct {
		NameWithOwner   string    `json:"nameWithOwner"`
		Name            string    `json:"name"`
		Description     string    `json:"description"`
		URL             string    `json:"url"`
		IsPrivate       bool      `json:"isPrivate"`
		IsFork          bool      `json:"isFork"`
		IsArchived      bool      `json:"isArchived"`
		UpdatedAt       time.Time `json:"updatedAt"`
		PrimaryLanguage *struct {
			Name string `json:"name"`
		} `json:"primaryLanguage"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("gh repo list: unexpected output: %w", err)
	}
	out := make([]GitHubRepo, 0, len(raw))
	for _, x := range raw {
		g := GitHubRepo{Slug: x.NameWithOwner, Name: x.Name, Description: x.Description, URL: x.URL,
			Private: x.IsPrivate, Fork: x.IsFork, Archived: x.IsArchived, UpdatedAt: x.UpdatedAt}
		if x.PrimaryLanguage != nil {
			g.Language = x.PrimaryLanguage.Name
		}
		out = append(out, g)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out, nil
}

// repoSource is what to clone: the URL git fetches, the GitHub owner/repo
// when it is on GitHub (gh then clones it, with gh's credentials), and the
// repository's name.
type repoSource struct {
	URL  string
	Slug string
	Name string
}

var (
	slugInput  = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$`)
	scpInput   = regexp.MustCompile(`^[A-Za-z0-9._-]+@([A-Za-z0-9][A-Za-z0-9.-]*):([A-Za-z0-9._~/][A-Za-z0-9._~/-]*)$`)
	safeRepoPa = regexp.MustCompile(`^/?[A-Za-z0-9._~/-]+$`)
)

// parseRepoSource reads what a person typed or pasted: owner/repo, a GitHub
// page of the repository (any of its pages: …/tree/main, …/pull/3), or a
// clone URL over https or ssh. Anything git could be made to run a command
// with (ext::, file://, a leading "-") is refused.
func parseRepoSource(in string) (repoSource, error) {
	s := strings.TrimSpace(in)
	bad := func() (repoSource, error) {
		return repoSource{}, badRequest("%q is not a repository link: use owner/repo or its https or ssh URL", in)
	}
	if s == "" || strings.HasPrefix(s, "-") || strings.ContainsAny(s, " \t\n\r'\"`$\\") {
		return bad()
	}
	github := func(owner, repo string) (repoSource, error) {
		repo = strings.TrimSuffix(repo, ".git")
		if repo == "" || repo == "." || repo == ".." || strings.HasPrefix(owner, "-") || strings.HasPrefix(repo, "-") {
			return bad()
		}
		slug := owner + "/" + repo
		return repoSource{URL: "https://github.com/" + slug + ".git", Slug: slug, Name: repo}, nil
	}
	if m := slugInput.FindStringSubmatch(s); m != nil {
		return github(m[1], m[2])
	}
	if m := scpInput.FindStringSubmatch(s); m != nil {
		path := strings.Trim(m[2], "/")
		if strings.EqualFold(m[1], "github.com") {
			if parts := strings.Split(path, "/"); len(parts) == 2 {
				src, err := github(parts[0], parts[1])
				src.URL = s
				return src, err
			}
		}
		return repoSource{URL: s, Name: repoName(path)}, nil
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || u.User != nil && u.Scheme != "ssh" || !safeRepoPa.MatchString(u.Path) || strings.HasPrefix(u.Hostname(), "-") {
		return bad()
	}
	if _, has := u.User.Password(); u.User != nil && has {
		return bad()
	}
	switch u.Scheme {
	case "https", "http", "ssh":
	default:
		return bad()
	}
	path := strings.Trim(u.Path, "/")
	if strings.EqualFold(u.Hostname(), "github.com") || strings.EqualFold(u.Hostname(), "www.github.com") {
		parts := strings.Split(path, "/")
		if len(parts) < 2 {
			return bad()
		}
		src, err := github(parts[0], parts[1])
		if u.Scheme == "ssh" {
			src.URL = s
		}
		return src, err
	}
	if repoName(path) == "" {
		return bad()
	}
	host := u.Host
	if u.User != nil {
		host = u.User.Username() + "@" + host
	}
	return repoSource{URL: u.Scheme + "://" + host + "/" + path, Name: repoName(path)}, nil
}

// Display is the source as it may be shown and logged: its URL without a
// password.
func (r repoSource) Display() string {
	if u, err := url.Parse(r.URL); err == nil && u.User != nil {
		if _, has := u.User.Password(); has {
			u.User = url.User(u.User.Username())
			return u.String()
		}
	}
	return r.URL
}

// repoName is a repository's name from its URL path.
func repoName(path string) string {
	base := path
	if i := strings.LastIndex(path, "/"); i >= 0 {
		base = path[i+1:]
	}
	base = strings.TrimSuffix(base, ".git")
	if base == "." || base == ".." {
		return ""
	}
	return base
}
