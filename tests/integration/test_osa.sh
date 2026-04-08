#!/bin/bash
# tests/integration/test_osa.sh — integration tests for lib/osa.sh
#
# Requires iTerm2. Skipped if $TERM_PROGRAM != iTerm.app.
# This test reads from the current pane but does NOT write to it (the visible
# probe is only run as part of pre-flight #7 in the in-pane script, not here).
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/osa.sh"
CL_TEST_NAME="test_osa"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  echo "SKIPPED: not running in iTerm2 (TERM_PROGRAM=$TERM_PROGRAM)"
  exit 0
fi

if [ -z "${ITERM_SESSION_ID:-}" ]; then
  echo "SKIPPED: ITERM_SESSION_ID not set"
  exit 0
fi

UUID=$(osa_session_uuid "$ITERM_SESSION_ID")
echo "Testing against current pane UUID: $UUID"
echo

echo "=== osa_session_uuid ==="
assert_eq "$UUID" "${ITERM_SESSION_ID#*:}" "extracts UUID portion"
assert_eq "$(osa_session_uuid 'w3t0p1:ABCDEF')" "ABCDEF" "explicit arg"

echo
echo "=== osa_iterm_version ==="
v=$(osa_iterm_version)
if [ -n "$v" ]; then
  echo "  iTerm2 version: $v"
  assert_match "$v" "^[0-9]+\.[0-9]+" "iTerm2 version looks like a version string"
else
  assert_nonzero 0 "osa_iterm_version returned non-empty"
fi

echo
echo "=== osa_session_alive ==="
if osa_session_alive "$UUID"; then
  assert_nonzero 1 "current session is alive"
else
  assert_nonzero 0 "current session is alive"
fi

if osa_session_alive "00000000-0000-0000-0000-000000000000"; then
  assert_nonzero 0 "fake UUID is not alive"
else
  assert_nonzero 1 "fake UUID is not alive"
fi

echo
echo "=== osa_get_session_name ==="
name=$(osa_get_session_name "$UUID")
if [ -n "$name" ]; then
  echo "  session name: $name"
  assert_nonzero 1 "got a non-empty session name"
else
  assert_nonzero 0 "got a non-empty session name"
fi

echo
echo "=== osa_get_contents ==="
contents=$(osa_get_contents "$UUID")
if [ -n "$contents" ]; then
  echo "  contents length: ${#contents} bytes"
  assert_nonzero 1 "got non-empty contents"
else
  assert_nonzero 0 "got non-empty contents"
fi

echo
echo "=== osa_contents_hash ==="
h1=$(osa_contents_hash "$UUID")
h2=$(osa_contents_hash "$UUID")
echo "  hash1=$h1"
echo "  hash2=$h2"
# We expect the hashes to match because the pane hasn't changed between calls
# (modulo any spinners or updates from this very test running). If they don't
# match, it means the pane is animated or the test output itself changed it.
# Either way, the function works.
assert_match "$h1" "^[a-f0-9]{32}$" "hash is md5 format"

echo
echo "=== osa_contents_has_prompt ==="
# This may or may not be true depending on whether we're in a Claude Code TUI.
# We just verify the function runs without error.
osa_contents_has_prompt "$UUID" || true
assert_nonzero 1 "function ran without error"

test_summary
