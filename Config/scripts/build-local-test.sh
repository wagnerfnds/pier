#!/bin/bash
# An opt-in, ad-hoc signed Catalyst build with independent identity and storage. Only `test` launches its mock UI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
MODE="${1:-build}"
BUILD_DIR="$ROOT/build/local-test"
DERIVED="$BUILD_DIR/DerivedData"
LOGS="$BUILD_DIR/logs"
mkdir -p "$LOGS"

generate() {
  ruby Config/scripts/generate-local-test.rb
  xcodegen generate --spec .pier-local-test.json
}

base_args=(
  -project PierLocalTest.xcodeproj -scheme Pier -configuration Debug
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64'
  -derivedDataPath "$DERIVED"
  -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO
)

build() {
  generate
  xcodebuild "${base_args[@]}" build 2>&1 | tee "$LOGS/build.log"
}

test_ui() {
  # The mock-only suite never connects to a real box or reads its credentials.
  xcodebuild "${base_args[@]}" test \
    -only-testing:PierUITests/ChatHistoryUITests \
    -parallel-testing-enabled NO \
    -maximum-test-execution-time-allowance 180 \
    -test-timeouts-enabled YES \
    -resultBundlePath "$BUILD_DIR/ChatHistory.xcresult" \
    2>&1 | tee "$LOGS/ui-tests.log"
}

package() {
  local products="$DERIVED/Build/Products/Debug-maccatalyst"
  local app="$products/Pier Teste.app"
  local dsym="$products/Pier Teste.app.dSYM"
  test -d "$app"
  test -d "$dsym"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tee "$LOGS/signature.log"
  /usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" | /usr/bin/grep -Fx 'dev.pier.app.chatfix'
  /usr/bin/plutil -extract PierLocalTest raw "$app/Contents/Info.plist" | /usr/bin/grep -Fx 'true'
  /usr/bin/codesign --display --entitlements - --xml "$app" > "$LOGS/entitlements.plist" 2> "$LOGS/signing-details.log"
  python3 - "$app" "$LOGS/entitlements.plist" <<'PY'
import pathlib
import plistlib
import sys

app, entitlement_path = map(pathlib.Path, sys.argv[1:])
raw = entitlement_path.read_bytes().strip()
entitlements = plistlib.loads(raw) if raw else {}
restricted = [key for key in entitlements if key in {
    'keychain-access-groups', 'com.apple.security.application-groups', 'aps-environment'
} or key.startswith('com.apple.developer.icloud') or key.startswith('com.apple.developer.ubiquity')]
if restricted:
    raise SystemExit('Unexpected provisioned entitlements: ' + ', '.join(restricted))
if list(app.rglob('*.appex')) or list(app.rglob('*.provisionprofile')):
    raise SystemExit('An isolated build must not include app extensions or provisioning profiles')
PY
  /usr/bin/ditto -c -k --keepParent "$app" "$BUILD_DIR/Pier-Teste.app.zip"
  /usr/bin/ditto -c -k --keepParent "$dsym" "$BUILD_DIR/Pier-Teste.dSYM.zip"
  {
    git rev-parse HEAD
    xcodebuild -version
    xcodegen --version
    shasum -a 256 "$BUILD_DIR/Pier-Teste.app.zip" "$BUILD_DIR/Pier-Teste.dSYM.zip"
  } > "$BUILD_DIR/build-info.txt"
}

case "$MODE" in
  generate) generate ;;
  build) build ;;
  test) test_ui ;;
  package) package ;;
  all) build; test_ui; package ;;
  *) echo 'Usage: build-local-test.sh [generate|build|test|package|all]' >&2; exit 2 ;;
esac
