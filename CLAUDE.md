# CLAUDE.md

Pier is a monorepo with two halves that talk to each other over a mutual-TLS `/v1` API:

- **The apps** (Swift): iPhone, iPad and Mac (Mac Catalyst, same target), plus widgets, Live Activities, a notification
  service extension and the Mac menu bar plugin.
- **pierd** (Go): the server each Linux dev box runs. It runs the agents (Claude Code, Codex) in tmux, follows them
  through their hooks, manages git worktrees and dev servers, and sends push through the user's own APNs key.

There is no cloud or relay: the app pairs with each box once (QR code / `pier://` link) and talks to it directly.

## Layout

| Path | What | Language |
|---|---|---|
| `App/` | The app target (SwiftUI): `Core/` (AppModel, BoxConnection, EventHub, Router), `Features/*` (one folder per screen), `Shared/` (compiled into the app *and* the extensions), `Debug/` (mock box), `DesignSystem/`, `Intents/`, `Resources/` | Swift |
| `Extensions/PierWidgets` | Home Screen / desktop widgets and Live Activities | Swift |
| `Extensions/PierNotificationService` | Turns a push's `options` into notification buttons | Swift |
| `Mac/PierMenuBar` | AppKit plugin: menu bar item, edge tab, side panel | Swift |
| `Packages/PierKit` | SwiftPM package shared by everything Swift: transport (swift-nio-ssl), identity, pairing, typed API, Codable models of pierd's JSON, pure tested helpers (`Support/`) | Swift |
| `Server/pierd` | The box server, its own Go module (`go.mod`, standard library only), own README and `docs/` | Go |
| `Tools/pierctl` | macOS CLI client for end-to-end checks against a real box | Swift |
| `Vendor/swift-nio-ssl` | Vendored with a TLS-exporter patch needed for pairing (see `Vendor/README.md`) | Swift |
| `UITests/PierUITests` | XCUITest against the in-memory mock box | Swift |
| `Config/` | `Base.xcconfig` (identifiers), `Signing.example.xcconfig`, build-number script | |
| `Design/` | Script that renders the app icon's mascot | |
| `docs/` | `ARCHITECTURE.md` (read this first), `PROTOCOL.md` (transport, pairing), `API.md` (endpoints), `PUSH.md` | |

`project.yml` is the XcodeGen spec; `Pier.xcodeproj` is generated and gitignored. Targets: `Pier`, `PierWidgets`,
`PierNotificationService`, `PierMenuBar`, `PierUITests`.

## Build and test

```sh
xcodegen generate                                      # after any change to project.yml or new/removed files
cd Packages/PierKit && swift test                      # transport, pairing, API, parsers
cd Server/pierd && go vet ./... && go test ./...       # the server (needs tmux and git)
xcodebuild -project Pier.xcodeproj -scheme Pier -destination 'generic/platform=iOS Simulator' build
xcodebuild test -project Pier.xcodeproj -scheme Pier -destination 'platform=iOS Simulator,name=iPhone 17'
```

- Mac build: `-destination 'platform=macOS,variant=Mac Catalyst'`.
- `-uiTestMock 1` replaces every paired box with an in-memory one: UI work without a server. Other launch arguments are
  listed in `docs/ARCHITECTURE.md`.
- pierd for a box: `cd Server/pierd && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o pierd ./cmd/pierd`.

## Rules

- **Changes that cross the wire touch both halves in the same PR**: pierd's handler/`internal/wire`, PierKit's
  `Models/` and `API/`, the fixtures in `Packages/PierKit/Tests/PierKitTests/Fixtures`, and `docs/API.md`.
  `Server/pierd/docs/API-SURFACE.md` maps which app code calls which route.
- **Fixed names** (see "Fixed names and values" in `docs/ARCHITECTURE.md`): the pairing labels `EXPORTER-pier-pair-v1` /
  `pier pair v1` must stay byte-identical in Swift and Go; `pier://` is the only URL scheme.
- **Identifiers are never hard-coded**: everything derives from `PIER_BUNDLE_ID` and is read from Info.plist by
  `App/Shared/SharedSupport.swift`.
- Swift 6 strict concurrency; PierKit types are `Sendable`; UI state is `@Observable` on the main actor. iOS 17 minimum.
- Pure logic goes in PierKit `Support/` with tests, not in views.
- UI strings in pt-BR and English through String Catalogs (`App/Resources/Localizable.xcstrings`,
  `App/Features/Dashboard/Home.xcstrings`, `App/Resources/AppShortcuts.xcstrings`); never a fixed string in one language.

## Workflow and privacy

- This is a public repository (`github.com/wagnerfnds/pier`). Work on a branch and open a PR (`gh pr create`) into `main`.
- Never commit personal or machine-specific data: `Config/Signing.xcconfig` (team, bundle id), APNs/ASC keys (`*.p8`),
  IPs or hostnames of boxes, emails, App Store Connect ids. They are gitignored; keep it that way and add new local
  files to `.gitignore`.
- Commit messages: one descriptive sentence of what changed and why, in the style of `git log`.
