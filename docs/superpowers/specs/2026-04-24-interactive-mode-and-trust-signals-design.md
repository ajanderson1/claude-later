# claude-later — Interactive mode, trust signals, and comprehensive testing

**Date:** 2026-04-24
**Status:** Design approved; pending written-spec review before implementation planning.
**Target version:** v0.3.0

## Problem

The tool is not being used by its primary user because of two frictions:

- **Per-invocation cognitive load.** Remembering `--in`/`--at` syntax, the `--claude-args` allowlist, and the `--resume-name` rules is too much to re-derive each time.
- **Lack of trust the job will fire.** After arming, the pane goes silent until T−5s. The ARMED banner is informational but does not explicitly say what was verified vs. what residual risks remain. Users hesitate to rely on the tool for its headline workflows (overnight runs, rate-limit recovery).

One-time install friction (Automation permission, `jq`, Xcode CLT) is **not** on the list. Preflight error-message quality is **not** on the list. This spec addresses only the two frictions above and the adjacent testing gap.

## Goals

1. Ship an `--interactive` wizard that walks a user through scheduling with live validation, eliminating the need to memorize flag syntax.
2. Replace the silent post-arm sleep with a live in-pane countdown that makes the armed state visible.
3. Enrich the ARMED banner so trust is explicit: enumerate what was verified now and the residual risks that cannot be defended against.
4. Close the highest-value testing gap (fake-claude end-to-end) and provide full coverage of every new surface introduced in this spec.

## Non-goals

- **Not** adding a rehearsal/test-fire mode.
- **Not** adding a post-hoc `--history` command.
- **Not** adding reusable profiles or a config file.
- **Not** fix-forward preflight (auto-install `jq`, auto-grant Automation, etc.).
- **Not** changing any existing flag's semantics. This release is purely additive.
- **Not** touching `lib/osa.sh` or `claude-later-helper`. Fire path stays stable.
- **Not** chasing tombstone classes that require exotic test infrastructure (`write_failed`, Secure Input at T-0).

## Design

### 1. Wizard (`--interactive` / `-i`)

Scheduling wizard only — not an install fixer, not a persistent TUI. A thin front-end that collects answers, validates each through the **same** validators the flag path uses, and hands off to the existing arm flow with a constructed argv identical to what the flag path would produce.

**Prompt sequence:**

1. **When should it fire?** Free-text. Accepts everything `--at` and `--in` accept (`4h`, `06:30`, `2026-04-25 03:00`, `2h30m`). Validated via existing `parse_in` / `parse_at`. On error: show the error inline and re-prompt. On success: echo `→ fires 2026-04-25 02:00 (in 3h 7m)`.

2. **Resume a previous Claude session?** Three choices: `[f]` fresh / `[u]` resume by UUID / `[n]` resume by name.
   - `f` → skip to step 3.
   - `u` → prompt for UUID; validate regex and transcript existence.
   - `n` → list `/rename`'d sessions found in the current cwd's project dir; accept pick-by-number or type the exact name. Resolve to UUID and show both. On zero matches: re-prompt with `no sessions named 'X' in <dir>; try again or type !abort`. On multiple exact-name matches: show disambiguation list and re-prompt.

3. **Any extra claude flags?** Default: `[enter]` for none. Otherwise: free-text, validated through the existing `--claude-args` allowlist/blocklist path. On reject: show which token failed and why, then re-prompt.

4. **Your message?** Single line. Validated (non-empty, single-line, printable) via the existing prompt validators.

5. **Confirmation.** Show the equivalent non-interactive command:
   ```
   This is equivalent to running:
     claude-later --in 4h --claude-args "--resume-name nightly" "review the PRs"
   Proceed? [Y/n]
   ```
   On `y` → continue into the normal arm flow (preflights, banner, countdown, fire). On `n` → offer to restart the wizard or exit.

**Design principles:**
- One validator per field, shared with the flag path. No duplicate logic.
- Wizard output argv is byte-identical to what the equivalent flag invocation would produce. This is the property that makes testing cheap and guarantees the two paths cannot drift.
- The confirmation line doubles as a teaching surface — users see the flag equivalent every time they use the wizard and can graduate to flags.
- Abort word `!abort` is accepted at any prompt to exit cleanly with no state written.

### 2. Enriched ARMED banner

Replaces the current banner. Fields preserved; two new sections added.

