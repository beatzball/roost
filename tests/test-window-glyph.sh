#!/usr/bin/env bash
# A brand-new window that no Claude hook has stamped yet must show the CONFIGURED
# idle glyph (@roost-glyph-idle), not a hardcoded emoji. Regression test for:
# new tabs always showed 💤 even when a different glyph set was selected.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
T source-file "$HERE/tmux/roost.conf"
T set-option -g @roost-home "$HERE"

# user picked a glyph set whose idle glyph is this distinctive marker
T set-option -g @roost-glyph-idle "IDLEMARK"

# a brand-new window, as `prefix c` / `roost new` would create — no agent panes
T new-window
w2="$(T list-windows -F '#{window_id}' | tail -1)"
assert_eq "$(T show-options -pqv -t "$w2" @agent_state)" "" "new window has no stamped state"

# both tab formats render the configured idle glyph for the agent-less window
fmt="$(T show-options -gqv window-status-format)"
assert_contains "$(T display-message -p -t "$w2" "$fmt")" "IDLEMARK" \
  "agent-less window tab renders the configured idle glyph (not a hardcoded emoji)"
cfmt="$(T show-options -gqv window-status-current-format)"
assert_contains "$(T display-message -p -t "$w2" "$cfmt")" "IDLEMARK" \
  "agent-less active window tab renders the configured idle glyph"

# the rollup counts agents, not tabs: with no agent panes it stays empty rather
# than reporting every window as idle
out="$(ROOST_STATUS_SOCK="$sock" "$HERE/scripts/roost-status")"
assert_eq "$out" "" "rollup is empty when no pane is an agent"

# once a pane is an agent, its badge uses the configured idle glyph
p="$(T display-message -p '#{pane_id}')"
T set-option -p -t "$p" @agent_state idle
out="$(ROOST_STATUS_SOCK="$sock" "$HERE/scripts/roost-status")"
assert_contains "$out" "IDLEMARK" "status rollup idle badge uses the configured idle glyph"
