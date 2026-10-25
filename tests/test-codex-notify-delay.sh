#!/usr/bin/env bash
# The deferred `blocked` ping (#195): codex opts in, every other harness pings
# at once.
#
# Under codex's auto-review (`approvals_reviewer = "auto_review"`) every
# sandbox escalation fires PermissionRequest, roost badges 🛑, and about two
# seconds later the reviewer approves it and the pane is working again. A ping
# sent the instant the pane went blocked sends the human to a pane with nothing
# to answer -- measured on one machine, 20 of 38 codex blocked states cleared
# within 5 s once auto-review was on, against 0 of 30 before. A parallel tool
# batch sent 3 to 4 of them in the same second.
#
# So the codex adapter opts in (ROOST_NOTIFY_DEFER=1) and the sink waits
# @roost-notify-delay seconds before it pings, and then pings only if the SAME
# dialog is still open on a window that is still off screen. Each case below is
# one line of the issue's "done when", plus the window that comes back on
# screen during the wait.
#
# The notifier is a logger: @roost-notify-cmd appends one line per delivery to
# $NOTES, with the OSC backend off so nothing reaches the terminal running the
# suite. That is the real roost-notify running a fake delivery command, so the
# count is of calls that would have reached the desktop. Every wait is bounded:
# a deferred ping that never arrives fails the case after a few seconds, it
# does not hang the suite.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HERE/adapters/codex/roost-codex-hook"
SINK="$HERE/scripts/roost-agent-state"

# Every home a hook could write into goes to a temp dir (AGENTS.md §8). The
# sink writes the event log under XDG_STATE_HOME unless ROOST_EVENTS says
# otherwise, so both are pointed here; the rest are pointed at a canary that
# nothing may write to, checked at the end, the shape tests/test-install.sh
# uses.
T0="$(mktemp -d /tmp/amx.XXXX)"; s="$T0/roost"
CANARY="$T0/canary"
mkdir -p "$T0/home" "$T0/state"
export HOME="$T0/home" XDG_STATE_HOME="$T0/state" ROOST_EVENTS="$T0/state/events"
export XDG_CONFIG_HOME="$CANARY/xdg-config" XDG_DATA_HOME="$CANARY/xdg-data"
export COPILOT_HOME="$CANARY/copilot" PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex" CLAUDE_SETTINGS="$CANARY/claude/settings.json"
export ZDOTDIR="$CANARY/zdot"
unset ROOST_NOTIFY_DEFER TMUX TMUX_PANE
# A deferred child outlives the hook that started it, so it can outlive this
# file too. Killing the server first means a late child's tmux calls fail, and
# every one of them carries `|| true`.
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$T0"' EXIT

# The agent's window and a second one, and the SECOND is selected: the agent is
# off screen, which is the only case that notifies at all.
tmux -S "$s" -f /dev/null new-session -d -s s -n agent -x 200 -y 50 'sleep 600'
pane="$(tmux -S "$s" display -p -t s:agent '#{pane_id}')"
tmux -S "$s" new-window -d -t s -n other 'sleep 600'
tmux -S "$s" select-window -t s:other

NOTES="$T0/notes"; : > "$NOTES"
tmux -S "$s" set-option -g @roost-notify-backend auto
tmux -S "$s" set-option -g @roost-notify-osc off
tmux -S "$s" set-option -g @roost-notify-cmd "echo \"%t|%s\" >> $NOTES"
# 1 s, so the suite stays fast. The default is 5 and is checked below without
# waiting for it.
tmux -S "$s" set-option -g @roost-notify-delay 1

