#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# roost-agent-state only acts on a socket whose path ends in /roost, so build one
# directly rather than via roost_test_server (whose socket lacks that suffix).
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
# deadsdir/ccdir/aliasdir are unset until the blocks below create them; the
# ${:-} keeps this trap safe to install (and to fire) before that point.
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir" "${deadsdir:-}" "${ccdir:-}" "${aliasdir:-}"' EXIT
# -x/-y: a detached server with no attached client defaults to an 80x24
# window. This file accumulates ten split-window panes across its assertions
# (sib, named, configured, zero, tabname, nlname, envname, envtab, namedenv,
# errp) — at 80x24, or even at a merely generous -y 200 (which fits only
# seven), tmux runs out of room and split-window fails with "no space for new
# pane" partway through, which some assertions here would otherwise mask (a
# failed split leaves the target pane ID empty, and `-t ""` quietly falls back
# to the current pane). The error-state assertions below check a specific
# pane's own state, so they do not get that accidental pass — they need the
# split to genuinely succeed, so give the window generous room.
#
# Room alone is not the guard, though. -y 2000 fits exactly the splits this
# file makes today, so the next one added would fail — and the masking above
# is what decides whether that failure is visible. Every pane id captured
# below therefore goes through require_pane (tests/lib.sh), which stops the
# file at the split that failed rather than letting the assertions after it
# quietly read the active pane. Raising the number is the fix that expires;
# checking the id is the fix that does not.
tmux -S "$s" -f /dev/null new-session -d -x 400 -y 2000
pane="$(tmux -S "$s" display -p '#{pane_id}')"
run() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-agent-state" "$1"; }
pstate() { tmux -S "$s" show-options -pqv -t "$1" @agent_state; }

# state is recorded on the PANE, which is what lets two agents share a window
run working
assert_eq "$(pstate "$pane")" "working" "state is stamped at pane scope"

# an unnamed agent pane is labelled with the built-in default, so its border
# and the switcher stop reading a churning #{pane_current_command} version
# string (e.g. "2.1.226") the moment it first reports a state
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @roost-name)" "claude" \
  "an unnamed agent pane is labelled with the default"

# and NOT on the window — a window-scoped value would be inherited by every
# unstamped pane in that window (pane -> window -> global lookup)
assert_eq "$(tmux -S "$s" show-options -wqv -t "$pane" @agent_state)" "" \
  "nothing is stamped at window scope"

# a sibling pane in the same window is untouched
sib="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$sib" sib
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
PATH="$ccdir:$PATH" TMUX="$s,0,0" TMUX_PANE="$pane" "$HERE/scripts/roost-agent-state" done
calls="$(wc -l < "$ccdir/calls" | tr -d ' ')"
assert_eq "$calls" "1" "the unchanged-state early-bail path makes exactly one tmux call"
rm -rf "$ccdir"

# a pane that already carries a human-chosen @roost-name (split -n, spawn
# NAME) keeps it — a chosen name always wins over the default
named="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$named" named
tmux -S "$s" set-option -p -t "$named" @roost-name "reviewer"
env TMUX="$s,0,0" TMUX_PANE="$named" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$named" @roost-name)" "reviewer" \
  "a pane with an existing @roost-name keeps it"

# the default label is configurable via a global tmux option, same pattern
# as @roost-glyph-* / @roost-notify-*
tmux -S "$s" set-option -g @roost-name-default "worker"
configured="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$configured" configured
env TMUX="$s,0,0" TMUX_PANE="$configured" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$configured" @roost-name)" "worker" \
  "the configured @roost-name-default overrides the built-in default"
tmux -S "$s" set-option -gu @roost-name-default

# a pane deliberately named the literal string "0" is a real tmux truthiness
# trap: #{?@roost-name,...} treats the STRING "0" as false, a bug that has
# already bitten this project at four separate sites — which is exactly why
# the hot-path read above uses #{==:#{@roost-name},} (string equality) rather
# than tmux's own truthiness ternary. Pin it: a "0"-named pane must be
# treated as already-named (has_name=1) and left alone, not overwritten with
# the default label.
zero="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$zero" zero
tmux -S "$s" set-option -p -t "$zero" @roost-name "0"
env TMUX="$s,0,0" TMUX_PANE="$zero" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$zero" @roost-name)" "0" \
  "a pane named the literal string \"0\" is treated as already-named, not overwritten"

