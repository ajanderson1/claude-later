#!/bin/bash
# tests/test_sigpipe_regression.sh
#
# Regression test for the SIGPIPE-vs-pipefail bug found 2026-04-08.
#
# THE BUG
# Both claude-later and claude-later-helper run with `set -uo pipefail`.
# Several osa.sh helpers used to be implemented as:
#
#   osa_contents_has_prompt() {
#     osa_get_contents "$1" | grep -q '❯'
#   }
#
# When the upstream (osa_get_contents) produces enough data to overflow the
# pipe buffer (~64KB on macOS), and grep finds the match early and exits,
# the upstream's next write hits a closed pipe → SIGPIPE → rc=141. With
# pipefail active, the pipeline rc becomes 141 (the highest non-zero rc
# among pipeline members), and the function returns "false" — even though
# the glyph is present.
#
# This was masked by the fact that during early testing, the pane scrollback
# was small enough that osa_get_contents finished its single write before
# grep ever exited. Production-sized panes triggered the bug intermittently.
#
# THE FIX
# Capture osa_get_contents output into a variable, then test with bash
# case-glob (no pipe involved). See lib/osa.sh.
#
# THIS TEST
# Reproduces the bug condition by feeding a known-large payload through the
# old pipe-and-grep pattern, asserts it fails under pipefail, and asserts
# the new pattern succeeds under the same conditions.

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)

PASS=0
FAIL=0

#
# Phase 1: Demonstrate the bug condition exists.
# Generate ~1MB of text containing a target glyph, pipe through grep -q.
# Under pipefail this MUST fail with rc=141 — that's the bug we're guarding
# against. If it doesn't fail, either the OS pipe buffer is huge (unlikely)
# or pipefail isn't working (in which case the rest of the test is invalid).
#
printf '=== SIGPIPE bug condition exists ===\n'

bug_repro() {
  set -uo pipefail
  local big
  big=$(printf 'filler line %d\n' {1..50000})
  big="$big
TARGET-GLYPH
$(printf 'more filler line %d\n' {1..50000})"
  printf '%s' "$big" | grep -q 'TARGET-GLYPH'
}
bug_repro && bug_rc=0 || bug_rc=$?

if [ "$bug_rc" -eq 141 ]; then
  printf '  PASS: bug condition reproduces (rc=141 SIGPIPE under pipefail)\n'
  PASS=$((PASS + 1))
elif [ "$bug_rc" -eq 0 ]; then
  printf '  SKIP: cannot reproduce SIGPIPE bug condition on this system\n'
  printf '        (pipe buffer may be larger than the test payload)\n'
else
  printf '  WARN: unexpected exit code %d from bug repro (expected 0 or 141)\n' "$bug_rc"
fi

#
# Phase 2: The fix — case-glob against a captured variable — must work.
#
printf '\n=== fix: case-glob against captured variable works under pipefail ===\n'

fix_pattern() {
  set -uo pipefail
  local big
  big=$(printf 'filler line %d\n' {1..50000})
  big="$big
TARGET-GLYPH
$(printf 'more filler line %d\n' {1..50000})"
  case "$big" in
    *TARGET-GLYPH*) return 0 ;;
    *) return 1 ;;
  esac
}
fix_pattern && fix_rc=0 || fix_rc=$?

if [ "$fix_rc" -eq 0 ]; then
  printf '  PASS: case-glob pattern returns 0 for present glyph\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: case-glob pattern returned rc=%d (expected 0)\n' "$fix_rc"
  FAIL=$((FAIL + 1))
fi

#
# Phase 3: The actual osa.sh functions must work under pipefail against a
# pane large enough to have triggered the bug. We test against the current
# live iTerm2 pane.
#
printf '\n=== osa.sh functions correct under pipefail with live pane ===\n'

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf '  SKIP: live-pane tests require iTerm2 (TERM_PROGRAM=%s)\n' "${TERM_PROGRAM:-unset}"
else
  # shellcheck disable=SC1091
  . "$REPO_ROOT/lib/osa.sh"
  UUID="${ITERM_SESSION_ID#*:}"

  # We can't assert WHAT the result is (depends on whether the pane is busy
  # or idle), but we CAN assert the function returns either 0 or 1 — never
  # 141. Any 141 means the SIGPIPE bug is back.
  for fn in osa_contents_has_prompt osa_contents_has_spinner osa_contents_is_idle; do
    "$fn" "$UUID" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
      printf '  PASS: %s returns clean 0/1 (got %d) under pipefail\n' "$fn" "$rc"
      PASS=$((PASS + 1))
    else
      printf '  FAIL: %s returned rc=%d under pipefail (SIGPIPE regression?)\n' "$fn" "$rc"
      FAIL=$((FAIL + 1))
    fi
  done
fi

printf '\n=== test_sigpipe_regression: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
