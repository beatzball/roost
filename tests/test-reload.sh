#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

# prefix r: source-file -F must expand #{@amux-home}, not pass it literally
out="$(T source-file -F "#{@amux-home}/tmux/amux.conf" 2>&1)"
assert_eq "$out" "" "prefix r reload sources cleanly (no literal-path error)"

# prefix r migrates a live server off the old window-scoped state model
assert_contains "$(cat "$HERE/tmux/amux.conf")" "amux-migrate-state" \
  "prefix r reload migrates window-scoped leftovers"
# glyph changes need no re-stamping: nothing stamps glyphs any more
case "$(cat "$HERE/tmux/amux.conf")" in
  *amux-restamp*) assert_eq present absent "the retired re-stamper is gone from the conf" ;;
  *)              assert_eq ok ok          "the retired re-stamper is gone from the conf" ;;
esac

# --- Fix: SOURCING the conf must migrate a legacy server by itself ---------
# On a RUNNING server, `prefix + r` presses execute the OLD, already-parsed
# `bind r` — sourcing installs the new binding, it does not retroactively add
# `run-shell amux-migrate-state` to the command list currently executing.
# Grepping the conf text (above) passes whether or not migration ever runs;
# this proves the real behaviour by driving it end to end.
w="$(T new-window -d -PF '#{window_id}')"
p="$(T list-panes -t "$w" -F '#{pane_id}')"
T set-option -w -t "$w" @agent_state working   # simulate a pre-pane-state leftover

# precondition: option lookup falls back pane -> window, so the unstamped
# pane inherits the window-scoped leftover
assert_eq "$(T display-message -p -t "$p" '#{@agent_state}')" "working" \
  "precondition: unstamped pane inherits a window-scoped leftover"

T source-file -F "#{@amux-home}/tmux/amux.conf"

# The migration runs via a backgrounded `run-shell -b` (needed so an
# unguarded run-shell can't block a client), so it may still be in flight the
# instant source-file returns — poll briefly instead of assuming it's done.
n=25
while [ "$n" -gt 0 ]; do
  [ -z "$(T display-message -p -t "$p" '#{@agent_state}')" ] && break
  sleep 0.2; n=$((n - 1))
done
assert_eq "$(T display-message -p -t "$p" '#{@agent_state}')" "" \
  "sourcing the conf alone migrates a legacy server (not just the bind r keypress)"
