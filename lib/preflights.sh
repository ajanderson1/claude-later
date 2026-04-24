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
