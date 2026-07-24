#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RESTAMP="$HERE/scripts/amux-restamp"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_RESTAMP_SOCK="$sock"

T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-done    "D"
T set-option -g @amux-glyph-idle    "I"

w1="$(T display-message -p '#{window_id}')"
T set-option -w -t "$w1" @agent_state working
T set-option -w -t "$w1" @agent_glyph "STALE"

T new-window
w2="$(T list-windows -F '#{window_id}' | tail -1)"
T set-option -w -t "$w2" @agent_state ""
T set-option -w -t "$w2" @agent_glyph "STALE2"

"$RESTAMP"

assert_eq "$(T show-options -wqv -t "$w1" @agent_glyph)" "W" "restamp maps working -> W"
assert_eq "$(T show-options -wqv -t "$w2" @agent_glyph)" "I" "restamp falls back to idle glyph for empty state"
