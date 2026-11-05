#!/bin/zsh
# Capture every page offscreen, using only a disposable library and preferences suite.
set -euo pipefail
ROOT="${0:A:h:h}"
export VIDEOPROMPTER_TEST_SCRATCH="${VIDEOPROMPTER_TEST_SCRATCH:-/private/tmp/bama/build-prompter/snapshot-build}"
export VIDEOPROMPTER_SNAPSHOTS="${VIDEOPROMPTER_SNAPSHOTS:-/private/tmp/bama/build-prompter/snapshots}"
source "$ROOT/env.sh"
"$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH"
BUNDLE="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
for appearance in light dark; do
  VIDEOPROMPTER_SNAPSHOT_APPEARANCE="$appearance" "$XCTEST" -XCTest PrompterCoreTests.AppearanceSnapshotTests "$BUNDLE"
done
python3 "$ROOT/checks/check-grid.py"
