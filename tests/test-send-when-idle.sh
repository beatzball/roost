#!/usr/bin/env bash
# tests/test-send-when-idle.sh — `roost send --when-idle` holds a prompt until
# the target stops reading `working`, then sends it the normal way (#56, the
# "Delivery timing" half).
#
# THE GAP. A plain `send` pastes at once. Into a `working` pane the text queues
# in the harness's input line and lands mid-turn: the agent folds it into the
# running turn, `send` can name no turn for it, and a real cross-harness run
# lost a report exactly this way. `--when-idle` is opt-in; the default send is
# unchanged, and case 6 holds it to that.
#
# Badges are set BY HAND on the throwaway server (`set-option -p
# @agent_state`), as the other send tests do, so the timing is the test's and
# not a fixture's. Where a real turn is wanted after the paste, the pane runs
# tests/fixtures/turn-agent.sh, which stamps through roost's real
# scripts/roost-agent-state.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
AGENT="$HERE/tests/fixtures/turn-agent.sh"

# Records are on, for the turn numbers — tests/lib.sh switches them off for
# the suite. HOME and the XDG dirs point at a canary directory the last block
# checks, the way tests/test-send-turn.sh does.
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
badge() { T set-option -p -t "$1" @agent_state "$2"; }
unbadge() { T set-option -p -u -t "$1" @agent_state; }

# newagent WORK -> %N, once its READY marker is on screen. No hook delay: the
# race test-send-turn.sh is about is not this file's question.
newagent() {
  local p n=50
  p="$(T new-window -d -P -F '#{pane_id}' "exec /bin/sh $AGENT $HOOK 0 $1")"
  require_pane "$p" "turn-agent 0/$1"
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$p" 2>/dev/null | grep -q READY && break
    sleep 0.1; n=$((n - 1))
  done
  printf '%s' "$p"
}
# newcat -> %N: a pane that echoes what it is given and stamps nothing.
newcat() {
  local p
  p="$(T new-window -d -P -F '#{pane_id}' 'exec cat')"
  require_pane "$p" "cat"
  sleep 0.3
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
# snd TAG SEND-ARGS... — one send in the background. Its stdout, stderr, exit
# code and wall seconds land in $work/TAG.{out,err,rc,secs}; the caller `wait`s.
snd() {
  local tag="$1"; shift
  ( t0=$(date +%s)
    "$ROOST" send "$@" >"$work/$tag.out" 2>"$work/$tag.err"; echo $? >"$work/$tag.rc"
    echo $(( $(date +%s) - t0 )) >"$work/$tag.secs" ) &
}
# Fields of a send --json document, by python3 (a test dependency already).
jv() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$work/$1.out" "$2" 2>/dev/null; }
lockdir() { printf '%s/roost-send-lock.roost.%s' "$work" "${1#%}"; }
# How many times the agent fixture has replied: the turns it ran.
turns() { ls "$1" 2>/dev/null | grep -c '^[0-9]*$' || true; }

# Detector proof: the fixture runs a turn and records it, so a turn number in
# the cases below means something.
p="$(newagent 0.4)"
"$ROOST" send "$p" "first prompt" >/dev/null 2>&1
wait_state "$p" done
assert_eq "$("$ROOST" read --turn 1 "$p" 2>/dev/null)" "REPLY-TO[first prompt]" \
  "detector proof: the fixture records turn 1"

# --- 1. working, then done after 2 s ----------------------------------------
echo "1. a working target that finishes after two seconds"
badge "$p" working
( sleep 2; badge "$p" done ) &
snd w1 --when-idle --json "$p" "second prompt"
wait
assert_eq "$(cat "$work/w1.rc")" 0 "the held send exits 0"
assert_eq "$(jv w1 'd["turn"], d["started"]')" "(2, True)" "...and names the turn the prompt started: 2"
case "$(jv w1 'd["waited"]')" in
  2|3) assert_true 0 "...and says it waited 2 or 3 seconds" ;;
  *)   assert_true 1 "...and says it waited 2 or 3 seconds (got '$(jv w1 'd["waited"]')')" ;;
