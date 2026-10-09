# Push notifications

pierd sends the app's push notifications itself: APNs alerts, Live Activity updates and widget reloads, for the
devices paired with the box. Code: `Server/pierd/internal/push` (`push.go`: config and routes; `engine/`: what to
send when; `payload/`: the JSON bodies; `apns/`: the APNs client; `state/`: registrations; `recap/`: AI recaps;
`text/`: the wording). In the app: `PushClient` (PierKit), `App/Core/PushManager.swift`,
`App/Shared/PushSupport.swift`, `App/Core/Notifications.swift`, `App/Shared/LiveActivities`.

This document is the contract between the two: the routes, the payloads, and what the app expects. The app also
registers the same categories for its own local notifications; a push only has to name the same category and carry
the same custom keys.

## 1. Setting it up on a box

Push is on when `$PIER_HOME/push.json` exists (default `~/.config/pier/push.json`):

```json
{ "key_id": "ABC123DEFG", "team_id": "TEAMID1234", "bundle_id": "com.example.pier" }
```

| Key | Meaning |
| --- | --- |
| `key_id`, `team_id` | the APNs auth key's id and the Apple developer team (required) |
| `bundle_id` | the app's bundle id, `PIER_BUNDLE_ID` in the app's `Config/Signing.xcconfig`; it is the APNs topic (required) |
| `key_path` | the APNs auth key (`.p8`); default `$PIER_HOME/AuthKey.p8`. Keep it mode 0600 (pierd warns otherwise) |
| `listen` | extra addresses that also serve the push routes, comma separated (absent, empty or `"off"`: none). The routes are always on pierd's own listener |
| `activity_date_epoch` | how dates inside a Live Activity `content-state` are written: `"unix"` (default) or `"reference"` (seconds since 2001) |
| `recaps` | AI recaps of finished turns (section 6); default `true` |

All three of `key_id`, `team_id` and `bundle_id` are required: a `push.json` without them is an error and pierd
serves without push (it logs why). Restart pierd after changing it (`systemctl --user restart pierd`).
Registrations are kept in `$PIER_HOME/push-state.json`. pierd logs every APNs answer (status, reason, apns-id,
shortened tokens) in its log.

## 2. Transport and registration routes

The push routes are part of pierd's API: same TLS identity, same paired clients, same pin (PROTOCOL.md). They are
served on pierd's main listener and on any extra address `listen` names, a listener that serves only
these routes (and `GET /v1/ping`; no pairing: `POST /v1/pair` is on pierd's own port alone, behind its one rate limit). They refuse the box's local socket (403): registrations come from paired devices. Errors are
`{"error": "...", "code": "..."}`.

| Route | Body → answer |
| --- | --- |
| `GET /v1/push/info` | → `{"version":"1","apns_env_supported":["development","production"],"bundle_id":"com.example.pier"}` |
| `PUT /v1/push/device` | `{"device_token":"<hex>","env":"development\|production","locale":"pt-BR","events":{"waiting":true,"finished":true,"working":false},"widget_token":"<hex>"?,"push_to_start_token":"<hex>"?,"box_name":"devbox"?}` → 204. Registers or replaces this client's device. Without `events`: waiting and finished on. Without `locale`: `en` |
| `DELETE /v1/push/device` | → 204 (unregister) |
| `PUT /v1/push/activities/{box}/{session}` | `{"token":"<hex>","env":"…"}` (a Live Activity update token) → 204 |
| `DELETE /v1/push/activities/{box}/{session}` | → 204 |
| `POST /v1/push/test` | → `{"sent":true,"apns_id":"…"}`; 404 `no_device` before a `PUT /v1/push/device`; 502 `apns_error` (with `reason`, `status`) or `apns_unreachable` |

Bad tokens (not hex) are 400 `bad_token`, a bad `env` 400 `bad_env`. A client's registrations are dropped within
about 5 s of it being revoked, and nothing is pushed to it meanwhile. Tokens APNs reports as `BadDeviceToken`,
`Unregistered`, `DeviceTokenNotForTopic` or 410 are dropped (a dead activity token drops that activity).

### 2.1 How the app reaches them

`PushClient(box:identity:)` (PierKit) sends every push call to the box's **main address**, with the box's identity and
pinned fingerprint; header `X-Pier-Origin: ios-push`. When push is not configured in pierd, the push routes answer
404: the box shows as "push indisponível".

## 3. What the app does (registration)

* On launch, every foreground, device-token change, pairing change, toggle change and widget-token change, the app
  calls `GET /v1/push/info`, then `PUT /v1/push/device`, on **every paired box** (8 s deadline each).
  * `env`: read at run time from the build's signed `aps-environment` (`embedded.mobileprovision`; no profile means
    App Store / TestFlight, hence production). Builds installed from Xcode, Debug or Release, are `development`.
  * `locale`: the language the app runs in (the per-app language in iOS Settings counts), so pushes match the UI.
  * `box_name`: the name this device gave the box (`BoxRecord.name`). **pierd uses it as the payload's `box`** and
    for `thread-id`: the app resolves deep links by that name, which can differ from the box's own name. Without it
    pierd uses the `{box}` of the device's activity registrations, then its own name.
  * `widget_token`: iOS 26+ `WidgetPushHandler` token; absent before iOS 26 or with no widget on the home screen.
  * `push_to_start_token`: `Activity<SessionActivityAttributes>.pushToStartTokenUpdates` (iOS 17.2+).
