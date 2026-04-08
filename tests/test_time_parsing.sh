#!/bin/bash
# tests/test_time_parsing.sh — unit tests for lib/time.sh
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/time.sh"
CL_TEST_NAME="test_time_parsing"

echo "=== parse_in ==="

r=$(parse_in "30s") || r="ERROR"
assert_eq "$r" "30" "parse_in 30s"

r=$(parse_in "5m") || r="ERROR"
assert_eq "$r" "300" "parse_in 5m"

r=$(parse_in "4h") || r="ERROR"
assert_eq "$r" "14400" "parse_in 4h"

r=$(parse_in "2h30m") || r="ERROR"
assert_eq "$r" "9000" "parse_in 2h30m"

r=$(parse_in "1d12h") || r="ERROR"
assert_eq "$r" "129600" "parse_in 1d12h"

r=$(parse_in "1h30m45s") || r="ERROR"
assert_eq "$r" "5445" "parse_in 1h30m45s"

if parse_in "0s" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_in 0s rejects zero"
else
  assert_nonzero 1 "parse_in 0s rejects zero"
fi

if parse_in "garbage" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_in garbage rejects"
else
  assert_nonzero 1 "parse_in garbage rejects"
fi

if parse_in "" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_in empty rejects"
else
  assert_nonzero 1 "parse_in empty rejects"
fi

if parse_in "5x" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_in 5x rejects unknown unit"
else
  assert_nonzero 1 "parse_in 5x rejects unknown unit"
fi

echo
echo "=== parse_at ==="

# We can't easily test exact times because "now" is moving, but we can test:
# 1. Future absolute times succeed
# 2. Past absolute times fail
# 3. HH:MM that's already past today rolls to tomorrow

# Pick a time well in the future (year 2030)
r=$(parse_at "2030-01-01 03:00:00") || r="ERROR"
expected=$(date -j -f "%Y-%m-%d %H:%M:%S" "2030-01-01 03:00:00" "+%s")
assert_eq "$r" "$expected" "parse_at YYYY-MM-DD HH:MM:SS far future"

r=$(parse_at "2030-01-01 03:00") || r="ERROR"
expected=$(date -j -f "%Y-%m-%d %H:%M" "2030-01-01 03:00" "+%s")
assert_eq "$r" "$expected" "parse_at YYYY-MM-DD HH:MM far future"

# Past time must fail
if parse_at "2020-01-01 03:00:00" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_at past time rejects"
else
  assert_nonzero 1 "parse_at past time rejects"
fi

# HH:MM already past today should roll to tomorrow
# (We'll use 00:01 — almost certainly past unless we run this at midnight)
now_h=$(date +%H)
if [ "$now_h" -gt 0 ]; then
  r=$(parse_at "00:01") || r="ERROR"
  now=$(date +%s)
  if [ "$r" != "ERROR" ] && [ "$r" -gt "$now" ]; then
    assert_nonzero 1 "parse_at 00:01 rolls to tomorrow"
  else
    assert_nonzero 0 "parse_at 00:01 rolls to tomorrow (got $r vs now $now)"
  fi
fi

# HH:MM in the future today should NOT roll
# (Pick 23:59 — almost certainly future unless we run at exactly 23:59)
now_h=$(date +%H)
if [ "$now_h" -lt 23 ]; then
  r=$(parse_at "23:59") || r="ERROR"
  now=$(date +%s)
  tomorrow=$((now + 86400))
  if [ "$r" != "ERROR" ] && [ "$r" -gt "$now" ] && [ "$r" -lt "$tomorrow" ]; then
    assert_nonzero 1 "parse_at 23:59 stays today"
  else
    assert_nonzero 0 "parse_at 23:59 stays today (got $r)"
  fi
fi

# Invalid format
if parse_at "yesterday at 3" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_at unparseable rejects"
else
  assert_nonzero 1 "parse_at unparseable rejects"
fi

if parse_at "03:60" >/dev/null 2>&1; then
  assert_nonzero 0 "parse_at 03:60 rejects"
else
  assert_nonzero 1 "parse_at 03:60 rejects"
fi

# DST gap detection — pin TZ to America/Los_Angeles where 2026-03-08 02:30 doesn't exist
# (spring forward jumps from 02:00 to 03:00). The round-trip check should catch this.
if TZ=America/Los_Angeles parse_at "2026-03-08 02:30:00" >/dev/null 2>&1; then
  # The parser may have accepted it; check what it returned and whether it round-trips
  r=$(TZ=America/Los_Angeles parse_at "2026-03-08 02:30:00") || r="ERROR"
  # If parse_at correctly detected the gap, we'd be in the else branch.
  # Acceptance here means parse_at trusted BSD date's normalization. We expect rejection.
  assert_nonzero 0 "parse_at DST gap (2026-03-08 02:30 PT) rejects"
else
  assert_nonzero 1 "parse_at DST gap (2026-03-08 02:30 PT) rejects"
fi

echo
echo "=== polling predicates ==="

if polling_should_fire 100 100; then assert_nonzero 1 "polling_should_fire equal"; else assert_nonzero 0 "polling_should_fire equal"; fi
if polling_should_fire 101 100; then assert_nonzero 1 "polling_should_fire after"; else assert_nonzero 0 "polling_should_fire after"; fi
if polling_should_fire 99 100; then assert_nonzero 0 "polling_should_fire before"; else assert_nonzero 1 "polling_should_fire before (false)"; fi

if polling_missed_window 161 100 60; then assert_nonzero 1 "polling_missed_window 161-100>60"; else assert_nonzero 0 "polling_missed_window 161-100>60"; fi
if polling_missed_window 159 100 60; then assert_nonzero 0 "polling_missed_window 159-100<=60"; else assert_nonzero 1 "polling_missed_window 159-100<=60 (false)"; fi

echo
echo "=== delta_human ==="
assert_eq "$(delta_human 30)" "+30s" "delta_human 30s"
assert_eq "$(delta_human 90)" "+1m 30s" "delta_human 90s"
assert_eq "$(delta_human 3661)" "+1h 1m 1s" "delta_human 3661s"
assert_eq "$(delta_human 14400)" "+4h 0m 0s" "delta_human 4h"

test_summary
