# Landing-page hero for roosting.dev — build with:
#   ./demo/seed-fleet.sh && vhs demo/roost-hero.tape
#
# The tape only LOOKS at the fleet. Everything it shows -- the five badges, the
# agent's answer -- was put there by seed-fleet.sh, so a re-record does not
# depend on an agent replying inside a Sleep.
#
# Screenshot needs a relative path and a Sleep after it, or vhs writes nothing.
# Output only understands gif/webm/mp4, so the PNGs come from the Screenshot
# lines and the gif below is what Output actually writes.
Output demo/roost-hero.gif

Set Shell "bash"
# A Nerd Font is not decoration here. roost's status line is built from
# powerline separators and state glyphs that live in the private-use area; in
# any other font they are blank, and the fleet -- the whole point of the shot
# -- renders as empty space.
Set FontFamily "FiraCode Nerd Font Mono"
Set FontSize 15
Set Width 1800
Set Height 620
Set Padding 20
Set Framerate 20
Set TypingSpeed 55ms
Set Theme { "name": "roost", "background": "#211e38", "foreground": "#c8c3e0", "cursor": "#bd93f9", "selection": "#3a3558", "black": "#211e38", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#7c6ff0", "magenta": "#bd93f9", "cyan": "#8be9fd", "white": "#c8c3e0", "brightBlack": "#8a84b0", "brightRed": "#ff6e6e", "brightGreen": "#69ff94", "brightYellow": "#ffffa5", "brightBlue": "#9d8df5", "brightMagenta": "#d6acff", "brightCyan": "#a4ffff", "brightWhite": "#e0dcf5" }

# Setup is hidden so no real path or user name ever reaches a frame.
#
# Nothing here clears a pane. The focused window holds a live agent and its
# answer, which is the content the shot is for; `clear` would throw it away.
Hide
Type 'export ROOST_SOCKET=/tmp/roost-demo-sock/roost'
Enter
Type "cd /tmp/roost-demo-repo && clear"
Enter
Sleep 1s
Type "roost session demo"
Enter
Sleep 4s
# Claude offers a greyed follow-up in its input box once a turn ends. It is
# real, but on a still it reads as a half-typed question nobody asked. Escape
# dismisses it; with an empty prompt it does nothing else.
Escape
Sleep 500ms
Show

# --- the fleet, and one agent's answer ---
Sleep 2s
Screenshot demo/roost-agent.png
Sleep 1s

# --- the switcher: every agent, its state, and how long it has been there ---
Ctrl+S
Type "a"
Sleep 3s
Screenshot demo/roost-hero.png
Sleep 2s
