#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# amux-agent-state only acts on a socket whose path ends in /amux, so build one
# directly rather than via amux_test_server (whose socket lacks that suffix).
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
# deadsdir is unset until the dead-server block below creates it; the ${:-}
# keeps this trap safe to install (and to fire) before that point.
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir" "${deadsdir:-}"' EXIT
tmux -S "$s" -f /dev/null new-session -d
pane="$(tmux -S "$s" display -p '#{pane_id}')"
run() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/amux-agent-state" "$1"; }
pstate() { tmux -S "$s" show-options -pqv -t "$1" @agent_state; }

# state is recorded on the PANE, which is what lets two agents share a window
run working
assert_eq "$(pstate "$pane")" "working" "state is stamped at pane scope"

# and NOT on the window — a window-scoped value would be inherited by every
# unstamped pane in that window (pane -> window -> global lookup)
assert_eq "$(tmux -S "$s" show-options -wqv -t "$pane" @agent_state)" "" \
  "nothing is stamped at window scope"

# a sibling pane in the same window is untouched
sib="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
run blocked
assert_eq "$(pstate "$sib")" "" "stamping one pane leaves its sibling empty"
assert_eq "$(pstate "$pane")" "blocked" "the stamped pane holds its own state"

# the retired glyph option is never written
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @agent_glyph)" "" \
  "@agent_glyph is retired and never stamped"

# early-return: a repeat call does not rewrite @agent_since
run done
before="$(tmux -S "$s" show-options -pqv -t "$pane" @agent_since)"
sleep 1; run done
after="$(tmux -S "$s" show-options -pqv -t "$pane" @agent_since)"
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
# deadsdir cleanup is handled by the top-of-file EXIT trap.
