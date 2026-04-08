#!/bin/bash
# tests/test_preflight_dry_run.sh — error-path tests for the in-pane script.
# These exercise pre-flight failure modes via --dry-run.
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$CL_DIR/tests/test-utils.sh"
CL_TEST_NAME="test_preflight_dry_run"

CLAUDE_LATER="$CL_DIR/claude-later"

# Helper: run claude-later and capture exit code + stderr.
run_cl() {
  local stderr
  stderr=$("$CLAUDE_LATER" "$@" 2>&1 >/dev/null)
  local rc=$?
  printf '%s\n%s\n' "$rc" "$stderr"
}

assert_fails_with() {
  local label=$1
  local expected_pattern=$2
  shift 2
  local out rc
  # Capture stderr (combined with stdout) AND exit code without losing either.
  out=$("$CLAUDE_LATER" "$@" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s\n    expected non-zero exit, got 0\n    output: %s\n' "$label" "$out"
    return
  fi
  if printf '%s' "$out" | grep -qE "$expected_pattern"; then
    CL_TEST_PASS=$((CL_TEST_PASS + 1))
    printf '  PASS: %s\n' "$label"
  else
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s\n    expected pattern: %s\n    actual: %s\n' "$label" "$expected_pattern" "$out"
  fi
}

assert_succeeds() {
  local label=$1
  shift
  if "$CLAUDE_LATER" "$@" >/dev/null 2>&1; then
    CL_TEST_PASS=$((CL_TEST_PASS + 1))
    printf '  PASS: %s\n' "$label"
  else
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s (exit=%s)\n' "$label" "$?"
  fi
}

echo "=== --help and --version ==="
assert_succeeds "--help" --help
assert_succeeds "--version" --version

echo
echo "=== flag validation ==="
assert_fails_with "no flags, no message" "must specify either --at or --in" --dry-run
assert_fails_with "both --at and --in" "exactly one of --at or --in" --dry-run --at "23:59" --in 5m "msg"
assert_fails_with "no message" "message is required" --dry-run --in 5m
assert_fails_with "unknown flag" "unknown flag" --dry-run --bogus --in 5m "msg"

echo
echo "=== --in parsing ==="
assert_fails_with "--in garbage" "invalid --in" --dry-run --in garbage "msg"
assert_fails_with "--in 0s" "invalid --in" --dry-run --in 0s "msg"

echo
echo "=== --at parsing ==="
assert_fails_with "--at past" "invalid --at" --dry-run --at "2020-01-01 03:00:00" "msg"
assert_fails_with "--at unparseable" "invalid --at" --dry-run --at "yesterday at 3" "msg"

echo
echo "=== --resume validation ==="
assert_fails_with "--resume shell injection" "invalid --resume" --dry-run --in 5s --resume "; rm -rf ~" "msg"
assert_fails_with "--resume not UUID" "invalid --resume" --dry-run --in 5s --resume "garbage" "msg"
assert_fails_with "--resume too short" "invalid --resume" --dry-run --in 5s --resume "12345678-1234-1234-1234-12345678" "msg"

echo
echo "=== message validation ==="
# Empty message would be parsed as no message — already covered above.
# Multi-line message via $'...\n...' (bash 3.2 supports this construct)
assert_fails_with "multi-line message" "single line" --dry-run --in 5s "$(printf 'line1\nline2')"
assert_fails_with "tab character" "non-printable" --dry-run --in 5s "$(printf 'has\tab')"

test_summary
