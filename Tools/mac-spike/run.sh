#!/bin/bash
# Track 7 spike: builds the Catalyst app and the native PierMac the same way (optimized, with the DEBUG launch hooks,
# unsigned), puts copies side by side and measures them on the mock box. No real box, pairing or key is touched.
#
#   Tools/mac-spike/run.sh build            both apps, into build/dd-cat and build/dd-mac
#   Tools/mac-spike/run.sh prepare          build/measure/{cat-full,cat-noplugin,native}: isolated copies
#   Tools/mac-spike/run.sh measure <out> <rounds>   the scenarios, every build in turn
#   python3 -I Tools/mac-spike/table.py <out>      the PR's table (aggregate.py: every run's numbers)
#
# With AeroSpace, MAC_SPIKE_WORKSPACE=<an empty workspace> MAC_SPIKE_HOME_WORKSPACE=<yours> give every window the same
# size. The shell running this needs Accessibility permission for the accessibility walks.
#
# cat-full is the Catalyst app as it ships on the Mac (its menu bar / edge tab plugin); cat-noplugin leaves the plugin
# out, to compare the window alone with `native -pierMacNoSurface 1`. Every copy is isolated like the local test build
# (PierLocalTest: no App Group, iCloud or push) and has no pier:// scheme, so this Mac never hands links to it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$ROOT/Tools/mac-spike"
M="$ROOT/build/measure"
OPT=(-configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
     SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s
     ENABLE_TESTABILITY=NO ENABLE_DEBUG_DYLIB=NO)
LAB=(-uiTestMock 1 -uiTestChatLab 1 -uiTestChatLabTurns 240 -uiTestChatLabPageSize 300)

case "${1:-}" in
build)
  cd "$ROOT"
  xcodegen generate
  xcodebuild -project Pier.xcodeproj -scheme Pier -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath build/dd-cat "${OPT[@]}" build
  xcodebuild -project Pier.xcodeproj -scheme PierMac -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/dd-mac "${OPT[@]}" build
  xcrun swiftc -O -o "$T/axprobe" "$T/axprobe.swift"
  ;;
prepare)
  rm -rf "$M"
  mkdir -p "$M/cat-full" "$M/cat-noplugin" "$M/native"
  ditto "$ROOT/build/dd-cat/Build/Products/Debug-maccatalyst/Pier.app" "$M/cat-full/Pier.app"
  rm -rf "$M/cat-full/Pier.app/Contents/PlugIns/PierWidgets.appex"
  ditto "$M/cat-full/Pier.app" "$M/cat-noplugin/Pier.app"
  rm -rf "$M/cat-noplugin/Pier.app/Contents/PlugIns"
  ditto "$ROOT/build/dd-mac/Build/Products/Debug/PierMac.app" "$M/native/PierMac.app"
  for p in "$M"/cat-*/Pier.app/Contents/Info.plist; do
    /usr/libexec/PlistBuddy -c "Add :PierLocalTest bool true" "$p" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :PierLocalTest true" "$p"
  done
  for p in "$M"/*/*.app/Contents/Info.plist; do /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$p" 2>/dev/null || true; done
  ;;
measure)
  OUT="$2"; ROUNDS="${3:-2}"
  mkdir -p "$OUT"
  m() { python3 -I "$T/measure.py" "$@"; }
  for r in $(seq 1 "$ROUNDS"); do
    # A: the long chat open, 60 s idle, then an accessibility client walks the tree twice and polls the windows.
    m "$M/cat-full/Pier.app" cat-full "$OUT/idle-cat-full-$r.json" --settle 20 --idle 60 --ax -- "${LAB[@]}" -openSession chatlab-claude-z9
    m "$M/native/PierMac.app" native-surface "$OUT/idle-native-surface-$r.json" --settle 20 --idle 60 --ax -- "${LAB[@]}" -openSession chatlab-claude-z9
    m "$M/cat-noplugin/Pier.app" cat-noplugin "$OUT/idle-cat-noplugin-$r.json" --settle 20 --idle 60 --ax -- "${LAB[@]}" -openSession chatlab-claude-z9
    m "$M/native/PierMac.app" native "$OUT/idle-native-$r.json" --settle 20 --idle 60 --ax -- "${LAB[@]}" -openSession chatlab-claude-z9 -pierMacNoSurface 1
    # B: NavPerfProbe, three walks through Home, the sessions (the long chat among them), Inbox, Board, Projetos.
    m "$M/cat-noplugin/Pier.app" cat-noplugin "$OUT/nav-cat-noplugin-$r.json" --settle 5 --idle 0 --wait-for NAV-PERF-SUMMARY --wait-timeout 240 -- "${LAB[@]}" -navPerfProbe 1 -navPerfProbeLoops 3
    m "$M/native/PierMac.app" native "$OUT/nav-native-$r.json" --settle 5 --idle 0 --wait-for NAV-PERF-SUMMARY --wait-timeout 240 -- "${LAB[@]}" -navPerfProbe 1 -navPerfProbeLoops 3 -pierMacNoSurface 1
    # C: ChatPerfProbe on the long chat (a fling up and back, a streamed reply), then 60 s idle with the indicators on.
    CHAT=(-openSession chatlab-claude-z9 -chatPerfProbe 1 -sessionSend "Explain it once more, briefly")
    m "$M/cat-noplugin/Pier.app" cat-noplugin "$OUT/chat-cat-noplugin-$r.json" --settle 35 --idle 60 --wait-for CHAT-PERF --wait-timeout 30 -- "${LAB[@]}" "${CHAT[@]}"
    m "$M/native/PierMac.app" native "$OUT/chat-native-$r.json" --settle 35 --idle 60 --wait-for CHAT-PERF --wait-timeout 30 -- "${LAB[@]}" "${CHAT[@]}" -pierMacNoSurface 1
  done
  ;;
*)
  sed -n '2,15p' "$0"; exit 2 ;;
esac
