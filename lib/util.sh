#!/bin/bash
# claude-later/lib/util.sh — logging, notifications, and Secure Input check.
#
# Sourced by both claude-later (in-pane script) and claude-later-helper.
# All public functions are prefixed with their concern (log_, notify_, sec_).

# ---- Logging ----------------------------------------------------------------

# Single global log file path. Set by log_init at startup.
CL_LOG_PATH=""

# log_init "$path"
# Open the log file for append. Aborts if not writable.
log_init() {
  local path=$1
  CL_LOG_PATH=$path
  : > /dev/null  # placate set -u
  if ! touch "$path" 2>/dev/null; then
    printf 'claude-later: cannot open log file: %s\n' "$path" >&2
    return 1
  fi
}

# log_event "key=val key=val ..."
# Append a structured single-line log entry with a timestamp prefix.
log_event() {
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  printf '%s %s\n' "$ts" "$*" >> "$CL_LOG_PATH"
}

# log_tombstone "$reason" "$detail"
# Append a tombstone line. Used on every terminal exit path.
log_tombstone() {
  local reason=$1
  local detail=${2:-}
  log_event "TOMBSTONE reason=$reason detail=$(printf '%s' "$detail" | tr '\n' ' ')"
}

# ---- Notifications ----------------------------------------------------------

# notify "$title" "$body"
# Fire a macOS user notification. Both args are passed via osascript argv to
# avoid AppleScript injection from user-controlled message content.
notify() {
  local title=$1
  local body=$2
  osascript - "$title" "$body" <<'OSA' >/dev/null 2>&1
on run argv
  set t to item 1 of argv
  set b to item 2 of argv
  display notification b with title t
end run
OSA
}

# ---- Secure Input check -----------------------------------------------------

# sec_input_engaged
# Returns 0 (true) if Secure Input is currently engaged anywhere on the system.
# Returns 1 (false) otherwise. Uses Carbon API via swift one-liner.
sec_input_engaged() {
  local r
  r=$(swift -e 'import Carbon; print(IsSecureEventInputEnabled())' 2>/dev/null)
  [ "$r" = "true" ]
}
