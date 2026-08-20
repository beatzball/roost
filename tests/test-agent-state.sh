#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# amux-agent-state only acts on a socket whose path ends in /amux, so build one
# directly rather than via amux_test_server (whose socket lacks that suffix).
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/amux"
# deadsdir/ccdir are unset until the blocks below create them; the ${:-}
# keeps this trap safe to install (and to fire) before that point.
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir" "${deadsdir:-}" "${ccdir:-}"' EXIT
# -x/-y: a detached server with no attached client defaults to an 80x24
# window. This file accumulates ten split-window panes across its assertions
# (sib, named, configured, zero, tabname, nlname, envname, envtab, namedenv,
# errp) — at 80x24, or even at a merely generous -y 200 (which fits only
# seven), tmux runs out of room and split-window fails with "no space for new
# pane" partway through, which some existing assertions mask (a failed split
# leaves the target pane ID empty, and `-t ""` quietly falls back to the
# current pane). The error-state assertions below check a specific pane's own
# state, so they do not get that accidental pass — they need the split to
# genuinely succeed, so give the window generous room.
tmux -S "$s" -f /dev/null new-session -d -x 400 -y 2000
pane="$(tmux -S "$s" display -p '#{pane_id}')"
run() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/amux-agent-state" "$1"; }
pstate() { tmux -S "$s" show-options -pqv -t "$1" @agent_state; }

# state is recorded on the PANE, which is what lets two agents share a window
run working
assert_eq "$(pstate "$pane")" "working" "state is stamped at pane scope"

# an unnamed agent pane is labelled with the built-in default, so its border
# and the switcher stop reading a churning #{pane_current_command} version
# string (e.g. "2.1.226") the moment it first reports a state
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @amux-name)" "claude" \
  "an unnamed agent pane is labelled with the default"

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

# the label check is folded into the same display-message call that reads
# @agent_state for the early-bail comparison, so the hot (unchanged-state)
# path must still cost exactly ONE tmux invocation — proven by shimming
# `tmux` on PATH to log every call it receives, then counting.
ccdir="$(mktemp -d /tmp/amx.XXXX)"
realtmux="$(command -v tmux)"
: > "$ccdir/calls"
cat > "$ccdir/tmux" <<SHIM
#!/bin/sh
echo x >> "$ccdir/calls"
exec "$realtmux" "\$@"
SHIM
chmod +x "$ccdir/tmux"
# $pane is already "done" (set above), so this call hits the early bail.
PATH="$ccdir:$PATH" TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/amux-agent-state" done
calls="$(wc -l < "$ccdir/calls" | tr -d ' ')"
assert_eq "$calls" "1" "the unchanged-state early-bail path makes exactly one tmux call"
rm -rf "$ccdir"

# a pane that already carries a human-chosen @amux-name (split -n, spawn
# NAME) keeps it — a chosen name always wins over the default
named="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
tmux -S "$s" set-option -p -t "$named" @amux-name "reviewer"
env TMUX="$s,0,0" TMUX_PANE="$named" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$named" @amux-name)" "reviewer" \
  "a pane with an existing @amux-name keeps it"

# the default label is configurable via a global tmux option, same pattern
# as @amux-glyph-* / @amux-notify-*
tmux -S "$s" set-option -g @amux-name-default "worker"
configured="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
env TMUX="$s,0,0" TMUX_PANE="$configured" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$configured" @amux-name)" "worker" \
  "the configured @amux-name-default overrides the built-in default"
tmux -S "$s" set-option -gu @amux-name-default

# a pane deliberately named the literal string "0" is a real tmux truthiness
# trap: #{?@amux-name,...} treats the STRING "0" as false, a bug that has
# already bitten this project at four separate sites — which is exactly why
# the hot-path read above uses #{==:#{@amux-name},} (string equality) rather
# than tmux's own truthiness ternary. Pin it: a "0"-named pane must be
# treated as already-named (has_name=1) and left alone, not overwritten with
# the default label.
zero="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
tmux -S "$s" set-option -p -t "$zero" @amux-name "0"
env TMUX="$s,0,0" TMUX_PANE="$zero" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$zero" @amux-name)" "0" \
  "a pane named the literal string \"0\" is treated as already-named, not overwritten"

