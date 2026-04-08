# Roadmap

`claude-later` is intentionally narrow in v0.1.0 — macOS + iTerm2 only. This document describes what broader distribution would look like and what work it would require. It is **exploratory**, not a commitment.

## Principles

1. **Loud failure over silent success.** Whatever environment we support, pre-flight must refuse to arm when it can't guarantee delivery.
2. **Keystroke injection over `-p`.** The whole point of `claude-later` is the live interactive TUI takeover. Any port that falls back to headless mode is a different tool.
3. **One fire primitive per terminal.** Don't try to be universal — ship a clean port per supported terminal, not a lowest-common-denominator compatibility shim.

## Tier 1 — Targeted ports

Each of these is a realistic ~weekend of focused work if someone knows the target environment.

### tmux (any OS)

**Why it's worth it:** tmux is the most common terminal multiplexer for developers who live in the CLI. It has a well-defined `send-keys` primitive that injects keystrokes into a pane, addressable by session/window/pane index. It works over SSH, which opens the door to scheduling from a laptop but firing inside a dev server.

**What changes vs iTerm2:**
- `osa_write_text` → `tmux send-keys -t <target> -- "$msg"` + `tmux send-keys -t <target> Enter`
- `osa_get_contents` → `tmux capture-pane -t <target> -p`
- `osa_session_alive` → `tmux has-session -t <target>` or pane-id lookup
- `$ITERM_SESSION_ID` → `$TMUX_PANE`
- No iTerm2 scripting permission prompt; no Automation settings
- `caffeinate` still works on macOS; use `systemd-inhibit` on Linux
- `sec_input_engaged` has no real equivalent outside macOS; skip on Linux, keep on macOS

**What gets harder:**
- Detecting the `❯` glyph in captured text works the same way (assuming the terminal emulator supports UTF-8).
- Window-closing detection: a pane can die without the parent session dying. Need a different liveness check.
- First-run hygiene: no `~/.claude/projects/-<slug>/` equivalent check that's cross-platform.

**Architecture:** introduce `lib/driver/` directory with `iterm2.sh` (current) and `tmux.sh` (new). Pre-flight picks a driver based on env. Helpers dispatch through a thin shim.

### Ghostty (macOS primary, eventually cross-platform)

**Why it's worth it:** Mitchell Hashimoto's Ghostty is the fastest-growing "modern" terminal for Mac users who want something native-feeling but not locked to iTerm2. It has CLI action hooks via `ghostty +show-config` and is building out scripting support but as of 2026-04 **does not yet have a mature keystroke-injection API**.

**Blocking issue:** Ghostty needs a native scripting surface equivalent to iTerm2's `write text`. Until it ships, a Ghostty port would have to either (a) use OS-level synthetic keystrokes via `osascript -e 'tell application "System Events" to keystroke ...'` — which targets the *frontmost* window and is fragile — or (b) hack pty injection which is ugly and unreliable.

**Status:** Track Ghostty's scripting roadmap. Revisit when they ship a stable API.

### Alacritty (cross-platform)

**Why it's worth it:** Alacritty users care about performance, are often power users, and often run inside tmux — which means **the tmux port covers most Alacritty users for free**.

**Direct Alacritty port (non-tmux):** Alacritty has no AppleScript surface, no CLI control, no `send-keys`. The only option is OS-level synthetic keystrokes, which is frontmost-window-only and fragile.

**Recommendation:** Don't build a direct Alacritty port. Ship the tmux port and document "Alacritty + tmux" as supported.

### Kitty (cross-platform)

**Why it's worth it:** Kitty has an excellent remote-control protocol — `kitten @ send-text --match title:mypane "hello"` — that's a direct analog of iTerm2's `write text`. This is the most promising non-iTerm2 target.

**Requirements:**
- User must enable `allow_remote_control yes` in `kitty.conf`
- Socket-based control: `--to unix:/tmp/kitty-socket` or similar
- Window/tab addressing via `--match`

