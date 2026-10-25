#!/usr/bin/env bash
# tests/test-send-turn.sh — `roost send` must prove the target began a NEW turn
# (#92), and hand back the turn number that prompt started.
#
# THE BUG, MEASURED before anything here was written (tmux 3.6, macOS 26.3,
# bash 3.2, tests/fixtures/turn-agent.sh):
#
#   turn 1 finished, state=[done], read -> REPLY-TO[first prompt]
#   roost send %1 "second prompt"   exit 0, 731 ms; state right after: [done]
#   roost wait-done %1 30           exit 0 after 35 ms
#   roost read %1                -> REPLY-TO[first prompt]
#
# A well-formed answer to somebody else's question. `send` verifies the SUBMIT
# and stops there, and `wait-done` counts only `working` and `blocked` as busy,
# so the previous turn's `done` satisfies it at once.
#
# HOW WIDE THE WINDOW IS. `roost send` presses Enter about 340 ms before it
# returns (two @roost-send-enter-delay sleeps plus the verification), so a
# harness that stamps `working` inside that cushion never loses. Stale replies
# over 10 runs at a range of prompt-submit-hook latencies:
#
#   0 s 0/10   0.1 s 0/10   0.2 s 0/10   0.3 s 0/10
#   0.4 s 4/10   0.5 s 1/10   1.0 s 4/10   3.0 s 8/10
#
# roost's own hook costs 21.7/22.5/63.2 ms (min/median/max, 10 runs), so almost
# all of a real harness's latency is its own submit handling, which is NOT
# measured here — no real model is started by this file. That is why the fixture
# below takes the latency as a parameter instead of claiming a number for Claude.
#
# So every case that wants the race uses a 2 s hook delay: far enough above the
# cushion to be deterministic, far enough below any sane bound to stay quick.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
AGENT="$HERE/tests/fixtures/turn-agent.sh"

# Records are the turn numbering, so this file turns them on — tests/lib.sh
# switches them off for the suite. HOME and the XDG dirs point at a canary
# directory the last block checks, so a record that ignored ROOST_RECORD_DIR
# fails here instead of landing in the developer's real state directory.
work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"          # a PATH ending in /roost: the hook acts only on those
export ROOST_RECORD_DIR="$work/rec"
export HOME="$work/canary" XDG_CONFIG_HOME="$work/canary/config" \
       XDG_STATE_HOME="$work/canary/state" XDG_DATA_HOME="$work/canary/data"
mkdir -p "$work/canary"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT

tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
export ROOST_SOCKET="$s"
T() { tmux -S "$s" "$@"; }
state() { T display-message -p -t "$1" '#{@agent_state}' 2>/dev/null; }

# newagent DELAY WORK -> %N, once its READY marker is on screen. Waiting for the
# marker rather than sleeping: /bin/sh's cold start is not a fixed cost, and
# typing before the loop reads would test the cold-start race instead of this one.
newagent() {
  local p n=50
  p="$(T new-window -d -P -F '#{pane_id}' "exec /bin/sh $AGENT $HOOK $1 $2")"
  require_pane "$p" "turn-agent $1/$2"
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$p" 2>/dev/null | grep -q READY && break
    sleep 0.1; n=$((n - 1))
  done
  printf '%s' "$p"
}
# wait_state PANE STATE — bounded, and it NEVER short-circuits on the badge the
# race leaves behind: callers use it only to settle a turn they already know
# started.
wait_state() {
  local n=300
  while [ "$n" -gt 0 ]; do
    [ "$(state "$1")" = "$2" ] && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}

# sent_pane / sent_turn — `roost send` prints ONE line, "%N TURN", on a target
# that began a turn. Both fields or neither: a target with no turn to name
# prints nothing at all, and then both of these are empty, which is exactly the
# "you cannot use --turn here" signal a caller has to branch on.
send_into() {   # send_into TARGET TEXT... -> $sent_rc, $sent_pane, $sent_turn
  local out
  out="$("$ROOST" send "$@" 2>/dev/null)"; sent_rc=$?
  sent_pane="" sent_turn=""
  read -r sent_pane sent_turn <<< "$out"
}

# --- detector proof: the fixture really does produce turns ------------------
#
# A probe whose own setup is broken records nothing and reports nothing, which
# is indistinguishable from the bug being hunted. So prove the fixture badges,
# replies and numbers a turn before any assertion below means anything.
p="$(newagent 2 0.4)"
"$ROOST" send "$p" "first prompt" >/dev/null 2>&1
wait_state "$p" done
assert_eq "$(state "$p")" "done" "detector proof: the fixture reaches done"
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "REPLY-TO[first prompt]" \
  "detector proof: the fixture records a real reply"
assert_eq "$("$ROOST" read --turn 1 "$p" 2>/dev/null)" "REPLY-TO[first prompt]" \
  "detector proof: that reply is turn 1"

# --- detector proof: the race is really there -------------------------------
#
# PLANTED BY HAND, through tmux, not through `roost send`. That is the whole
# point: a fixed `send` waits for the turn, so it can no longer show the bug,
# and a "before" written through it would go green for the wrong reason the
# moment the fix landed. What is typed here is exactly what `send` types —
# a bracketed paste and an Enter — and nothing else. If this block stops being
# able to hand back a stale reply, the fixture's delay has fallen inside
# `send`'s own ~340 ms cushion and every case below is measuring that cushion
# rather than a fix.
printf '%s' "second prompt" | T load-buffer -b probe -
T paste-buffer -p -d -b probe -t "$p"
sleep 0.3
T send-keys -t "$p" Enter
assert_eq "$(state "$p")" "done" \
  "detector proof: right after a bare submit, the badge still reads the PREVIOUS turn's done"
"$ROOST" wait-done "$p" 30 >/dev/null 2>&1
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "REPLY-TO[first prompt]" \
  "detector proof: wait-done + read then hand back the PREVIOUS turn's reply"
wait_state "$p" done

# --- and the fix, at the same moment, on the same pane ----------------------
#
# The same prompt through `roost send`. It must NOT come back with the badge
# still reading the finished turn's done.
"$ROOST" send "$p" "third prompt" >/dev/null 2>&1
case "$(state "$p")" in
  done|idle|'') assert_eq "$(state "$p")" "working" \
     "send does not return until the target has left the finished turn's badge" ;;
  *) assert_eq ok ok "send does not return until the target has left the finished turn's badge" ;;
