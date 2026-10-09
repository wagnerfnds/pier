# pierd API surface

Every route pierd serves, the handler behind it, and who calls it. The app's `docs/PROTOCOL.md` and
`docs/API.md` describe the protocol (paths, JSON shapes, error format, TLS and pairing) and payloads in detail.

Handlers are in `internal/box` unless said otherwise. "App" names the PierKit method
(`Packages/PierKit/Sources/PierKit`) and the main app files that use it.

All routes are reachable by paired clients over TLS 1.3 (mutual, Ed25519, pinned) on pierd's listener, and
by the box's own user over the Unix socket `$PIER_HOME/box/pierd.sock` (the `pierd` CLI, agents' hooks).

## Wire (`internal/wire`)

| Route | Handler | Caller |
|---|---|---|
| `POST /v1/pair` (HTTP/1.1, exporter-bound proof) | `wire/server.go` `handlePair` | App `Pairing.pair` (onboarding, QR, pasted link); `pierd client pair` |
| `GET /v1/ping` | `wire/server.go` `handlePing` | App `BoxClient.ping` (H2Connection health, revocation check) |
| `POST /v1/clients/changed` (socket only) | `wire/server.go` | `pierd revoke` |

## Box

| Route | Handler | Caller |
|---|---|---|
| `GET /v1/info` | `info.go` `handleInfo` | App `info()`: BoxConnection, HeadlessBoxes, PushSupport |
| `GET /v1/stats` | `stats.go` `handleStats` | App `stats()`: BoxConnection (box card); `pierd stats` |
| `GET /v1/doctor` | `doctor.go` `handleDoctor` | `pierd doctor`; pierctl selftest (the app has `doctor()` but no caller today) |
| `GET /v1/agents` | `info.go` `listAgentCLIs` | pierctl selftest (`installableAgents`); kept small: claude and codex, no installer |

## Locations and worktrees

| Route | Handler | Caller |
|---|---|---|
| `GET /v1/locations` | `api.go` `listLocations` | App `locations()`: BoxConnection, HeadlessBoxes; `pierd locations` |
| `POST /v1/locations` | `api.go` `addLocation` | `pierd location add` |
| `DELETE /v1/locations/{name}` | `api.go` `removeLocation` | `pierd location rm` |
| `GET /v1/locations/{name}/branches` | `helpers.go` `listBranches` | App `branches()`: ComposeModel, WorktreeParts |
| `GET`/`PUT /v1/locations/{name}/config` | `repoconfig.go` `getConfig`/`putConfig` | `pierd location config [--set FILE]` |
| `POST`/`DELETE /v1/locations/{name}/config/trust` | `repotrust.go` | `pierd location config --trust HASH` / `--untrust` |
| `POST /v1/locations/{name}/worktrees` | `api.go` `addWorktree` (setup script, autostart services) | App `createWorktree()`: ComposeModel, PullRequestStore, WorktreeParts; `pierd worktree new` |
| `DELETE /v1/locations/{name}/worktrees/{worktree}` (`force`, `delete_branch`; 202 while the archive script runs) | `api.go` `removeWorktree` | App `removeWorktree()`: EndSessionSheet, Housekeeper (Faxina), WorktreeParts; `pierd worktree rm` |
| `POST /v1/locations/{name}/worktrees/{worktree}/attachments` | `attachments.go` `worktreeAttachment` | App ComposeSupport (photos before the agent exists) |
| `GET /v1/locations/{name}/worktrees/{worktree}/touched` | `touched.go` `worktreeTouched` | App `touched()`: LiveActivitySync |
| `GET /v1/locations/{name}/worktrees/{worktree}/services` | `wtservices.go` `listWorktreeServices` | App `worktreeServices()`: Housekeeper; `pierd service list` |
| `POST /v1/locations/{name}/worktrees/{worktree}/services/{service}/{start\|stop\|restart}` | `wtservices.go` `serviceAction` | App `serviceAction()`: Housekeeper; `pierd service start…` |
| `GET /v1/worktrees[?location=]` | `worktreeops.go` `listWorktreeStatuses` | App `worktreeStatuses()`: EndSessionSheet, Housekeeper, Project/Worktree screens |
| `GET /v1/services` | `services.go` `handleServices` | App `services()`: HomeStore, Housekeeper; `pierd services` |
| `GET /v1/review[?all=1]` | `review.go` `review` | App `review()`: ReviewStore, PullRequestStore/Screen/Sheets, SessionSignals; push engine |
| `POST /v1/exec` | `orchestrate.go` `handleExec` | App `exec()`: GitActions, PRCommands, AIDraft, HomeCommands (PRs, CI, git activity), ReviewStore, DiffScreen, EndSessionSheet, Housekeeper, WorktreeParts |

