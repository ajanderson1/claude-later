#!/bin/bash
# claude-later/tests/test-utils.sh — plain-shell test assertions.
# Source from each test file. Bash 3.2 compatible.

CL_TEST_PASS=0
CL_TEST_FAIL=0
CL_TEST_NAME=${CL_TEST_NAME:-test}

assert_eq() {
  local actual=$1
  local expected=$2
  local label=${3:-}
  if [ "$actual" = "$expected" ]; then
    CL_TEST_PASS=$((CL_TEST_PASS + 1))
    printf '  PASS: %s\n' "$label"
  else
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
  fi
}

assert_zero() {
  local actual=$1
  local label=${2:-}
  if [ "$actual" -eq 0 ]; then
    CL_TEST_PASS=$((CL_TEST_PASS + 1))
    printf '  PASS: %s\n' "$label"
  else
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s (exit=%s)\n' "$label" "$actual"
  fi
}

assert_nonzero() {
  local actual=$1
  local label=${2:-}
  if [ "$actual" -ne 0 ]; then
    CL_TEST_PASS=$((CL_TEST_PASS + 1))
    printf '  PASS: %s\n' "$label"
  else
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s (expected nonzero, got 0)\n' "$label"
  fi
}

assert_match() {
  local actual=$1
  local pattern=$2
  local label=${3:-}
  if printf '%s' "$actual" | grep -qE "$pattern"; then
    CL_TEST_PASS=$((CL_TEST_PASS + 1))
    printf '  PASS: %s\n' "$label"
  else
    CL_TEST_FAIL=$((CL_TEST_FAIL + 1))
    printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' "$label" "$pattern" "$actual"
  fi
}

test_summary() {
  printf '\n=== %s: %d passed, %d failed ===\n' "$CL_TEST_NAME" "$CL_TEST_PASS" "$CL_TEST_FAIL"
  if [ "$CL_TEST_FAIL" -gt 0 ]; then return 1; fi
  return 0
}

# setup_fake_project_dir
# Creates ~/.claude/projects/-<slug>/ for the current PWD if it doesn't exist.
# This lets pre-flight #12 (first-run hygiene) pass in test environments where
# claude has never actually run in the test cwd — e.g. a fresh clone of the
# repo. Sets CL_FAKE_PROJ_CREATED=1 if we created it, so cleanup_fake_project_dir
# can remove only what we created.
setup_fake_project_dir() {
  local cwd_slug
  cwd_slug=$(printf '%s' "$PWD" | sed -e 's|/|-|g' -e 's|_|-|g')
  CL_FAKE_PROJ_DIR="$HOME/.claude/projects/-${cwd_slug#-}"
  CL_FAKE_PROJ_CREATED=0
  if [ ! -d "$CL_FAKE_PROJ_DIR" ]; then
    mkdir -p "$CL_FAKE_PROJ_DIR"
    CL_FAKE_PROJ_CREATED=1
  fi
}

cleanup_fake_project_dir() {
  if [ "${CL_FAKE_PROJ_CREATED:-0}" = "1" ] && [ -d "${CL_FAKE_PROJ_DIR:-}" ]; then
    rmdir "$CL_FAKE_PROJ_DIR" 2>/dev/null || true
  fi
}

# cleanup_test_state_files
# Remove any claude-later state files for the current iTerm2 session that
# were left behind by dry-runs during this test file.
cleanup_test_state_files() {
  local uuid="${ITERM_SESSION_ID#*:}"
  [ -n "$uuid" ] || return 0
  rm -f "$HOME/.claude-later/state/"*"$uuid"* 2>/dev/null || true
}
