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

# --- the canary -------------------------------------------------------------
found="$(find "$work/canary" -mindepth 1 2>/dev/null | head -n 3)"
assert_eq "$found" "" "nothing was written into HOME/XDG during this file"