esac
wait_state "$p" done
assert_eq "$("$ROOST" read --turn 2 "$p" 2>/dev/null)" "REPLY-TO[second prompt]" \
  "...and turn 2 is the reply to that prompt"
# The human form: the same "%N TURN" line a plain send prints.
badge "$p" working
( sleep 1; badge "$p" done ) &
snd w1h --when-idle "$p" "third prompt"
wait
assert_eq "$(cat "$work/w1h.rc") $(cat "$work/w1h.out")" "0 $p 3" "without --json it prints '%N TURN' as a plain send does"
wait_state "$p" done

# --- 2. working past the bound ----------------------------------------------
echo "2. a target that stays working past the bound"
T set-option -g @roost-send-idle-timeout 2
c="$(newcat)"
badge "$c" working
screen_before="$(T capture-pane -p -t "$c")"
snd w2 --when-idle "$c" "never typed"
wait
assert_eq "$(cat "$work/w2.rc")" 6 "a target still working at the bound: exit 6"
assert_eq "$(cat "$work/w2.out")" "" "...with nothing on stdout"
assert_eq "$(grep -c . "$work/w2.err")" 1 "...and one line on stderr"
assert_contains "$(cat "$work/w2.err")" "$c" "...naming the target"
assert_contains "$(cat "$work/w2.err")" "working" "...the state it still reads"
assert_contains "$(cat "$work/w2.err")" "2s" "...and the bound"
case "$(cat "$work/w2.secs")" in
  2|3|4) assert_true 0 "...after about the bound" ;;
  *)     assert_true 1 "...after about the bound (took $(cat "$work/w2.secs")s)" ;;
esac
assert_eq "$(T capture-pane -p -t "$c")" "$screen_before" "...and the pane's screen is unchanged"
assert_eq "$(T list-buffers -F '#{buffer_name}' 2>/dev/null)" "" "...no roost-send buffer is left"
[ ! -d "$(lockdir "$c")" ]; assert_true $? "...no lock directory is left"
snd w2j --when-idle --json "$c" "never typed either"
wait
assert_eq "$(cat "$work/w2j.rc") [$(cat "$work/w2j.out")]" "6 []" "--json on a timeout: exit 6 and nothing on stdout"
# 0 means do not wait at all: one look, and exit 6 at once.
T set-option -g @roost-send-idle-timeout 0000000
snd w2z --when-idle "$c" "not this either"
wait
assert_eq "$(cat "$work/w2z.rc")" 6 "@roost-send-idle-timeout 0000000 is zero: exit 6"
case "$(cat "$work/w2z.secs")" in
  0|1) assert_true 0 "...at once" ;;
  *)   assert_true 1 "...at once (took $(cat "$work/w2z.secs")s)" ;;
esac
assert_contains "$(cat "$work/w2z.err")" "0s" "...and the message names 0s, not 0000000s"
assert_eq "$(T capture-pane -p -t "$c")" "$screen_before" "...and nothing was typed"
T set-option -g -u @roost-send-idle-timeout

# --- 3. no badge -------------------------------------------------------------
echo "3. a target with no badge"
unbadge "$c"
snd w3 --when-idle --json "$c" "into a plain pane"
wait
assert_eq "$(cat "$work/w3.rc")" 0 "no badge: exit 0"
assert_eq "$(jv w3 'd["waited"]')" 0 "...having waited 0 seconds"
case "$(cat "$work/w3.secs")" in
  0|1|2) assert_true 0 "...at once" ;;
  *)     assert_true 1 "...at once (took $(cat "$work/w3.secs")s)" ;;
esac
assert_contains "$(T capture-pane -p -t "$c")" "into a plain pane" "...and the text landed"

