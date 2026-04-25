#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_countdown"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/countdown.sh"

assert_eq "$(cl_format_countdown 0)" "⏳ claude-later • fires in 0s • ^C to cancel • ^D to re-banner" "zero"
assert_eq "$(cl_format_countdown 59)" "⏳ claude-later • fires in 59s • ^C to cancel • ^D to re-banner" "<1m"
assert_eq "$(cl_format_countdown 60)" "⏳ claude-later • fires in 1m 0s • ^C to cancel • ^D to re-banner" "exact 1m"
assert_eq "$(cl_format_countdown 3599)" "⏳ claude-later • fires in 59m 59s • ^C to cancel • ^D to re-banner" "<1h"
assert_eq "$(cl_format_countdown 3600)" "⏳ claude-later • fires in 1h 0m 0s • ^C to cancel • ^D to re-banner" "exact 1h"
assert_eq "$(cl_format_countdown 13632)" "⏳ claude-later • fires in 3h 47m 12s • ^C to cancel • ^D to re-banner" "sample 3h47m12s"

test_summary
