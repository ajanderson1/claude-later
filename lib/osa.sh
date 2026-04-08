#!/bin/bash
# claude-later/lib/osa.sh — iTerm2 scripting wrappers.
#
# Per Unit 0 spike #1: iTerm2's `id of session` is the UUID portion of
# $ITERM_SESSION_ID only (the wXtYpZ: prefix is iTerm2's positional path
# and is NOT a valid scripting key). The flat `tell session id "..."` form
# does NOT work — every wrapper must walk the windows -> tabs -> sessions
# hierarchy.
#
# All user-controlled values are passed via `osascript - "$arg" "$arg2" …`
# with `on run argv` to avoid AppleScript injection.
#
# Error surfacing: osascript stderr carries the actionable information when
# something goes wrong — most importantly, "Not authorized to send Apple
# events to iTerm2" (System Settings → Privacy & Security → Automation). We
# capture that stderr and, on failure, emit it to the shared last-error sink
# so the caller can log it or abort with a helpful message.

# _OSA_LAST_ERR is populated by every wrapper on failure with the raw
# osascript stderr. Read it via osa_last_error().
_OSA_LAST_ERR=""

osa_last_error() {
  printf '%s' "${_OSA_LAST_ERR:-}"
}

# _osa_classify_error "$stderr"
# Echo a one-line hint for common, recoverable osascript failures.
_osa_classify_error() {
  local err=$1
  case "$err" in
    *"Not authorized to send Apple events"*|*"not authorized"*|*"-1743"*)
      printf 'iTerm2 automation permission denied — grant access in System Settings → Privacy & Security → Automation → Terminal (or your parent app) → iTerm2.\n';;
    *"Application isn’t running"*|*"-600"*)
      printf 'iTerm2 is not running.\n';;
    *"Can’t get"*|*"-1728"*)
      printf 'iTerm2 session UUID not found (pane may have been closed).\n';;
    *"execution error"*)
      printf 'AppleScript execution error: %s\n' "$err";;
    "")
      printf '(no stderr from osascript)\n';;
    *)
      printf '%s\n' "$err";;
  esac
}

# osa_session_uuid
# Echo the UUID portion of $ITERM_SESSION_ID (strip the wXtYpZ: prefix).
# Reads from arg or, if absent, from $ITERM_SESSION_ID.
osa_session_uuid() {
  local sid=${1:-${ITERM_SESSION_ID:-}}
  if [ -z "$sid" ]; then return 1; fi
  printf '%s' "${sid#*:}"
}

# osa_get_session_name "$uuid"
# Echo the iTerm2 session name. Returns 1 if not found.
osa_get_session_name() {
  local uuid=$1
  local r errfile
  errfile=$(mktemp -t claude-later-osa.XXXXXX) || return 1
  r=$(osascript - "$uuid" <<'OSA' 2>"$errfile"
on run argv
  set targetUUID to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as string) is targetUUID then
            return name of s
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "__NOT_FOUND__"
end run
OSA
  )
  _OSA_LAST_ERR=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  if [ "$r" = "__NOT_FOUND__" ] || [ -z "$r" ]; then return 1; fi
  printf '%s\n' "$r"
}

# osa_get_contents "$uuid"
# Echo the rendered text of the iTerm2 pane. Returns 1 if not found.
# When $CL_OSA_CONTENTS_TAIL is set to an integer N>0, the AppleScript returns
# only the last N lines of the session contents (efficiency: avoids hashing
# huge scrollbacks every poll — see hardening (C)).
osa_get_contents() {
  local uuid=$1
  local tail_n=${CL_OSA_CONTENTS_TAIL:-0}
  local r errfile
  errfile=$(mktemp -t claude-later-osa.XXXXXX) || return 1
  r=$(osascript - "$uuid" "$tail_n" <<'OSA' 2>"$errfile"
on run argv
  set targetUUID to item 1 of argv
  set tailN to (item 2 of argv) as integer
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as string) is targetUUID then
            set allText to (contents of s)
            if tailN is less than or equal to 0 then
              return allText
            end if
            -- Return only the last tailN newline-delimited lines.
            set AppleScript's text item delimiters to linefeed
            set lineList to text items of allText
            set totalLines to count of lineList
            if totalLines <= tailN then
              return allText
            end if
            set startIdx to totalLines - tailN + 1
            set sliceList to items startIdx thru totalLines of lineList
            set tailText to sliceList as text
            set AppleScript's text item delimiters to ""
            return tailText
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "__NOT_FOUND__"
end run
OSA
  )
  _OSA_LAST_ERR=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  if [ "$r" = "__NOT_FOUND__" ]; then return 1; fi
  printf '%s' "$r"
}

# osa_write_text "$uuid" "$text"
# Type a string into the pane via iTerm2's native scripting (NOT System Events
# keystrokes). With `newline YES`, the trailing newline submits the line.
# Per Unit 0 spike #5: this delivers as keyboard input into Claude Code's TUI
# input box (not as bracketed paste) and Enter is honored.
osa_write_text() {
  local uuid=$1
  local text=$2
  local r errfile
  errfile=$(mktemp -t claude-later-osa.XXXXXX) || return 1
  r=$(osascript - "$uuid" "$text" <<'OSA' 2>"$errfile"
on run argv
  set targetUUID to item 1 of argv
  set msgText to item 2 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as string) is targetUUID then
            tell s
              write text msgText newline YES
            end tell
            return "OK"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "__NOT_FOUND__"
end run
OSA
  )
  _OSA_LAST_ERR=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  if [ "$r" = "OK" ]; then return 0; fi
  return 1
}

