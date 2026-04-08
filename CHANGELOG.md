# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] — 2026-04-08

### Added

- **`--resume-name NAME` synthetic sub-flag** inside `--claude-args`. Resolves
  a Claude Code session by its `/rename`'d display name at arm time: scans
  the current cwd's transcripts (`~/.claude/projects/-<cwd-slug>/*.jsonl`)
  for matching `customTitle` or `agentName` JSON events, extracts the
  session UUID, and rewrites the claude_args array to `--resume <uuid>`
  before firing. Exact match only; zero-match and multi-match both abort
  with specific error messages. Cannot be combined with `--resume`. The
  banner shows both the name and the resolved UUID so you see what fires.
  - Rationale: typing UUIDs for rate-limit recovery is annoying when you
    can `/rename` sessions to memorable names. This provides a
    name→UUID resolver without inventing a non-claude top-level flag.
- **9 new failure-mode tests** covering the `--resume-name` resolver:
  zero matches, multi-match, missing value, conflict with `--resume`,
  duplicate `--resume-name`, successful resolution (with synthetic test
  transcripts), and banner format assertions.

### Changed

- Conflict detection for `--resume` vs `--resume-name` now happens in a
  fast upfront pass over the token list, before the resolver runs. This
  ensures conflicts fail immediately with the right error regardless of
  which flag appears first in the string.

### Test count

- Unit: 143 → 152
- Integration: 9 (unchanged)
- Total: 152 → 161

## [0.2.0] — 2026-04-08

**Breaking:** the top-level `--resume UUID` flag is removed. Resume now lives
inside the new `--claude-args` transparent passthrough.

### Changed (BREAKING)

- **`--resume UUID` removed as a top-level flag.** Pass it through
  `--claude-args` instead:
  ```sh
  # Old (v0.1.x):
  claude-later --in 30m --resume 7f3a4c12-... "continue"
  # New (v0.2.0):
  claude-later --in 30m --claude-args "--resume 7f3a4c12-0000-4000-8000-000000000000" "continue"
  ```
  The resume UUID is still validated against the UUID regex at arm time
  (with transcript-existence best-effort check), just inside the
  `--claude-args` validator instead of a dedicated pre-flight.
- **State file schema bumped to v2.** `resume_id` field removed;
  `claude_args` JSON array added. State files are per-run ephemeral and
  don't persist across arms, so no migration is needed for existing users.

### Added

- **`--claude-args "..."`** transparent passthrough for claude sub-flags.
  Whitespace-separated string, validated at arm time against both an
  allowlist and a blocklist, with explicit error messages for every
  rejection reason.
  - **Allowlist**: `--resume`/`-r`, `--continue`/`-c`, `--model`,
    `--teammate-mode`, `--agent`, `--effort`, `--permission-mode`,
    `--name`/`-n`, `--append-system-prompt`, `--system-prompt`,
    `--fork-session`, `--add-dir`, `--mcp-config`, `--settings`.
  - **Blocklist** (with explicit rejection reason): `-p`/`--print`,
    `-h`/`--help`, `-v`/`--version`, `--bare`,
    `--dangerously-skip-permissions`, `-d`/`--debug`/`--debug-file`,
    `-w`/`--worktree`, `--session-id`.
  - Single and double quote characters inside `--claude-args` are rejected
    (word-splitting is whitespace-only; quoted values would silently
    mis-parse).
- **Banner now shows `Invocation: claude <args>`** — the effective claude
  command line as it will be exec'd at fire time. Replaces the
  `Resume: (fresh session) / Resume: <uuid>` line.
- **18 new failure-mode tests** in `test_failure_modes.sh` covering the
  `--claude-args` allowlist/blocklist/sanitation.
- **7 new state-file tests** in `test_state_file.sh` covering schema v2
  (`schema_version: 2`, `claude_args` array, removal of `resume_id`).

### Test count

- Unit: 120 → 143
- Integration: 9 (unchanged)
- Total: 129 → 152

### Migration notes

If you have shell aliases or scripts that invoke `claude-later --resume
UUID`, rewrite them as `claude-later --claude-args "--resume UUID"`. The
error message at arm time is specific: running the old syntax gives
"unknown flag: --resume" so the breakage is loud and obvious.

For users whose `cc` function wraps claude with `--teammate-mode tmux`,
a convenience wrapper is easy:

```sh
cc_later() {
  claude-later --claude-args "--teammate-mode tmux" "$@"
}
```

## [0.1.1] — 2026-04-08

Bugfix release. One critical fix in the helper's load-bearing readiness signal.

### Fixed

