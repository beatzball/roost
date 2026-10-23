#!/usr/bin/env bash
# tests/test-send-lock.sh — two `roost send`s at once must each deliver their
# own message, whole and on its own, and must not share a turn number (#175).
#
# THE BUG, MEASURED before anything here was written, with the real bin/roost
# on a throwaway server and a TUI that does not echo a paste (tmux 3.5a, bash
# 5 on Linux; tmux 3.5a, bash 3.2 on macOS):
#
#   same pane, 15 trials (Linux):  7 silent losses — both exit 0, one message
#                                  never submitted; 8 loud — one sender exit 1,
#                                  "failed to paste text … (pane may have
#                                  died)" on a healthy pane; 0 clean
#   different panes, 15 (Linux):   15 with one sender failing the same way
#   same pane, 6 trials (macOS):   6 loud, 0 clean
#   different panes, 6 (macOS):    6 with one sender failing
#
# Three causes, one fix each: every send loaded its text into ONE tmux buffer
# named roost-send (now one per process); nothing kept two senders out of one
# input box, so the head-check retry's C-u erased the other sender's paste (now
# a per-pane lock, scripts/lib/roost-panelock.sh); and a re-paste that tmux
# refused was swallowed by `|| true` (now said and stopped on).
#
# The fixture is tests/fixtures/cold-start-tui.py with no startup delay and
# `collapse`: a TUI that does not echo a paste and draws a placeholder for it,
# the shape pi, opencode 2 and Claude Code all have. That shape is what puts
# `send` into its head-check retry loop — C-u, re-paste — which is where one
# sender erased the other's text. @roost-send-ready-timeout is 2 here, not 15:
# enough for exactly one C-u + re-paste per send, which is the dangerous step,
# and it keeps the file quick.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
TUI="$HERE/tests/fixtures/cold-start-tui.py"
AGENT="$HERE/tests/fixtures/turn-agent.sh"

# Records are on, for the turn-number case at the end — tests/lib.sh switches
# them off for the suite. HOME and the XDG dirs point at a canary directory the
# last block checks, the way tests/test-send-turn.sh does.
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

# newtui LINES_FILE -> %N, once its prompt is drawn. Submitted lines go to the
# file, never to the screen, so a test cannot mistake text still sitting in
# the input box for a delivery.
newtui() {
  local p n=50
  p="$(T new-window -d -P -F '#{pane_id}' "exec python3 $TUI 0 $1 0 collapse")"
  require_pane "$p" "collapse tui"
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$p" 2>/dev/null | grep -q 'ready>' && break
    sleep 0.1; n=$((n - 1))
  done
  printf '%s' "$p"
}
# snd TAG SEND-ARGS... — one send in the background. Its stdout, stderr and
# exit code land in $work/TAG.{out,err,rc}; the caller `wait`s.
snd() {
  local tag="$1"; shift
  ( "$ROOST" send "$@" >"$work/$tag.out" 2>"$work/$tag.err"; echo $? >"$work/$tag.rc" ) &
}
# The lock directory for a pane on this server, spelled out rather than asked
# of the library: the NAME is the contract (beside the socket, named for the
# socket and the pane), and a test that derived it from the code under test
# would pass whatever the code did.
lockdir() { printf '%s/roost-send-lock.roost.%s' "$work" "${1#%}"; }
# Non-blank lines only: the fixture writes a line for every Enter, and `send`
# may press more than one.
lines() { grep -c . "$1" 2>/dev/null || true; }

T set-option -g @roost-send-ready-timeout 2

f1="$work/p1.lines"; : >"$f1"; p1="$(newtui "$f1")"
f2="$work/p2.lines"; : >"$f2"; p2="$(newtui "$f2")"

# --- 1. two sends into ONE pane, at once ------------------------------------
# Three trials, not one: the broken code lost one message in 7 of 15 trials
# and failed loudly in the other 8, so a single trial could pass it by luck.
echo "1. two concurrent sends to the same pane"
for i in 1 2 3; do
  : >"$f1"
  snd a "$p1" "AAAA$i from sender A"
  snd b "$p1" "BBBB$i from sender B"
  wait
  sleep 0.5
  assert_eq "$(cat "$work/a.rc") $(cat "$work/b.rc")" "0 0" "trial $i: both sends exit 0"
  assert_eq "$(grep -c "^AAAA$i from sender A\$" "$f1")" 1 "trial $i: A's message arrived whole, on a line of its own"
  assert_eq "$(grep -c "^BBBB$i from sender B\$" "$f1")" 1 "trial $i: B's message arrived whole, on a line of its own"
  assert_eq "$(lines "$f1")" 2 "trial $i: two submissions — not one merged, not one lost"
