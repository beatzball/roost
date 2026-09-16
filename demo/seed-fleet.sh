#!/usr/bin/env bash
# Build a throwaway roost server with a believable fleet on it, for the demo
# recordings.
#
#   ./demo/seed-fleet.sh
#
# It runs on its OWN socket, never the roost server you are working
# in. That is not only politeness: roost's status counts and its agent switcher
# roll up across every session on a server, so a recording made against a real
# server would put that machine's real session names and real agent counts into
# a public image.
#
# The panes stand in a seeded throwaway repo, so no home path and no project
# name of yours reaches a frame either.
set -euo pipefail

SOCK=/tmp/roost-demo-sock/roost
SESS=demo
REPO=/tmp/roost-demo-repo
WINDOWS="api web worker docs tests"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOST="$HERE/../bin/roost"

# --- a small neutral repo for the panes to sit in -----------------------
rm -rf "$REPO"
mkdir -p "$REPO/src"
cd "$REPO"
g() { git -c user.name=demo -c user.email=demo@example.com "$@"; }
git init -q -b main .
cat > src/server.js <<'A'
const http = require("http");

http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));
}).listen(3000);
A
cat > README.md <<'A'
# demo

A throwaway repo, so the recordings have somewhere neutral to stand.
A
g add -A
g commit -qm "initial commit"

# --- the fleet ----------------------------------------------------------
# TMUX_PANE would make `roost spawn` look for the caller's pane on the demo
# socket, where it does not exist. Unset it: this script is a caller from
# outside, even when you run it from inside roost.
unset TMUX_PANE || true
export ROOST_SOCKET="$SOCK"

# A socket PATH, not a -L name, and it has to end in "/roost".
#
# scripts/lib/roost-socket.sh recognises the server a process is running inside
# only when the socket path ends that way -- deliberately, so a global Claude
# hook cannot stamp state onto the user's everyday tmux. scripts/roost-agent-
# state, which is what actually writes a badge, takes its socket from there and
# does NOT consult $ROOST_SOCKET. On a socket called anything else every
# `roost state` in this script exits 0 and writes nothing, which is exactly
# what a working run looks like.
mkdir -p "$(dirname "$SOCK")"

# Only ever the demo socket, which $ROOST_SOCKET above pins. Never run this
# without it set.
"$ROOST" kill >/dev/null 2>&1 || true

t() { tmux -S "$SOCK" "$@"; }

# One spawn brings the server up, so there is something to set the environment
# on before the panes that need it exist.
"$ROOST" spawn api >/dev/null

# Every pane needs this, and it is not optional.
#
# scripts/lib/roost-socket.sh only recognises a server whose socket path ENDS
# IN /roost -- deliberately, so a global Claude hook cannot stamp state onto
# the user's everyday tmux. A socket called anything else, this one included,
# is refused, and the caller is expected to set $ROOST_SOCKET instead. Without
# it, a `roost` run inside a demo pane falls through to the REAL roost server.
#
# Set on the session as well as globally: tmux copies the global environment
# into a session when the SESSION is created, and this one already exists by
# the time the first spawn returns.
t set-environment -g ROOST_SOCKET "$SOCK"
t set-environment -t "=main" ROOST_SOCKET "$SOCK"

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
# environment. Both are set above, but a pane that was already open when they
# were set does not have them, and a state written to the wrong server is the
# one failure here that looks exactly like success.
state() {
  t send-keys -t "=$SESS:$1" "ROOST_SOCKET=$SOCK roost state $2" Enter
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
# switcher. A hero with an empty pane behind the popup was two thirds dead
# space.
#
# Its hooks need no help finding this server. scripts/roost-agent-state takes
# the socket from $TMUX and accepts any path ending in "/roost" -- which is
# the whole reason $SOCK is spelled the way it is.
if command -v claude >/dev/null 2>&1; then
  # --settings blanks the user's own status line for this run. Theirs reports
  # plan tier and weekly usage across the bottom of every frame, and that is
  # their account, not roost's product.
  # The command is TYPED into the pane, so its text is on screen above the
  # agent until enough conversation pushes it out of frame. $HERE is an
  # absolute path under the author's home directory; typed as-is it would put
  # a username into a public image. Copy the file under /tmp and type that.
  settings="$(dirname "$SOCK")/claude-settings.json"
  cp "$HERE/claude-demo-settings.json" "$settings"
  t send-keys -t "=$SESS:api" "clear" Enter
  t send-keys -t "=$SESS:api" "claude --settings $settings" Enter
  sleep 10

  # Claude asks whether it trusts a folder it has not seen before, and the
  # seeded repo is new every run. Answering is safe here and only here: this
  # directory was created by this script, three lines up.
  if "$ROOST" screen "$SESS:api" 20 2>/dev/null | grep -q "trust this folder"; then
    t send-keys -t "=$SESS:api" Down
    t send-keys -t "=$SESS:api" Enter
    sleep 8
  fi

  # Three turns, not one. Two reasons, both learned from the shot:
  #  - One answer left the bottom half of the frame empty.
  #  - Claude's startup banner names the account's plan tier, and it only
  #    scrolls out of frame once there is enough conversation above it.
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
