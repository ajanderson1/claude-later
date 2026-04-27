#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_banner"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/time.sh"
. "$CL_DIR/lib/preflights.sh"
. "$CL_DIR/lib/banner.sh"

cl_pf_registry_reset
cl_pf_register 1 "label one" true
cl_pf_register 2 "label two" true
cl_pf_run_all >/dev/null

# Minimum globals the banner reads
CL_TARGET_EPOCH=$(( $(date +%s) + 3600 ))
_SAVED_ITERM_SESSION_ID="${ITERM_SESSION_ID:-}"
ITERM_SESSION_ID="w0t0p0:00000000-0000-0000-0000-000000000000"
CL_PANE_ID="w0t0p0"
CL_ITERM_VERSION="3.5.0"
CL_CLAUDE_VERSION="2.0.0 (Claude Code)"
CL_CLAUDE_ARGS_ARR=()
CL_RESUME_NAME_RESOLUTION=""
ARG_MESSAGE="hello world"
CL_LOG_PATH="/tmp/x.log"
CL_STATE_PATH="/tmp/x.json"
ARG_NO_CAFFEINATE=0

out=$(cl_banner_render)
assert_match "$out" "claude-later ARMED" "banner headline present"
assert_match "$out" "Verified now \(2 checks passed\)" "verified-now header with count"
assert_match "$out" "✓ label one" "verified label 1"
assert_match "$out" "✓ label two" "verified label 2"
assert_match "$out" "Residual risks" "residual-risks header"
assert_match "$out" "iTerm2 window close" "residual risk: window close"
assert_match "$out" "Reboot" "residual risk: reboot"
assert_match "$out" "lid close" "residual risk: lid close"

# Resume-name resolution line appears when set
CL_RESUME_NAME_RESOLUTION="nightly -> abc-def"
CL_CLAUDE_ARGS_ARR=(--resume abc-def)
out=$(cl_banner_render)
assert_match "$out" "resolved --resume-name nightly" "resume-name line shown"

# E2E: dry-run a real invocation; banner must list multiple ✓ lines
ITERM_SESSION_ID="$_SAVED_ITERM_SESSION_ID"
if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
  setup_fake_project_dir
  out=$(./claude-later --dry-run --in 1m --skip-mcp-check "banner e2e test" 2>&1 || true)
  assert_match "$out" "Verified now \([0-9]+ checks passed\)" "dry-run banner: verified count"
  assert_match "$out" "✓ macOS \+ iTerm2" "dry-run banner: pf_1 label"
  cleanup_test_state_files
  cleanup_fake_project_dir
else
  printf '  SKIP: e2e dry-run banner (not in iTerm2)\n'
fi

test_summary