# @roost-name-default is user-controlled tmux state, not validated at write
# time the way every OTHER @roost-name write site is (bin/roost's
# reject_bad_name). A tab or newline in it must NOT reach @roost-name
# verbatim — it would corrupt `roost status`'s tab-delimited switcher rows the
# same way reject_bad_name exists to prevent — so the hook degrades to the
# built-in default instead.
tabname="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$tabname" tabname
tmux -S "$s" set-option -g @roost-name-default "$(printf 'evil\tINJECTED')"
env TMUX="$s,0,0" TMUX_PANE="$tabname" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$tabname" @roost-name)" "claude" \
  "a tab-bearing @roost-name-default falls back to the built-in default"
tmux -S "$s" set-option -gu @roost-name-default

nlname="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$nlname" nlname
tmux -S "$s" set-option -g @roost-name-default "$(printf 'evil\nINJECTED')"
env TMUX="$s,0,0" TMUX_PANE="$nlname" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$nlname" @roost-name)" "claude" \
  "a newline-bearing @roost-name-default falls back to the built-in default"
tmux -S "$s" set-option -gu @roost-name-default

# ROOST_AGENT_NAME lets a non-Claude harness (the opencode adapter sets it in
# its execFile env) name its own pane instead of inheriting the Claude-
# flavoured default — it must be preferred over @roost-name-default.
tmux -S "$s" set-option -g @roost-name-default "worker"
envname="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$envname" envname
env TMUX="$s,0,0" TMUX_PANE="$envname" ROOST_AGENT_NAME="opencode" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$envname" @roost-name)" "opencode" \
  "ROOST_AGENT_NAME wins over @roost-name-default"

# ROOST_AGENT_NAME is process env from whatever invoked the hook — just as
# uncontrolled as @roost-name-default — so it gets the identical tab/newline
# rejection, degrading to the next fallback (@roost-name-default here) rather
# than reaching @roost-name verbatim.
envtab="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$envtab" envtab
env TMUX="$s,0,0" TMUX_PANE="$envtab" ROOST_AGENT_NAME="$(printf 'evil\tINJECTED')" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$envtab" @roost-name)" "worker" \
  "a tab-bearing ROOST_AGENT_NAME degrades to @roost-name-default"
tmux -S "$s" set-option -gu @roost-name-default

# an existing human-chosen @roost-name still wins over BOTH ROOST_AGENT_NAME
# and @roost-name-default — has_name=1 means this whole branch never runs.
namedenv="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$namedenv" namedenv
tmux -S "$s" set-option -p -t "$namedenv" @roost-name "reviewer"
env TMUX="$s,0,0" TMUX_PANE="$namedenv" ROOST_AGENT_NAME="opencode" "$HERE/scripts/roost-agent-state" working
assert_eq "$(tmux -S "$s" show-options -pqv -t "$namedenv" @roost-name)" "reviewer" \
  "an existing human-chosen @roost-name wins over ROOST_AGENT_NAME too"

# notify path: newly blocked on a NON-active window invokes roost-notify.
# The script calls roost-notify by absolute path (not via PATH), so prove the
# call through roost-notify's own effect — a marker-writing @roost-notify-cmd.
tmux -S "$s" new-window   # window 2 becomes active → our pane's window is inactive
marker="$sdir/notified"
tmux -S "$s" set-option -g @roost-notify-backend auto
tmux -S "$s" set-option -g @roost-notify-cmd "touch $marker"
run working    # establish a non-blocked prev so the next call is a real transition
run blocked    # transition → blocked on an inactive window → notify
[ -f "$marker" ] && assert_eq ok ok "blocked on an inactive window invokes roost-notify" \
  || assert_eq "" fired "blocked on an inactive window invokes roost-notify"

# --- the error state ---
# error is a real state word, not folded into idle by the normaliser.
errp="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$errp" errp
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/roost-agent-state" error
assert_eq "$(pstate "$errp")" "error" "error is accepted as a state, not normalised to idle"

# an unrecognised word still lands on idle — the normaliser did not simply
# start passing everything through
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/roost-agent-state" banana
assert_eq "$(pstate "$errp")" "idle" "an unrecognised state is still normalised to idle"

# error shares blocked's notification path: an agent that will not progress
# without you is worth a ping whether it is waiting or broken. The window here
# is inactive (a second window was created above), so the ping should fire.
notif2="$sdir/notified-error"
tmux -S "$s" set-option -g @roost-notify-cmd "touch $notif2"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/roost-agent-state" working
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/roost-agent-state" error
[ -f "$notif2" ] && assert_eq ok ok "error on an inactive window invokes roost-notify" \
  || assert_eq "" fired "error on an inactive window invokes roost-notify"

