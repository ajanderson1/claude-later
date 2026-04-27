# claude-later --interactive demo
# Render with: vhs assets/demo.tape

Output assets/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1000
Set Height 600
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0

# --- Setup: stand-in iTerm2 env so the wizard's preflight gate passes far
# enough to show the wizard. The recording exits at the confirmation prompt
# before any iTerm2-only preflights run. No keystrokes are ever injected.
Hide
Type `cd ~/GitHub/projects/claude_later`
Enter
Type `export TERM_PROGRAM=iTerm.app ITERM_SESSION_ID="w0t0p0:00000000-0000-0000-0000-000000000000"`
Enter
Type `clear`
Enter
Show

# --- Demo starts here
Sleep 800ms
Type `# claude-later: schedule a Claude Code TUI session for later`
Sleep 1500ms
Enter

Type `./claude-later --interactive --dry-run --skip-mcp-check`
Sleep 600ms
Enter

# Wizard prompt 1: when
Sleep 2200ms
Type `30s`
Sleep 600ms
Enter

# Wizard prompt 2: resume — accept default (No)
Sleep 1800ms
Enter

# Wizard prompt 3: extra claude flags — none
Sleep 1500ms
Enter

# Wizard prompt 4: message
Sleep 1500ms
Type `summarize today's commits and open a PR`
Sleep 800ms
Enter

# Pause on the "Proceed?" line so viewers can read the equivalent command.
Sleep 4500ms

# Bail out instead of confirming (would otherwise hit iTerm-specific preflights
# that aren't reachable from vhs's embedded terminal).
Ctrl+C
Sleep 800ms
