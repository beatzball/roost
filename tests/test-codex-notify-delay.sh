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
# suite. Each line starts with the time the delivery ran, to the microsecond,
# so a case can ask how many pings came before a deadline (pings_before).
# That is the real roost-notify running a fake delivery command, so the
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
export CODEX_HOME="$CANARY/codex" CLAUDE_CONFIG_DIR="$CANARY/claude-config" CLAUDE_SETTINGS="$CANARY/claude/settings.json"
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
# A script, not an inline command: roost-notify turns every %s in the command
# into the message, so a printf format cannot live in it.
cat > "$T0/note" <<EOF
#!/bin/sh
printf '%s|%s|%s\\n' "\$(python3 -c 'import time; print(repr(time.time()))')" "\$1" "\$2" >> "$NOTES"
EOF
chmod +x "$T0/note"
tmux -S "$s" set-option -g @roost-notify-cmd "$T0/note \"%t\" \"%s\""
# 2 s, so the suite stays fast. The default is 5 and is checked below without
# waiting for it. Not 1: cases 1 and 7 answer a dialog (or bring the window on
# screen) a few tenths of a second after the hook, and the deferred child
# wakes one delay after the hook. With 1 s that left the answer about 0.6 s to
# land, which a hook slowed by a loaded machine can spend; 2 s gives it more
# than a second and a half (#202). Delay 1 itself has its own check, in case 2.
tmux -S "$s" set-option -g @roost-notify-delay 2

# The date shim (#202): with FAKE_S set, `date +%s` in a hook prints it, so
# cases 9 to 11 choose which whole second each stamp lands in instead of
# racing the real clock for it (case 9 says why). Anything else, and any
# call with FAKE_S empty, is the real date. A script, never a symlink to the
# real binary: a later `>` into a shim entry would follow the link.
SHIM="$T0/shim"; mkdir -p "$SHIM"
REAL_DATE="$(command -v date)"
cat > "$SHIM/date" <<EOF
#!/bin/sh
if [ -n "\${ROOST_TEST_FAKE_S:-}" ] && [ "\$#" = 1 ] && [ "\$1" = +%s ]; then
  echo "\$ROOST_TEST_FAKE_S"; exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$SHIM/date"
FAKE_S=""
hook() { printf '%s' "${2-{\}}" | env TMUX="$s,0,0" TMUX_PANE="$pane" PATH="$SHIM:$PATH" ROOST_TEST_FAKE_S="$FAKE_S" "$HOOK" "$1"; }
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
# Sub-second timing for the cases that are ABOUT one second: the sink's stamp
# is `date +%s`, so whether two dialogs share it depends on where in the
# second they open. python3 rather than `date +%s.%N`, which BSD date lacks.
# next_second -> the next whole second, after waiting until just past it.
# at S+F -- sleep until that absolute time; at once if it has passed.
next_second() { python3 -c 'import time; s = int(time.time()) + 1; time.sleep(max(0, s + 0.02 - time.time())); print(s)'; }
at() { python3 -c 'import sys, time; time.sleep(max(0, eval(sys.argv[1]) - time.time()))' "$1"; }
since() { tmux -S "$s" show-options -pqv -t "$pane" @agent_since; }
# now -> the time, to the microsecond. Cases 9 to 11 take their deadlines
# from when each hook really ran, not from where in the second it was meant
# to run: on a loaded CI runner one hook took more than 0.25 s to reach its
# stamp, and fixed offsets from S carried that slip into the asserts.
now() { python3 -c 'import time; print(repr(time.time()))'; }
# count_by N T -- poll until N pings or the absolute time T, whichever is
# first. Unlike until_count it ends AT T, so a case can read the count just
# before a deadline it must not reach.
count_by() {
  python3 -c '
import sys, time
n, end, f = int(sys.argv[1]), eval(sys.argv[2]), sys.argv[3]
while time.time() < end and sum(1 for _ in open(f)) < n:
    time.sleep(0.05)' "$1" "$2" "$NOTES"
}
# pings_before T -- how many pings the notifier stamped before the absolute
# time T. The "no ping yet" checks use this, not count (#202): a deferred
# child cannot ping before its hook started plus its delay, so with T that
# deadline, a ping that the code was right to send is never counted, however
# long this file is paused before it reads. A ping too early is counted.
pings_before() {
  python3 -c '
import sys
end = eval(sys.argv[1])
print(sum(1 for l in open(sys.argv[2]) if float(l.split("|", 1)[0]) < end))' "$1" "$NOTES"
}
# before T -- true if the time is still before T. Called just after a dialog
# is answered, with T its child's earliest wake: then the answer landed
# first, and a ping would be wrong. If not, the setup missed (#202).
before() { python3 -c 'import sys, time; sys.exit(0 if time.time() < eval(sys.argv[1]) else 1)' "$1"; }
# retry_once CASE -- run CASE; if its setup missed (it returns 1 and sets
# MISS_WHAT / MISS_WANT / MISS_GOT), say so and run it once more in a fresh
# second. Only a second miss fails. The setup is hooks landing in chosen
# seconds, or an answer landing before a child wakes, and a loaded runner can
# push either one late however wide the margin; a miss is not a wrong tree, so
# one is forgiven and reported. A case checks for a ping that no timing could
# make right BEFORE it returns 1, because the retry's reset erases the log.
retry_once() {
  "$1" && return 0
  printf '  note: %s missed (%s: got [%s]), retrying once in a fresh second\n' "$1" "$MISS_WHAT" "$MISS_GOT"
  sleep 1
  "$1" && return 0
  assert_eq "$MISS_GOT" "$MISS_WANT" "$MISS_WHAT"
}

