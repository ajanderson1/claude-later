#!/bin/bash
# claude-later/lib/interactive.sh — scheduling wizard.
#
# Contract: the wizard asks four questions plus confirmation. On confirmation
# it populates ARG_AT or ARG_IN, ARG_CLAUDE_ARGS, and ARG_MESSAGE as if the
# user had typed the equivalent flag invocation. The normal arm flow runs
# unchanged after the wizard returns.
#
# Abort sentinel: typing "!abort" at any prompt exits 0 cleanly.

_cl_iw_read() {
  # Read one line of user input from stdin. Strips CR. Returns 1 on EOF.
  local prompt=$1
  local _var=$2
  printf '%s' "$prompt" >&2
  local IFS= line
  if ! IFS= read -r line; then return 1; fi
  if [ "$line" = "!abort" ]; then
    printf '\nclaude-later: wizard aborted\n' >&2
    exit 0
  fi
  eval "$_var=\$line"
}

# cl_list_renamed_sessions DIR
# Echo one line per /rename'd session in DIR: "NAME<TAB>UUID"
cl_list_renamed_sessions() {
  local dir=$1
  [ -d "$dir" ] || return 0
  local f name uuid
  for f in "$dir"/*.jsonl; do
    [ -r "$f" ] || continue
    name=$(grep -o '"customTitle":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"customTitle":"\([^"]*\)".*/\1/')
    [ -n "$name" ] || continue
    uuid=$(basename "$f" .jsonl)
    printf '%s\t%s\n' "$name" "$uuid"
  done
}

# cl_resolve_session_name DIR NAME
# Echo the UUID whose /rename'd name exactly matches NAME. Returns 1 on zero
# or multi match.
cl_resolve_session_name() {
  local dir=$1 want=$2
  local matches
  matches=$(cl_list_renamed_sessions "$dir" | awk -F'\t' -v n="$want" '$1==n {print $2}')
  local count
  count=$(printf '%s' "$matches" | awk 'NF' | wc -l | tr -d ' ')
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$matches"
    return 0
  fi
  return 1
}

