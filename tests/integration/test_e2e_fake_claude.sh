#!/bin/bash
# tests/integration/test_e2e_fake_claude.sh
#
# End-to-end: arm claude-later with fake-claude as `claude` on PATH, wait for
# fire to elapse, assert fake-claude received the exact message.
#
# Regime requirement: must run from a bare iTerm2 shell, NOT from inside a
# running Claude Code session. When run inside Claude Code, the agent's TUI
# already owns the iTerm2 pane's pty; the backgrounded `claude-later`'s
# `exec fake-claude` then inherits the agent subshell's pipe rather than the
# pane, so fake-claude's stdout never reaches the pane and the helper's
# readiness probe never finds the `❯` glyph. We auto-skip in that case.
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CL_TEST_NAME="test_e2e_fake_claude"
. "$CL_DIR/tests/test-utils.sh"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: e2e requires iTerm2\n' >&2
  exit 0
fi
if [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
  printf 'SKIP: e2e cannot run from inside a Claude Code session — fake-claude exec inherits the agent subshell pty, not the iTerm2 pane. Run from a bare shell.\n' >&2
  exit 0
fi

# Install fake-claude on PATH for this test
TMPBIN=$(mktemp -d)
trap 'rm -rf "$TMPBIN"' EXIT
ln -s "$CL_DIR/tests/fixtures/fake-claude" "$TMPBIN/claude"
export PATH="$TMPBIN:$PATH"

MARK=$(mktemp -t clfc.XXXXXX)
export CL_FAKE_CLAUDE_OUTPUT="$MARK"

setup_fake_project_dir

MSG="e2e test payload $$"
"$CL_DIR/claude-later" --in 8s --skip-mcp-check "$MSG" &
CL_PID=$!

# Wait up to 40s for the marker to populate; poll every 500ms.
for _ in $(seq 1 80); do
  if [ -s "$MARK" ]; then break; fi
  sleep 0.5
done

got=$(cat "$MARK" 2>/dev/null | head -c 4096)
wait "$CL_PID" 2>/dev/null || true

assert_eq "$got" "$MSG
" "delivered message matches arm-time message"

cleanup_test_state_files
cleanup_fake_project_dir
test_summary
