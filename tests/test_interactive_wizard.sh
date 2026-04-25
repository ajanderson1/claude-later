#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_interactive_wizard"
. "$CL_DIR/tests/test-utils.sh"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: wizard e2e requires iTerm2 (dry-run still hits preflights)\n' >&2
  exit 0
fi

setup_fake_project_dir

# Drive the wizard with scripted stdin. Expected answers:
#   when: "4h"
#   resume: "f" (fresh)
#   extra flags: (enter, none)
#   message: "wizard test payload"
#   confirm: "y"
out=$(printf '4h\nf\n\nwizard test payload\ny\n' \
  | "$CL_DIR/claude-later" --interactive --dry-run --skip-mcp-check 2>&1 || true)

assert_match "$out" "When should it fire" "prompt 1 asked"
assert_match "$out" "Resume a previous" "prompt 2 asked"
assert_match "$out" "extra claude flags" "prompt 3 asked"
assert_match "$out" "Your message" "prompt 4 asked"
assert_match "$out" "This is equivalent to running" "confirmation shown"
assert_match "$out" "claude-later --in 4h \"wizard test payload\"" "argv preview matches"
assert_match "$out" "claude-later ARMED" "dry-run reached ARMED banner"

# Invalid input is re-prompted
out=$(printf 'banana\n4h\nf\n\nok\ny\n' \
  | "$CL_DIR/claude-later" --interactive --dry-run --skip-mcp-check 2>&1 || true)
assert_match "$out" "invalid" "invalid time input rejected"

# !abort exits cleanly
out=$(printf '!abort\n' | "$CL_DIR/claude-later" --interactive 2>&1 || true)
assert_match "$out" "aborted" "!abort exits cleanly"

cleanup_test_state_files
cleanup_fake_project_dir
test_summary