**What changes vs iTerm2:**
- `osa_write_text` → `kitten @ --to $SOCKET send-text --match "$MATCH" -- "$msg\n"`
- `osa_get_contents` → `kitten @ --to $SOCKET get-text --match "$MATCH"`
- `$ITERM_SESSION_ID` → `$KITTY_WINDOW_ID` + `$KITTY_LISTEN_ON`

**Effort:** Probably one focused evening for a working port. Should ship as a sibling driver to iTerm2.

## Tier 2 — Architectural work

### Liveness watchdog for rate-limit recovery

Currently the user has to manually note the session UUID and the reset timestamp, then compose the `--at ... --resume ...` invocation. A watchdog mode could automate this:

```sh
claude-later --watch-pane
```

This would:
1. Attach to the current iTerm2 pane via `osa_get_contents` in a polling loop.
2. Scan for the Claude Code rate-limit error string (`Claude usage limit reached. Your limit will reset at ...`).
3. Extract the reset timestamp from the error.
4. Extract the session UUID from the most recent `~/.claude/projects/-<slug>/*.jsonl` (sorted by mtime).
5. Self-arm `claude-later --at <reset+5min> --resume <uuid> "continue"` and exit.

**Risks:** Parsing a natural-language error string is fragile; Claude Code's error format could change. Would need a version check and per-version regex.

**Alternative:** If Claude Code ever exposes the reset time in a machine-readable place (a file, an env var on exit, a JSON field), use that instead.

### Schema v2 for multi-pane scheduling

Current state file is per-pane. What about "arm this message into pane B from pane A"? Would require:
- Decoupling `CL_PANE_ID` from `$ITERM_SESSION_ID`
- Named target syntax: `claude-later --target tab:3 ...` or `--target name:"morning review"`
- Pre-flight that validates the target pane is reachable at arm time AND at fire time

**Priority:** Low until someone asks for it.

### Desktop notifications with actions

Currently `notify` uses `osascript display notification`, which shows a banner but supports no actions. Modern macOS notifications can have clickable buttons. Could offer:
- "Open log" (opens the log file in default viewer)
- "Cancel scheduled job" (invalidates the state file)
- "Retry now" (re-arms the same job immediately)

This requires `terminal-notifier` or a small Swift helper. Adds a dependency for modest UX polish. **Defer until v0.3+.**

## Tier 3 — Non-goals

Things I'm deliberately **not** planning to do, with reasoning:

### `claude -p` headless fallback

It would trivially expand platform support, but the whole point of `claude-later` is the live TUI takeover. Users who want headless already have `at`, `cron`, `launchd`, and Desktop Scheduled Tasks.

### Homebrew formula

Premature. v0.1.0 is a 5-file install. Once v0.2 adds real features that more than a handful of people care about, revisit.

### GUI wrapper

Out of scope. This is a CLI tool for CLI users.

### Windows support

Not unless someone contributes a Windows Terminal port AND Claude Code's TUI runs reliably under Windows Terminal. Neither of those is a given today.

### Cross-language rewrite (Rust/Go)

Bash is the right language for this. The dependency footprint is the standard Unix toolbox. A rewrite would add install complexity and build infrastructure for zero functional gain. If a specific bottleneck ever justifies native code, rewrite only that piece as a helper binary — not the whole thing.

## Contributing

If you want to help with any of the above, open an issue first describing the approach. The structure of the project makes it easy to add a new driver without touching the existing one — see `lib/osa.sh` for the abstraction boundary we'd want to formalize for Tier 1 ports.

## Version plan

- **v0.1.x** — Bugfixes and hardening for the iTerm2 macOS path. No new features.
- **v0.2.0** — The first tier 1 port that materializes (likely tmux or kitty, depending on demand).
- **v0.3.0** — Watchdog mode for rate-limit recovery automation, if there's a clean way to detect the error.
- **v1.0.0** — When the CLI surface has been stable for 3+ months across at least two drivers and the test suite covers all tombstone paths automatically.

This is aspirational, not a commitment.