# --- 4. blocked is still refused ---------------------------------------------
echo "4. a blocked target"
b="$(newcat)"
badge "$b" blocked
screen_before="$(T capture-pane -p -t "$b")"
snd w4 --when-idle "$b" "into a dialog"
snd w4p "$b" "into a dialog too"
wait
assert_eq "$(cat "$work/w4.rc") $(cat "$work/w4p.rc")" "3 3" "blocked: exit 3 with --when-idle and without"
assert_eq "$(diff "$work/w4.err" "$work/w4p.err" >/dev/null && echo same)" same "...with the same message"
assert_eq "$(T capture-pane -p -t "$b")" "$screen_before" "...and nothing typed"

# --- 5. two held senders at one busy pane ------------------------------------
echo "5. two --when-idle senders at one working pane"
q="$(newagent 0.5)"
base="$(turns "$ROOST_RECORD_DIR"/*/"${q#%}"/replies)"
badge "$q" working
( sleep 2; badge "$q" done ) &
snd w5a --when-idle "$q" "prompt from A"
snd w5b --when-idle "$q" "prompt from B"
wait
assert_eq "$(cat "$work/w5a.rc") $(cat "$work/w5b.rc")" "0 0" "both held sends exit 0"
ta="$(cut -d' ' -f2 "$work/w5a.out")"; tb="$(cut -d' ' -f2 "$work/w5b.out")"
assert_eq "$(printf '%s\n%s\n' "$ta" "$tb" | sort -n | tr '\n' ' ')" "$((base + 1)) $((base + 2)) " \
  "...each with its own turn number"
wait_state "$q" done
sleep 1
wait_state "$q" done
ra="$("$ROOST" read --turn "$ta" "$q" 2>/dev/null)"
rb="$("$ROOST" read --turn "$tb" "$q" 2>/dev/null)"
assert_eq "$ra|$rb" "REPLY-TO[prompt from A]|REPLY-TO[prompt from B]" "...and each turn is its own sender's prompt"

# --- 6. the default send is unchanged ----------------------------------------
echo "6. without --when-idle, a working target is pasted into at once"
d="$(newcat)"
badge "$d" working
snd w6 "$d" "pasted at once"
wait
assert_eq "$(cat "$work/w6.rc") [$(cat "$work/w6.out")]" "0 []" "exit 0 and no turn number, as before"
case "$(cat "$work/w6.secs")" in
  0|1|2) assert_true 0 "...at once" ;;
  *)     assert_true 1 "...at once (took $(cat "$work/w6.secs")s)" ;;
esac
assert_contains "$(T capture-pane -p -t "$d")" "pasted at once" "...and the text landed"
snd w6j --json "$d" "json at once"
wait
assert_eq "$(jv w6j '"waited" in d')" False "a plain send --json has no waited field"

# --- 7. the bound's parser ---------------------------------------------------
echo "7. the bound's parser"
. "$HERE/scripts/lib/roost-panelock.sh"
idle_t() { roost_panelock_timeout "$1" 300 3600; }
assert_eq "$(idle_t '')" 300 "unset: 300"
assert_eq "$(idle_t abc)" 300 "not digits: 300"
assert_eq "$(idle_t 08)" 8 "08 is eight, not octal"
assert_eq "$(idle_t 0000000)" 0 "0000000 is zero"
assert_eq "$(idle_t 3600)" 3600 "3600 is kept"
assert_eq "$(idle_t 3601)" 3600 "3601 is clamped to 3600"
assert_eq "$(idle_t 00099999)" 3600 "a padded large value is clamped"
assert_eq "$(idle_t "$(printf '9%.0s' $(seq 1 200))")" 3600 "an over-long value is clamped"
assert_eq "$(roost_panelock_timeout '')" 60 "the lock bound's own default is unchanged"
assert_eq "$(roost_panelock_timeout 900)" 600 "the lock bound's own clamp is unchanged"
"$ROOST" help 2>/dev/null | grep -q -- '--when-idle'; assert_true $? "roost help names --when-idle"
"$ROOST" help 2>/dev/null | grep -q -- '@roost-send-idle-timeout'; assert_true $? "roost help names where the bound comes from"

assert_eq "$(find "$work/canary" -type f 2>/dev/null | head -1)" "" "nothing was written under the canary HOME"
