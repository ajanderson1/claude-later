#!/bin/bash
# claude-later/lib/countdown.sh — in-pane live countdown.
#
# Public API (populated as the plan proceeds):
#   cl_format_countdown REMAINING_SEC   — pure string formatter (Task 9)
#   cl_countdown_loop TARGET_EPOCH      — main loop w/ signal traps (Task 10)

cl_format_countdown() {
  local s=$1 h m sec body
  if [ "$s" -lt 60 ]; then
    body="${s}s"
  elif [ "$s" -lt 3600 ]; then
    m=$((s / 60)); sec=$((s % 60))
    body="${m}m ${sec}s"
  else
    h=$((s / 3600)); m=$(((s % 3600) / 60)); sec=$((s % 60))
    body="${h}h ${m}m ${sec}s"
  fi
  printf '⏳ claude-later • fires in %s • ^C to cancel • ^D to re-banner' "$body"
}
