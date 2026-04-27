#!/bin/bash
# assets/demo-sim.sh — paint the post-confirmation half of the demo gif.
#
# Used by assets/demo.tape (vhs script) to simulate ARMED → countdown →
# fire → claude splash → response in a single pane. We can't run the
# real fire path inside vhs's embedded terminal because the iTerm-only
# preflights can't resolve a real session. This script is presentation-
# only — bytes printed match the real flow.

# ARMED banner (compressed: full banner is verbose)
printf '\n\033[32m✓ claude-later ARMED\033[0m\n'
printf '  Fire time : 2026-04-27 14:15:08 CEST (+0200)  (in +8s)\n'
printf '  Pane      : w12t0p0 (UUID 355DEB7F-…)\n'
printf '  Invocation: claude (no passthrough args)\n'
printf '  Message   : say\\ hello\\ in\\ 3\\ words (20 chars)\n'
printf '  Caffeinate: active\n\n'
printf '  Verified now (10 checks passed):\n'
printf '    \033[32m✓\033[0m macOS + iTerm2 + not in tmux\n'
printf '    \033[32m✓\033[0m claude + jq + swift + caffeinate + pmset present\n'
printf '    \033[32m✓\033[0m --at / --in parses to a valid future time\n'
printf '    \033[32m✓\033[0m message is single-line, printable, non-empty\n'
printf '    \033[32m✓\033[0m iTerm2 scripting reachable; Secure Input not engaged\n'
printf '    \033[32m✓\033[0m on AC power; no other claude-later armed in this pane\n'
printf '    \033[32m✓\033[0m claude first-run hygiene; no MCP auth pending\n\n'
printf '  \033[33mDO NOT close this iTerm2 window. Closing it cancels the job.\033[0m\n\n'
sleep 0.8

# Countdown — same `\r\033[K` pattern the real one uses
for s in 7 6 5; do
  printf '\r\033[K⏳ claude-later • fires in %ds • ^C to cancel' "$s"
  sleep 1
done

# T-5s → helper takes over
printf '\r\033[K→ T−5s, spawning helper...\n\n'
sleep 0.6

# Real claude splash
printf ' \033[38;5;208m▐▛███▜▌\033[0m   Claude Code\n'
printf '\033[38;5;208m▝▜█████▛▘\033[0m  Sonnet 4.6 · /help for commands\n'
printf '  \033[38;5;208m▘▘ ▝▝\033[0m\n\n'
printf -- '─────────────────────────────────────────────────\n'
sleep 0.4

# Injected message lands in the input box
printf '❯ say hello in 3 words\n'
sleep 0.5
printf -- '─────────────────────────────────────────────────\n\n'
sleep 0.6

# Claude's response (real claude tends to be brief for this prompt)
printf '⏺ Hi there friend\n\n'
sleep 1.5
