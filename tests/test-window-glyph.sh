#!/usr/bin/env bash
# A brand-new window that no Claude hook has stamped yet must show the CONFIGURED
# idle glyph (@amux-glyph-idle), not a hardcoded emoji. Regression test for:
# new tabs always showed 💤 even when a different glyph set was selected.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

# user picked a glyph set whose idle glyph is this distinctive marker
T set-option -g @amux-glyph-idle "IDLEMARK"

# a brand-new window, as `prefix c` / `amux new` would create — unstamped
T new-window
w2="$(T list-windows -F '#{window_id}' | tail -1)"
assert_eq "$(T show-options -wqv -t "$w2" @agent_glyph)" "" "new window has no stamped @agent_glyph"

# the window-status-format renders the configured idle glyph for the unstamped window
fmt="$(T show-options -gqv window-status-format)"
assert_contains "$(T display-message -p -t "$w2" "$fmt")" "IDLEMARK" \
  "unstamped window tab renders the configured idle glyph (not a hardcoded emoji)"

# the active-window format too (a new window may be current)
cfmt="$(T show-options -gqv window-status-current-format)"
assert_contains "$(T display-message -p -t "$w2" "$cfmt")" "IDLEMARK" \
  "unstamped active window tab renders the configured idle glyph"

# the status rollup's idle badge uses the configured idle glyph, not hardcoded 💤,
# when the only idle window is unstamped
out="$(AMUX_STATUS_SOCK="$sock" "$HERE/scripts/amux-status")"
assert_contains "$out" "IDLEMARK" "status rollup idle badge uses the configured idle glyph"
