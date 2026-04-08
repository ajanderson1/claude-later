#!/bin/bash
# claude-later/lib/time.sh — time parsing and polling math.
#
# Public API:
#   parse_in "$value"           -> echoes seconds; returns 1 on parse error
#   parse_at "$value"           -> echoes epoch; returns 1 on parse error or DST gap
#   wall_clock_for_epoch $epoch -> echoes "YYYY-MM-DD HH:MM:SS ZONE (+ZHZM)"
#   polling_should_fire $now $target   -> returns 0 if now >= target
#   polling_missed_window $now $target $grace_seconds -> returns 0 if now-target > grace

# parse_in "$value"
# Accepts: 30s, 5m, 4h, 2h30m, 1h30m45s, etc. Returns total seconds on stdout.
parse_in() {
  local input=$1
  local total=0
  local remaining=$input
  if [ -z "$input" ]; then return 1; fi
  while [ -n "$remaining" ]; do
    if [[ "$remaining" =~ ^([0-9]+)([smhd])(.*)$ ]]; then
      local n=${BASH_REMATCH[1]}
      local u=${BASH_REMATCH[2]}
      remaining=${BASH_REMATCH[3]}
      case "$u" in
        s) total=$((total + n));;
        m) total=$((total + n*60));;
        h) total=$((total + n*3600));;
        d) total=$((total + n*86400));;
      esac
    else
      return 1
    fi
  done
  if [ "$total" -le 0 ]; then return 1; fi
  printf '%s\n' "$total"
}

# parse_at "$value"
# Accepts: HH:MM, HH:MM:SS, YYYY-MM-DD HH:MM, YYYY-MM-DD HH:MM:SS.
# For HH:MM/HH:MM:SS, picks today if still in the future, otherwise tomorrow.
# Detects DST gaps via round-trip; aborts on ambiguous/nonexistent local times.
# Returns epoch on stdout.
parse_at() {
  local input=$1
  local epoch=""
  local back=""
  local fmt=""
  local now_epoch
  now_epoch=$(date +%s)

  if [[ "$input" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    fmt="%H:%M"
    epoch=$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) $input" "+%s" 2>/dev/null) || return 1
    if [ "$epoch" -le "$now_epoch" ]; then
      epoch=$((epoch + 86400))
    fi
    back=$(date -j -r "$epoch" "+%H:%M")
    if [ "$back" != "$input" ]; then return 1; fi
  elif [[ "$input" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    fmt="%H:%M:%S"
    epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) $input" "+%s" 2>/dev/null) || return 1
    if [ "$epoch" -le "$now_epoch" ]; then
      epoch=$((epoch + 86400))
    fi
    back=$(date -j -r "$epoch" "+%H:%M:%S")
    if [ "$back" != "$input" ]; then return 1; fi
  elif [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
    fmt="%Y-%m-%d %H:%M"
    epoch=$(date -j -f "$fmt" "$input" "+%s" 2>/dev/null) || return 1
    back=$(date -j -r "$epoch" "+%Y-%m-%d %H:%M")
    if [ "$back" != "$input" ]; then return 1; fi
  elif [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    fmt="%Y-%m-%d %H:%M:%S"
    epoch=$(date -j -f "$fmt" "$input" "+%s" 2>/dev/null) || return 1
    back=$(date -j -r "$epoch" "+%Y-%m-%d %H:%M:%S")
    if [ "$back" != "$input" ]; then return 1; fi
  else
    return 1
  fi

  if [ "$epoch" -le "$now_epoch" ]; then return 1; fi
  printf '%s\n' "$epoch"
}

# wall_clock_for_epoch $epoch
# Echo a human-readable wall-clock string with zone info.
wall_clock_for_epoch() {
  local epoch=$1
  date -j -r "$epoch" "+%Y-%m-%d %H:%M:%S %Z (%z)"
}

# delta_human $seconds
# Echo a "+1h 23m 45s" style string.
delta_human() {
  local s=$1
  local h=$((s / 3600))
  local m=$(((s % 3600) / 60))
  local sec=$((s % 60))
  if [ "$h" -gt 0 ]; then
    printf '+%dh %dm %ds\n' "$h" "$m" "$sec"
  elif [ "$m" -gt 0 ]; then
    printf '+%dm %ds\n' "$m" "$sec"
  else
    printf '+%ds\n' "$sec"
  fi
}

# polling_should_fire $now_epoch $target_epoch
# Returns 0 if now >= target.
polling_should_fire() {
  local now=$1
  local target=$2
  [ "$now" -ge "$target" ]
}

# polling_missed_window $now_epoch $target_epoch $grace_seconds
# Returns 0 if (now - target) > grace, meaning the fire window was missed.
polling_missed_window() {
  local now=$1
  local target=$2
  local grace=$3
  [ $((now - target)) -gt "$grace" ]
}