done

# --- 2. two sends into DIFFERENT panes, at once -----------------------------
# The shared buffer alone broke this one: the second paste found "no buffer"
# and a healthy pane was reported as dead, 15 times out of 15.
echo "2. two concurrent sends to different panes"
for i in 1 2; do
  : >"$f1"; : >"$f2"
  snd c "$p1" "CCCC$i to pane one"
  snd d "$p2" "DDDD$i to pane two"
  wait
  sleep 0.5
  assert_eq "$(cat "$work/c.rc") $(cat "$work/d.rc")" "0 0" "trial $i: both sends exit 0"
  assert_eq "$(grep -c "^CCCC$i to pane one\$" "$f1")" 1 "trial $i: pane one got its message"
  assert_eq "$(grep -c "^DDDD$i to pane two\$" "$f2")" 1 "trial $i: pane two got its message"
  assert_eq "$(grep -c DDDD "$f1")$(grep -c CCCC "$f2")" "00" "trial $i: nothing crossed over"
done

# --- 3. nothing is left behind ----------------------------------------------
assert_eq "$(T list-buffers -F '#{buffer_name}' 2>/dev/null)" "" "no roost-send buffer is left on the server"
[ ! -d "$(lockdir "$p1")" ] && [ ! -d "$(lockdir "$p2")" ]; assert_true $? "no lock directory is left beside the socket"

# --- 4. a lock whose holder is gone is taken over ---------------------------
echo "4. stale and live locks"
lock="$(lockdir "$p1")"
mkdir "$lock"
sh -c 'echo $$' >"$lock/pid"           # a pid that has already exited
: >"$f1"
"$ROOST" send "$p1" "after a dead holder" >/dev/null 2>"$work/e.err"; rc=$?
assert_eq "$rc" 0 "a lock whose holder is gone is taken over: exit 0"
assert_eq "$(grep -c 'after a dead holder' "$f1")" 1 "...and the message is delivered"
[ ! -d "$lock" ]; assert_true $? "...and the lock is gone afterwards"

# --- 5. a lock held by a LIVE roost is waited on, then refused --------------
# Exit 1 is the documented "nothing was submitted, retry the same target" code,
# and it is exactly true here: not one byte was typed. The holder is a bash
# whose $0 is "roost-fake-holder", so `ps -o args=` mentions roost the way a
# real `bash .../bin/roost send` does — the staleness check asks that. Two
# commands, not one: bash execs a lone `-c` command in place, and the holder
# would then BE `sleep 60`, with no roost in its args (measured: the first
# version of this case saw its holder taken over).
bash -c 'sleep 60; true' roost-fake-holder & holder=$!
mkdir "$lock"
printf '%s\n' "$holder" >"$lock/pid"
T set-option -g @roost-send-lock-timeout 1
: >"$f1"
err="$("$ROOST" send "$p1" "while another send holds the pane" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 1 "a lock held by a live roost: exit 1 after the bound"
assert_contains "$err" "still in progress" "...and the message says another send is in progress"
assert_contains "$err" "nothing was submitted" "...and that nothing was submitted"
assert_eq "$(lines "$f1")" 0 "...and nothing reached the pane"
[ -d "$lock" ]; assert_true $? "...and the live holder's lock was not stolen"

# A timeout with a leading zero is read as a human reads it, not as octal:
# `$((08 * 10))` aborts bash 3.2 and 5 alike ("value too great for base"),
# which under `set -e` would end the send with no message at all.
T set-option -g @roost-send-lock-timeout 08
err="$("$ROOST" send "$p1" "while another send holds the pane" 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" 1 "@roost-send-lock-timeout 08 waits eight seconds and exits 1"
assert_contains "$err" "after 8s" "...and reports the bound it waited"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -rf "$lock"
T set-option -gu @roost-send-lock-timeout 2>/dev/null || true

# --- 5b. a pid that was handed to a stranger does not hold the lock ----------
# A killed sender's pid can be reused by a long-lived process that is not
# roost; without the `ps` clause every later send to the pane would wait the
# whole bound and fail for as long as that process lived.
sleep 60 & stranger=$!
mkdir "$lock"
printf '%s\n' "$stranger" >"$lock/pid"
: >"$f1"
"$ROOST" send "$p1" "after a stranger took the pid" >/dev/null 2>"$work/e.err"; rc=$?
assert_eq "$rc" 0 "a lock whose pid now belongs to a non-roost process is taken over: exit 0"
assert_eq "$(grep -c 'after a stranger took the pid' "$f1")" 1 "...and the message is delivered"
[ ! -d "$lock" ]; assert_true $? "...and the lock is gone afterwards"
kill "$stranger" 2>/dev/null; wait "$stranger" 2>/dev/null