# cl_wizard_run
# Populates ARG_AT/ARG_IN, ARG_CLAUDE_ARGS, ARG_MESSAGE. Caller then enters
# the normal arm flow as if the flags had been passed.
cl_wizard_run() {
  local input
  printf '\nclaude-later interactive wizard (type !abort at any prompt to quit)\n\n' >&2

  # Q1: when
  while :; do
    _cl_iw_read '  When should it fire? (e.g. 4h, 06:30, 2026-04-25 03:00): ' input || exit 0
    if parse_in "$input" >/dev/null 2>&1; then
      ARG_IN="$input"
      local secs
      secs=$(parse_in "$input")
      printf '    -> fires %s (in %s)\n\n' \
        "$(wall_clock_for_epoch "$(( $(date +%s) + secs ))")" \
        "$(delta_human "$secs")" >&2
      break
    elif parse_at "$input" >/dev/null 2>&1; then
      ARG_AT="$input"
      local ep
      ep=$(parse_at "$input")
      printf '    -> fires %s (in %s)\n\n' \
        "$(wall_clock_for_epoch "$ep")" \
        "$(delta_human "$(( ep - $(date +%s) ))")" >&2
      break
    else
      printf '    invalid time value: %s — try again\n' "$input" >&2
    fi
  done

  # Q2: resume
  local cwd_slug proj_dir
  cwd_slug=$(printf '%s' "$PWD" | sed -e 's|/|-|g' -e 's|_|-|g')
  proj_dir="$HOME/.claude/projects/-${cwd_slug#-}"
  local resume_arg=""
  local named_list
  named_list=$(cl_list_renamed_sessions "$proj_dir")
  while :; do
    _cl_iw_read '  Resume a previous Claude session? (y/N): ' input || exit 0
    case "$input" in
      ""|n|N|no|NO) break ;;
      y|Y|yes|YES) ;;
      f|F)
        # Back-compat: legacy "f" (fresh) still means no.
        break ;;
      *) printf '    answer with y or n (Enter for no)\n' >&2; continue ;;
    esac

    # User said yes — pick a session.
    while :; do
      if [ -n "$named_list" ]; then
        printf '    named sessions in this cwd (from /rename):\n' >&2
        printf '%s\n' "$named_list" | awk -F'\t' '{printf "      [%d] %s  (%s)\n", NR, $1, $2}' >&2
        _cl_iw_read '    Pick by number, type the exact name, or paste a UUID: ' input || exit 0
      else
        printf '    no /rename'"'"'d sessions found for this cwd (%s)\n' "$proj_dir" >&2
        _cl_iw_read '    Paste a Claude session UUID: ' input || exit 0
      fi
      [ -n "$input" ] || { printf '    enter a value or !abort to quit\n' >&2; continue; }

      # UUID? -> --resume
      if [[ "$input" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        resume_arg="--resume $input"
        break 2
      fi

      # Number? -> only valid when we have a list
      local chosen=""
      if [[ "$input" =~ ^[0-9]+$ ]] && [ -n "$named_list" ]; then
        chosen=$(printf '%s\n' "$named_list" | awk -F'\t' -v i="$input" 'NR==i {print $1}')
        [ -n "$chosen" ] || { printf '    no entry [%s] — try again\n' "$input" >&2; continue; }
      else
        chosen=$input
      fi

      # Resolve as name (only meaningful when we have a list).
      # We emit --resume <uuid> rather than --resume-name <name> because
      # --claude-args is whitespace-tokenised, so names containing spaces
      # would be unparseable downstream. The UUID is always safe.
      if [ -n "$named_list" ]; then
        local resolved
        if resolved=$(cl_resolve_session_name "$proj_dir" "$chosen"); then
          resume_arg="--resume $resolved"
          printf '    -> %s (%s)\n' "$chosen" "$resolved" >&2
          break 2
        fi
      fi
      printf '    no match for %s — paste a UUID or pick from the list\n' "$chosen" >&2
    done
  done

  # Q3: extra flags
  _cl_iw_read '  Any extra claude flags? (enter for none): ' input || exit 0
  local combined="$resume_arg $input"
  combined=$(printf '%s' "$combined" | sed -e 's/^ *//' -e 's/ *$//' -e 's/  */ /g')
  if [ -n "$combined" ]; then
    ARG_CLAUDE_ARGS="$combined"
    # Dry-run-validate by invoking pf_4 in a subshell so any abort does not kill us
    if ! ( ARG_CLAUDE_ARGS="$combined" pf_4_claude_args ) 2>/dev/null; then
      printf '    claude-args rejected — try the whole wizard again\n' >&2
      ARG_CLAUDE_ARGS=""
      cl_wizard_run
      return
    fi
  fi

  # Q4: message
  while :; do
    _cl_iw_read '  Your message (single line): ' input || exit 0
    ARG_MESSAGE="$input"
    if ( pf_5_message_content ) 2>/dev/null; then break; fi
    printf '    message rejected (empty, multi-line, or non-printable) — try again\n' >&2
    ARG_MESSAGE=""
  done

  # Confirmation — show the equivalent non-interactive command
  printf '\nThis is equivalent to running:\n' >&2
  local eqcmd="claude-later"
  [ -n "$ARG_AT" ] && eqcmd="$eqcmd --at \"$ARG_AT\""
  [ -n "$ARG_IN" ] && eqcmd="$eqcmd --in $ARG_IN"
  [ -n "$ARG_CLAUDE_ARGS" ] && eqcmd="$eqcmd --claude-args \"$ARG_CLAUDE_ARGS\""
  eqcmd="$eqcmd \"$ARG_MESSAGE\""
  printf '  %s\n\nProceed? [Y/n]: ' "$eqcmd" >&2
  _cl_iw_read '' input || exit 0
  case "$input" in
    n|N|no|NO)
      printf 'aborted\n' >&2
      exit 0
      ;;
  esac
}