- **SIGPIPE-vs-pipefail bug in `osa_contents_has_prompt`**: under `set -uo
  pipefail` (which both `claude-later` and `claude-later-helper` use), the
  `osa_get_contents | grep -q '❯'` pattern returned false when the upstream
  output exceeded the pipe buffer (~64KB) because grep would find the match
  early, exit, and the upstream's next write would receive SIGPIPE (rc=141)
  which `pipefail` propagates as the pipeline rc. The bug only triggered on
  panes with large scrollbacks; small panes' single-syscall writes never
  tripped it — which is why v0.1.0's live test succeeded. Fixed by capturing
  contents into a variable and using bash case-glob instead of pipe-and-grep.
  Same fix applied to `state_check_stale` and `pf_8_power_sleep` for
  consistency, even though those weren't likely to encounter the trigger
  condition.

### Added

- `osa_contents_has_spinner` and `osa_contents_is_idle` in `lib/osa.sh`:
  positive-idle detection that recognises Claude Code's busy-state indicator
  (`(Xs · ↓ N tokens)` pattern) and inverts it. The helper's readiness
  detector now uses `is_idle` as a fast path before falling back to the
  hash-stability check, eliminating a class of "spinner-active at fire time"
  failures where the hash would never stabilise within the 60s budget.
- `tests/test_sigpipe_regression.sh` (5 tests): reproduces the SIGPIPE bug
  condition, validates the fix, and asserts all three osa.sh content-check
  functions return clean 0/1 (never 141) under pipefail with a real
  large-scrollback pane.
- `tests/test_tail_slicing.sh` extended (+2 tests): added invariant checks
  for `osa_contents_has_spinner` / `osa_contents_is_idle` consistency, and
  changed the hash-stability check from a flaky WARN to a clean SKIP when
  run against a busy Claude pane.

### Test count

- Unit: 113 → 120
- Integration: 9 (unchanged)
- Total: 122 → 129

## [0.1.0] — 2026-04-08

First public release. Pre-1.0: the CLI surface is usable but may change.

### Added

- `claude-later` in-pane script that arms a scheduled Claude Code message via
  `--at HH:MM` (absolute) or `--in DURATION` (relative, e.g. `30m`, `4h`,
  `2h30m`, `1d`).
- 13-step pre-flight: platform/terminal, binaries, time parsing, resume id
  validation, message content, iTerm2 scripting reachability, Secure Input,
  battery/power, first-run hygiene (claude has run in cwd), MCP auth cache,
  stale-state detection. Every check aborts loudly at arm time, not fire time.
- `--resume UUID` to pick up a prior Claude Code session at fire time. Validated
  end-to-end for the rate-limit-recovery workflow where a user arms a resume
  for after their 5-hour session window resets.
- `--skip-mcp-check` escape hatch for environments where the MCP auth cache is
  stale and being regenerated by a background process.
- `--dry-run` for pre-flight validation without actually scheduling.
- `--no-caffeinate`, `--allow-battery`, `--log-pane-snapshots` for unusual
  environments.
- `claude-later-helper`, a detached helper that drives the message via iTerm2's
  native scripting after the in-pane script `exec`s into `claude`. Implements
  stable-hash readiness detection, `❯` prompt-glyph validation, `Ctrl+U`
  pre-clear, and Secure Input recheck at T-0.
- macOS `caffeinate -dimsu` auto-wrapping to prevent system sleep during long
  waits.
- Per-run timestamped state files in `~/.claude-later/state/` and per-run log
  files in `~/.claude-later/logs/`. Both permission-restricted to `0700`.
- Explicit failure tombstones: `delivered`, `helper_timeout`, `tui_not_ready`,
  `session_died`, `unexpected_modal`, `write_failed`, `secure_input_engaged`,
  `missed_window`, `cancelled_by_window_close`.
- `osascript` stderr capture with hint classification — automation denied,
  iTerm2 not running, session closed — so failures produce actionable error
  messages instead of opaque return codes.
- Tail-sliced scrollback fetching (`CL_OSA_CONTENTS_TAIL`) for the helper's
  polling loop: 80 lines instead of the full scrollback. ~35× less data
  hashed per poll and resilient to window-resize reflow.
- Full test suite: 72 unit tests + 9 osa integration tests + end-to-end
  tests against a fake `claude` binary.

### Design decisions documented

- `SPIKES.md` captures the 11 Unit 0 spikes that validated load-bearing
  assumptions before implementation, including empirical evidence that
  iTerm2's native `write text ... newline YES` delivers keystrokes into
  Claude Code's TUI input box (not bracketed paste) and that Enter is
  honored as submit.
- `docs/plans/` and `docs/brainstorms/` (gitignored) contain the brainstorm
  and implementation plan that preceded the code.

[Unreleased]: https://github.com/ajanderson1/claude-later/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/ajanderson1/claude-later/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ajanderson1/claude-later/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/ajanderson1/claude-later/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ajanderson1/claude-later/releases/tag/v0.1.0
