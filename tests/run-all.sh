#!/bin/bash
# tests/run-all.sh — runs all unit tests (no integration tests).
# Integration tests (which require a live iTerm2 + claude) live in tests/integration/
# and are run separately via tests/run-integration.sh.
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$CL_DIR"

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=""

for t in tests/test_*.sh; do
  printf '\n##### %s #####\n' "$t"
  if /bin/bash "$t"; then
    :
  else
    FAILED_FILES="$FAILED_FILES $t"
  fi
done

printf '\n##### SUMMARY #####\n'
if [ -n "$FAILED_FILES" ]; then
  printf 'FAILED test files:%s\n' "$FAILED_FILES"
  exit 1
fi
printf 'All test files passed.\n'
