package box

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"pier/pierd/internal/statefile"
)

// The box's variables (~/.pier/env.json) are edited from the app, each with
// a note saying what it is for, and the skills pierd installs tell Claude
// Code and Codex about them: an agent that needs the staging API's URL or
// a token for a service finds it named in its skill, and in its
// environment. Values are never written into a skill.
//
// Skills go where each agent reads them: <account folder>/skills/<id>/
// SKILL.md for every Claude Code account (code.claude.com/docs/en/skills),
// ~/.agents/skills/<id>/SKILL.md for Codex. A skill pierd wrote carries a
// marker; a file of the same name without it is the person's and is left
// alone.

// BoxEnvView answers GET /v1/env.
type BoxEnvView struct {
	Env   map[string]string `json:"env"`
	Notes map[string]string `json:"notes"`
}

const skillMarker = "<!-- written by pierd: edit the box's variables in the Pier app instead -->"

// Skill is one of the skills pierd can install.
type Skill struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Installed   bool     `json:"installed"`
	Paths       []string `json:"paths"`
}

var skillCatalog = []struct{ id, name, description string }{
	{"pier-box", "Pier box", "The box's variables (what each is for), the worktree's ports and its project's environment: databases, runtime. Use when a task needs a URL, a token, a database or a port of this box."},
	{"pier-preview", "Pier preview", "Run the worktree's dev server on its own port so the person sees it in the Pier app (and can make a public link). Use when you change anything with a page."},
}

var skillsMu sync.Mutex

func (b *Box) skillsStatePath() string {
	dir := b.StateDir
	if dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "skills.json")
}

func (b *Box) installedSkills() map[string]bool {
	var ids []string
	if data, err := os.ReadFile(b.skillsStatePath()); err == nil {
		json.Unmarshal(data, &ids)
	}
	out := map[string]bool{}
	for _, id := range ids {
		out[id] = true
	}
	return out
}

