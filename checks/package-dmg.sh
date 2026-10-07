#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h}

if (( $# != 2 )); then
  print -u2 "Usage: $0 /path/to/Video Prompter.app /path/to/output-directory"
  exit 2
fi

APP=${1:A}
OUTPUT_DIR=${2:A}
[[ -d "$APP" && "$APP" == *.app ]] || { print -u2 "Expected an existing .app bundle: $APP"; exit 1; }
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { print -u2 "Missing $PLIST"; exit 1; }
NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")
IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")
[[ "$NAME" == "Video Prompter" && "$IDENTIFIER" == "com.juniornkanabassi.VidPrompt" && -x "$APP/Contents/MacOS/$EXECUTABLE" ]] || { print -u2 "Bundle name, identifier or executable is invalid"; exit 1; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Invalid three-part app version: $VERSION"; exit 1; }
[[ "$MINIMUM" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { print -u2 "Invalid minimum macOS version: $MINIMUM"; exit 1; }
MIN_MAJOR=${MINIMUM%%.*}
MIN_TAIL=${MINIMUM#*.}
MIN_MINOR=${MIN_TAIL%%.*}
MIN_PATCH=0
[[ "$MIN_TAIL" == *.* ]] && MIN_PATCH=${MIN_TAIL#*.}
(( 10#$MIN_MAJOR < 26 || (10#$MIN_MAJOR == 26 && 10#$MIN_MINOR == 0 && 10#$MIN_PATCH == 0) )) || { print -u2 "This DMG targets macOS 26.0; bundle minimum must be 26.0 or earlier, got $MINIMUM"; exit 1; }

MAIN_ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")
HELPER="$APP/Contents/Helpers/videoprompter"
[[ -x "$HELPER" ]] || { print -u2 "Missing bundled CLI helper: $HELPER"; exit 1; }
HELPER_ARCHS=$(/usr/bin/lipo -archs "$HELPER")
[[ " $MAIN_ARCHS " == *" arm64 "* && " $HELPER_ARCHS " == *" arm64 "* ]] || { print -u2 "DMG requires arm64 support in both the app and CLI helper (app: $MAIN_ARCHS; CLI: $HELPER_ARCHS)"; exit 1; }
/usr/bin/codesign --verify --strict "$HELPER"
/usr/bin/codesign --verify --strict "$APP"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=${OUTPUT_DIR:A}
DMG="$OUTPUT_DIR/$NAME $VERSION.dmg"
[[ ! -e "$DMG" ]] || { print -u2 "Refusing to overwrite $DMG"; exit 1; }
WORK=$(/usr/bin/mktemp -d /private/tmp/videoprompter-dmg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$NAME"
/bin/mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/$NAME.app"
/bin/ln -s /Applications "$STAGE/Applications"
GUIDE="$STAGE/Install Video Prompter $VERSION.txt"
/usr/bin/sed "s/@APP_VERSION@/$VERSION/g; s/@MINIMUM_MACOS@/$MINIMUM/g; s/@MAIN_ARCHITECTURES@/$MAIN_ARCHS/g; s/@CLI_ARCHITECTURES@/$HELPER_ARCHS/g" "$ROOT/../Resources/Install Video Prompter.md" > "$GUIDE"
WORK_DMG="$WORK/$NAME $VERSION.dmg"
/usr/bin/hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$WORK_DMG"
PUBLISH_TMP="$OUTPUT_DIR/.$NAME $VERSION.dmg.partial.$$"
trap 'rm -rf "$WORK"; rm -f "$PUBLISH_TMP"' EXIT
/usr/bin/ditto "$WORK_DMG" "$PUBLISH_TMP"
/bin/mv -n "$PUBLISH_TMP" "$DMG"
[[ ! -e "$PUBLISH_TMP" && -f "$DMG" ]] || { print -u2 "Could not publish DMG without overwriting an existing file: $DMG"; exit 1; }

print "Created: $DMG"
print "Requires macOS $MINIMUM or later. Main executable architectures: $MAIN_ARCHS. Bundled CLI architectures: $HELPER_ARCHS."
print "This packaging step does not add Developer ID signing or notarisation; the app may be unsigned or locally signed."
