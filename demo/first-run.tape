# First run, end to end: an ordinary shell, into roost, three agents, one of
# them writing a file and handing it to you in a pane on the right.
#
#   ./demo/record.sh first-run
#
# Always record through demo/record.sh: it starts from an empty environment and
# refuses to finish if any pane shows the home path or username.
#
# Runs against a live Claude Code, so the waits are on what appears on screen
# (Wait+Screen), never on a guessed number of seconds. The long stretch while
# the agent works is recorded Hidden, so the video cuts from "it started" to
# "it finished" instead of showing a minute of spinner.
Output demo/first-run.webm
Output demo/first-run.mp4

Set Shell "bash"
# A Nerd Font, because roost's status line is powerline separators and state
# glyphs from the private-use area, which render blank in anything else.
Set FontFamily "FiraCode Nerd Font Mono"
# 22, not 15: the video is shown about 1070px wide on the page, and at 15 the
# terminal text came out around 9px there -- present but unreadable. 22 at this
# width is ~133 columns, which still clears ROOST_VIEW_MIN_COLS below, so the
# notes still open in a pane beside the agent.
Set FontSize 22
Set Width 1800
Set Height 920
Set Padding 20
Set Framerate 30
Set TypingSpeed 40ms
Set Theme { "name": "roost", "background": "#211e38", "foreground": "#c8c3e0", "cursor": "#bd93f9", "selection": "#3a3558", "black": "#211e38", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#7c6ff0", "magenta": "#bd93f9", "cyan": "#8be9fd", "white": "#c8c3e0", "brightBlack": "#8a84b0", "brightRed": "#ff6e6e", "brightGreen": "#69ff94", "brightYellow": "#ffffa5", "brightBlue": "#9d8df5", "brightMagenta": "#d6acff", "brightCyan": "#a4ffff", "brightWhite": "#e0dcf5" }

# --- setup, off camera --------------------------------------------------
# The demo server, config and pane shell (demo/lib.sh). ROOST_VIEW_MIN_COLS is
# lowered so `roost view` always opens a pane beside the agent at this width,
# never a separate window the video would not show.
Hide
Type 'export ROOST_SOCKET=/tmp/roost-demo-sock/roost XDG_CONFIG_HOME=/tmp/roost-demo-xdg ZDOTDIR=/tmp/roost-demo-zdot ROOST_VIEW_MIN_COLS=120'
Enter
Type 'export PS1="\[\e[38;2;124;111;240m\]❯\[\e[0m\] "'
Enter
Type "cd /tmp/roost-demo-repo && clear"
Enter
Sleep 1s
Show

# --- an ordinary shell, then roost ---------------------------------------
Sleep 1500ms
Type "roost"
Sleep 500ms
Enter
Wait+Screen@20s /main/
# Name the first window, which would otherwise be titled after whatever runs
# in it and change as that does. Inside the pane, tmux talks to $TMUX: the
# demo server.
Hide
Type "tmux rename-window api && clear"
Enter
Sleep 800ms
Show
Sleep 1500ms

# --- two agents in the background -----------------------------------------
Type "roost spawn web claude"
Sleep 400ms
Enter
Sleep 1500ms
Type "roost spawn tests claude"
Sleep 400ms
Enter
Sleep 2500ms

# --- Claude in this pane ---------------------------------------------------
# Started off camera: the --settings path is long and dull, and `clear` first
# means the command line is not left on screen above the agent.
Hide
Type "clear; claude --settings /tmp/roost-demo-sock/claude-settings.json"
Enter
Wait+Screen@40s /auto mode|for shortcuts|bypass permissions/
Sleep 1s
Show

Sleep 1s
Type "Write NOTES.md: a five-step checklist for adding a /health route to src/server.js. Then open it for me with roost view and preen."
Sleep 600ms
Enter
# Let the start of the work be seen, then cut to the end.
Sleep 5s
Hide
# "for 26s · done" or "for 1m 5s · done": allow minutes as well as seconds.
Wait+Screen@300s /for [0-9hms ]+· done/
Sleep 2s
# Claude offers a greyed follow-up in its input box when a turn ends; on a
# still it reads as a half-typed request nobody made.
Escape
Sleep 500ms
Show

# --- the hand-off: go to the notes the way the agent says to ---------------
Sleep 3s
Ctrl+S
Type "l"
Sleep 800ms
# preen pages through less; g is the top of the render.
Type "g"
Sleep 5s
Screenshot demo/first-run.png
Sleep 1s