# osa_write_ctrl_u "$uuid"
# Send a bare Ctrl+U (ASCII NAK, 0x15) into the pane with NO newline. This is
# a kill-line-backward control code: in Claude Code's TUI (and most readline-
# style input boxes) it clears whatever is currently in the input buffer,
# ensuring the next typed message lands into an empty field. Used by the
# helper as defense-in-depth against residual pty bytes.
osa_write_ctrl_u() {
  local uuid=$1
  local nak=$'\025'
  local r errfile
  errfile=$(mktemp -t claude-later-osa.XXXXXX) || return 1
  r=$(osascript - "$uuid" "$nak" <<'OSA' 2>"$errfile"
on run argv
  set targetUUID to item 1 of argv
  set ctrlU to item 2 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as string) is targetUUID then
            tell s
              write text ctrlU newline NO
            end tell
            return "OK"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "__NOT_FOUND__"
end run
OSA
  )
  _OSA_LAST_ERR=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  [ "$r" = "OK" ]
}

# osa_session_alive "$uuid"
# Returns 0 if the session id resolves to a live iTerm2 session.
osa_session_alive() {
  local uuid=$1
  local r errfile
  errfile=$(mktemp -t claude-later-osa.XXXXXX) || return 1
  r=$(osascript - "$uuid" <<'OSA' 2>"$errfile"
on run argv
  set targetUUID to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s as string) is targetUUID then
            return "ALIVE"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "DEAD"
end run
OSA
  )
  _OSA_LAST_ERR=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  [ "$r" = "ALIVE" ]
}

# osa_iterm_version
# Echo the running iTerm2 version string.
osa_iterm_version() {
  local r errfile
  errfile=$(mktemp -t claude-later-osa.XXXXXX) || return 1
  r=$(osascript -e 'tell application "iTerm2" to version' 2>"$errfile")
  _OSA_LAST_ERR=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

# osa_contents_hash "$uuid"
# Echo an md5 hash of the current pane contents. Used by the helper's
# stable-hash readiness detector.
osa_contents_hash() {
  local uuid=$1
  osa_get_contents "$uuid" | md5
}

# osa_contents_has_prompt "$uuid"
# Returns 0 if the pane contents include the steady-state Claude Code prompt
# glyph (the heavy right-pointing angle quotation mark, U+276F). This is the
# defense-in-depth secondary check from Unit 0 spike #3.
#
# IMPORTANT: do NOT use a pipe (`osa_get_contents | grep`) here. Under
# `set -uo pipefail` (which both claude-later and claude-later-helper use),
# a pipeline where grep finds an early match and exits before the upstream
# finishes writing causes the upstream to receive SIGPIPE (rc=141), which
# pipefail then propagates as the pipeline's rc. The result: the function
# returns "false" even when the glyph is present, but only on panes with
# large scrollbacks (small panes finish their write in one syscall and
# never trip SIGPIPE). This was a real production bug masked by the live
# test pane being small enough to avoid the trigger condition.
osa_contents_has_prompt() {
  local uuid=$1
  local contents
  contents=$(osa_get_contents "$uuid") || return 1
  case "$contents" in
    *❯*) return 0 ;;
    *) return 1 ;;
  esac
}

# osa_contents_has_spinner "$uuid"
# Returns 0 if the pane contains Claude Code's live busy-state indicator.
#
# Claude Code's busy indicator has the form:
#   <cycling-glyph> <Verb>… (<elapsed-time> · <arrow> <N>k tokens)
# where:
#   - cycling-glyph rotates through ✢ ✻ · ⏺ ✺ ⊛ ✳ etc every ~100ms
#   - Verb rotates per-turn through Working, Thinking, Pontificating,
#     Seasoning, Musing, Cooking, Germinating, Simmering, Stewing, ...
#   - elapsed-time ticks every second (`12s`, `2m 30s`, etc.)
#   - arrow is ↓ (input) or ↑ (output) plus a tokens counter
#
# The only element that is ~always present for a busy claude is the
# parenthesized `(Xs · ↓ N tokens)` or `(Xm Ys · ↑ N tokens)` pattern —
# all other pieces vary. That's our signal. Idle claude never shows this.
#
# Used by the helper as a fast-path positive-idle check: if `❯` is present
# AND this spinner check is FALSE, claude is definitively idle-waiting.
#
# Same pipefail/SIGPIPE caveat as osa_contents_has_prompt — capture into a
# variable, then grep against the variable.
osa_contents_has_spinner() {
  local uuid=$1
  local contents
  contents=$(osa_get_contents "$uuid") || return 1
  # Use bash case-glob with the spinner pattern. We can't use a regex but
  # we can match the load-bearing fragment: a parenthesized "Xs · ↓" or
  # "Xm Ys · ↑" pattern. Glob patterns can do this with a few carefully
  # ordered cases.
  case "$contents" in
    *"s · ↓"*tokens*) return 0 ;;
    *"s · ↑"*tokens*) return 0 ;;
    *) return 1 ;;
  esac
}

# osa_contents_is_idle "$uuid"
# Returns 0 iff the pane contains `❯` AND does NOT contain a busy spinner.
# This is the "definitively idle and ready to accept input" signal used by
# the helper's readiness detector fast path.
osa_contents_is_idle() {
  local uuid=$1
  local contents
  contents=$(osa_get_contents "$uuid") || return 1
  # Must contain the ❯ glyph
  case "$contents" in
    *❯*) ;;
    *) return 1 ;;
  esac
  # Must NOT contain a busy spinner (same case-glob pattern as
  # osa_contents_has_spinner).
  case "$contents" in
    *"s · ↓"*tokens*) return 1 ;;
    *"s · ↑"*tokens*) return 1 ;;
  esac
  return 0
}
