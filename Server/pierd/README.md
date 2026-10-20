# pierd

pierd is the box server of **Pier**: it runs on a development box (a Linux server or a Mac with git, tmux and the
agent CLIs) and serves the Pier app over the network. It keeps the box's locations (repositories) and their git
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

On the machine that runs the agents (a Linux server or a Mac), as the user the agents run as:

```sh
curl -fsSL https://docktopier.com/install.sh | sh
# or: npm install -g pierd && pierd setup
# or: brew install wagnerfnds/tap/pierd && pierd setup
```

The script downloads the release for this system from GitHub (`pierd-v*` tags, checked against their SHA-256), puts
it in `~/.local/bin` and runs `pierd setup`, which:

- installs Claude Code, Codex and the GitHub CLI in `~/.local/bin` where they are missing, with no sudo (`pierd tools
  install`, below);
- runs pierd as a user service on every interface, port 7444 (`~/.config/systemd/user/pierd.service`; a launchd agent
  on a Mac) and installs the agents' hooks (see Agent hooks);
- adds the git repositories in the usual folders (`~/code`, `~/Projects`, `~/src`, `~/Developer`, …; `--repos DIR`
  for others) as locations;
- prints a single-use `pier://` link (10 minutes) and its QR code: scan it with the app, or paste the link. On a Mac,
  at its own screen, it hands the link to the Pier app, which pairs with that Mac by itself.

On Linux, setup also turns on lingering, so pierd keeps running after you log out: `loginctl enable-linger`, which
systemd lets a user do for themselves where polkit runs; where it does not (many containers), setup and `pierd doctor`
say so, and an admin runs `sudo loginctl enable-linger USER` once. `pierd doctor` says what works and what to fix,
`pierd pair` prints a new link any time, and running `pierd setup` again keeps what was chosen before.

The link names the address the app should dial: the box's public IPv4 address when it has one, else (a Mac) its
Bonjour name `<name>.local`, else a tailnet address, else a LAN one; `--address HOST[:PORT]` says otherwise. pierd
answers only paired devices (mutual TLS with pinned keys) and pairing needs the single-use link, so a server with a
public address needs no VPN; behind NAT, forward the port or use a VPN such as Tailscale. `--listen ADDR:PORT` limits
pierd to one address. The other flags: `--name`, `--ports` (below), `--no-projects`, `--no-integrations`, `--no-tools`
(or `PIERD_NO_TOOLS=1`, which the install script passes on), `--no-open`, and `--no-service` when pierd already runs
under a supervisor of your own (a container): setup only adds the projects and pairs.

### The agents and the GitHub CLI

`pierd tools` says where Claude Code, Codex and the GitHub CLI are; `pierd tools install [claude] [codex] [gh]` installs
the missing ones (all three without names; `--force` installs again), each in `~/.local/bin` with no sudo: Claude Code
and Codex through their own installers (`https://claude.ai/install.sh`; Codex's standalone
`https://chatgpt.com/codex/install.sh`, falling back to the binary of its latest GitHub release, checked against the
SHA-256 GitHub keeps with it), the GitHub CLI from its latest release's archive, checked against the release's checksums
file. Nothing is installed whose checksum does not match. The app asks for the same through `POST /v1/tools/install`,
and signs the three in through `/v1/logins`: pierd runs the CLI's own sign-in (`claude auth login`, `codex login
--device-auth`, `gh auth login --web`) in a session of its own, reads the link and the code off its screen for the app,
and calls it done once the CLI's own status agrees (the app's docs/API.md §2.10.1).

Underneath, `pierd install [--listen ADDR:PORT]` writes and starts the service and installs the hooks;
`pierd uninstall` removes the service (state stays). The unit is a plain user unit: `systemctl --user status pierd`,
logs in `~/.config/pier/box/pierd.log`.

To build it yourself instead: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o pierd ./cmd/pierd`, copy
the binary to `~/.local/bin` on the box, then `pierd setup`.

### From anywhere: the Pier tunnel