# but done still does NOT notify — it fires every turn and would be noise
notif3="$sdir/notified-done"
tmux -S "$s" set-option -g @roost-notify-cmd "touch $notif3"
env TMUX="$s,0,0" TMUX_PANE="$errp" "$HERE/scripts/roost-agent-state" done
[ -f "$notif3" ] && assert_eq fired "" "done does not notify" \
  || assert_eq ok ok "done does not notify"

# reached through a symlink, the hook must still find its REAL sibling. This
# script is wired into ~/.claude/settings.json by absolute path, and that path
# can be a symlink (an alias on PATH, a compatibility shim left behind by a
# rename). $0 is then the SYMLINK, so a plain `$(dirname "$0")/roost-notify`
# resolves the sibling next to the symlink, misses, and — because the call
# deliberately carries `|| true` so a dead tmux server can never break Claude —
# fails silently as far as the caller can tell: the hook still exits 0, so
# desktop notifications just stop, the only trace a stderr line the harness
# that invoked the hook discards.
# Pin it: invoked via an alias in an unrelated directory, the notify still fires.
aliasdir="$(mktemp -d /tmp/amx.XXXX)"
ln -s "$HERE/scripts/roost-agent-state" "$aliasdir/agent-state-alias"
notif4="$sdir/notified-via-symlink"
tmux -S "$s" set-option -g @roost-notify-cmd "touch $notif4"
# A fresh pane, because the notify only fires on a real transition INTO
# blocked and every pane above already carries a state. It gets its OWN window
# rather than an eleventh split of $pane: that window is already carrying the
# ten splits the header comment lists, and one more overflows even -y 2000
# ("no space for new pane"). `new-window -d` leaves window 2 current, so the
# new window is inactive — which is what the notify path requires.
aliasp="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' 'sh -c "while :; do sleep 5; done"')"
require_pane "$aliasp" aliasp
env TMUX="$s,0,0" TMUX_PANE="$aliasp" "$aliasdir/agent-state-alias" working
env TMUX="$s,0,0" TMUX_PANE="$aliasp" "$aliasdir/agent-state-alias" blocked
[ -f "$notif4" ] && assert_eq ok ok "invoked through a symlink, the hook still finds the real roost-notify" \
  || assert_eq "" fired "invoked through a symlink, the hook still finds the real roost-notify"

# and through a CHAIN whose first hop is relative. `readlink` hands back the
# target verbatim, so a relative one is meaningless until it is re-anchored to
# the link's own directory — the `[[ "$SOURCE" != /* ]]` arm of the resolver
# loop, which the absolute link above never reaches. Link farms (Homebrew,
# stow) and an in-place rename shim both produce exactly this shape, and
# getting it wrong lands SELF_DIR on the alias directory again.
ln -s agent-state-alias "$aliasdir/agent-state-hop"
notif5="$sdir/notified-via-symlink-chain"
tmux -S "$s" set-option -g @roost-notify-cmd "touch $notif5"
hopp="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' 'sh -c "while :; do sleep 5; done"')"
require_pane "$hopp" hopp
env TMUX="$s,0,0" TMUX_PANE="$hopp" "$aliasdir/agent-state-hop" working
env TMUX="$s,0,0" TMUX_PANE="$hopp" "$aliasdir/agent-state-hop" blocked
[ -f "$notif5" ] && assert_eq ok ok "a relative symlink hop is re-anchored to the link's own directory" \
  || assert_eq "" fired "a relative symlink hop is re-anchored to the link's own directory"
# aliasdir cleanup is handled by the top-of-file EXIT trap.

# never-break-Claude: a dead tmux server must degrade, not abort the hook.
deadsdir="$(mktemp -d /tmp/amx.XXXX)"; ds="$deadsdir/roost"
tmux -S "$ds" -f /dev/null new-session -d
dpane="$(tmux -S "$ds" display -p '#{pane_id}')"
tmux -S "$ds" kill-server 2>/dev/null
env TMUX="$ds,0,0" TMUX_PANE="$dpane" "$HERE/scripts/roost-agent-state" working
assert_eq "$?" "0" "dead tmux server degrades, does not abort the hook"
# deadsdir cleanup is handled by the top-of-file EXIT trap.