`exec` runs a login shell in the location or worktree with its environment; the app's PR, commit, AI draft
and Home widgets are shell strings run this way, so the box needs `git`, `gh` and `claude` for them.

## Agents and sessions

| Route | Handler | Caller |
|---|---|---|
| `POST /v1/tasks` | `tasks.go` `addTask` | App `createTask()`: ComposeModel, TaskCreator (Shortcuts); `pierd task new` |
| `GET /v1/sessions` | `api.go` `listSessions` | App `sessions()`: BoxConnection, BackgroundRefresh, intents, widgets; push engine |
| `POST /v1/sessions` (agent, command, or `home`) | `api.go` `addSession` | App `startSession()`: ComposeModel, PullRequestStore; `pierd session new` |
| `DELETE /v1/sessions/{name}` | `api.go` `removeSession` | App `kill()`: EndSessionSheet, Housekeeper, SessionViewModel |
| `PATCH /v1/sessions/{name}` (title) | `titles.go` `renameSession` | App `rename()`: SessionScreen, SessionViewModel, ProjectsPlaceholder |
| `GET /v1/sessions/{name}/screen?history=` | `api.go` `screen` | App `screen()`: SessionViewModel, SessionSignals, BoardScreen, LiveActivitySync, intents; push engine (menus) |
| `GET /v1/sessions/{name}/draft` | `draft.go` `draft` | App `draft()`: SessionViewModel; push engine |
| `POST /v1/sessions/{name}/send` (`when`, `idem_key`, `force`, `enter`) | `orchestrate.go` `sendToSession` | App `send()`: ComposerBar, BoardScreen, Notifications (reply action), AgentIntents, AppModel |
| `POST /v1/sessions/{name}/keys` | `controls.go` `sessionKeys` | App `keys()`: NeedsYouCard, SessionViewModel (menus, question digits) |
| `POST /v1/sessions/{name}/interrupt` | `controls.go` `interruptSession` | App `interrupt()`: ComposerBar (Stop), SessionScreen |
| `POST /v1/sessions/{name}/answer` | `answer.go` `answerSession` | App `answerQuestions()`: SessionViewModel (falls back to digit keys) |
| `GET /v1/sessions/{name}/controls` | `controls.go` `sessionControls` | pierctl selftest (the mode list; the app reads the mode from `mode`'s answer) |
| `POST /v1/sessions/{name}/mode` | `controls.go` `setMode` | App `setMode()`: ConversationView, NeedsYouCard, SessionScreen |
| `GET /v1/sessions/{name}/wait?for=&after=&timeout=` | `orchestrate.go` `waitForSession` | `pierd session send --wait`, `pierd session wait`; pierctl `wait` |
| `GET /v1/sessions/{name}/turns` | `orchestrate.go` `listTurns` | `pierd session turns`; pierctl selftest |
| `GET /v1/sessions/{name}/queue` | `inbox.go` `listQueue` | App `heldPrompts()`: SessionViewModel |
| `DELETE /v1/sessions/{name}/queue/{turn}` | `inbox.go` `cancelQueued` | App `cancelHeld()`: ComposerBar |
| `POST /v1/sessions/{name}/queue/{turn}/send` | `inbox.go` `sendQueued` | App `sendHeldNow()`: ComposerBar |
| `POST /v1/sessions/{name}/attachments` | `attachments.go` `sessionAttachment` | App `uploadAttachment()`: SessionViewModel |
| `GET /v1/sessions/{name}/diff?file=` | `sessiondiff.go` `sessionDiff` | App `fileDiff()`: PullRequestStore |
| `GET /v1/sessions/{name}/transcript?since=&gen=` / `?before=&limit=` | `transcriptapi.go` `transcript` (items, `signals` incl. background jobs, `crew`) | App `transcript()`/`transcriptBefore()`: SessionViewModel, SessionSignals (signals only, `since=2000000000`), LiveActivitySync; push engine (last reply, background work) |
| `GET /v1/sessions/{name}/transcript/tool/{id}` | `transcriptapi.go` `toolDetail` | App `toolDetail()`: SessionViewModel |

## Events

| Route | Handler | Caller |
|---|---|---|
| `GET /v1/events[?since=SEQ&max=N]` (NDJSON, `\n` keepalive every 25 s, resume by seq) | `api.go` `streamEvents` | App `EventStreamer` / `BoxClient.events`: EventHub (one stream per box); `pierd events` |
| `POST /v1/events` | `api.go` `emit` | Agents' hooks (`pierd hook`); `pierd emit` |

The push engine follows the bus in-process (`internal/push`), not this route.

Event types pierd publishes, and what the app does with them:

| Type | App reaction |
|---|---|
| `agent.ready`, `agent.started`, `agent.waiting`, `agent.finished`, `agent.exited` (from hooks or the screen) | EventHub refreshes sessions; SessionViewModel ticks; HomeStore/BoardScreen re-read signals; local notifications (`agent.waiting`, `agent.finished`); ReviewScreen reloads |
| `session.started`, `session.stopped`, `session.renamed`, `session.sent`, `session.queued`, `session.unqueued`, `session.mode`, `session.open` | sessions refresh; SessionViewModel ticks |
| `transcript.changed` (while a client reads the transcript) | SessionViewModel refetches the transcript |
| `task.created` | sessions and locations refresh |
| `worktree.created`, `worktree.removed`, `worktree.{setup,archive}.{started,finished,failed}` | locations refresh; ReviewScreen reloads; local notification on `*.failed` |
| `location.added`, `location.removed`, `config.changed` | locations refresh |
| `service.started`, `service.stopped`, `service.failed` | HomeStore refreshes services; local notification on `service.failed` |
| `exec.finished`, `client.paired`, `client.revoked`, `pairing.invited`, `agents.found` | none (informational) |

pierd has no runs, so no `run.*` events.

## Clients and pairing invites

| Route | Handler | Caller |
|---|---|---|
| `GET /v1/clients` | `pairinginvite.go` `listClients` | pierctl / scripts (`you` marks the caller) |
| `DELETE /v1/clients/{name\|fingerprint}` | `pairinginvite.go` `revokeClient` | App `AppModel.unpair` (removes itself; pierd now allows that and closes its connections a second later) |
| `POST /v1/pair/invite` `{"for":"name"?}` → `{"link":"pier://…","expires":"RFC3339"}` | `pairinginvite.go` `invite` | New: a paired device shows a QR for another device. Single use, 10 minutes, at most 10 per 10 minutes, gated by `before:pairing.invite` hooks |

## Push (`internal/push`, when `$PIER_HOME/push.json` exists)

Served on pierd's listener, where the app registers, and on any extra addresses `listen` in push.json lists.
Same TLS identity and paired clients; an extra listener serves only these routes and `GET /v1/ping` (`wire.Server.NoPairing`: no `POST /v1/pair` there).

| Route | Caller |
|---|---|
| `GET /v1/push/info` | App `PushClient.info` (PushManager, background refresh probe) |
| `PUT /v1/push/device` | App `PushClient.register` |
| `DELETE /v1/push/device` | App `PushClient.unregister` (unpair) |
| `PUT`/`DELETE /v1/push/activities/{box}/{session}` | App `PushClient` Live Activity tokens |
| `POST /v1/push/test` | App Settings → Notificações |

The engine (`internal/push/engine`) reads `info`, `sessions`, `locations`, `screen`, `draft`, `review` and
`transcript` through pierd's handler in-process (`internal/push/boxapi`), and is fed from the event bus.