# --- 5c. a send killed midway drops its lock and types nothing more ----------
# SIGTERM lands during the head-check sleep, after the paste and before any
# Enter. The handler must EXIT, not clean up and carry on: a send that went on
# to C-u, paste and Enter after dropping its lock would be typing beside
# whoever took the lock next. Bash runs the trap once the foreground sleep
# returns, so the kill is sent early and the exit is collected with wait.
: >"$f1"
"$ROOST" send "$p1" "killed midway" >/dev/null 2>&1 & victim=$!
sleep 0.7
kill -TERM "$victim" 2>/dev/null
wait "$victim" 2>/dev/null; rc=$?
assert_eq "$rc" 143 "a send that takes SIGTERM exits 143"
assert_eq "$(lines "$f1")" 0 "...and submits nothing"
[ ! -d "$lock" ]; assert_true $? "...and its lock is gone"
assert_eq "$(T list-buffers -F '#{buffer_name}' 2>/dev/null)" "" "...and its buffer is gone"
T send-keys -t "$p1" C-u 2>/dev/null   # clear what the killed send left in the input box

# --- 6. two sends racing an IDLE agent do not share a turn number -----------
# Seen live: two senders both watched the badge leave `idle`, both printed
# `%N 1`, and the second overwrote the first's sent_by sidecar. With the lock
# held through the turn watch, the second sender gets in once the first turn
# is under way. Usually that is while the agent is still `working` (it works
# for 2 s), so the second hands back no number — the honest answer for a
# prompt that is queued inside the harness. On a loaded runner the second
# sender can get in after the first turn has finished, see `done`, and be
# handed turn 3 — also correct. What must never happen is the SAME number
# twice, or a sidecar that names the wrong sender, so that is what is
# asserted, not the schedule (found by review).
echo "6. turn numbers under a race"
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
wait_state() {
  local n=300
  while [ "$n" -gt 0 ]; do
    [ "$(state "$1")" = "$2" ] && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}
# turnfile N — the recorded turn N (or its sidecar) of the one agent in this block
turnfile() { find "$ROOST_RECORD_DIR" -path "*/replies/$1" 2>/dev/null | head -n 1; }
wait_turn() {
  local n=300
  while [ "$n" -gt 0 ]; do
    [ -n "$(turnfile "$1")" ] && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}
p="$(newagent 0 2)"                   # stamps working at once, works for 2 s
"$ROOST" send "$p" "warm up" >/dev/null 2>&1
wait_state "$p" done                  # turn 1 is recorded; the badge is done
snd x --from alpha "$p" "second prompt"
snd y --from beta "$p" "third prompt"
wait
ox="$(cat "$work/x.out")"; oy="$(cat "$work/y.out")"
assert_eq "$(cat "$work/x.rc") $(cat "$work/y.rc")" "0 0" "both racing sends exit 0"
case "$ox|$oy" in
  "$p 2|"|"|$p 2"|"$p 2|$p 3"|"$p 3|$p 2")
    assert_true 0 "one sender was handed turn 2 and the other no number or turn 3, never the same number (got [$ox] and [$oy])" ;;
  *)
    assert_true 1 "one sender was handed turn 2 and the other no number or turn 3, never the same number (got [$ox] and [$oy])" ;;
esac
wait_turn 000003; assert_true $? "both prompts ran: turn 3 is recorded"
if [ "$ox" = "$p 2" ]; then winner=alpha; loser=beta; other="$oy"; else winner=beta; loser=alpha; other="$ox"; fi
assert_eq "$(cat "$(turnfile 000002.sent_by)" 2>/dev/null)" "$winner" "turn 2's sent_by names the sender that was handed the number, not the last writer"
if [ "$other" = "$p 3" ]; then
  assert_eq "$(cat "$(turnfile 000003.sent_by)" 2>/dev/null)" "$loser" "turn 3's sent_by names the sender that was handed 3"
else
  assert_eq "$(turnfile 000003.sent_by)" "" "the numberless sender filed no sidecar"
fi

# --- the canary -------------------------------------------------------------
found="$(find "$work/canary" -mindepth 1 2>/dev/null | head -n 3)"
assert_eq "$found" "" "nothing was written into HOME/XDG during this file"