hook() { printf '%s' "${2-{\}}" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" "$1"; }
# Claude's own hook: the sink called directly, with no opt-in in its env.
claude() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$SINK" "$@" < /dev/null; }
pstate() { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }
count() { wc -l < "$NOTES" | tr -d ' '; }
# until_count N SECS -- wait up to SECS for N pings, polling. Bounded.
until_count() {
  local i=0
  while [ "$(count)" -lt "$1" ] && [ "$i" -lt $(($2 * 10)) ]; do sleep 0.1; i=$((i + 1)); done
}
reset() { : > "$NOTES"; }

FIX_DIR=/tmp/roost-codex-fixture
UPS='{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","transcript_path":null,"cwd":"'"$FIX_DIR"'/work","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"go"}'
# perm N -- a PermissionRequest shaped like codex 0.164.0's, one per escalation.
perm() { printf '{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","transcript_path":null,"cwd":"%s/work","hook_event_name":"PermissionRequest","model":"m","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"gh api repos/x/y/contents/f%s"}}' "$FIX_DIR" "$1"; }
POST='{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh api"},"tool_response":""}'
STOP_EMPTY='{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","transcript_path":null,"cwd":"'"$FIX_DIR"'/work","hook_event_name":"Stop","model":"m","permission_mode":"default","stop_hook_active":false,"last_assistant_message":""}'

hook UserPromptSubmit "$UPS"
assert_eq "$(pstate)" "working" "setup: the codex pane is working"

# --- 1. self-approved escalations inside the delay ping nothing ---------------
reset
for i in 1 2 3 4 5; do
  hook PermissionRequest "$(perm "a$i")"
  sleep 0.2
  hook PostToolUse "$POST"
done
assert_eq "$(pstate)" "working" "five auto-approved escalations leave the pane working"
sleep 2.5
assert_eq "$(count)" "0" "five escalations approved inside the delay send no ping"

# --- 2. a dialog still open after the delay pings once ------------------------
# A fresh second, so this dialog's stamp is not the one before it.
sleep 1
reset
hook PermissionRequest "$(perm b1)"
assert_eq "$(count)" "0" "a codex dialog does not ping at once"
until_count 1 4
sleep 1.5
assert_eq "$(count)" "1" "a codex dialog still open after the delay pings exactly once"
assert_contains "$(cat "$NOTES")" "needs your input" "...with the blocked message"
hook PostToolUse "$POST"

# --- 3. a parallel batch of four is one ping ----------------------------------
sleep 1
reset
for i in 1 2 3 4; do hook PermissionRequest "$(perm "c$i")" & done
wait
assert_eq "$(pstate)" "blocked" "a parallel batch of four escalations badges blocked"
until_count 1 4
sleep 1.5
assert_eq "$(count)" "1" "a burst of four blocked hooks sends one ping, not four"
hook PostToolUse "$POST"

# --- 4. codex error is immediate ----------------------------------------------
reset
hook Stop "$STOP_EMPTY"
assert_eq "$(pstate)" "error" "an empty codex Stop reports error"
assert_eq "$(count)" "1" "a codex error pings at once, with no delay"
assert_contains "$(cat "$NOTES")" "hit an error" "...with the error message"

# --- 5. Claude, which does not opt in, is immediate ---------------------------
claude working
reset
claude blocked
assert_eq "$(pstate)" "blocked" "a Claude blocked badges blocked"
assert_eq "$(count)" "1" "a Claude blocked (no opt-in) pings at once"
claude working

# --- 6. @roost-notify-delay 0 is today's instant ping for codex ----------------
# The control for cases 1 to 3: with no delay the same harness and logger see
# a codex ping at once, so the zeroes above are a delay working and not a
# logger that never fires.
hook UserPromptSubmit "$UPS"
tmux -S "$s" set-option -g @roost-notify-delay 0
reset
hook PermissionRequest "$(perm d1)"
assert_eq "$(count)" "1" "@roost-notify-delay 0 makes a codex dialog ping at once"
hook PostToolUse "$POST"
# A pane option beats the global one: delay 0 on this pane alone, 1 globally.
tmux -S "$s" set-option -g @roost-notify-delay 1
tmux -S "$s" set-option -p -t "$pane" @roost-notify-delay 0
sleep 1
reset
hook PermissionRequest "$(perm d2)"
assert_eq "$(count)" "1" "a pane's @roost-notify-delay overrides the global one"
hook PostToolUse "$POST"
tmux -S "$s" set-option -pu -t "$pane" @roost-notify-delay

# --- 7. the window came on screen during the wait: no ping ---------------------
sleep 1
reset
hook PermissionRequest "$(perm e1)"
tmux -S "$s" select-window -t s:agent
sleep 2.5
assert_eq "$(count)" "0" "a window brought on screen during the delay gets no ping"
hook PostToolUse "$POST"
tmux -S "$s" select-window -t s:other

# --- 8. a bad delay degrades to the default, and the hook never waits ---------
# The child is detached: codex waits on this hook's exit, and the hook's
# caller here is a command substitution, which would also wait on any child
# that kept stdout open. "abc" degrades to the 5 s default, so a hook that
# slept or held the pipe would take 5 s; a detached one returns at once.
tmux -S "$s" set-option -g @roost-notify-delay abc
sleep 1
reset
t0="$(date +%s)"
out="$(hook PermissionRequest "$(perm f1)"; echo "rc=$?")"
t1="$(date +%s)"
assert_eq "$out" "rc=0" "a bad @roost-notify-delay never breaks the hook"
[ $((t1 - t0)) -le 2 ] && assert_eq ok ok "the hook returns before the deferred ping, not after it" \
  || assert_eq "$((t1 - t0)) s" "under 3 s" "the hook returns before the deferred ping, not after it"
sleep 1.5
assert_eq "$(count)" "0" "a bad @roost-notify-delay falls back to the default, not to 0"
hook PostToolUse "$POST"

canary_leaks="$(find "$CANARY" -mindepth 1 2>/dev/null | sort)"
assert_eq "$canary_leaks" "" "nothing wrote into a home this file did not redirect"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
