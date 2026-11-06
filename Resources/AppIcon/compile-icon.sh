#!/bin/zsh
# Compile the authored default, dark and tinted appearances; never launches an app.
set -euo pipefail
ROOT="${0:A:h}"
DESTINATION="${1:?Pass the app Resources directory}"
WORK="$(mktemp -d /private/tmp/vp-icon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DESTINATION"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" /usr/bin/xcrun actool \
  "$ROOT/VideoPrompter.icon" --compile "$WORK" --app-icon VideoPrompter \
  --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$WORK/partial.plist" \
  --output-format human-readable-text
test -s "$WORK/Assets.car"
test -s "$WORK/VideoPrompter.icns"
cp "$WORK/Assets.car" "$DESTINATION/"
# Legacy icon sizes have their own optical master; the modern appearance catalogue stays native.
cp "$ROOT/VideoPrompter.icns" "$DESTINATION/"