* After a successful device PUT, the app sends again every Live Activity token it holds for that box, so pierd may
  lose activity state without harm.
* Live Activities: `PUT /v1/push/activities/{box}/{session}` on each `pushTokenUpdates` value (path segments
  percent-encoded); `DELETE` when the activity ends or the person stops following the session. Activities started by
  push-to-start are adopted and their tokens forwarded the same way. The tokens are also kept in the App Group file
  `live-activity-tokens.json` (`{"activities": {"<box>/<session>": {box, session, token, updated}}, "pushToStart":
  "<hex>"}`).
* Unpairing a box sends `DELETE /v1/push/device` (best effort, 4 s).
* Settings → Notificações: `POST /v1/push/test` (the app shows `sent` or the box's error text) and a status per box:
  *registrado* (info and PUT ok), *push indisponível* (connection, TLS or timeout failure on both ports), or an error
  (401, pin mismatch, other HTTP status). Unreachable boxes are retried while the app is in front, from 30 s doubling
  to 10 minutes.
* **Local-notification dedupe**: the app posts no local "needs you" / "done" notification for a box whose push is
  registered **and** still answers `info` (probed in each background refresh, 4 s), nor for an event type the person switched off. A box
  without push gets local notifications from its event stream as before (API.md §9).

## 4. Alerts

### 4.1 Categories (registered in `App/Core/Notifications.swift`)

Selected by `NotificationCategoryID.category(state:ask:)` in PierKit for local notifications, and by pierd for push.

| `aps.category` | When | Actions |
| --- | --- | --- |
| `NEEDS_YOU` | agent `waiting` on a permission with a numbered menu on screen | `ALLOW` "Permitir" (authentication required, runs in the background), `DENY` "Negar" (destructive, background), `ANSWER` "Responder" (opens the app) |
| `NEEDS_YOU_QUESTION` | `waiting` on a question, a plan approval, or a permission with no menu found, when the choices could not be read | `OPEN` "Abrir" (opens the app) |
| `NEEDS_YOU_CHOICE_2` … `_4` | the same, with the choices read (`options`, 4.3): the body ends with them numbered | `CHOICE_0` … `CHOICE_n-1` "1" … "n" (background), `OPEN` "Abrir". The service extension swaps in a category whose buttons carry the choices' words. |
| `FINISHED` | agent `finished` | `REVIEW` "Revisar" (opens Review), `MESSAGE` "Mandar mensagem" (text input, sent with `when: idle`, background) |

Custom keys, top level next to `aps`:

| Key | Meaning |
| --- | --- |
| `box` | the box's name on this device (`box_name`) |
| `session` | session name |
| `location` | the session's `location` (`"repo/worktree"`), used by `REVIEW` |
| `hasMenu` | `true` when a numbered permission menu was seen on screen (informational) |
| `options` | a waiting agent's choices, in order (≤ 4, each ≤ 60 characters): the notification's buttons, see 4.3 |
| `optionsKind` | where they came from: `question` (the transcript's form; answered by label) or `menu` (numbered rows on screen; answered by digit) |

### 4.2 Payload and headers

```json
{
  "aps": {
    "alert": { "title": "✋ Needs you · Fix login", "subtitle": "shop / checkout-fix · Claude Code", "body": "Bash  rm -rf build" },
    "category": "NEEDS_YOU",
    "thread-id": "devbox/shop-checkout-claude-1x2y",
    "sound": "default",
    "interruption-level": "time-sensitive",
    "mutable-content": 1
  },
  "box": "devbox", "session": "shop-checkout-claude-1x2y", "location": "shop/checkout-fix", "hasMenu": true
}
```

* Headers: `apns-push-type: alert`, `apns-topic: <bundle_id>`, `apns-collapse-id` = the session, priority 10
  (5 for `working`). Expiration: waiting 1 h, finished 4 h, working 10 min.
* `thread-id` is `"<box>/<session>"`, so a session's notifications group together.
* Title: the state first, then the session's name: "✋ Needs you", "✅ Done", "⚠️ Failed", "⏳ In background",
  "⚙️ Working" (pt-BR: "Precisa de você", "Concluído", "Falhou", "Em segundo plano", "Trabalhando"), by the device's
  `locale`. Subtitle: `<repo / worktree> · <agent>` (plus the box when the device has several). Body: the ask for
  waiting; for finished, the recap or the reply's first sentence, then `+N −M` from `/v1/review`.
* Interruption level: `time-sensitive` (waiting), `active` (finished), `passive` (working).
* The Allow/Deny actions do not trust the push: they read the session's screen again, find the menu with
  `MenuParser` and send the digit the menu assigns (API.md §5.3), never a fixed `1`. If the menu is gone or changed
  the app posts a local "Não consegui permitir/negar" instead.
* Actions without the foreground option run with the app launched in the background; `content-available` is not
  needed for the buttons. `content-available: 1` pushes make the app run a background refresh (widgets and Live
  Activities).
* While the app is open and following that box, pushes go to Notification Center without a banner (the in-app
  banner already announced the transition).
* Test without a server: `xcrun simctl push <udid> com.example.pier payload.json`.

### 4.3 Answer from the notification (a question's choices as buttons)

A question has no fixed buttons, so `NEEDS_YOU_QUESTION` alone only offers "Abrir". When pierd can read what the agent
offers, the alert carries `options` (and `optionsKind`), names `NEEDS_YOU_CHOICE_<n>` (the app's own category with
buttons "1" … "n", the body ending with the choices numbered the same way) and the app's **notification service
extension** (`Extensions/PierNotificationService`, run for every alert thanks to `mutable-content: 1`) registers a
category for that set of choices (`CHOICE:<hash>`, one action `CHOICE_<n>` per choice titled with it, plus `OPEN`
"Abrir") and names it on the content before the banner is drawn, so the buttons read "Three tiers" / "One plan" / "A
table". Where the extension does not run (it is not started for `xcrun simctl push` in the simulator, for one) the
numbered buttons still answer. `NotificationChoices` (`App/Shared`) is the shared code: the app uses it for its own
local notifications too, and merges its fixed categories with the dynamic ones instead of replacing them (a replace
would strip the buttons off a question still on the Lock Screen; the newest 24 sets are kept).

What pierd reads (`internal/push/engine`, `waitingOptions`): for a question tool, the transcript's open `question`
item when it is one question with a single pick (`optionsKind: "question"`), else the numbered rows on screen minus
the agent's own trailing "Type something." / "Chat about this" rows (`menu.OptionLabels`, `optionsKind: "menu"`;
Claude Code draws AskUserQuestion that way and writes the transcript item only once answered; a plan approval is a
plain numbered menu), looked for up to 4 times 600 ms apart like the permission menu. A permission *with* its
Allow/Deny menu keeps `NEEDS_YOU`; one without gets one look at the screen for a plain menu. A wait answered while
the choices were read is not announced.

A `CHOICE_<n>` button runs the app in the background (`SessionActions.answerChoice`): the session must still be
waiting; a question in the transcript whose option still carries those words is answered with `POST .../answer`
(API.md §5.4); otherwise the row with those words on screen gets its digit (`send` with `force`), and an unnumbered
menu its cursor keys. A choice that is gone (answered elsewhere, a different question) is refused and the app posts
"Não consegui responder". The buttons do not require unlocking (an answer is the person's words, not an action on
the box like Allow).

The app starts a Live Activity per followed session (`SessionActivityAttributes`, `App/Shared/LiveActivities`) with
`pushType: .token`. Updates: headers `apns-push-type: liveactivity`, `apns-topic: <bundle_id>.push-type.liveactivity`,
priority 10 (5 for silent progress).

```json
{ "aps": { "timestamp": 1790000000, "event": "update",
    "content-state": { "phase": "waiting", "since": 1790000000, "step": null, "ask": "Bash  rm -rf build",
                       "hasMenu": true, "added": null, "removed": null, "reply": null },
    "alert": { "title": "Fix login", "body": "Needs you" } } }
```

### 5.1 `content-state` (exact JSON)

`ContentState` has a hand-written Codable, so the wire format does not depend on ActivityKit's decoder (which uses a
plain `JSONDecoder()` whose default date strategy reads seconds since 2001).

