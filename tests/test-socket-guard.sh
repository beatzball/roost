#!/usr/bin/env bash
# tests/test-socket-guard.sh — prove the amux-agent-state SHIM forwards
# roost-agent-state's socket guard faithfully.
#
# Before Task 12, amux-agent-state and roost-agent-state were two independent
# scripts, each with its own socket guard, coexisting as Claude Code hooks
# registered at the same time. This test originally proved they no-op on
# each other's socket.
#
# Task 12 replaced scripts/amux-agent-state with a relative symlink to
# scripts/roost-agent-state — there is only one live implementation now, and
# the old absolute hook path (still wired into ~/.claude/settings.json) just
# resolves through it. That makes the old "mutual no-op" property impossible
# to test (there is nothing left to be mutual with): invoking the symlink
# now runs the exact same code as invoking roost-agent-state directly, guard
# included. What is still worth proving is that the guard itself survives
# the indirection — that going through the OLD name doesn't change which
# socket it acts on.
#
# The guard keys off the socket PATH, so the sockets built here must
# genuinely end in "/amux" and "/roost" — a socket at a fixed name (as
# roost_test_server in lib.sh gives you) would not exercise the case
# statement at all. Build them the same way tests/test-agent-state.sh does:
# directly, with mktemp -d for a short parent dir and an explicit basename.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# --- socket whose path ends /amux ---
adir="$(mktemp -d /tmp/amx.XXXX)"; asock="$adir/amux"
# --- socket whose path ends /roost ---
rdir="$(mktemp -d /tmp/amx.XXXX)"; rsock="$rdir/roost"
trap 'tmux -S "$asock" kill-server 2>/dev/null; tmux -S "$rsock" kill-server 2>/dev/null; rm -rf "$adir" "$rdir"' EXIT

tmux -S "$asock" -f /dev/null new-session -d -x 200 -y 50
apane="$(tmux -S "$asock" display -p '#{pane_id}')"

tmux -S "$rsock" -f /dev/null new-session -d -x 200 -y 50
rpane="$(tmux -S "$rsock" display -p '#{pane_id}')"

astate() { tmux -S "$asock" show-options -pqv -t "$apane" @agent_state; }
rstate() { tmux -S "$rsock" show-options -pqv -t "$rpane" @agent_state; }

# --- negative cases: the guard still fires on a /amux socket, through BOTH
#     entry-point names ---

# roost-agent-state invoked directly on a socket ending /amux: exits 0, stamps nothing
env TMUX="$asock,0,0" TMUX_PANE="$apane" "$HERE/scripts/roost-agent-state" working
rc=$?
assert_eq "$rc" "0" "roost-agent-state exits 0 on a /amux socket"
assert_eq "$(astate)" "" "roost-agent-state stamps nothing on a /amux socket"

# amux-agent-state (the compat symlink) on a socket ending /amux: still exits
# 0, still stamps nothing — the shim does not resurrect the old amux-only
# guard, it forwards to roost-agent-state's guard unchanged.
env TMUX="$asock,0,0" TMUX_PANE="$apane" "$HERE/scripts/amux-agent-state" working
rc=$?
assert_eq "$rc" "0" "amux-agent-state (shim) exits 0 on a /amux socket"
assert_eq "$(astate)" "" "amux-agent-state (shim) stamps nothing on a /amux socket"

# --- positive cases: the guard fires on a /roost socket, through BOTH
#     entry-point names, proving the shim is a faithful forward and not a
#     dead link ---

env TMUX="$rsock,0,0" TMUX_PANE="$rpane" "$HERE/scripts/roost-agent-state" working
assert_eq "$(rstate)" "working" "roost-agent-state stamps @agent_state on its own /roost socket"

# A same-state call would exit early via roost-agent-state's own guard
# (`[ "$state" = "$prev" ] && exit 0`) before ever writing — that would pass
# even if the shim forwarded to nothing, so it proves nothing about the
# shim's wiring. Drive a real transition instead: "working" -> "blocked".
env TMUX="$rsock,0,0" TMUX_PANE="$rpane" "$HERE/scripts/amux-agent-state" blocked
assert_eq "$(rstate)" "blocked" "amux-agent-state (shim) stamps @agent_state on a /roost socket, same as roost-agent-state"
