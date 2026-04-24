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

cl_pf_3_time_parsing() {
  if [ -n "$ARG_AT" ] && [ -n "$ARG_IN" ]; then
    abort "specify exactly one of --at or --in" 64
  fi
  if [ -z "$ARG_AT" ] && [ -z "$ARG_IN" ]; then
    abort "must specify either --at or --in" 64
  fi
  if [ -n "$ARG_AT" ]; then
    CL_TARGET_EPOCH=$(parse_at "$ARG_AT") || abort "invalid --at value: $ARG_AT (DST gap, past time, or unparseable)" 64
  else
    local secs
    secs=$(parse_in "$ARG_IN") || abort "invalid --in value: $ARG_IN" 64
    CL_TARGET_EPOCH=$(( $(date +%s) + secs ))
  fi
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 3 "--at / --in parses to a valid future time" cl_pf_3_time_parsing
fi

cl_pf_4_claude_args() {
  CL_CLAUDE_ARGS_ARR=()
  if [ -z "$ARG_CLAUDE_ARGS" ]; then return 0; fi

  # Rail 1: input sanitation
  local nl_count
  nl_count=$(printf '%s' "$ARG_CLAUDE_ARGS" | awk 'END{print NR}')
  if [ "$nl_count" -gt 1 ]; then
    abort "--claude-args must be a single line (no embedded newlines)" 64
  fi
  if printf '%s' "$ARG_CLAUDE_ARGS" | LC_ALL=C grep -q '[^[:print:]]'; then
    abort "--claude-args contains non-printable characters" 64
  fi
  case "$ARG_CLAUDE_ARGS" in
    *\'*) abort "--claude-args must not contain single quotes (word-splitting is whitespace-only; quoted values are not honored)" 64 ;;
    *\"*) abort "--claude-args must not contain double quotes (word-splitting is whitespace-only; quoted values are not honored)" 64 ;;
  esac

  # Word-split into a bash array. IFS default is fine — whitespace only.
  # shellcheck disable=SC2206  # intentional word-splitting
  local tokens=($ARG_CLAUDE_ARGS)

  # Allowlist: sub-flags permitted. Each entry: the flag name (canonical or
  # short form). `takes_value` means the next token is the flag's argument
  # and should be consumed together.
  #
  # We use a pair of parallel case statements rather than associative arrays
  # because bash 3.2 (macOS system bash) doesn't have associative arrays.
  _is_allowed_flag() {
    case "$1" in
      --resume|-r) return 0 ;;
      --resume-name) return 0 ;;  # claude-later synthetic: resolves to --resume UUID at arm time
      --continue|-c) return 0 ;;
      --model) return 0 ;;
      --teammate-mode) return 0 ;;
      --agent) return 0 ;;
      --effort) return 0 ;;
      --permission-mode) return 0 ;;
      --name|-n) return 0 ;;
      --append-system-prompt) return 0 ;;
      --system-prompt) return 0 ;;
      --fork-session) return 0 ;;
      --add-dir) return 0 ;;
      --mcp-config) return 0 ;;
      --settings) return 0 ;;
      *) return 1 ;;
    esac
  }
  _flag_takes_value() {
    case "$1" in
      --continue|-c|--fork-session) return 1 ;;  # boolean, no value
      --resume|-r|--resume-name|--model|--teammate-mode|--agent|--effort|\
      --permission-mode|--name|-n|--append-system-prompt|--system-prompt|\
      --add-dir|--mcp-config|--settings) return 0 ;;
      *) return 1 ;;
    esac
  }
  _blocked_flag_reason() {
    case "$1" in
      -p|--print) printf 'headless mode defeats the whole point of claude-later' ;;
      -h|--help) printf '--help exits before any TUI is drawn' ;;
      -v|--version) printf '--version exits before any TUI is drawn' ;;
      --bare) printf 'skips CLAUDE.md, hooks, plugins — surprising behaviour at fire time' ;;
      --dangerously-skip-permissions|--allow-dangerously-skip-permissions)
        printf 'security-sensitive; must be explicit at arm time, not via passthrough' ;;
      -d|--debug|--debug-file) printf 'debug output breaks TUI rendering' ;;
      -w|--worktree) printf 'creates a new worktree, changes cwd at fire time and violates the first-run hygiene pre-flight' ;;
      --session-id) printf 'fixed session IDs conflict with fresh-session assumptions' ;;
      *) printf '' ;;
    esac
  }

  # Upfront conflict check for resume-family flags. We do this BEFORE the
  # main state machine loop so we can fail fast on conflict without
  # triggering the (potentially slow) --resume-name resolver.
  #
  # Two resume-family flags are handled specially:
  #   --resume UUID       — passed through verbatim, UUID validated + transcript checked
  #   --resume-name NAME  — synthetic; resolved to a UUID at arm time, then REWRITTEN
  #                         to `--resume <resolved-uuid>` in the output array. The
  #                         synthetic flag never reaches the claude exec.
  # Using BOTH in the same --claude-args is an error (they target the same thing).
  local _tc_resume=0
  local _tc_resume_name=0
  local _j
  for (( _j=0; _j<${#tokens[@]}; _j++ )); do
    case "${tokens[$_j]}" in
      --resume|-r) _tc_resume=$((_tc_resume + 1)) ;;
      --resume-name) _tc_resume_name=$((_tc_resume_name + 1)) ;;
    esac
  done
  if [ "$_tc_resume" -gt 0 ] && [ "$_tc_resume_name" -gt 0 ]; then
    abort "--claude-args: cannot use both --resume-name and --resume in the same invocation" 64
  fi
  if [ "$_tc_resume_name" -gt 1 ]; then
    abort "--claude-args: --resume-name may only appear once" 64
  fi

  local saw_resume=0
  local saw_resume_name=0
  local i=0
  local n=${#tokens[@]}
  while [ "$i" -lt "$n" ]; do
    local tok=${tokens[$i]}
    case "$tok" in
      -*)
        # Check blocklist FIRST — blocked flags give a more specific error
        # than "not in allowlist".
        local reason
        reason=$(_blocked_flag_reason "$tok")
        if [ -n "$reason" ]; then
          abort "--claude-args: blocked sub-flag '$tok': $reason" 64
        fi
        # Check allowlist
        if ! _is_allowed_flag "$tok"; then
          abort "--claude-args: sub-flag '$tok' is not in the allowlist (see --help for the full list)" 64
        fi
        # Does it consume the next token?
        if _flag_takes_value "$tok"; then
          i=$((i + 1))
          if [ "$i" -ge "$n" ]; then
            abort "--claude-args: sub-flag '$tok' requires a value but none was provided" 64
          fi
          local val=${tokens[$i]}
          # The value token must not itself start with `-` — that would be
          # the user forgetting the value and the next flag getting
          # consumed. This IS possible for flags whose value is a flag-like
          # string (rare) but we prefer false-positives here over silent
          # mis-parsing.
          case "$val" in
            -*) abort "--claude-args: sub-flag '$tok' requires a value; got another flag-like token '$val'" 64 ;;
          esac

          # Resume family — conflict check and special handling
          if [ "$tok" = "--resume" ] || [ "$tok" = "-r" ]; then
            if [ "$saw_resume_name" -eq 1 ]; then
              abort "--claude-args: cannot use both --resume-name and --resume in the same invocation" 64
            fi
            saw_resume=1
            # Validate UUID regex + check transcript
            if ! [[ "$val" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
              abort "--claude-args: --resume value must be a UUID (got '$val')" 64
            fi
            local cwd_slug
            cwd_slug=$(printf '%s' "$PWD" | sed -e 's|/|-|g' -e 's|_|-|g')
            local transcript="$HOME/.claude/projects/-${cwd_slug#-}/${val}.jsonl"
            if [ ! -r "$transcript" ]; then
              printf 'claude-later: warning: --resume transcript not found at %s (will try anyway)\n' "$transcript" >&2
            fi
            CL_CLAUDE_ARGS_ARR+=("$tok" "$val")
          elif [ "$tok" = "--resume-name" ]; then
            if [ "$saw_resume" -eq 1 ]; then
              abort "--claude-args: cannot use both --resume-name and --resume in the same invocation" 64
            fi
            if [ "$saw_resume_name" -eq 1 ]; then
              abort "--claude-args: --resume-name may only appear once" 64
            fi
            saw_resume_name=1
            # Resolve the name to a UUID. _resolve_resume_name aborts on
            # zero matches / multi-match; on success it echoes the UUID.
            local resolved_uuid
            resolved_uuid=$(_resolve_resume_name "$val") || exit 1
            # Record the resolution for the banner
            CL_RESUME_NAME_RESOLUTION="$val -> $resolved_uuid"
            # Rewrite: the synthetic --resume-name becomes a real --resume UUID
            # in the output array that gets exec'd into claude.
            CL_CLAUDE_ARGS_ARR+=("--resume" "$resolved_uuid")
          else
            # Normal pass-through (non-resume-family flag with value)
            CL_CLAUDE_ARGS_ARR+=("$tok" "$val")
          fi
        else
          # Flag with no value (boolean flag)
          CL_CLAUDE_ARGS_ARR+=("$tok")
        fi
        ;;
      *)
        abort "--claude-args: unexpected non-flag token '$tok' (all tokens must be flags or flag values)" 64
        ;;
    esac
    i=$((i + 1))
  done
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 4 "--claude-args validated against allowlist / blocklist" cl_pf_4_claude_args
fi

cl_pf_5_message_content() {
  if [ -z "$ARG_MESSAGE" ]; then
    abort "message is required (trailing positional argument)" 64
  fi
  # Reject embedded newlines (single-line only). Use awk for portability across
  # bash 3.2 quirks with $'\n' inside grep patterns.
  local nl_count
  nl_count=$(printf '%s' "$ARG_MESSAGE" | awk 'END{print NR}')
  if [ "$nl_count" -gt 1 ]; then
    abort "message must be a single line (no embedded newlines)" 64
  fi
  # Reject other control characters (not newline since we already checked above,
  # but still block tabs, escape, NUL, etc. — printable + space only).
  # Pipe-into-grep is safe here because $ARG_MESSAGE is bounded to a single
  # line (the multi-line check above guarantees it) — well under pipe buffer
  # size, so the SIGPIPE-vs-pipefail bug class can't trigger.
  if printf '%s' "$ARG_MESSAGE" | LC_ALL=C grep -q '[^[:print:]]'; then
    abort "message contains non-printable characters" 64
  fi
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 5 "message is single-line, printable, non-empty" cl_pf_5_message_content
fi

cl_pf_6_silent_probe_secure_input() {
  # Resolve $ITERM_SESSION_ID via the scripting dictionary as a read-only check
  local uuid="${ITERM_SESSION_ID#*:}"
  if ! osa_session_alive "$uuid"; then
    local hint
    hint=$(_osa_classify_error "$(osa_last_error)")
    abort "iTerm2 scripting cannot resolve current session id (UUID=$uuid): $hint" 1
  fi
  # Secure Input check
  if sec_input_engaged; then
    abort "Secure Input is currently engaged (1Password unlock, lock screen, etc.). Wait for it to clear and try again." 1
  fi
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 6 "iTerm2 scripting reachable; Secure Input not engaged" cl_pf_6_silent_probe_secure_input
fi

cl_pf_8_power_sleep() {
  # Detect AC power
  local power
  power=$(pmset -g ps 2>/dev/null | head -1)
  # Case-glob instead of pipe-into-grep — see SIGPIPE-vs-pipefail bug class.
  case "$power" in
    *"Battery Power"*|*"battery power"*)
      if [ "$ARG_ALLOW_BATTERY" -eq 0 ]; then
        abort "on battery power. Plug in, or pass --allow-battery to override." 1
      fi
      printf 'claude-later: warning: on battery and --allow-battery is set; the Mac may sleep.\n' >&2
      ;;
  esac
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 8 "on AC power (or --allow-battery set)" cl_pf_8_power_sleep
fi

cl_pf_9_state_file() {
  state_dir_init || abort "cannot initialize ~/.claude-later/" 1
  CL_ARMED_AT_EPOCH=$(date +%s)
  CL_STATE_PATH=$(state_path_for "$ITERM_SESSION_ID" "$CL_ARMED_AT_EPOCH")
  CL_ACTIVE_PTR=$(state_active_pointer_for "$ITERM_SESSION_ID")
  local stale
  stale=$(state_check_stale "$ITERM_SESSION_ID")
  case "$stale" in
    no_active|stale)
      : # safe to arm
      ;;
    live*)
      abort "another claude-later is already armed in this pane: $stale" 1
      ;;
  esac
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 9 "no other claude-later armed in this pane" cl_pf_9_state_file
fi

cl_pf_10_logs() {
  CL_LOG_PATH="$CL_LOGS_ROOT/$(date +%Y-%m-%dT%H-%M-%S).log"
  log_init "$CL_LOG_PATH" || abort "cannot open log file at $CL_LOG_PATH" 1
  log_event "armed cwd=$PWD pane=$ITERM_SESSION_ID claude=$CL_CLAUDE_VERSION iterm=$CL_ITERM_VERSION target=$CL_TARGET_EPOCH"
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 10 "log file writable" cl_pf_10_logs
fi

cl_pf_12_first_run_hygiene() {
  local cwd_slug
  cwd_slug=$(printf '%s' "$PWD" | sed -e 's|/|-|g' -e 's|_|-|g')
  local proj_dir="$HOME/.claude/projects/-${cwd_slug#-}"
  if [ ! -d "$proj_dir" ]; then
    abort "first-run hygiene: \`claude\` has not run in this directory yet. Run \`claude\` once interactively first to clear any trust-folder/setup prompts. (looked for: $proj_dir)" 1
  fi

  # MCP auth check — see SPIKE.md spike #8
  if [ "$ARG_SKIP_MCP_CHECK" -eq 1 ]; then
    return 0
  fi
  local mcp_cache="$HOME/.claude/mcp-needs-auth-cache.json"
  if [ -s "$mcp_cache" ]; then
    local needs
    needs=$(jq 'length' "$mcp_cache" 2>/dev/null || echo "0")
    if [ "$needs" != "0" ] && [ "$needs" != "" ]; then
      local servers
      servers=$(jq -r 'keys | join(", ")' "$mcp_cache" 2>/dev/null)
      abort "MCP servers need interactive auth: $servers. Run \`claude\` once interactively to complete authentication, then retry." 1
    fi
  fi
}

if [ "${CL_PF_AUTOREGISTER:-0}" = "1" ]; then
  cl_pf_register 12 "claude first-run hygiene; no MCP auth pending" cl_pf_12_first_run_hygiene
fi