FIX_DIR=/tmp/roost-codex-fixture
UPS='{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","transcript_path":null,"cwd":"'"$FIX_DIR"'/work","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"default","prompt":"go"}'
# perm N -- a PermissionRequest shaped like codex 0.164.0's, one per escalation.
perm() { printf '{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","transcript_path":null,"cwd":"%s/work","hook_event_name":"PermissionRequest","model":"m","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"gh api repos/x/y/contents/f%s"}}' "$FIX_DIR" "$1"; }
POST='{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh api"},"tool_response":""}'
STOP_EMPTY='{"session_id":"01a16fcc-0000-7000-8000-000000000001","turn_id":"t1","transcript_path":null,"cwd":"'"$FIX_DIR"'/work","hook_event_name":"Stop","model":"m","permission_mode":"default","stop_hook_active":false,"last_assistant_message":""}'

hook UserPromptSubmit "$UPS"
assert_eq "$(pstate)" "working" "setup: the codex pane is working"

# --- 1. self-approved escalations inside the delay ping nothing ---------------
# Started just past a second boundary, on purpose: the first two or three
# dialogs open in the same second and share a stamp, so this holds only
# because each entry into blocked has its own identity, not because each
# dialog happens to land in a later second (review, #195).
#
# Each answer must land before that dialog's child wakes, two seconds after
# its hook was called; one that lands later leaves a dialog open for the full
# delay, and its ping is right. So a late answer is a missed setup, retried
# once, not a FAIL (#202).
#
# The batch stops at the first late answer. Every dialog before it was
# answered in time, so none of their children may ping at all, and the late
# one's child cannot wake before its own t + 2: no ping before that is right.
# Opening more dialogs after a miss would add deadlines that a ping carries
# no id to tell apart, and a wrong ping from one of them could pass a check
# on the first and be erased by the retry (review, #202).
case_1() {
  reset
  next_second > /dev/null
  late=""; tl=""
  for i in 1 2 3 4 5; do
    t="$(now)"; hook PermissionRequest "$(perm "a$i")"
    sleep 0.2
    hook PostToolUse "$POST"
    before "$t + 2" || { late="a$i"; tl="$t"; break; }
  done
  assert_eq "$(pstate)" "working" "five auto-approved escalations leave the pane working"
  sleep 3.5
  if [ -n "$late" ]; then
    # Counted after the wait, which outlasts the late dialog's child, and
    # before the retry's reset empties the log (#202).
    assert_eq "$(pings_before "$tl + 2")" "0" "an escalation does not ping before its delay, even in a missed setup"
    MISS_WHAT="setup: each escalation answered before its child woke"
    MISS_WANT="none late"; MISS_GOT="late: $late"
    return 1
  fi
  assert_eq "$(count)" "0" "five escalations approved inside the delay send no ping"
}
retry_once case_1

