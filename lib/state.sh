#!/bin/bash
# claude-later/lib/state.sh — state file lifecycle.
#
# State files live at:
#   ~/.claude-later/state/<iterm-session-id-sanitized>-<armed_at_epoch>.json   (per-run)
#   ~/.claude-later/state/<iterm-session-id-sanitized>.active                  (pointer)
#
# The "sanitized" session id replaces ':' with '_' for filename safety.
#
# All writes are atomic via mktemp + mv.

CL_STATE_ROOT="${HOME}/.claude-later/state"
CL_LOGS_ROOT="${HOME}/.claude-later/logs"

# state_dir_init
# Create state and logs dirs with 0700. Idempotent.
state_dir_init() {
  if ! mkdir -p "$CL_STATE_ROOT" "$CL_LOGS_ROOT" 2>/dev/null; then
    printf 'claude-later: cannot create state dirs at ~/.claude-later/\n' >&2
    return 1
  fi
  chmod 0700 "${HOME}/.claude-later" "$CL_STATE_ROOT" "$CL_LOGS_ROOT" 2>/dev/null
  return 0
}

# state_sanitize_sid "$ITERM_SESSION_ID"
# Replace : with _ for filename safety. The full sid is preserved as the key
# inside the JSON; only the filename is sanitized.
state_sanitize_sid() {
  printf '%s' "${1//:/_}"
}

# state_path_for "$iterm_session_id" "$armed_at_epoch"
# Echo the state file path for this run.
state_path_for() {
  local sid_safe
  sid_safe=$(state_sanitize_sid "$1")
  printf '%s/%s-%s.json\n' "$CL_STATE_ROOT" "$sid_safe" "$2"
}

# state_active_pointer_for "$iterm_session_id"
# Echo the path of the per-pane .active pointer file.
state_active_pointer_for() {
  local sid_safe
  sid_safe=$(state_sanitize_sid "$1")
  printf '%s/%s.active\n' "$CL_STATE_ROOT" "$sid_safe"
}

# state_write "$path" "$iterm_session_id" "$iterm_version" "$claude_version" \
#             "$pane_id" "$script_pid" "$target_epoch" "$armed_at_epoch" \
#             "$resume_id" "$message" "$log_path"
# Build a fresh state file via jq -n. Atomic write via mktemp + mv.
state_write() {
  local path=$1
  local sid=$2
  local iv=$3
  local cv=$4
  local pane=$5
  local pid=$6
  local target=$7
  local armed=$8
  local resume=$9
  local msg=${10}
  local log=${11}
  local tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  jq -n \
    --arg sid "$sid" \
    --arg iv "$iv" \
    --arg cv "$cv" \
    --arg pane "$pane" \
    --argjson pid "$pid" \
    --argjson target "$target" \
    --argjson armed "$armed" \
    --arg resume "$resume" \
    --arg msg "$msg" \
    --arg log "$log" \
    '{
      schema_version: 1,
      iterm_session_id: $sid,
      iterm_version: $iv,
      claude_version: $cv,
      pane_id: $pane,
      script_pid: $pid,
      helper_pid: null,
      target_epoch: $target,
      armed_at_epoch: $armed,
      resume_id: (if $resume == "" then null else $resume end),
      message: $msg,
      log_path: $log,
      status: "armed",
      status_detail: null,
      status_at_epoch: null
    }' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# state_read "$path" "$jq_filter"
# Read a value from the state file. Aborts on parse error.
state_read() {
  local path=$1
  local filter=$2
  if [ ! -r "$path" ]; then return 1; fi
  jq -er "$filter" "$path" 2>/dev/null
}

# state_set_field "$path" "$field" "$value"
# Atomic update of a single string field. value="" means JSON null.
state_set_field() {
  local path=$1
  local field=$2
  local value=$3
  local tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  if [ -z "$value" ]; then
    jq --arg f "$field" '.[$f] = null' "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# state_set_int "$path" "$field" "$value"
# Atomic update of a single integer field.
state_set_int() {
  local path=$1
  local field=$2
  local value=$3
  local tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# state_mark "$path" "$status" ["$detail"]
# Update status, status_detail, status_at_epoch atomically.
state_mark() {
  local path=$1
  local status=$2
  local detail=${3:-}
  local now
  now=$(date +%s)
  local tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  jq --arg s "$status" --arg d "$detail" --argjson t "$now" \
    '.status = $s | .status_detail = (if $d == "" then null else $d end) | .status_at_epoch = $t' \
    "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# state_active_set "$pointer_path" "$state_path"
# Write the .active pointer (atomic).
state_active_set() {
  local pointer=$1
  local target=$2
  local tmp
  tmp=$(mktemp "${pointer}.XXXXXX") || return 1
  printf '%s\n' "$target" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$pointer" || { rm -f "$tmp"; return 1; }
}

# state_active_clear "$pointer_path"
state_active_clear() {
  rm -f "$1" 2>/dev/null
}

# state_check_stale "$iterm_session_id"
# If a .active pointer exists for this pane, check whether the prior process is
# still alive AND is a claude-later. Echoes one of:
#   "no_active"     - no .active pointer; safe to arm
#   "stale"         - prior PID is dead or unrelated; safe to arm (and clean up)
#   "live <pid> <target_epoch>" - prior arm is genuinely live; refuse to arm
state_check_stale() {
  local sid=$1
  local pointer
  pointer=$(state_active_pointer_for "$sid")
  if [ ! -e "$pointer" ]; then
    printf 'no_active\n'; return 0
  fi
  local prior_path
  prior_path=$(cat "$pointer" 2>/dev/null)
  if [ -z "$prior_path" ] || [ ! -r "$prior_path" ]; then
    printf 'stale\n'; return 0
  fi
  local prior_pid prior_target
  prior_pid=$(state_read "$prior_path" .script_pid 2>/dev/null) || { printf 'stale\n'; return 0; }
  prior_target=$(state_read "$prior_path" .target_epoch 2>/dev/null) || { printf 'stale\n'; return 0; }
  if ! kill -0 "$prior_pid" 2>/dev/null; then
    printf 'stale\n'; return 0
  fi
  local cmd
  cmd=$(ps -p "$prior_pid" -o command= 2>/dev/null)
  # Use case-glob instead of pipe-into-grep to avoid the SIGPIPE-vs-pipefail
  # bug class. See lib/osa.sh osa_contents_has_prompt for the full
  # explanation and tests/test_sigpipe_regression.sh for the regression.
  case "$cmd" in
    *claude-later*) ;;
    *) printf 'stale\n'; return 0 ;;
  esac
  printf 'live %s %s\n' "$prior_pid" "$prior_target"
}
