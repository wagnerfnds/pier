# Pier box API

What pierd serves and how the Pier app uses it: routes, request and response JSON, errors, events, and the
conventions the app builds on top (permission menus, transcript paging, git and PR actions through `exec`,
notifications).

* Transport, TLS and pairing: [PROTOCOL.md](PROTOCOL.md). Push notifications: [PUSH.md](PUSH.md).
* The authoritative route list, with the Go handler and the app code behind each route:
  [Server/pierd/docs/API-SURFACE.md](../Server/pierd/docs/API-SURFACE.md). This document describes payloads and
  behaviour; when the two disagree on whether a route exists, API-SURFACE.md wins.
* Section numbers are referenced from code comments (`docs/API.md §8.4` and the like). Keep them stable when editing.

## Contents

0. [Ground rules](#0-ground-rules)
1. [Box info and health](#1-box-info-and-health)
2. [Locations and worktrees](#2-locations-and-worktrees)
3. [Agents, tasks, and starting an agent](#3-agents-tasks-and-starting-an-agent)
4. [Sessions](#4-sessions)
5. ["Needs you": permissions and questions](#5-needs-you-permissions-and-questions)
6. [Conversation / transcript](#6-conversation--transcript)
7. [Live updates: events](#7-live-updates-events)
8. [Diffs, review and git actions](#8-diffs-review-and-git-actions)
9. [Notifications](#9-notifications)
10. [Clients and pairing invites](#10-clients-and-pairing-invites)
11. [Routes pierd does not serve](#11-routes-pierd-does-not-serve)
12. [Gotchas](#12-gotchas)
13. [Swift client (PierKit)](#13-swift-client-pierkit)

---

## 0. Ground rules

### 0.1 Reaching the API

* Paired clients (the app, `Tools/pierctl`, `pierd client`) reach every route over mutual TLS 1.3 on pierd's
  listener, HTTP/2 (see PROTOCOL.md). Paths are used exactly as written below, rooted at `/v1/`.
* The box's own user reaches the same handlers over the Unix socket `$PIER_HOME/box/pierd.sock` (default
  `~/.config/pier/box/pierd.sock`): that is what the `pierd` CLI and the agents' hooks use. So
  `pierd <command> --json` prints what a paired client gets over the wire.
* Push routes (`/v1/push/*`) are only served when push is configured and refuse the local socket (PUSH.md).

### 0.2 Conventions

| Topic | Rule |
| --- | --- |
| Bodies | JSON, `Content-Type: application/json`. Bodies that carry a prompt (`POST /v1/tasks`, `POST /v1/sessions`, `.../send`) may be up to 2 MB; everything else 64 KB. |
| Times | RFC 3339 with up to 9 fractional digits (`2026-10-07T19:07:42.53987405Z`). Zero times are omitted. Some fields are Unix milliseconds (transcript); they are named in place. |
| Omitted fields | Most fields are omitted when empty: absent means zero, false or empty. Model every non-identity field as optional. |
| Lists | Top-level empty lists are `[]`. Nested lists can be `null` or missing (`branches`, transcript `items`); decode defensively. |
| Errors | Non-2xx: `{"error": "human text", "code": "..."}`. Branch on `code`, show `error` verbatim. Codes: `not_found` (404), `session_exited` (409), `session_exists` (409), `agent_waiting` (409), `refused` (403, a `before:` hook or a box rule said no), `unsupported` (501), `tmux_missing` (503), `git_failed`, `command_failed`, `too_many` (429), `bad_request`, `internal`. Unknown routes answer Go's plain-text `404 page not found` (or 405 for a known path with another method), not JSON: fall back to the raw text. |
| Origin header | Optional `X-Pier-Origin: <[a-z0-9][a-z0-9-]{0,31}>` sets the `origin` of the events a call causes (default `pier`). The app sends `ios` (and `ios-push` for push routes). Hooks see a paired client as `client:<name>` whatever the header says. |
| Gates | Many mutating calls run `before:<action>` hooks the box owner configured (`~/.pier/hooks.json` or a trusted repository config). A refusal is 403 `refused` with the hook's output as `error`. |
| Capabilities | `GET /v1/info` → `capabilities[]` names optional features: `transcript history diff titles answer session.home session.chat draft journal touched`, plus `turns queue ask controls` (turn ledger) and `pair.invite`. |

### 0.3 Naming and addressing

* A **location** is a registered repository (`name`, `path`). A **worktree** is a checkout of it. API refs use
  `"shop"` for the repository's own (main) checkout and `"shop/checkout-fix"` for a linked worktree; `exec`,
  `POST /v1/sessions` and `Location.ref(_:)` in PierKit all use this convention.
* A **session** is a tmux session (in pierd's own tmux server, `$PIER_TMUX_SOCKET`, default `pier`) named
  `[A-Za-z0-9][A-Za-z0-9_-]{0,62}`. A session belongs to a worktree when `session.dir` is the worktree's path (or
  a folder inside it). Its `location` is the ref it was started with (empty for home terminals and chats, 3.5).

---

## 1. Box info and health

### 1.1 `GET /v1/info`

```json
{"name":"devbox","os":"linux","arch":"amd64","version":"0.4.0","build":"3f9c0a1b2d4e",
 "user":"octocat","home":"/home/octocat","tools":["claude","codex"],
 "agents":[{"id":"claude","name":"Claude Code","command":"claude","model_flag":"--model","effort_flag":"--effort",
            "models":["opus","sonnet","haiku"],"efforts":["low","medium","high","xhigh","max"]},
           {"id":"codex","name":"Codex","command":"codex","model_flag":"--model","effort_flag":"-c model_reasoning_effort=",
            "efforts":["minimal","low","medium","high"]}],
 "agent_paths":[{"id":"claude","name":"Claude Code","command":"claude","path":"/home/octocat/.local/bin/claude","via":"path"}],
 "capabilities":["transcript","history","diff","..."],
 "adapters":{"claude":{"ready":true,"started":true,"waiting":true,"finished":true,"final_message":true,"via":"hooks"}}}
```

* `version` is pierd's release (`dev` from a checkout); `build` is a 12-hex digest of the running binary (two
  binaries with the same version and another build are different bytes).
* `agents` are the presets this box can start (3.1). `adapters`: per agent, which state events it reports and how
  (`hooks`, `notify`, `screen`); `via: "screen"` means state is read from the terminal, less precisely.

### 1.2 `GET /v1/stats`

```json
{"hostname":"devbox","uptime_s":11486,"cpus":12,"load":[1.49,1.14,1.16],
 "memory":{"total":63096745984,"used":230916096},"swap":{"total":8589930496,"used":8192},
 "disks":[{"mount":"/","total":1889743667200,"used":813817757696}],
 "agents":[{"tool":"codex","pid":6366,"path":"/home/octocat/code/shop","state":"finished","since":"2026-10-07T19:07:42Z"}],
 "hooks":true}
```

No CPU percentage: CPU is `load` (1/5/15-minute load average) over `cpus`. Sizes are bytes. `agents` are agent
processes seen on the box, including ones pierd did not start. `hooks: true` means the agents' hooks report to pierd.

### 1.3 `GET /v1/doctor`

`[{area, name, status: "ok"|"warn"|"fail"|"info", detail?, fix?}]`, the same as `pierd doctor --json`. The app turns
the `warn` / `fail` checks into Inbox cards (`BoxHealth` in PierKit): besides tools, service and locations, the
"Agents" area has `<agent> hooks` (pierd's hooks installed) and `<agent> sign-in` (the CLI's credentials file, or an
API key in pierd's environment; left out where that cannot be told), with `fix` the command to run on the box.

### 1.4 Reachability

`GET /v1/ping` → `{"name":"<box name>"}` is the cheap liveness and trust check (401 once revoked; 503
`{"code":"box_stopping"}` while pierd shuts down). `GET /v1/info` tells the capability set after a (re)connect.

### 1.5 Other box-level reads

| Route | Answer |
| --- | --- |
| `GET /v1/services` | `[{location, worktree, path, port, process?, main?}]`: dev servers listening, by worktree |
| `GET /v1/agents` | `[{id, name, command, ..., installed, path?}]`: the known agent CLIs (claude, codex) and whether each is installed. Model and effort lists are in `info.agents`, not here |

---

## 2. Locations and worktrees

### 2.1 List: `GET /v1/locations`

`Location[]`, each with its worktrees:

```json
{"name":"shop","path":"/home/octocat/code/shop","repo":true,
 "worktrees":[{"name":"shop","path":"/home/octocat/code/shop","branch":"main","head":"c938d8e7e1","main":true,"port":41000},
              {"name":"checkout-fix","path":"/home/octocat/code/shop-checkout-fix","branch":"checkout-fix","port":41010}],
 "scripts":{"setup":"bash scripts/setup.sh","from":"repo"},
 "remote":"https://github.com/octocat/shop.git","slug":"octocat/shop","default_branch":"main","repo_trust":"trusted"}
```

* Location: `name, path, repo (git root), worktrees?, scripts {setup?, archive?, from? ("pierd" | "repo")},
  agents? (repository presets, 3.2), remote?, slug? ("owner/repo"), default_branch?, repo_trust?`
  (`"none" | "trusted" | "untrusted" | "changed"`).
* Worktree: `name, path, branch?, head? (10 hex), main? (the repository's own checkout; cannot be removed),
  setting_up?, port? ($PIER_PORT), locked?, lock_reason?`. `lock_reason == "initializing"` means
  `git worktree add` is still running.
* A linked worktree lives at `dirname(repo)/<basename(repo)>-<name>`; its `name` is that suffix.

### 2.2 Per-worktree status: `GET /v1/worktrees[?location=L]`

```json
[{"location":"shop","name":"checkout-fix","path":"...","branch":"checkout-fix","port":41010,"base":"origin/main",
  "ahead":2,"behind":0,"changed":3,"untracked":1,"sessions":1,
  "last_commit":{"sha":"...","short":"c938d8e7e","subject":"...","author":"...","time":"...","refs":"HEAD -> checkout-fix",
                 "parents":["..."],"on_base":false},
  "error":"..."}]
```

File counts only (no line counts). Without `location` it covers every location and runs git per worktree, which can
be slow.

### 2.3 Branches: `GET /v1/locations/{loc}/branches`

`{"default":"main","branches":[{"name":"main","remote":false,"current":true},{"name":"feat/x","remote":true}]}`, most
recent commit first; a branch that exists locally and on origin appears once with `remote: false`. `branches` can be
`null`.

### 2.4 Create a worktree: `POST /v1/locations/{loc}/worktrees`

```json
{ "name": "fix-login", "branch": "fix-login", "base": "origin/main", "pr": 123, "ref": "pull/123/head" }
```

* `name` (required): `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`.
* `branch` defaults to `name`. A local branch of that name is checked out as is; else, if `origin/<branch>`
  exists, a branch **tracking it** is created (`git worktree add --track -b`); else a new branch is created from
  `base` (any ref; empty means the main checkout's HEAD). The app relies on the tracking case to bring a
  same-repository PR into a worktree: it fetches `origin/<head>` first (`PRCommands.fetchHead`), then creates the
  worktree.
* `pr` / `ref`: fetch a pull request head (default ref `pull/<pr>/head`) into `branch` when origin has no such branch.
* Answer: the `Worktree`. The location's setup script then runs in the background (`worktree.setup.started |
  finished | failed`), and services marked `autostart` start after it.
* Errors: 400 invalid name, not a repository, or git's message; 403 `refused` (`before:worktree.create`); 404
  unknown location.

### 2.5 Remove: `DELETE /v1/locations/{loc}/worktrees/{wt}[?force=1&delete_branch=1]`

* `force=1`: `git worktree remove --force` (discards uncommitted changes). Without it git's refusal comes back as
  400 `git_failed`; show it and offer "Force".
* `delete_branch=1`: also `git branch -D` the worktree's branch.
* Refuses the main checkout, and a worktree a person locked (409). Stops the worktree's services and **kills every
  session running in it**.
* `200 {"removed":"<wt>"}`, or `202 {"removing":"<wt>","archive":"<script>"}` when the location has an archive
  script: it runs in the background, then the worktree is removed (`worktree.archive.*`, then `worktree.removed`).
  On `worktree.archive.failed` the worktree is still there.
* Gate: `before:worktree.remove`.

### 2.6 Other location and worktree routes

| Route | Purpose |
| --- | --- |
| `GET /v1/locations/{loc}/worktrees/{wt}/touched` | files the latest turn changed (8.2) |
| `POST /v1/locations/{loc}/worktrees/{wt}/attachments` | upload a file before an agent exists (4.9) |
| `GET /v1/locations/{loc}/worktrees/{wt}/services` | `[{name, run, autostart?, state, unit, port?}]` |
| `POST .../services/{service}/{start\|stop\|restart}` | run as systemd user units named `svc-<location>-<worktree>-<service>` |
| `POST /v1/locations {name, path}`, `DELETE /v1/locations/{name}` | add or forget a repository (`pierd location add\|rm`) |
| `GET`/`PUT /v1/locations/{name}/config`, `POST`/`DELETE .../config/trust` | box-local config and repository-config trust (`pierd location config`); the app does not call them |

---

## 3. Agents, tasks, and starting an agent

### 3.1 Which agents the box has

Use `GET /v1/info` → `agents[]` (`AgentPreset`), refined per repository by `Location.agents[]` (3.2). Only agents
whose CLI is found on the box appear.

| Field | Meaning |
| --- | --- |
| `id` | `claude`, `codex`, or a repository-defined id |
| `name`, `command` | display name; the command run |
| `prompt_flag?` | how the first prompt is passed; empty means as the last argument |
| `model_flag?`, `effort_flag?` | present means the agent can be given a model / effort; a flag ending in `=` takes the value with no space |
| `models?`, `efforts?` | what to offer, in the CLI's own names. Codex lists no models: free text is allowed because `model_flag` is set |

Picker rule: show models only when `model_flag` is set, efforts only when `effort_flag` is set, and always offer
"Default" (empty). Values must match `^[A-Za-z0-9._:/-]+$` and not start with `-`. `model` / `effort` are only valid
with `agent`, never with a raw `command` (400).

### 3.2 Per-location presets

`Location.agents[]` comes from the repository's `.pier/config.json` or the box-local location config. Merge rule
(app): an entry with a `command` adds or replaces an agent; an entry with only `id` plus `models` / `efforts`
overrides those lists on the box agent with that id. De-duplicate by `id`, repository entries first.

### 3.3 Create a task (worktree + agent + prompt): `POST /v1/tasks`

```json
{ "location": "shop", "name": "checkout-fix", "branch": "checkout-fix", "base": "origin/main",
  "agent": "claude", "prompt": "Fix the webhook retries", "model": "sonnet", "effort": "high",
  "title": "Fix webhook retries" }
```

| Field | Notes |
| --- | --- |
| `location`, `name` | required |
| `branch?`, `base?`, `pr?`, `ref?` | as 2.4 |
| `agent?` / `command?` | a preset id, or a command to run instead (then no `model` / `effort`). Neither: an empty shell |
| `prompt?` | the first prompt, passed to the agent as **one argument**: at most 128 KB on Linux (413 beyond). For longer text, start short and `send` the rest |
| `model?`, `effort?` | 3.1 |
| `title?` | session title; defaults to the prompt's first line (≤ 48 characters) |
| `open?` | a hint for other clients to show the session; the app never sets it |

Answer: `{"worktree": Worktree, "session": Session}`. Order on the box: `before:task.create` →
`before:worktree.create` → worktree (setup in the background) → `before:session.start` → the tmux session. If the
session cannot start, the worktree is removed again. Errors: 503 `tmux_missing` (checked first), 400 unknown agent,
403 `refused`, 404 unknown location, 413 prompt too long. Events: `worktree.created`, `session.started`,
`task.created {location, name, path, branch, session, agent}`.

### 3.4 Start an agent in an existing worktree: `POST /v1/sessions`

```json
{ "location": "shop/checkout-fix", "agent": "claude", "prompt": "Continue with the tests",
  "model": "opus", "effort": "max", "title": "Tests", "name": "optional-session-name" }
```

* `location`: `"shop"` or `"shop/checkout-fix"`; required unless `home: true`.
* `agent` or `command` (both: 400); neither starts a login shell.
* `name?`: the tmux name; by default `<loc>-<program>-<base36 time>`. 409 `session_exists` when taken.
* `home: true` (capability `session.home`): a terminal in the box user's home, no location and no agent.
* Answer: the `Session` (4.1). Event `session.started {name, location, path, command, agent?}`.
* With `agent` + `prompt`, pierd also handles the agent's start-up question (trust this folder) and holds the prompt
  until it is answered.

### 3.5 Start a chat, tied to no project: `POST /v1/sessions` with `chat: true`

```json
{ "chat": true, "agent": "claude", "prompt": "Help me plan a home server", "model": "opus", "effort": "high" }
```

A chat (capability `session.chat`) is an agent for a conversation that belongs to no project: ask something, talk
an idea through, plan what does not exist yet.

* `agent` is required (a built-in preset, 3.1); `prompt?`, `model?`, `effort?`, `title?`, `name?`, `open?` as 3.4.
  `location`, `command` or `home` beside it: 400.
* It runs in an **empty folder of its own**, `~/pier/chats/<session name>` (made 0700), never in the home folder: an
  agent there would take the whole home for its project, and the turn ledger places a hook that names no session by
  its folder, so two chats never share one. The default name is `chat-<program>-<base36 time>`; when an earlier chat left a
  folder of that name, the next free `-2`, `-3`... is taken. A `name` whose folder exists: 409.
* Answer: the `Session` (4.1), with `location` empty and `chat: true`. Event `session.started {..., chat: true}`.
  It is an agent like any other: `PIER_SESSION`, the turn ledger, transcripts, push and Live Activities (their place
  reads "Chat" / "Conversa") all work as for a task's session. There is no worktree: no review, diff, services or
  worktree cleanup.
* Ending it (`DELETE /v1/sessions/{name}`) removes its folder when the agent left nothing there but the app's
  attachments (`.pier/`); anything else it wrote stays, for the user to find.

---

## 4. Sessions

### 4.1 List: `GET /v1/sessions`

```json
{"name":"shop-checkout-claude-1x2y","location":"shop/checkout-fix","dir":"/home/octocat/code/shop-checkout-fix",
 "command":"claude --model sonnet 'Fix ...'","created":"2026-10-07T19:00:00Z","attached":0,"exited":false,
 "agent":"claude","agent_state":"waiting","state_since":"2026-10-07T19:05:12Z","preset":"claude",
 "turn":"shop-checkout-claude-1x2y#3","state_seq":1234,"fidelity":"hooks","title":"Fix webhook retries","queued":1,
 "ask":{"tool":"Bash","input":"rm -rf build","why":"clean build","message":"Claude needs your permission to use Bash"},
 "scope":"pier-shop-checkout-claude-1x2y-tj8k2c.scope","usage":{"memory":512000000,"cpu_s":42.5,"cpu_percent":3.1,"processes":7}}
```

| Field | Notes |
| --- | --- |
| `name` | the id for every `/sessions/{name}/...` call |
| `location`, `dir`, `command`, `created`, `attached` (tmux clients), `exited` | `exited: true`: the program ended; the pane stays readable but takes no input (`session_exited`). Offer "remove" (DELETE) |
| `agent` | `claude`, `codex`, ...; empty for shells |
| `agent_state` | `idle` (at its prompt) \| `running` (working on a turn) \| `waiting` (needs a person) \| `finished` (turn ended); absent for shells and exited sessions. An agent with no hook data reads as `running` |
| `state_since` | when it entered that state ("waiting 3m") |
| `preset`, `turn`, `state_seq`, `fidelity` | `fidelity`: `hooks` (exact) \| `partial` \| `screen` (inferred) |
| `title` | first prompt line (≤ 48 characters) or a rename; empty until there is one |
| `queued` | prompts held until the agent is idle (4.5) |
| `ask` | only while `waiting`, when the hooks said what for: `{tool?, input?, why?, message?}`, each ≤ 300 characters, never file contents |
| `scope`, `usage` | the systemd scope the program runs in, and what it uses (`memory`, `memory_high?`, `cpu_s`, `cpu_percent?`, `processes?`), on boxes where sessions get one |
| `chat` | `true` for a chat (3.5): an agent with no location, in its own folder under `~/pier/chats` |

There is no `GET /v1/sessions/{name}`: list and filter.

### 4.2 Screen and draft

* `GET /v1/sessions/{name}/screen?history=N` → `{"screen":"..."}`: plain text (no ANSI) of the visible pane plus N
  lines of scrollback (N ≤ 10000; omitted means the visible screen only). Wrapped lines are joined, so lines can be
  wider than the pane. An exited session still returns its last output.
* `GET /v1/sessions/{name}/draft` (capability `draft`) → `{agent, text?, clipped?, status?: {word, elapsed?,
  tokens?}}`: for Claude Code, the reply it is writing right now as Markdown, read from the styled screen, and the
  status line ("Brewing… (12s, 7.1k tokens)"). Poll it to show the reply as it streams.

### 4.3 Send a prompt: `POST /v1/sessions/{name}/send`

```json
{ "text": "run the tests", "enter": true, "when": "idle", "force": false, "idem_key": "ios-7F3A..." }
```

Answer: `{"sent":true, "queued":false, "duplicate":false, "turn":"name#4", "seq":1250, "at":"<box time>"}`.

| Field | Semantics |
| --- | --- |
| `text` | pasted as one bracketed paste (any length, multi-line safe), then Enter. A single `[0-9a-zA-Z]` character with `enter: false` is typed as a keystroke (menu answers) |
| `enter` | default `true`; `false` only pastes |
| `when` | omitted: type at once **without checking whether the agent waits** (legacy). `"now"`: type at once, but 409 `agent_waiting` when the agent waits for someone, unless `force`. `"idle"`: if the agent is not ready, pierd **holds** the prompt (`queued: true`, event `session.queued`) and types it when the agent is idle or finished with nothing queued before it; held prompts survive the phone going away |
| `force` | type even though the agent waits (only when the person is answering it) |
| `idem_key` | always send one: a retry with the same key returns the original turn with `duplicate: true` and types nothing |

* 409 `session_exited` when the program has ended.
* At the agent's start-up question, text is held (`idle`, `now`) or refused (`force`).
* A forced send into a waiting agent is an **answer** (`session.sent {answer: true, turn}`), not a new turn.
* Slash commands (`/model`, `/cost`) pass through and create no turn (`sent: true` with no `turn`).
* A prompt on an untitled session names it. Gate `before:session.send`.
* Event `session.sent {name, from, idem_key?, turn?, answer?, command?, startup?}`; the text never appears in events.

### 4.4 Keys, interrupt and mode

* `POST /v1/sessions/{name}/keys {"keys":["escape","1"]}` (1 to 12 keys) → `{"sent":true}`. Names
  (case-insensitive): `escape, enter, tab, btab` (alias `shift+tab`), `up, down, left, right, interrupt` (Ctrl-C),
  `1`..`9`, `y`, `n`. Anything else: 400. No other control keys, no free text: use `send` for text. 409
  `session_exited`. Hard stop = `["interrupt","interrupt"]`.
* `POST /v1/sessions/{name}/interrupt` → `{"sent":true,"stopped":bool}`: presses Esc, waits up to 4 s for the agent
  to stop, then ends the turn with `agent.finished {source: "interrupt", status: "interrupted"}` (no notification
  for it). This is the Stop button.
* `GET /v1/sessions/{name}/controls` → `{agent, mode?, effort?, modes?, limit?}` (Claude Code modes `default,
  acceptEdits, plan, auto, bypassPermissions`). `POST .../mode {"mode":"plan"}` → `{"mode":"plan"}` cycles
  Shift-Tab until the mode matches (409 when the agent waits or the mode cannot be reached; event `session.mode`).

### 4.5 Held prompts (capability `queue`)

* `GET /v1/sessions/{name}/queue` → `[{turn, preview (≤ 280 characters), length, origin?, at}]`, oldest first.
* `DELETE /v1/sessions/{name}/queue/{turn}` → `{"cancelled": turn}` (404 once sent). Event `session.unqueued`.
* `POST /v1/sessions/{name}/queue/{turn}/send {force?}` → the send answer: type it now (409 while the agent waits,
  unless `force`).
* `{turn}` looks like `name#3`: encode `#` as `%23` in the path.

### 4.6 Stop and rename

* `DELETE /v1/sessions/{name}` → `{"removed": name}`: kills the session (also clears an exited pane). Event
  `session.stopped`, gate `before:session.stop`.
* `PATCH /v1/sessions/{name} {"title":"..."}` (empty clears) → the `Session`. Event `session.renamed`.

### 4.7 Turns and waiting

* `GET /v1/sessions/{name}/turns?limit=N` (≤ 500, default 20) → `Turn[]`, oldest first: `{id: "name#n", session,
  agent?, n, origin?, sent?, sent_seq?, end_seq?, state: queued|pending|running|waiting|finished|exited|lost, queued?,
  started?, ended?, waits?: [{start, end?, reason?, ask?}], fidelity?, idem_key?, status?: "error"|"cancelled"}`.
* `GET /v1/sessions/{name}/wait?for=finished,waiting&after=<RFC3339Nano>&timeout=60s` → `{state, timed_out, turn?}`
  (`state` may be `exited`). Pass the `at` of the send answer (box clock) as `after` to wait for a state newer than
  your send. Timeout default 10 minutes.
* Long polls only help in the foreground; the event stream (7) is the main channel.

### 4.8 Raw terminal

Not served: pierd has no terminal attach stream. The app reads `screen` and drives the session with `send` and `keys`.

### 4.9 Attachments (photos)

`POST /v1/sessions/{name}/attachments?name=photo.png` with the raw bytes as the body, or JSON
`{"name": "...", "data": "<base64>"}`, ≤ 20 MB → `{path, name, type, size}`. Images, PDFs and text only (415
otherwise); the file is saved inside the session's worktree under a timestamped name. To hand it to the agent, put
`path` in the next prompt, one per line after the text. Before a session exists (a new task with photos) use the
worktree form: `POST /v1/locations/{loc}/worktrees/{wt}/attachments`.

---

## 5. "Needs you": permissions and questions

### 5.1 How a request arises

1. The agent's own hooks (installed by `pierd integrations install`) report to pierd. Claude Code: a
   `PermissionRequest` hook or a `permission_prompt` notification → `agent.waiting {reason: "permission"}`;
   `elicitation_dialog` / `agent_needs_input` → `reason: "question"`. Codex reports permission requests too. Agents
   followed by their screen are detected from the terminal.
2. What is asked goes in `ask`: `{tool, input, why?, message?}`, with `input` a one-line summary (Bash: the command;
   Edit/Write/Read: the path relative to the session folder; WebFetch: the URL; Grep/Glob: the pattern;
   AskUserQuestion: the first question). Never file contents. `ask` is not in the event: read it from
   `Session.ask` (while waiting) or `Turn.waits[].ask`.
3. The session turns `agent_state: "waiting"`; `agent.waiting` is published.

**pierd is not a permission broker.** The hook does not block on an answer: the agent shows its own terminal menu,
and answering means typing that menu's key.

### 5.2 Listing what needs you

`GET /v1/sessions` filtered to `agent_state == "waiting"`, oldest `state_since` first, refreshed on `agent.*` events.

### 5.3 Permission: Allow / Always allow / Deny

Classification: if `ask.tool` is missing or matches `^(AskUserQuestion|request_user_input|ExitPlanMode)$`, it is a
**question** (5.4); otherwise a **permission**. For a permission the app (`MenuParser`; pierd's push engine does the
same, `internal/push/menu`):

1. Reads `GET .../screen`. The menu is drawn a moment after the event: retry up to 4 times, 600 ms apart.
2. Parses numbered options from the last 14 meaningful lines: `^\s*(?:[│┃]\s*)?(?:[❯›>]\s*)?(\d)[.)]\s+(\S.*?)(?:\s+[│┃])?\s*$`,
   first of each digit, valid only with ≥ 2 options starting at `1`. When the pane is wide Claude Code draws a side
   panel (`<text> │ <panel>`); labels are cut at ` │`. A screen with `← ☐ … ✔ Submit` tab rows is a question form,
   not a menu.
3. Maps options: **Always allow** = label matching `don.t ask again|always|allow all|this session`; **Allow** =
   another option matching `^(yes|allow|approve|proceed)\b`; **Deny** = `^(no|deny|reject)\b` (all
   case-insensitive). Buttons are shown only when both Allow and Deny exist. The key sent is **the option's own
   digit**: Claude Code's manual-mode menu has four options (`1. Yes`, `2. Yes, and don't ask again …`,
   `3. Yes, and switch to auto mode …`, `4. No`), so Deny is not necessarily `3`.
4. Sends the digit with the person's authority:

   ```json
   POST /v1/sessions/{name}/send
   { "text": "1", "enter": false, "when": "now", "force": true }
   ```

   `force: true` is required (else 409 `agent_waiting`). `POST .../keys {"keys":["1"]}` also works but publishes no
   `session.sent`.
5. The state returns to `running` by itself when the tool runs. After a Deny, Claude Code goes back to its prompt.

Start-up dialogs are not permission menus. Claude Code's "Quick safety check: … do you trust this folder?" has
unnumbered rows with the cursor on **No**: send `keys: ["down","enter"]`. Codex's `› 1. Trust and continue` ignores
the digit: send `keys: ["enter"]`. pierd reports both as `agent.waiting {reason: "startup question"}` and holds
prompts until they are answered.

When no Allow/Deny can be derived, offer "Answer": the screen plus a key bar (`1 2 3 y n enter esc`) through `keys`.
Always show `ask.tool` + `ask.input` (+ `why`), e.g. `Bash  rm -rf build`.

### 5.4 Questions (AskUserQuestion / request_user_input / ExitPlanMode)

* The structured question is a transcript item `kind: "question"` (6.2): `questions: [{question, header?, multi?,
  options: [{label, description?}], id?}]`; once answered, `done: true` and `answers: ["Blue"]` (`error: true` when
  dismissed).
* Claude Code: `POST /v1/sessions/{name}/answer` (capability `answer`):

  ```json
  { "tool": "<item.tool>", "answers": [ { "picks": ["Option label"], "other": "my own words" } ] }
  ```

  One entry per question, in order; `picks` are option labels (exactly one unless `multi`), `other` one line of free
  text. Answer `{"answered": ["Option label, my own words"]}`. pierd drives the form with keys and checks the screen
  after each one; anything unexpected stops it untouched with 409 `…: finish in Claude's screen`. Other 409s:
  "Claude isn't waiting for an answer", "those questions were already answered", "already answering"; 404 "that
  question isn't in Claude's conversation"; 400 for agents other than Claude Code.
* Fallback (Codex, or a 409): read the screen and send the option's position as a key (`send {text: "2", enter:
  false, when: "now", force: true}`). A question screen lists options `1..n`, then `n+1. Type something.` and
  `n+2. Chat about this`.
* `ExitPlanMode` (plan approval) is a numbered menu: treat it like a permission (5.3); the plan is the preceding
  `text` item.

### 5.5 Notification text

See section 9.

---

## 6. Conversation / transcript

pierd reads the **agent's own record** (Claude Code's `~/.claude/projects/.../<id>.jsonl`, Codex's
`~/.codex/sessions`), not the terminal. Capability `transcript`; Claude Code and Codex only, other sessions answer
`source: "none"`.

### 6.1 `GET /v1/sessions/{name}/transcript?since=N&gen=G`

```json
{ "source":"claude", "items":[...], "next":42, "crew":[...], "truncated":true, "last":1760000000000,
  "gen":"1760000000000123.0", "reset":false, "start":123456, "file":"5b84275f-...",
  "signals":{...}, "artifacts":[...] }
```

| Field | Meaning |
| --- | --- |
| `source` | `claude` \| `codex` \| `none` (then `reason` says why) |
| `items` | items from index `since` on (6.2). `null` when nothing is new |
| `next` | the `since` for the next call |
| `truncated` | older items exist outside the window (the box keeps the last 300 items, reading at most the last 4 MB on first open) |
| `last` | Unix ms of the agent's last write to its record ("thinking for 12s") |
| `gen` | names this reading of the record; send it back |
| `reset`, `start` | 6.3 |
| `file` | the record's id; another `file` is another conversation (after `/clear`): drop what you hold |
| `crew` | subagents: `[{id, name, kind: "subagent", agent, state: "running"\|"finished", doing, since (ms), until? (ms)}]` |
| `signals` | mode, model, effort, context, todos, background jobs, retry (6.5) |
| `artifacts` | claude.ai pages the agent published, `[{url, title, description?, file?, at (ms), tool, updated?}]`, newest last; every answer carries all |

Tool output and the agent's thinking are never included, only that a call finished: fetch one call on demand (6.6).

### 6.2 Items

Every item has `kind`, `id` (stable: `cl@<offset>.<n>` for Claude Code, `co@…` for Codex) and `off` (byte offset
of its source line, used to page older items).

| `kind` | Fields | UI |
| --- | --- | --- |
| `user` | `text` (≤ 4000), `uuid?`, `parent?`, `midTurn?` | the person's prompt (also prompts typed in the terminal) |
| `text` | `text` (≤ 32 KB Markdown) | assistant message; also plan text |
| `tools` | `verb`, `items: [{verb, target, file?, id?, at? (ms)}]`, `done` | a group of calls with the same verb; an open group (`done` false) is sent again until done |
| `edit` | `file`, `added`, `removed`, `tool?` | a file edit with line counts; its patch via 6.6 |
| `command` | `command` (`/model`, or `!` for shell), `args?`, `text?`, `markdown?`, `error?` | a slash or shell command typed to the agent; its output arrives later |
| `crew` | `names[]`, `tool?` | subagents started |
| `question` | `tool`, `questions[]`, `answers?`, `done?`, `error?` | 5.4 |
| `notice` | `notice` (`api_error\|limit\|rate_limit\|auth\|billing\|hook\|interrupted\|stop_failure\|exited`), `level?` (`error\|warning\|info`), `text`, `resets?` (ms) | banner |
| `artifact` | `text` (title), `url?`, `file?`, `description?`, `done?`, `error?`, `updated?`, `tool?` | a published claude.ai page |
| `agent-message`, `ping` | `msg: {from: {id, name, kind}, intent?, status?, title?, summary?, body?, ...}` | a message from another agent or from Claude Code, not the person |

Unknown kinds draw nothing (PierKit decodes `kind` tolerantly; it also still knows a `report` kind pierd does not
produce). The app synthesises items the box does not send: `ask` (a permission, from `Session.ask` + screen
options), `thinking` (from `draft.status`, a running tool group and `last`), a `user` item with `pending: true` (a
prompt just sent, until the record echoes it) and the live reply (from `GET .../draft`).

### 6.3 Paging and incremental fetch

1. **Open**: `GET .../transcript?since=0`. Keep `items` (the last ≤ 300), `next`, `gen`, `file`, `start`.
2. **Poll**: `GET .../transcript?since=<next>&gen=<gen>`. Items start at `since`, **except** that the tools or
   command item just before `since`, an open tool group, and an artifact or question that settled are sent again.
   So **upsert by `id`** (replace in place, else append); never blindly append. Then `next = r.next`.
3. **Reset**: `reset: true` means the box read the record afresh (a pierd restart, a conversation idle for a while,
   a rewind, a `gen` it no longer knows, or `since` before the kept window). The answer is the whole window starting
   at offset `start` (absent: 0). Keep the items you hold with `off < start`, replace the rest with `items`, take
   `next` and `gen` from the answer, and fill any hole with `?before=` pages (at most 10). If `file` changed,
   discard everything instead.
4. **Older history**: `GET .../transcript?before=<off of the oldest item held>&limit=<≤ 300>` (capability
   `history`) → `{source, items (oldest first, all with off < before), more, ...}`. `next` is meaningless here
   (0): never feed it back as `since`. `more: true` means earlier items remain. `before=0` means from the end.
5. **Liveness**: `transcript.changed` events arrive shortly after the agent writes, but only while someone read the
   transcript in the last 8 s: read at least every 2 s while the view is open, and right away on the event. Allow
   ~8 s for the first read. 404 means the session is gone.

`TranscriptStore` in PierKit implements this.

### 6.4 Questions inside the transcript

5.4: an open question is `kind: "question"` with `done != true`.

### 6.5 `signals`

```
{ mode?: "default|acceptEdits|plan|auto|bypassPermissions" (Claude Code) | approval policy (Codex),
  model?, effort?,
  context?: {tokens, window?, at?},
  todos?: [{id?, text, active?, status: "pending|in_progress|completed"}],
  background?: [{tool, task?, kind: "shell|monitor", command, label?, state, since, until?}],
  retrying?: {message, attempt?, max?, at} }
```

The header chips ("opus · plan mode · 64% context") and the to-do list come from here. `background` also tells
whether a finished turn still has work running (the app and pierd's push say "in background").

### 6.6 One call's detail: `GET /v1/sessions/{name}/transcript/tool/{id}`

`{id, name, command?, file?, pattern?, old?, new?, hunks?: [{oldStart, oldLines, newStart, newLines, lines: [" x",
"-y", "+z"]}], output?, truncated?, error?, pending?, live?}` (note the camelCase hunk keys). `{id}` is a
`tools.items[].id`, an `edit.tool`, a `question.tool` or a `signals.background[].tool`. For an edit, `hunks` is that
single edit's patch, numbered by the file's own lines. `output` is head and tail when long. 404 "that step is no
longer in the conversation" once it left the window. Fetch only when a row is expanded.

---

## 7. Live updates: events

### 7.1 Stream: `GET /v1/events[?since=SEQ&max=N]`

* NDJSON (`application/x-ndjson`), one event per line, kept open. A blank line every 25 s is a keepalive: skip empty
  lines.
* Without `since`: only new events. With `since=SEQ`: first everything after `SEQ` from the journal (at most `max`,
  default 5000; further behind, you start at the most recent `max`), then live. A `since` beyond the journal's head
  (a box set up again) starts from now.
* Resume: remember the highest `seq`, reconnect with `?since=<seq>`. After a long gap also refetch sessions and
  locations.

### 7.2 Envelope

```json
{"seq":161,"type":"agent.finished","time":"2026-10-07T20:31:25.97Z","box":"devbox","origin":"claude","error":"...","data":{...}}
```

`origin`: the caller's `X-Pier-Origin` (`ios`, `pier`, ...), or the source (`claude`, `codex`, `screen`, ...).
`error` is set on failures. `data` is free-form; unknown types and keys are ignorable.

### 7.3 Event catalogue

**Agent state** (`data`: `path`, `agent`, `session?`, `agent_session_id?`, `session_id?`, `turn_id?`):

| Event | Extra `data` | Use |
| --- | --- | --- |
| `agent.ready` | | at its prompt |
| `agent.started` | `signal` (`prompt`\|`tool`), or `source: "send"` + `turn` | working |
| `agent.waiting` | `reason` (`permission`\|`question`\|`startup question`) | **needs you** |
| `agent.finished` | `status: "error"`; `source: "interrupt"`, `status: "interrupted"`; `via: "notify"` (Codex) | turn done |
| `agent.exited` | | the agent quit |

Matching an agent event to a session: `data.session` when present, else the agent session whose `dir ==
data.path` (`NotificationText.session(for:in:)`). Events spooled while pierd was down carry `spooled: true` and the
time the hook ran: ignore old ones for notifications.

**Sessions and tasks**: `task.created`, `session.started {name, location, path, command, agent?}`,
`session.stopped`, `session.renamed`, `session.sent`, `session.queued {name, turn}`, `session.unqueued`,
`session.mode {name, mode}`, `session.open` (a hint for other clients: ignore), `exec.finished {location, path, command,
exit_code}` (every client's exec, the app's own background commands included: never notify on it).

**Worktrees and locations**: `worktree.created {location, name, path, branch}`, `worktree.removed`,
`worktree.setup.{started,finished,failed}` and `worktree.archive.{started,finished,failed}` `{location, name,
path, script, log}` (failures set the envelope `error`), `location.added`, `location.removed`, `config.changed`,
`service.started|stopped|failed`.

**Box**: `client.paired`, `client.revoked {name, fingerprint}`, `pairing.invited`, `agents.found`.

**Chatter**: `transcript.changed {session, name, path, size}`.

The app synthesises "box connected / disconnected" from its own transport.

### 7.4 `transcript.changed`

Only for sessions whose transcript someone read in the last 8 s, throttled; it only says "read again now". Never
notify on it.

### 7.5 Posting events

`POST /v1/events {type, data?}` publishes an event (agents' hooks through `pierd hook`, `pierd emit`; gate
`before:event.emit`). Anything a
client posts reaches every stream, so `notify {title, body, path?}` posted by a script shows as a notification in
the app (9).

---

## 8. Diffs, review and git actions

There is **no git API** beyond review data. Patches and every git or GitHub action are shell commands the app builds
and runs through `POST /v1/exec` in the worktree.

### 8.1 Review inbox: `GET /v1/review[?all=1]`

Worktrees whose agent session is `finished` or `waiting` (every state with `all=1`) and that have changes or
unpushed commits; `[]` when none.

```json
[{ "location":"shop","worktree":"checkout-fix","path":"/home/octocat/code/shop-checkout-fix","branch":"checkout-fix",
   "head":"<sha>","base":"origin/main","upstream":"origin/checkout-fix","ahead":2,"behind":0,
   "files":[{"path":"a.ts","from":"old.ts","code":" M","added":10,"removed":3}],"added":10,"removed":3,
   "commits":[{"sha":"...","subject":"...","author":"...","when":"..."}],"base_ahead":2,
   "committed":[{"path":"b.ts","code":"A","added":5,"removed":0}],
   "session":"shop-checkout-claude-1x2y","agent":"claude","agent_state":"finished","state_since":"..." }]
```

* `files`: uncommitted changes vs HEAD; `code` is git's 2-character porcelain status (`" M"`, `"A "`, `"??"`, ...);
  `binary: true` for binaries; `added` / `removed` are their line totals.
* `commits` (≤ 20), `committed` (1-letter name-status codes) and `base_ahead`: what the branch has that `base` (the
  default branch, `origin/<default>` when present, else the local branch) lacks. `ahead` / `behind` are against the
  upstream. A worktree on the default branch only shows uncommitted work.
* One item per worktree (its best session: waiting > finished > idle > running). "Reviewed" marks are per device,
  kept by the app.

### 8.2 Per-turn changes: `GET /v1/locations/{loc}/worktrees/{wt}/touched`

`{"files": [{path, added, removed, created?, deleted?, at (ms), live?, session, agent, base: "turn"|"head"}]}`: the
files each agent's latest turn changed (for Claude Code, exactly, against the file as the turn found it). Cheap:
"+120 −30 in 5 files" per session and on Live Activities.

### 8.3 Patch of one file

1. `GET /v1/sessions/{name}/diff?file=PATH` (capability `diff`) → `{file, diff, untracked?, truncated?}`: the unified
   diff of one file against HEAD in the session's folder (an untracked file as all added), first 64 KB. `PATH`
   relative to the session folder or absolute inside it; `..` is refused.
2. Through exec (`GitActions`): uncommitted `git diff --no-color --find-renames HEAD -- [<from> ]<path>`; untracked
   `git diff --no-color --no-index -- /dev/null <path>; true`; committed on the branch `git diff --no-color
   --find-renames '<base>...HEAD' -- [<from> ]<path>`. Paths are single-quoted.

`POST /v1/exec`:

```json
{ "location": "shop/checkout-fix", "command": "git status --porcelain=v1 -b -z", "timeout": "60s" }
```

→ `{"exit_code": 0, "output": "...", "truncated": false}`. The command runs in the user's `$SHELL -lc` in the
location or worktree, with the worktree's environment (`PIER_*`, `PORT`). `output` is stdout
and stderr together, the **last 64 KB** (`truncated: true` when the head was dropped). `timeout` is a Go duration,
default 10 minutes, at most 1 hour; on timeout `exit_code` is `-1` and the output ends with `[pierd: stopped after
…]`. Gate `before:exec`; event `exec.finished`.

A chat has no location: `{"session": "<chat name>", "command": …}` (no `location`) runs in that chat's own folder
(next steps and AI titles for a chat). A session that is not a chat is refused (400).

### 8.4 Git actions through exec (commit, push, open a PR)

None is a route: the app composes one shell string (`GitActions`, `PRCommands`) and runs it with `POST /v1/exec`
(5-minute timeout for actions):

```text
commit : git add -A && printf %s '<base64 message>' | base64 -d | git commit -q -F -      # only when files changed
push   : … && git push -u origin HEAD 2>&1
PR     : … && printf %s '<base64 body>' | base64 -d | gh pr create --title '<subject>' --body-file - --base '<base without origin/>' 2>&1
discard: git restore --staged . && git checkout -- . && git clean -fd
PR info: gh pr view --json number,state,isDraft,url,title,reviewDecision 2>/dev/null     # exit 0 => JSON
status : git status --porcelain=v1 -b -z && printf '\n--pier-numstat--\n' && { git diff --numstat HEAD 2>/dev/null; true; }
detail : git show -s --format=%B '<sha>' && printf '\n--pier-stat--\n' && git show --shortstat --format= '<sha>'
```

* Steps are joined with `&&`. Messages and bodies travel as base64 so no quoting can break them; every other value
  is single-quoted (`GitActions.q`). Only send commands built by these helpers.
* The commit message is drafted from the agent's last message; the PR URL is read from the output with
  `https://\S+/pull/\d+`. A nonzero `exit_code` means show `output`.
* Pushes use the **box's** git credentials, and `gh` must be signed in on the box (`pierd doctor`). With no PR,
  `gh pr view` exits 1 with empty output.
* "Send back" = `POST .../send {text: "Changes requested: …", enter: true, when: "now", force: true}`.

### 8.5 Pull requests through exec

`PRCommands` names a PR by number and `--repo owner/name`, so it works from any location: `gh pr view … --json
<fields>`, a single file's diff cut out of `gh pr diff` on the box, `gh pr merge`, `gh pr comment`, `gh pr review`
(`--approve`, `--request-changes`, `--comment`), `gh pr close`, `gh pr ready`. Bringing a PR into a worktree: for a
same-repository PR, `fetchHead` in the main checkout, create the worktree (2.4), then `trackHead` in it; for a fork,
create the worktree on a throwaway branch and run `checkoutFork` (`gh pr checkout`). The Home screen's PR, CI and git
activity widgets are exec commands too (`HomeCommands`). The box needs `git`, `gh` and `claude` (for AI drafts) on
its PATH.

---

## 9. Notifications

Two paths:

* **Push** (PUSH.md): pierd sends APNs alerts, Live Activity updates and widget reloads itself when push is
  configured. While a box's push is registered and answering, the app does not post its own local "needs you" / "done"
  notifications for that box.
* **Local notifications** from the event stream while the app runs (and on background refresh).
  `NotificationText.make(for:box:sessions:locations:)` turns an event into one:

| Event | Condition | Notification (key) |
| --- | --- | --- |
| `agent.waiting` | not a spooled event older than 10 minutes | "✋ Needs you · <session>", body `<agent> · <repo / worktree> · <box>` + `ask` summary; Allow/Deny actions only for a permission (`waiting\|box\|session`) |
| `agent.finished` | `data.source != "interrupt"`, not stale | "✅ Done · <session>", or "⚠️ Failed" when `status: "error"` (`finished\|box\|session`) |
| `worktree.setup.failed`, `worktree.archive.failed` | | "Setup / Archiving failed for <name>", body the envelope `error` |
| `service.failed` | | "Service failed" |
| `notify` | `data.title` present | title and body as posted (7.5) |

The key replaces an earlier notification for the same thing. Person-level toggles (waiting, finished) apply to both
paths. Categories and actions are the same for local and push notifications (PUSH.md).

---

## 10. Clients and pairing invites

| Route | Answer |
| --- | --- |
| `GET /v1/clients` | `[{name, fingerprint, paired_at, you?}]`; `you` marks the caller |
| `DELETE /v1/clients/{name\|fingerprint}` | `{"removed": name}`; gate `before:client.revoke`; event `client.revoked`. Any paired client may remove any client, itself included (the app's "unpair"): a paired client is a full-control principal (it has `exec`). The revoked client's connections close a second later, after the answer |
| `POST /v1/pair/invite` `{"for":"<name>"}` (optional) | `{"link":"pier://HOST:PORT?code=…&fp=…","expires":"RFC3339"}` |

An invite is the same as a `pierd pair` link: single use, 10 minutes, at most 10 per 10 minutes from all clients
together (429 beyond), gated by `before:pairing.invite`, never logged or put in an event (`pairing.invited` carries
only `for` and `by`). 501 when the box does not know the address to advertise. The app shows the link as a QR code
for another device, or bundles several boxes' invites into one join link (PROTOCOL.md §1.2). A box without the route
answers 404/405 (`PairInviteError.unsupported`).

---

## 11. Routes pierd does not serve

Runs and gates (`/v1/runs…`, `run.*` events), `/v1/turns/{id}[/wait]`, terminal attach (`/attach`) and port streams
(`/v1/tcp`), `/v1/ports`, `/v1/processes`, the memory guard, the phone web app and its token, units, shares, teams,
flows and webhooks, browsers and visual diffs, `/v1/hooks`, `/v1/env`, secrets, skills, integrations install over
HTTP, self-upgrade, agent CLI install, session commands/files/subagents/fork/rewind, worktree log/sync/pause/resume/
files/rename, location clone, and service logs. A client asking for one gets a plain-text 404.

---

## 12. Gotchas

1. **Permissions are not brokered.** Allow/Deny is reading the screen, parsing a numbered menu and typing the
   option's digit with `force: true` (5.3). Handle "no menu found" with the screen and a key bar.
2. **Git and PR actions are not routes**: shell strings through `POST /v1/exec` (8.4, 8.5).
3. **`send` without `when` skips the waiting check.** Always send `when: "now"` or `"idle"`, and an `idem_key`.
4. **The first prompt of a task rides in argv** (128 KB on Linux); `send` has no such limit (2 MB body).
5. **The transcript has no tool output, no thinking and not the reply being written**: combine it with `draft`
   and `transcript/tool/{id}`. Items are sent again: upsert by `id`. `transcript.changed` only flows while someone
   reads (8 s).
6. **Events only flow while connected**: resume with `?since=SEQ` (at most `max`, default 5000 events back).
7. **Removing a worktree kills its sessions**, and answers 202 (asynchronous) when an archive script runs.
8. **Times have nanosecond fractions** (`…42.53987405Z`): Foundation's `ISO8601DateFormatter` rejects them; use
   `JSONDecoder.pier` (`RFC3339.parse`). Go's zero time can appear as `0001-01-01T00:00:00Z`. Pass `SendResult.at`
   back as `after=` formatted with `RFC3339.format` (it keeps the nanoseconds).
9. `agent_state: "running"` is the default for an agent with no hook data; `fidelity` says how much to trust it
   (`screen` for the first seconds of a session, `hooks` after).
10. `ask` is only in `GET /v1/sessions` (and turns), not in `agent.waiting`; `ask.message` reads "Claude needs your
    permission" even for `AskUserQuestion`.
11. `when: "idle"` while any turn is open (even a stray `pending` one) is held: `{sent: false, queued: true}`. A
    digit sent to an agent that already finished starts a new turn: send keys only while it waits.
12. Unknown routes answer plain text, not `{"error"}`.

---

## 13. Swift client (PierKit)

`Packages/PierKit/Sources/PierKit`: `API/` (clients), `Models/` (Codable payloads), `Support/` (helpers). Verified
against a live box with `pierctl selftest` and against captured fixtures (`Tests/PierKitTests/Fixtures`).

### 13.1 Transport and errors

* `BoxClient` (one paired box: TLS dial, pinned HTTP/2 connection, `X-Pier-Origin`) conforms to `PierTransport`
  (`send(method, path, body) -> (status, data)`, `stream(path)`, `reset()`). It also has `requestStatus(...)` (the
  2xx status, e.g. 200 vs 202) and `ping()`.
* `BoxAPI(client:)` / `BoxAPI(transport:)` is the concrete `PierBoxClient`.
* Errors: `BoxError(status, error, code)` for box-level failures (JSON `{"error","code"}` or a plain-text body, with
  `kind` mapping `code`); `PierError` for the rest: `.unauthorized` (401, revoked), `.pinMismatch`, `.rateLimited`,
  `.api`, `.pairingRejected`, `.invalidLink`, `.tls`, `.transport`, `.timeout`, ...

### 13.2 `PierBoxClient`

`API/PierBoxClient.swift`, one method per route:

| Area | Methods |
| --- | --- |
| Info | `info()`, `stats()`, `doctor()` |
| Locations | `locations()`, `worktreeStatuses(location:)`, `branches(location:)`, `createWorktree(location:_:)`, `removeWorktree(location:worktree:force:deleteBranch:)` → `WorktreeRemoval` (`.removed` / `.archiving`) |
| Agents | `createTask(_:)`, `startSession(_:)`, `installableAgents()` |
| Sessions | `sessions()`, `screen(session:history:)`, `draft(session:)`, `send(session:_:)`, `keys(session:_:)`, `interrupt(session:)`, `kill(session:)`, `rename(session:title:)`, `controls(session:)`, `setMode(session:mode:)`, `heldPrompts`, `cancelHeld`, `sendHeldNow`, `turns`, `waitForSession`, `uploadAttachment` |
| Needs you | `answerQuestions(session:tool:answers:)` |
| Transcript | `transcript(session:since:gen:)`, `transcriptBefore(session:before:limit:)`, `toolDetail(session:id:)` |
| Events | `events(since:)` → `AsyncThrowingStream<PierEvent, Error>` |
| Review | `review(all:)`, `touched(location:worktree:)`, `fileDiff(session:file:)`, `exec(location:command:timeout:)` |
| Connection | `reset()` |

`BoxAPI` adds `pairInvite()`, the Home commands (`BoxAPI+Home.swift`) and `events(since:onState:)`. `PushClient`
covers `/v1/push/*` (PUSH.md). `events` reconnects with backoff (1 s doubling to 30 s, ±20 % jitter), resumes with
`?since=<max seq>`, skips keepalives and undecodable lines, and ends only on non-retryable errors (revoked, pin
mismatch, 4xx).

### 13.3 Models

Field names and optionality follow sections 1 to 8 and the Go structs; every model has a public memberwise `init`
with defaults and a tolerant decoder (missing keys, `null` lists).

| File | Types |
| --- | --- |
| `Models/BoxModels.swift` | `BoxInfo`, `AgentPreset`, `AdapterCaps`, `AgentCLI`, `BoxStats`, `DoctorCheck` |
| `Models/LocationModels.swift` | `Location`, `Worktree`, `Scripts`, `WorktreeStatus`, `Commit`, `BranchList`, `WorktreeRequest` |
| `Models/SessionModels.swift` | `Session`, `Ask`, `TaskRequest`, `TaskResult`, `SessionRequest`, `SendResult`, `InterruptResult`, `SessionControls`, `HeldPrompt`, `Turn`, `WaitResult`, `Draft`, `Attachment` |
| `Models/QuestionModels.swift` | `Question`, `QuestionOption`, `QuestionAnswer` |
| `Models/TranscriptModels.swift` | `TranscriptPage`, `TranscriptItem`, `CrewMember`, `ArtifactRef`, `Signals`, `ToolDetail` |
| `Models/ReviewModels.swift` | `ReviewItem`, `ReviewFile`, `ReviewCommit`, `TouchedFile`, `FileDiff`, `ExecResult`, `PullRequest` |
| `Models/Common.swift` | `AgentState` (with `.unknown(String)`), `SendRequest`, `ControlKey`, `PierEvent`, `BoxError`, `WorktreeRemoval`, `RFC3339`, `JSONDecoder.pier` |
| `JSON.swift` | `JSONValue`, `typealias JSON = [String: JSONValue]`, `PierJSON` (shared coders) |

Use explicit `CodingKeys`, not `.convertFromSnakeCase`: keys are mixed (`oldStart` in hunks, `midTurn`).

### 13.4 Helpers

| Helper | Purpose |
| --- | --- |
| `TranscriptStore` | the upsert, reset and gap-filling merge of 6.3 (`apply`, `absorbHistory`, `gapBefore`, `hasMoreBefore`, pending prompts) |
| `MenuParser`, `parseMenu(_:)`, `permissionActions(_:)` | the menu parsing and Allow/Always/Deny mapping of 5.3; also `questionForm(in:)`, `lastMessage` |
| `Ask.classify`, `Session.needsYouKind`, `canUseAnswerEndpoint` | permission vs question (5.3, 5.4) |
| `GitActions` | the exec strings of 8.3 and 8.4 and their parsers (`approveCommand`, `discard`, `prView`, `diffUncommitted`, `diffCommitted`, `commitDetail`, `statusCommand`, `parseStatus`, `parseDiff`, `sendBack`, `pullRequestURL`) |
| `PRCommands`, `HomeCommands` | pull request and Home screen commands (8.5) |
| `NotificationText`, `DisplayNames` | notification text and names (9) |
