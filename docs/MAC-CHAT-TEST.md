# Isolated Mac conversation test

`Pier Teste.app` is an experimental Mac Catalyst build for testing the conversation view. It keeps the visual chat and
uses Debug hooks with Swift optimization (`-O`) and debugging symbols. It is ad-hoc signed, not Developer ID signed or
notarized. It is not an official Pier release, and passing automated tests does not establish that every hang is fixed.

## Build

Use a Mac with full Xcode and XcodeGen; Command Line Tools alone do not include the Catalyst build environment. The
manual GitHub Actions workflow `Pier isolated Mac test` uses the standard `macos-26` Apple silicon runner and selects
`/Applications/Xcode_26.6.app/Contents/Developer`. It runs PierKit unit tests, builds the app, packages it and optionally
runs the mock conversation history UI tests. It uses no signing certificate or Apple account secrets.

```sh
bash Config/scripts/build-local-test.sh build
bash Config/scripts/build-local-test.sh package
bash Config/scripts/build-local-test.sh test
```

The generator reads `project.yml` and writes an ignored `.pier-local-test.json`, `PierLocalTest.xcodeproj`, and a test
Info.plist under `build/local-test`. Production configuration and `Config/Signing.xcconfig` are not changed or read.
Outputs are in `build/local-test`: the zipped app, dSYM, build metadata, logs and the UI test result bundle. The workflow
packages the app before any test launch; it does not collect pairings, conversation caches or other user data.

The workflow must exist on the fork's default branch before GitHub registers its `workflow_dispatch` trigger. A run can
then select another branch. See [GitHub manual workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
and the [runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

## Isolation and pairing

- The app and keychain service use `dev.pier.app.chatfix`, with a separate Application Support folder and defaults.
  Its conversation cache also lives under `Caches/dev.pier.app.chatfix/Transcripts`, rather than the generic
  `Caches/Transcripts` directory used by an unprovisioned production build.
- `PierLocalTest = true` in its generated Info.plist disables App Group storage, iCloud sync/alerts, remote push, login
  registration and keychain migration. Widgets and notification service extensions are omitted. The menu bar plugin
  keeps its own test bundle identifier.
- The build first uses its own keychain service. The existing Debug fallback uses private files (directory 0700,
  files 0600) if macOS denies keychain access because the build lacks the required entitlement.
- Pair the test app with the box again. Do not copy the installed app's private identity or pairing files. Session
  transcripts remain on the box, so the new pairing can open those conversations.
- Both apps understand `pier://`. Paste the pairing link inside **Pier Teste** to avoid opening the installed app by
  mistake. Keep the installed Pier in place; this script never replaces or installs either app.

The test app does not have the production app's provisioning or sandbox. macOS may ask for approval when opening this
experimental app. Follow the normal macOS prompts; do not disable Gatekeeper or remove security attributes. Apple's
[opening apps guidance](https://support.apple.com/en-us/102445) describes the available system checks and prompts.

## Scroll correction

On Mac Catalyst 18 and later (macOS 15+), a `VStack` measures loaded history directly, avoiding the lazy stack's
height-estimation loop when older Markdown rows enter the viewport. Its final child is one `VStack` containing the
two latest turns with a response, including their prompts and work folds,
plus newer items, outgoing messages, the live draft, cards and the end marker. Keeping the previous response in this child
preserves its measured height when a draft becomes a recorded reply. The child has a stable identity; transcript row IDs
are retained when prepending history or changing content. Text selection and Markdown remain available.

The Mac has no automatic bottom anchor: loading, content changes and a settled viewport request one explicit scroll to
the bottom of that measured group, outside the layout transaction. Resize requests wait for 250 ms without another
viewport size change, and user interaction or reading older messages prevents automatic following. After the first valid
scroll command, one correction waits 250 ms; any rounded, positive child-height change restarts that same timer. A new
height callback is not required, since a retained view may not repeat an unchanged measurement on reappearance. This
budget is consumed before following and is canceled when loading older history or leaving the view. Only a new
appearance or deliberate return-to-end/new send resets it; draft, revision and viewport events cannot rearm it.
Scroll geometry callbacks record
passive diagnostics and handle actual user scrolling; estimated list height and idle scroll geometry cannot request
history or schedule another follow. iPhone and iPad keep separate lazy rows and their initial-position
fallback. Catalyst 17 (macOS 14) also retains separate lazy rows and the default bottom anchor because its visibility
fallback uses row appearance.

Content following uses a view-model revision when transcript items or pending prompts change, including a command or tool
updated at the same server cursor. Metadata-only polls do not request a follow; the transcript is not compared in the view body.

The server's initial window contains at most 300 transcript items; each request for older messages adds up to 120.
Pagination preserves the previously visible block after a successful history load. Already loaded and cached items are
not discarded, so memory and layout costs can grow with requested history. Offscreen transcript blocks beyond one
viewport of overscan on each side are hidden only from the accessibility tree; their content, layout and scroll IDs
remain intact. This pruning is disabled when VoiceOver or Switch Control is enabled, and unknown geometry leaves
the block accessible. Per-block geometry updates only this accessibility state, never follow or pagination.
Exceptionally large replies and expanded work folds still have a rendering cost. This change
does not cap or remove access to older messages; test expanded histories as well as the initial window.

## Validation

`ChatHistoryUITests` uses an in-memory mock: a small unpaged conversation, hundreds of paginated turns, and a final reply with tall Markdown rows. It
checks opening at the latest reply, loading older history by scrolling, returning to the latest reply, and switching
sessions while retaining UI responsiveness, plus a completed streamed reply after a very tall message. With the opt-in
mock probe enabled, `CHAT-SCROLL` logs contain only numeric geometry, decision roles and mock stream phases; no text or
user/session identifiers are recorded. It never contacts a real box. The artifact includes failures as well as
successes; check the workflow conclusion and `ChatHistory.xcresult` before interpreting its result.

After pairing locally, repeat the session switch that previously froze the app, scroll older messages, return to the
latest reply, and resize the window. A new hang requires a fresh process sample and the build's dSYM; do not include
private message text or pairing credentials in a public report. The automated mock and this manual reproduction cover
different evidence; keep their outcomes separate.

For an A/B comparison, dispatch the same workflow with `baseline = true`. It replaces only `ConversationView.swift`
with the released `pier-mac-v1.1` implementation and adds the same scroll identifier and DEBUG counter. All other
configuration and synthetic tests stay identical. The baseline run uploads diagnostics, not an app for distribution.
The helper can also write a scratch file locally with `--output`; it refuses to replace local app source outside CI.