# --- 2. a dialog still open after the delay pings once ------------------------
# A fresh second, so this dialog's stamp is not the one before it.
sleep 1
reset
t="$(now)"; hook PermissionRequest "$(perm b1)"
until_count 1 4
sleep 1.5
# Counted after the wait, not as the hook returns: an early ping from the
# detached child takes a moment to reach the notifier, and read at once it
# would not be in the log yet. A right ping is stamped after t + 2, so the
# wait never counts it (#202).
assert_eq "$(pings_before "$t + 2")" "0" "a codex dialog does not ping at once"
assert_eq "$(count)" "1" "a codex dialog still open after the delay pings exactly once"
assert_contains "$(cat "$NOTES")" "needs your input" "...with the blocked message"
hook PostToolUse "$POST"
# The smallest delay there is, 1 s (#202). The global delay was 1 until it
# went to 2 for cases 1 and 7, and a sink that treated 1 as 0 would then
# pass every other case here.
sleep 1
reset
tmux -S "$s" set-option -g @roost-notify-delay 1
t="$(now)"; hook PermissionRequest "$(perm b2)"
until_count 1 4
sleep 1
# After the wait, as above.
assert_eq "$(pings_before "$t + 1")" "0" "@roost-notify-delay 1 does not ping at once"
assert_eq "$(count)" "1" "...and pings exactly once after its one second"
hook PostToolUse "$POST"
tmux -S "$s" set-option -g @roost-notify-delay 2

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
# A pane option beats the global one: delay 0 on this pane alone, 2 globally.
tmux -S "$s" set-option -g @roost-notify-delay 2
tmux -S "$s" set-option -p -t "$pane" @roost-notify-delay 0
sleep 1
reset
hook PermissionRequest "$(perm d2)"
assert_eq "$(count)" "1" "a pane's @roost-notify-delay overrides the global one"
hook PostToolUse "$POST"
tmux -S "$s" set-option -pu -t "$pane" @roost-notify-delay

# --- 7. the window came on screen during the wait: no ping ---------------------
# The window must come on screen before the child wakes, two seconds after
# the hook was called; later is a missed setup, as in case 1 (#202).
case_7() {
  reset
  t="$(now)"; hook PermissionRequest "$(perm e1)"
  tmux -S "$s" select-window -t s:agent
  if ! before "$t + 2"; then
    MISS_WHAT="setup: the window came on screen before the child woke"
    MISS_WANT="before"; MISS_GOT="late"
    sleep 3.5
    # As in case 1: a ping before the child woke is wrong whatever the
    # setup did, so it is counted here, after the wait, before the retry's
    # reset erases it (#202).
    assert_eq "$(pings_before "$t + 2")" "0" "a dialog does not ping before its delay, even in a missed setup"
    hook PostToolUse "$POST"
    tmux -S "$s" select-window -t s:other
    return 1
  fi
  sleep 3.5
  assert_eq "$(count)" "0" "a window brought on screen during the delay gets no ping"
  hook PostToolUse "$POST"
  tmux -S "$s" select-window -t s:other
}
sleep 1
retry_once case_7

# --- 8. a bad delay degrades to the default, and the hook never waits ---------
# The child is detached: codex waits on this hook's exit, and the hook's
# caller here is a command substitution, which would also wait on any child
# that kept stdout open. "abc" degrades to the 5 s default, so a hook that
# slept or held the pipe would take 5 s; a detached one returns at once.
tmux -S "$s" set-option -g @roost-notify-delay abc
sleep 1
reset
t8="$(now)"; t0="$(date +%s)"
out="$(hook PermissionRequest "$(perm f1)"; echo "rc=$?")"
t1="$(date +%s)"
assert_eq "$out" "rc=0" "a bad @roost-notify-delay never breaks the hook"
[ $((t1 - t0)) -le 2 ] && assert_eq ok ok "the hook returns before the deferred ping, not after it" \
  || assert_eq "$((t1 - t0)) s" "under 3 s" "the hook returns before the deferred ping, not after it"
