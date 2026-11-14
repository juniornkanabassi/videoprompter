#!/bin/zsh
# The iPad presenter drawn to PNG with nothing on screen: boots a throwaway iPad headless (no Simulator
# window), runs PresenterSnapshotTests in it, which draws setup, reading and clean screen at iPad 11-inch,
# 13-inch and a narrow Stage Manager width, then deletes the device. Pictures land in $OUT.
set -euo pipefail
ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
# xcodebuild wants the platform SDK, not the Mac one env.sh sets for SwiftPM.
unset SDKROOT DYLD_FRAMEWORK_PATH DYLD_LIBRARY_PATH
OUT="${OUT:-${TMPDIR:-/tmp}/ipad-presenter-shots}"
mkdir -p "$OUT"
VP_LINK_FIXTURE_DIR="$OUT" swift test --package-path "$ROOT" --filter CameraLinkPipelineTests/testLinkedPictureOrientationFixture
RUNTIME=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c 'import json,sys; print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]][-1])')
DEVICE=$(xcrun simctl create "Video Prompter shots" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB "$RUNTIME")
cleanup() {
  xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
  xcrun simctl delete "$DEVICE" 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
TEST_RUNNER_VP_SHOTS_DIR="$OUT" xcodebuild test -project "$ROOT/iPad/VideoPrompter.xcodeproj" -scheme VideoPrompterShots \
  -destination "id=$DEVICE" -derivedDataPath "${DERIVED_DATA:-$OUT/dd}" CODE_SIGNING_ALLOWED=NO -only-testing:VideoPrompterTests/PresenterSnapshotTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180
ls "$OUT"/*.png
