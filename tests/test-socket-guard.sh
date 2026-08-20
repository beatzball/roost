#!/usr/bin/env bash
# tests/test-socket-guard.sh — prove the mutual no-op between the two
# agent-state halves.
#
# scripts/amux-agent-state and scripts/roost-agent-state get registered as
# Claude Code hooks AT THE SAME TIME, in the same settings.json, and both
# fire on every tool call of every agent. The only thing stopping them
# colliding is each script's socket guard: it inspects the tmux socket path
# it was invoked under (`${TMUX%%,*}`) and exits 0, untouched, unless that
# path ends in its own name. That mutual no-op is the entire basis for the
# coexistence design — nothing else prevents amux-agent-state from stamping
# state meant for a roost pane, or vice versa.
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

# --- cross cases: each half must no-op on the OTHER half's socket ---

# roost-agent-state invoked on a socket ending /amux: exits 0, stamps nothing
env TMUX="$asock,0,0" TMUX_PANE="$apane" "$HERE/scripts/roost-agent-state" working
rc=$?
assert_eq "$rc" "0" "roost-agent-state exits 0 on a /amux socket"
assert_eq "$(astate)" "" "roost-agent-state stamps nothing on a /amux socket"

# amux-agent-state invoked on a socket ending /roost: exits 0, stamps nothing
env TMUX="$rsock,0,0" TMUX_PANE="$rpane" "$HERE/scripts/amux-agent-state" working
rc=$?
assert_eq "$rc" "0" "amux-agent-state exits 0 on a /roost socket"
assert_eq "$(rstate)" "" "amux-agent-state stamps nothing on a /roost socket"

# --- positive controls: each half DOES stamp on its OWN socket ---
# Without these, a broken guard that no-ops on EVERY socket (including its
# own) would pass the two cross-case assertions above for the wrong reason.

env TMUX="$asock,0,0" TMUX_PANE="$apane" "$HERE/scripts/amux-agent-state" working
assert_eq "$(astate)" "working" "amux-agent-state stamps @agent_state on its own /amux socket"

env TMUX="$rsock,0,0" TMUX_PANE="$rpane" "$HERE/scripts/roost-agent-state" working
assert_eq "$(rstate)" "working" "roost-agent-state stamps @agent_state on its own /roost socket"
