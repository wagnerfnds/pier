# Pier: architecture

Pier is a native SwiftUI app (iPhone, iPad, Mac Catalyst) to watch and drive coding agents (Claude Code, Codex) running
on your development boxes. Each box runs **pierd** (`Server/pierd`, Go), which keeps the box's repositories and worktrees,
runs the agents in tmux, follows them through their hooks and serves the app over mutual TLS. The app pairs with each box
on its own (no account, no relay) and speaks pierd's `/v1` API directly: see `docs/PROTOCOL.md` for the transport and
pairing, `docs/API.md` for the endpoints, `docs/PUSH.md` for push, and `Server/pierd/docs/API-SURFACE.md` for which app
code calls which route.

## What the app does
1. Pair with a box (scan the QR / paste or open a `pier://` pair or join link).
2. Home and Inbox: every agent across boxes grouped **Needs you / Working / Your turn / Done**, live; a keyboard-first Inbox.
3. Create a task: prompt + project + agent up front; worktree, base branch, name, model, effort and title fold under
   "Opções" with smart defaults and a one-line summary (+ photo). Model and effort are chips (every choice in sight,
   "Outro…" for a name typed by hand); the form is a 720 pt column, and on the Mac Start sits at its end with ⌘↩
   beside it (the iPhone and the iPad keep a bar above the on-screen keyboard, the iPad's as wide as the column).
4. Session = a chat first (transcript folded into turns, Markdown replies, needs-you card above the composer, Send that
   becomes Stop while the agent works); the raw terminal is a secondary view remembered per session.
5. Needs you: permission Allow once / Always / Deny (screen menu parsing) and question answering.
6. Review: files changed, per-file diff, git actions (commit, push, open PR) and pull requests, via `exec` on the box.
7. Projects: user-defined **sections** (stored on the device), each ordered by hand, by name or by recent activity, renames,
   hide; worktrees per project; the agents board. On the iPad and the Mac a project opens its **workspace**: the file
   tree and an editor that saves to the box, the changes beside their patches, the git history.
8. Notifications: push from pierd (APNs) or, for a box without a key, relayed by a Mac running Pier through the
   person's iCloud (`CloudAlerts`, docs/PUSH.md 8); local notifications from the event stream as a fallback; Live
   Activities and widgets; App Shortcuts; "Falar" (talk to the agents).

## Repo layout
```
project.yml                 # XcodeGen spec: `xcodegen generate` writes Pier.xcodeproj (gitignored)
Config/                     # Base.xcconfig (identifiers), Signing.example.xcconfig, build-number script
Vendor/swift-nio-ssl/       # vendored with a TLS exporter patch (needed for pairing), see Vendor/README.md
Packages/PierKit/           # SwiftPM: transport, identity, pairing, typed API, models, pure helpers (tested)
  Sources/PierKit/
    API/        BoxAPI (+Home), PierBoxClient protocol, PierTransport, EventStreamer, PushClient, PairInvite
    Models/     Codable models of pierd's JSON
    Support/    ConversationFold, MenuParser, GitActions, PRCommands, AgentBoard, InboxRules, NextSteps, TalkRouter, …
  Tests/PierKitTests/  Fixtures/*.json (pierd answers, sample data) and synthetic/ (hand-written edge cases)
Tools/pierctl/              # macOS CLI client for end-to-end checks against a real box (~/.config/pierctl or $PIERCTL_HOME)
App/                        # the app target (SwiftUI)
  PierApp.swift
  Core/        AppModel (@Observable), BoxConnection, EventHub, Router/Routes, Notifications, PushManager, LiveActivities
  Features/    Board, Compose, Dashboard (Home), Dots, Housekeeping (Faxina), Inbox, MenuBar, Navigation, Onboarding,
               Palette, Projects, PullRequests, Review, Session, Settings, Talk
  Intents/     App Intents and App Shortcuts
  Shared/      compiled into the app and the widget extension (identifiers, keychain, snapshot, push support)
  Debug/       the mock box for UI tests (`-uiTestMock 1`) and the in-app demo (Release too), window snapshots
  DesignSystem/ colors, typography, components
  Resources/   Assets, AppIcon.icon, Info.plist and entitlements (generated from project.yml), string catalogs
Extensions/PierWidgets/     # Home Screen widgets and Live Activities (iPhone/iPad)
Mac/PierMenuBar/            # AppKit plugin for the Mac app's menu bar item
UITests/PierUITests/        # XCUITest against the mock box (RealBoxUITests: against a real box, skipped by default)
Server/pierd/               # the box server (Go), its own README and docs
Design/                     # the script that renders the app icon's mascot
docs/
```

## Key decisions
- **Transport**: swift-nio-ssl (BoringSSL) because pierd uses TLS 1.3 + Ed25519 mutual TLS; Apple's TLS stack can't.
- **Reach**: a box's address, or, for a box behind NAT, its relay (`BoxRecord.relay`, from the pairing link or
  `GET /v1/info`; `pierd relay` on a server the person runs). `H2Connection.dial` races the two (`Race.first`: the
  address first, the relay 0.6 s later or at once when the address fails; the last winner goes first next time); the
  relay only carries the same pinned TLS (docs/PROTOCOL.md §10). `AppModel.relayChanged` keeps the record in step with
  what the box says and reconnects it; Ajustes shows the relay under the address.
- **Concurrency**: Swift 6 strict; PierKit types Sendable; UI state via `@Observable` on the main actor.
- **Multi-box**: everything keyed by box name; Home, Inbox and the board merge boxes.
- **Persistence**: Keychain for the identity key and the pairings (shared with the widget extension); JSON files in
  Application Support / the App Group for sections, renames, hidden projects, prompt drafts and caches.
- **Live updates**: one event stream per box while the app is active (`/v1/events?since=` NDJSON, resume by seq); refresh
  affected resources on events; the transcript polls ~1.5 s while a conversation is open.
- **Background**: push from pierd, or the Mac's alerts through iCloud (docs/PUSH.md 8); BGAppRefreshTask polls
  `/v1/sessions` and posts local notifications for new `waiting`/`finished` on boxes without push.
- **Never** set `open` on task/session requests. Always pass `when` on send (`idle` from the composer, `now` for answers).
- iOS 17 minimum. Portuguese (pt-BR) UI strings with English via String Catalogs (`App/Resources/Localizable.xcstrings`,
  `App/Features/Dashboard/Home.xcstrings`, `App/Resources/AppShortcuts.xcstrings`).

