# pierd

pierd is the box server of **Pier**: it runs on a development box (a Linux server with git, tmux and the agent
CLIs) and serves the Pier app over the network. It keeps the box's locations (repositories) and their git
worktrees, runs coding agents (Claude Code, Codex) and plain shells in tmux sessions, knows what each agent is
doing turn by turn through the agents' own hooks, reads their conversations, runs the worktrees' dev servers,
and sends push notifications to the paired phones.

The app pairs with a box once (a `pier://` link or its QR code) and then talks to it directly over mutual
TLS 1.3 with Ed25519 keys and HTTP/2; there is no account and no relay.

## Licence

pierd is MIT licensed ([LICENSE](LICENSE)); third-party notices are in the repository's
[NOTICE](../../NOTICE).

## Build

Go 1.25 or newer, standard library only:

```sh
go build ./cmd/pierd                                          # this machine
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o pierd-linux-amd64 ./cmd/pierd
go test ./... && go vet ./...
scripts/smoke.sh                                              # end to end, see Tests
```

## Install on a box

Copy the binary to the box (e.g. `~/.local/bin/pierd`), then, as the user the agents run as:

```sh
pierd install --listen 192.0.2.10:7444   # writes and starts ~/.config/systemd/user/pierd.service,
                                           # then installs the agents' hooks (see Agent hooks)
sudo loginctl enable-linger $USER          # once, so pierd keeps running after you log out
pierd pair                                 # prints a single-use pier:// link (10 minutes) and its QR code; scan it or paste the link in the app
pierd doctor                               # what works and what to fix
```

Without `--listen`, pierd listens on the box's tailnet address (100.64.0.0/10) only; it never picks an address
on every interface by itself. `pierd uninstall` removes the service (state stays). The unit is a plain user
unit: `systemctl --user status pierd`, logs in `~/.config/pier/box/pierd.log`.

### One box, several people

Each person gets an Ubuntu user of their own and runs their own pierd as that user: their own agent logins, sessions,
pairings and push setup, kept apart by the system's permissions. Give each pierd its own port, a name the apps show,
and a range of worktree ports no one else's pierd hands out:

```sh
pierd install --listen 192.0.2.10:7445 --name pier-maria --ports 42000-42999
```

`--name` and `--ports` are kept in `~/.config/pier/box/name` and `ports` for later installs (default: the hostname,
and 41000-48999).

Then add the repositories the app should see:

```sh
pierd location add shop ~/code/shop
```

A paired device can also invite another one: `POST /v1/pair/invite` answers a fresh `pier://` link (single
use, 10 minutes) for the app to show as a QR code. `pierd clients` lists paired devices, `pierd revoke NAME`
removes one (its open connections close within seconds).

## Configuration

| Where | What |
|---|---|
| `$PIER_HOME` (default `~/.config/pier`) | `box/` (identity, `clients.json`, `locations.json`, `ports.json`, `journal/`, `turns.json`, logs, `pierd.sock`), `push.json`, `AuthKey.p8`, `push-state.json` |
| `$PIER_USER_DIR` (default `~/.pier`) | `hooks.json` (box hooks: `{"hooks":[{"on":"before:worktree.create","run":"…"}]}`), `env.json` (`{"env":{…}}` for every worktree) |
| repository `.pier/config.json` | what every worktree of the repository gets (below). It runs only once trusted on the box: `pierd location config NAME --trust HASH` |
| box-local location config | the same keys, for one box, laid over the repository's: `pierd location config NAME --set file.json` |
| `$PIER_TMUX_SOCKET` | the tmux server's name (default `pier`) |

A location config:

```json
{
  "setup": "bash scripts/setup-worktree.sh",
  "archive": "bash scripts/drop-worktree-db.sh",
  "ports": 2,
  "env": { "DB_NAME": "shop_$PIER_PORT" },
  "services": [ { "name": "web", "run": "npm run dev -- --port $PIER_PORT", "autostart": true } ],
  "hooks": [ { "on": "worktree.created", "run": "echo $PIER_WORKTREE_PATH" } ],
  "agents": [ { "id": "claude", "command": "claude --model opus" } ]
}
```

