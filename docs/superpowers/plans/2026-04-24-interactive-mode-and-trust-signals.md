# v0.3.0 — Interactive mode, trust signals, comprehensive testing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.3.0 with an `--interactive` scheduling wizard, a live in-pane countdown, an enriched ARMED banner driven by a preflight registry, a new `cancelled_by_user` tombstone, and closure of the fake-claude end-to-end test gap.

**Architecture:** Targeted refactor to extract 13 preflights into `lib/preflights.sh` with a registry API (display label + function), so the banner can enumerate "what was verified now" without duplicating strings. Three new pure-function modules (`countdown.sh`, `banner.sh`, `interactive.sh`) orchestrated from the main script with stable boundaries. The wizard is a thin front-end that produces argv identical to the equivalent flag invocation, reusing existing validators from `time.sh` and `preflights.sh`. The countdown replaces the current silent `sleep_until_fire` loop post-caffeinate-reexec. All existing flag behaviour is preserved byte-for-byte.

**Tech Stack:** Bash 3.2 (macOS system bash), `jq`, `osascript`, `caffeinate`, `swift` (existing). No new runtime deps. Test-only dep `rlwrap` added **conditionally** based on the fake-claude spike result.

**Spec:** `docs/superpowers/specs/2026-04-24-interactive-mode-and-trust-signals-design.md`

**Branch / worktree:** `feat/v0.3-interactive-mode` at `.worktrees/v0.3-interactive/`. All commands in this plan assume CWD is the worktree.

---

## File structure after this plan

```
claude-later                          # MODIFIED — dispatches --interactive, swaps sleep loop for countdown, defers to new modules
claude-later-helper                   # UNCHANGED
lib/
  util.sh                             # UNCHANGED
  time.sh                             # UNCHANGED
  state.sh                            # MODIFIED — documents new tombstone class cancelled_by_user (no code change required)
  osa.sh                              # UNCHANGED
  preflights.sh                       # NEW — registry + 13 extracted preflight functions
  banner.sh                           # NEW — builds the ARMED banner from registry state
  countdown.sh                        # NEW — cl_format_countdown + countdown_loop + ^C/^D traps
  interactive.sh                      # NEW — wizard prompts and input validation loop
tests/
  test_preflights_registry.sh         # NEW — registry API unit tests
  test_banner.sh                      # NEW — banner rendering driven by registry state
  test_countdown.sh                   # NEW — formatter + trap installation
  test_interactive_wizard.sh          # NEW — stdin-driven wizard runs through to --dry-run banner
  test_interactive_resolution.sh      # NEW — resume-name listing (zero/one/many)
  fixtures/
    fake-claude                       # MODIFIED (conditionally) — readline mode if spike demands it
  integration/
    test_e2e_fake_claude.sh           # NEW — full arm → fire → assert-delivery cycle
    spike_write_text_to_read.sh       # NEW — one-shot spike script; deleted in final commit
```

**Why extract preflights.** The enriched banner needs each preflight's display label. Inline functions in `claude-later` have no externally-addressable label. A registry makes labels first-class and guarantees the banner cannot drift from the actual preflight set.

**Why three separate new modules.** `interactive.sh`, `banner.sh`, `countdown.sh` each have one responsibility, no cyclic deps. Boundaries:
- `interactive.sh` → depends on `preflights.sh` (validators) + `time.sh`.
- `banner.sh` → depends on `preflights.sh` (reads registry).
- `countdown.sh` → depends on nothing.

---

## Execution notes for the implementer

- **Bash 3.2 constraints.** No associative arrays, no `mapfile`, no `${var^^}` uppercase expansion. Use parallel arrays or newline-separated strings with `while read`. Every existing file is bash 3.2; stay in that dialect.
- **Testing discipline (TDD).** For every new function: red (failing test) → green (minimal code) → refactor → commit. Don't skip red.
- **Commit cadence.** Each task ends with a commit. Commit messages follow the existing style (see `git log`): `feat: …`, `refactor: …`, `test: …`, `docs: …`.
- **Run the suite often.** `bash tests/run-all.sh` must pass after every task. Some tests self-skip outside iTerm2; that's fine.
- **Preserve behavior.** No existing flag changes semantics. Every existing test file must still pass after every task without being modified, **except** where a task explicitly modifies a test file.
- **Shared validators.** When the wizard asks for a `--claude-args` value, it must pass the string through the SAME `pf_4_claude_args` path so the rules are identical. Do not duplicate allowlist logic.
- **Caffeinate × countdown.** The countdown must run on the *post-caffeinate-reexec* side (same place `sleep_until_fire` runs today). The re-exec boundary is at `claude-later:822-824`.
- **`--dry-run` is the test lever.** Tests can drive the full arm path up to banner-print without scheduling by passing `--dry-run`. The wizard must honor `--dry-run` the same way the flag path does.

---

## Task 1: Preflight registry skeleton

**Files:**
- Create: `lib/preflights.sh`
- Create: `tests/test_preflights_registry.sh`

The registry is a pair of parallel bash-3.2-compatible newline-separated strings holding slot-number, display-label, and function-name per preflight. Plus a "passed slots" accumulator the banner reads.

- [ ] **Step 1: Write the failing test**

Create `tests/test_preflights_registry.sh`:

```bash
#!/bin/bash
# tests/test_preflights_registry.sh — preflight registry unit tests.
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_preflights_registry"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/preflights.sh"

# Fresh registry state per test
cl_pf_registry_reset

# Register two fake preflights
_fake_pf_a() { return 0; }
_fake_pf_b() { return 1; }
cl_pf_register 1 "label A" _fake_pf_a
cl_pf_register 2 "label B" _fake_pf_b

# Listing preflights in slot order
got=$(cl_pf_list_labels)
assert_eq "$got" "label A
label B" "list labels in slot order"

# Lookup label by slot
got=$(cl_pf_label_for 1); assert_eq "$got" "label A" "label_for slot 1"
got=$(cl_pf_label_for 2); assert_eq "$got" "label B" "label_for slot 2"

# Passed accumulator starts empty
got=$(cl_pf_passed_labels); assert_eq "$got" "" "passed starts empty"

# Running the registry marks passed slots and aborts on first failure
output=$(cl_pf_run_all 2>&1); rc=$?
assert_nonzero "$rc" "run_all returns nonzero when a preflight fails"

# After the run, slot 1 is in 'passed' but slot 2 is not
got=$(cl_pf_passed_labels); assert_eq "$got" "label A" "only slot 1 recorded as passed"

test_summary
```

- [ ] **Step 2: Run test to verify it fails**