sleep 1.5
assert_eq "$(pings_before "$t8 + 5")" "0" "a bad @roost-notify-delay falls back to the default, not to 0"
hook PostToolUse "$POST"

# --- 9. two dialogs in one second: the first's child does not ping the second
# A opens in second S and is approved at once; B opens in the same second, so
# on a whole-second stamp it reads as A. A's child wakes with B open; B is
# answered after that but before B's own child wakes. B was never open for
# the full delay, so nothing pings.
#
# The real times, from the code: each hook starts its child just before it
# returns, and the child sleeps the delay and then checks. A's hook is given
# a 2 s delay and B's a 5 s one (a pane option, read by each hook when it
# runs), so A's child has woken by tb + 2 (tb: B's hook was called; A's hook
# had returned by then) and B's cannot wake before tb + 5. B is answered at
# tb + 3: a second after A's child woke, and two before B's can.
#
# Why two delays (#202). With one delay for both, the two deadlines were only
# as far apart as the two hooks, a few tenths of a second, since both had to
# land in one second; B was answered halfway between, and under a full suite
# the answering hook or B's child slipped past that midpoint and B's own
# child pinged (want [0] got [1]), a ping the code was right to send. No
# delay closes that gap -- it moves both deadlines by the same amount -- but
# a longer delay for B alone opens it to seconds. The case still pins what it
# is about: A's child wakes while B, with A's stamp, is open.
#
# Why a pinned clock (#202). The two stamps used to share a REAL second: A
# was called just past a second boundary and B at S+0.45, so a hook slowed
# past 0.55 s pushed B into the next second (measured: 0.1 to 0.3 s idle; at
# S+0.6 a loaded run missed twice in a row). A miss was retried once, but on
# a machine loaded until each hook took most of a second, the setup missed
# twice in a row in 6 runs of 18 even with B called the moment A was
# answered, and in 11 of 12 under a heavier load. So the hooks of cases 9 to
# 11 read their stamp from the date shim above: every hook in the setup
# stamps FAKE_S, whatever the real clock reads, which is the whole-second
# stamp two dialogs in one real second share. The deferred child sleeps on
# the real clock and reads no stamp of its own. The stamps are still
# compared, and a mismatch is still a missed setup, retried once, but with
# the clock pinned only a stamp written somewhere other than `date +%s`
# could cause one.
#
# The claim record says which child pinged, with no clock: a child that pings
# first writes @roost-notified "<entry> <token>", the entry being
# "<stamp>-<pid>" of the hook that moved the pane to blocked and the token
# that hook's own pid (scripts/roost-agent-state, roost_defer_blocked_ping).
# So each case also asserts whose claim it is, or that nobody claimed.
entry() { tmux -S "$s" show-options -pqv -t "$pane" @roost-block-entry; }
notified() { tmux -S "$s" show-options -pqv -t "$pane" @roost-notified; }
delay_p() { tmux -S "$s" set-option -p -t "$pane" @roost-notify-delay "$1"; }
# two_dialogs TAG WHAT -- the setup cases 9 and 10 share. Sets sa sb ea eb tb
# r0 (r0: the claim record before the case) and pins FAKE_S, which the case
# clears when it is done; on a miss, clears the pane, waits out both children,
# counts any ping too early for either, and returns 1.
two_dialogs() {
  MISS_WHAT="$2"
  r0="$(notified)"
  # An hour back, so the control below cannot pass by the real clock landing
  # on the pinned second, which it does on an idle machine. Stamps are only
  # ever compared for equality, never as numbers, so a past one is safe.
  FAKE_S=$(($(date +%s) - 3600))
  delay_p 2
  ta="$(now)"; hook PermissionRequest "$(perm "${1}1")"; sa="$(since)"; ea="$(entry)"
  hook PostToolUse "$POST"
  delay_p 5
  tb="$(now)"; hook PermissionRequest "$(perm "${1}2")"; sb="$(since)"; eb="$(entry)"
  [ "$sb" = "$sa" ] && return 0
  MISS_WANT="$sa"; MISS_GOT="$sb"
  hook PostToolUse "$POST"
  FAKE_S=""
  at "$tb + 6"
  # A's child cannot wake before ta + 2 and B's before tb + 5, so a ping
  # before ta + 2 is wrong whatever the stamps did. Counted after both
  # children woke, before the retry's reset erases it (#202).
  assert_eq "$(pings_before "$ta + 2")" "0" "a dialog does not ping before its delay, even in a missed setup (two dialogs)"
  return 1
}
case_9() {
  reset
  two_dialogs g "setup: the two dialogs share one whole-second stamp" || return 1
  assert_eq "$sb" "$sa" "$MISS_WHAT"
  # The control for the shim: a hook that read the real clock instead would
  # leave this case racing it again, and green while it won.
  assert_eq "$sa" "$FAKE_S" "setup: the hook stamped the pinned second"
  [ "$eb" != "$ea" ] && assert_eq ok ok "the second dialog is a new entry into blocked" \
    || assert_eq "$eb" "not $ea" "the second dialog is a new entry into blocked"
  at "$tb + 3"
  assert_eq "$(pings_before "$tb + 5")" "0" "a dialog not yet open for the delay is not pinged by the one before it"
  hook PostToolUse "$POST"
  # The answer must land before B's child wakes, at tb + 5 or later. A hook
  # held past that left B open for its full delay, and its ping is right: a
  # missed setup, not a FAIL (#202).
  if ! before "$tb + 5"; then
    MISS_WHAT="setup: the second dialog answered before its own child woke"
    MISS_WANT="before"; MISS_GOT="late"
    FAKE_S=""
    at "$tb + 6.5"
    return 1
  fi
  FAKE_S=""
  # B's child has woken by now (B's hook returned well before tb + 1).
  at "$tb + 6.5"
  assert_eq "$(count)" "0" "two dialogs in one second, both answered inside their delay, ping nothing"
  assert_eq "$(notified)" "$r0" "...and neither child claimed its entry"
}
# Case 8 left the global delay at "abc"; case 12 wants it back at 2.
tmux -S "$s" set-option -g @roost-notify-delay 2
sleep 1
retry_once case_9

