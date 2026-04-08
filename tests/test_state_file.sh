#!/bin/bash
# tests/test_state_file.sh — unit tests for lib/state.sh
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/state.sh"
CL_TEST_NAME="test_state_file"

# Use a sandbox dir so we don't pollute ~/.claude-later
SANDBOX=$(mktemp -d -t cl_state_test.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

CL_STATE_ROOT="$SANDBOX/state"
CL_LOGS_ROOT="$SANDBOX/logs"
mkdir -p "$CL_STATE_ROOT" "$CL_LOGS_ROOT"

echo "=== state_sanitize_sid ==="
assert_eq "$(state_sanitize_sid 'w3t0p1:EDDAB47A')" "w3t0p1_EDDAB47A" "colon -> underscore"

echo
echo "=== state_path_for / state_active_pointer_for ==="
sid="w3t0p1:EDDAB47A-46AA-4781-B69E-64A270E0C61F"
path=$(state_path_for "$sid" 1712554800)
expected="$CL_STATE_ROOT/w3t0p1_EDDAB47A-46AA-4781-B69E-64A270E0C61F-1712554800.json"
assert_eq "$path" "$expected" "state_path_for"

ptr=$(state_active_pointer_for "$sid")
expected_ptr="$CL_STATE_ROOT/w3t0p1_EDDAB47A-46AA-4781-B69E-64A270E0C61F.active"
assert_eq "$ptr" "$expected_ptr" "state_active_pointer_for"

echo
echo "=== state_write + state_read ==="
state_write "$path" "$sid" "3.5.0" "2.1.92" "w3t0p1" 12345 1712554800 1712528280 '[]' "review the open PRs" "$CL_LOGS_ROOT/test.log"
assert_zero $? "state_write succeeds"

# jq parses it
if jq -e .target_epoch "$path" >/dev/null 2>&1; then
  assert_nonzero 1 "state file is valid JSON"
else
  assert_nonzero 0 "state file is valid JSON"
fi

assert_eq "$(state_read "$path" .iterm_session_id)" "$sid" "read iterm_session_id"
assert_eq "$(state_read "$path" .iterm_version)" "3.5.0" "read iterm_version"
assert_eq "$(state_read "$path" .claude_version)" "2.1.92" "read claude_version"
assert_eq "$(state_read "$path" .target_epoch)" "1712554800" "read target_epoch"
assert_eq "$(state_read "$path" .message)" "review the open PRs" "read message"
assert_eq "$(state_read "$path" .status)" "armed" "initial status is armed"
assert_eq "$(state_read "$path" '.schema_version')" "2" "schema_version is 2"
assert_eq "$(state_read "$path" '.claude_args | length')" "0" "claude_args empty by default"
assert_eq "$(state_read "$path" .helper_pid)" "null" "helper_pid is null at write"

# v0.2: resume_id field no longer exists
assert_eq "$(state_read "$path" '.resume_id // "missing"')" "missing" "resume_id field removed in schema v2"

echo
echo "=== state_write with populated claude_args ==="
args_path=$(state_path_for "$sid" 1712554850)
state_write "$args_path" "$sid" "3.5.0" "2.1.92" "w3t0p1" 12346 1712554800 1712528280 \
  '["--teammate-mode","tmux","--resume","7f3a4c12-0000-4000-8000-000000000000"]' \
  "test message" "$CL_LOGS_ROOT/test.log"
assert_zero $? "state_write with populated claude_args succeeds"
assert_eq "$(state_read "$args_path" '.claude_args | length')" "4" "claude_args has 4 tokens"
assert_eq "$(state_read "$args_path" '.claude_args[0]')" "--teammate-mode" "claude_args[0] preserved"
assert_eq "$(state_read "$args_path" '.claude_args[2]')" "--resume" "claude_args[2] preserved"
assert_eq "$(state_read "$args_path" '.claude_args[3]')" "7f3a4c12-0000-4000-8000-000000000000" "claude_args[3] UUID preserved"

echo
echo "=== state_write with shell-injection-y message ==="
nasty_msg='hello "world" $foo `backtick` \backslash; rm -rf ~'
nasty_path=$(state_path_for "$sid" 1712554900)
state_write "$nasty_path" "$sid" "3.5.0" "2.1.92" "w3t0p1" 12345 1712554800 1712528280 '[]' "$nasty_msg" "$CL_LOGS_ROOT/test.log"
assert_zero $? "state_write with metacharacters succeeds"

# Round-trip through jq must be byte-for-byte identical
read_back=$(state_read "$nasty_path" .message)
assert_eq "$read_back" "$nasty_msg" "metacharacters survive jq round-trip"

echo
echo "=== state_set_field / state_set_int / state_mark ==="
state_set_int "$path" "helper_pid" 99999
assert_eq "$(state_read "$path" .helper_pid)" "99999" "state_set_int helper_pid"

state_mark "$path" "delivered"
assert_eq "$(state_read "$path" .status)" "delivered" "state_mark delivered"
read_at=$(state_read "$path" .status_at_epoch)
if [ -n "$read_at" ] && [ "$read_at" != "null" ]; then
  assert_nonzero 1 "state_mark sets status_at_epoch"
else
  assert_nonzero 0 "state_mark sets status_at_epoch"
fi

state_mark "$path" "tui_not_ready" "60s timeout exceeded"
assert_eq "$(state_read "$path" .status)" "tui_not_ready" "state_mark with detail (status)"
assert_eq "$(state_read "$path" .status_detail)" "60s timeout exceeded" "state_mark with detail (detail)"

echo
echo "=== state_active_set / state_active_clear ==="
state_active_set "$ptr" "$path"
if [ -e "$ptr" ]; then assert_nonzero 1 "active pointer exists after set"; else assert_nonzero 0 "active pointer exists after set"; fi
assert_eq "$(cat "$ptr")" "$path" "active pointer contents"

state_active_clear "$ptr"
if [ -e "$ptr" ]; then assert_nonzero 0 "active pointer cleared"; else assert_nonzero 1 "active pointer cleared"; fi

echo
echo "=== state_check_stale ==="
# No active pointer
state_active_clear "$ptr"
r=$(state_check_stale "$sid")
assert_eq "$r" "no_active" "stale check: no_active when no pointer"

# Pointer exists but points to file with dead PID (use 99999 — almost certainly dead)
fake_path=$(state_path_for "$sid" 1712554999)
state_write "$fake_path" "$sid" "3.5.0" "2.1.92" "w3t0p1" 99999 1712554800 1712528280 '[]' "old message" "$CL_LOGS_ROOT/old.log"
state_active_set "$ptr" "$fake_path"
r=$(state_check_stale "$sid")
assert_eq "$r" "stale" "stale check: dead PID -> stale"

# Pointer exists, PID alive but not claude-later (use $$ which is /bin/bash)
state_set_int "$fake_path" "script_pid" $$
r=$(state_check_stale "$sid")
# $$ is the test script's bash; ps will not show "claude-later" in command
assert_eq "$r" "stale" "stale check: PID alive but unrelated -> stale"

# Pointer exists, points to nothing readable
echo "/nonexistent/path.json" > "$ptr"
r=$(state_check_stale "$sid")
assert_eq "$r" "stale" "stale check: pointer to missing file -> stale"

echo
echo "=== state file is valid JSON across all writes ==="
for f in "$CL_STATE_ROOT"/*.json; do
  if jq empty "$f" 2>/dev/null; then
    assert_nonzero 1 "valid JSON: $(basename "$f")"
  else
    assert_nonzero 0 "valid JSON: $(basename "$f")"
  fi
done

test_summary
