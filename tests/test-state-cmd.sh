#!/usr/bin/env bash
# `amux state` is the public contract every state source calls: the Claude
# hooks, the opencode plugin, a future pi extension, or a user's own script.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# amux-agent-state only acts on a socket path ending in /amux, so build one
# directly rather than via amux_test_server.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d
pane="$(tmux -S "$s" display -p '#{pane_id}')"
pstate() { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }

# it stamps the calling pane, same as the hook does
env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/amux" state working
assert_eq "$(pstate)" "working" "amux state stamps the calling pane"

env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/amux" state error
assert_eq "$(pstate)" "error" "amux state accepts the error state"

# outside tmux it is a silent no-op that exits 0 -- an adapter must be safe to
# leave installed when its agent runs outside amux
out="$(env -u TMUX -u TMUX_PANE "$HERE/bin/amux" state working 2>&1)"; rc=$?
assert_eq "$rc" "0" "amux state exits 0 outside tmux"
assert_eq "$out" "" "amux state prints nothing outside tmux"

# no argument is idle, not a usage error: the sink's own default
env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/bin/amux" state
assert_eq "$(pstate)" "idle" "amux state with no argument means idle"

# it is advertised, or nobody will find it
usage="$("$HERE/bin/amux" not-a-command 2>&1 || true)"
assert_contains "$usage" "state" "amux state appears in the usage line"