## Identifiers and signing

Every identifier derives from one build setting, `PIER_BUNDLE_ID` (default `dev.pier.app` in `Config/Base.xcconfig`),
overridden with your team in the gitignored `Config/Signing.xcconfig` (copy `Config/Signing.example.xcconfig`):

| What | Value |
|---|---|
| App / widgets / menu bar plugin / UI tests | `$(PIER_BUNDLE_ID)`, `.widgets`, `.menubar`, `.uitests` |
| App Group | `group.$(PIER_BUNDLE_ID)` (Info.plist `PierAppGroup`, read by `Shared.appGroup`) |
| Keychain access groups | `$(AppIdentifierPrefix)$(PIER_BUNDLE_ID).shared` (Info.plist `PierKeychainGroup`) and the app's own group |
| Keychain service | `$(PIER_KEYCHAIN_SERVICE)`, default `$(PIER_BUNDLE_ID)` (Info.plist `PierKeychainService`) |
| Background refresh task | `$(PIER_BUNDLE_ID).refresh` |
| Widget kind | `<bundle id>.status` (`StatusWidgetConfig.kind`) |
| APNs topic | the bundle id; put the same id as `bundle_id` in the box's `~/.config/pier/push.json` |

Swift never hard-codes these: `App/Shared/SharedSupport.swift` reads them from Info.plist and the bundle id.

## Fixed names and values

Some names live in data already stored on devices and boxes, or in the pairing cryptography; both sides must agree on
them:

