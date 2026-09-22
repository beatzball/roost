#!/bin/sh
# turn-agent.sh HOOK DELAY WORK — a stand-in agent with a SLOW prompt-submit
# hook, for issue #92.
#
# It runs roost's real scripts/roost-agent-state, so the badge and the reply
# record it produces are the ones a real Claude turn produces. What it models
# is the one thing the suite could not otherwise reach deterministically: the
# gap between a submit landing and the harness stamping `working`.
#
#   READY on stdout, then for each line read from the tty:
#     sleep DELAY, then `roost-agent-state working`      <- the prompt-submit hook
#     sleep WORK,  then `roost-agent-state done --stop-hook` with a reply
#
# DELAY is the race. MEASURED on this machine (tmux 3.6, macOS 26.3, bash 3.2):
# `roost send` returns about 340 ms AFTER it presses Enter, so a harness that
# stamps `working` inside that cushion never loses the race at all — 0 stale
# replies in 10 runs at DELAY 0, 0.1, 0.2 and 0.3. It starts losing at 0.4
# (4/10) and is losing nearly always by 3.0 (9/10). So a test that wants the
# race every time must sit well above the cushion; 2 s is used below.
#
# The turn runs in the FOREGROUND, not a background subshell. A backgrounded
# turn lets two prompts overlap, the badge flaps between them, and the test
# then measures its own fixture rather than roost — which is exactly what the
# first version of this file did.
#
# Cooked mode, so the pane echoes what `roost send` pastes and `send`'s own
# submit verification sees the screen change. Nothing here needs raw mode:
# tests/fixtures/cold-start-tui.py is the fixture for that question.
# PIN (optional 4th argument) is how a test isolates ONE of `roost send`'s
# turn-started signals from the others. `send` watches four things, and a fast
# turn with recording off leaves only two of them able to answer: @agent_since
# moving, and @roost-reply changing. Added together, either alone passed the
# whole test file (measured by review, flock round 2, by short-circuiting each
# to `if false` — three runs each, all green). So a test has to be able to hold
# one of them still:
#
#   PIN=since   the stamp is written back to its pre-turn value after each hook
#               call, so only the reply can answer
#   PIN=reply   the reply is written back, so only the stamp can answer
#
# It NARROWS the window rather than closing it: between a hook's own write and
# the restore below — about 10 ms — the pinned option does hold its new value.
# `send` presses Enter roughly 340 ms before its first poll, and the whole turn
# plus both restores takes about 120 ms, so every poll `send` makes lands well
# after the pin is back. The test asserts the pinned option is unchanged
# afterwards as well, and the mutation runs in the report are what prove each
# signal is load-bearing.
HOOK="$1"; DELAY="$2"; WORK="$3"; PIN="${4:-}"

# The pane's own server, from the tmux the pane is running under.
SOCK="${TMUX%%,*}"
PINVAL=""
pin_save() {
  case "$PIN" in
    since) PINVAL="$(tmux -S "$SOCK" show-options -pqv -t "$TMUX_PANE" @agent_since 2>/dev/null)" ;;
    reply) PINVAL="$(tmux -S "$SOCK" show-options -pqv -t "$TMUX_PANE" @roost-reply 2>/dev/null)" ;;
  esac
}
pin_restore() {
  [ -n "$PINVAL" ] || return 0
  case "$PIN" in
    since) tmux -S "$SOCK" set-option -p -t "$TMUX_PANE" @agent_since "$PINVAL" 2>/dev/null ;;
    reply) tmux -S "$SOCK" set-option -p -t "$TMUX_PANE" @roost-reply "$PINVAL" 2>/dev/null ;;
  esac
}

printf 'READY\n'
while IFS= read -r line; do
  # An empty line is an extra Enter, not a prompt. `send` can fire more than
  # one, and a turn per stray Enter would number turns the test cannot predict.
  [ -n "$line" ] || continue
  pin_save
  [ "$DELAY" = 0 ] || sleep "$DELAY"
  "$HOOK" working </dev/null
  pin_restore
  [ "$WORK" = 0 ] || sleep "$WORK"
  printf '{"last_assistant_message":"REPLY-TO[%s]"}' "$line" | "$HOOK" done --stop-hook
  pin_restore
done
