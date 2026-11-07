#!/bin/zsh
# Capture every page offscreen, using only a disposable library and preferences suite.
set -euo pipefail
ROOT="${0:A:h:h}"
if [[ -z "${VIDEOPROMPTER_SNAPSHOTS:-}" ]]; then
  temporary_snapshots="$(mktemp -d "${TMPDIR:-/tmp}/VideoPrompter-snapshots.XXXXXX")"
  export VIDEOPROMPTER_SNAPSHOTS="$temporary_snapshots"
  # test.sh passes the bundle and only wants the pass/fail; a direct run keeps the images to look at.
  if (( $# )); then trap 'rm -rf -- "$temporary_snapshots"' EXIT; fi
fi
print "Snapshot output: $VIDEOPROMPTER_SNAPSHOTS"
source "$ROOT/env.sh"
if (( $# )); then
  BUNDLE="$1"
else
  "$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH"
  BUNDLE="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
  python3 "$ROOT/checks/check-grid.py"
fi
for appearance in light dark; do
  VIDEOPROMPTER_SNAPSHOT_APPEARANCE="$appearance" zsh "$ROOT/checks/run-xctest.sh" "$XCTEST" -XCTest PrompterCoreTests.AppearanceSnapshotTests "$BUNDLE"
done