* `phase`: `starting | running | waiting | finished | ended` (`running`, not "working"; unknown values decode as
  `running`).
* `since`: a number, **seconds since 1970**, fractions allowed. The app also accepts a number < 1e9 as seconds since
  2001 (legacy, `activity_date_epoch: "reference"`) and an RFC 3339 string. pierd sends Unix seconds with millisecond
  precision.
* Required: `phase`, `since`. Optional (null or absent): `step`, `ask`, `added`, `removed`, `reply`; `hasMenu`
  defaults to `false`. pierd always sends all eight keys, nulls included.
* `reply`: the agent's last reply of the turn (or its recap), Markdown marks stripped, whitespace folded, ≤ 280
  characters, sent with `finished`; the lock-screen card shows it. Zero `added` / `removed` are not shown.
* End: `"event": "end"` with the final `content-state` and `"dismissal-date": <Unix seconds>`.

### 5.2 Push-to-start (iOS 17.2+)

Sent to the `push_to_start_token` with the same headers; `attributes-type` is the Swift type name:

```json
{ "aps": { "timestamp": 1790000000, "event": "start",
    "attributes-type": "SessionActivityAttributes",
    "attributes": { "box": "devbox", "session": "shop-checkout-claude-1x2y", "title": "Fix login",
                    "project": "shop · checkout-fix", "agent": "claude" },
    "content-state": { "phase": "running", "since": 1790000000, "step": null, "ask": null, "hasMenu": false,
                       "added": null, "removed": null, "reply": null },
    "alert": { "title": "Fix login", "body": "Working" } } }
```

