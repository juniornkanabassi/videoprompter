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
# The commit this builds, taken before compiling ("-dirty" with uncommitted or untracked changes); release.sh
# publishes only a clean HEAD's build.
COMMIT=$("$GIT" -C "$ROOT" rev-parse HEAD)
STATUS=$("$GIT" -C "$ROOT" status --porcelain --untracked-files=all) || { print -u2 "git status failed"; exit 1; }
[[ -z $STATUS ]] || COMMIT+="-dirty"
MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache" SWIFT_MODULECACHE_PATH="$BUILD_ROOT/SwiftModuleCache" "$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT"
BIN=$("$SWIFT" build --package-path "$ROOT" --configuration release --scratch-path "$BUILD_ROOT" --show-bin-path)/VideoPrompter
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mcp" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/VideoPrompter"
cp "${BIN:h}/VideoPrompterCLI" "$APP/Contents/Helpers/videoprompter"
cp "$ROOT/mcp/videoprompter-mcp.mjs" "$APP/Contents/Resources/mcp/"
# Sparkle, found through the app's rpath @executable_path/../Frameworks; ditto keeps its symlinks.
[[ -d "${BIN:h}/Sparkle.framework" ]] || { print -u2 "No Sparkle.framework in ${BIN:h}"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "${BIN:h}/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_ID")
(( DEVELOPER_ID_AVAILABLE )) && SIGN_FLAGS+=(--timestamp)
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/videoprompter"
/usr/bin/codesign --verify --strict "$APP/Contents/Helpers/videoprompter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
# Everything taken from the source tree is copied before the commit is stamped below.
if [[ -f "$ROOT/Resources/AppIcon/VideoPrompter.icns" ]]; then cp "$ROOT/Resources/AppIcon/VideoPrompter.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
if [[ -d "$ROOT/Resources/Fonts" ]]; then cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"; fi
ENTITLEMENTS="$WORK/Entitlements.plist"   # signed from this copy, so a later edit to the source cannot reach the app
cp "$ROOT/Resources/Entitlements.plist" "$ENTITLEMENTS"
# A checkout that moved or changed while compiling marks the build dirty.
STATUS=$("$GIT" -C "$ROOT" status --porcelain --untracked-files=all) || { print -u2 "git status failed"; exit 1; }
[[ $("$GIT" -C "$ROOT" rev-parse HEAD) == ${COMMIT%-dirty} && -z $STATUS ]] || COMMIT="${COMMIT%-dirty}-dirty"
/usr/libexec/PlistBuddy -c "Add :VPSourceCommit string $COMMIT" "$APP/Contents/Info.plist"
# Updates only in a Developer ID build with a real public key. Any other build has no feed, so the app starts no
# updater and shows no Check for Updates item (Updates.swift), and can never replace itself with a release.
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)
if (( ! DEVELOPER_ID_AVAILABLE )) || [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == REPLACE_WITH_* ]]; then
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" -c "Delete :SUPublicEDKey" "$APP/Contents/Info.plist"
  print "Updates off in this build (no Developer ID identity, or SUPublicEDKey is not set)"
fi
# Sparkle's nested code inside-out, as its documentation gives for apps outside the App Store, then the framework.
# The XPC services keep their own entitlements. No --deep on the app: it would re-sign all of this and the helper.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc(N); do
  /usr/bin/codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
done
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
# Hardened runtime only loads Sparkle when it shares the app's Team ID. A local identity (ReadAlong Dev or ad hoc) has
# none, so only those builds turn library validation off; Developer ID builds keep it.
if (( ! DEVELOPER_ID_AVAILABLE )); then
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
/usr/bin/codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
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
    print -r -u2 "Query the submission ID in $NOTARY_LOG with: xcrun notarytool info <id> --keychain-profile ${(q)NOTARY_PROFILE}"
    print -r -u2 "After Accepted: xcrun stapler staple ${(q)APP} && xcrun stapler validate ${(q)APP} && /usr/sbin/spctl -a -vv -t exec ${(q)APP} && /bin/mkdir -p ${(q)OUTPUT_ROOT} && /usr/bin/ditto -c -k --sequesterRsrc --keepParent ${(q)APP} ${(q)ARCHIVE}"
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
  /usr/sbin/spctl -a -vv -t exec "$APP"
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