func (b *Box) saveInstalledSkills(set map[string]bool) error {
	ids := []string{}
	for id := range set {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	data, _ := json.Marshal(ids)
	return statefile.Write(b.skillsStatePath(), data)
}

// skillDirs are the folders each agent reads skills from: every Claude Code
// account's, and Codex's.
func (b *Box) skillDirs() []string {
	var out []string
	for _, a := range b.Accounts() {
		if a.Agent != "claude" {
			continue
		}
		if _, err := os.Stat(a.Dir); err == nil {
			out = append(out, filepath.Join(a.Dir, "skills"))
		}
	}
	home, _ := os.UserHomeDir()
	if home != "" {
		out = append(out, filepath.Join(home, ".agents", "skills"))
	}
	return out
}

// skillText is a skill's SKILL.md as it is now on this box.
func (b *Box) skillText(id string) string {
	var desc, name string
	for _, s := range skillCatalog {
		if s.id == id {
			name, desc = s.name, s.description
		}
	}
	var body strings.Builder
	fmt.Fprintf(&body, "---\nname: %s\ndescription: %s\n---\n\n", id, desc)
	switch id {
	case "pier-box":
		fmt.Fprintf(&body, "# %s\n\nYou run on a Pier box, in one of its worktrees. Everything below is in your environment already; read values with `printenv NAME`, never print secrets back to the person.\n\n", name)
		body.WriteString("## The worktree\n\n")
		body.WriteString("- `PIER_PORT` (and `PIER_PORT_1`… when the project asks for more): this worktree's own ports. `PORT` is `PIER_PORT` unless the project sets it. Serve on these, never on a fixed port: other worktrees run beside you.\n")
		body.WriteString("- `PIER_LOCATION`, `PIER_WORKTREE_NAME`, `PIER_WORKTREE_PATH`, `PIER_ROOT_PATH` (the main checkout), `PIER_BRANCH`, `PIER_WORKTREE_SLUG` (safe in database names).\n")
		body.WriteString("- When the project has an isolated environment: `PIER_ENV_BIN` holds launchers that run its language (php, node, python…) in Docker at the project's version; they are first on `PATH`, so just run the commands. Its databases are reached through `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `DATABASE_URL`, `REDIS_URL`, and `PIER_<NAME>_HOST` / `PIER_<NAME>_PORT` for each container.\n\n")
		body.WriteString("## Its preparation may still be running\n\n")
		body.WriteString("A new worktree is prepared while you work: the project's setup script, or a setup agent in a session of its own installing what the project needs (dependencies, database, `.env`, its dev server). Reading and changing code is fine meanwhile. Before you run the app, its tests, its migrations or anything that needs its dependencies, run `pierd prepare wait`: it returns once the environment is ready, or says why its preparation failed (`pierd prepare status` shows where it is). Never start a second preparation, and leave the setup agent's files (`.env`, the database) to it while it runs.\n\n")
		env, _ := loadBoxEnv(b.EnvFile)
		if len(env.Env) > 0 {
			body.WriteString("## The box's variables\n\nSet on this box for every project (a project's own `.env` or config wins over them):\n\n")
			keys := make([]string, 0, len(env.Env))
			for k := range env.Env {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				note := strings.TrimSpace(env.Notes[k])
				if note == "" {
					note = "no note given"
				}
				fmt.Fprintf(&body, "- `%s`: %s\n", k, strings.ReplaceAll(note, "\n", " "))
			}
			body.WriteString("\n")
		}
	case "pier-preview":
		fmt.Fprintf(&body, "# %s\n\n", name)
		body.WriteString("The person follows your work from the Pier app; a page they can open beats a description.\n\n")
		body.WriteString("1. Start the dev server on this worktree's port, listening beyond localhost: `PORT=$PIER_PORT HOST=0.0.0.0 npm run dev`, or the framework's flags (`--port $PIER_PORT --host 0.0.0.0` for Vite and Astro, `-p $PIER_PORT -H 0.0.0.0` for Next, `runserver 0.0.0.0:$PIER_PORT` for Django, `-b 0.0.0.0 -p $PIER_PORT` for Rails, `--host=0.0.0.0 --port=$PIER_PORT` for `php artisan serve`). Run it in the background.\n")
		body.WriteString("2. Check it answers: `curl -sS -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:$PIER_PORT/`.\n")
		body.WriteString("3. Record it for the person: `pierd preview set --port $PIER_PORT` (add `--path /login` for the page to open first, and `--user U --password P` for a test login of the app, never a real account). The worktree's Details screen in the Pier app shows it with its public link and the login.\n")
		body.WriteString("4. Tell the person it is up on port `$PIER_PORT` (print the number).\n\n")
		body.WriteString("If the project defines a service for its dev server (the app's Details lists them), prefer starting it there: it keeps running when your session ends.\n")
	}
	body.WriteString("\n" + skillMarker + "\n")
	return body.String()
}

// syncSkills writes the installed skills where the agents read them, and
// takes down the ones no longer installed.
func (b *Box) syncSkills() {
	skillsMu.Lock()
	defer skillsMu.Unlock()
	installed := b.installedSkills()
	for _, dir := range b.skillDirs() {
		for _, s := range skillCatalog {
			path := filepath.Join(dir, s.id, "SKILL.md")
			existing, err := os.ReadFile(path)
			ours := err == nil && bytes.Contains(existing, []byte(skillMarker))
			if err == nil && !ours {
				continue // the person's own skill of that name
			}
			if !installed[s.id] {
				if ours {
					os.Remove(path)
					os.Remove(filepath.Dir(path))
				}
				continue
			}
			text := b.skillText(s.id)
			if string(existing) == text {
				continue
			}
			if os.MkdirAll(filepath.Dir(path), 0o755) == nil {
				os.WriteFile(path, []byte(text), 0o644)
			}
		}
	}
}

func (b *Box) skillViews() []Skill {
	installed := b.installedSkills()
	out := []Skill{}
	for _, s := range skillCatalog {
		v := Skill{ID: s.id, Name: s.name, Description: s.description, Installed: installed[s.id], Paths: []string{}}
		for _, dir := range b.skillDirs() {
			path := filepath.Join(dir, s.id, "SKILL.md")
			if data, err := os.ReadFile(path); err == nil && bytes.Contains(data, []byte(skillMarker)) {
				v.Paths = append(v.Paths, path)
			}
		}
		out = append(out, v)
	}
	return out
}

func (b *Box) listSkills(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, b.skillViews())
	return nil
}

