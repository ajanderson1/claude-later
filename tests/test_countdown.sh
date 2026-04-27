#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_countdown"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/countdown.sh"

assert_eq "$(cl_format_countdown 0)" "⏳ claude-later • fires in 0s • ^C to cancel" "zero"
assert_eq "$(cl_format_countdown 59)" "⏳ claude-later • fires in 59s • ^C to cancel" "<1m"
assert_eq "$(cl_format_countdown 60)" "⏳ claude-later • fires in 1m 0s • ^C to cancel" "exact 1m"
assert_eq "$(cl_format_countdown 3599)" "⏳ claude-later • fires in 59m 59s • ^C to cancel" "<1h"
assert_eq "$(cl_format_countdown 3600)" "⏳ claude-later • fires in 1h 0m 0s • ^C to cancel" "exact 1h"
assert_eq "$(cl_format_countdown 13632)" "⏳ claude-later • fires in 3h 47m 12s • ^C to cancel" "sample 3h47m12s"

# cl_countdown_loop exits cleanly at T-5s on a synthetic target
. "$CL_DIR/lib/time.sh"
CL_TARGET_EPOCH=$(( $(date +%s) + 7 ))
# Run with a NO-OP banner reprint fn and a NO-OP tombstone writer
cl_banner_render() { :; }
cl_countdown_cancel_tombstone() { printf 'fake_tombstone_called\n' > "$1"; }
MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT
CL_STATE_PATH="$MARK-state"
CL_ACTIVE_PTR="$MARK-active"
# Non-interactive run — no signals — should return 0 after ~2s (loop exits at T-5s)
t0=$(date +%s)
cl_countdown_loop 2>/dev/null
t1=$(date +%s)
elapsed=$((t1 - t0))
# Should have taken between 1 and 4 seconds (target+7 → exit at target-5 = now+2)
[ "$elapsed" -ge 1 ] && [ "$elapsed" -le 4 ] && pass=1 || pass=0
assert_eq "$pass" "1" "loop exits near T-5s (elapsed=${elapsed}s)"

test_summary