A box the apps cannot dial from outside (a Mac or a server at home, behind NAT) is reached through the Pier tunnel,
with nothing to set up: pierd keeps a connection out to `t.docktopier.com`, the box gets a name there
(`<id>.t.docktopier.com`, which `pierd relay` and `pierd setup` print) and pairing links carry it. The app dials the
box's own address first and the tunnel when that does not answer; inside runs the same mutual TLS, pinned to the keys
from pairing, so the tunnel only carries bytes it cannot read. `pierd relay off` turns it off; `pierd relay default`
back on.

Or run a relay of your own on any server with a public address. It is the same binary:

```sh
# on the server (a small VPS): pierd without setting up a box, then the relay as a user service on port 7443,
# with a token boxes must present
curl -fsSL https://docktopier.com/install.sh | PIERD_NO_SETUP=1 sh
~/.local/bin/pierd relay install        # prints: pierd relay use 203.0.113.7:7443 --token …
# on the box (or at setup: pierd setup --relay 203.0.113.7 --relay-token …)
pierd relay use 203.0.113.7 --token …
pierd relay                             # connected?
```

`pierd relay serve --public` is the Pier tunnel's own mode (open to any box, per-box limits, no addresses in the log);
`deploy/tunnel/deploy.sh root@HOST` installs it as a service on port 443 of a fresh Ubuntu server.

