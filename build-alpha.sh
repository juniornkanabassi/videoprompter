#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
WORK=$(mktemp -d /private/tmp/juniorprompter-alpha.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
OUTPUT_ROOT="${JUNIORPROMPTER_OUTPUT_ROOT:-$ROOT/../Outputs}"
ARCHIVE="$OUTPUT_ROOT/JuniorPrompter Alpha $VERSION.zip"
[[ ! -e "$ARCHIVE" ]] || { print -u2 "Archive already exists: $ARCHIVE"; exit 1; }
JUNIORPROMPTER_OUTPUT_ROOT="$WORK" zsh "$ROOT/build.sh"
ditto -x -k "$WORK/JuniorPrompter $VERSION.zip" "$WORK/unpacked"
APP="$WORK/unpacked/JuniorPrompter Alpha.app"
mv "$WORK/unpacked/JuniorPrompter.app" "$APP"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.juniornkanabassi.JuniorPrompter.alpha' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleName JuniorPrompter Alpha' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleDisplayName JuniorPrompter Alpha' "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/alpha.zip"
mkdir -p "$OUTPUT_ROOT"
mv "$WORK/alpha.zip" "$ARCHIVE"
print "Alpha archive: $ARCHIVE"
