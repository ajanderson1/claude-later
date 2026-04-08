#!/bin/bash
# tests/integration/run-integration.sh — runs integration tests.
# Requires iTerm2. Skipped if $TERM_PROGRAM != iTerm.app.
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$CL_DIR"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIPPED: integration tests require iTerm2 (TERM_PROGRAM=%s)\n' "${TERM_PROGRAM:-unset}"
  exit 0
fi

FAILED=""
for t in tests/integration/test_*.sh; do
  printf '\n##### %s #####\n' "$t"
  if /bin/bash "$t"; then
    :
  else
    FAILED="$FAILED $t"
  fi
done

if [ -n "$FAILED" ]; then
  printf '\nFAILED:%s\n' "$FAILED"
  exit 1
fi
printf '\nAll integration tests passed.\n'