esac
wait_state "$p" done

# --- 1. send hands back the turn its prompt started -------------------------
p="$(newagent 2 0.4)"
"$ROOST" send "$p" "turn one" >/dev/null 2>&1; wait_state "$p" done
send_into "$p" "turn two"
assert_eq "$sent_rc" "0" "send into a healthy agent still exits 0"
assert_eq "$sent_turn" "2" "send prints the turn number its prompt started"
assert_eq "$sent_pane" "$p" "...beside the %N pane that started it"

# --- 2. wait-done --turn N does not return on the OLD turn's done -----------
#
# The same pane, the same moment. Turn 2 is running; turn 1's `done` is what
# plain wait-done would settle for.
"$ROOST" wait-done --turn 2 "$p" 30 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done --turn 2 returns once turn 2 is recorded"
assert_eq "$("$ROOST" read --turn 2 "$p" 2>/dev/null)" "REPLY-TO[turn two]" \
  "read --turn 2 is the reply to THAT prompt"
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "REPLY-TO[turn two]" \
  "...and the pane has really moved on, so plain read agrees"

# --- 3. the whole idiom, in one line, gives the RIGHT reply -----------------
#
# This is the contract the issue asks for: send, wait for the turn that send
# named, read that turn. It must not be able to return an older turn's answer.
p="$(newagent 2 0.4)"
"$ROOST" send "$p" "warm up" >/dev/null 2>&1; wait_state "$p" done
send_into "$p" "the real question"
"$ROOST" wait-done --turn "$sent_turn" "$sent_pane" 30 >/dev/null 2>&1
assert_eq "$("$ROOST" read --turn "$sent_turn" "$sent_pane" 2>/dev/null)" "REPLY-TO[the real question]" \
  "send | wait-done --turn | read --turn returns the reply to THIS prompt"

# --- 4. a submit that never starts a turn gets its own exit code ------------
#
# Exit 4, and not 1: the text WAS delivered and submitted. A caller that reads
# this as 1 and resends would run the prompt twice.
T set-option -g @roost-send-turn-timeout 2
p="$(newagent 30 0.4)"
"$ROOST" send "$p" "warm up" >/dev/null 2>&1
wait_state "$p" done
err="$("$ROOST" send "$p" "never starts" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "4" "a submit that starts no turn inside the bound exits 4"
assert_contains "$err" "never started a turn" "...and says exactly that"
assert_contains "$err" "submitted" "...and says the text WAS submitted, so do not resend"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true

# --- 5. a pane that is not an agent is untouched ----------------------------
#
# A shell helper, a log tail, a pager: no badge, so there is no turn to wait
# for and nothing to report. This must stay as fast and as quiet as it was, or
# `roost send "$logs" ...` in skills/roost/SKILL.md gains a multi-second wait
# and an exit code for a pane that was never going to stamp anything.
T set-option -g @roost-send-turn-timeout 30
sh="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
require_pane "$sh" "plain shell"
sleep 0.5
start="$(date +%s)"
out="$("$ROOST" send "$sh" "printf 'SHELL-%s\n' OK" 2>/dev/null)"; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$rc" "0" "send into a pane with no badge still exits 0"
assert_eq "$out" "" "...prints no turn, because it has none"
[ "$elapsed" -lt 10 ]; assert_true $? "...and does not wait out the bound (${elapsed}s)"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true

# --- 5b. the bound set to 0 turns the watch off entirely ---------------------
#
# The escape hatch for a fleet whose harness stamps nothing. It has to be
# spelled out rather than fall out of the arithmetic: `$((0 * 4))` runs the poll
# loop zero times, which would report exit 4 on EVERY send — a knob that reads
# as "do not wait" and instead breaks the command.
T set-option -g @roost-send-turn-timeout 0
p="$(newagent 2 0.4)"
"$ROOST" send "$p" "warm up" >/dev/null 2>&1; wait_state "$p" done
out="$("$ROOST" send "$p" "no wait wanted" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "@roost-send-turn-timeout 0 turns the watch off: still exit 0"
assert_eq "$out" "" "...and names no pane and no turn, because none was proven"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true
wait_state "$p" done

# --- 6. --json carries the turn --------------------------------------------
p="$(newagent 2 0.4)"
"$ROOST" send "$p" "warm up" >/dev/null 2>&1; wait_state "$p" done
doc="$("$ROOST" send --json "$p" "json prompt" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "send --json exits 0"
assert_contains "$doc" '"schema":1' "send --json carries the schema"
assert_contains "$doc" '"command":"send"' "send --json names the command"
assert_contains "$doc" '"turn":2' "send --json carries the turn it started"
"$ROOST" wait-done --turn 2 "$p" 30 >/dev/null 2>&1
assert_eq "$("$ROOST" read --turn 2 "$p" 2>/dev/null)" "REPLY-TO[json prompt]" \
  "the turn --json named is the one that answers"

# --- 7. wait-done --turn refuses what it cannot answer -----------------------
#
# Turn numbers belong to one pane. A window target aggregates panes, so there is
# no single numbering to wait on, and silently waiting on the active pane would
# be a guess. Refuse instead.
# Both assertions name a string only the fix can print. Checking for "--turn"
# alone passed against the UNFIXED code, which echoed the word back as the
# target it had mistaken it for -- a green line that proved nothing.
out="$("$ROOST" wait-done --turn 2 "main:1" 2>&1)"; rc=$?
assert_eq "$rc" "1" "wait-done --turn against a window target exits 1"
assert_contains "$out" "roost wait-done: --turn needs a %N pane" \
  "...and says why a window target cannot carry a turn number"
out="$("$ROOST" wait-done --turn abc "$p" 2>&1)"; rc=$?
assert_eq "$rc" "1" "wait-done --turn with a non-number exits 1"
assert_contains "$out" "roost wait-done: --turn needs a turn number" \
  "...and says what it wanted instead"

