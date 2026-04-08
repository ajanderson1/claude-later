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

printf '\n=== --resume flag is removed in v0.2 (must go through --claude-args) ===\n'

assert_fails_with "--resume as top-level flag is rejected" "unknown flag" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --resume "7f3a4c12-0000-4000-8000-000000000000" "x"

printf '\n=== --claude-args validation ===\n'

# Word-splitting defensive checks
assert_fails_with "--claude-args with single quote rejected" "single quotes" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--model 'opus'" "x"

assert_fails_with "--claude-args with double quote rejected" "double quotes" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args '--model "opus"' "x"

# Blocklist
assert_fails_with "--claude-args -p is blocked" "headless" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "-p" "x"

assert_fails_with "--claude-args --print is blocked" "headless" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--print" "x"

assert_fails_with "--claude-args --debug is blocked" "debug" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--debug" "x"

assert_fails_with "--claude-args --worktree is blocked" "worktree" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--worktree myname" "x"

assert_fails_with "--claude-args --dangerously-skip-permissions is blocked" "security-sensitive" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--dangerously-skip-permissions" "x"

# Not in allowlist (and not in blocklist either) — should say "not in allowlist"
assert_fails_with "--claude-args unknown flag is rejected" "not in the allowlist" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--not-a-real-flag" "x"

# Non-flag token (positional) rejected
assert_fails_with "--claude-args positional token is rejected" "unexpected non-flag token" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "hello" "x"

# Allowed flag missing a value
assert_fails_with "--claude-args --model with no value rejected" "requires a value" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--model" "x"

# Allowed flag followed by another flag-looking thing where value was expected
assert_fails_with "--claude-args --model --resume is rejected" "flag-like token" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--model --resume 7f3a4c12-0000-4000-8000-000000000000" "x"

printf '\n=== --claude-args --resume UUID safety belt ===\n'

# Resume sub-flag still validates the UUID even inside --claude-args
assert_fails_with "--claude-args --resume non-UUID rejected" "--resume value must be a UUID" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--resume garbage" "x"

assert_fails_with "--claude-args --resume shell-injection attempt rejected" "single quotes" \
  "$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--resume '\$(whoami)'" "x"

printf '\n=== --claude-args allowlist passes happy cases ===\n'

# Valid cases must NOT abort. We use --dry-run and grep for the ARMED banner.
output=$("$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--teammate-mode tmux" "x" 2>&1 || true)
if printf '%s' "$output" | grep -q 'claude-later ARMED'; then
  printf '  PASS: --claude-args "--teammate-mode tmux" accepted\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: --claude-args "--teammate-mode tmux" was rejected\n'
  printf '%s\n' "$output" | head -5 | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

output=$("$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--model opus" "x" 2>&1 || true)
if printf '%s' "$output" | grep -q 'claude-later ARMED'; then
  printf '  PASS: --claude-args "--model opus" accepted\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: --claude-args "--model opus" was rejected\n'
  printf '%s\n' "$output" | head -5 | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

output=$("$CLAUDE_LATER" --dry-run --in 1m --skip-mcp-check --claude-args "--teammate-mode tmux --model opus" "x" 2>&1 || true)
if printf '%s' "$output" | grep -q 'claude-later ARMED'; then
  printf '  PASS: --claude-args with multiple flags accepted\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: --claude-args with multiple flags was rejected\n'
  printf '%s\n' "$output" | head -5 | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

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
