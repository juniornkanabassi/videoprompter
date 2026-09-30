#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h}"
OUTPUT_ROOT="${JUNIORPROMPTER_OUTPUT_ROOT:-$SOURCE_ROOT/../Outputs}"
INSTALL_ROOT="${JUNIORPROMPTER_INSTALL_ROOT:-/Applications/JuniorOS Apps}"
DEST="$INSTALL_ROOT/JuniorPrompter.app"
BIN_DIR="${JUNIORPROMPTER_BIN_DIR:-$HOME/.local/bin}"
CLI_LINK="$BIN_DIR/juniorprompter"
[[ ! -e "$CLI_LINK" || -L "$CLI_LINK" ]] || { print -u2 "Refusing to replace real file $CLI_LINK"; exit 1; }
EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE_ROOT/Resources/Info.plist")
EXPECTED_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_ROOT/Resources/Info.plist")
ARCHIVE="${1:-$OUTPUT_ROOT/JuniorPrompter $EXPECTED_VERSION.zip}"
if (( $# > 1 )); then print -u2 'Usage: zsh install.sh [JuniorPrompter <version>.zip]'; exit 2; fi
[[ -f "$ARCHIVE" ]] || { print -u2 "No JuniorPrompter archive found: $ARCHIVE"; exit 1; }
[[ ! -L "$INSTALL_ROOT" ]] || { print -u2 "Refusing symlink install root $INSTALL_ROOT."; exit 1; }
[[ ! -L "$DEST" ]] || { print -u2 "Refusing to replace symlink $DEST."; exit 1; }
if pgrep -x JuniorPrompter >/dev/null 2>&1; then print -u2 'JuniorPrompter is running. Quit it before installing; this installer will not kill it.'; exit 1; fi
mkdir -p "$INSTALL_ROOT"
WORK=$(mktemp -d "$INSTALL_ROOT/.juniorprompter-install.XXXXXX")
STAGE="$WORK/JuniorPrompter.app"
BACKUP="$INSTALL_ROOT/.JuniorPrompter.app.previous.$$"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
/usr/bin/ditto -x -k --sequesterRsrc "$ARCHIVE" "$WORK"
[[ ! -L "$STAGE" && -d "$STAGE" ]] || { print -u2 'Archive does not contain a real JuniorPrompter.app bundle at its root.'; exit 1; }
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$STAGE/Contents/Info.plist")
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAGE/Contents/Info.plist")
ACTUAL_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$STAGE/Contents/Info.plist")
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { print -u2 "Bundle identifier mismatch: $ACTUAL_ID"; exit 1; }
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || { print -u2 "Archive version $ACTUAL_VERSION does not match source version $EXPECTED_VERSION."; exit 1; }
[[ -n "$ACTUAL_EXECUTABLE" && -f "$STAGE/Contents/MacOS/$ACTUAL_EXECUTABLE" && ! -L "$STAGE/Contents/MacOS/$ACTUAL_EXECUTABLE" ]] || { print -u2 'Archive bundle executable is missing or is a symlink.'; exit 1; }
/usr/bin/codesign --verify --strict "$STAGE"
if pgrep -x JuniorPrompter >/dev/null 2>&1; then print -u2 'JuniorPrompter started during verification. Install aborted; this installer will not kill it.'; exit 1; fi
if [[ -e "$DEST" ]]; then /bin/mv "$DEST" "$BACKUP"; fi
if ! /bin/mv "$STAGE" "$DEST"; then
  [[ ! -e "$BACKUP" ]] || /bin/mv "$BACKUP" "$DEST"
  print -u2 'Install failed; the previous app was restored.'
  exit 1
fi
if ! /usr/bin/codesign --verify --strict "$DEST"; then
  /bin/rm -rf "$DEST"
  [[ ! -e "$BACKUP" ]] || /bin/mv "$BACKUP" "$DEST"
  print -u2 'Installed signature verification failed; the previous app was restored.'
  exit 1
fi
[[ ! -e "$BACKUP" ]] || /bin/rm -rf "$BACKUP"
print "Installed JuniorPrompter $ACTUAL_VERSION at $DEST"

mkdir -p "$BIN_DIR"
[[ ! -e "$CLI_LINK" || -L "$CLI_LINK" ]] || { print -u2 "Refusing to replace real file $CLI_LINK"; exit 1; }
ln -sfn "$DEST/Contents/Helpers/juniorprompter" "$CLI_LINK"
NODE_PATH=$(command -v node || true)
[[ -n "$NODE_PATH" ]] || NODE_PATH="node"
print "claude mcp add juniorprompter -- \"$NODE_PATH\" \"$DEST/Contents/Resources/mcp/juniorprompter-mcp.mjs\""
# JSON strings are also valid TOML basic strings, including paths with quotes.
python3 - "$NODE_PATH" "$DEST/Contents/Resources/mcp/juniorprompter-mcp.mjs" <<'PYCONFIG'
import json, sys
print("# ~/.codex/config.toml\n[mcp_servers.juniorprompter]")
print("command = " + json.dumps(sys.argv[1]))
print("args = [" + json.dumps(sys.argv[2]) + "]")
PYCONFIG
