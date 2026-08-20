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
#
# On a SECOND server, because the migration is backgrounded (`run-shell -b`)
# and this file has already sourced the conf twice above with @amux-home set.
# Each of those scheduled a migration, and a straggler landing between the
# leftover being planted and the precondition being read would unset it and
# fail an assertion that has nothing to do with what is under test. That is a
# real race, not a hypothetical: it failed in CI on a loaded runner while
# passing on a second run of the same commit.
#
# The conf below is sourced with @amux-home UNSET, so the conf's own
# `if-shell -F '#{@amux-home}'` guard is false and NO migration is scheduled.
# Nothing can run until this test arms it, which makes the ordering ours.
mdir="$(mktemp -d /tmp/amx.XXXX)"; msock="$mdir/s"
trap 'tmux -S "$msock" kill-server 2>/dev/null; rm -rf "$mdir"; amux_test_teardown' EXIT
tmux -S "$msock" -f /dev/null new-session -d -x 200 -y 50
M() { tmux -S "$msock" "$@"; }

M source-file "$HERE/tmux/amux.conf"
w="$(M new-window -d -PF '#{window_id}')"
p="$(M list-panes -t "$w" -F '#{pane_id}')"
M set-option -w -t "$w" @agent_state working   # simulate a pre-pane-state leftover

# precondition: option lookup falls back pane -> window, so the unstamped
# pane inherits the window-scoped leftover
assert_eq "$(M display-message -p -t "$p" '#{@agent_state}')" "working" \
  "precondition: unstamped pane inherits a window-scoped leftover"

# arm the migration and source: this is the behaviour under test
M set-option -g @amux-home "$HERE"
M source-file -F "#{@amux-home}/tmux/amux.conf"

# The migration runs via a backgrounded `run-shell -b` (needed so an
# unguarded run-shell can't block a client), so it may still be in flight the
# instant source-file returns — poll briefly instead of assuming it's done.
n=25
while [ "$n" -gt 0 ]; do
  [ -z "$(M display-message -p -t "$p" '#{@agent_state}')" ] && break
  sleep 0.2; n=$((n - 1))
done
assert_eq "$(M display-message -p -t "$p" '#{@agent_state}')" "" \
  "sourcing the conf alone migrates a legacy server (not just the bind r keypress)"