# --- 8. a WINDOW target hands back the %N it resolved to ---------------------
#
# Found by review (flock round 1). `send` resolved a window to its active pane
# and printed that pane's turn number, but `wait-done --turn` refuses anything
# that is not a %N -- so the skill's own idiom ("pass --turn whenever send gave
# you a number") broke on the target form the site docs use throughout:
#
#   roost send api "..."        -> turn=[2]
#   roost wait-done --turn 2 api -> rc=1
#
# Printing the resolved pane beside the turn is what closes it, and it costs a
# field the caller wanted anyway. `send-keys` and `display-message` resolve a
# window target to the SAME active pane, so the id printed is the pane the text
# really went into.
p="$(newagent 2 0.4)"
win="$(T display-message -p -t "$p" '#{session_name}:#{window_index}')"
assert_true $? "setup: the agent's window has a SESSION:INDEX target"
"$ROOST" send "$win" "warm up" >/dev/null 2>&1; wait_state "$p" done
send_into "$win" "window prompt"
assert_eq "$sent_rc" "0" "send into a window target exits 0"
assert_eq "$sent_pane" "$p" "send on a WINDOW target names the %N it resolved to"
assert_eq "$sent_turn" "2" "...and the turn that pane started"
"$ROOST" wait-done --turn "$sent_turn" "$sent_pane" 30 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "the pair send printed can be handed straight to wait-done --turn"
assert_eq "$("$ROOST" read --turn "$sent_turn" "$sent_pane" 2>/dev/null)" "REPLY-TO[window prompt]" \
  "...and to read --turn, for the reply to THAT prompt"
# --json must name the same pane the human line does. Two modes that disagree
# about which pane was written to would be worse than either being wrong alone.
wait_state "$p" done
doc="$("$ROOST" send --json "$win" "window json" 2>/dev/null)"
assert_contains "$doc" "\"pane\":\"$p\"" "send --json on a window target names the resolved %N too"
assert_contains "$doc" '"target":"'"$win"'"' "...and still reports the target as it was typed"
assert_contains "$doc" '"started":true' "...and says a turn really began"
wait_state "$p" done

# --- 9. recording OFF: a turn inside the Enter cushion is still seen ---------
#
# Found by review (flock round 1). `ROOST_RECORD_DIR=""` is a supported setting
# -- tests/lib.sh sets it for the whole suite -- and with it there is no turn
# numbering to watch. A turn that begins AND ends inside `send`'s ~340 ms Enter
# cushion is then invisible to BOTH of the original signals: the badge is back
# to `done` before the first poll, and the record check is skipped. Measured on
# the unfixed code: rc=4 after the whole bound, with the reply sitting on the
# pane the entire time.
#
# The fixture runs with no delay and no work, so its turn is two hook calls
# (about 50 ms) and finishes long before `send` returns. Both the pane and the
# `send` process have recording off, so nothing on disk can rescue this.
T set-option -g @roost-send-turn-timeout 4
p="$(T new-window -d -P -F '#{pane_id}' "exec env ROOST_RECORD_DIR= /bin/sh $AGENT $HOOK 0 0")"
require_pane "$p" "recording-off agent"
n=50
while [ "$n" -gt 0 ]; do
  T capture-pane -p -t "$p" 2>/dev/null | grep -q READY && break
  sleep 0.1; n=$((n - 1))
done
env ROOST_RECORD_DIR="" "$ROOST" send "$p" "warm up" >/dev/null 2>&1
wait_state "$p" done
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "REPLY-TO[warm up]" \
  "detector proof: the recording-off pane still publishes a reply on the pane"
start="$(date +%s)"
out="$(env ROOST_RECORD_DIR="" "$ROOST" send "$p" "fast turn" 2>/dev/null)"; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$rc" "0" "recording off: a turn that finished inside the cushion is NOT reported as never started"
[ "$elapsed" -lt 4 ]; assert_true $? "...and it does not burn the whole bound (${elapsed}s)"
assert_eq "$out" "" "...and no turn is named, because recording off means there are no turn numbers"
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "REPLY-TO[fast turn]" \
  "...and the turn really did run"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true

# --- 10. each record-independent signal, on its own -------------------------
#
# Found by review (flock round 2): signals 3 (@agent_since) and 4 (@roost-reply)
# went in together, and case 9 above passes with EITHER of them short-circuited
# to `if false` — three runs each, all green. A test that cannot tell two
# mechanisms apart is not testing either of them.
#
# So each case below holds ONE of them still, through
# tests/fixtures/turn-agent.sh's PIN mode, and then asserts afterwards that it
# really did not move. Both run with recording off and a turn that finishes
# inside the Enter cushion, so signals 1 and 2 cannot answer either — which
# leaves exactly one.
pin_agent() {   # pin_agent since|reply -> %N, recording off, an instant turn
  local p n=50
  p="$(T new-window -d -P -F '#{pane_id}' "exec env ROOST_RECORD_DIR= /bin/sh $AGENT $HOOK 0 0 $1")"
  require_pane "$p" "pinned agent ($1)"
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$p" 2>/dev/null | grep -q READY && break
    sleep 0.1; n=$((n - 1))
  done
  printf '%s' "$p"
}
opt() { T show-options -pqv -t "$1" "$2" 2>/dev/null; }

T set-option -g @roost-send-turn-timeout 4

# 10a. the stamp is frozen, so ONLY the reply can answer.
p="$(pin_agent since)"
env ROOST_RECORD_DIR="" "$ROOST" send "$p" "warm up" >/dev/null 2>&1
wait_state "$p" done
since_before="$(opt "$p" @agent_since)"
reply_before="$(opt "$p" @roost-reply)"
[ -n "$since_before" ]; assert_true $? "detector proof: the pinned pane has a stamp to freeze"
start="$(date +%s)"
env ROOST_RECORD_DIR="" "$ROOST" send "$p" "only the reply" >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$rc" "0" "stamp frozen: the reply alone is enough to prove a turn began"
[ "$elapsed" -lt 4 ]; assert_true $? "...without burning the bound (${elapsed}s)"
assert_eq "$(opt "$p" @agent_since)" "$since_before" \
  "...and the stamp really was unchanged, so signal 3 could not have answered"
[ "$(opt "$p" @roost-reply)" != "$reply_before" ]; assert_true $? \
  "...while the reply really did change, which is the only signal left"