Everything run in a worktree (sessions, setup and archive scripts, services, `exec`, repository hooks) gets
`PIER_BOX`, `PIER_LOCATION`, `PIER_ROOT_PATH`, `PIER_WORKTREE_PATH`, `PIER_WORKTREE_NAME`,
`PIER_WORKTREE_SLUG`, `PIER_BRANCH`, `PIER_PORT`, `PIER_PORT_1`…, and `PORT`. Sessions also get
`PIER_SESSION` and `PIER_AGENT`; hooks get `PIER_EVENT` and `PIER_<KEY>` for the event's data.

Each worktree gets its own block of 10 ports from 41000 (kept in `ports.json`); a new block is never one where
something already listens.

## Agent hooks

pierd knows an agent's state (working, needs you, done) from the agent's own hooks: Claude Code's settings
and Codex's `hooks.json` and `notify` run `pierd hook TOOL EVENT`, which hands the event to the running pierd
(or spools it while pierd is down). `pierd integrations install claude|codex|all` installs them (in
`$CLAUDE_CONFIG_DIR` / `$CODEX_HOME` when set; running it again changes nothing);
`pierd integrations` says which hooks each agent has. Codex asks once to trust new hooks (`/hooks`).

Without any hooks pierd still follows agents by reading their screens, less precisely.

## Push notifications

Push is on when `$PIER_HOME/push.json` exists:

```json
{ "key_id": "ABC123DEFG", "team_id": "TEAMID1234", "bundle_id": "com.example.pier" }
```

All three keys are required: `bundle_id` is the app's bundle id (`PIER_BUNDLE_ID` in the app's
`Config/Signing.xcconfig`), the topic of every push. The APNs auth key goes at `$PIER_HOME/AuthKey.p8` (mode 0600;
`key_path` moves it). The push routes (`/v1/push/info`, `device`, `activities/{box}/{session}`, `test`) are on
pierd's own listener, where the app registers. Optional: `listen` (extra addresses that also serve them, comma
separated; none by default),
`activity_date_epoch` (`"unix"` default, or `"reference"`) and `recaps` (`false` turns off the AI recaps). pierd
logs every APNs answer; the behaviour (alerts, Live Activities, widgets, push-to-start, debouncing) is the
contract in the app's `docs/PUSH.md`.

## Commands

`pierd help` lists them all: `serve`, `install`, `uninstall`, `pair`, `clients`, `revoke`, `id`,
`doctor`, `version`, `hook`, `integrations`, `client` (a paired client for scripts: `pierd client pair LINK`,
then `pierd client GET /v1/sessions`), and the box commands over the local socket: `locations`,
`location add|rm|config`, `worktree new|rm`, `services`, `service list|start|stop|restart`, `sessions`,
`session new|send|screen|rename|wait|turns|kill`, `task new`, `exec`, `stats`, `info`, `emit`, `events`.

## API

The routes, their handlers and the app code that calls each one: [docs/API-SURFACE.md](docs/API-SURFACE.md).
The wire protocol is described in the repository's `docs/PROTOCOL.md` and `docs/API.md`. Pairing binds its
proof to the TLS exporter label `EXPORTER-pier-pair-v1` and prefixes it with `pier pair v1`; requests name their
tool in `X-Pier-Origin`.

## Tests

`go test ./...` runs the unit and integration tests (tmux and git needed; the systemd scope test runs with
`PIER_TEST_SYSTEMD=1` on a box with a user manager). `scripts/smoke.sh` builds pierd, starts it with a
temporary `PIER_HOME` and its own tmux server, pairs a client the way the app does and calls the main routes;
`SMOKE_REPO=~/code/sandbox` runs it against a real repository, `PIERD=path` against a given binary.
