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
KEEP_WORK=0
cleanup() { (( KEEP_WORK )) || rm -rf "$WORK"; rm -f "$OUTPUT_TMP"; }
trap cleanup EXIT
MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache" SWIFT_MODULECACHE_PATH="$BUILD_ROOT/SwiftModuleCache" "$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT"
BIN=$("$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT" --show-bin-path)/VideoPrompter
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mcp" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/VideoPrompter"
cp "${BIN:h}/VideoPrompterCLI" "$APP/Contents/Helpers/videoprompter"
cp "$ROOT/mcp/videoprompter-mcp.mjs" "$APP/Contents/Resources/mcp/"
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_ID")
(( DEVELOPER_ID_AVAILABLE )) && SIGN_FLAGS+=(--timestamp)
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/videoprompter"
/usr/bin/codesign --verify --strict "$APP/Contents/Helpers/videoprompter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon/VideoPrompter.icns" ]]; then cp "$ROOT/Resources/AppIcon/VideoPrompter.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
if [[ -d "$ROOT/Resources/Fonts" ]]; then cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"; fi
/usr/bin/codesign "${SIGN_FLAGS[@]}" --deep --entitlements "$ROOT/Resources/Entitlements.plist" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
# Developer ID builds are notarised and stapled before they are archived, so the archive and every
# DMG made from it open on another Mac without a Gatekeeper warning. The ticket is stapled to the
# app; package-dmg.sh notarises and staples the disk image as well.
if (( DEVELOPER_ID_AVAILABLE )); then
  NOTARY_ZIP="$WORK/notary-upload.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
  print "Submitting to Apple notary service (profile $NOTARY_PROFILE)…"
  NOTARY_LOG="$WORK/notary.log"
  KEEP_WORK=1
  if ! xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$NOTARY_LOG"; then
    print -u2 "Notarisation did not finish. App, upload and submission log retained at $WORK."
    print -u2 "Query the submission ID in $NOTARY_LOG with: xcrun notarytool info <id> --keychain-profile ${(q)NOTARY_PROFILE}"
    print -u2 "After Accepted: xcrun stapler staple ${(q)APP} && xcrun stapler validate ${(q)APP} && /usr/bin/spctl -a -vv -t exec ${(q)APP} && /usr/bin/ditto -c -k --sequesterRsrc --keepParent ${(q)APP} ${(q)ARCHIVE}"
    exit 1
  fi
  if ! grep -q "status: Accepted" "$NOTARY_LOG"; then
    SUBMISSION_ID=$(awk '/^  id: /{print $2; exit}' "$NOTARY_LOG")
    [[ -z "$SUBMISSION_ID" ]] || xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
    print -u2 "Notarisation was not accepted; see the log above."
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  /usr/bin/spctl -a -vv -t exec "$APP"
  print "Developer ID signed, notarised and stapled."
else
  print "Local signing identity ($SIGN_ID); not notarised. Unset VIDEOPROMPTER_LOCAL_SIGNING for a release build."
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ARCHIVE"
mkdir -p "$OUTPUT_ROOT"
/usr/bin/ditto "$TMP_ARCHIVE" "$OUTPUT_TMP"
/bin/mv -f "$OUTPUT_TMP" "$ARCHIVE"
KEEP_WORK=0
print "Built and verified $APP"
print "Archive: ${ARCHIVE:A}"