`attributes`: `box`, `session`, `title`, `project` (strings, required), `agent` (optional). `box` + `session` must be
the ids used in activity paths (the app tracks activities by `"box/session"`). The system then gives the app an
update token, which it PUTs to `/v1/push/activities/{box}/{session}`.

Without push, an activity is updated only while the app runs (events, step polling in the foreground) and on each
background refresh (iOS decides, typically every 15 minutes or more). Requires the `aps-environment` entitlement.

## 6. What pierd sends, and when

* **Source**: pierd's event bus, in-process, from the last event push handled (kept in `push-state.json`), so a
  restart announces what changed meanwhile; at start a baseline is taken, so nothing merely present is announced.
  Events trigger a re-read of the sessions (also every 30 s); a transition is a change of `(agent_state,
  state_since)` per session. States older than 10 minutes are never announced.
* **Waiting**: settles 700 ms, then reads the screen up to 4 times, 600 ms apart, for a numbered Allow/Deny menu (a
  port of `MenuParser`, side panel included). Menu found: `NEEDS_YOU`, `hasMenu: true`. A question tool, or a
  permission without a menu on screen: `NEEDS_YOU_QUESTION`, `hasMenu: false`, with the question's choices as
  `options` when they can be read (4.3). Answered within the settle window: nothing is sent.
