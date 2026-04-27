# claude-later --interactive demo (full simulated flow)
# Render with: vhs assets/demo.tape
#
# vhs runs in its own embedded terminal (ttyd), not iTerm2, so the iTerm-only
# preflights would block a real fire here. The first half is a genuine
# wizard run (--dry-run); after the confirmation we switch to a simulated
# replay (assets/demo-sim.sh) that paints the rest of the happy-path bytes
# without us injecting real keystrokes.

Output assets/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 720
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set PlaybackSpeed 1.0

# --- Setup
Hide
Type `cd ~/GitHub/projects/claude_later`
Enter
Type `export TERM_PROGRAM=iTerm.app ITERM_SESSION_ID="w0t0p0:00000000-0000-0000-0000-000000000000"`
Enter
Type `export PS1='$ '`
Enter
Type `clear`
Enter
Show

# --- Real wizard run (--dry-run keeps it safe in vhs)
Sleep 600ms
Type `./claude-later --interactive --dry-run --skip-mcp-check`
Sleep 500ms
Enter

# Q1: when
Sleep 1200ms
Type `8s`
Sleep 300ms
Enter

# Q2: resume — Enter for default No
Sleep 1000ms
Enter

# Q3: extra claude flags — Enter for none
Sleep 900ms
Enter

# Q4: message
Sleep 900ms
Type `say hello in 3 words`
Sleep 400ms
Enter

# Pause briefly on "Proceed?" so viewers see the equivalent-command line
Sleep 1800ms

# Bail out before vhs hits iTerm-only preflights
Ctrl+C
Sleep 300ms

# --- Simulated continuation
Hide
Type `clear && bash assets/demo-sim.sh`
Show
Enter

# Wait for demo-sim.sh to finish (countdown 3s + helper spawn 0.6s
# + splash 0.4s + message 1.1s + response 1.5s ≈ 7s) plus a brief
# hold on the final response so the loop seam is comfortable.
Sleep 7500ms
