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

# --- the subagent count (Phase 0 lane D) -------------------------------------
# Claude's SubagentStart and SubagentStop, wired to `--subagent-hook start|stop`,
# keep how many subagents a pane has running in @roost-subagents and their ids
# in @roost-subagent-ids. They are a COUNT, never a badge: neither event may
# touch @agent_state or @agent_since (the turn-over design, #97, decides what
# background work does to the badge; this is not it). The payloads below are
# the shape docs/airig/specs/2026-09-29-turn-over-design.md M10 measured on
# Claude Code 2.1.307, with every id replaced by a fake of the same shape.
if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
  printf '  SKIP: the subagent-count cases need python3 or jq to read a payload\n'
else
  subp="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' 'sh -c "while :; do sleep 5; done"')"
  require_pane "$subp" subp
  sub() { # sub start|stop PAYLOAD -- the hook exactly as `roost hooks` wires it
    env TMUX="$s,0,0" TMUX_PANE="$subp" "$HERE/scripts/roost-agent-state" --subagent-hook "$1" <<< "$2"
  }
  scount() { tmux -S "$s" show-options -pqv -t "$subp" @roost-subagents; }
  sids()   { tmux -S "$s" show-options -pqv -t "$subp" @roost-subagent-ids; }
  sstate() { tmux -S "$s" show-options -pqv -t "$subp" @agent_state; }
  # sp EVENT AGENT_ID AGENT_TYPE -> a payload of that event's measured shape.
  # SubagentStop carries everything Stop carries, including the subagent's own
  # last_assistant_message and a background_tasks that still lists the agent
  # as running (M10): the hook must take the id and the type and nothing else.
  sp() {
    case "$1" in
      SubagentStart)
        printf '{"session_id":"00000000-0000-4000-8000-000000000551","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-0000000005a1","agent_id":"%s","agent_type":"%s","hook_event_name":"SubagentStart"}' "$2" "$3" ;;
      *)
        printf '{"session_id":"00000000-0000-4000-8000-000000000551","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-0000000005a1","permission_mode":"default","agent_id":"%s","agent_type":"%s","effort":{"level":"medium"},"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000551/subagents/agent-%s.jsonl","last_assistant_message":"SUBPONG","background_tasks":[{"id":"%s","type":"subagent","status":"running","description":"rig agent","agent_type":"%s"}],"session_crons":[]}' "$2" "$3" "$2" "$2" "$3" ;;
    esac
  }
  ID1=a0000000000000001; ID2=a0000000000000002; ID3=a0000000000000003

  # Before anything: a hook that fell through into the state logic would label
  # the pane "claude" and stamp a state. Neither may happen.
  sub start "$(sp SubagentStart "$ID1" general-purpose)"; rc=$?
  assert_eq "$rc" "0" "subagent start exits 0"
  assert_eq "$(scount)" "1" "one SubagentStart -> @roost-subagents is 1"
  assert_eq "$(sids)" "$ID1" "...and @roost-subagent-ids holds its id"
  assert_eq "$(sstate)" "" "a subagent start on an unstamped pane stamps no state"
  assert_eq "$(tmux -S "$s" show-options -pqv -t "$subp" @roost-name)" "" \
    "...and labels nothing: the hook exits before the state logic"

  # Now with a badge on the pane that the subagent hooks must not touch.
  # `blocked`, not `working`: a mutant that stamps working or done moves it, and
  # the stamp's time is pinned too so a rewrite of the same value shows.
  env TMUX="$s,0,0" TMUX_PANE="$subp" "$HERE/scripts/roost-agent-state" working
  env TMUX="$s,0,0" TMUX_PANE="$subp" "$HERE/scripts/roost-agent-state" blocked
  since0="$(tmux -S "$s" show-options -pqv -t "$subp" @agent_since)"
  sleep 1
  sub start "$(sp SubagentStart "$ID2" general-purpose)"
  assert_eq "$(scount)" "2" "a second start -> 2"
  assert_eq "$(sids)" "$ID1 $ID2" "...and both ids, in start order"
  sub start "$(sp SubagentStart "$ID2" general-purpose)"
  assert_eq "$(scount)" "2" "a repeated start for an id already running changes nothing"
  assert_eq "$(sids)" "$ID1 $ID2" "...and does not list the id twice"
  sub stop "$(sp SubagentStop "$ID1" general-purpose)"; rc=$?
  assert_eq "$rc" "0" "subagent stop exits 0"
  assert_eq "$(scount)" "1" "a stop -> 1"
  assert_eq "$(sids)" "$ID2" "...and its id is gone from the list"
  sub stop "$(sp SubagentStop a0000000000000099 general-purpose)"
  assert_eq "$(scount)" "1" "a stop for an id never started changes nothing"
  assert_eq "$(sids)" "$ID2" "...and the list is untouched"
  # M4 / M10: the prompt-suggestion helper fork has agent_type "" and is not
  # the user's work. Both events must ignore it.
  sub start "$(sp SubagentStart a0000000000000077 "")"
  assert_eq "$(scount)" "1" "a SubagentStart with an empty agent_type changes nothing"
  assert_eq "$(sids)" "$ID2" "...and adds no id"
  sub stop "$(sp SubagentStop "$ID2" "")"
  assert_eq "$(scount)" "1" "a SubagentStop with an empty agent_type changes nothing, even for a running id"
  assert_eq "$(sstate)" "blocked" "@agent_state is never written by a subagent start or stop"
  assert_eq "$(tmux -S "$s" show-options -pqv -t "$subp" @agent_since)" "$since0" \
    "...and @agent_since is not rewritten either"
  sub stop "$(sp SubagentStop "$ID2" general-purpose)"
  assert_eq "$(scount)" "0" "the last stop -> 0, not unset: the pane has seen a subagent"
  assert_eq "$(sids)" "" "...and the list is empty"
  sub stop "$(sp SubagentStop "$ID2" general-purpose)"
  assert_eq "$(scount)" "0" "a stop at 0 stays 0"

  # Nothing from a payload reaches a tmux option unchecked: the id is 1-64 of
  # [a-z0-9] or the event is ignored. A space or a `;` in the list would split
  # the next format or command that reads it; an upper-case letter is refused
  # too, because the ids Claude sends are lower-case hex and anything else is
  # not an id this hook has seen.
  for bad in 'a000 0000' 'a0;set-option' 'A0000000000000001' "$(printf 'a%.0s' $(seq 65))" '' 'a0000000000000001 '; do
    sub start "$(sp SubagentStart "$bad" general-purpose)"
    assert_eq "$(scount)" "0" "a SubagentStart whose agent_id is not an id changes nothing [${bad:0:20}]"
  done
  sub start 'not json at all'
  assert_eq "$(scount)" "0" "a payload that is not JSON changes nothing"
  sub start "$(sp SubagentStart "$ID3" 'general purpose; x')"
  assert_eq "$(scount)" "1" "agent_type is only tested for emptiness: an odd one still counts"
  assert_eq "$(sids)" "$ID3" "...and only the id is recorded"
  sub bogus "$(sp SubagentStart "$ID1" general-purpose)"; rc=$?
  assert_eq "$rc" "0" "--subagent-hook with an unknown word exits 0"
  assert_eq "$(scount)" "1" "...and changes nothing"
  sub stop "$(sp SubagentStop "$ID3" general-purpose)"

  # The list is capped at 32 ids; the count keeps counting. A stop for an id
  # that is not listed takes one off the count only while the count is above
  # the list's length (so it must be one of the unlisted ones), and is ignored
  # when the two agree (so a stop for an id never started stays a no-op).
  capp="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' 'sh -c "while :; do sleep 5; done"')"
  require_pane "$capp" capp
  i=1
  while [ "$i" -le 33 ]; do
    env TMUX="$s,0,0" TMUX_PANE="$capp" "$HERE/scripts/roost-agent-state" --subagent-hook start \
      <<< "$(sp SubagentStart "$(printf 'a0000000000000%02d' "$i")" general-purpose)"
    i=$((i+1))
  done
  ccount() { tmux -S "$s" show-options -pqv -t "$capp" @roost-subagents; }
  cids()   { tmux -S "$s" show-options -pqv -t "$capp" @roost-subagent-ids; }
  assert_eq "$(ccount)" "33" "33 starts -> the count is 33"
  assert_eq "$(cids | wc -w | tr -d ' ')" "32" "...and the id list holds 32"
  case " $(cids) " in *" a000000000000033 "*) s33=listed ;; *) s33=unlisted ;; esac
  assert_eq "$s33" "unlisted" "...the 33rd id is the one left out"
  env TMUX="$s,0,0" TMUX_PANE="$capp" "$HERE/scripts/roost-agent-state" --subagent-hook stop \
    <<< "$(sp SubagentStop a000000000000033 general-purpose)"
  assert_eq "$(ccount)" "32" "a stop for the unlisted 33rd takes the count to 32"
  assert_eq "$(cids | wc -w | tr -d ' ')" "32" "...and leaves the list alone"
  env TMUX="$s,0,0" TMUX_PANE="$capp" "$HERE/scripts/roost-agent-state" --subagent-hook stop \
    <<< "$(sp SubagentStop a000000000000099 general-purpose)"
  assert_eq "$(ccount)" "32" "with count and list agreeing, a stop for an unknown id changes nothing"
  env TMUX="$s,0,0" TMUX_PANE="$capp" "$HERE/scripts/roost-agent-state" --subagent-hook stop \
    <<< "$(sp SubagentStop a000000000000001 general-purpose)"
  assert_eq "$(ccount)" "31" "a stop for a listed id -> 31"
  assert_eq "$(cids | wc -w | tr -d ' ')" "31" "...and 31 listed"

  # Three Agent calls in one message fire three SubagentStart 0.2 ms apart
  # (M10), so the update has to happen inside tmux, in one command, or the
  # three read the same value and two increments are lost. 12 starts at once
  # from a clean pane must land on 12, every time.
  parp="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' 'sh -c "while :; do sleep 5; done"')"
  require_pane "$parp" parp
  i=1
  while [ "$i" -le 12 ]; do
    env TMUX="$s,0,0" TMUX_PANE="$parp" "$HERE/scripts/roost-agent-state" --subagent-hook start \
      <<< "$(sp SubagentStart "$(printf 'b0000000000000%02d' "$i")" general-purpose)" &
    i=$((i+1))
  done
  wait
  assert_eq "$(tmux -S "$s" show-options -pqv -t "$parp" @roost-subagents)" "12" \
    "12 concurrent starts count 12: the increment happens inside tmux, not in the hook"
  assert_eq "$(tmux -S "$s" show-options -pqv -t "$parp" @roost-subagent-ids | wc -w | tr -d ' ')" "12" \
    "...and all 12 ids are listed"
  i=1
  while [ "$i" -le 12 ]; do
    env TMUX="$s,0,0" TMUX_PANE="$parp" "$HERE/scripts/roost-agent-state" --subagent-hook stop \
      <<< "$(sp SubagentStop "$(printf 'b0000000000000%02d' "$i")" general-purpose)" &
    i=$((i+1))
  done
  wait
  assert_eq "$(tmux -S "$s" show-options -pqv -t "$parp" @roost-subagents)" "0" \
    "12 concurrent stops bring it back to 0"
  assert_eq "$(tmux -S "$s" show-options -pqv -t "$parp" @roost-subagent-ids)" "" \
    "...with an empty list"
fi
