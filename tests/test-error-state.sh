#!/usr/bin/env bash
# The error state renders everywhere the other four do, and sorts first.
# error means "this agent will not make progress without you" — for opencode
# the usual cause is a provider it cannot reach, retrying forever.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"
T set-option -g @amux-glyph-error   "E"
T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-done    "D"
T set-option -g @amux-glyph-idle    "I"

hold='sh -c "while :; do sleep 5; done"'
badge()  { T list-windows -a -F "#{window_id}|#{E:@amux-tab-badge}" | grep "^$1|" | cut -d'|' -f2; }
busy()   { T list-windows -a -F "#{window_id}|#{E:@amux-tab-busy}"  | grep "^$1|" | cut -d'|' -f2; }
border() { T list-panes   -a -F "#{pane_id}|#{E:@amux-pane-border}" | grep "^$1|" | cut -d'|' -f2; }
# A failed split-window (out of space) prints an EMPTY pane id, not an error,
# and `set-option -p -t ""` silently resolves to the ACTIVE pane instead of
# erroring -- with -d keeping $p1 active throughout this file, a lost split
# would re-stamp $p1 instead of a new pane, and a dedupe assertion downstream
# could pass for the wrong reason. Fail loudly here instead of drifting into
# that trap.
require_pane() { [ -n "$1" ] || { echo "  FAIL: split for $2 produced no pane id"; exit 1; }; }

# --- tab badge ---
w1="$(T display-message -p '#{window_id}')"
p1="$(T display-message -p '#{pane_id}')"
T set-option -p -t "$p1" @agent_state error
assert_eq "$(badge "$w1")" "E" "an error pane badges its tab with the error glyph"
assert_eq "$(busy "$w1")"  "1" "a window with an error agent is busy"

# error sorts FIRST, ahead of blocked: a crashed agent outranks a waiting one
p2="$(T split-window -h -d -P -F '#{pane_id}' -t "$p1" "$hold")"
require_pane "$p2" p2
T set-option -p -t "$p2" @agent_state blocked
assert_eq "$(badge "$w1")" "EB" "error sorts ahead of blocked"

p3="$(T split-window -h -d -P -F '#{pane_id}' -t "$p1" "$hold")"
require_pane "$p3" p3
T set-option -p -t "$p3" @agent_state working
p4="$(T split-window -h -d -P -F '#{pane_id}' -t "$p1" "$hold")"
require_pane "$p4" p4
T set-option -p -t "$p4" @agent_state done
assert_eq "$(badge "$w1")" "EBWD" "all four urgent states render in urgency order"

# duplicates still dedupe now that a fifth arm exists
p5="$(T split-window -h -d -P -F '#{pane_id}' -t "$p1" "$hold")"
require_pane "$p5" p5
T set-option -p -t "$p5" @agent_state error
assert_eq "$(badge "$w1")" "EBWD" "two error panes dedupe to one glyph"

# --- pane border ---
assert_contains "$(border "$p1")" "E"     "an error pane's border shows the error glyph"
# Companion guard, not discriminating coverage: the border already prints the
# raw @agent_state string regardless of the glyph chain, so this passed even
# before the glyph arm existed (see the RED run). It stays anyway, to catch a
# future change that drops the state word from the border -- the assertion
# above is the one that actually exercises this task's wiring.
assert_contains "$(border "$p1")" "error" "an error pane's border names its state"

# --- status rollup ---
out="$(AMUX_STATUS_SOCK="$sock" "$HERE/scripts/amux-status")"
assert_contains "$out" "E 2" "the rollup counts error panes"
case "$out" in
  E*) assert_eq ok ok "the rollup lists error first" ;;
  *)  assert_eq "$out" "E first" "the rollup lists error first" ;;
esac

# --- switcher ---
rows="$(AMUX_SWITCH_SOCK="$sock" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
assert_contains "$rows" "E error" "the switcher renders the error glyph beside the state"
