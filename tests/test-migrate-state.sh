#!/usr/bin/env bash
# A server that predates per-pane state carries window-scoped @agent_state.
# Option lookup falls back pane -> window -> global, so those leftovers would be
# inherited by every UNSTAMPED pane in the window — badging plain shells as
# agents. prefix + r must clean them out without a server restart.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; trap amux_test_teardown EXIT
export AMUX_MIGRATE_SOCK="$AMUX_TEST_SOCK"

w="$(T display-message -p '#{window_id}')"
p="$(T display-message -p '#{pane_id}')"
T set-option -w -t "$w" @agent_state working
T set-option -w -t "$w" @agent_glyph "STALE"
T set-option -w -t "$w" @agent_since "12345"

# the leak this guards against: an unstamped pane inherits the window's state
assert_eq "$(T display-message -p -t "$p" '#{@agent_state}')" "working" \
  "precondition: a window-scoped leftover leaks into an unstamped pane"

"$HERE/scripts/amux-migrate-state"

assert_eq "$(T show-options -wqv -t "$w" @agent_state)" "" "migrate clears window @agent_state"
assert_eq "$(T show-options -wqv -t "$w" @agent_glyph)" "" "migrate clears window @agent_glyph"
assert_eq "$(T show-options -wqv -t "$w" @agent_since)" "" "migrate clears window @agent_since"
assert_eq "$(T display-message -p -t "$p" '#{@agent_state}')" "" \
  "an unstamped pane reads empty once the leftover is gone"

# idempotent: a second run is a clean no-op
"$HERE/scripts/amux-migrate-state"; rc=$?
assert_eq "$rc" "0" "migrate is idempotent"

# a pane's OWN state survives migration
T set-option -p -t "$p" @agent_state blocked
"$HERE/scripts/amux-migrate-state"
assert_eq "$(T show-options -pqv -t "$p" @agent_state)" "blocked" "migrate leaves pane state alone"

# no server at all -> silent no-op, never an error
out="$(AMUX_MIGRATE_SOCK=/tmp/amx.nonexistent "$HERE/scripts/amux-migrate-state" 2>&1)"; rc=$?
assert_eq "$rc" "0" "migrate exits 0 with no server"
assert_eq "$out" "" "migrate is silent with no server"