# @amux-name-default is user-controlled tmux state, not validated at write
# time the way every OTHER @amux-name write site is (bin/amux's
# reject_bad_name). A tab or newline in it must NOT reach @amux-name
# verbatim — it would corrupt `amux status`'s tab-delimited switcher rows the
# same way reject_bad_name exists to prevent — so the hook degrades to the
# built-in default instead.
tabname="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
tmux -S "$s" set-option -g @amux-name-default "$(printf 'evil\tINJECTED')"
env TMUX="$s,0,0" TMUX_PANE="$tabname" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$tabname" @amux-name)" "claude" \
  "a tab-bearing @amux-name-default falls back to the built-in default"
tmux -S "$s" set-option -gu @amux-name-default

nlname="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
tmux -S "$s" set-option -g @amux-name-default "$(printf 'evil\nINJECTED')"
env TMUX="$s,0,0" TMUX_PANE="$nlname" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$nlname" @amux-name)" "claude" \
  "a newline-bearing @amux-name-default falls back to the built-in default"
tmux -S "$s" set-option -gu @amux-name-default

# AMUX_AGENT_NAME lets a non-Claude harness (the opencode adapter sets it in
# its execFile env) name its own pane instead of inheriting the Claude-
# flavoured default — it must be preferred over @amux-name-default.
tmux -S "$s" set-option -g @amux-name-default "worker"
envname="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
env TMUX="$s,0,0" TMUX_PANE="$envname" AMUX_AGENT_NAME="opencode" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$envname" @amux-name)" "opencode" \
  "AMUX_AGENT_NAME wins over @amux-name-default"

# AMUX_AGENT_NAME is process env from whatever invoked the hook — just as
# uncontrolled as @amux-name-default — so it gets the identical tab/newline
# rejection, degrading to the next fallback (@amux-name-default here) rather
# than reaching @amux-name verbatim.
envtab="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
env TMUX="$s,0,0" TMUX_PANE="$envtab" AMUX_AGENT_NAME="$(printf 'evil\tINJECTED')" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$envtab" @amux-name)" "worker" \
  "a tab-bearing AMUX_AGENT_NAME degrades to @amux-name-default"
tmux -S "$s" set-option -gu @amux-name-default

# an existing human-chosen @amux-name still wins over BOTH AMUX_AGENT_NAME
# and @amux-name-default — has_name=1 means this whole branch never runs.
namedenv="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
tmux -S "$s" set-option -p -t "$namedenv" @amux-name "reviewer"
env TMUX="$s,0,0" TMUX_PANE="$namedenv" AMUX_AGENT_NAME="opencode" "$HERE/scripts/amux-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$namedenv" @amux-name)" "reviewer" \
  "an existing human-chosen @amux-name wins over AMUX_AGENT_NAME too"

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

# --- the error state ---
# error is a real state word, not folded into idle by the normaliser.
errp="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" error
assert_eq "$(pstate "$errp")" "error" "error is accepted as a state, not normalised to idle"

# an unrecognised word still lands on idle — the normaliser did not simply
# start passing everything through
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" banana
assert_eq "$(pstate "$errp")" "idle" "an unrecognised state is still normalised to idle"

# error shares blocked's notification path: an agent that will not progress
# without you is worth a ping whether it is waiting or broken. The window here
# is inactive (a second window was created above), so the ping should fire.
notif2="$sdir/notified-error"
tmux -S "$s" set-option -g @amux-notify-cmd "touch $notif2"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" working
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" error
[ -f "$notif2" ] && assert_eq ok ok "error on an inactive window invokes amux-notify" \
  || assert_eq "" fired "error on an inactive window invokes amux-notify"

# but done still does NOT notify — it fires every turn and would be noise
notif3="$sdir/notified-done"
tmux -S "$s" set-option -g @amux-notify-cmd "touch $notif3"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/amux-agent-state" done
[ -f "$notif3" ] && assert_eq fired "" "done does not notify" \
  || assert_eq ok ok "done does not notify"

# never-break-Claude: a dead tmux server must degrade, not abort the hook.
deadsdir="$(mktemp -d /tmp/amx.XXXX)"; ds="$deadsdir/amux"
tmux -S "$ds" -f /dev/null new-session -d
dpane="$(tmux -S "$ds" display -p '#{pane_id}')"
tmux -S "$ds" kill-server 2>/dev/null
env TMUX="$ds,0,0" TMUX_PANE="$dpane" "$HERE/scripts/amux-agent-state" working
assert_eq "$?" "0" "dead tmux server degrades, does not abort the hook"
# deadsdir cleanup is handled by the top-of-file EXIT trap.
