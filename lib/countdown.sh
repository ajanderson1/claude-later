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
  printf '⏳ claude-later • fires in %s • ^C to cancel' "$body"
}

# cl_countdown_cancel_tombstone STATE_PATH
# Hook point for ^C handling — writes the cancelled_by_user tombstone and
# clears the active pointer. Separated so tests can stub it.
cl_countdown_cancel_tombstone() {
  local state_path=$1
  state_mark "$state_path" "cancelled_by_user" "^C during countdown" 2>/dev/null || true
  state_active_clear "$CL_ACTIVE_PTR" 2>/dev/null || true
}

# cl_countdown_loop
# Reads CL_TARGET_EPOCH, CL_STATE_PATH, CL_ACTIVE_PTR, CL_LOG_PATH.
# Prints a live countdown to STDERR once per second (so STDOUT stays clean).
# Exits the loop when remaining <= 5. Signal handling:
#   ^C → cl_countdown_cancel_tombstone, notify, exit 130
#   ^D → re-print banner via cl_banner_render, continue loop
cl_countdown_loop() {
  cl_countdown_on_int() {
    cl_countdown_cancel_tombstone "$CL_STATE_PATH"
    notify "claude-later: cancelled" "Cancelled by user (^C) before fire time" 2>/dev/null || true
    printf '\n' >&2
    exit 130
  }
  trap 'cl_countdown_on_int' INT
  while :; do
    local now remaining
    now=$(date +%s)
    remaining=$((CL_TARGET_EPOCH - now))
    if [ "$remaining" -le 5 ]; then
      printf '\r\033[K' >&2
      printf '→ T−5s, spawning helper...\n' >&2
      return 0
    fi
    if polling_missed_window "$now" "$CL_TARGET_EPOCH" 60; then
      state_mark "$CL_STATE_PATH" "missed_window" "asleep through fire window" 2>/dev/null || true
      state_active_clear "$CL_ACTIVE_PTR" 2>/dev/null || true
      notify "claude-later: missed_window" "System was asleep through the fire window" 2>/dev/null || true
      exit 1
    fi
    local line
    line=$(cl_format_countdown "$remaining")
    # \r returns cursor to col 0; \033[K clears to EOL. Stderr keeps stdout clean for tests.
    printf '\r\033[K%s' "$line" >&2
    sleep 1
  done
}
