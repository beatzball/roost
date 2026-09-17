#!/usr/bin/env bash
# Build a throwaway roost server with a believable fleet on it, for the hero
# recording.
#
#   ./demo/seed-fleet.sh && vhs demo/roost-hero.tape
#
# The server, its config and every path on screen live under /tmp; see
# demo/lib.sh for why each of those has to be redirected.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESS=demo
WINDOWS="api web worker docs tests"

demo_reset
t() { demo_tmux "$@"; }

# Panes are created from this shell, so they inherit its environment -- the
# demo socket and config included. Run from the seeded repo so every window
# opens there.
cd "$DEMO_REPO"

# One spawn brings the server up, so there is something to set the environment
# on before the rest of the panes exist.
"$ROOST" spawn api >/dev/null

# Set on the session as well as globally: tmux copies the global environment
# into a session when the SESSION is created, and this one already exists by
# the time the first spawn returns.
t set-environment -g ROOST_SOCKET "$DEMO_SOCK"
t set-environment -t "=main" ROOST_SOCKET "$DEMO_SOCK"
t set-environment -g XDG_CONFIG_HOME "$DEMO_XDG"
t set-environment -t "=main" XDG_CONFIG_HOME "$DEMO_XDG"

for w in $WINDOWS; do
  [ "$w" = api ] || "$ROOST" spawn "$w" >/dev/null
done

# tmux opens a new session with a bare shell window, which is not one of ours.
# Killed by exclusion, not by index: base-index is 1 here, so a hardcoded 0
# matched nothing and left the window in frame. By name and BEFORE the rename,
# because the session is still called "main" at this point.
t list-windows -t "=main" -F '#{window_index} #{window_name}' | while read -r idx name; do
  case " $WINDOWS " in
    *" $name "*) ;;
    *) t kill-window -t "=main:$idx" 2>/dev/null || true ;;
  esac
done

t rename-session -t "=main" "$SESS"

# Each window reports its own state. `roost state` is the path every harness
# has whether or not an adapter ships for it, so these badges arrive through
# the same code as a hooked agent's -- reported, not painted on.
#
# $ROOST_SOCKET is spelled out on the command rather than trusted to the pane's
# environment: a state written to the wrong server is the one failure here that
# looks exactly like success.
state() {
  t send-keys -t "=$SESS:$1" "ROOST_SOCKET=$DEMO_SOCK roost state $2" Enter
  t send-keys -t "=$SESS:$1" "clear" Enter
}

state web    working
state worker blocked
state docs   idle
state tests  error

# --- one real agent, in the window the recording looks at ----------------
# The other four report their state by hand, which is the documented path for
# a harness with no adapter. This one is a live Claude Code: it badges itself
# through roost's hooks, and its answer is what fills the pane behind the
# switcher. Its hooks need no help finding this server: roost-agent-state takes
# the socket from $TMUX, which is why DEMO_SOCK ends in /roost.
if command -v claude >/dev/null 2>&1; then
  # The command is TYPED into the pane, so its text sits on screen above the
  # agent until conversation pushes it out of frame. DEMO_CLAUDE_SETTINGS is
  # under /tmp for exactly that reason. --settings blanks the status line,
  # which reports plan usage across the bottom of every frame.
  t send-keys -t "=$SESS:api" "clear" Enter
  t send-keys -t "=$SESS:api" "claude --settings $DEMO_CLAUDE_SETTINGS" Enter
  sleep 10

  # Claude asks whether it trusts a folder it has not seen before, and the
  # seeded repo is new every run. Safe to answer: demo_reset created it.
  if "$ROOST" screen "$SESS:api" 20 2>/dev/null | grep -q "trust this folder"; then
    t send-keys -t "=$SESS:api" Down
    t send-keys -t "=$SESS:api" Enter
    sleep 8
  fi

  # Three turns, not one: one answer left the bottom half of the frame empty,
  # and Claude's startup banner only scrolls out of frame once there is enough
  # conversation above it.
  ask() {
    "$ROOST" send "$SESS:api" "$1" || true
    "$ROOST" wait-done "$SESS:api" 180 || true
  }
  ask "In three short bullets, say what roost does for someone running several coding agents at once. No preamble, no tool calls, no code."
  ask "Now just the shell one-liner that prompts three agents named api, web and worker and then waits for all three. Code block only, no explanation."
  # Asked about the seeded repo, not about roost. An earlier cut asked which
  # key jumps to the agent that needs you, and the agent answered "Ctrl-s then
  # a" -- wrong, it is Ctrl-s b -- and the answer shipped in the hero. The
  # agent can read src/server.js; it cannot read roost's key bindings.
  ask "In one line, what does src/server.js do? No code block."
else
  echo "seed-fleet: claude not found — leaving 'api' as a shell." >&2
  state api working
fi

t select-window -t "=$SESS:api"

sleep 2
"$ROOST" status