```
╭─ claude-later ARMED ────────────────────────────────────────────╮
│ Fires:       2026-04-25 06:00  (in 7h 32m)                      │
│ Pane:        iTerm2 session A1B2...                             │
│ Invocation:  claude --resume 7f3a4c12-…  (resolved from         │
│              --resume-name nightly-refactor)                    │
│ Message:     "review last night's commits and write a summary"  │
│                                                                 │
│ Verified now (13 checks passed):                                │
│   ✓ macOS + iTerm2 + not in tmux                                │
│   ✓ claude binary + jq + swift + caffeinate present             │
│   ✓ iTerm2 scripting reachable (probe returned session UUID)    │
│   ✓ Secure Input not engaged                                    │
│   ✓ On AC power                                                 │
│   ✓ First-run hygiene: claude has run in this cwd               │
│   ✓ No MCP auth pending                                         │
│   ✓ No other claude-later armed in this pane                    │
│   ✓ Resume UUID validated; transcript file exists               │
│                                                                 │
│ Residual risks (cannot defend against):                         │
│   ⚠ iTerm2 window close → cancelled (tombstone + notification)  │
│   ⚠ Reboot / kernel panic → job lost                            │
│   ⚠ Laptop lid close → caffeinate can't prevent clamshell sleep │
│                                                                 │
│ State: ~/.claude-later/state/A1B2….json                         │
│ Log:   ~/.claude-later/logs/A1B2….log                           │
╰─────────────────────────────────────────────────────────────────╯
```

**Generation.** The "Verified now" list is generated from a preflight registry (see §4). Each preflight registers a display label at definition time; the banner renders the labels of preflights that passed. If preflights are added or removed later, the banner updates automatically with no duplicated strings.

**Residual-risks section** surfaces the three items already documented in README's "Failure modes the snippet does not defend against." Hard-coded list in `banner.sh`; these change rarely.

**No flag gates the new sections.** Users who picked D as their trust friction want this by default. A `--quiet-banner` flag may be considered later if real feedback asks for it.

### 3. Live in-pane countdown

Replaces the current silent `sleep`. After the ARMED banner prints, the script enters a countdown loop that rewrites a single status line in place:

```
⏳ claude-later • fires in 3h 47m 12s • ^C to cancel • ^D to re-banner
```

**Mechanism:**
- Loop ticks every 1 second. Each tick: compute remaining time, render, emit `\r` + `tput el` + line.
- Runs inside the existing `caffeinate` re-exec (post-exec side), so caffeinate keeps the machine awake.
- At T−5s: print a newline (commits last countdown line to scrollback), print `→ T−5s, spawning helper...`, hand off to the existing pre-fire sequence (helper spawn + `exec claude`).

**Signal handling:**
- `^C` (SIGINT) → trap writes a `cancelled_by_user` tombstone, fires the macOS notification, clears the active state pointer, exits 130.
- `^D` (EOF on stdin) → re-print the ARMED banner (useful when the countdown has scrolled past). Does not cancel.
- Stdin is never consumed by the countdown; only the signal traps fire. The TUI needs a clean stdin when `exec claude` takes over.

**Refresh rate.** 1s. The per-second cost is negligible (one `date +%s`, one `printf`) and preflight already rejects battery power by default. No configurable rate.

### 4. Architecture: preflight registry + extracted modules

The banner's "Verified now" list is load-bearing on having each preflight's display label available. Today the 13 preflights are inline `pf_1_*`…`pf_13_*` functions in the main script with no externally-addressable label. A targeted refactor extracts them into a registry.

**File layout after this change:**

```
claude-later                     # main script (--interactive dispatch, countdown, enriched banner orchestration)
claude-later-helper              # UNCHANGED
lib/
  util.sh                        # UNCHANGED
  time.sh                        # UNCHANGED
  state.sh                       # +1 tombstone: cancelled_by_user
  osa.sh                         # UNCHANGED
  preflights.sh                  # NEW — each preflight becomes a registered unit with a display label
  interactive.sh                 # NEW — wizard prompts + re-prompt loop
  countdown.sh                   # NEW — cl_format_countdown + countdown_loop + signal traps
  banner.sh                      # NEW — builds the enriched ARMED banner from the registry
tests/
  test_interactive_wizard.sh     # NEW
  test_interactive_resolution.sh # NEW — resume-name listing, zero/multi-match
  test_countdown.sh              # NEW
  test_banner.sh                 # NEW
  integration/
    test_e2e_fake_claude.sh      # NEW — resolves the fake-claude spike
```

**Registry API (preflights.sh):**

```bash
# Each preflight calls this at source-time:
cl_register_preflight "<slot>" "<display label>" <fn_name>
# slot is a number 1..13 to preserve run order.
# Banner iterates passed preflights in slot order.
```

Each preflight function returns 0 on pass, non-zero on fail with an error message on stderr. The registry orchestrator invokes them in slot order and records which passed for the banner.

**Boundaries:**
- `interactive.sh` depends on `preflights.sh` (validators) and `time.sh` (parsing). Does not depend on `countdown.sh` or `banner.sh`.
- `countdown.sh` depends on nothing. Pure rendering + signal traps.
- `banner.sh` depends on `preflights.sh` (reads which preflights passed). Does not depend on `interactive.sh` or `countdown.sh`.
- Main script orchestrates: parse flags → (if `--interactive`) run wizard → run preflights → render banner → countdown → fire.