- **Pairing cryptography**: the TLS exporter label `EXPORTER-pier-pair-v1` and the proof prefix `pier pair v1`
  (`Pairing.swift`, `Identity.swift`; pierd's `internal/wire`, `internal/pairing`). They must be byte-identical on both
  sides: PierKit's `proofVector` test and pierd's `TestProofVector` check the same fixed vector.
- **Links**: `pier://` is the only URL scheme, for pairing and join links and for `pier://session?…` deep links held
  by widgets and Live Activities.
- **Identifiers of an install**: bundle id, App Group, keychain groups, keychain service, background task and widget
  kind all follow `PIER_BUNDLE_ID` / `PIER_KEYCHAIN_SERVICE`, set in `Config/Signing.xcconfig`.
- **Application Support folder**: iPhone/iPad builds keep `prefs.json`, `home-cache.json` and `next-steps.json` in
  `Application Support/Pier`. The Mac keeps its folder named after the bundle id.
- **Keychain migration flag** `keychain.migratedToShared.v1` (UserDefaults) and the app-only keychain group move,
  unchanged.
- **Third-party notices** for pierd are in the repository's `NOTICE`.

## Session screen (chat) — how it is built

Its quality targets and the commands that measure them: `docs/CHAT-QUALITY.md`.

- `ConversationFold` (PierKit, tested) turns the transcript into rows: a prompt starts a
  turn; the agent's tool calls, helpers and intermediate notes fold into one "Trabalhou · 3 comandos, 2 arquivos lidos"
  line; edits, questions, notices, artifacts and the answer stay visible. The last turn's fold reads "Trabalhando"
  while the agent runs.
- `SessionViewModel.tick()` polls transcript / screen / held prompts every ~1.5 s (at once on an event) with
  per-request deadlines (the first transcript read 12 s, then 6 s); the screen also feeds the "doing" line (`StepText`)
  every third tick while the agent runs. The review list ("Revisar") is read off that loop, so a slow `git` never
  holds the conversation back.
- The reply being written (`GET .../draft`, Claude Code only) has a clock of its own (`followDraft`): every 0.6 s while
  its words grow, 1.5 s once they stop, at once on an event or a send; only new words redraw it. `DraftEcho` (PierKit)
  hides it once the record has the same block (pierd blanks it too), so a finished block never shows twice.
- Markdown: `MarkdownBlocks` (PierKit, tested) reads the block structure as CommonMark and GFM do (setext and ATX
  headings, lists whose items hold code and paragraphs, numbered as CommonMark numbers them, quotes holding blocks,
  tables with alignment and escaped pipes, indented code, tabs as 4 columns); `MarkdownView` draws it, inline styling
  through `AttributedString(markdown:)` (bare links included). A table's column grows to its longest cell up to a cap
  (260 pt, 340 on the Mac) and wraps past it, the table scrolling sideways when wider than the reply. A paragraph keeps
  its line breaks (chat convention). In the conversation the text is selectable on the Mac only (`touchSelection`: a
  long press on the iPhone opens the message's Copiar), and the lazy stack iterates light rows (id + index), which
  took a fling through a long chat on an iPhone from ~28 to ~5.5 ms/s of hitches.
- A message shows the moment it is sent (`outgoing`, "Enviando…"), through the undo window, until the box's pending
  copy and then the record's replace it in the same turn. A send has 15 s; when it fails on the connection the view
  model drops the connection and sends again with the same `idem_key` (pierd types it once).
- `LinkWatch` (PierKit): polls that fail on the connection itself (not on the box's answer) mark the screen troubled
  ("A box não está respondendo. Reconectando…" at the top, as are "offline", revoked and another key), and two in a
  row drop the connection, so the next request dials again, address and relay, instead of waiting for the PING
  watchdog (~45 s).
- On regular width the conversation and the composer are a 780 pt column. The Mac's window shows the session's title
  and, beside it, its state line; Return sends there (Shift- or Option-Return writes a line). "Ir para o fim" and
  loading older messages follow the scroll view's own geometry (iOS 18), so a trackpad or wheel counts like a finger.
- The working indicators (`ShimmerText`, `PulsingDot`) are Core Animation layers: a SwiftUI `repeatForever` updated
  the view graph every frame (about a fifth of the main thread while an agent worked). XCUITest takes an endless Core
  Animation for an app that never idles (60 s per tap), so with `-uiTestMock` they stand still (`Motion.endless`),
  except under `-chatPerfProbe`.
- The compact title (name + "Claude Code · Trabalhando · 12s") opens a Details sheet (project, box, model, mode,
  context, to-dos, helpers, published pages). The ⋯ menu holds rename, review, terminal toggle, Live Activity, stop.
- Agents the box keeps no record for (`source: none`) and plain terminals show `ConversationFallback`: the last message
  read from the screen, rendered as Markdown, plus a way into the terminal.

- Startup dialogs no hook announces (Claude Code's "New MCP server found", trust) are read from the screen. The box reports
  the agent as `running` meanwhile. Current Claude Code draws them **without numbers** (a `❯` on the selected option, "Enter
  to confirm" below): `MenuParser.cursorMenu` reads that (fixture `screen_mcp_dialog.json`, captured from 2.1.294) and the
  card's buttons answer with ↑/↓ + Enter; numbered menus (also inside a `│ … │` box) answer with the digit
  (`SessionViewModel.screenMenu`). `RealBoxUITests` (skipped unless `TEST_RUNNER_REAL_SESSION` is set, simulator paired with
  a real box) answers a real dialog through the card and measures send-to-reply latency.

- Background work (`signals.background` jobs and `crew` subagents with `state: "running"`) shows as a strip above the
  composer ("2 tarefas em segundo plano", tap for the list with timers) and in the title line; a finished turn with work still
  running reads as working, not done. The Home reads the same signals cheaply (`transcript?since=2000000000`: signals, no
  items) every 15 s for finished sessions and lists those under "Trabalhando agora" instead of "Sua vez".

## Review: AI-written commit / PR text

The Aprovar sheet asks the box for a draft as it opens: `AIDraft.command` (PierKit) runs through `exec` in the worktree,
gathers the diff since the merge base with the PR base (plus recent commit subjects for the house style) and pipes it to
`claude -p --model haiku` on the box (the subscription already there; nothing on the phone). The answer has three blocks
(`<<<COMMIT`, `<<<TITLE`, `<<<BODY`) parsed by `AIDraft.parse`. Fields the person already edited are kept; "Gerar" replaces
all. Without the CLI (exit 3) or on failure the sheet keeps the session-title draft and says why.

## Answer from the notification

A question's choices ride on the notification as its buttons ("Three tiers" / "One plan" / "A table" / "Abrir"), so the
phone answers a question from the Lock Screen the way it answers a permission. pierd sends them as `options` on a waiting
push (docs/PUSH.md 4.3); the notification service extension (`Extensions/PierNotificationService`) turns them into a
category of their own through `NotificationChoices` (`App/Shared`, compiled into the app and the extension), and the app
does the same for its local notifications (`ChoiceOptions.fetch` reads the transcript's open question or the numbered rows
on screen, `MenuParser.optionLabels`). A `CHOICE_<n>` button runs `SessionActions.answerChoice`: the session must still
wait, and the choice must still be there under the same words (a structured answer, else the row's digit, else the cursor
keys). Debug: `-uiTestAsk 1` adds the asking agent to the mock box; `-runIntent postNotif` reports the category and buttons
it registered, `-runIntent notifAction -notifActionID CHOICE_1` runs a button; `NotificationUITests`.

## The Inbox's attention: seen, dismissed, archived

A finished turn stays in the Inbox (and in "Sua vez") until archived, but the badge counts only what the person has not
looked at: `LocalPrefs.seen` ("box/session" -> when) is written by the session screen whenever it shows a finished turn and
by the Inbox card when its reply is opened or the session is opened from it; a seen card shows a small eye and
`InboxStore.unseenCount` (the tab badge, the sidebar count) leaves it out. A newer turn is unseen again by itself (the mark is
compared with `state_since`). Dismissing a question (E, swipe) and archiving a finished turn (E, swipe, Arquivar) go through
the undo window like answers: the card leaves at once and "Desfazer" brings it back; a dismissal is kept in
`LocalPrefs.dismissed` (per wait) so it does not come back at the next launch. Marks older than two weeks are pruned.

## The box needs you too (health cards)

`GET /v1/doctor` is read per box (`BoxHealthStore`, every 10 minutes while online, on pull-to-refresh) and `BoxHealth.issues`
(PierKit, tested) keeps the checks that need a hand: an agent CLI signed out (pierd's new `<agent> sign-in` check reads the
CLI's credentials file), hooks not installed, no agent installed, git/tmux missing, pierd not a service or stopping at
logout, a location that no longer exists, events lost. A box that cannot be reached, revoked or with another key is an
issue too. The Inbox lists them first ("A box precisa de você"), each card with the words for the problem, the exact
command to run on the box and "Copiar"; "Ignorar por hoje" snoozes the card for a day (`LocalPrefs.snoozedHealth`), with
the undo window. Keys: Return copies the fix, E ignores. Debug: `-uiTestHealth 1` makes the mock box report three problems.

## Undo window ("Enviando… Desfazer")

Answers and messages wait before they go out (Ajustes → Respostas → "Tempo para desfazer": Desligado / 2 s / 5 s, default 2 s,
UserDefaults `undoSeconds`; `-undoSeconds 0` as a launch argument for a run). `PendingActions.shared.schedule(label:symbol:after:
perform:onUndo:)` (App/Core/PendingAction.swift) returns a token for `undo(_:)`; `PendingActionToast` (mounted once in RootView) shows
the newest one at the bottom with a ring and a shrinking bar; "Desfazer", ⌘Z (on the button) and Esc (the ring's shortcut, and the
composer's own key handler) undo it. The work runs when the window ends even if its screen closed, and at once when the app goes to
the background (under a background-task assertion). Used by the needs-you card (permission, menu, cursor menu, trust, questions: the
card hides meanwhile and comes back on undo; an answer whose wait changed meanwhile is dropped), the composer (text and photos come
back on undo or failure) and the board's Permitir/Negar. Live Activity and notification actions stay immediate.

## AI titles

A task made on the phone without a title gets one from Haiku on the box right after it is created (`AITitle` in PierKit: prompt
base64-encoded, `claude -p --model haiku` run from `$HOME` through `exec` at the session's location, ≤ 6 words in the task's language;
`AITitler` then `PATCH`es the session's title). Non-blocking and silent on failure. The session's ⋯ menu has "Gerar título com IA"
(from the first user message). pierd's push writes finished-turn recaps the same way (docs/PUSH.md).

## Home: "Sua vez" vs closed

A finished turn means the agent waits for the person to carry on, not that the work is over. The Home widget "Sua vez" lists
finished turns; "Arquivar (terminei aqui)" (row context menu or the session's ⋯ menu) moves one to the folded "Encerradas"
section together with sessions that exited on the box. Marks are phone-local (`LocalPrefs.closed`, "box/session" -> date)
and lapse by themselves when the session starts a newer turn.

## Agents board ("Quadro")

Its own section (`AppTab.board`: a tab on iPhone, a sidebar row on iPad and Mac; ⌘3, the palette, the Mac menu "Ir"): every
agent session of every box in columns Precisa de você / Trabalhando / Sua vez / Pronto / Encerradas. The rules (column, filter, sort, which drops mean something) are `AgentBoard` in PierKit (tested); an
archive wins over background work, needs-you is oldest first, the rest newest first with the id as tie-break (no reordering on
refresh). The live extras (current step, background work, line changes, last reply of a finished turn, whether a waiting
agent shows an Allow/Deny menu) live in `SessionSignals.shared`, which the Home's `HomeStore` also reads, so the two never poll
twice. Card menu: open, review, Permitir/Negar (only when a menu is on screen), archive / back to "Sua vez", end session
(`EndSessionSheet`). Dragging a card onto Encerradas archives it; back onto Sua vez / Pronto un-archives. iPhone (and portrait
iPad): paged lanes with a column bar whose chips also take drops; wide screens: lanes side by side, Encerradas folded to a
strip. `BoardUITests` covers it on iPhone and iPad (`-openBoard 1` or `-startTab board` opens it at launch).

## Inbox (keyboard first) and suggested next steps

`App/Features/Inbox`: the second tab (iPhone, with a badge) / sidebar item (iPad, Mac), after Início; ⌘2 and the palette. One list across
boxes: agents waiting (oldest first; options read from the screen like the needs-you card: permission menu, numbered menu,
unnumbered cursor menu, single-choice AskUserQuestion; "Recomendado" from `InboxRules.recommended`) then finished turns not
archived and without background work (newest first: reply in Markdown folded, +/−, Revisar, next steps, a reply field). Keys:
J/K or ↓/↑ focus, 1–9 answer (on a finished card 1/2 send a next step), E archive / dismiss, Return open, R reply field, Esc
leaves it. ↓/↑ use a UIKit key command with `wantsPriorityOverSystemBehavior` (the List eats arrows otherwise). Data: the
sessions store plus `SessionSignals` (it now also keeps the waiting agents' screens and the full last reply, in the same
fetches). Every answer/reply goes through `InboxStore.perform(_:on:model:)` into a per-card `SessionViewModel` (the session
screen's `answer(key:)`, `answer(keys:)`, `answerQuestion`, `send(_:when: .idle)`), after re-reading the screen.

Next steps: `NextSteps` (PierKit, tested) builds `claude -p --model haiku` for `exec` in the session's worktree from the last
reply and parses `{"replies":[…]}` (≤ 2, ≤ 60 chars). `NextStepsStore` asks once per turn (box/session/state_since), lazily when
an Inbox card or the end of a finished chat shows, and keeps the answers in memory and in `next-steps.json`. Chips send only on
a tap. Push notifications are unchanged. Debug: `-startTab inbox`, `-inboxResetArchive 1`; `InboxUITests`.

## Ending a session, and the Faxina

"Encerrar sessão" offers **Encerrar e limpar** for a session in a worktree: `DELETE` the worktree (pierd stops its services,
kills its sessions, runs the project's archive script if any) with `delete_branch=1`, then `GitActions.updateMain` (`git pull
--ff-only` in the main checkout, only when nothing tracked is modified). The sheet reads `/v1/worktrees` first: changed or
untracked files and commits not on GitHub (`ahead` against `base`, which is `origin/<branch>` once pushed) are listed and need
"Descartar isso". "Só encerrar o agente" keeps the old behaviour.

**Faxina** (Projetos ⟶ ✦, Ajustes ⟶ Manutenção, and the Shortcuts action "Faxina nas boxes"): `Housekeeping.plan` (PierKit,
tested) over `/v1/worktrees`, sessions and `/v1/services` per box: remove worktrees nobody is on (safe when nothing would be
lost), stop the services of the ones kept, drop exited sessions, update every project's main. The screen ticks the safe steps
and shows why the others are risky; the Shortcuts action runs only the safe ones (`Housekeeper.runSafe`), for a daily
automation.

## Projects coming and going

Projetos ⟶ + (boxes with the `projects` capability): **Repositórios do GitHub** lists the account the box's gh is signed
in to, and its organisations (`GET /v1/github/repos`), marking what is already on the box; a tap clones one, **Clonar
por link** takes any repository link (setup off by default there: it runs the repository's own config, so turning it
on is the person's call; the GitHub list, their own account's, sets up by default). Both `POST /v1/clones` with `setup` (the box trusts the repository's config or
works one out, runs setup, starts the dev server: docs/API.md 2.8); `ClonesStore` polls `GET /v1/clones` while one runs,
shows it under "Chegando na box" and reloads the box's projects when it is ready. **Remover do disco** (a project's
screen, its menu in Projetos, the main checkout's Visão geral) reads `GET …/disk` first (size, uncommitted files,
commits no remote has, stashes, sessions) and needs "Descartar este trabalho" for anything that would be lost; the
project stays on GitHub, to download again from the list.

**Projects folder, spaces, environments** (Ajustes › Projetos, per box with the `environments` capability): the folder
every project lives under and the spaces in it (`BoxProjectsSettingsScreen`; the clone sheets pick a space,
`SpacesStore`). A project's **Ambiente** (`ProjectEnvironmentScreen`, from the project, its Visão geral and a worktree's
Detalhes) picks its language version and its databases. pierd runs them in Docker with launchers first on the
worktrees' PATH, never in the project (docs/API.md 2.9); rows and cards show the space and an "isolated" mark.

**Accounts, limits, variables, public links**: Ajustes › Projetos also has the box's Claude Code and Codex accounts
(`AccountsScreen`: add one, sign in from a terminal session in the app, make it the default) and its variables with a
note each, plus the skills that tell the agents about them (`BoxVariablesScreen`). A project picks its agents' account
(`ProjectAccountsSection`, on the project's screen and in a worktree's Detalhes; `AccountsCache` loads them). The Home's
**Limites de uso** (`LimitsWidget`) shows each account's 5-hour and weekly use and switches the box's default with a tap.
A worktree's Detalhes makes a dev server's **public link** through the box's relay (docs/API.md 2.10–2.12,
PROTOCOL.md §10.1).

## Layouts: tabs (compact) and sidebar (regular width, Mac)

`MainLayout` (RootView) picks by horizontal size class: the iPhone's TabView, or `MainSplit` (iPad, Mac Catalyst): a
`NavigationSplitView` whose sidebar lists Início / Inbox / Quadro / Projetos (the tab bar's order) and the projects in the person's sections, each
expandable to its worktrees and their agent sessions with live state dots. The detail column shows the stack of `Router.tab`,
the same `homePath` / `inboxPath` / `boardPath` / `projectsPath` the tabs use, so notifications, `pier://` links and intents work unchanged
in both. A sidebar pick is `Router.select(_:)`: a project, worktree or session goes on the Projetos stack above its parents
(Back walks up the tree and `projectsPathChanged()` moves the highlight with it). Sidebar rows are buttons into the router,
not a List selection: the split view resets the detail's stack on a selection change. Routes stay registered only in
`pierDestinations()`; on regular width `ProjectRoute` and `WorktreeRoute` show the project workspace below, on the iPhone
their lists.

The sidebar (`Sidebar.swift`) is a ScrollView of its own rows, not a List: a List's drag handling swallowed the drops on
the Mac. Sizes follow `Density` (13 pt text in 26 pt rows on the Mac, room for a finger on the iPad). Projects are dragged
to reorder them or into another section (an insertion line, or the section highlighted), sections by their titles; the
drag carries a type of the app's own (`<bundle id>.sidebar-item`, declared in project.yml, visible to this process
only) so it never drops as text into a field. Each group orders its projects by hand, by name or by recent activity
(`ProjectOrder`, PierKit, tested; `LocalPrefs.Section.sort`, `unsortedSort` / `unsortedOrder` for the projects in
none); a drop that reorders a sorted group makes it manual, and a manual order keeps the keys it does not show (hidden
projects, a box still connecting). "Nova seção" (the footer, where the Mac keeps "New Folder"), "Renomear seção" and
"Renomear…" edit in place: Return keeps the name, Esc drops it, a click elsewhere keeps it. The footer also holds the
Faxina and Ajustes.

## The project workspace (iPad, Mac)

`App/Features/Workspace`: `ProjectWorkspace` shows one worktree of a project (the picker on its bar switches through the
router, so the sidebar's highlight follows) in four tabs, with a status bar (branch, ↑/↓, changes, sessions, port; the
editor's line, column, language and line ending):

- **Arquivos** (`FilesPane`): the tree loads a folder at a time (`GET …/files`, docs/API.md §2.7) with git's word per
  entry (the status letter, a dot on a folder with changes, ignored entries faint and hideable); "Abrir rápido" (⇧⌘O)
  matches every file of the worktree (`FileSearch`: `git ls-files` through exec, read again after the box changed, a
  fuzzy score; in a repository whose list doesn't fit exec's 64 KB, git also narrows by what is typed). git commands run
  from the worktree's top folder, the file routes' root, even for a location inside a repository. Files open in tabs
  in `CodeEditor`: a TextKit 1 UITextView per open file (its own undo, caret and scroll) with line numbers, colors from
  `SyntaxHighlighter` a moment after typing, Return and Tab in the file's indentation and Shift-Tab (`EditorText`), the
  system's find and replace (⌘F); long lines wrap. ⌘S (the menu bar's Salvar, through `FocusedValues.workspace`) saves
  with `PUT …/file` naming the sha the edit started from (one save at a time): when an agent wrote the file meanwhile
  the box answers 409 `file_changed` and that worktree's editor asks (save over it, or reload). The open text file is
  polled (`stat=1`, 3 s): without edits it follows the box, with edits (typed even while it was being read) a banner says
  it changed there, and one deleted says so until it is back. Images show as pictures; files over 2 MiB are not opened.
  A box whose pierd predates the routes says so.
- **Alterações** (`ChangesPane`): the review (`ReviewStore`) as a list of files, uncommitted then the branch's commits,
  beside the patch of the one picked (`PatchView`, shared with `DiffScreen`); Aprovar (commit, push, PR with the AI
  draft), ask the agent for changes, discard (confirmed twice, as on the review screen).
- **Histórico** (`HistoryPane`): `GitLog` through exec, a page at a time (more as the list scrolls; reading the first
  page again keeps the older ones and the commit picked), what is not pushed marked, local and remote branches and tags
  as badges (`--decorate=full`); a commit's message, author, files with their counts, and the patch of the file picked.
- **Visão geral** (`OverviewPane`): the project (path, remote, default branch), its worktrees with their git state, the
  sessions running in this one.
- **Detalhes** (`WorktreeDetailsView`, also a screen of its own on the iPhone): the dev servers listening in the worktree
  as links to the box's address and port (checked from the device), the project's services there with their command and
  start / stop / restart, and its environment (branch, base, port block, folder, setup).

What each worktree holds (open files with their unsaved text, the folders open, the history read, the tab) lives in
`WorkspaceState` for the app's run (`WorkspaceRegistry`), so opening a session or another project and coming back finds it
as it was; the sidebar and the Projetos cards mark projects with unsaved files. A worktree removed (`worktree.removed`, or
Remover worktree, which warns of unsaved files) takes its state with it. The menu bar adds ⌘S, ⇧⌘O (Ir), ⌘R (read the
box again) and ⌥⌘1–5 (the tabs), handed to the workspace in front as requests on its `WorkspaceState`. Projetos itself is
a grid of project cards on regular width; a location that is not a git repository keeps its project screen.

On the iPhone the worktree screen has **Arquivos** and **Histórico**, the same stores one screen at a time
(`CompactWorkspace.swift`): a folder per screen, a file full screen in the editor with Salvar, the commits, a commit's
files, a file's patch (`WorkspaceUITests` covers both).

Keyboard (iPad hardware keyboard, Mac menu "Ir", `PierCommands`; the palette lists the same): ⌘1 Início, ⌘2 Inbox,
⌘3 the agents board, ⌘4 Projetos (the order of the tabs and the sidebar), ⌘, Ajustes, ⌘N new task, ⌘K / ⌘P the palette, ⇧⌘L Faxina, ⇧⌘Space Falar;
in a workspace ⌘S, ⇧⌘O, ⌘R and ⌥⌘1–4. Sheets answer Return (or ⌘Return where Return writes a line) and Esc.

## Live Activity details

`SessionActivityAttributes.ContentState` carries `choices` (how many answers a question offers, read by `LiveActivitySync`
through `ChoiceOptions.fetch`, optional on the wire): the island's compact side shows "?3", the expanded bottom "3 opções ·
toque para responder". "Revisar" is `pier://review?box=&name=` (`Shared.reviewURL`): the Review of the session's worktree
(`Router.onOpenReview` → `AppModel.openSession(review: true)`), the chat when it has none. A finished turn is an update with
a stale date an hour out, as pierd pushes it (the agent can run again on the person's next words and the same activity
follows it); only an exit (`ended`) ends the activity. Debug `-openLink pier://…` opens a link as if tapped.

## DEBUG launch arguments (simulator automation)

`-pairLink <pier://…>`, `-openSession <name>`, `-openFirstSession 1`, `-openCompose 1 -composeProject <loc>
-composePrompt <text> -composeNoFocus 1 -composeOptions 1 -composeSheet project|worktree|base -composeSubmit 1`,
`-startTab inbox|board|projects|settings`, `-seedSections 1`, `-snapshotTo <file.png> [-snapshotAfter <s>]`, `-homeCustomize 1`, `-homeScrollTo <widget>`, `-sessionExpandAll 1`,
`-sessionDetails 1`, `-sessionTerminal 1`, `-uiTestChatLab 1` (with the mock: a long chat of hard Markdown that streams a
reply like Claude Code's when sent to; `ChatQualityUITests`), `-chatPerfProbe 1 [-sessionSend <text>]` (frame pacing of
the open conversation, scrolled and while a reply streams: `CHAT-PERF {...}` on stderr and Documents/chat-perf.json), `-openInstallHelp 1` (the onboarding's "Outros jeitos de instalar" sheet),
`-runIntent postNotif|notifAction|notifDelivered …` (App/Intents/DebugIntentRunner.swift), `-openLink <pier://…>`,
`-debugStartActivity 1`, `-widgetGallery home|lock|activity|island|all`, `-openTalk 1 [-talkText "…" -talkRoute 1]`,
`-openPalette 1`, `-openFaxina 1`, `-openGitHubRepos 1` (with `-startTab projects`: the GitHub list), `-openProject <loc>[/<worktree>] [-workspaceTab files|changes|history|overview|details]
[-openFile <path>]` (a project's workspace); Mac: `-macSurfaceDebug <commands>`, `-macFakeShot <png>`, `-macWindowSize 1280x800`,
and for the alerts through iCloud (`CloudAlerts`, docs/PUSH.md 8) `-cloudAlertsDiagnose 1` (logs every device's
subscription), `-cloudAlertsTest 1` (a test alert for the iPhone and iPad), `-cloudAlertsSeed 1` (every field in
CloudKit's development schema, before deploying it) and `-cloudAlertsFromMock 1` (the mock's transitions relayed too).
`-uiTestShowcase 1` (with the mock) swaps the fixture data for an English showcase dataset (`App/Debug/UITestShowcase.swift`:
four projects, a permission, a question with a recommended choice, a finished turn with a diff and next steps, agents at
work, a chat, pull requests, CI, git activity, dev servers, the AI touches' answers) for screenshots; the widget gallery and
`-seedSections 1` follow it. `UITests/PierUITests/ShowcaseShots.swift` (skipped unless `TEST_RUNNER_SHOWCASE_SHOTS=<dir>`)
writes the system-UI shots: the Lock Screen and the island with a Live Activity, a notification with its choice buttons,
the iPad in landscape. `UITests/PierUITests/StoreShots.swift` (skipped unless `TEST_RUNNER_STORE_SHOTS=<dir>`;
`TEST_RUNNER_STORE_LANG=pt-BR` for Portuguese) writes the App Store's raw screenshots, the iPhone upright and the iPad on
its side. The hooks above run with the mock as with real boxes (`AppModel.runLaunchHooks`).
`-uiTestMock 1` swaps the paired boxes for one in-memory box (`App/Debug/UITestMock.swift`, fixtures generated from
`Packages/PierKit/Tests/PierKitTests/Fixtures` into `App/Debug/UITestMockFixtures.swift`): no network, keychain or push.
It answers like pierd for the endpoints the app uses and is stateful for send, answer and create task; its worktrees
have files and a history (`App/Debug/UITestMockWorkspace.swift`: the file routes with sha checks, `GitLog` and
`FileSearch` commands), and saves stick for the run. Its projects come and go too (`App/Debug/UITestMockProjects.swift`:
a GitHub account's repositories, clones that are ready after about 3 s, disk use and removal, with `sandbox` holding
unsaved work, and each worktree's `dev` service, which can be stopped and started), and so do its projects folder (a
space "clientes" once one is set), spaces and environments (each "building" for 2 s, then ready). On the Mac a mock run shares the installed app's container and App
Group: its sidebar prefs go to `prefs-mock.json`, and it never writes the widgets' copy of names and hidden projects
(the app rewrites that copy at launch). `-uiTestExtras 1`,
`-uiTestChats 1`, `-uiTestPRs 1`, `-uiTestAsk 1` (an agent asking a question with three choices) and `-uiTestHealth 1`
(a doctor report with three things to fix) add to its data.

## UI tests (real keyboard)

`UITests/PierUITests` (XCUITest, runs against the mock box) types with the real software keyboard: Compose with a long
prompt and Opções open, the session composer growing / sending / interactive dismissal, the needs-you card with the keyboard
closed and open, the Revisar card, and the Home "Nova tarefa" placement (toolbar "+", next to Falar).
Run: `xcodebuild test -scheme Pier -destination 'platform=iOS Simulator,name=<sim>' -derivedDataPath build/dd`
(Simulator: Connect Hardware Keyboard off). `TEST_RUNNER_KBD_SHOTS=<dir>` also writes the screenshots as PNG
(`kbd-*.png`).
Note: XCUITest does not see the bottom ~130pt of the lazily laid out conversation in its accessibility snapshot, so the
Revisar button is tapped by position in that test.

## Status dots, Mac menu bar, onboarding, "Levar para o iPhone"

- **Dots** (`App/Features/Dots`): `AgentDots.make` lists every live agent session (archived turns and hidden projects left
  out), needs-you first; `AgentDotStrip` draws them at the top of the Home (iPhone/iPad) and of the sidebar. Tap opens the
  session; labels (title · project) show while ⌥ is held (`ModifierKeys`, which observes `UIApplication.sendEvent`), while
  the pointer rests on the strip, or after a long press.
- **The Mac plugin**: Catalyst cannot use AppKit, so `Mac/PierMenuBar` is a macOS bundle target (project.yml
  `PierMenuBar`, embedded in `Contents/PlugIns` for Mac Catalyst only). `MenuBarBridge` loads it with `Bundle.load()` and
  talks through Objective-C methods with Foundation values (`start:` with the action handler, `update:strings:` with the
  agents and the localized texts, `configureSurface:` / `updateSurface:` for the edge surface below); updates follow the
  model through Observation. The **menu bar item** (the dots in the macOS menu bar, with a menu of the agents) is off by
  default now that the edge tab exists (Ajustes → Mac → "Mostrar na barra de menus"); hiding the tab turns it on by
  itself, so Pier never has no always-present surface (`MacSurfaceSettings.enforce`). ⌃⌥Space (the Carbon hot key) is
  registered either way. Set `PIER_MENUBAR_DUMP=<dir>` to write the button image and the menu titles; Debug
  `-menuBarAction open:<box>/<session>|talk|new|app` runs a pick. The plugin links no SwiftUI: the Catalyst process already
  holds the iOS one, and a second (macOS) copy of the module would clash.
- **The edge tab (Mac)**: the always-present One-style surface, drawn by the same plugin (`EdgeSurfacePanels.swift`,
  `SurfaceStyle.swift`) and fed by `MacSurfaceStore` (App/Features/MenuBar). One narrow black tab hanging from a screen
  edge like a drop: the body about 1.9 × an indicator wide (19 / 23 / 30 pt at Pequeno / Médio / Grande), each end an
  S-curve out of the edge — a concave flare tangent to the edge (radius 0.6 × the width) turning, tangent, into the body's
  round end (radius 0.5 ×), one continuous path (`EdgeOutline`, PierKit: the tangents, the radii and the mirrored bottom
  are tested). Right by default; draggable along the edge (the position a fraction of the screen's height, also a slider
  in Ajustes); on every Space, over full-screen apps only by setting; on the main screen, the one the pointer is on, or a
  chosen one; three sizes (`EdgeMetrics`: the indicators 10 / 12 / 16 pt at a pitch of 1.4 ×, the glyphs 12 / 14 / 16 pt in
  clickable boxes of 24 pt or more, invisible, inside the shape). Folded it shows one indicator per agent in
  `AgentDots.make` order: a blue ring turning while it works, an amber dot when it needs the person (dimmed for the ones
  the Inbox is not showing), green when its turn ended; a quiet ring when there is no agent. It **grows in place** — the
  same silhouette, the body wider, the ends' curves scaling with it, the first and last item at the centre of the round
  ends — to hold the Inbox button with the unseen count (the badge at the glyph's corner, ringed, drawn last), the agents
  (the section is left out when there are none), Nova tarefa, Falar, Apontar na tela and "…" (a menu with everything the
  menu bar item offered and the tab's settings: edge, position, size, screen, full screen, "Ocultar a aba" ⌃⌥P, Ajustes).
  The window is one fixed transparent **canvas** (`EdgeMetrics.canvasSize`: room for the grown tab and the widest label
  beside it), flush with the edge at whole points, its middle at the chosen fraction; it moves or
  resizes only when the state does (the agents' count, a label, the settings), never while the pointer is on it:
  folding and growing (one `openness` number driven by a stiff critically damped spring, about 0.2 s, no overshoot) happen
  inside it, so the edge side and the tab's centre never move. The glyphs are drawn once at their final size and fade in
  over the first half of the growth. Items keep their size under the pointer: a Dock-like magnification was tried and
  removed (it made the tab wobble as the pointer moved). The item under the pointer glows and a label with its name floats
  beside it. Only the shape takes the pointer
  (`hitTest` by the outline path, 3 pt of slack); the transparent rest is click-through — `NSWindow.windowNumber(at:)`
  names the window behind, which the `probe` debug command logs. When it opens: `EdgeHover` (PierKit, tested) — open
  while the pointer is on the shape, folds only 0.4 s after the pointer left (a return cancels; the real pointer position
  is checked again before folding), and never while something pins it: an agent needing the person, the side panel or
  the menu open, ⌥ held (labels beside the dots), the 8 s "Sua vez · title" toast after a turn finished. Reduce Motion:
  no spring (the tab grows and folds at once). The pure rules
  (`EdgeLayout`, `EdgeMetrics`, `EdgeOutline`, `EdgeColumn`, `EdgeHover`, `PanelNavigator`, `OptionDoubleTap`,
  `SurfacePaging`, `EdgeSurfaceRules`) are PierKit's `EdgeSurface.swift`, tested, and compiled into the plugin as a
  source. Settings in Ajustes → Mac (`MacSurfaceSettings`, UserDefaults `macSurface.*`: enabled, edge, fraction, display,
  size, fullScreen, optionTap, menuBar; the tab's menu and its drag write the same keys). **⌃⌥P** (a Carbon hot key, id 2
  beside ⌃⌥Space's 1, no permission needed) shows or hides the tab from any app (`surface:toggle`); hiding shows the toast
  "Aba oculta · ⌃⌥P mostra de novo" and turns the menu bar item on, whose first item is then "Mostrar a aba na borda".
  Debug: `-macSurfaceDebug "hover,panel:inbox,pick:1,…"` (one command every 1.5 s: hover, unhover, option, labels,
  collapse, toast, point:<y>, panel:<inbox|agents|agent:<id>|task|chat|project|talk|close>, page:<n>, pick:<n>,
  reply:<text>, undo, optiontap, pointat, pointat:auto, probe, menu, state — `state` logs the canvas, the openness, every
  button's frame and the panel's stack; screenshots without Screen Recording: `snapshot:<dir>` writes `tab.png` and
  `panel.png` drawn from the views at 2× with alpha, `pointat:render:<dir>` the point-at-it overlay as `pointat.png`,
  `offscreen` keeps the tab and the panel laying out but off the screen, `hidewindow` orders the app's window out),
  `-macFakeShot <png>` stands in for the screen, `-uiTestEmpty 1` a box with no session.
- **The side panel (Mac)**: `SidePanelController` (`SidePanel.swift`, `PanelScreens.swift`, `InboxCardPanel.swift`,
  `MarkdownText.swift`) — a dark panel beside the tab, its pointer aimed at the tab's Inbox button, dark in both
  appearances (`PanelStyle`: #141416 / #1C1C1E, hairlines, radius 26, bold white titles, gray secondary text, keycaps,
  green "Recomendado" and checks), with one navigation stack (`PanelNavigator`, PierKit, tested: a tab button opens its
  root screen and the same button closes it; an indicator opens its agent under the agents list; a task just started
  replaces the form by its agent; an agent that is gone goes back to the list). Screens: **Inbox** — one Inbox item at a
  time (`InboxStore.items`, needs-you then finished; a page indicator, ← → / J K), the agent, its question (a command in
  a code box), the answers as rows with keycaps, a reply field (the mic dictates into it with the app's `Dictation`), a
  hint pill; 1–9 answer through `InboxStore.perform` (the undo window: the row turns green with a check, "Enviando… Esc
  desfaz", then "✓ Enviado para Claude"), E archives / dismisses, Return opens the agent. **Agentes** → one **agent**:
  its state and step, the last reply as compact Markdown (`MarkdownText`, Foundation's `AttributedString(markdown:)`),
  its question and choices, the next steps as keycap rows (`NextStepsStore`, asked only while that screen shows), a
  composer with the mic, Interromper / Arquivar / Revisar +N −M, "Abrir no Pier". **Nova tarefa / Nova conversa** on the
  app's `ComposeModel` and `TaskCreator`: a searchable project picker recent-first, new worktree or main, the agent,
  model and effort, the prompt (⌘↩ starts), dictation, a screenshot through Apontar; started, the panel shows the agent
  ("Iniciando…") without opening the app. **Falar** on `TalkModel`: the words, Encaminhar, the plan to confirm or adjust
  in the app. Keys: Esc goes back, then closes (undoes while an answer waits); ⌘N / ⌘⇧N; ← or H back. The panel is a
  non-activating `NSPanel` that never takes the keyboard until a text field is clicked (Esc gives it back), and the app's
  window is never brought forward unless asked (Abrir no Pier, Revisar, Ajustes). The plugin ↔ app protocol: actions
  `panel:screen:<name>`, `agent:<pick|send|interrupt|archive|review|open>:<id>…`, `compose:<set…|project|camera|start>`,
  `talk:<route|confirm|open>`, `dictation:toggle:<target>`, `shot:<target>|<path>`; payload keys `agents`, `agentDetail`,
  `started`, `compose`, `talk`, `dictation`, next to the Inbox's `cards` / `current` / `pending` / `receipt`.
- **⌥ twice → Falar (Mac)**: `OptionTapMonitor` in the plugin feeds every modifier change to `OptionDoubleTap` (two taps of
  ⌥ alone within 0.35 s each and 0.45 s apart; any other key or modifier cancels). Other apps' keys reach the process only
  with Input Monitoring (or Accessibility): checked with `IOHIDCheckAccess` / `AXIsProcessTrusted`, asked for with
  `IOHIDRequestAccess` only from Ajustes → Mac ("Permitir…", and the System Settings pane), never at launch. Without it the
  double tap works while Pier is in front and ⌃⌥Space (the Carbon hot key) stays the way in from anywhere.
- **Apontar na tela (Mac)**: ⇧⌘A, the camera button or the menu: `RegionPicker` dims every screen (non-activating panels,
  Esc cancels), the person drags a rectangle, `SCScreenshotManager` (ScreenCaptureKit) captures it at the screen's scale
  and the app opens Falar with the picture attached (`TalkImage`: JPEG like Compose's photos, a chip under the field).
  `TalkActions.perform` uploads it first (`POST /v1/sessions/{name}/attachments`, or the worktree-first path of
  `TaskCreator.create(attachments:)` for a new task) and sends its path under the words. Screen Recording is checked with
  `CGPreflightScreenCaptureAccess` and asked with `CGRequestScreenCaptureAccess` the first time the person reaches for it
  (macOS applies it after a relaunch); Ajustes → Mac shows the state and the pane.
- **Widgets on the Mac**: `PierWidgets` builds for Mac Catalyst too (`SUPPORTS_MACCATALYST`, families
  `systemSmall/Medium/Large/ExtraLarge`, its own sandboxed entitlements `PierWidgets-mac.entitlements`); the Live Activity
  stays `#if !targetEnvironment(macCatalyst)`. The app writes the snapshot to the App Group on the Mac as on the phone;
  the refresh timing is `WidgetRefreshPolicy` (PierKit). Debug `-widgetGallery home` renders the families in-app.
- **Onboarding**: three steps, then "Tudo pronto!" (`Router.onboardingFinishing` keeps it up after the box pairs). The
  pairing step asks where the agents run (`PairPlace`). "Neste Mac" (the Mac's default): the one install command
  (`PierLinks.installCommand`, `site/install.sh`) to paste in Terminal; it ends with `pierd setup`, which opens its
  `pier://` link on this Mac, and the app pairs without the confirm phase because the link names this very device
  (`ThisDevice.isHere`, `LocalHost.isThisDevice` in PierKit); the switch "Abrir o Pier quando o Mac ligar" (on by
  default) registers the app as a login item once the box pairs (`LoginItem`, `SMAppService.mainApp`; also in Ajustes).
  "Tudo pronto!" then offers "Levar para o iPhone". "Num servidor": the same command, to run over SSH, then the link
  (scanned on a phone, pasted on the Mac); "Outros jeitos de instalar" (`InstallHelpSheet`, also under Ajustes →
  Adicionar box) offers a prompt for the agent already running there and the commands (the script, npm, Homebrew) with
  Copiar. "No meu Mac" (the phone's default): the code the Mac's "Levar para o iPhone" shows.
  Debug `-uiTestMock 1 -uiTestOnboarding 1` starts with no box; pairing any link "pairs" the mock box.
- **Demo**: the first step and the pairing step offer "Explorar com dados de exemplo" (`DemoMode`): the mock box with the
  showcase's data (`UITestMock.makeConnection`, compiled into Release builds), one more box for the app — no network,
  keychain or push — until the person leaves it (Ajustes, the Home's banner) or pairs a box of their own; it comes back
  after a relaunch. It is how App Review sees the app. Its sections and marks are `prefs-demo.json`, push registration
  skips it, and the Home's cache remembers the boxes it came from (`HomeStore.Cache.boxes`), so neither the demo nor a
  mock run on the Mac leaves its data on the person's Home. Debug `-uiTestDemoReset 1` starts outside the demo.
- **Links from outside**: a `pier://` pairing or join link that reaches the app through `onOpenURL` (a tap in a
  message or a web page) opens the pairing sheet in a confirm phase (`PendingPair.confirm`: address and pinned
  fingerprint, Parear / Cancelar) because pairing hands the box this device's name and push tokens. Links the person
  scanned or pasted, links that name this very Mac (pierd setup on it), and the Debug `-pairLink` argument, pair at
  once.
- **Levar para o iPhone** (Ajustes): `BoxAPI.pairInvite()` asks `POST /v1/pair/invite` (`{"link","expires"}`); a box
  without it gives `PairInviteError.unsupported` (the screen says to run `pierd pair`). Several boxes become one
  `pier://join` link. Debug `-openInvite 1` (with `-startTab settings`), `-uiTestNoInvite 1`.
