#!/bin/zsh
# Build and run the whole XCTest suite. `swift test` does not discover the
# XCTest cases with this toolchain, so run the built bundle with xctest.
set -euo pipefail
ROOT="${0:A:h}"
source "$ROOT/env.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/checks/test_capture_safety.py"
"$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" >&2
BUNDLE="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$VIDEOPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
# The wrapper removes the defaults suites the tests recorded once xctest has exited.
exec zsh "$ROOT/checks/run-xctest.sh" "$XCTEST" "$@" "$BUNDLE"
