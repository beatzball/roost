# A review flock, end to end: into roost, Claude drafts a design, three other
# agents on three harnesses review it in parallel, Claude folds their notes in
# and hands you the plan in a pane on the right.
#
#   ./demo/record.sh flock
#
# Always record through demo/record.sh: it starts from an empty environment and
# refuses to finish if any pane shows the home path, username or an email.
#
# Live agents, so every wait is on what appears on screen, never a guessed
# number of seconds. A dry run took ~5.5 minutes: reviewers start around 80s,
# sonnet and codex finish around 2 minutes, nemotron around 4, the plan opens
# around 5.5. The waits are recorded Hidden, so the video cuts between the
# moments that matter.
Output demo/flock.webm
Output demo/flock.mp4

Set Shell "bash"
# A Nerd Font, because roost's status line is powerline separators and state
# glyphs from the private-use area, which render blank in anything else.
Set FontFamily "FiraCode Nerd Font Mono"
# 22 at this width: readable when the video is shown ~1070px wide on the page,
# and ~133 columns, so the plan's pane is ~66 wide.
Set FontSize 22
Set Width 1800
Set Height 920
Set Padding 20
Set Framerate 30
Set TypingSpeed 40ms
Set Theme { "name": "roost", "background": "#211e38", "foreground": "#c8c3e0", "cursor": "#bd93f9", "selection": "#3a3558", "black": "#211e38", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#7c6ff0", "magenta": "#bd93f9", "cyan": "#8be9fd", "white": "#c8c3e0", "brightBlack": "#8a84b0", "brightRed": "#ff6e6e", "brightGreen": "#69ff94", "brightYellow": "#ffffa5", "brightBlue": "#9d8df5", "brightMagenta": "#d6acff", "brightCyan": "#a4ffff", "brightWhite": "#e0dcf5" }

# --- setup, off camera --------------------------------------------------
# Demo server, config, pane shell and wrappers (demo/lib.sh). The wrappers on
# PATH give every agent -- including the three Claude starts itself -- the demo
# flags without them being typed on camera. ROOST_VIEW_MIN_COLS is lowered so
# `roost view` opens a pane beside the lead rather than a separate window.
Hide
Type 'export ROOST_SOCKET=/tmp/roost-demo-sock/roost XDG_CONFIG_HOME=/tmp/roost-demo-xdg ZDOTDIR=/tmp/roost-demo-zdot ROOST_VIEW_MIN_COLS=60 PATH=/tmp/roost-demo-bin:$PATH'
Enter
Type 'export PS1="\[\e[38;2;124;111;240m\]❯\[\e[0m\] "'
Enter
Type "cd /tmp/roost-demo-repo && clear"
Enter
Sleep 1s
Show

# --- into roost, start Claude ---------------------------------------------
Sleep 1200ms
Type "roost"
Sleep 400ms
Enter
Wait+Screen@20s /main/
Hide
Type "tmux rename-window lead && clear"
Enter
Sleep 800ms
Show
Sleep 800ms
Type "claude"
Sleep 400ms
Enter
Wait+Screen@40s /auto mode|for shortcuts|bypass permissions/
Sleep 1500ms

# --- the ask -------------------------------------------------------------
# "no hard line wraps": glow keeps a source file's line breaks, so a wrapped
# PLAN.md breaks mid-sentence in a narrow pane at any render width.
Type@22ms "Write PLAN.md, a short design for inline images in roost on kitty-protocol terminals: prose, no checklists, no hard line wraps. Get it reviewed in parallel in roost windows by claude on sonnet, codex on gpt-5.6-terra and opencode on nemotron-3.5-lightning-free. Fold in their feedback and show me the plan with roost view and preen."
Sleep 700ms
Enter
Sleep 6s

# --- the flock: three reviewers on three harnesses --------------------------
# Wait until the last reviewer is WORKING, not merely open. Waiting on its tab
# appearing cut in before any reviewer had been prompted, and the switcher then
# listed all three with no state at all.
#
# U+F252 is roost's nerd "working" glyph (roost_glyphset in
# scripts/lib/roost-config.sh), and a tab reads "<glyph> <index> <name>", so
# this is window 4 -- the third reviewer, opened last -- badged working. It does
# not depend on the name Claude gives the window, which changed between runs.
# Checked both ways before use: it matched the working glyph and timed out on
# the idle one.
Hide
Wait+Screen@480s /\x{F252} 4 /
# Straight in: the first two reviewers finish in under a minute, and the shot
# is worth most while all three are still badged working.
Show
Sleep 4s

# The switcher: every agent on the server, its state, how long it has had it.
Ctrl+S
Type "a"
Sleep 4500ms
Escape
Sleep 1s

# A look at two of the reviewers at work: codex, then opencode.
Ctrl+S
Type "3"
Sleep 4500ms
Ctrl+S
Type "4"
Sleep 4500ms
Ctrl+S
Type "1"
Sleep 1500ms

# --- the hand-off: the plan, reviewed, in a pane on the right ----------------
# Wait for the lead's turn to end, which is after it has opened the view. Not
# on less's "(END)": that only shows when the whole file fits the pane, and a
# reviewed plan does not, so less shows ":" and the wait never ends. The turn
# line reads "Baked for 5m 29s · done" -- minutes as well as seconds, so the
# pattern allows both. Window 1 is in front here, so no reviewer's own "done"
# line is on screen to match instead.
Hide
Wait+Screen@900s /for [0-9hms ]+· done/
Sleep 2s
# Claude offers a greyed follow-up in its input box when a turn ends.
Escape
Sleep 500ms
Show
Sleep 3s
Ctrl+S
Type "l"
Sleep 800ms
# preen pages through less; g is the top of the render.
Type "g"
Sleep 7s
Screenshot demo/flock.png
Sleep 1s
