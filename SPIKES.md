# Unit 0 Empirical Spikes — Results

**Status:** 7 of 11 spikes complete (Tier A non-interactive). Spikes #3, #4, #5 require an interactive `claude` TUI session with the user present and are pending.

**CRITICAL spikes (#2, #3, #5, #9):** #2 and #9 GREEN; #3 and #5 PENDING.

**Major plan corrections discovered:**
1. iTerm2's scripting `id of session` is the **UUID portion of `$ITERM_SESSION_ID`** (e.g. `EDDAB47A-46AA-4781-B69E-64A270E0C61F`), not the full value (`w3t0p1:EDDAB47A-…`). The `wXtYpZ:` prefix is iTerm2's positional path and is not a valid scripting key. Strip via `${ITERM_SESSION_ID#*:}`.
2. The flat `tell session id "..."` form does **not** work. The osa wrappers must walk the hierarchy: `repeat with w in windows → tabs → sessions → if (id of s) is "<uuid>" then tell s → … end tell`.
3. State files should be **built** with `jq -n --arg ... --argjson ...` (not just *read* with `jq`). This eliminates the printf-templates approach and any escaping concerns. `jq` is already a hard dependency.
4. The arm-time `claude --version` capture + final-pre-fire recheck is the only practical detection for "claude self-updated overnight"; there is no reliable filesystem marker for a *pending* update.

---

## Spike #1 — iTerm2 `write text` into a shell — **GREEN**

**Question:** Does `tell session id … to write text` work without focus, with embedded specials, and submit on `newline YES`?

**Method:** From this Bash session running in an iTerm2 pane, attempted three forms of the AppleScript invocation. The first two failed with `(-1728) Can't get session id`. The third succeeded:

```applescript
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "EDDAB47A-46AA-4781-B69E-64A270E0C61F" then
          tell s
            write text ": claude-later spike1 ok " & (do shell script "date '+%H:%M:%S'") newline YES
          end tell
        end if
      end repeat
    end repeat
  end repeat
end tell
```

**Result:** The line `: claude-later spike1 ok 13:36:24` landed visibly in the user's pane. User confirmed by sending it back as a message.

**Chosen approach:** The hierarchy-walking form above. `lib/osa.sh` will encapsulate this so call sites see only `osa_write_text "$session_uuid" "$text"`.

**Open sub-questions for spike #5 (live TUI):**
- Does `newline YES` *submit* the message in claude's TUI, or insert a literal newline in the input box?
- Do special characters (`"`, `\`, `$`, `` ` ``) survive into claude's input vs. shell?
- Does claude's input handler receive `write text` as keyboard input or as a paste event?

---

## Spike #2 (CRITICAL) — Detached helper survives `exec` under caffeinate — **GREEN**

**Question:** Does `nohup helper & disown; exec other_thing` keep the helper alive after the parent is replaced, including when the parent is itself a child of `caffeinate -dimsu`?

**Method:** `claude-later/spikes/scratch/test_helper_survival.sh` runs two scenarios:
1. `( nohup helper & disown; sleep 0.5; exec sleep 3 )` — verify helper PID alive after parent dies.
2. `caffeinate -dimsu /bin/bash -c "nohup helper & disown; sleep 0.5; exec sleep 3"` — verify same under caffeinate.

The helper logs its own PID and PPID every 500ms to `/tmp/cl_helper_survival.log`.

**Result:**
- **Test 1:** Helper PID 43240 still alive after exec; reparented to PID 1. PASS.
- **Test 2 (under caffeinate):** Helper PID 43389 still alive after exec; reparented to PID 1. caffeinate did NOT prevent reparenting. PASS.

**Chosen approach:** `nohup "$helper" "$state_path" </dev/null >>"$log_path" 2>&1 & disown` from inside the in-pane script. Helper inherits a closed stdin so it won't hold the tty. After `exec`, the helper is reparented to PID 1 in both test scenarios.

**Caveats:**
- I tested with `exec sleep 3`, not `exec vim` or `exec claude`. The reasoning: `exec` replaces the process *before* the new program runs; the helper was already detached at that point. The new process's tty handling cannot affect a process that has no controlling tty (which `nohup … </dev/null` ensures). The test result is structurally sufficient, but spike #5 will exercise the full path (helper polling iTerm2 from outside while `claude` runs in the pane) and provide end-to-end confidence.
- Stale-lock recovery using `ps -p $pid -o command=` will see `/bin/bash /path/to/claude-later-helper` — clean and identifiable.

**Fallback (not needed):** Documented in plan: `python3 -c 'import os; os.setsid(); …'`, then Swift, then a small C wrapper. None required.

---

## Spike #6 — Secure Input detection — **GREEN**

**Question:** Can the script reliably detect whether macOS Secure Input is engaged?

**Method:**
1. `ioreg -l -w 0 | grep -i SecureInput` — returned nothing (Secure Input not currently engaged), but the absence-of-string approach is fragile.
2. `swift -e 'import Carbon; print(IsSecureEventInputEnabled())'` — returned `false`. Reliable.

**Result:** Swift one-liner is the chosen approach.

```sh
swift -e 'import Carbon; print(IsSecureEventInputEnabled())'
```

Returns `true` or `false`. Startup time measured at **0.187s** — fast enough for arm-time pre-flight, fast enough for the T−0 final pre-fire recheck.

**Decision:** The in-pane script does Secure Input checks at arm time and at T−0 (final pre-fire). The detached helper does **not** poll Secure Input continuously — its 250ms poll loop wouldn't tolerate 187ms per call, and the script's T−0 check is sufficient because Secure Input is unlikely to engage in the ~5s window between T−5s helper spawn and T−0 exec.

**Pre-flight #2 dependency:** Add `swift` to the binary check list (it's always present on dev Macs but the principle of "every dependency is a checked binary" holds).

---

## Spike #7 — Pending Claude Code update detection — **DEGRADED to doc note**

**Question:** Can the script detect that a Claude Code update is pending (would show a banner or modal at next launch)?

**Method:** Searched `~/.claude/` for update marker files. Inspected `claude --version` output for any "update available" messaging. Looked for files like `~/.config/claude`, `~/Library/Application Support/Claude Code`.

**Result:** No reliable marker. `claude --version` returns `2.1.92 (Claude Code)` (exit 0) with no update info.

**Chosen approach:** Degrade to a doc note in the snippet README: "If you've been notified that a Claude Code update is available, run `claude` once interactively to clear any update banner before scheduling overnight runs." Pre-flight #2 captures `claude --version` and the final pre-fire check at T−0 re-runs it; if the version string changed between arm and fire, we abort with `claude_version_changed`. This catches the case where the update *installed itself* during the wait window — the more dangerous failure mode anyway.

**Trade-off acknowledged in risk table.**

---

## Spike #8 — MCP interactive-auth detection — **GREEN**

**Question:** Can the script detect that an MCP server requires interactive auth (which would block claude startup with an auth prompt)?

**Method:** Searched `~/.claude/` for any auth-related cache files.

**Result:** Found `~/.claude/mcp-needs-auth-cache.json`:

```json
{"claude.ai Gmail":{"timestamp":1775561240781},"claude.ai Google Calendar":{"timestamp":1775561240774}}
```

This file maps MCP server name → "needs auth" timestamp. If the file exists and is non-empty, at least one MCP server needs auth and `claude` will likely show an auth prompt at next launch.

**Chosen approach:** Pre-flight #12 reads this file and aborts if it's non-empty:

```sh
if [ -s ~/.claude/mcp-needs-auth-cache.json ] && \
   [ "$(jq 'length' ~/.claude/mcp-needs-auth-cache.json)" != "0" ]; then
  abort "MCP servers need interactive auth (see ~/.claude/mcp-needs-auth-cache.json). Run \`claude\` once interactively to authenticate before scheduling."
fi
```

**Caveat:** The file is global, not project-scoped. If an MCP server only triggers in a specific project, this check may be falsely strict in unrelated cwds. Acceptable as a "fail loud" default; the user can resolve any false positive by completing the auth.

**Risk note:** the user (AJ) currently has Gmail and Google Calendar MCP servers needing auth right now. **This means in the production snippet, pre-flight #12 will refuse to arm until those auths are completed.** Worth knowing before the first real use.

---

## Spike #9 (CRITICAL) — Bash 3.2 compatibility — **GREEN**

**Question:** Do all the patterns the snippet needs work under macOS system Bash (3.2.57)?

**Method:** `claude-later/spikes/scratch/test_bash32.sh` exercises 9 patterns:
1. `if ! func; then` (errexit propagation in functions)
2. `func || fallback`
3. Per-signal trap installation (no `$SIG` variable)
4. `[[ … =~ … ]]` regex with `BASH_REMATCH`, including UUID match and shell injection rejection
5. `$ITERM_SESSION_ID` allowlist regex
6. `--in 2h30m` parser using `BASH_REMATCH` loop
7. BSD `date -j -f` for `HH:MM` and `YYYY-MM-DD HH:MM:SS` parsing
8. **DST gap detection via round-trip** — `2026-03-08 02:30` (US Pacific spring-forward) parses to `2026-03-08 03:30` (1772965800), so the comparison `back != input` reliably catches the gap.
9. `printf`-built JSON parsed by `jq` (later superseded by `jq -n --arg` direct construction)

**Result:** All 9 PASS. Bash 3.2.57 is sufficient. No newer-bash dependency needed.

**Plan amendment:** State files are now built with `jq -n --arg msg "$message" --argjson epoch "$target" ... '{...}'` rather than printf templates. Eliminates the python3 dependency for JSON escaping (which was an oversight in my first test 9). `jq` is already required, so this is no-cost.

**Patterns committed for production use:**
- `if ! func; then …; fi` for all error checking (no reliance on errexit propagation through pipelines/conditionals)
- One trap per signal, each setting a `last_signal=HUP|INT|TERM` flag and calling a single cleanup function
- `[[ "$value" =~ ^…$ ]]` for all input validation regexes
- `BASH_REMATCH[N]` for capture groups
- `date -j -f "%Y-%m-%d %H:%M:%S" "$input" "+%s"` for parsing, `date -j -r "$epoch" "+%Y-%m-%d %H:%M:%S"` for reverse round-trip
- `jq -n --arg key "$value" '{key: $key}'` for state file construction

---

## Spike #10 — caffeinate signal forwarding — **GREEN**

**Question:** Does `caffeinate -dimsu` forward signals (specifically SIGTERM, SIGHUP) to its child?

**Method:** Spawned `caffeinate -dimsu sleep 30 &`, captured caffeinate's pid and the child sleep pid, sent `kill -TERM` to caffeinate, verified both processes died.

**Result:** Both PIDs gone after `kill -TERM`. caffeinate forwards signals correctly. PASS.

**Implication for the production design:** When the iTerm2 window closes, SIGHUP propagates: iTerm2 → bash session → caffeinate → in-pane script. The script's SIGHUP trap fires; tombstone gets written; the helper (which is detached and reparented to PID 1) does NOT receive the SIGHUP automatically — it must be SIGTERM'd by the script as part of the trap handler.

---

## Spike #11 — `$ITERM_SESSION_ID` format — **GREEN**

**Question:** What does `$ITERM_SESSION_ID` look like, and what's the strict allowlist regex?

**Method:** `echo "$ITERM_SESSION_ID"` from inside an iTerm2 pane.

**Result:** `w3t0p1:EDDAB47A-46AA-4781-B69E-64A270E0C61F`.

**Format:** `w<window_int>t<tab_int>p<pane_int>:<UUID-uppercase>`.

**Allowlist regex:** `^w[0-9]+t[0-9]+p[0-9]+:[0-9A-F-]{36}$`

**CRITICAL:** The UUID portion is what iTerm2's AppleScript dictionary calls `id of session`. The `wXtYpZ:` prefix is iTerm2's positional descriptor and is NOT a valid scripting key. The `lib/osa.sh` wrappers must extract the UUID portion before using it:

```sh
osa_session_uuid() {
  printf '%s' "${ITERM_SESSION_ID#*:}"
}
```

This is a load-bearing detail that the brainstorm and original plan got slightly wrong.

---

## Spike #3 (CRITICAL) — Steady-state TUI readiness signal — **GREEN — STRONGER THAN HOPED**

**Question:** What's the polling interval, stable-poll count N, and glyph signature for detecting that `claude` is idle and ready for input?

**Method:** From a separate Bash session, called `tell session id "<uuid>" to get contents` 20 times against a live `claude` pane sitting at the steady-state prompt. Hashed each capture, recorded byte count, observed wall-clock cadence.

**Result:**
```
[13:45:28.627] iter=1  hash=a75dc7d298f9372caebbe9a8e7f0dd98 bytes=2409
[13:45:29.996] iter=2  hash=a75dc7d298f9372caebbe9a8e7f0dd98 bytes=2409
... (all 20 iterations)
[13:45:55.971] iter=20 hash=a75dc7d298f9372caebbe9a8e7f0dd98 bytes=2409
```

**All 20 polls returned identical content.** Hash and byte count never changed. The steady-state Claude Code TUI is **completely static** when idle — no cursor blink, no spinner, no time tick.

**Chosen approach:**
- **Polling interval:** 250ms target (the script's `sleep 0.25` between calls).
- **Actual cadence:** ~1.3s wall-clock between polls — `osascript` cold-start is ~1s per call. Plan correction: real ready latency for N=3 stable polls is ~4s, not ~750ms.
- **Stable-poll count N:** 3 (gives a generous safety margin; even N=2 would suffice).
- **Glyph signature (defense in depth):** match the substring `❯` (U+276F HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT) in the stable contents. The full prompt block is:
  ```
  ───────────────────…─── (long horizontal rule, U+2500)
  ❯
  ───────────────────…───
    [Opus 4.6 (1M context)] │ … │ 📁 <cwd> │ ⚙️ auto
    ⏵⏵ bypass permissions on (shift+tab to cycle)
  ```
- The glyph match is a *secondary* check; the primary signal is "contents stable for N polls." If both are true, the helper proceeds. If hash is stable but `❯` is missing, the helper aborts with `unexpected_modal` (catches a frozen modal that happens to be static).

**Plan amendments:**
- Drop the "256ms polling for fast detection" assumption — actual minimum cadence is bounded by `osascript` cold-start (~1s).
- Drop the "version-pinned glyph match" worry — `❯` is the glyph in this version (2.1.92), and the stable-hash check is the primary signal anyway. A future Claude Code version that changed the prompt glyph would still hit "stable contents but no `❯`" → abort with `unexpected_modal`, which is the loud-failure outcome we want.
- Readiness latency budget: the 60s readiness timeout in Unit 5 is more than enough — typical real latency is ~4s.

---

## Spike #4 — Modal-state captures — **PARTIALLY DEFERRED, NO LONGER CRITICAL**

**Status reclassified:** Spike #3 found that the stable-hash + glyph-match check is sufficient on its own. Modal signatures become a "nice to have" for better error messages, not a load-bearing requirement. The helper aborts on any stable-but-wrong-shape state regardless.

**What WAS captured (during the live spike #5 run):**
- The "permissions bypass on" steady-state — the pane this conversation was tested against was in `⏵⏵ bypass permissions on` mode, which presumably skips the trust-folder prompt entirely. Captured in `live_tui_results/spike5_before.txt`.

**What was NOT captured (deferred to later):**
- Trust-folder modal (would need a fresh-dir pane in default permission mode)
- Model picker modal (uncertain if it exists in current Claude Code)
- Update banner (no update currently pending)
- MCP auth dialog (could be triggered by Gmail/Calendar — see Spike #8 finding)
- `claude --resume` picker variants (the one I need most)

**Decision:** Defer the explicit modal captures. The helper's "stable but missing `❯`" check is sufficient for v1; if real-world use turns up specific modals worth detecting separately, we can add signatures to `lib/osa.sh` later. The plan's `tests/fixtures/modal-*.txt` files will exist but be empty placeholders for now.

**Important live discovery:** the test pane had **`bypass permissions on`** mode active. This is significant — pre-flight #12 should also detect/note the permission mode, since some modes (notably `auto` / `bypass permissions on`) eliminate the trust-folder modal entirely. **Unknown:** does pre-flight need to require a specific permission mode, or is "any mode where claude reaches the steady-state prompt without manual intervention" acceptable? The pragmatic answer is "any mode" — the readiness detector validates the outcome regardless.

---

## Spike #5 (CRITICAL) — `write_text` into the live `claude` TUI — **GREEN ✅ DEFINITIVELY**

**Question:** Does `osa write_text … newline YES` deliver a string into a live Claude Code TUI's input box as keyboard input AND submit it?

**Method:** From a separate Bash session, called `osa_write_text "<uuid>" 'hello "world" $foo \backslash `backtick` :: claude-later spike5'` against a live claude pane at the steady-state prompt. Captured pane contents 1s and 4s after.

**Result:** The captured pane contents (`live_tui_results/spike5_before.txt`) show:

```
❯ hello "world" $foo \backslash `backtick` :: claude-later spike5

⏺ Noted—looks like you're testing how special characters round-trip through the input. Let me know if you'd like me to do something with that string.
```

**Every criterion passed:**

| Criterion | Result |
|---|---|
| (a) Characters appear in claude's input box, not scrollback | ✅ Appeared on the prompt line after `❯` |
| (b) Treated as keyboard input, not bracketed paste | ✅ No paste indicator; claude responded as if typed |
| (c) `newline YES` actually submits the message | ✅ Claude *responded* (lines 29-30 of capture) — Enter was honored |
| (d) Special characters survive unchanged | ✅ `"world"`, `$foo`, `\backslash`, `` `backtick` `` all literal |
| (e) No characters lost | ✅ Full string intact |

**Bonus finding:** After claude responded, the TUI returned to the steady-state prompt within ~4 seconds (visible in `spike5_after_4s.txt`). This means the **same stable-hash detector** the helper uses to detect "ready before send" can also detect "claude finished responding" for the post-send observation phase. Unit 5's "wait ≥5s after send" can be replaced with "wait until contents are stable again, up to 30s budget."

**Token cost note:** Each spike #5 run consumes a real Claude API exchange. Subsequent spike runs should use the shortest possible test message (e.g., `: test`, which claude will likely just acknowledge briefly).

**The architecture's load-bearing premise is validated.** The exec-in-place + detached helper + osa write_text design works.

---

## SUMMARY: Unit 0 status — **READY TO PROCEED WITH UNIT 1**

| # | Spike | Status | Critical? |
|---|---|---|---|
| 1 | iTerm2 `write text` form | ✅ GREEN | |
| 2 | Helper survives `exec` under caffeinate | ✅ GREEN | CRITICAL ✅ |
| 3 | Steady-state TUI readiness signal | ✅ GREEN | CRITICAL ✅ |
| 4 | Modal-state captures | ⚠️ DEFERRED (no longer critical) | |
| 5 | `write_text` into live claude TUI | ✅ GREEN | CRITICAL ✅ |
| 6 | Secure Input detection | ✅ GREEN | |
| 7 | Pending update detection | ⚠️ DEGRADED to doc note | |
| 8 | MCP auth detection | ✅ GREEN | |
| 9 | Bash 3.2 compatibility | ✅ GREEN | CRITICAL ✅ |
| 10 | caffeinate signal forwarding | ✅ GREEN | |
| 11 | `$ITERM_SESSION_ID` format | ✅ GREEN | |

**All four CRITICAL spikes returned GREEN. The plan is buildable as designed, with the corrections noted above.**

**Net plan corrections from Unit 0:**
1. iTerm2 scripting `id` is the UUID portion of `$ITERM_SESSION_ID` only; flat `tell session id` doesn't work; must walk hierarchy.
2. State files built with `jq -n --arg`, not printf templates.
3. cwd-slug algorithm: `/` AND `_` both → `-`.
4. Polling cadence is bounded by `osascript` cold-start (~1s/call), not the requested sleep interval.
5. Stable-hash check alone is sufficient as the readiness signal; glyph match is defense-in-depth, not load-bearing.
6. Post-send observation can use the same stable-hash detector to know when claude has finished responding.
7. Pre-flight #2 must check for `swift` (used at arm time and T−0 for Secure Input).
8. The user's current MCP auth state will block arming until Gmail/Calendar are reauth'd — worth knowing before first use.
9. `bypass permissions on` mode skips the trust-folder modal — permission mode isn't required to be a specific value, just one where claude reaches steady-state without intervention.