// setSkill installs (PUT) or removes (DELETE) one of pierd's skills.
func (b *Box) setSkill(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	known := false
	for _, s := range skillCatalog {
		known = known || s.id == id
	}
	if !known {
		return httpError{http.StatusNotFound, "no skill " + id}
	}
	install := r.Method == http.MethodPut
	if err := b.before(r, "skill.change", map[string]any{"skill": id, "installed": install}); err != nil {
		return err
	}
	skillsMu.Lock()
	set := b.installedSkills()
	if install {
		set[id] = true
	} else {
		delete(set, id)
	}
	err := b.saveInstalledSkills(set)
	skillsMu.Unlock()
	if err != nil {
		return err
	}
	b.syncSkills()
	b.publish(r, "skills.changed", map[string]any{"skill": id, "installed": install})
	writeJSON(w, b.skillViews())
	return nil
}

var envVarName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

// reservedEnv are names the box sets itself for each worktree, or that
// would break every program it starts.
var reservedEnv = map[string]bool{"PATH": true, "HOME": true, "SHELL": true, "USER": true, "PIER_ENV_BIN": true}

func (b *Box) getEnv(w http.ResponseWriter, r *http.Request) error {
	e, err := loadBoxEnv(b.EnvFile)
	if err != nil {
		return err
	}
	v := BoxEnvView{Env: e.Env, Notes: e.Notes}
	if v.Env == nil {
		v.Env = map[string]string{}
	}
	if v.Notes == nil {
		v.Notes = map[string]string{}
	}
	writeJSON(w, v)
	return nil
}

// putEnv replaces the box's variables and their notes, keeping anything
// else in env.json, and brings the skills up to date.
func (b *Box) putEnv(w http.ResponseWriter, r *http.Request) error {
	var req BoxEnvView
	if err := decode(r, &req); err != nil {
		return err
	}
	for k, v := range req.Env {
		if !envVarName.MatchString(k) || strings.HasPrefix(k, "PIER_") || reservedEnv[k] {
			return badRequest("%q cannot be a box variable", k)
		}
		if len(v) > 16<<10 {
			return badRequest("%s is too long", k)
		}
	}
	if b.EnvFile == "" {
		return httpError{http.StatusNotImplemented, "this box has no env file"}
	}
	if err := b.before(r, "env.change", map[string]any{"names": len(req.Env)}); err != nil {
		return err
	}
	raw := map[string]json.RawMessage{}
	if data, err := os.ReadFile(b.EnvFile); err == nil {
		json.Unmarshal(data, &raw)
	}
	notes := map[string]string{}
	for k, n := range req.Notes {
		if _, ok := req.Env[k]; ok && strings.TrimSpace(n) != "" {
			notes[k] = strings.TrimSpace(n)
		}
	}
	envJSON, _ := json.Marshal(req.Env)
	notesJSON, _ := json.Marshal(notes)
	raw["env"], raw["notes"] = envJSON, notesJSON
	data, _ := json.MarshalIndent(raw, "", "  ")
	if err := os.MkdirAll(filepath.Dir(b.EnvFile), 0o700); err != nil {
		return err
	}
	if err := statefile.Write(b.EnvFile, append(data, '\n')); err != nil {
		return err
	}
	os.Chmod(b.EnvFile, 0o600)
	b.syncSkills()
	names := make([]string, 0, len(req.Env))
	for k := range req.Env {
		names = append(names, k)
	}
	sort.Strings(names)
	b.publish(r, "env.changed", map[string]any{"names": names})
	return b.getEnv(w, r)
}

// SyncSkills brings installed skills up to date once pierd starts:
// a new pierd may write them differently.
func (b *Box) SyncSkills() { b.syncSkills() }