```
bash tests/test_preflights_registry.sh
```
Expected: FAIL (source error — `lib/preflights.sh` does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/preflights.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

```
bash tests/test_preflights_registry.sh
```
Expected: PASS (all assertions green).

- [ ] **Step 5: Commit**

```bash
git add lib/preflights.sh tests/test_preflights_registry.sh
git commit -m "feat: preflight registry (slot + label + fn)"
```

---

## Task 2: Extract `pf_1_platform_terminal` into the registry

**Files:**
- Modify: `lib/preflights.sh` (append the extracted function + `cl_pf_register` call guarded by `CL_PF_AUTOREGISTER`)
- Modify: `claude-later:161-179` (replace body with a delegation that calls the registry version; keep name)

**Why a guard flag.** Tests for the registry mechanics (Task 1) must NOT trigger real platform checks. `CL_PF_AUTOREGISTER=1` is set only by `claude-later` when it sources `lib/preflights.sh`.

- [ ] **Step 1: Write the failing test (append to existing test)**

Append to `tests/test_preflights_registry.sh` (just before `test_summary`):

```bash
# Autoregistration: sourcing with CL_PF_AUTOREGISTER=1 registers pf_1 by slot/label
cl_pf_registry_reset
CL_PF_AUTOREGISTER=1 . "$CL_DIR/lib/preflights.sh"
got=$(cl_pf_label_for 1)
assert_eq "$got" "macOS + iTerm2 + not in tmux" "pf_1 registered with correct label"
unset CL_PF_AUTOREGISTER
```

- [ ] **Step 2: Run test to verify it fails**

```
bash tests/test_preflights_registry.sh
```
Expected: FAIL on "pf_1 registered with correct label" (label is empty).

- [ ] **Step 3: Add the extracted function and autoregistration block to `lib/preflights.sh`**

Append to `lib/preflights.sh`:

```bash
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
```

- [ ] **Step 4: Replace `pf_1_platform_terminal` body in `claude-later`**

In `claude-later`, replace lines 161-179 with:

```bash
pf_1_platform_terminal() { cl_pf_1_platform_terminal; }
```

- [ ] **Step 5: Run test and full suite**

```
bash tests/test_preflights_registry.sh
bash tests/run-all.sh
```
Expected: all PASS; `test_failure_modes.sh` still exercises every existing preflight.

- [ ] **Step 6: Commit**

```bash
git add lib/preflights.sh claude-later tests/test_preflights_registry.sh
git commit -m "refactor: extract pf_1 into registry"
```

---

## Task 3: Extract `pf_2_binaries`

**Files:**
- Modify: `lib/preflights.sh` (append `cl_pf_2_binaries` + autoregister)
- Modify: `claude-later:181-190` (replace body with delegation)

- [ ] **Step 1: Append test assertion**

Append to `tests/test_preflights_registry.sh`:

```bash
cl_pf_registry_reset
CL_PF_AUTOREGISTER=1 . "$CL_DIR/lib/preflights.sh"
got=$(cl_pf_label_for 2)
assert_eq "$got" "claude + jq + swift + caffeinate + pmset present" "pf_2 registered"
unset CL_PF_AUTOREGISTER
```

- [ ] **Step 2: Verify red**
```
bash tests/test_preflights_registry.sh
```
Expected: FAIL on "pf_2 registered".

- [ ] **Step 3: Append to `lib/preflights.sh`**

```bash
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
```

- [ ] **Step 4: Replace `pf_2_binaries` in `claude-later`** with `pf_2_binaries() { cl_pf_2_binaries; }`

- [ ] **Step 5: Run full suite**
```
bash tests/run-all.sh
```
Expected: all pass.

- [ ] **Step 6: Commit**
```
git add lib/preflights.sh claude-later tests/test_preflights_registry.sh
git commit -m "refactor: extract pf_2 into registry"
```

---

## Task 4: Extract remaining preflights (pf_3, pf_4, pf_5, pf_6, pf_8, pf_9, pf_10, pf_12)

**Files:**
- Modify: `lib/preflights.sh` (append 8 functions + 8 autoregister lines, mirroring the current bodies verbatim)
- Modify: `claude-later` (replace 8 function bodies with delegations)

**Rationale:** Task 2 proved the pattern. Extract the remaining eight in one task, one function at a time with `bash tests/run-all.sh` between each, but a single commit at the end. `pf_7_visible_probe` is already a no-op and stays inline. `pf_11` does not exist.

**Slot labels (for `cl_pf_register`):**

| Slot | Label                                                                  |
| ---- | ---------------------------------------------------------------------- |
| 3    | `--at / --in parses to a valid future time`                            |
| 4    | `--claude-args validated against allowlist / blocklist`                |
| 5    | `message is single-line, printable, non-empty`                         |
| 6    | `iTerm2 scripting reachable; Secure Input not engaged`                 |
| 8    | `on AC power (or --allow-battery set)`                                 |
| 9    | `no other claude-later armed in this pane`                             |
| 10   | `log file writable`                                                    |
| 12   | `claude first-run hygiene; no MCP auth pending`                        |

- [ ] **Step 1: For each preflight listed above, one at a time:**
  1. Copy the existing function body from `claude-later` into `lib/preflights.sh` prefixed `cl_pf_N_<name>`.
  2. Add `cl_pf_register N "<label from table>" cl_pf_N_<name>` inside the `CL_PF_AUTOREGISTER` block.
  3. Replace the `claude-later` function body with `pf_N_<name>() { cl_pf_N_<name>; }`.
  4. Append a test assertion to `tests/test_preflights_registry.sh`:
     ```bash
     got=$(cl_pf_label_for N); assert_eq "$got" "<label from table>" "pf_N registered"
     ```
     (Wrap the appended assertions in a single `cl_pf_registry_reset; CL_PF_AUTOREGISTER=1 . lib/preflights.sh; unset CL_PF_AUTOREGISTER` stanza.)
  5. Run `bash tests/run-all.sh` — all tests must still pass.

- [ ] **Step 2: Final full run**
```
bash tests/run-all.sh
```
Expected: all pass. `test_failure_modes.sh` in particular regression-covers every preflight's failure path.

- [ ] **Step 3: Commit**
```bash
git add lib/preflights.sh claude-later tests/test_preflights_registry.sh
git commit -m "refactor: extract remaining preflights into registry"
```

---

## Task 5: `lib/banner.sh` — enriched ARMED banner

**Files:**
- Create: `lib/banner.sh`
- Create: `tests/test_banner.sh`
- Modify: `claude-later` (replace `print_armed_banner` body with delegation to `cl_banner_render`)

Banner renders:
- Top block: Fire time, delta, Pane, iTerm2 version, claude version, Invocation (with resume-name resolution), Message, PID, Log, State, Caffeinate status (unchanged from current).
- **NEW "Verified now" section**: iterates `cl_pf_passed_labels`, one `  ✓ LABEL` per line.
- **NEW "Residual risks" section**: three hardcoded lines.

- [ ] **Step 1: Write failing test `tests/test_banner.sh`**

```bash
#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_banner"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/preflights.sh"
. "$CL_DIR/lib/banner.sh"

cl_pf_registry_reset
cl_pf_register 1 "label one" true
cl_pf_register 2 "label two" true
cl_pf_run_all >/dev/null

# Minimum globals the banner reads
CL_TARGET_EPOCH=$(( $(date +%s) + 3600 ))
ITERM_SESSION_ID="w0t0p0:00000000-0000-0000-0000-000000000000"
CL_PANE_ID="w0t0p0"
CL_ITERM_VERSION="3.5.0"
CL_CLAUDE_VERSION="2.0.0 (Claude Code)"
CL_CLAUDE_ARGS_ARR=()
CL_RESUME_NAME_RESOLUTION=""
ARG_MESSAGE="hello world"
CL_LOG_PATH="/tmp/x.log"
CL_STATE_PATH="/tmp/x.json"
ARG_NO_CAFFEINATE=0

out=$(cl_banner_render)
assert_match "$out" "claude-later ARMED" "banner headline present"
assert_match "$out" "Verified now \(2 checks passed\)" "verified-now header with count"
assert_match "$out" "✓ label one" "verified label 1"
assert_match "$out" "✓ label two" "verified label 2"
assert_match "$out" "Residual risks" "residual-risks header"
assert_match "$out" "iTerm2 window close" "residual risk: window close"
assert_match "$out" "Reboot" "residual risk: reboot"
assert_match "$out" "lid close" "residual risk: lid close"

# Resume-name resolution line appears when set
CL_RESUME_NAME_RESOLUTION="nightly -> abc-def"
CL_CLAUDE_ARGS_ARR=(--resume abc-def)
out=$(cl_banner_render)
assert_match "$out" "resolved --resume-name nightly" "resume-name line shown"

test_summary
```

- [ ] **Step 2: Verify red** — `bash tests/test_banner.sh` fails (no `lib/banner.sh`).

- [ ] **Step 3: Write `lib/banner.sh`**

```bash
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
  printf '%s' "$passed" | while IFS= read -r label; do
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
```

- [ ] **Step 4: Replace `print_armed_banner` body in `claude-later:590-626`** with:

```bash
print_armed_banner() { cl_banner_render; }
```

Add `. "$CL_DIR/lib/banner.sh"` to the source block at `claude-later:11-15`.

- [ ] **Step 5: Run suites**
```
bash tests/test_banner.sh
bash tests/run-all.sh
```
Expected: all pass.

- [ ] **Step 6: Register preflight runs from `run_preflight`**

In `claude-later`, the existing `run_preflight` calls `pf_1 … pf_12` directly. It must ALSO populate `CL_PF_PASSED` so the banner sees them. Simplest path: keep the current inline calls for control-flow (abort on first failure), but after each successful call, record the slot by calling `cl_pf_record_passed N`. Add this helper to `lib/preflights.sh`:

```bash
cl_pf_record_passed() {
  local slot=$1
  local label
  label=$(cl_pf_label_for "$slot")
  [ -n "$label" ] || return 0
  CL_PF_PASSED="${CL_PF_PASSED}${slot}|${label}
"
}
```

And at the top of `claude-later`, after sourcing `preflights.sh`, set `CL_PF_AUTOREGISTER=1` *before* sourcing so registration happens:

```bash
CL_PF_AUTOREGISTER=1 . "$CL_DIR/lib/preflights.sh"
unset CL_PF_AUTOREGISTER
```

Then in `run_preflight`, after each `pf_N_*` returns success, call `cl_pf_record_passed N`.

- [ ] **Step 7: Add an end-to-end banner test via `--dry-run`**

Append to `tests/test_banner.sh`:

```bash
# E2E: dry-run a real invocation; banner must list multiple ✓ lines
if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
  setup_fake_project_dir
  out=$(./claude-later --dry-run --in 1m "banner e2e test" 2>&1 || true)
  assert_match "$out" "Verified now \([0-9]+ checks passed\)" "dry-run banner: verified count"
  assert_match "$out" "✓ macOS \+ iTerm2" "dry-run banner: pf_1 label"
  cleanup_test_state_files
  cleanup_fake_project_dir
else
  printf '  SKIP: e2e dry-run banner (not in iTerm2)\n'
fi
```

- [ ] **Step 8: Run and commit**
```
bash tests/run-all.sh
git add lib/banner.sh lib/preflights.sh claude-later tests/test_banner.sh
git commit -m "feat: enriched ARMED banner driven by preflight registry"
```

---

## Task 6: Fake-claude spike

**Files:**
- Create: `tests/integration/spike_write_text_to_read.sh`

Resolves the open question from `tests/README.md` lines 55-56: does `osa_write_text ... newline YES` deliver bytes into a bash process blocked on `read -r`? The answer determines whether the e2e test can use the existing `fake-claude` fixture as-is or needs a readline wrapper.

**Requires iTerm2.** If not running in iTerm2, the spike self-skips with a clear message.

- [ ] **Step 1: Write the spike**

Create `tests/integration/spike_write_text_to_read.sh`:

```bash
#!/bin/bash
# tests/integration/spike_write_text_to_read.sh
#
# One-shot empirical test: does `osa_write_text ... newline YES` deliver
# bytes into a bash `read -r` call running in the same pane?
#
# Spawns a subshell that waits for one line of input, writes the line to
# a marker file, and exits. The parent (this script) sleeps briefly, then
# uses osa_write_text to deliver "spike_payload" into the pane. If the
# marker file contains "spike_payload" afterward, read-r is sufficient
# and the e2e test can use fake-claude unmodified. If not, we need rlwrap.
set -uo pipefail

CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$CL_DIR/lib/osa.sh"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: spike requires iTerm2\n' >&2
  exit 77
fi

MARKER=$(mktemp -t clspike.XXXXXX)
trap 'rm -f "$MARKER"' EXIT

# Fork: child reads one line and writes marker
(
  if IFS= read -r line; then
    printf '%s\n' "$line" > "$MARKER"
  fi
) &
CHILD=$!

sleep 1

# Deliver the line via osa_write_text into the current pane
uuid="${ITERM_SESSION_ID#*:}"
osa_write_text "$uuid" "spike_payload"

wait "$CHILD" 2>/dev/null || true

got=$(cat "$MARKER" 2>/dev/null)
if [ "$got" = "spike_payload" ]; then
  printf 'RESULT: read-r SUFFICIENT — fake-claude works as-is\n'
  exit 0
else
  printf 'RESULT: read-r INSUFFICIENT — got=%s — need rlwrap\n' "$got"
  exit 2
fi
```

- [ ] **Step 2: Make executable and run the spike**

```
chmod +x tests/integration/spike_write_text_to_read.sh
bash tests/integration/spike_write_text_to_read.sh
```

Record the result. Two paths:

- **Exit 0 ("SUFFICIENT")** → go to Task 7 with `CL_FAKE_CLAUDE_USES_RLWRAP=0`.
- **Exit 2 ("INSUFFICIENT")** → go to Task 7 with `CL_FAKE_CLAUDE_USES_RLWRAP=1`. Also verify `rlwrap` is installed (`command -v rlwrap`); if not, document the dep.

- [ ] **Step 3: Delete the spike**

The spike was exploratory. Delete it (we've recorded the answer):

```
git rm tests/integration/spike_write_text_to_read.sh
```

- [ ] **Step 4: Commit the spike outcome as a doc note**

Add a one-line entry to `CHANGELOG.md` under `## [Unreleased]` (create that section at the top if it doesn't exist):

```markdown
## [Unreleased]

### Testing

- Spike: confirmed `osa_write_text ... newline YES` [IS / IS NOT] sufficient for bash `read -r`. E2E test [uses / wraps] fake-claude [as-is / with rlwrap].
```

Pick the bracketed words that match the spike outcome, commit:

```
git add CHANGELOG.md
git commit -m "test: record fake-claude e2e spike outcome"
```

---

## Task 7: `test_e2e_fake_claude.sh` — end-to-end arm→fire→deliver

**Files:**
- Create: `tests/integration/test_e2e_fake_claude.sh`
- Modify (conditional): `tests/fixtures/fake-claude` if spike said "INSUFFICIENT"

- [ ] **Step 1 (conditional): If spike said INSUFFICIENT, wrap fake-claude's `read -r`**

Only if Task 6 returned exit 2. Modify `tests/fixtures/fake-claude` lines 82-90: replace the `read -r` block with a `rlwrap`-friendly pattern. The simplest fix that gives readline line-discipline to a pure bash read is to invoke the existing logic under `rlwrap -a`. Pragmatic approach: keep the fixture's main logic in place, but replace the `read -r` call site with:

```bash
if command -v rlwrap >/dev/null; then
  received_line=$(rlwrap -o -S "" bash -c 'IFS= read -r L; printf "%s" "$L"')
else
  IFS= read -r received_line
fi
```

Document that the e2e test requires `rlwrap` when in the INSUFFICIENT branch.

- [ ] **Step 2: Write the e2e test**

Create `tests/integration/test_e2e_fake_claude.sh`:

```bash
#!/bin/bash
# tests/integration/test_e2e_fake_claude.sh
#
# End-to-end: arm claude-later with fake-claude as CLAUDE_CMD, wait for the
# fire window to elapse, assert fake-claude received the exact message.
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CL_TEST_NAME="test_e2e_fake_claude"
. "$CL_DIR/tests/test-utils.sh"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: e2e requires iTerm2\n' >&2
  exit 0
fi

# Install fake-claude on PATH for this test
TMPBIN=$(mktemp -d)
trap 'rm -rf "$TMPBIN"' EXIT
ln -s "$CL_DIR/tests/fixtures/fake-claude" "$TMPBIN/claude"
export PATH="$TMPBIN:$PATH"

MARK=$(mktemp -t clfc.XXXXXX)
export CL_FAKE_CLAUDE_OUTPUT="$MARK"

setup_fake_project_dir

# Arm for T+6s so the 5s sleep + render finishes inside a reasonable test window.
MSG="e2e test payload $$"
"$CL_DIR/claude-later" --in 8s "$MSG" &
CL_PID=$!

# Wait up to 40s for the marker file to be populated (fake-claude writes it
# on receive). Poll every 500ms.
for _ in $(seq 1 80); do
  if [ -s "$MARK" ]; then break; fi
  sleep 0.5
done

# fake-claude strips the leading ^U and writes one line, newline-terminated.
got=$(cat "$MARK" 2>/dev/null | head -c 4096)
wait "$CL_PID" 2>/dev/null || true

assert_eq "$got" "$MSG
" "delivered message matches arm-time message"

cleanup_test_state_files
cleanup_fake_project_dir
test_summary
```

- [ ] **Step 3: Add to the integration runner**

Append to `tests/integration/run-integration.sh` the invocation of `test_e2e_fake_claude.sh` following the same pattern already used for `test_osa.sh`.

- [ ] **Step 4: Run**
```
bash tests/integration/run-integration.sh
```
Expected: all integration tests pass.

- [ ] **Step 5: Commit**
```
git add tests/integration/test_e2e_fake_claude.sh tests/integration/run-integration.sh tests/fixtures/fake-claude
git commit -m "test: end-to-end fake-claude arm→fire→deliver"
```

---

## Task 8: `cancelled_by_user` tombstone

**Files:**
- Modify: `lib/state.sh` (document; no code change — `state_mark` accepts any status string)
- Modify: `README.md` (`## Robustness` → "Tombstone classes" list, add `cancelled_by_user`)

`state_mark` already accepts any string for status. The tombstone class is introduced in the next task (`countdown.sh`) where it's written; this task is documentation only.

- [ ] **Step 1: Update README tombstone list**

In `README.md` find the list of tombstone classes (currently around `delivered | tui_not_ready | ...` in the Robustness section). Add a new entry:

```markdown
- `cancelled_by_user` — user pressed ^C during the live countdown before fire time
```

- [ ] **Step 2: Add a code comment to `lib/state.sh`** (just above the `state_mark` definition):

```bash
# Known status values (as of v0.3.0): armed, delivered, tui_not_ready,
# session_died, session_died_pre_exec, secure_input_engaged, unexpected_modal,
# write_failed, helper_timeout, missed_window, cancelled_by_window_close,
# cancelled_by_user, killed, iterm_version_changed, claude_version_changed.
```

- [ ] **Step 3: Commit**
```
git add README.md lib/state.sh
git commit -m "docs: introduce cancelled_by_user tombstone class"
```

---

## Task 9: `lib/countdown.sh` — formatter

**Files:**
- Create: `lib/countdown.sh`
- Create: `tests/test_countdown.sh`

Pure string function first. The loop + signal handling come in Task 10.

- [ ] **Step 1: Write failing test `tests/test_countdown.sh`**

```bash
#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_countdown"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/countdown.sh"

assert_eq "$(cl_format_countdown 0)" "⏳ claude-later • fires in 0s • ^C to cancel • ^D to re-banner" "zero"
assert_eq "$(cl_format_countdown 59)" "⏳ claude-later • fires in 59s • ^C to cancel • ^D to re-banner" "<1m"
assert_eq "$(cl_format_countdown 60)" "⏳ claude-later • fires in 1m 0s • ^C to cancel • ^D to re-banner" "exact 1m"
assert_eq "$(cl_format_countdown 3599)" "⏳ claude-later • fires in 59m 59s • ^C to cancel • ^D to re-banner" "<1h"
assert_eq "$(cl_format_countdown 3600)" "⏳ claude-later • fires in 1h 0m 0s • ^C to cancel • ^D to re-banner" "exact 1h"
assert_eq "$(cl_format_countdown 13632)" "⏳ claude-later • fires in 3h 47m 12s • ^C to cancel • ^D to re-banner" "sample 3h47m12s"

test_summary
```

- [ ] **Step 2: Verify red**
```
bash tests/test_countdown.sh
```
Expected: FAIL (source error).

- [ ] **Step 3: Write `lib/countdown.sh`**

```bash
#!/bin/bash
# claude-later/lib/countdown.sh — in-pane live countdown.
#
# Public API (populated as the plan proceeds):
#   cl_format_countdown REMAINING_SEC   — pure string formatter (Task 9)
#   cl_countdown_loop TARGET_EPOCH      — main loop w/ signal traps (Task 10)

cl_format_countdown() {
  local s=$1 h m sec body
  if [ "$s" -lt 60 ]; then
    body="${s}s"
  elif [ "$s" -lt 3600 ]; then
    m=$((s / 60)); sec=$((s % 60))
    body="${m}m ${sec}s"
  else
    h=$((s / 3600)); m=$(((s % 3600) / 60)); sec=$((s % 60))
    body="${h}h ${m}m ${sec}s"
  fi
  printf '⏳ claude-later • fires in %s • ^C to cancel • ^D to re-banner' "$body"
}
```

- [ ] **Step 4: Verify green**
```
bash tests/test_countdown.sh
```
Expected: all pass.

- [ ] **Step 5: Commit**
```
git add lib/countdown.sh tests/test_countdown.sh
git commit -m "feat: countdown formatter"
```

---

## Task 10: `cl_countdown_loop` + signal traps + integration

**Files:**
- Modify: `lib/countdown.sh` (append `cl_countdown_loop` and trap helpers)
- Modify: `tests/test_countdown.sh` (append trap/loop tests)
- Modify: `claude-later` — replace `sleep_until_fire` body with the countdown loop; keep `sleep_until_fire` as a function name that delegates so the existing `main` flow is unchanged.

The loop ticks every 1s, writes `\r` + the rendered line + `tput el` to stderr (keeps stdout clean for tests), polls `polling_missed_window` with 60s grace (unchanged), exits the loop at T-5s, then returns. On `^C` it writes the `cancelled_by_user` tombstone and exits 130. On `^D` it re-prints the banner.

- [ ] **Step 1: Append test cases**

Append to `tests/test_countdown.sh`:

```bash
# cl_countdown_loop exits cleanly at T-5s on a synthetic target
. "$CL_DIR/lib/time.sh"
CL_TARGET_EPOCH=$(( $(date +%s) + 7 ))
# Run with a NO-OP banner reprint fn and a NO-OP tombstone writer
cl_banner_render() { :; }
cl_countdown_cancel_tombstone() { printf 'fake_tombstone_called\n' > "$1"; }
MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT
CL_STATE_PATH="$MARK-state"
CL_ACTIVE_PTR="$MARK-active"
# Non-interactive run — no signals — should return 0 after ~2s (loop exits at T-5s)
t0=$(date +%s)
cl_countdown_loop 2>/dev/null
t1=$(date +%s)
elapsed=$((t1 - t0))
# Should have taken between 1 and 4 seconds (target+7 → exit at target-5 = now+2)
[ "$elapsed" -ge 1 ] && [ "$elapsed" -le 4 ] && pass=1 || pass=0
assert_eq "$pass" "1" "loop exits near T-5s (elapsed=${elapsed}s)"

test_summary
```

- [ ] **Step 2: Implement `cl_countdown_loop` and helpers**

Append to `lib/countdown.sh`:

```bash
# cl_countdown_cancel_tombstone STATE_PATH
# Hook point for ^C handling — writes the cancelled_by_user tombstone and
# clears the active pointer. Separated so tests can stub it.
cl_countdown_cancel_tombstone() {
  local state_path=$1
  state_mark "$state_path" "cancelled_by_user" "^C during countdown" 2>/dev/null || true
  state_active_clear "$CL_ACTIVE_PTR" 2>/dev/null || true
}

# cl_countdown_loop
# Reads CL_TARGET_EPOCH, CL_STATE_PATH, CL_ACTIVE_PTR, CL_LOG_PATH.
# Prints a live countdown to STDERR once per second (so STDOUT stays clean).
# Exits the loop when remaining <= 5. Signal handling:
#   ^C → cl_countdown_cancel_tombstone, notify, exit 130
#   ^D → re-print banner via cl_banner_render, continue loop
cl_countdown_loop() {
  local got_eof=0
  cl_countdown_on_int() {
    cl_countdown_cancel_tombstone "$CL_STATE_PATH"
    notify "claude-later: cancelled" "Cancelled by user (^C) before fire time" 2>/dev/null || true
    printf '\n' >&2
    exit 130
  }
  trap 'cl_countdown_on_int' INT
  # ^D detection: read -t 0 with no bytes returns nonzero; EOF returns 1 after
  # flushing. We enable job-control-like check via a non-blocking read stub.
  while :; do
    local now remaining
    now=$(date +%s)
    remaining=$((CL_TARGET_EPOCH - now))
    if [ "$remaining" -le 5 ]; then
      printf '\r\033[K' >&2
      printf '→ T−5s, spawning helper...\n' >&2
      return 0
    fi
    if polling_missed_window "$now" "$CL_TARGET_EPOCH" 60; then
      state_mark "$CL_STATE_PATH" "missed_window" "asleep through fire window" 2>/dev/null || true
      state_active_clear "$CL_ACTIVE_PTR" 2>/dev/null || true
      notify "claude-later: missed_window" "System was asleep through the fire window" 2>/dev/null || true
      exit 1
    fi
    local line
    line=$(cl_format_countdown "$remaining")
    # \r returns cursor to col 0; \033[K clears to EOL. Write to stderr so
    # stdout captures in tests stay clean.
    printf '\r\033[K%s' "$line" >&2
    # Sleep 1s but wake on ^D (EOF on stdin)
    if IFS= read -r -t 1 _junk; then
      # Got a line of input during countdown — treat as ^D re-banner signal
      printf '\n' >&2
      cl_banner_render >&2
    fi
    if [ "$got_eof" -eq 1 ]; then break; fi
  done
}
```

- [ ] **Step 3: Run test**
```
bash tests/test_countdown.sh
```
Expected: all pass.

- [ ] **Step 4: Wire into `claude-later`**

Add `. "$CL_DIR/lib/countdown.sh"` to the source block. Replace the body of `sleep_until_fire` (`claude-later:711-733`) with:

```bash
sleep_until_fire() {
  install_pre_traps
  log_event "countdown loop start target=$CL_TARGET_EPOCH"
  cl_countdown_loop
}
```

- [ ] **Step 5: Full suite**
```
bash tests/run-all.sh
```
Expected: pass.

- [ ] **Step 6: Commit**
```
git add lib/countdown.sh tests/test_countdown.sh claude-later
git commit -m "feat: live in-pane countdown with ^C/^D handling"
```

---

## Task 11: `lib/interactive.sh` — wizard

**Files:**
- Create: `lib/interactive.sh`
- Create: `tests/test_interactive_wizard.sh`
- Create: `tests/test_interactive_resolution.sh`
- Modify: `claude-later` — add `--interactive`/`-i` to `parse_args`; dispatch to wizard before preflights.

The wizard produces **the same argv the flag path would produce**, then falls through to the normal arm flow. It does NOT duplicate preflight logic; it calls the existing parsers (`parse_in` / `parse_at` / `pf_4_claude_args` via a thin validator wrapper).

- [ ] **Step 1: Write `tests/test_interactive_wizard.sh`**

```bash
#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_interactive_wizard"
. "$CL_DIR/tests/test-utils.sh"

if [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  printf 'SKIP: wizard e2e requires iTerm2 (dry-run still hits preflights)\n' >&2
  exit 0
fi

setup_fake_project_dir

# Drive the wizard with scripted stdin. Expected answers:
#   when: "4h"
#   resume: "f" (fresh)
#   extra flags: (enter, none)
#   message: "wizard test payload"
#   confirm: "y"
out=$(printf '4h\nf\n\nwizard test payload\ny\n' \
  | "$CL_DIR/claude-later" --interactive --dry-run 2>&1 || true)

assert_match "$out" "When should it fire" "prompt 1 asked"
assert_match "$out" "Resume a previous" "prompt 2 asked"
assert_match "$out" "extra claude flags" "prompt 3 asked"
assert_match "$out" "Your message" "prompt 4 asked"
assert_match "$out" "This is equivalent to running" "confirmation shown"
assert_match "$out" "claude-later --in 4h \"wizard test payload\"" "argv preview matches"
assert_match "$out" "claude-later ARMED" "dry-run reached ARMED banner"

# Invalid input is re-prompted
out=$(printf 'banana\n4h\nf\n\nok\ny\n' \
  | "$CL_DIR/claude-later" --interactive --dry-run 2>&1 || true)
assert_match "$out" "invalid" "invalid time input rejected"

# !abort exits cleanly
out=$(printf '!abort\n' | "$CL_DIR/claude-later" --interactive 2>&1 || true)
assert_match "$out" "aborted" "!abort exits cleanly"

cleanup_test_state_files
cleanup_fake_project_dir
test_summary
```

- [ ] **Step 2: Write `tests/test_interactive_resolution.sh`**

```bash
#!/bin/bash
set -uo pipefail
CL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL_TEST_NAME="test_interactive_resolution"
. "$CL_DIR/tests/test-utils.sh"
. "$CL_DIR/lib/interactive.sh"

# Seed a fake project dir with two /rename'd transcripts
FAKE_PROJ=$(mktemp -d)
export CL_INTERACTIVE_FAKE_PROJ_DIR="$FAKE_PROJ"
cat > "$FAKE_PROJ/7f3a4c12-0000-4000-8000-000000000000.jsonl" <<EOF
{"type":"custom-title","customTitle":"nightly-refactor","sessionId":"7f3a4c12-0000-4000-8000-000000000000"}
EOF
cat > "$FAKE_PROJ/5e2d3b11-0000-4000-8000-000000000000.jsonl" <<EOF
{"type":"custom-title","customTitle":"morning-review","sessionId":"5e2d3b11-0000-4000-8000-000000000000"}
EOF

# Zero matches: empty list returned
got=$(cl_list_renamed_sessions "$FAKE_PROJ" | wc -l | tr -d ' ')
assert_eq "$got" "2" "lists two renamed sessions"

# Pick-by-exact-name returns the uuid
got=$(cl_resolve_session_name "$FAKE_PROJ" "nightly-refactor")
assert_eq "$got" "7f3a4c12-0000-4000-8000-000000000000" "resolves name to uuid"

# Zero-match returns nonzero
if cl_resolve_session_name "$FAKE_PROJ" "does-not-exist" >/dev/null; then
  assert_eq "resolved" "expected-fail" "nonexistent name"
else
  assert_eq "failed" "failed" "nonexistent name fails as expected"
fi

rm -rf "$FAKE_PROJ"
test_summary
```

- [ ] **Step 3: Verify red**

```
bash tests/test_interactive_resolution.sh
```
Expected: FAIL — no `lib/interactive.sh`.

- [ ] **Step 4: Write `lib/interactive.sh`**

```bash
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
      printf '    → fires %s (in %s)\n\n' \
        "$(wall_clock_for_epoch "$(( $(date +%s) + secs ))")" \
        "$(delta_human "$secs")" >&2
      break
    elif parse_at "$input" >/dev/null 2>&1; then
      ARG_AT="$input"
      local ep
      ep=$(parse_at "$input")
      printf '    → fires %s (in %s)\n\n' \
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
  while :; do
    _cl_iw_read '  Resume a previous Claude session? [f]resh / [u]uid / [n]ame: ' input || exit 0
    case "$input" in
      f|F|"") break ;;
      u|U)
        _cl_iw_read '    UUID: ' input || exit 0
        if [[ "$input" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
          resume_arg="--resume $input"
          break
        else
          printf '    not a valid UUID — try again\n' >&2
        fi
        ;;
      n|N)
        local list
        list=$(cl_list_renamed_sessions "$proj_dir")
        if [ -z "$list" ]; then
          printf '    no /rename'"'"'d sessions found in %s\n' "$proj_dir" >&2
          continue
        fi
        printf '    known sessions in this cwd:\n' >&2
        printf '%s\n' "$list" | awk -F'\t' '{printf "      [%d] %s  (%s)\n", NR, $1, $2}' >&2
        _cl_iw_read '    Pick by number or type the exact name: ' input || exit 0
        local chosen=""
        if [[ "$input" =~ ^[0-9]+$ ]]; then
          chosen=$(printf '%s\n' "$list" | awk -F'\t' -v i="$input" 'NR==i {print $1}')
        else
          chosen=$input
        fi
        local resolved
        if resolved=$(cl_resolve_session_name "$proj_dir" "$chosen"); then
          resume_arg="--resume-name $chosen"
          printf '    → %s (%s)\n' "$chosen" "$resolved" >&2
          break
        else
          printf '    no unique session named %s — try again\n' "$chosen" >&2
        fi
        ;;
      *) printf '    answer with f, u, or n\n' >&2 ;;
    esac
  done

  # Q3: extra flags
  _cl_iw_read '  Any extra claude flags? (enter for none): ' input || exit 0
  local combined="$resume_arg $input"
  combined=$(printf '%s' "$combined" | sed -e 's/^ *//' -e 's/ *$//' -e 's/  */ /g')
  if [ -n "$combined" ]; then
    ARG_CLAUDE_ARGS="$combined"
    # Dry-run-validate by invoking pf_4 with a subshell so any abort does not kill us
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
```

- [ ] **Step 5: Wire `--interactive` / `-i` into `claude-later`**

In `parse_args`, add cases:

```bash
--interactive|-i) ARG_INTERACTIVE=1;;
```

Add `ARG_INTERACTIVE=0` to the arg-default block at the top.

In `main`, after `parse_args "$@"` and before the caffeinate re-exec, add:

```bash
if [ "$ARG_INTERACTIVE" -eq 1 ]; then
  . "$CL_DIR/lib/interactive.sh"
  cl_wizard_run
fi
```

- [ ] **Step 6: Run all tests**
```
bash tests/run-all.sh
```
Expected: pass (wizard tests will only run when in iTerm2; otherwise self-skip).

- [ ] **Step 7: Commit**
```
git add lib/interactive.sh claude-later tests/test_interactive_wizard.sh tests/test_interactive_resolution.sh
git commit -m "feat: --interactive scheduling wizard"
```

---

## Task 12: Docs + version bump

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `claude-later` (`CL_VERSION="0.3.0"`)

- [ ] **Step 1: Update `CL_VERSION`**

In `claude-later`, change `CL_VERSION="0.2.1"` to `CL_VERSION="0.3.0"`.

- [ ] **Step 2: CHANGELOG entry**

Add under `## [Unreleased]` (promote to `## [0.3.0] — 2026-04-24`):

```markdown
## [0.3.0] — 2026-04-24

### Added
- `--interactive` / `-i` scheduling wizard that walks through time, resume, claude-args, and message with live validation, then hands off to the normal arm flow. Shows the equivalent non-interactive command at the confirmation step as a teaching surface.
- Live in-pane countdown replaces the silent sleep between arm and fire. `^C` cancels with a `cancelled_by_user` tombstone; `^D` re-prints the ARMED banner.
- Enriched ARMED banner enumerates every preflight that was verified at arm time and lists the residual risks (window close, reboot, lid close) that cannot be defended against.
- End-to-end test (`tests/integration/test_e2e_fake_claude.sh`) exercises the full arm→fire→deliver cycle against the `fake-claude` fixture. Resolves the spike tracked in `tests/README.md`.
- New tombstone class: `cancelled_by_user`.

### Changed
- Preflights extracted to `lib/preflights.sh` behind a registry API. Behavior preserved byte-for-byte; the banner uses the registry to render the "Verified now" list.

### Unchanged
- All existing flags. No breaking changes.
```

- [ ] **Step 3: README — document `--interactive`**

Add a subsection to the Usage section:

```markdown
### Interactive mode

If you forget the flag syntax, run the wizard:

```sh
claude-later --interactive    # or -i
```

It asks four questions (when, resume?, extra flags, message), validates each as you type, and shows the equivalent non-interactive command before arming:

```
This is equivalent to running:
  claude-later --in 4h --claude-args "--resume-name nightly" "review the PRs"
Proceed? [Y/n]
```

Type `!abort` at any prompt to exit cleanly.
```

Also add to the Options table: `| --interactive, -i | Walk through scheduling with a guided wizard. |`

And update the Status section: `**0.3.0 — Beta.**`

- [ ] **Step 4: Run the full suite one more time**

```
bash tests/run-all.sh
bash tests/integration/run-integration.sh
```
Expected: all green.

- [ ] **Step 5: Commit + tag**

```
git add README.md CHANGELOG.md claude-later
git commit -m "release: v0.3.0 — --interactive, countdown, enriched banner"
git tag v0.3.0
```

---

## Self-review checklist

- [x] Every spec section (wizard, banner, countdown, preflight registry, tombstone, testing) has at least one task.
- [x] No TBD / TODO / "implement later" / "add appropriate X" / placeholder code blocks.
- [x] Types and names consistent: `cl_pf_register`, `cl_pf_run_all`, `cl_pf_passed_labels`, `cl_pf_record_passed`, `cl_banner_render`, `cl_countdown_loop`, `cl_format_countdown`, `cl_wizard_run`, `cl_list_renamed_sessions`, `cl_resolve_session_name`, `cl_countdown_cancel_tombstone`.
- [x] Every task with code shows the actual code.
- [x] Exact file paths on every task.
- [x] Test commands have expected outcomes.
- [x] Commit at the end of each task.
- [x] Backward compatibility preserved (`sleep_until_fire` kept as a delegating function, all flags unchanged, schema_version unchanged).
- [x] Conditional branching for spike outcome is explicit, not vague.
