#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
source "$ROOT/env.sh"
BUILD_ROOT="${JUNIORPROMPTER_BUILD_ROOT:-/private/tmp/JuniorPrompter-release-cache}"
OUTPUT_ROOT="${JUNIORPROMPTER_OUTPUT_ROOT:-$ROOT/../Outputs}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
ARCHIVE="$OUTPUT_ROOT/JuniorPrompter $VERSION.zip"
WORK=$(mktemp -d /private/tmp/juniorprompter-package.XXXXXX)
APP="$WORK/JuniorPrompter.app"
TMP_ARCHIVE="$WORK/JuniorPrompter $VERSION.zip"
OUTPUT_TMP="$OUTPUT_ROOT/.JuniorPrompter $VERSION.zip.$$"
cleanup() { rm -rf "$WORK"; rm -f "$OUTPUT_TMP"; }
trap cleanup EXIT
MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache" SWIFT_MODULECACHE_PATH="$BUILD_ROOT/SwiftModuleCache" "$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT"
BIN=$("$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT" --show-bin-path)/JuniorPrompter
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JuniorPrompter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon/JuniorPrompter.icns" ]]; then cp "$ROOT/Resources/AppIcon/JuniorPrompter.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
if [[ -d "$ROOT/Resources/Fonts" ]]; then cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"; fi
/usr/bin/codesign --force --deep --sign "$SIGN_ID" "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ARCHIVE"
mkdir -p "$OUTPUT_ROOT"
/usr/bin/ditto "$TMP_ARCHIVE" "$OUTPUT_TMP"
/bin/mv -f "$OUTPUT_TMP" "$ARCHIVE"
print "Built and verified $APP"
print "Archive: ${ARCHIVE:A}"
