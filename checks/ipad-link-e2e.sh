#!/bin/zsh
# The Mac-to-iPad link end to end, with nothing on screen: builds the iPad app for the Simulator,
# boots a throwaway iPad headless (no Simulator window), seeds a script, and runs
# IPadSimulatorEndToEndTests against it. Leaves a screenshot of the iPad showing the Mac's
# picture at $OUT/ipad-link-e2e.png, then deletes the device.
set -euo pipefail
ROOT="${0:A:h:h}"
source "$ROOT/env.sh"
OUT="${OUT:-${TMPDIR:-/tmp}/ipad-link-e2e}"
mkdir -p "$OUT"
BUNDLE=com.juniornkanabassi.VideoPrompter
xcodebuild -project "$ROOT/iPad/VideoPrompter.xcodeproj" -scheme VideoPrompter -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUT/dd" build -quiet
APP="$OUT/dd/Build/Products/Debug-iphonesimulator/VideoPrompter.app"
RUNTIME=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c 'import json,sys; print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]][-1])')
DEVICE=$(xcrun simctl create "Video Prompter link test" com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4 "$RUNTIME")
trap 'kill ${LOG:-0} 2>/dev/null; xcrun simctl shutdown "$DEVICE" 2>/dev/null; xcrun simctl delete "$DEVICE"' EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
SCRIPTS="$(xcrun simctl get_app_container "$DEVICE" $BUNDLE data)/Documents/Scripts"
mkdir -p "$SCRIPTS"
{
  print "# Link test\n"
  for i in {1..12}; do print "Passage $i says the quick brown fox jumps over the lazy dog, and then it runs along the river bank to see the boats.\n"; done
} > "$SCRIPTS/Link test.md"
xcrun simctl spawn "$DEVICE" log stream --level debug --predicate 'process == "VideoPrompter"' > "$OUT/ipad.log" 2>&1 &
LOG=$!
xcrun simctl launch "$DEVICE" $BUNDLE >/dev/null
sleep 4
"$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" >&2
TESTS="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
MARKER="$OUT/streaming"
rm -f "$MARKER"
VP_IPAD_E2E=1 VP_IPAD_E2E_MARKER="$MARKER" "$XCTEST" -XCTest PrompterCoreTests.IPadSimulatorEndToEndTests "$TESTS" &
TEST=$!
for _ in {1..300}; do [[ -e "$MARKER" ]] && break; sleep 0.1; done
sleep 1
[[ -e "$MARKER" ]] && xcrun simctl io "$DEVICE" screenshot "$OUT/ipad-link-e2e.png" >/dev/null
wait $TEST
