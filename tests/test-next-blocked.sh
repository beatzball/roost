#!/usr/bin/env bash
# prefix + b jumps to the next agent that needs you. With panes as the unit, it
# must select the right WINDOW *and* the right PANE inside it.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NEXT="$HERE/scripts/roost-next-blocked"
roost_test_server; trap roost_test_teardown EXIT
export ROOST_NEXT_SOCK="$ROOST_TEST_SOCK"
hold='sh -c "while :; do sleep 5; done"'

[ -x "$NEXT" ] && assert_eq ok ok "roost-next-blocked is executable" \
  || assert_eq "" exec "roost-next-blocked is executable"

# nothing blocked -> a silent no-op that changes no selection
w0="$(T display-message -p '#{window_id}')"
before="$(T display-message -p '#{window_id}')"
out="$("$NEXT" 2>&1)"; rc=$?
assert_eq "$rc" "0" "no blocked pane exits 0"
assert_eq "$out" "" "no blocked pane is silent"
assert_eq "$(T display-message -p '#{window_id}')" "$before" "no blocked pane changes nothing"

# a blocked pane in a NON-active window, and not the window's active pane
w1p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w1="$(T display-message -p -t "$w1p" '#{window_id}')"
w1b="$(T split-window -d -P -F '#{pane_id}' -t "$w1p" "$hold")"
T set-option -p -t "$w1b" @agent_state blocked

"$NEXT"
assert_eq "$(T display-message -p '#{window_id}')" "$w1" "jumps to the blocked pane's window"
assert_eq "$(T display-message -p '#{pane_id}')" "$w1b" "selects the blocked PANE, not the window's active one"

# only blocked counts — a working pane is not a jump target
T set-option -p -t "$w1b" @agent_state working
T select-window -t "$w0"
"$NEXT"
assert_eq "$(T display-message -p '#{window_id}')" "$w0" "a working pane is not a jump target"

# an error pane is also a jump target
T set-option -p -t "$w1b" @agent_state error
T select-window -t "$w0"
"$NEXT"
assert_eq "$(T display-message -p '#{window_id}')" "$w1" "jumps to the errored pane's window"
assert_eq "$(T display-message -p '#{pane_id}')" "$w1b" "selects the errored PANE"

# error is preferred over blocked when both exist
w2p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w2="$(T display-message -p -t "$w2p" '#{window_id}')"
T set-option -p -t "$w2p" @agent_state blocked
T select-window -t "$w0"
"$NEXT"
assert_eq "$(T display-message -p '#{window_id}')" "$w1" "error is preferred over blocked when both exist"
assert_eq "$(T display-message -p '#{pane_id}')" "$w1b" "error is preferred over blocked (correct pane)"