# 10b. the reply is frozen, so ONLY the stamp can answer.
#
# The turn's own reply is written back, so `read` cannot prove the turn ran
# here. The stamp moving does: nothing else writes @agent_since, and the restore
# that left the reply untouched only runs AFTER the done hook — so the two
# assertions together say the turn completed.
p="$(pin_agent reply)"
env ROOST_RECORD_DIR="" "$ROOST" send "$p" "warm up" >/dev/null 2>&1
wait_state "$p" done
since_before="$(opt "$p" @agent_since)"
reply_before="$(opt "$p" @roost-reply)"
[ -n "$reply_before" ]; assert_true $? "detector proof: the pinned pane has a reply to freeze"
# A whole second, so the stamp this turn writes cannot collide with the last
# one: @agent_since is `date +%s`, and the point of this case is that it MOVED.
sleep 1.2
start="$(date +%s)"
env ROOST_RECORD_DIR="" "$ROOST" send "$p" "only the stamp" >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$rc" "0" "reply frozen: the stamp alone is enough to prove a turn began"
[ "$elapsed" -lt 4 ]; assert_true $? "...without burning the bound (${elapsed}s)"
assert_eq "$(opt "$p" @roost-reply)" "$reply_before" \
  "...and the reply really was unchanged, so signal 4 could not have answered"
[ "$(opt "$p" @agent_since)" != "$since_before" ]; assert_true $? \
  "...while the stamp really did move, which is the only signal left"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true

# --- 11. @roost-send-turn-timeout survives a leading zero -------------------
#
# Both of these were measured on the version without the strip loop, and both
# are worse than the bad value they came from:
#
#   00   every arithmetic context reads it as zero, but the off-switch is a
#        STRING compare — so the watch stayed on with a bound of zero ticks and
#        EVERY send reported exit 4 against a healthy agent.
#   08   a leading zero makes `[ -gt ]` and `$(( ))` read octal, and 08 is not
#        octal. `$(( ))` in the loop header carries no 2>/dev/null and cannot,
#        so under `set -e` it aborted `send` AFTER the text was submitted.
p="$(newagent 2 0.4)"
"$ROOST" send "$p" "warm up" >/dev/null 2>&1; wait_state "$p" done
T set-option -g @roost-send-turn-timeout 00
send_into "$p" "double zero"
assert_eq "$sent_rc" "0" "@roost-send-turn-timeout 00 reads as 0 (off), not as a zero-tick watch"
assert_eq "$sent_turn" "" "...so no turn is claimed, exactly as a plain 0 does"
# `wait_state done` would return AT ONCE here -- the watch was off, so the badge
# is still the previous turn's -- which is the very bug this file is about. Wait
# on the turn instead, which is what `--turn` is for.
"$ROOST" wait-done --turn 2 "$p" 30 >/dev/null 2>&1
T set-option -g @roost-send-turn-timeout 08
send_into "$p" "octal eight"
assert_eq "$sent_rc" "0" "@roost-send-turn-timeout 08 is 8 seconds, not an arithmetic error"
assert_eq "$sent_turn" "3" "...and the send still names the turn it started"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true
wait_state "$p" done

# --- 12. an ERRORED turn starts, but is never numbered ----------------------
#
# Found by review (flock round 2). An errored turn records nothing — the hook
# and every adapter drop the half-built reply, because a failed turn has no
# answer to publish — so a number handed back here could only ever time out
# under `wait-done --turn`. The turn did begin, so this is still exit 0.
p="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
require_pane "$p" "error pane"
sleep 0.3
spid="$(T display -p '#{pid}')"
env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" working </dev/null
printf '{"last_assistant_message":"first answer"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" done --stop-hook
assert_eq "$(state "$p")" "done" "detector proof: the error pane has a finished turn to send into"
assert_eq "$("$ROOST" read --turn 1 "$p" 2>/dev/null)" "first answer" \
  "detector proof: ...and that turn is numbered 1"
