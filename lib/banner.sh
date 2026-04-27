#!/bin/bash
# claude-later/lib/banner.sh — render the ARMED banner.
#
# Reads globals populated during pre-flight (CL_TARGET_EPOCH, CL_PANE_ID,
# CL_ITERM_VERSION, CL_CLAUDE_VERSION, CL_CLAUDE_ARGS_ARR, CL_RESUME_NAME_RESOLUTION,
# ARG_MESSAGE, CL_LOG_PATH, CL_STATE_PATH, ARG_NO_CAFFEINATE, ITERM_SESSION_ID).
# Also reads the preflight registry via cl_pf_passed_labels.

cl_banner_render() {
  local now delta passed count
  now=$(date +%s)
  delta=$((CL_TARGET_EPOCH - now))
  passed=$(cl_pf_passed_labels)
  count=$(printf '%s' "$passed" | awk 'NF' | wc -l | tr -d ' ')

  printf '\n'
  printf '\033[32m✓ claude-later ARMED\033[0m\n'
  printf '  Fire time : %s\n' "$(wall_clock_for_epoch "$CL_TARGET_EPOCH")"
  printf '              %s from now\n' "$(delta_human "$delta")"
  printf '  Pane      : %s (UUID %s)\n' "$CL_PANE_ID" "${ITERM_SESSION_ID#*:}"
  printf '  iTerm2    : %s\n' "$CL_ITERM_VERSION"
  printf '  claude    : %s\n' "$CL_CLAUDE_VERSION"
  if [ ${#CL_CLAUDE_ARGS_ARR[@]} -gt 0 ]; then
    printf '  Invocation: claude'
    local arg
    for arg in "${CL_CLAUDE_ARGS_ARR[@]}"; do printf ' %q' "$arg"; done
    printf '\n'
    if [ -n "$CL_RESUME_NAME_RESOLUTION" ]; then
      printf '              (resolved --resume-name %s)\n' "$CL_RESUME_NAME_RESOLUTION"
    fi
  else
    printf '  Invocation: claude (no passthrough args)\n'
  fi
  printf '  Message   : %q (%d chars)\n' "$ARG_MESSAGE" "${#ARG_MESSAGE}"
  printf '  PID       : %d\n' "$$"
  printf '  Log       : %s\n' "$CL_LOG_PATH"
  printf '  State     : %s\n' "$CL_STATE_PATH"
  if [ "$ARG_NO_CAFFEINATE" -eq 0 ]; then
    printf '  Caffeinate: active\n'
  else
    printf '  Caffeinate: DISABLED (--no-caffeinate)\n'
  fi

  printf '\n  Verified now (%d checks passed):\n' "$count"
  local label
  printf '%s\n' "$passed" | while IFS= read -r label; do
    [ -n "$label" ] && printf '    ✓ %s\n' "$label"
  done

  printf '\n  Residual risks (cannot defend against):\n'
  printf '    ⚠ iTerm2 window close → cancelled (tombstone + notification)\n'
  printf '    ⚠ Reboot / kernel panic → job lost\n'
  printf '    ⚠ Laptop lid close → caffeinate cannot prevent clamshell sleep\n'

  printf '\n'
  printf '  \033[33mDO NOT close this iTerm2 window. Closing it cancels the job.\033[0m\n'
  printf '\n'
}
