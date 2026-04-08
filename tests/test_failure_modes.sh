#!/bin/bash
# tests/test_failure_modes.sh
#
# Chaos-style tests: deliberately break each precondition claude-later relies
# on and assert it aborts with a specific, actionable error message. These
# catch regressions where someone "helpfully" softens a pre-flight check.
#
# No mocks — we manipulate real env vars, PATH, file paths, etc.

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
CLAUDE_LATER="$REPO_ROOT/claude-later"
# shellcheck disable=SC1091
. "$TEST_DIR/test-utils.sh"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: failure-mode tests require iTerm2 (TERM_PROGRAM=%s)\n' "${TERM_PROGRAM:-unset}"
  exit 0
fi

setup_fake_project_dir
cleanup() { cleanup_fake_project_dir; cleanup_test_state_files; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0

# assert_fails_with
# Runs claude-later with the given env prefix and args; asserts the exit code
# is non-zero AND the error output contains the expected substring.
assert_fails_with() {
  local label=$1 needle=$2
  shift 2
  local output rc
  output=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  FAIL: %s (exit 0, expected non-zero)\n' "$label"
    printf '    full output:\n%s\n' "$output" | head -5 | sed 's/^/      /'
    FAIL=$((FAIL + 1))
    return
  fi
  # Use grep -E so alternation (|) works
  if printf '%s' "$output" | grep -qE -- "$needle"; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n' "$label"
    printf '    expected pattern: [%s]\n' "$needle"
    printf '    full output:\n%s\n' "$output" | head -5 | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
}

printf '=== terminal environment rejection ===\n'

# Fake TERM_PROGRAM → rejected
assert_fails_with "non-iTerm TERM_PROGRAM rejected" "must be run from iTerm2" \
  env TERM_PROGRAM=Terminal.app "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "x"

# Simulate being inside tmux
assert_fails_with "TMUX env var rejected" "does not support running inside tmux" \
  env TMUX=/tmp/fake-tmux-socket,1234,0 "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "x"

# Simulate being inside GNU screen
assert_fails_with "STY env var rejected" "does not support running inside GNU screen" \
  env STY=12345.pts-0.host "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "x"

# Missing ITERM_SESSION_ID
assert_fails_with "missing ITERM_SESSION_ID rejected" "ITERM_SESSION_ID" \
  env -u ITERM_SESSION_ID "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "x"

# Malformed ITERM_SESSION_ID
assert_fails_with "malformed ITERM_SESSION_ID rejected" "format unexpected" \
  env ITERM_SESSION_ID=not-a-valid-id "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "x"

printf '\n=== time parsing rejection ===\n'

assert_fails_with "past --at rejected" "invalid --at value" \
  "$CLAUDE_LATER" --dry-run --at "2020-01-01 00:00" --skip-mcp-check "x"

assert_fails_with "unparseable --at rejected" "invalid --at value" \
  "$CLAUDE_LATER" --dry-run --at "banana" --skip-mcp-check "x"

assert_fails_with "unparseable --in rejected" "invalid --in value" \
  "$CLAUDE_LATER" --dry-run --in "xyz" --skip-mcp-check "x"

assert_fails_with "negative --in rejected" "invalid --in value" \
  "$CLAUDE_LATER" --dry-run --in "-5m" --skip-mcp-check "x"

printf '\n=== neither --at nor --in rejected ===\n'

assert_fails_with "no time flag rejected" "must specify either --at or --in" \
  "$CLAUDE_LATER" --dry-run --skip-mcp-check "x"

printf '\n=== both --at and --in rejected ===\n'

assert_fails_with "both time flags rejected" "specify exactly one of --at or --in" \
  "$CLAUDE_LATER" --dry-run --at "23:59" --in "1m" --skip-mcp-check "x"

printf '\n=== resume UUID validation ===\n'

# Shell injection attempt via --resume
assert_fails_with "resume shell injection rejected" "invalid --resume value" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --resume '$(whoami)' "x"

# Path traversal attempt
assert_fails_with "resume path traversal rejected" "invalid --resume value" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --resume '../../etc/passwd' "x"

# Non-UUID string
assert_fails_with "resume non-UUID rejected" "invalid --resume value" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --resume 'not-a-uuid' "x"

printf '\n=== message content validation ===\n'

assert_fails_with "empty message rejected" "message is required" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check ""

assert_fails_with "missing message rejected" "message is required" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check

# Multi-line via command substitution
assert_fails_with "multi-line message rejected" "single line" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "$(printf 'line1\nline2')"

printf '\n=== binary missing rejection ===\n'

# Run with a minimal PATH that contains coreutils but no claude. Most systems
# have claude installed somewhere outside /bin:/usr/bin (homebrew, ~/.claude/
# local/bin, etc.), so this reliably hides it without breaking the script.
# If your system has claude in /bin or /usr/bin this test will be a no-op
# success — skip rather than false-pass.
if env PATH="/bin:/usr/bin" command -v claude >/dev/null 2>&1; then
  printf '  SKIP: claude is in /bin:/usr/bin — cannot test "missing claude" without it\n'
else
  assert_fails_with "missing claude binary rejected" "claude not on PATH" \
    env PATH="/bin:/usr/bin" "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check "x"
fi

printf '\n=== unknown flag rejection ===\n'

assert_fails_with "unknown flag rejected" "unknown flag" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --nonexistent-flag "x"

printf '\n=== test_failure_modes: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
