#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
source "$ROOT/env.sh"
BUILD_ROOT="${VIDEOPROMPTER_BUILD_ROOT:-/private/tmp/VideoPrompter-release-cache}"
OUTPUT_ROOT="${VIDEOPROMPTER_OUTPUT_ROOT:-$ROOT/../Outputs}"
mkdir -p "$BUILD_ROOT"
[[ ! -L "$BUILD_ROOT" && -O "$BUILD_ROOT" ]] || { print -u2 "Unsafe build cache $BUILD_ROOT"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
ARCHIVE="$OUTPUT_ROOT/Video Prompter $VERSION.zip"
WORK=$(mktemp -d /private/tmp/videoprompter-package.XXXXXX)
APP="$WORK/Video Prompter.app"
TMP_ARCHIVE="$WORK/Video Prompter $VERSION.zip"
OUTPUT_TMP="$OUTPUT_ROOT/.Video Prompter $VERSION.zip.$$"
cleanup() { rm -rf "$WORK"; rm -f "$OUTPUT_TMP"; }
trap cleanup EXIT
MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache" SWIFT_MODULECACHE_PATH="$BUILD_ROOT/SwiftModuleCache" "$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT"
BIN=$("$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT" --show-bin-path)/VideoPrompter
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mcp" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/VideoPrompter"
cp "${BIN:h}/VideoPrompterCLI" "$APP/Contents/Helpers/videoprompter"
cp "$ROOT/mcp/videoprompter-mcp.mjs" "$APP/Contents/Resources/mcp/"
/usr/bin/codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Helpers/videoprompter"
/usr/bin/codesign --verify --strict "$APP/Contents/Helpers/videoprompter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon/VideoPrompter.icns" ]]; then cp "$ROOT/Resources/AppIcon/VideoPrompter.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
if [[ -d "$ROOT/Resources/Fonts" ]]; then cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"; fi
/usr/bin/codesign --force --deep --options runtime --entitlements "$ROOT/Resources/Entitlements.plist" --sign "$SIGN_ID" "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ARCHIVE"
mkdir -p "$OUTPUT_ROOT"
/usr/bin/ditto "$TMP_ARCHIVE" "$OUTPUT_TMP"
/bin/mv -f "$OUTPUT_TMP" "$ARCHIVE"
print "Built and verified $APP"
print "Archive: ${ARCHIVE:A}"
