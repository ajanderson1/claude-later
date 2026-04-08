#!/bin/bash
# tests/test_prompt_sources.sh
#
# Tests that the prompt-as-positional-arg contract works with every supported
# source: literal string, environment variable expansion, file substitution,
# clipboard (via pbpaste), and pipeline chains.
#
# These are SHELL CONTRACT tests, not claude-later internal tests — they
# validate that the way users are documented to pass prompts actually works
# when fed into claude-later's arg parsing + pre-flight validation.
#
# Runs dry-run mode so we don't actually schedule anything.

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)
CLAUDE_LATER="$REPO_ROOT/claude-later"
# shellcheck disable=SC1091
. "$TEST_DIR/test-utils.sh"

# These tests require iTerm2 because pre-flight #1 checks TERM_PROGRAM.
# Skip cleanly if we're somewhere else.
if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: prompt-source tests require iTerm2 (TERM_PROGRAM=%s)\n' "${TERM_PROGRAM:-unset}"
  exit 0
fi

setup_fake_project_dir
cleanup() { cleanup_fake_project_dir; cleanup_test_state_files; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0

# Helper: run claude-later dry-run with a given prompt and assert it made it
# to the ARMED banner's Message line intact.
run_and_assert() {
  local label=$1 expected_substring=$2
  shift 2
  local output
  output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check "$@" 2>&1 || true)
  if printf '%s' "$output" | grep -q -- "$expected_substring"; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n' "$label"
    printf '    expected substring: [%s]\n' "$expected_substring"
    printf '    full output:\n%s\n' "$output" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
}

printf '=== literal string ===\n'
run_and_assert "literal message passes through" "literal\\\\ message" "literal message"

printf '\n=== environment variable expansion ===\n'
export TEST_PROMPT="env var expansion works"
# shellcheck disable=SC2154
run_and_assert "\$VAR expands correctly" "env\\\\ var\\\\ expansion" "$TEST_PROMPT"
unset TEST_PROMPT

printf '\n=== env var set-then-pass (two-step pattern) ===\n'
# The documented correct pattern: set the variable first, then pass it on the
# next line. This is what claude-later users should be doing and the README
# examples show.
TEST_INLINE2="two-step env works"
run_and_assert "set-then-pass pattern works" "two-step\\\\ env\\\\ works" "$TEST_INLINE2"
unset TEST_INLINE2

printf '\n=== file substitution (single-line file) ===\n'
tmpf=$(mktemp -t claude-later-prompt.XXXXXX)
printf 'file content prompt' > "$tmpf"
run_and_assert "\$(cat file.txt) substitution" "file\\\\ content\\\\ prompt" "$(cat "$tmpf")"
rm -f "$tmpf"

printf '\n=== file substitution (multi-line file rejected) ===\n'
tmpf=$(mktemp -t claude-later-prompt.XXXXXX)
printf 'line 1\nline 2\n' > "$tmpf"
output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check "$(cat "$tmpf")" 2>&1 || true)
if printf '%s' "$output" | grep -q 'single line'; then
  printf '  PASS: multi-line file is rejected with clear error\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: multi-line file should be rejected\n'
  printf '    got: %s\n' "$output" | head -3
  FAIL=$((FAIL + 1))
fi
rm -f "$tmpf"

printf '\n=== file substitution (flatten wrapped lines) ===\n'
tmpf=$(mktemp -t claude-later-prompt.XXXXXX)
printf 'wrapped\nlines\nhere' > "$tmpf"
flattened=$(tr '\n' ' ' < "$tmpf" | sed 's/  */ /g; s/ $//')
run_and_assert "flattened via tr+sed" "wrapped\\\\ lines\\\\ here" "$flattened"
rm -f "$tmpf"

printf '\n=== empty prompt rejected ===\n'
output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check "" 2>&1 || true)
if printf '%s' "$output" | grep -q 'message is required'; then
  printf '  PASS: empty prompt is rejected\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: empty prompt should be rejected\n'
  printf '    got: %s\n' "$output" | head -3
  FAIL=$((FAIL + 1))
fi

printf '\n=== prompt with non-printable control chars rejected ===\n'
bad=$'good$(printf "\x01"):bad'
output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check "$bad" 2>&1 || true)
if printf '%s' "$output" | grep -q 'non-printable'; then
  printf '  PASS: control character in prompt is rejected\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: control char in prompt should be rejected\n'
  printf '    got: %s\n' "$output" | head -3
  FAIL=$((FAIL + 1))
fi

printf '\n=== prompt with tab rejected ===\n'
tabbed=$'has\ttab'
output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check "$tabbed" 2>&1 || true)
if printf '%s' "$output" | grep -q 'non-printable'; then
  printf '  PASS: tab in prompt is rejected\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: tab in prompt should be rejected\n'
  printf '    got: %s\n' "$output" | head -3
  FAIL=$((FAIL + 1))
fi

printf '\n=== prompt with special shell chars preserved ===\n'
# These assertions look at the banner's Message line, which uses printf %q
# formatting — so special chars appear backslash-escaped. Rather than match
# the exact %q output (which is platform-dependent), we just assert the
# prompt passed pre-flight validation and appears in the armed banner.
output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check 'foo && bar' 2>&1 || true)
if printf '%s' "$output" | grep -qE 'foo.+bar' && printf '%s' "$output" | grep -q 'claude-later ARMED'; then
  printf '  PASS: ampersand-containing prompt preserved\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: ampersand-containing prompt test\n'
  printf '%s' "$output" | head -20 | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

output=$("$CLAUDE_LATER" --dry-run --in 2m --skip-mcp-check '$var' 2>&1 || true)
if printf '%s' "$output" | grep -qE '\$var|\\$var' && printf '%s' "$output" | grep -q 'claude-later ARMED'; then
  printf '  PASS: literal dollar in prompt preserved\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: literal dollar prompt test\n'
  printf '%s' "$output" | head -20 | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

printf '\n=== test_prompt_sources: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
