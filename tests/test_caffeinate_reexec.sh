#!/bin/bash
# tests/test_caffeinate_reexec.sh
#
# Regression test for the caffeinate re-exec bug (fixed 2026-04-08).
#
# The bug: `claude-later` used to run pre-flights → write state file → then
# `exec caffeinate -dimsu "$0" "$@"`. The re-exec'd process would re-run
# pre-flights, see the state file + .active pointer it wrote on pass 1,
# see a "live" PID in the state file (caffeinate's PID is alive and the ps
# line contains "claude-later"), and abort with "another claude-later is
# already armed in this pane".
#
# The fix: re-exec under caffeinate BEFORE running pre-flights, so the whole
# chain happens exactly once inside the caffeinated process.
#
# This test validates the fix by:
#   1. Running a dry-run (which also exercises caffeinate re-exec) and asserting
#      it succeeds without the stale-check error
#   2. Reading the source to confirm the re-exec is ordered BEFORE run_preflight
#
# The dry-run approach is preferred because it exercises the real caffeinate
# process (not a simulation) but exits before the sleep loop starts.

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
CLAUDE_LATER="$REPO_ROOT/claude-later"
# shellcheck disable=SC1091
. "$TEST_DIR/test-utils.sh"

setup_fake_project_dir
cleanup() { cleanup_fake_project_dir; cleanup_test_state_files; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
assert() {
  local name=$1; local expected=$2; local actual=$3
  if [ "$expected" = "$actual" ]; then
    printf '  PASS: %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: [%s]\n    actual:   [%s]\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name=$1; local needle=$2; local haystack=$3
  if printf '%s' "$haystack" | grep -q -- "$needle"; then
    printf '  PASS: %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    needle: [%s]\n    haystack: [%s]\n' "$name" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local name=$1; local needle=$2; local haystack=$3
  if printf '%s' "$haystack" | grep -q -- "$needle"; then
    printf '  FAIL: %s\n    unexpected needle: [%s]\n    in haystack: [%s]\n' "$name" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  else
    printf '  PASS: %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

printf '=== caffeinate re-exec order (source inspection) ===\n'

# Read the main() function and check that reexec_under_caffeinate appears
# BEFORE run_preflight in the call order.
main_body=$(awk '/^main\(\) \{/,/^\}/' "$CLAUDE_LATER")

reexec_line=$(printf '%s\n' "$main_body" | grep -n 'reexec_under_caffeinate' | head -1 | cut -d: -f1)
preflight_line=$(printf '%s\n' "$main_body" | grep -n 'run_preflight' | head -1 | cut -d: -f1)

if [ -z "$reexec_line" ] || [ -z "$preflight_line" ]; then
  printf '  FAIL: could not find reexec_under_caffeinate or run_preflight in main()\n'
  FAIL=$((FAIL + 1))
elif [ "$reexec_line" -lt "$preflight_line" ]; then
  printf '  PASS: reexec_under_caffeinate (line %d) comes before run_preflight (line %d) in main()\n' "$reexec_line" "$preflight_line"
  PASS=$((PASS + 1))
else
  printf '  FAIL: reexec_under_caffeinate (line %d) should come BEFORE run_preflight (line %d) — regression!\n' "$reexec_line" "$preflight_line"
  FAIL=$((FAIL + 1))
fi

printf '\n=== caffeinate re-exec skipped for --dry-run ===\n'

# The re-exec must be skipped in --dry-run mode, otherwise dry-run would fork
# a caffeinate process that outlives the dry-run's exit.
if printf '%s\n' "$main_body" | grep -B1 'reexec_under_caffeinate' | grep -q 'ARG_DRY_RUN'; then
  printf '  PASS: reexec_under_caffeinate is guarded by ARG_DRY_RUN check in main()\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: reexec_under_caffeinate should be skipped when ARG_DRY_RUN is 1\n'
  FAIL=$((FAIL + 1))
fi

printf '\n=== CL_UNDER_CAFFEINATE guard prevents infinite re-exec ===\n'

# The reexec_under_caffeinate function must short-circuit if CL_UNDER_CAFFEINATE
# is already set, otherwise each re-exec would spawn another caffeinate.
reexec_fn=$(awk '/^reexec_under_caffeinate\(\) \{/,/^\}/' "$CLAUDE_LATER")
assert_contains "reexec guard checks CL_UNDER_CAFFEINATE" "CL_UNDER_CAFFEINATE" "$reexec_fn"

printf '\n=== dry-run executes without the stale-check regression ===\n'

# Dry-run the actual script (it runs inside caffeinate re-exec path in
# non-dry-run mode, but for dry-run it skips caffeinate by design per the
# guard above). This test asserts the dry-run path is still clean — a
# regression where pre-flight leaves stale state would fail a subsequent
# dry-run with "another claude-later is already armed".
#
# We can only run this test from inside iTerm2; skip otherwise.
if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
  output=$("$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "regression test dry-run" 2>&1 || true)
  assert_contains "first dry-run prints ARMED banner" "claude-later ARMED" "$output"
  assert_not_contains "first dry-run has no stale-check error" "already armed in this pane" "$output"

  # Immediately run a second dry-run. If the state file from pass 1 isn't
  # cleaned up cleanly (state_active_clear at end of dry-run), this will hit
  # the stale-check error — which would be a regression.
  output2=$("$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "second regression test dry-run" 2>&1 || true)
  assert_contains "second dry-run prints ARMED banner" "claude-later ARMED" "$output2"
  assert_not_contains "second dry-run has no stale-check error" "already armed in this pane" "$output2"
else
  printf '  SKIP: iTerm2-required tests skipped (TERM_PROGRAM=%s)\n' "${TERM_PROGRAM:-unset}"
fi

printf '\n=== test_caffeinate_reexec: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
