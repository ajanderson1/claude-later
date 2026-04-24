#!/bin/bash
# claude-later/lib/preflights.sh — preflight registry.
#
# The banner enumerates "what was verified now" by reading this registry,
# so adding/removing a preflight automatically keeps the banner in sync.
#
# Storage uses newline-separated parallel strings because bash 3.2 (macOS
# system bash) has no associative arrays.
#
#   CL_PF_REG       lines "slot|label|fn_name"
#   CL_PF_PASSED    lines "slot|label" recorded after each fn returns 0
#
# Public API:
#   cl_pf_registry_reset         — wipe both registers (for tests)
#   cl_pf_register SLOT LABEL FN — append an entry
#   cl_pf_list_labels            — labels in slot-sorted order, one per line
#   cl_pf_label_for SLOT         — look up the label for a slot
#   cl_pf_passed_labels          — labels of passed preflights, one per line
#   cl_pf_run_all                — iterate slots ascending, call FN, record pass; abort on first nonzero

CL_PF_REG=""
CL_PF_PASSED=""

cl_pf_registry_reset() {
  CL_PF_REG=""
  CL_PF_PASSED=""
}

cl_pf_register() {
  local slot=$1 label=$2 fn=$3
  CL_PF_REG="${CL_PF_REG}${slot}|${label}|${fn}
"
}

cl_pf_list_labels() {
  printf '%s' "$CL_PF_REG" | awk -F'|' 'NF==3 {print $1"\t"$2}' | sort -n | awk -F'\t' '{print $2}'
}

cl_pf_label_for() {
  local want=$1
  printf '%s' "$CL_PF_REG" | awk -F'|' -v s="$want" '$1==s {print $2; exit}'
}

cl_pf_passed_labels() {
  printf '%s' "$CL_PF_PASSED" | awk -F'|' 'NF==2 {print $1"\t"$2}' | sort -n | awk -F'\t' '{print $2}'
}

cl_pf_run_all() {
  local sorted
  sorted=$(printf '%s' "$CL_PF_REG" | awk -F'|' 'NF==3 {print $1"|"$2"|"$3}' | sort -n -t'|')
  local IFS_SAVE=$IFS
  local line
  IFS='
'
  for line in $sorted; do
    IFS=$IFS_SAVE
    local slot=${line%%|*}
    local rest=${line#*|}
    local label=${rest%%|*}
    local fn=${rest#*|}
    if "$fn"; then
      CL_PF_PASSED="${CL_PF_PASSED}${slot}|${label}
"
    else
      return 1
    fi
    IFS='
'
  done
  IFS=$IFS_SAVE
  return 0
}

# ---- Extracted preflight functions ------------------------------------------
# These are sourced into the main script. Each returns 0 on pass, nonzero on
# fail after calling `abort`. Behaviour must be byte-identical to the inline
# versions they replace in claude-later v0.2.1.

cl_pf_1_platform_terminal() {
  [ "$(uname -s)" = "Darwin" ] || abort "macOS only (uname=$(uname -s))" 1
  [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || abort "must be run from iTerm2 (TERM_PROGRAM=${TERM_PROGRAM:-unset})" 1
  [ -n "${ITERM_SESSION_ID:-}" ] || abort "ITERM_SESSION_ID is unset" 1
  [ -z "${TMUX:-}" ] || abort "claude-later does not support running inside tmux — keystroke targeting cannot be guaranteed" 1
  [ -z "${STY:-}" ] || abort "claude-later does not support running inside GNU screen" 1
  if ! [[ "$ITERM_SESSION_ID" =~ ^w[0-9]+t[0-9]+p[0-9]+:[0-9A-Fa-f-]{36}$ ]]; then
    abort "ITERM_SESSION_ID format unexpected: $ITERM_SESSION_ID" 1
  fi
  CL_PANE_ID="${ITERM_SESSION_ID%%:*}"
  CL_ITERM_VERSION=$(osa_iterm_version) || {
    local hint
    hint=$(_osa_classify_error "$(osa_last_error)")
    abort "cannot query iTerm2 via AppleScript: $hint" 1
  }
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 1 "macOS + iTerm2 + not in tmux" cl_pf_1_platform_terminal
fi

cl_pf_2_binaries() {
  command -v claude >/dev/null || abort "claude not on PATH" 1
  CL_CLAUDE_PATH=$(command -v claude)
  CL_CLAUDE_VERSION=$(claude --version 2>/dev/null) || abort "claude --version failed" 1
  command -v osascript >/dev/null || abort "osascript missing" 1
  command -v caffeinate >/dev/null || abort "caffeinate missing" 1
  command -v jq >/dev/null || abort "jq missing — install with: brew install jq" 1
  command -v swift >/dev/null || abort "swift missing — install Xcode CLI tools: xcode-select --install" 1
  command -v pmset >/dev/null || abort "pmset missing" 1
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 2 "claude + jq + swift + caffeinate + pmset present" cl_pf_2_binaries
fi
