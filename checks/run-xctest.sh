#!/bin/zsh
# Run one XCTest process, then remove exactly the defaults suites it recorded.
# Usage: zsh checks/run-xctest.sh "$XCTEST" [xctest arguments...] BUNDLE
# Tests record every suite they open in $VIDEOPROMPTER_TEST_DEFAULTS_MANIFEST. In-process cleanup
# cannot stop cfprefsd rewriting an empty plist after the process exits, so the final removal
# runs here, after the child has exited. The child's exit status is kept; if the tests passed
# but cleanup failed, this fails instead.
set -uo pipefail
unsetopt BG_NICE  # Waiting on a child must not lower XCTest's scheduling priority.
(( $# >= 1 )) || { print -u2 "usage: run-xctest.sh EXECUTABLE [ARGS...]"; exit 64; }
HERE="${0:A:h}"
MANIFEST_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/VideoPrompter-test-defaults.XXXXXX")" || exit 70
chmod 700 "$MANIFEST_DIR"
export VIDEOPROMPTER_TEST_DEFAULTS_MANIFEST="$MANIFEST_DIR/suites.txt"
: > "$VIDEOPROMPTER_TEST_DEFAULTS_MANIFEST"

child=0
interrupted=0
forward() {
  interrupted=$1
  # Stop the test process first and wait for it, so nothing deletes suites it is still writing.
  (( child > 0 )) && kill -"$1" "$child" 2>/dev/null
}
trap 'forward INT' INT
trap 'forward TERM' TERM

"$@" &
child=$!
test_status=0
# `wait` returns early when a trapped signal arrives; keep waiting until the child has really gone.
while true; do
  wait "$child"
  test_status=$?
  kill -0 "$child" 2>/dev/null || break
done
trap - INT TERM

python3 "$HERE/clean-test-defaults.py" "$VIDEOPROMPTER_TEST_DEFAULTS_MANIFEST"
cleanup_status=$?
rm -rf -- "$MANIFEST_DIR"

if [[ "$interrupted" != 0 ]]; then
  (( test_status != 0 )) && exit "$test_status"
  exit 130
fi
(( test_status != 0 )) && exit "$test_status"
(( cleanup_status != 0 )) && { print -u2 "Test defaults cleanup failed"; exit "$cleanup_status"; }
exit 0