# The next thing that happens to this pane is an error, not a turn.
( sleep 1; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" error </dev/null ) &
send_into "$p" "this one errors"
assert_eq "$sent_rc" "0" "a turn that begins and errors is still exit 0"
assert_eq "$sent_turn" "" "...but is NOT numbered, because an errored turn records nothing"
assert_eq "$sent_pane" "" "...and with no turn there is no pane either: both fields or neither"
# The pane is now PARKED at `error`, which is not a state `send` watches at all,
# so a second send there would report started false for an unrelated reason.
# Put it back on a finished turn first, then arrange the same error again, so
# --json is asked the same question the human line was.
env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" working </dev/null
printf '{"last_assistant_message":"second answer"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" done --stop-hook
assert_eq "$(state "$p")" "done" "detector proof: the error pane is back on a finished turn"
( sleep 1; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" error </dev/null ) &
doc="$("$ROOST" send --json "$p" "and again" 2>/dev/null)"
assert_contains "$doc" '"turn":null' "send --json says turn null on a turn that errored"
assert_contains "$doc" '"started":true' "...and started true, because a turn did begin"
wait

# --- 13. who sent it: --from LABEL and the sent_by sidecar (#56) ------------
#
# The label is kept BESIDE the turn, as `replies/NNNNNN.sent_by` in the pane's
# record, and the text pasted into the pane is unchanged: no envelope in this
# cut, so a `send` without the flag is byte-identical to what it was. The
# fixture echoes the prompt back inside its reply, which is what proves that
# second half: an envelope would show up inside REPLY-TO[...].
boot="$(T display -p '#{start_time}-#{pid}')"
side() { printf '%s/%s/%s/replies/%06d.sent_by' "$ROOST_RECORD_DIR" "$boot" "${1#%}" "$2"; }
# Run with neither TMUX nor TMUX_PANE: this file may itself be running inside a
# roost pane, and the default label is decided from exactly those two.
outside() { env -u TMUX -u TMUX_PANE "$@"; }

# 13a. the FIRST prompt of a fresh agent that already wears a badge. No record
# exists yet, and the label must still land. The fixture has no badge until
# its first turn, and neither does a fresh Claude pane (its SessionStart hook
# injects context and stamps nothing), so `send` does not watch either one and
# their first prompt keeps no label — docs/known-gaps.md says so. A harness
# that starts on a badge (opencode 2 at adapter load, codex after an
# interrupt) is the case here, so the badge is stamped by hand through the
# real hook.
p="$(newagent 2 0.4)"
spid="$(T display -p '#{pid}')"
env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" idle </dev/null
assert_eq "$(state "$p")" idle "detector proof: the fresh agent is badged idle before its first prompt"
rec="$ROOST_RECORD_DIR/$boot/${p#%}"
[ ! -d "$rec" ]; assert_true $? "detector proof: a fresh agent has no record yet"
out="$(outside "$ROOST" send --from coord "$p" "first prompt" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$p 1" "send --from on a fresh agent still exits 0 and names turn 1"
[ -f "$(side "$p" 1)" ]; assert_true $? "...and replies/000001.sent_by exists before the turn has even finished"
printf '%s' coord | cmp -s - "$(side "$p" 1)"; assert_true $? "...holding exactly the label, no newline"
assert_eq "$(ls -l "$(side "$p" 1)" | cut -c1-10)" "-rw-------" "...private to the user"
assert_eq "$(ls -ld "$rec" | cut -c1-10)" "drwx------" "...in a record directory send made private, as the hook does"
assert_eq "$(cat "$rec/schema")" 1 "...with the schema file the hook would have written"
assert_eq "$(cat "$rec/socket")" "$s" "...and the socket, so forget --gone can check it later"
"$ROOST" wait-done --turn 1 "$p" 30 >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "wait-done --turn 1 still returns: a sidecar is not a turn"
assert_eq "$("$ROOST" read --turn 1 "$p" 2>/dev/null)" "REPLY-TO[first prompt]" \
  "read --turn 1 reads the turn, and the prompt arrived with no envelope"
assert_eq "$("$ROOST" read --turn -1 "$p" 2>/dev/null)" "REPLY-TO[first prompt]" "...counting back steps over the sidecar"
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "REPLY-TO[first prompt]" "...and plain read agrees"
[ -f "$(side "$p" 1)" ]; assert_true $? "the sidecar survives the turn being recorded beside it"
assert_contains "$("$ROOST" read --json --turn 1 "$p" 2>/dev/null)" '"sent_by":"coord"' \
  "read --json --turn 1 carries the label from the sidecar"
assert_contains "$("$ROOST" read --json "$p" 2>/dev/null)" '"sent_by":"coord"' \
  "...and so does plain read --json while the pane still holds that turn"
assert_eq "$(ls "$rec/replies" | grep -v '\.pane$' | tr '\n' ' ')" "000001 000001.sent_by " \
  "the turn and its .sent_by, and no temp file"

# 13b. without --from, from outside any pane: human.
outside "$ROOST" send "$p" "second prompt" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "a send without --from is unchanged: exit 0"
assert_eq "$(cat "$(side "$p" 2)")" human "...and its sidecar says human when the caller is not in a pane"
"$ROOST" wait-done --turn 2 "$p" 30 >/dev/null 2>&1
assert_contains "$("$ROOST" read --json "$p" 2>/dev/null)" '"sent_by":"human"' "...which read --json then reports"

# 13c. without --from, from a live pane on THIS server: pane:%N.
helper="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
require_pane "$helper" "sending pane"
env TMUX="$s,$spid,0" TMUX_PANE="$helper" "$ROOST" send "$p" "third prompt" >/dev/null 2>&1
assert_eq "$(cat "$(side "$p" 3)")" "pane:$helper" "a send from a live pane on this server is labelled pane:%N"
"$ROOST" wait-done --turn 3 "$p" 30 >/dev/null 2>&1
# A $TMUX_PANE that is not a pane HERE. The user's everyday tmux sets the same
# two variables, and a %N from that server is a stranger's id on this one. A
# pane this server does not have, and a pid that is not this server's, both
# read as human -- never as some other pane.
env TMUX="$s,$spid,0" TMUX_PANE="%999" "$ROOST" send "$p" "fourth prompt" >/dev/null 2>&1
assert_eq "$(cat "$(side "$p" 4)")" human "a TMUX_PANE this server does not have is human"
"$ROOST" wait-done --turn 4 "$p" 30 >/dev/null 2>&1
env TMUX="/nowhere/roost,1,0" TMUX_PANE="$helper" "$ROOST" send "$p" "fifth prompt" >/dev/null 2>&1
assert_eq "$(cat "$(side "$p" 5)")" human "a TMUX naming another server's pid is human, even with a pane id this server has"
"$ROOST" wait-done --turn 5 "$p" 30 >/dev/null 2>&1

# 13d. a label that cannot be kept is refused BEFORE anything is pasted.
wait_state "$p" done
screen_before="$(T capture-pane -p -t "$p")"
n_before="$(ls "$rec/replies" | grep -c 'sent_by$')"
for bad in "two words" "$(printf 'tab\there')" "$(printf 'ctl\001here')" "$(printf '%065d' 0)" "" "--json" "-" "-x"; do
  err="$(outside "$ROOST" send --from "$bad" "$p" "never pasted" 2>&1 >/dev/null)"; rc=$?
  shown="$(printf '%s' "$bad" | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-12)"
  assert_eq "$rc" 2 "a bad label [$shown] is refused with exit 2"
  assert_contains "$err" "--from" "...naming the flag"
done
assert_eq "$(T capture-pane -p -t "$p")" "$screen_before" "...and nothing reached the pane"
assert_eq "$(state "$p")" done "...no turn began"
assert_eq "$(ls "$rec/replies" | grep -c 'sent_by$')" "$n_before" "...and no sidecar was written"
err="$(outside "$ROOST" send --from 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 2 "--from with no label is refused with exit 2"
assert_contains "$err" "--from" "...naming the flag"
# A flag in the label slot is a mistyped flag order, not a sender called
# `--json`: refused, so a program that asked for a document gets exit 2 and
# nothing on stdout, never the human line with a label it did not mean.
out="$(outside "$ROOST" send --from --json "$p" "never pasted" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "2|" "--from --json is an error, not a label named --json, and prints nothing"
assert_eq "$(state "$p")" done "...and starts no turn"
# The two edges that ARE accepted: exactly 64 bytes, and non-ASCII.
label64="$(printf '%064d' 0)"
outside "$ROOST" send --from "$label64" "$p" "sixth prompt" >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(cat "$(side "$p" 6)")" "0|$label64" "a 64-byte label is the longest accepted"
"$ROOST" wait-done --turn 6 "$p" 30 >/dev/null 2>&1
utf="$(printf 'caf\303\251')"
outside "$ROOST" send --from "$utf" "$p" "seventh prompt" >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(cat "$(side "$p" 7)")" "0|$utf" "a UTF-8 label is kept as its bytes"
"$ROOST" wait-done --turn 7 "$p" 30 >/dev/null 2>&1
# A repeated --from is not consumed: it lands in the target slot and fails as
# "no such target", exactly as a repeated --force or --json does.
err="$(outside "$ROOST" send --from a --from b "$p" "x" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 2 "a repeated --from exits 2"
assert_contains "$err" "no such target '--from'" "...as the target it fell through to"

# 13e. --json carries the label, and null when there was no turn to keep it by.
wait_state "$p" done
doc="$(outside "$ROOST" send --json --from coord "$p" "json prompt" 2>/dev/null)"
assert_contains "$doc" '"sent_by":"coord"' "send --json carries sent_by"
assert_contains "$doc" '"turn":8' "...beside the turn it was kept by"
"$ROOST" wait-done --turn 8 "$p" 30 >/dev/null 2>&1
doc="$(outside "$ROOST" send --from coord --json "$p" "json prompt again" 2>/dev/null)"
assert_contains "$doc" '"sent_by":"coord"' "...with the flags in either order"
"$ROOST" wait-done --turn 9 "$p" 30 >/dev/null 2>&1
doc="$(outside "$ROOST" send --json "$p" "json no flag" 2>/dev/null)"
assert_contains "$doc" '"sent_by":"human"' "...and says human when the flag was not given"
"$ROOST" wait-done --turn 10 "$p" 30 >/dev/null 2>&1
doc="$(outside "$ROOST" send --json --from coord "$p" "" 2>/dev/null)"
assert_contains "$doc" '"sent_by":null' "a bare Enter starts no turn, so sent_by is null"
sh="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
require_pane "$sh" "plain shell for --from"
sleep 0.5
doc="$(outside "$ROOST" send --json --from coord "$sh" "printf 'SHELL-%s\n' OK" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "send --from into a pane with no badge still exits 0"
assert_contains "$doc" '"sent_by":null' "...and sent_by is null: no turn, so nowhere to keep it"

# 13f. exit 4 writes nothing: no turn began, so there is no turn to keep it by.
# The slow agent is parked on a finished turn by the hook directly, rather than
# by a warm-up send that would itself exit 4 and then need the whole delay
# waited out.
T set-option -g @roost-send-turn-timeout 2
p4="$(newagent 20 0)"
printf '{"last_assistant_message":"seeded"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p4" "$HOOK" done --stop-hook
assert_eq "$(state "$p4")" done "detector proof: the slow agent is parked on a finished turn"
rec4="$ROOST_RECORD_DIR/$boot/${p4#%}"
assert_file_absent "$rec4/replies/000001.sent_by" "detector proof: a turn the hook recorded on its own has no sidecar"
outside "$ROOST" send --from coord "$p4" "never starts" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 "detector proof: this send exits 4"
assert_eq "$(ls "$rec4/replies" | grep -c 'sent_by$')" 0 "a send that exits 4 writes no sidecar"
assert_file_absent "$(side "$p4" 2)" "...not even for the turn it predicted"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true

# 13g. recording off: the label has nowhere to go, and nothing is written.
poff="$(T new-window -d -P -F '#{pane_id}' "exec env ROOST_RECORD_DIR= /bin/sh $AGENT $HOOK 0 0")"
require_pane "$poff" "recording-off agent for --from"
n=50
while [ "$n" -gt 0 ]; do
  T capture-pane -p -t "$poff" 2>/dev/null | grep -q READY && break
  sleep 0.1; n=$((n - 1))
done
env ROOST_RECORD_DIR="" "$ROOST" send "$poff" "warm up" >/dev/null 2>&1
wait_state "$poff" done
doc="$(outside env ROOST_RECORD_DIR="" "$ROOST" send --json --from coord "$poff" "no record" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "recording off: send --from still exits 0"
assert_contains "$doc" '"started":true' "...and still proves the turn began"
assert_contains "$doc" '"sent_by":null' "...but sent_by is null: there is no turn number to keep it by"
assert_file_absent "$ROOST_RECORD_DIR/$boot/${poff#%}" "...and no record was made for it"

# 13h. an errored turn takes its label with it (flock review, fix loop 1). The
# sequence exactly as the reviewer ran it: a turn that `send --from` started
# and that then ERRORS records no reply, so the number `send` predicted goes
# to the NEXT recorded turn — here a prompt the human typed by hand. Before
# the fix that turn read `sent_by: coord`: a label about a prompt the
# coordinator never sent, and nothing in the document to tell it from a true
# one. The sidecar is dropped where every harness passes on its way into a
# NEW turn — scripts/roost-agent-state, on the stamp of `working` from a
# finished state — and before the badge moves, so a `send` watching that
# badge writes its own label only afterwards.
#
# A slow agent, so the turn `send` starts is still running when the hook is
# told, by hand, that it errored. The fixture's own sleeping turn is killed
# with the pane at the end, before it could record anything.
p5="$(newagent 0 60)"
printf '{"last_assistant_message":"seeded"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" done --stop-hook
assert_eq "$(state "$p5")" done "detector proof: turn 1 is seeded and the agent reads done"
rec5="$ROOST_RECORD_DIR/$boot/${p5#%}"
out="$(outside "$ROOST" send --from coord "$p5" "from the coordinator" 2>/dev/null)"; rc=$?
assert_eq "$rc|$out" "0|$p5 2" "detector proof: send --from names turn 2, the prediction"
assert_eq "$(state "$p5")" working "detector proof: that turn is running"
assert_eq "$(cat "$(side "$p5" 2)")" coord "detector proof: its sidecar says coord"
env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" error --stop-hook </dev/null
assert_eq "$(state "$p5")" error "detector proof: the turn ended as an error"
assert_file_absent "$rec5/replies/000002" "detector proof: and recorded no turn 2"
# The human types a prompt: the harness stamps working, works, and ends done
# with an answer — which becomes turn 2.
env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" working </dev/null
assert_file_absent "$(side "$p5" 2)" "a new turn starting takes the errored turn's label away"
printf '{"last_assistant_message":"typed by the human"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" done --stop-hook
assert_eq "$("$ROOST" read --turn 2 "$p5" 2>/dev/null)" "typed by the human" \
  "detector proof: the hand-typed turn is turn 2"
assert_contains "$("$ROOST" read --json --turn 2 "$p5" 2>/dev/null)" '"sent_by":null' \
  "read --json --turn 2 says nobody known sent it: null, not coord"
assert_contains "$("$ROOST" read --json "$p5" 2>/dev/null)" '"sent_by":null' "...and plain read --json agrees"
assert_eq "$(ls "$rec5/replies" | grep -c 'sent_by$')" 0 "...and no sidecar is left in the record"
# A label that belongs to the turn now starting is kept: the drop runs BEFORE
# the badge moves, and `send` writes only after it has seen it move. The
# fixture is asleep in its own turn, so the working stamp comes by hand, from
# the background, as a harness's prompt-submit hook would. A dialog answered
# in the middle of the turn (blocked, then working again) is not a new turn,
# and keeps the label too.
( sleep 0.5; env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" working </dev/null ) &
out="$(outside "$ROOST" send --from coord "$p5" "again from the coordinator" 2>/dev/null)"; rc=$?
wait
assert_eq "$rc|$out" "0|$p5 3" "detector proof: the next send names turn 3"
assert_eq "$(cat "$(side "$p5" 3)")" coord "...and its label survives the stamp that started it"
env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" blocked </dev/null
env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" working </dev/null
assert_eq "$(cat "$(side "$p5" 3)")" coord "a dialog answered mid-turn is not a new turn: the label stays"
printf '{"last_assistant_message":"answered the coordinator"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" done --stop-hook
assert_contains "$("$ROOST" read --json --turn 3 "$p5" 2>/dev/null)" '"sent_by":"coord"' \
  "...and turn 3 reads coord"
# The other two arms that end a turn unrecorded, through the same drop: an
# interrupt (codex, `idle --stop-hook`) and Claude's StopFailure.
for arm in "idle --stop-hook" "error --stop-failure-hook"; do
  last5="$(ls "$rec5/replies" | grep '^[0-9][0-9]*$' | sort | tail -n 1)"
  next5=$((10#$last5 + 1))
  ( sleep 0.5; env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" working </dev/null ) &
  outside "$ROOST" send --from coord "$p5" "once more" >/dev/null 2>&1
  wait
  [ -f "$(side "$p5" "$next5")" ]; assert_true $? "detector proof ($arm): the send filed a label for turn $next5"
  printf '{"error":"rate_limit"}' | env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" $arm
  env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" working </dev/null
  assert_file_absent "$(side "$p5" "$next5")" "a turn ended by \`$arm\` takes its label with it"
  printf '{"last_assistant_message":"typed by the human again"}' \
    | env TMUX="$s,$spid,0" TMUX_PANE="$p5" "$HOOK" done --stop-hook
  assert_contains "$("$ROOST" read --json "$p5" 2>/dev/null)" '"sent_by":null' "...and the hand-typed turn after it reads null"
done
T kill-pane -t "$p5" 2>/dev/null || true

# 13i. a bare %N is the sender pane:%N, and is kept in that spelling. `roost
# whoami` prints %N and the skill says `--from "$me"`, while the default the
# checked path writes is `pane:%N`; one record must not hold one coordinator
# under two names. Only % followed by digits is folded; anything else is a
# word like any other.
wait_state "$p" done
last="$(ls "$rec/replies" | grep '^[0-9][0-9]*$' | sort | tail -n 1)"
next=$((10#$last + 1))
doc="$(outside "$ROOST" send --json --from "%7" "$p" "bare pane id" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "a bare %N label is accepted"
assert_contains "$doc" '"sent_by":"pane:%7"' "...and kept as pane:%N, the spelling the default uses"
assert_eq "$(cat "$(side "$p" "$next")")" "pane:%7" "...in the sidecar too"
"$ROOST" wait-done --turn "$next" "$p" 30 >/dev/null 2>&1
next=$((next + 1))
outside "$ROOST" send --from "pane:%7" "$p" "spelled pane id" >/dev/null 2>&1
assert_eq "$(cat "$(side "$p" "$next")")" "pane:%7" "pane:%N is already that spelling and is kept as given"
"$ROOST" wait-done --turn "$next" "$p" 30 >/dev/null 2>&1
next=$((next + 1))
outside "$ROOST" send --from "%7x" "$p" "not a pane id" >/dev/null 2>&1
assert_eq "$(cat "$(side "$p" "$next")")" "%7x" "% followed by anything but digits is a word, kept as given"
"$ROOST" wait-done --turn "$next" "$p" 30 >/dev/null 2>&1

# --- 14. no turn number: one stderr line says why (#177) --------------------
#
# Empty stdout with exit 0 has more than one honest cause, and in a real run
# both workers read it as a failed delivery: one wrote "I'm unsure it was
# delivered, though the peer clearly responded". So every path that submits
# the text and names no turn says which cause it was, on stderr, in one line.
# Stdout stays empty — it is the "you cannot use --turn here" signal callers
# branch on — and --json stays as it was, because its started/turn/state fields
# already carry the same facts and a program reading it asked for no prose.
#
# send_both TARGET TEXT... -> $both_rc, $both_out, $both_err
send_both() {
  local errf="$work/send-err"
  both_out="$("$ROOST" send "$@" 2>"$errf")"; both_rc=$?
  both_err="$(cat "$errf")"
}

# 14a. no badge yet: a pane whose first turn has not started.
# HISTFILE empty: this shell is killed below, and on the way out it would
# otherwise save the lines typed into it into the canary HOME.
nb="$(T new-window -d -P -F '#{pane_id}' 'ENV= HISTFILE= exec /bin/sh')"
require_pane "$nb" "no-badge shell"
sleep 0.3
assert_eq "$(state "$nb")" "" "detector proof: the pane has no badge"
send_both "$nb" "echo first"
assert_eq "$both_rc" 0 "no badge: still exit 0"
assert_eq "$both_out" "" "no badge: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$nb' has no badge yet (its first turn has not started)" \
  "no badge: one stderr line says why there is no turn number"
doc="$("$ROOST" send --json "$nb" "echo json" 2>"$work/send-err")"
assert_contains "$doc" '"started":false' "no badge --json: the document is unchanged (started false)"
assert_contains "$doc" '"turn":null' "no badge --json: ...and turn null"
assert_eq "$(cat "$work/send-err")" "" "no badge --json: no prose on stderr"

# 14b. mid-turn: the badge is set by hand, so nothing else can move it.
T set-option -p -t "$nb" @agent_state working
assert_eq "$(state "$nb")" "working" "detector proof: the pane reads working"
send_both "$nb" "echo queued"
assert_eq "$both_rc" 0 "mid-turn: still exit 0"
assert_eq "$both_out" "" "mid-turn: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$nb' is mid-turn; the prompt is queued inside the harness" \
  "mid-turn: one stderr line says the prompt is queued"

# 14c. blocked, sent through with --force: not watched either.
T set-option -p -t "$nb" @agent_state blocked
send_both --force "$nb" "echo forced"
assert_eq "$both_rc" 0 "blocked --force: still exit 0"
assert_eq "$both_out" "" "blocked --force: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$nb' is blocked at a dialog (sent with --force); a turn is watched only from done or idle" \
  "blocked --force: one stderr line says why"
T set-option -p -u -t "$nb" @agent_state
T kill-pane -t "$nb" 2>/dev/null || true

# 14d. recording off: a turn started, and there is nothing to number it by.
T set-option -g @roost-send-turn-timeout 4
ro="$(T new-window -d -P -F '#{pane_id}' "exec env ROOST_RECORD_DIR= /bin/sh $AGENT $HOOK 0 0.3")"
require_pane "$ro" "recording-off agent (14d)"
n=50
while [ "$n" -gt 0 ]; do
  T capture-pane -p -t "$ro" 2>/dev/null | grep -q READY && break
  sleep 0.1; n=$((n - 1))
done
env ROOST_RECORD_DIR="" "$ROOST" send "$ro" "warm up" >/dev/null 2>&1
wait_state "$ro" done
both_out="$(env ROOST_RECORD_DIR="" "$ROOST" send "$ro" "no record" 2>"$work/send-err")"; both_rc=$?
both_err="$(cat "$work/send-err")"
assert_eq "$both_rc" 0 "recording off: still exit 0"
assert_eq "$both_out" "" "recording off: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$ro' started a turn, but recording is off (ROOST_RECORD_DIR is empty or not an absolute path, or there is no state directory), so turns are not numbered" \
  "recording off: one stderr line says turns are not numbered"
wait_state "$ro" done
# A RELATIVE ROOST_RECORD_DIR is refused the same way (roost_record_root
# accepts only an absolute root), so it gets the same line, not a claim that
# the variable is empty.
both_out="$(env ROOST_RECORD_DIR=rec "$ROOST" send "$ro" "relative record dir" 2>"$work/send-err")"; both_rc=$?
both_err="$(cat "$work/send-err")"
assert_eq "$both_rc" 0 "relative ROOST_RECORD_DIR: still exit 0"
assert_eq "$both_out" "" "relative ROOST_RECORD_DIR: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$ro' started a turn, but recording is off (ROOST_RECORD_DIR is empty or not an absolute path, or there is no state directory), so turns are not numbered" \
  "relative ROOST_RECORD_DIR: the same recording-off line, which names that cause too"
assert_file_absent "$PWD/rec" "relative ROOST_RECORD_DIR: nothing was written under the relative path"
wait_state "$ro" done
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true

# 14e. the watch turned off with @roost-send-turn-timeout 0.
T set-option -g @roost-send-turn-timeout 0
send_both "$ro" "unwatched"
assert_eq "$both_rc" 0 "watch off: still exit 0"
assert_eq "$both_out" "" "watch off: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$ro' was not watched (@roost-send-turn-timeout is 0)" \
  "watch off: one stderr line says the watch is off"
T set-option -gu @roost-send-turn-timeout 2>/dev/null || true
wait_state "$ro" done
T kill-pane -t "$ro" 2>/dev/null || true

# 14f. an errored turn: started, and never numbered (see 12).
ep="$(T new-window -d -P -F '#{pane_id}' 'ENV= HISTFILE= exec /bin/sh')"
require_pane "$ep" "error pane (14f)"
sleep 0.3
spid="$(T display -p '#{pid}')"
env TMUX="$s,$spid,0" TMUX_PANE="$ep" "$HOOK" working </dev/null
printf '{"last_assistant_message":"an answer"}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$ep" "$HOOK" done --stop-hook
( sleep 1; env TMUX="$s,$spid,0" TMUX_PANE="$ep" "$HOOK" error </dev/null ) &
send_both "$ep" "this one errors"
wait
assert_eq "$both_rc" 0 "errored turn: still exit 0"
assert_eq "$both_out" "" "errored turn: stdout stays empty"
assert_eq "$both_err" "roost send: no turn number: '$ep' started a turn that ended in error, and an errored turn is not numbered" \
  "errored turn: one stderr line says why"
T kill-pane -t "$ep" 2>/dev/null || true

# 14g. a NUMBERED send stays silent on stderr: the line is only for no number.
# Warmed up first: the fixture has no badge until its first turn (13a).
ok="$(newagent 0 0.3)"
"$ROOST" send "$ok" "warm up" >/dev/null 2>&1
wait_state "$ok" done
send_both "$ok" "numbered"
assert_eq "$both_rc" 0 "numbered send: exit 0"
assert_contains "$both_out" "$ok " "numbered send: stdout names the pane and turn"
assert_eq "$both_err" "" "numbered send: nothing on stderr"
wait_state "$ok" done
T kill-pane -t "$ok" 2>/dev/null || true

# --- 15. a reserved turn number is counted (#188) ---------------------------
#
# A SessionEnd release reserves the number of the turn it ended, in the same
# tmux command as the release, and files it about 70 ms later. A send inside
# that gap must predict the turn AFTER it, and the landing of the reserved
# file must not be taken for this send's turn. The reservation is planted by
# hand, with the `.reserving.*` file that makes the agent's own Stop start
# above it, exactly as the SessionEnd block leaves them.
rp="$(newagent 0 0.3)"
"$ROOST" send "$rp" "turn one" >/dev/null 2>&1
wait_state "$rp" done
rrec="$ROOST_RECORD_DIR/$boot/${rp#%}"
: > "$rrec/replies/.reserving.test"
T set-option -p -t "$rp" @roost-turn-reserved 2
send_into "$rp" "after the reserved one"
assert_eq "$sent_turn" "3" "send predicts the turn after a reserved number, not the reserved number"
wait_state "$rp" done
assert_eq "$("$ROOST" read --turn 3 "$rp" 2>/dev/null)" "REPLY-TO[after the reserved one]" \
  "...and that is the turn the reply is filed as"
[ ! -e "$rrec/replies/000002" ]; assert_true $? "...leaving the reserved number to its owner"
rm -f "$rrec/replies/.reserving.test"
T kill-pane -t "$rp" 2>/dev/null || true

# --- the canary -------------------------------------------------------------
found="$(find "$work/canary" -mindepth 1 2>/dev/null | head -n 3)"
assert_eq "$found" "" "nothing was written into HOME/XDG during this file"
