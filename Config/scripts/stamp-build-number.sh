#!/bin/sh
# Stamps a build number that grows with every build into the built Info.plist (before signing).
# iOS keys its icon caches (notifications, Settings, Spotlight) on CFBundleVersion: with a fixed "1"
# a new app icon shows on the home screen but notifications keep the old one.
# The widget extension builds first and writes the number; the app reuses it so both match.
set -e
STAMP="$BUILT_PRODUCTS_DIR/.pier-build-number"
if [ "$1" = "write" ] || [ ! -f "$STAMP" ]; then
  echo $(( ($(date +%s) - 1767225600) / 60 )) > "$STAMP"   # minutes since 2026-01-01
fi
NUM=$(cat "$STAMP")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUM" "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