**Backward compatibility:**
- All existing flags keep current behavior byte-for-byte.
- All banner fields the current banner exposes are preserved in the new banner.
- State file `schema_version` stays at 1; adding a new status value is additive per the existing versioning promise in the README.

### 5. New tombstone class

`cancelled_by_user` — written when `^C` fires during the countdown loop. Notification text: `claude-later cancelled before firing`.

### 6. Testing

New files in the existing `tests/*.sh` harness — no new framework.

| File                              | What it covers                                                                                                                                    |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test_interactive_wizard.sh`      | Each wizard step: valid input accepted, invalid input re-prompts, final argv byte-matches the flag-path equivalent, `!abort` exits cleanly        |
| `test_interactive_resolution.sh`  | Resume-by-name list rendering, pick-by-number vs pick-by-name, zero-match re-prompt, multi-match disambiguation re-prompt                         |
| `test_countdown.sh`               | `cl_format_countdown` output for representative remaining times; `^C` trap installed and writes `cancelled_by_user` tombstone; `^D` re-prints     |
| `test_banner.sh`                  | Banner includes every registered preflight's label; residual-risks section present; resume-name resolution line shown when applicable             |
| `test_e2e_fake_claude.sh` (new)   | **Resolves the fake-claude spike.** Arms a job with `fake-claude` as `$CLAUDE_CMD`, waits for fire, asserts the fake received the message verbatim |

**How the wizard is tested without a human typing.** The wizard reads from stdin. Tests feed a scripted stdin:

```bash
printf '4h\nn\nnightly-refactor\n\nreview PRs\ny\n' | \
  claude-later --interactive --dry-run
```

and assert on (a) the ARMED banner text and (b) the generated argv captured via `--dry-run`. `--dry-run` already exits cleanly before the real fire, so this is safe in CI-like contexts.

**How the countdown is tested.**
- **Unit:** `cl_format_countdown <remaining_seconds>` is a pure string function; test representative inputs.
- **Integration:** arm a `--in 3s` dry-run; capture stdout; assert countdown lines appeared and the `^C` trap is installed. Signal-handling path itself is covered via the existing `test_failure_modes.sh` pattern.

**Fake-claude spike — resolution plan.**
Per `tests/README.md`, the blocker is that `fake-claude` uses bash `read -r` which reads from bash's line buffer, and we have not confirmed that `osa_write_text` with `newline YES` delivers bytes there. Implementation plan will sequence this as:

1. **Spike first.** One small script that does `osa_write_text` into a waiting bash `read` and observes whether it lands. If it works → write the e2e test using `fake-claude` as-is.
2. **If it doesn't work** — rewrite `fake-claude` to use `rlwrap cat` (readline-capable wrapper) that mirrors Claude Code's readline behavior. Accepts `rlwrap` as a test-only dependency.

**What stays uncovered and why:**
- Secure Input engaged at T-0 — requires scripting 1Password/lock screen; still flaky.
- `write_failed` tombstone — requires revoking Automation mid-test.

These are unchanged from today's coverage boundary.

## Risks

1. **Preflight extraction is a load-bearing refactor.** If any preflight has hidden coupling to main-script locals, extraction can break behavior. Mitigation: extract one preflight at a time; the full unit suite must pass after each extraction; `test_failure_modes.sh` already exercises every preflight's failure path and is excellent regression coverage.

2. **Countdown × `caffeinate` re-exec ordering.** The current code re-execs under `caffeinate` before sleeping. The countdown must live on the *post-re-exec* side. Straightforward but easy to get wrong. Implementation plan calls this out as a dedicated step with its own test (the existing `test_caffeinate_reexec.sh` pattern is adapted).

3. **Wizard resume-name zero/multi-match at arm vs. fire.** A name that resolves at wizard time could become ambiguous if the user creates a second identically-named session before fire time. Arm-time validation already resolves to a UUID before the state file is written, so this is handled — but worth a test.

4. **Banner height on small panes.** New banner is ~25 lines vs. current ~10. On panes smaller than 30 rows the top of the banner scrolls off immediately. `^D`-to-re-print mitigates this; no further action this release.

## Implementation order (for the plan)

1. Extract preflights into `lib/preflights.sh` with a registry API. Full test suite must pass.
2. Build `lib/banner.sh` driven by the registry. Add `test_banner.sh`.
3. Run the fake-claude spike. Resolve path.
4. Write `test_e2e_fake_claude.sh` using whichever path the spike clears.
5. Build `lib/countdown.sh` and integrate into the main arm flow. Add `test_countdown.sh`. Add `cancelled_by_user` tombstone to `lib/state.sh`.
6. Build `lib/interactive.sh`. Wire `--interactive` / `-i` dispatch into `claude-later`. Add `test_interactive_wizard.sh` and `test_interactive_resolution.sh`.
7. Update `README.md` and `CHANGELOG.md`. Bump version to `0.3.0`.

Each step is independently testable and can land as its own PR.
