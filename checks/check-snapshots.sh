#!/bin/zsh
# Capture every page offscreen, using only a disposable library and preferences suite.
set -euo pipefail
ROOT="${0:A:h:h}"
export VIDEOPROMPTER_SNAPSHOTS="${VIDEOPROMPTER_SNAPSHOTS:-$(mktemp -d "${TMPDIR:-/tmp}/VideoPrompter-snapshots.XXXXXX")}"
print "Snapshot output: $VIDEOPROMPTER_SNAPSHOTS"
source "$ROOT/env.sh"
"$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH"
BUNDLE="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
for appearance in light dark; do
  VIDEOPROMPTER_SNAPSHOT_APPEARANCE="$appearance" zsh "$ROOT/checks/run-xctest.sh" "$XCTEST" -XCTest PrompterCoreTests.AppearanceSnapshotTests "$BUNDLE"
done
python3 "$ROOT/checks/check-grid.py"
