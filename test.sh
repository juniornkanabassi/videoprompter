#!/bin/zsh
# Build and run the whole XCTest suite. `swift test` does not discover the
# XCTest cases with this toolchain, so run the built bundle with xctest.
set -euo pipefail
ROOT="${0:A:h}"
source "$ROOT/env.sh"
"$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$JUNIORPROMPTER_TEST_SCRATCH" >&2
BUNDLE="$("$SWIFT" build --package-path "$ROOT" --build-tests --scratch-path "$JUNIORPROMPTER_TEST_SCRATCH" --show-bin-path)/PrompterCoreTests.xctest"
exec "$XCTEST" "$@" "$BUNDLE"