# --- 10. the same, but the second dialog stays open: one ping, on ITS deadline
# The count is polled up to tb + 4.5: A's child woke by tb + 2 with B open
# and has had two and a half seconds to ping, and B's own cannot wake before
# tb + 5. Then only the pings stamped before tb + 5 are counted, so a pause
# here between the poll and the read cannot count B's own (#202; a `sleep 1`
# after the poll once did). The ping that follows must be B's own child's
# claim on B's entry.
case_10() {
  reset
  two_dialogs h "setup: the two dialogs share one whole-second stamp (open case)" || return 1
  assert_eq "$sb" "$sa" "$MISS_WHAT"
  count_by 1 "$tb + 4.5"
  assert_eq "$(pings_before "$tb + 5")" "0" "no ping before the open dialog's own deadline"
  until_count 1 5
  at "$tb + 6.5"
  assert_eq "$(count)" "1" "the dialog left open past its own deadline pings exactly once"
  assert_eq "$(notified)" "$eb ${eb##*-}" "...and the claim is the open dialog's own child's"
  hook PostToolUse "$POST"
  FAKE_S=""
}
sleep 1
retry_once case_10

# --- 11. a repeat blocked in the next second still ends in one ping -----------
# The rest of a batch that spans a second boundary: A moves the pane to
# blocked in second S, and a second hook for a second dialog lands in S+1
# while the pane still reads blocked and before A's child wakes. That repeat
# moves @agent_since. The pane has been blocked for the full delay, so one
# ping must come, and only one -- and it comes on A's deadline, not the
# repeat's: the pane has been waiting on the human since A, and a repeat that
# restarted the wait would push every batch's ping back.
#
# The real times, from the code: A stamps FAKE_S and the repeat FAKE_S + 1,
# the pinned clock case 9 explains; before it, A was called just past a real
# second S so a hook up to 0.95 s slow still stamped S (on CI, A called at
# S+0.75 once stamped S+1, the repeat's second), and the repeat at S+1.35. A's
# hook is given a 3 s delay and the repeat's a 6 s one, the way case 9
# separates its two (#202), and the repeat is called the moment A returns:
# it has until ta0 + 3 to come back before A's child wakes, where it once had
# about 0.6 s, and its own child cannot wake before tr + 6 (tr: the repeat
# was called). So the count is read by polling up to tr + 5: A's ping, due
# just after ta0 + 3, has two seconds or more to arrive, and a ping on the
# repeat's deadline is not yet possible; with one 2 s delay for both it had
# about one. The claim record then says it was A's own child that pinged,
# with no clock: the token is the pid in A's entry. If the stamps do not
# differ, or the repeat is not back before ta0 + 3, the setup missed and is
# retried once.
case_11() {
  reset
  delay_p 3
  # An hour back, as in two_dialogs.
  FAKE_S=$(($(date +%s) - 3600))
  ta0="$(now)"; hook PermissionRequest "$(perm i1)"; sa="$(since)"; ea="$(entry)"
  delay_p 6
  FAKE_S=$((FAKE_S + 1))
  tr="$(now)"; hook PermissionRequest "$(perm i2)"; sb="$(since)"; eb="$(entry)"; st="$(pstate)"; tr1="$(now)"
  early="$(python3 -c 'import sys; print(1 if float(sys.argv[1]) < float(sys.argv[2]) + 3 else 0)' "$tr1" "$ta0")"
  if [ "$sb" = "$sa" ] || [ "$early" != 1 ]; then
    MISS_WHAT="setup: the repeat moved the stamp to the next second, before the first child woke"
    MISS_WANT="not $sa, early 1"; MISS_GOT="$sb, early $early"
    hook PostToolUse "$POST"
    FAKE_S=""
    at "$tr1 + 7"
    # A's child cannot wake before ta0 + 3 and the repeat's before tr + 6,
    # so a ping before ta0 + 3 is wrong however the setup missed. Counted
    # after both children woke, before the retry's reset erases it (#202).
    assert_eq "$(pings_before "$ta0 + 3")" "0" "a repeat does not ping before the first delay, even in a missed setup"
    return 1
  fi
  assert_eq "$st" "blocked" "setup: the repeat leaves the pane blocked"
  assert_eq ok ok "setup: the repeat moved the stamp to the next second"
  assert_eq "$sb" "$FAKE_S" "setup: the repeat stamped the pinned second"
  assert_eq "$eb" "$ea" "the repeat keeps the first entry"
  count_by 1 "$tr + 5"
  assert_eq "$(count)" "1" "the ping comes on the first entry's deadline, not the repeat's"
  assert_eq "$(notified)" "$ea ${ea##*-}" "...and the claim is the first hook's own child's"
  # The repeat's child has woken by tr1 + 6; a second ping would be in by now.
  at "$tr1 + 7"
  assert_eq "$(count)" "1" "a batch staggered across a second boundary pings exactly once"
  hook PostToolUse "$POST"
  FAKE_S=""
}
sleep 1
retry_once case_11
# Cases 1 to 8 and 12 use the global delay.
tmux -S "$s" set-option -pu -t "$pane" @roost-notify-delay

# --- 12. a repeat off screen pings when the first dialog opened on screen -----
# The first dialog opens while the human is looking at the window, so it
# starts no child. They switch away, and a second dialog arrives on the pane
# that still reads blocked. That repeat's own child is the only one, and it
# must ping (see the repeat path in scripts/roost-agent-state).
sleep 1
reset
tmux -S "$s" select-window -t s:agent
hook PermissionRequest "$(perm j1)"
tmux -S "$s" select-window -t s:other
hook PermissionRequest "$(perm j2)"
until_count 1 4
sleep 1
assert_eq "$(count)" "1" "a repeat off screen pings when the first dialog opened on screen"
hook PostToolUse "$POST"

canary_leaks="$(find "$CANARY" -mindepth 1 2>/dev/null | sort)"
assert_eq "$canary_leaks" "" "nothing wrote into a home this file did not redirect"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