* **Finished**: settles 1 s. No alert for `source: "interrupt"`; `status: "error"` reads "Failed". With background
  work still running (transcript `signals.background`, running `crew`) the alert reads "⏳ In background" with the
  job on the last line, and the Live Activity stays `running` with the job as `step`.
* **Working** (`events.working`): a passive alert; otherwise only Live Activity updates.
* **AI recap** (`recaps`, on by default): for a finished turn, the agent's last reply goes to `claude -p --model
  haiku` on the box (as pierd's user; the binary from `$PATH`, else `~/.local/bin/claude`, `~/.claude/local/claude`,
  `/usr/local/bin`, `/opt/homebrew/bin`, `~/.npm-global/bin`; run from `$HOME`, without the `PIER_*`
  variables), asking for one short sentence (≤ 120 characters) in the reply's language. 20 s deadline, once per turn
  (cached by session and `state_since`, failures too). The sentence replaces the reply excerpt in the alert body and
  the Live Activity `reply`; on any failure the excerpt stays. A turn that moved on while the model ran is not
  announced. A reply that already fits (one line, ≤ 120 characters) is shown as it is, without the model.
  Timing: the reply, the recap, the diff and background work are read as soon as the finish is seen, alongside the
  1 s settle (the reply is re-read every 150 ms until it reaches the transcript, up to 3 s). The model runs on a
  `claude` started when an agent starts working (`--input-format stream-json`, one process per recap, stopped after
  10 min unused, ~230 MB while it waits), with `--strict-mcp-config --no-session-persistence --disable-slash-commands
  --tools ""`; a CLI that cannot run that way runs cold. Its hooks are silenced (`PIER_HOOKS_QUIET=1`). Measured on a
  box, end of turn → APNs accepted: median 4.8 s before, 1.1 s (short reply) / 1.4 s (with a recap) after.
* **Live Activities**: an update for every transition (starting, running, waiting, finished), at most one per 5 s per
  session and device (waiting, finished and ended bypass the throttle). `finished` is an `update` with `stale-date`
  +1 h, because the agent can run again; `end` (phase `ended`, `dismissal-date` +5 min) when the session exits or
  disappears, then its token is forgotten. The activity update carries no `alert` while a regular alert goes to that
  device (it would double the banner).
* **Push-to-start**: for running or waiting sessions, once per session and device, when the device has no activity
  token for it, after an 8 s grace (skipped if the phone registered an activity of its own meanwhile: the app starts
  one itself for tasks made on the phone, and ends any second activity for the same session). `project` is
  `repo · worktree`, like the app's own activities.
* **Widgets** (iOS 26+): `apns-push-type: widgets`, topic `<bundle_id>.push-type.widgets`, body
  `{"aps":{"content-changed":true}}`, priority 5, at most one per 60 s per device, on session state changes.
* **Debounce**: at most one alert per state transition per session.
* **APNs**: HTTP/2 to `api.sandbox.push.apple.com` (development) or `api.push.apple.com` (production), by the
  device's `env`. Token auth: an ES256 JWT cached 40 minutes, minted again once on `ExpiredProviderToken` /
  `InvalidProviderToken`.
* **Not pushed**: `notify`, `service.failed`, worktree setup failures (the app shows those as local notifications
  from its event stream).

## 7. Widgets push in the app (iOS 26+)

`WidgetConfiguration.pushHandler(_:)` with a `WidgetPushHandler` whose `pushTokenDidChange(_:widgets:)` delivers
`pushInfo.token`; the app also reads `WidgetCenter.shared.currentPushInfo`. Implemented in
`Extensions/PierWidgets/StatusWidget.swift`: the Agentes widget registers the handler on iOS 26+ (a separate widget
bundle is chosen at launch, because the builders have no availability `if`/`else`); the token goes to the App Group
(`push-state.json`) and to every box as `widget_token` (the extension also registers on its own). On a widgets push
the timeline provider reloads and fetches live from the boxes. Not testable on the simulator.
