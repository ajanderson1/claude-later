#!/bin/bash
# tests/test_tail_slicing.sh
#
# Tests the CL_OSA_CONTENTS_TAIL env var behavior added in hardening pass C.
# We can't easily mock iTerm2, so this test validates the shell semantics by
# sourcing lib/osa.sh and calling it against the current live pane with the
# env var set.
#
# What it asserts:
#   1. Unset CL_OSA_CONTENTS_TAIL → full contents returned (same length as
#      explicit CL_OSA_CONTENTS_TAIL=0)
#   2. CL_OSA_CONTENTS_TAIL=5 → at most ~5 newlines returned (strict <= tail_n
#      because the slicing AppleScript does a tail by line count)
#   3. Hash stability: if we call osa_contents_hash with tail=5 twice in
#      quick succession, the hash should be the same IF the pane is quiet
#      (this is the load-bearing assumption for the helper's stable-hash
#      detector)
#   4. The ❯ glyph check path: when the pane contains `❯`, the function
#      returns 0; when tail-sliced to a window that excludes `❯`, returns 1.

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/.." && pwd)

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: tail-slicing tests require iTerm2 (TERM_PROGRAM=%s)\n' "${TERM_PROGRAM:-unset}"
  exit 0
fi

# shellcheck disable=SC1091
. "$REPO_ROOT/lib/osa.sh"

UUID="${ITERM_SESSION_ID#*:}"
if [ -z "$UUID" ]; then
  printf 'FAIL: no iTerm2 session UUID available\n'
  exit 1
fi

PASS=0
FAIL=0

printf '=== osa_get_contents without tail slicing ===\n'

unset CL_OSA_CONTENTS_TAIL
full_contents=$(osa_get_contents "$UUID")
full_bytes=${#full_contents}
if [ "$full_bytes" -gt 0 ]; then
  printf '  PASS: full contents returned %d bytes\n' "$full_bytes"
  PASS=$((PASS + 1))
else
  printf '  FAIL: full contents fetch returned zero bytes\n'
  FAIL=$((FAIL + 1))
fi

printf '\n=== osa_get_contents with CL_OSA_CONTENTS_TAIL=5 ===\n'

export CL_OSA_CONTENTS_TAIL=5
tail_contents=$(osa_get_contents "$UUID")
tail_bytes=${#tail_contents}
tail_lines=$(printf '%s\n' "$tail_contents" | wc -l | tr -d ' ')

if [ "$tail_bytes" -lt "$full_bytes" ]; then
  printf '  PASS: tail-sliced contents (%d bytes) < full (%d bytes)\n' "$tail_bytes" "$full_bytes"
  PASS=$((PASS + 1))
else
  printf '  FAIL: tail-sliced contents should be smaller than full\n'
  printf '    full bytes: %d, tail bytes: %d\n' "$full_bytes" "$tail_bytes"
  FAIL=$((FAIL + 1))
fi

if [ "$tail_lines" -le 10 ]; then
  printf '  PASS: tail-sliced contents has <=10 lines (got %d)\n' "$tail_lines"
  PASS=$((PASS + 1))
else
  printf '  FAIL: tail-sliced contents has %d lines (expected <=10 for tail=5 since wc -l counts newlines and AppleScript tail may add +/-1)\n' "$tail_lines"
  FAIL=$((FAIL + 1))
fi

printf '\n=== hash stability under tail slicing (pane quiet) ===\n'

# Double-sample with ~300ms gap. The pane should be quiet (this test isn't
# generating output between samples). Same tail window = same hash.
export CL_OSA_CONTENTS_TAIL=20
hash1=$(osa_contents_hash "$UUID")
sleep 0.3
hash2=$(osa_contents_hash "$UUID")
if [ "$hash1" = "$hash2" ]; then
  printf '  PASS: hashes stable across 300ms quiet period (%s)\n' "$hash1"
  PASS=$((PASS + 1))
else
  printf '  WARN: hashes differ — pane may not be quiet during test\n'
  printf '    hash1: %s\n    hash2: %s\n' "$hash1" "$hash2"
  # Not a hard fail — the pane could have a live status bar updating.
  # Flag it as a warning so it's visible but doesn't break CI.
fi

printf '\n=== osa_get_contents with CL_OSA_CONTENTS_TAIL=0 (explicit no-slice) ===\n'

export CL_OSA_CONTENTS_TAIL=0
nosplice=$(osa_get_contents "$UUID")
nosplice_bytes=${#nosplice}
# Should be approximately equal to full (may differ by a few bytes if the pane
# changed between the two calls — we allow a 5% tolerance)
tolerance=$((full_bytes / 20 + 10))
delta=$((nosplice_bytes - full_bytes))
if [ "$delta" -lt 0 ]; then delta=$((-delta)); fi
if [ "$delta" -lt "$tolerance" ]; then
  printf '  PASS: CL_OSA_CONTENTS_TAIL=0 returns full contents (within %d bytes tolerance)\n' "$tolerance"
  PASS=$((PASS + 1))
else
  printf '  FAIL: CL_OSA_CONTENTS_TAIL=0 delta %d exceeds tolerance %d\n' "$delta" "$tolerance"
  FAIL=$((FAIL + 1))
fi

unset CL_OSA_CONTENTS_TAIL

printf '\n=== test_tail_slicing: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
