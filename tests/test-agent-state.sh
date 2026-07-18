#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
# amux-agent-state only acts on a socket path ending in /amux
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
tmux -S "$s" -f /dev/null new-session -d
pane="$(tmux -S "$s" display -p '#{pane_id}')"
# configured glyph for 'working'
tmux -S "$s" set-option -g @amux-glyph-working "GW"
run() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/amux-agent-state" "$1"; }
st() { tmux -S "$s" display -p -t "$pane" '#{@agent_state}|#{@agent_glyph}'; }

run working
assert_eq "$(st)" "working|GW" "glyph is read from @amux-glyph-working, not hardcoded"

# unknown/empty config → built-in default, never blank
tmux -S "$s" set-option -gu @amux-glyph-working
run idle; run working
assert_contains "$(st)" "working|" "missing config falls back to a non-empty glyph"
[ "$(tmux -S "$s" display -p -t "$pane" '#{@agent_glyph}')" != "" ] \
  && assert_eq ok ok "glyph never blank" || assert_eq "" "non-empty" "glyph never blank"

# early-return: repeat call does not restamp @agent_since
run done
before="$(tmux -S "$s" display -p -t "$pane" '#{@agent_since}')"
sleep 1; run done
after="$(tmux -S "$s" display -p -t "$pane" '#{@agent_since}')"
assert_eq "$after" "$before" "unchanged state bails before writing"

tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"