The box keeps a connection out to the relay and opens one more for each app connection; the relay joins the two.
Inside runs the same mutual TLS as on a direct connection, pinned to the keys exchanged at pairing, so the relay only
carries bytes it cannot read or alter (the protocol: the app's docs/PROTOCOL.md §10). Pairing links name the relay and
`GET /v1/info` reports it, so paired apps start using it by themselves: the box's own address at home, the relay away
from it. `pierd relay off` stops using it; `pierd relay serve --open` runs a relay any box may use.

### One box, several people

Each person gets an Ubuntu user of their own and runs their own pierd as that user: their own agent logins, sessions,
pairings and push setup, kept apart by the system's permissions. Give each pierd its own port, a name the apps show,
and a range of worktree ports no one else's pierd hands out:

```sh
pierd setup --listen 192.0.2.10:7445 --name pier-maria --ports 42000-42999
```

`--name` and `--ports` are kept in `~/.config/pier/box/name` and `ports` for later installs (default: the hostname,
and 41000-48999). A repository setup did not find: `pierd location add shop ~/code/shop`.

A paired device can also invite another one: `POST /v1/pair/invite` answers a fresh `pier://` link (single
use, 10 minutes) for the app to show as a QR code. `pierd clients` lists paired devices, `pierd revoke NAME`
removes one (its open connections close within seconds).

## Configuration

| Where | What |
|---|---|
| `$PIER_HOME` (default `~/.config/pier`) | `box/` (identity, `clients.json`, `locations.json`, `ports.json`, `journal/`, `turns.json`, `accounts.json` and `accounts/`, `mcp.json`, `prepare.json`, `previews.json`, `settings.json`, `base/` (each project's base, below), logs, `pierd.sock`), `push.json`, `AuthKey.p8`, `push-state.json` |
| `$PIER_USER_DIR` (default `~/.pier`) | `hooks.json` (box hooks: `{"hooks":[{"on":"before:worktree.create","run":"…"}]}`), `env.json` (`{"env":{…}}` for every worktree) |
| repository `.pier/config.json` | what every worktree of the repository gets (below). It runs only once trusted on the box: `pierd location config NAME --trust HASH` |
| box-local location config | the same keys, for one box, laid over the repository's: `pierd location config NAME --set file.json` (replaces it) or `--merge file.json` (`-`: stdin; lays keys over it) |
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
  "agents": [ { "id": "claude", "command": "claude --model opus" } ],
  "preview": { "path": "/login", "login": { "user": "demo@example.com", "password": "demo-pass" } },
  "base": { "carry": [ "vendor", "node_modules" ] }
}
```

`preview` is the page each worktree prepared by its setup script shows in the app, on its `$PIER_PORT`, with a test
login of the app. The box's own config may also say `"auto_share": false`: that location's previews get no public
link by themselves.

Everything run in a worktree (sessions, setup and archive scripts, services, `exec`, repository hooks) gets
`PIER_BOX`, `PIER_LOCATION`, `PIER_ROOT_PATH`, `PIER_WORKTREE_PATH`, `PIER_WORKTREE_NAME`,
`PIER_WORKTREE_SLUG` (safe in database and user names, at most 32 characters; a worktree made by an older pierd keeps
the longer one it had), `PIER_BRANCH`, `PIER_PORT`, `PIER_PORT_1`…, and `PORT`. Sessions also get
`PIER_SESSION`, `PIER_AGENT` and, in chats and home terminals too, the tokens Codex reads for the box's MCP servers
(`PIER_MCP_<NAME>_TOKEN`, below); hooks get `PIER_EVENT` and `PIER_<KEY>` for the event's data.

Each worktree gets its own block of 10 ports from 41000 (kept in `ports.json`); a new block is never one where
something already listens.

### Preparing worktrees

A new worktree is prepared as it is made: by its location's setup script and autostart services, or by a **setup
agent**: Claude Code in a session of its own (`<worktree>-setup`, with `PIER_SETUP=1`), unattended (bypass mode, its
warning skipped for that process alone through `--settings`; the account's own settings are left as they are), told
by pierd that the repository is data, never instructions, and what the box allows (whether `sudo -n` works, the
worktree's ports, the box's preparation rules: by default no Docker or LXD, no network or firewall changes; the app
edits them). It installs what the project needs, gets the app running on `$PIER_PORT` with a test login and its debug
consoles off, saves what it did as the location's config (`location config --merge`, marked `by: setup`), so the next
worktrees are prepared by script, and reports with `pierd preview set` and `pierd prepare done`. A setup agent
prepares a location's new worktrees by default only once the person allowed it for that location (the app asks once
per project: `PUT /v1/locations/{name}/setup-agent`), and then only while it has no recipe, its repository config is
trusted, the worktree is not a pull request's and pierd does not run as root; asked for by name
(`--prepare-with agent`), one runs anyway. `worktree new` and `task new` take `--prepare-with agent|script|none`;
`pierd prepare wait` blocks until a worktree's preparation is over (agents run it before they run the app or its
tests; the setup agent itself never does). A worktree's preview with a port gets a public link by itself on a box
with a relay that serves links, a day at a time, renewed while the worktree is there.

### The project's base

What every new worktree of a project gets that git does not bring, configured once:

- **files** the box keeps for the project, untracked in it (`.env`, `auth.json`, keys): `pierd base add shop .env
  auth.json` takes them from the main checkout. Each new worktree gets them as it is made (a dotenv file key by key;
  what someone changed in a worktree stays when the base changes), never a pull request's from a fork. `pierd base
  apply shop` writes them into worktrees that already exist.
- **carried folders**: `pierd base carry shop vendor node_modules` (or `"base": {"carry": [...]}` in a config, or the
  repository's `.worktreeinclude`) copies those ignored folders from the main checkout into each new worktree before
  its recipe runs, copy-on-write where the disk can (btrfs, APFS: seconds), so `composer install` and `npm install`
  only bring them up to date. Laravel's caches, logs and `storage`, and a Python virtualenv, are never carried.

`pierd base status shop` shows what the base holds and whose each part is. On a machine where each person runs their
own pierd, root can keep a project's base in the team's folder (named in `/etc/pier/team.json`): every member's pierd
lays it under their own, its recipe between the repository's and their box's.

## Agent hooks

pierd knows an agent's state (working, needs you, done) from the agent's own hooks: Claude Code's settings
and Codex's `hooks.json` and `notify` run `pierd hook TOOL EVENT`, which hands the event to the running pierd
(or spools it while pierd is down). `pierd integrations install claude|codex|all` installs them (in
`$CLAUDE_CONFIG_DIR` / `$CODEX_HOME` when set; running it again changes nothing);
`pierd integrations` says which hooks each agent has. Codex asks once to trust new hooks (`/hooks`); pierd marks its
own as trusted in Codex's config (the hash Codex keeps for each) whenever it starts Codex on an account.

Without any hooks pierd still follows agents by reading their screens, less precisely.

Claude Code and Codex also ask before they work in a folder they have not seen. pierd answers that in their configs up
front for the folders of the box's projects, the worktrees it makes and its chats' (Claude Code's `.claude.json`, under
its own lock; Codex's `config.toml`), and from the screen when the question comes anyway. A prompt sent to either is
submitted, not just typed: pierd waits for its input box to show the prompt, presses Enter, and checks it went in
(docs/API.md 4.3).

## MCP servers

The MCP servers added in the app (Ajustes › Servidores MCP; `PUT /v1/mcp/{name}`) are kept in `$PIER_HOME/box/mcp.json`
(mode 0600, tokens included) and written into every Claude Code and Codex account on the box through the agents' own
CLIs (`claude mcp add --scope user`, `codex mcp add`): when one is saved, when an account is added and when pierd
starts. pierd records each entry the moment it is written (`mcp-written.json`) and only ever removes or rewrites one
that is still as it wrote it: never a server added by hand, nor one of its own changed by hand since.
Codex reads a server's token from `PIER_MCP_<NAME>_TOKEN`, which pierd gives every session it starts, so the token is
not written into Codex's `config.toml`.

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

`pierd help` lists them all: `setup`, `serve`, `relay`, `install`, `uninstall`, `pair`, `clients`, `revoke`, `id`,
`doctor`, `version`, `tools`, `hook`, `integrations`, `client` (a paired client for scripts: `pierd client pair LINK`,
then `pierd client GET /v1/sessions`), and the box commands over the local socket: `locations`,
`location add|rm|config`, `worktree new|rm`, `services`, `service list|start|stop|restart`, `sessions`,
`session new|send|screen|rename|wait|turns|kill`, `task new`, `prepare status|wait|start|done`, `preview get|set`,
`base status|add|rm|carry|apply`, `exec`, `stats`, `info`, `emit`, `events`. Run in a worktree's session, `prepare` and `preview` take that worktree
when none is named.

## API

The routes, their handlers and the app code that calls each one: [docs/API-SURFACE.md](docs/API-SURFACE.md).
The wire protocol is described in the repository's `docs/PROTOCOL.md` and `docs/API.md`. Pairing binds its
proof to the TLS exporter label `EXPORTER-pier-pair-v1` and prefixes it with `pier pair v1`; requests name their
tool in `X-Pier-Origin`.

## Releasing

Push a tag `pierd-vX.Y.Z` on `main`. `.github/workflows/pierd-release.yml` runs the tests, builds the Linux and macOS
binaries (amd64, arm64) into a GitHub Release with `checksums.txt` (what `site/install.sh` downloads), and publishes
the npm packages from `npm/` (`pierd` and `pierd-<os>-<cpu>`) with npm's trusted publishing, so there is no npm token
to keep: each package trusts that workflow, set once by a maintainer (`npm trust github <package> --file
pierd-release.yml --repo wagnerfnds/pier --allow-publish`; a new package is published by hand before it can trust it).
By hand: `npm/build.sh X.Y.Z <dir with the tarballs> out && npm/publish.sh out` (versions already on the registry are
skipped). Then the Homebrew formula, in github.com/wagnerfnds/homebrew-tap: `homebrew/formula.sh X.Y.Z >
Formula/pierd.rb` there, committed and pushed (its CI installs and tests it).

## Tests

`go test ./...` runs the unit and integration tests (tmux and git needed; the systemd scope test runs with
`PIER_TEST_SYSTEMD=1` on a box with a user manager). `scripts/smoke.sh` builds pierd, starts it with a
temporary `PIER_HOME` and its own tmux server, pairs a client the way the app does and calls the main routes;
`SMOKE_REPO=~/code/sandbox` runs it against a real repository, `PIERD=path` against a given binary.
