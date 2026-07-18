#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# amux-agent-state only acts on a socket whose path ends in /amux, so build one
# directly rather than via amux_test_server (whose socket lacks that suffix).
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
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

# notify path: newly blocked on a NON-active window invokes amux-notify.
# The script calls amux-notify by absolute path (not via PATH), so prove the
# call through amux-notify's own effect — a marker-writing @amux-notify-cmd.
tmux -S "$s" new-window   # window 2 becomes active → our pane's window is inactive
marker="$sdir/notified"
tmux -S "$s" set-option -g @amux-notify-backend auto
tmux -S "$s" set-option -g @amux-notify-cmd "touch $marker"
run working    # establish a non-blocked prev so the next call is a real transition
run blocked    # transition → blocked on an inactive window → notify
[ -f "$marker" ] && assert_eq ok ok "blocked on an inactive window invokes amux-notify" \
  || assert_eq "" fired "blocked on an inactive window invokes amux-notify"

# never-break-Claude: a dead tmux server must degrade, not abort the hook.
deadsdir="$(mktemp -d /tmp/amx.XXXX)"; ds="$deadsdir/amux"
tmux -S "$ds" -f /dev/null new-session -d
dpane="$(tmux -S "$ds" display -p '#{pane_id}')"
tmux -S "$ds" kill-server 2>/dev/null
env TMUX="$ds,0,0" TMUX_PANE="$dpane" "$HERE/scripts/amux-agent-state" working
assert_eq "$?" "0" "dead tmux server degrades, does not abort the hook"
rm -rf "$deadsdir"
