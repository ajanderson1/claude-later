#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_interactive_resolution"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/interactive.sh"

# Seed a fake project dir with two /rename'd transcripts
FAKE_PROJ=$(mktemp -d)
export CL_INTERACTIVE_FAKE_PROJ_DIR="$FAKE_PROJ"
cat > "$FAKE_PROJ/7f3a4c12-0000-4000-8000-000000000000.jsonl" <<EOF
{"type":"custom-title","customTitle":"nightly-refactor","sessionId":"7f3a4c12-0000-4000-8000-000000000000"}
EOF
cat > "$FAKE_PROJ/5e2d3b11-0000-4000-8000-000000000000.jsonl" <<EOF
{"type":"custom-title","customTitle":"morning-review","sessionId":"5e2d3b11-0000-4000-8000-000000000000"}
EOF

# Zero matches: empty list returned
got=$(cl_list_renamed_sessions "$FAKE_PROJ" | wc -l | tr -d ' ')
assert_eq "$got" "2" "lists two renamed sessions"

# Pick-by-exact-name returns the uuid
got=$(cl_resolve_session_name "$FAKE_PROJ" "nightly-refactor")
assert_eq "$got" "7f3a4c12-0000-4000-8000-000000000000" "resolves name to uuid"

# Zero-match returns nonzero
if cl_resolve_session_name "$FAKE_PROJ" "does-not-exist" >/dev/null; then
  assert_eq "resolved" "expected-fail" "nonexistent name"
else
  assert_eq "failed" "failed" "nonexistent name fails as expected"
fi

rm -rf "$FAKE_PROJ"
test_summary
