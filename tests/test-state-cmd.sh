#!/usr/bin/env bash
# `roost state` is the public contract every state source calls: the Claude
# hooks, the opencode plugin, a future pi extension, or a user's own script.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# roost-agent-state only acts on a socket path ending in /roost, so build one
# directly rather than via roost_test_server.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d
pane="$(tmux -S "$s" display -p '#{pane_id}')"
pstate() { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }

# it stamps the calling pane, same as the hook does
env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/roost" state working
assert_eq "$(pstate)" "working" "roost state stamps the calling pane"

env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/roost" state error
assert_eq "$(pstate)" "error" "roost state accepts the error state"

# outside tmux it is a silent no-op that exits 0 -- an adapter must be safe to
# leave installed when its agent runs outside roost
out="$(env -u TMUX -u TMUX_PANE "$HERE/bin/roost" state working 2>&1)"; rc=$?
assert_eq "$rc" "0" "roost state exits 0 outside tmux"
assert_eq "$out" "" "roost state prints nothing outside tmux"

# no argument is idle, not a usage error: the sink's own default
env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/roost" state
assert_eq "$(pstate)" "idle" "roost state with no argument means idle"

# it is advertised, or nobody will find it
usage="$("$HERE/bin/roost" not-a-command 2>&1 || true)"
assert_contains "$usage" "state" "roost state appears in the usage line"
