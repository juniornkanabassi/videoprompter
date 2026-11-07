#!/bin/zsh
# Build and run the whole XCTest suite. `swift test` does not discover the
# XCTest cases with this toolchain, so run the built bundle with xctest.
set -euo pipefail
ROOT="${0:A:h}"
source "$ROOT/env.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/checks/test_capture_safety.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/checks/test_check_grid.py"
python3 "$ROOT/checks/check-grid.py"
"$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" >&2
BUNDLE="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
# The wrapper removes the defaults suites the tests recorded once xctest has exited.
env -u VIDEOPROMPTER_SNAPSHOTS -u VIDEOPROMPTER_SNAPSHOT_APPEARANCE \
  zsh "$ROOT/checks/run-xctest.sh" "$XCTEST" "$@" "$BUNDLE"
# Each appearance gets its own XCTest process, with offscreen windows and disposable data.
zsh "$ROOT/checks/check-snapshots.sh"
