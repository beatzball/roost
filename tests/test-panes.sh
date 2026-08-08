#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AMUX="$HERE/bin/amux"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_SOCKET="$sock"

wait_for() { local t="$1" p="$2" n=20; while [ "$n" -gt 0 ]; do T capture-pane -p -t "$t" 2>/dev/null | grep -q "$p" && return 0; sleep 0.2; n=$((n-1)); done; return 1; }

w="$(T display-message -p '#{window_id}')"
agent="$(T display-message -p '#{pane_id}')"

# split adds a background pane to the current window, prints %N, no focus steal
before="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
active_before="$(T display-message -p -t "$w" '#{pane_id}')"
p="$(TMUX_PANE="$agent" "$AMUX" split)"
after="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "split adds a pane to the current window"
case "$p" in %*) assert_eq ok ok "split prints a stable pane id (%N)" ;; *) assert_eq "$p" "%..." "split prints a stable pane id (%N)" ;; esac
[ -n "$(T display-message -p -t "$p" '#{pane_id}')" ] \
  && assert_eq ok ok "split's target resolves to a live pane" || assert_eq "" live "split's target resolves to a live pane"
assert_eq "$(T display-message -p -t "$w" '#{pane_id}')" "$active_before" "split does not steal focus (active pane unchanged)"

# send/read work against the split pane's %N
"$AMUX" send "$p" "printf 'SPLIT-%s\n' OK"
wait_for "$p" 'SPLIT-OK' \
  && assert_eq ok ok "send/read reach a split pane by %N" || assert_eq no-exec executed "send/read reach a split pane by %N"

# CMD form runs and still prints a pane id
p2="$(TMUX_PANE="$agent" "$AMUX" split true)"
case "$p2" in %*) assert_eq ok ok "split CMD prints a pane id" ;; *) assert_eq "$p2" "%..." "split CMD prints a pane id" ;; esac

# guard: outside amux (no TMUX_PANE, no -t) exits 1
out="$(env -u TMUX_PANE "$AMUX" split 2>&1)"; rc=$?
assert_eq "$rc" "1" "split outside amux exits 1"
assert_contains "$out" "not inside an amux session" "split explains it's outside amux"

# layout: full-left agent + stacked-right via -h then -v -t <right>
w2="$(T new-window -P -F '#{window_id}')"
a2="$(T display-message -p -t "$w2" '#{pane_id}')"
r1="$(TMUX_PANE="$a2" "$AMUX" split -h)"
r2="$(TMUX_PANE="$a2" "$AMUX" split -v -t "$r1")"
assert_eq "$(T display-message -p -t "$a2" '#{pane_left}')" "0" "layout: agent pane on the left edge"
[ "$(T display-message -p -t "$r1" '#{pane_left}')" -gt 0 ] \
  && assert_eq ok ok "layout: right column is right of the agent" || assert_eq "" right "layout: right column is right of the agent"
[ "$(T display-message -p -t "$r2" '#{pane_top}')" -gt "$(T display-message -p -t "$r1" '#{pane_top}')" ] \
  && assert_eq ok ok "layout: right panes stack (r2 below r1)" || assert_eq "" stacked "layout: right panes stack (r2 below r1)"
