#!/usr/bin/env bash
# `roost events`: one JSON line per state change, read back with cursors (#98).
#
# Every line here is written by the REAL hook, scripts/roost-agent-state, driven
# with the payloads Claude Code sends, except in the two blocks that need many
# writers at once: those call the lib's writer directly, because the property
# under test is the append, not the hook.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
LIB="$HERE/scripts/lib/roost-events.sh"

# Everything under one throwaway directory. HOME and XDG_STATE_HOME point at
# canaries nothing may write to: the last block checks them, so a log that
# ignored ROOST_RECORD_DIR and fell through to the default path fails here
# instead of landing in the developer's real state directory.
work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"
REC="$work/rec"
export ROOST_RECORD_DIR="$REC"
unset ROOST_EVENTS ROOST_EVENTS_KEEP
export HOME="$work/home" XDG_STATE_HOME="$work/xdg-state" XDG_CONFIG_HOME="$work/xdg-config"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
follow_pid=""
cleanup() {
  [ -n "$follow_pid" ] && kill "$follow_pid" 2>/dev/null
  tmux -S "$s" kill-server 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# roost-agent-state acts only on a socket path ending in /roost, and bin/roost
# takes its socket from $ROOST_SOCKET — tests/test-reply-record.sh's shape.
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
boot="$(tmux -S "$s" display -p '#{start_time}-#{pid}')"
export ROOST_SOCKET="$s"

new_pane() { tmux -S "$s" new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
as_pane() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$@"; }
# hook PANE STATE [FLAG] [PAYLOAD] — one hook call, stdin the payload (or none).
hook() {
  local p="$1" st="$2" flag="${3:-}" payload="${4:-}"
  printf '%s' "$payload" > "$work/payload"
  if [ -n "$flag" ]; then
    as_pane "$p" "$HOOK" "$st" "$flag" < "$work/payload"
  else
    as_pane "$p" "$HOOK" "$st" < "$work/payload"
  fi
}
EVDIR="$REC/events"

# fields — one "event|from|to|turn|reason" row per JSON line on stdin. A line
# that is not JSON prints BAD, so a torn line cannot pass as a missing one.
fields() {
  python3 -c '
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
    except Exception:
        print("BAD"); continue
    f = lambda k: "null" if d.get(k) is None else str(d.get(k))
    print("|".join([f("event"), f("from"), f("to"), f("turn"), f("reason")]))'
}
# field KEY — the value of KEY on each JSON line on stdin.
field() {
  python3 -c '
import sys, json
for line in sys.stdin:
    v = json.loads(line).get(sys.argv[1], "MISSING")
    print("null" if v is None else v)' "$1"
}

# --- 1. a pane through working, blocked, done and error ----------------------

p1="$(new_pane)"; require_pane "$p1" "p1"
w1="$(tmux -S "$s" display -p -t "$p1" '#{window_id}')"
PR_NPM='{"tool_name":"Bash","tool_input":{"command":"npm test"},"transcript_path":"/tmp/t1.jsonl"}'
PR_RM='{"tool_name":"Bash","tool_input":{"command":"rm -rf build"},"transcript_path":"/tmp/t1.jsonl"}'
NOTE='{"notification_type":"permission_prompt","transcript_path":"/tmp/t1.jsonl"}'

hook "$p1" working
hook "$p1" working --tool-hook '{}'                     # PostToolUse, state unchanged
hook "$p1" blocked --permission-request-hook "$PR_NPM"
hook "$p1" blocked --notification-hook "$NOTE"          # the same dialog, six seconds on
hook "$p1" blocked --permission-request-hook "$PR_RM"   # a second dialog, still blocked
hook "$p1" blocked --permission-request-hook "$PR_RM"   # the same one again
hook "$p1" working --tool-hook '{}'
hook "$p1" done --stop-hook '{"last_assistant_message":"SECRET-REPLY-TEXT"}'
hook "$p1" working
hook "$p1" error --stop-failure-hook '{"error":"rate_limit"}'

"$ROOST" events --pane "$p1" > "$work/all" 2> "$work/err"; rc=$?
assert_eq "$rc" 0 "roost events exits 0"
assert_eq "$(cat "$work/err")" "" "...with nothing on stderr"
want="state|null|working|1|
state|working|blocked|1|Bash: npm test
blocked_on|blocked|blocked|1|Bash: rm -rf build
state|blocked|working|1|
state|working|done|1|
state|done|working|2|
state|working|error|2|Claude ended the turn on an API error (rate_limit)"
assert_eq "$(fields < "$work/all")" "$want" \
  "working, blocked, a new dialog, done and error read back as exactly those lines, in order"

assert_eq "$(field schema < "$work/all" | sort -u)" "1" "every line carries schema 1"
assert_eq "$(field server < "$work/all" | sort -u)" "$boot" "every line names its server by boot key"
assert_eq "$(field pane < "$work/all" | sort -u)" "$p1" "every line names its pane"
assert_eq "$(field window < "$work/all" | sort -u)" "$w1" "every line names its window"
assert_eq "$(field session_id < "$work/all" | sort -u)" "null" "session_id is null when @roost-session is not set"
now="$(date +%s)"
bad_ts="$(field ts < "$work/all" | awk -v n="$now" '$0 !~ /^[0-9]+$/ || $0 > n || $0 < n - 120' | head -1)"
assert_eq "$bad_ts" "" "ts is epoch seconds, and recent"
cursors="$(field cursor < "$work/all")"
bad_cur="$(printf '%s\n' "$cursors" | grep -v '^[0-9][0-9]*-[0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*$' || true)"
assert_eq "$bad_cur" "" "every line carries a cursor"
assert_eq "$(printf '%s\n' "$cursors" | sort -u | wc -l | tr -d ' ')" "7" "...and no two lines share one"

# Privacy: the reply went into the Stop payload and must not reach the log.
grep -rq 'SECRET-REPLY-TEXT' "$EVDIR"; assert_eq "$?" 1 "no reply text is written to the log"
# The files are the user's alone, as the kept replies are.
case "$(ls -ld "$EVDIR" | cut -c1-10)" in drwx------) r=0 ;; *) r=1 ;; esac
assert_true "$r" "the log directory is 0700"
bad_mode="$(ls -l "$EVDIR" | awk 'NR > 1 && substr($1,1,10) != "-rw-------"')"
assert_eq "$bad_mode" "" "every log file is 0600"

# --- 2. cursors resume ---------------------------------------------------------

i=0; resume_ok=0
while IFS= read -r c; do
  i=$((i + 1))
  "$ROOST" events --pane "$p1" --since "$c" > "$work/rest"; rc=$?
  tail -n +"$((i + 1))" "$work/all" > "$work/want"
  if [ "$rc" = 0 ] && cmp -s "$work/rest" "$work/want"; then resume_ok=$((resume_ok + 1)); fi
done <<EOF
$cursors
EOF
assert_eq "$resume_ok" "7" "--since each line's cursor prints exactly the lines after it"
last="$(printf '%s\n' "$cursors" | tail -n 1)"
hook "$p1" working
"$ROOST" events --pane "$p1" --since "$last" | fields > "$work/new"
# Turn 2 errored and recorded nothing, so the next turn is numbered 2 again:
# the number `roost send` would print for it.
assert_eq "$(cat "$work/new")" "state|error|working|2|" "a line written after the cursor is the one --since prints"

# --- 3. filters, sessions, and what writes nothing -----------------------------

p2="$(new_pane)"; require_pane "$p2" "p2"
tmux -S "$s" set-option -p -t "$p2" @roost-session "0b7d4c52-9a1e-4c1a-8f5e-2d3c4b5a6f70"
hook "$p2" working
assert_eq "$("$ROOST" events --pane "$p2" | field session_id)" "0b7d4c52-9a1e-4c1a-8f5e-2d3c4b5a6f70" \
  "session_id is read from @roost-session when it is set"
assert_eq "$("$ROOST" events --pane "$p1" | field pane | sort -u)" "$p1" "--pane keeps only that pane's lines"
assert_eq "$("$ROOST" events | field pane | sort -u)" "$(printf '%s\n%s\n' "$p1" "$p2" | sort)" "no --pane prints every pane"

n_before="$(cat "$EVDIR"/[0-9]* | wc -l | tr -d ' ')"
hook "$p2" working --tool-hook '{}'
hook "$p2" working
n_after="$(cat "$EVDIR"/[0-9]* | wc -l | tr -d ' ')"
assert_eq "$n_after" "$n_before" "a hook call that changes no state writes no line"

# A Stop that lands while a dialog is open is swallowed (#91): the badge stays
# blocked, so no line may say it moved.
p3="$(new_pane)"; require_pane "$p3" "p3"
hook "$p3" working
hook "$p3" blocked --permission-request-hook "$PR_NPM"
hook "$p3" done --stop-hook '{"last_assistant_message":"x"}'
assert_eq "$(tmux -S "$s" show-options -pqv -t "$p3" @agent_state)" "blocked" "(setup) the Stop was held back"
assert_eq "$("$ROOST" events --pane "$p3" | fields | tail -n 1)" "state|working|blocked|1|Bash: npm test" \
  "a Stop held back under an open dialog writes no line"

# A tab in a free-text option must not cost the line: ROOST_ERROR_REASON is
# process env and @roost-session is an option anyone can set, and either
# holding a tab once dropped the whole line. The line is written with reason ""
# and session_id null instead.
p6="$(new_pane)"; require_pane "$p6" "p6"
hook "$p6" working
ROOST_ERROR_REASON="$(printf 'a\tb')" hook "$p6" error
assert_eq "$(tmux -S "$s" show-options -pqv -t "$p6" @agent_state)" "error" "(setup) the tab reason was stored"
assert_eq "$("$ROOST" events --pane "$p6" | fields | tail -n 1)" "state|working|error|1|" \
  "a tab in the error reason still writes the line, with reason \"\""
tmux -S "$s" set-option -p -t "$p6" @roost-session "$(printf 'bad\tvalue')"
hook "$p6" working
assert_eq "$("$ROOST" events --pane "$p6" | fields | tail -n 1)" "state|error|working|1|" \
  "a tab in @roost-session still writes the line"
assert_eq "$("$ROOST" events --pane "$p6" | field session_id | tail -n 1)" "null" "...with session_id null"

# --- 4. the off switch -----------------------------------------------------------

p4="$(new_pane)"; require_pane "$p4" "p4"
n_before="$(cat "$EVDIR"/[0-9]* | wc -l | tr -d ' ')"
ROOST_EVENTS="" hook "$p4" working
n_after="$(cat "$EVDIR"/[0-9]* | wc -l | tr -d ' ')"
assert_eq "$n_after" "$n_before" "ROOST_EVENTS=\"\" writes nothing"
ROOST_EVENTS="" "$ROOST" events > "$work/out" 2> "$work/err"; rc=$?
assert_eq "$rc" 1 "roost events with the log off exits 1"
assert_contains "$(cat "$work/err")" "off" "...and says the log is off"
ROOST_RECORD_DIR="" hook "$p4" idle
n_after="$(cat "$EVDIR"/[0-9]* | wc -l | tr -d ' ')"
assert_eq "$n_after" "$n_before" "with kept replies off (ROOST_RECORD_DIR=\"\"), nothing is written either"
alt="$work/alt-events"
ROOST_EVENTS="$alt" hook "$p4" working
assert_eq "$(ROOST_EVENTS="$alt" "$ROOST" events | fields)" "state|idle|working|1|" \
  "ROOST_EVENTS=/path moves the log there"
# ROOST_EVENTS wins outright: with kept replies off it still names a log, and
# there is no turn numbering to give.
alt2="$work/alt2-events"
ROOST_RECORD_DIR="" ROOST_EVENTS="$alt2" hook "$p4" idle
assert_eq "$(ROOST_RECORD_DIR="" ROOST_EVENTS="$alt2" "$ROOST" events | fields)" "state|working|idle|null|" \
  "ROOST_EVENTS=/path writes a log even with kept replies off, with turn null"

# --- 5. rotation, and a cursor that has been rotated away ------------------------

rot="$work/rot"
# roost_events_write LINE through the lib, as the hook does.
write_line() { ROOST_EVENTS="$rot" ROOST_EVENTS_KEEP="${2:-8}" bash -c '. "$1"; roost_events_write "$2"' _ "$LIB" "$1"; }
line_n() { printf '{"schema":1,"ts":1,"server":"%s","pane":"%%9","window":"@9","session_id":null,"event":"state","from":null,"to":"working","turn":%s,"reason":""}' "$boot" "$1"; }
write_line "$(line_n 1)"
first="$(ROOST_EVENTS="$rot" "$ROOST" events | field cursor)"
k=2; while [ "$k" -le 30 ]; do write_line "$(line_n "$k")"; k=$((k + 1)); done
kept="$(ROOST_EVENTS="$rot" "$ROOST" events | field turn)"
nk="$(printf '%s\n' "$kept" | wc -l | tr -d ' ')"
[ "$nk" -ge 8 ] && [ "$nk" -le 10 ]; assert_true $? "ROOST_EVENTS_KEEP=8 keeps the newest 8 to 10 lines (kept $nk)"
assert_eq "$(printf '%s\n' "$kept" | tail -n 1)" "30" "...ending with the newest"
assert_eq "$(printf '%s\n' "$kept" | awk 'NR > 1 && $0 != p + 1 {print "gap"} {p = $0}')" "" "...with no gap"
nseg="$(ls "$rot" | grep -c '^[0-9][0-9]*$')"
[ "$nseg" -le 5 ]; assert_true $? "the log is bounded: at most five segment files ($nseg)"
ROOST_EVENTS="$rot" "$ROOST" events --since "$first" > "$work/out" 2> "$work/err"; rc=$?
assert_eq "$rc" 3 "a cursor that has been rotated away exits 3"
assert_eq "$(cat "$work/out")" "" "...printing nothing on stdout"
assert_eq "$(wc -l < "$work/err" | tr -d ' ')" "1" "...and one line on stderr"
assert_contains "$(cat "$work/err")" "rotated" "...that says why"
ROOST_EVENTS="$rot" "$ROOST" events --since "not-a-cursor" > /dev/null 2>&1; rc=$?
assert_eq "$rc" 1 "a --since that is not a cursor at all is a usage error, exit 1"

# --- 6. two hundred writers at once ----------------------------------------------

# Lines of 454 bytes, near the 512-byte PIPE_BUF this machine reports, so a
# torn append would show as a line that does not parse.
pad="$(printf '%0300d' 0)"
many() {
  local dir="$1" keep="$2" k=1
  while [ "$k" -le 200 ]; do
    ROOST_EVENTS="$dir" ROOST_EVENTS_KEEP="$keep" bash -c '. "$1"; roost_events_write "$2"' _ "$LIB" \
      "$(printf '{"schema":1,"ts":1,"server":"%s","pane":"%%9","window":"@9","session_id":null,"event":"state","from":null,"to":"working","turn":%s,"reason":"%s"}' "$boot" "$k" "$pad")" &
    k=$((k + 1))
  done
  wait
}
check_many() {
  local dir="$1" label="$2" got
  got="$(cat "$dir"/[0-9]* | python3 -c '
import sys, json
seen = []
bad = 0
for line in sys.stdin:
    try:
        seen.append(json.loads(line)["turn"])
    except Exception:
        bad += 1
print(len(seen), len(set(seen)), bad, sorted(seen) == list(range(1, 201)))')"
  assert_eq "$got" "200 200 0 True" "$label: 200 lines, 200 distinct, none torn, none lost"
}
many "$work/many" 100000
check_many "$work/many" "200 writers at once"
many "$work/many-rot" 200
nseg="$(ls "$work/many-rot" | grep -c '^[0-9][0-9]*$')"
[ "$nseg" -ge 3 ]; assert_true $? "(setup) the second run rotated during the race ($nseg segments)"
check_many "$work/many-rot" "200 writers racing four rotations"

# --- 7. forget --all clears the log ------------------------------------------------

# forget --all removes a log, never a directory that merely looks like one. A
# directory with no gen file was never written by roost, whatever it holds.
foreign="$work/foreign"; mkdir -p "$foreign"
for f in 20260930 7 .tmp.someone-elses notes.txt; do printf 'keep\n' > "$foreign/$f"; done
ROOST_RECORD_DIR="$work/other-rec" ROOST_EVENTS="$foreign" "$ROOST" forget --all > "$work/out" 2>&1
assert_eq "$(ls -A "$foreign" | sort | tr '\n' ' ')" ".tmp.someone-elses 20260930 7 notes.txt " \
  "forget --all with ROOST_EVENTS at a directory that is not a log removes nothing in it"
case "$(cat "$work/out")" in *"event log"*) r=1 ;; *) r=0 ;; esac
assert_true "$r" "...and does not say it cleared an event log"

old="$("$ROOST" events | field cursor | tail -n 1)"
"$ROOST" forget --all > "$work/out" 2>&1; rc=$?
assert_eq "$rc" 0 "forget --all exits 0"
assert_contains "$(cat "$work/out")" "event log" "...and says it cleared the event log"
left="$(ls "$EVDIR" 2>/dev/null | grep -c '^[0-9][0-9]*$')"
assert_eq "$left" "0" "...and no segment of it is left"
"$ROOST" events --since "$old" > /dev/null 2> "$work/err"; rc=$?
assert_eq "$rc" 3 "a cursor from before forget --all exits 3"
hook "$p4" working
assert_eq "$("$ROOST" events | fields)" "state|idle|working|1|" "the log starts again after forget --all"

# --- 7b. a 🛑 roost clears itself after a declined dialog --------------------------

# scripts/lib/roost-unblock.sh clears the badge without any hook (#38). The
# stamp and record are set by hand to the real capture's Notification time,
# the way tests/test-claude-decline.sh does, because the decline records in
# the fixture are older than a stamp taken now.
cp "$HERE/tests/fixtures/claude-transcript-no.jsonl" "$work/no.jsonl"
p5="$(new_pane)"; require_pane "$p5" "p5"
hook "$p5" working
hook "$p5" blocked --notification-hook "{\"transcript_path\":\"$work/no.jsonl\"}"
tmux -S "$s" set-option -p -t "$p5" @agent_since 1789398932
tmux -S "$s" set-option -p -t "$p5" @roost-transcript "1789398932 $work/no.jsonl"
"$ROOST" read "$p5" > /dev/null 2>&1
assert_eq "$(tmux -S "$s" show-options -pqv -t "$p5" @agent_state)" "" "(setup) read cleared the declined 🛑"
assert_eq "$("$ROOST" events --pane "$p5" | fields | tail -n 2)" "state|working|blocked|1|
state|blocked|null|1|the dialog was declined or dismissed" \
  "a 🛑 cleared after a declined dialog writes a line, blocked to null"
"$ROOST" read "$p5" > /dev/null 2>&1
assert_eq "$("$ROOST" events --pane "$p5" | fields | grep -c 'blocked|null')" "1" "...once"

# --- 7c. a pane closing ------------------------------------------------------------

# tmux/roost.conf hooks every way a pane can go (measured on tmux 3.4 and 3.6):
# a pane whose program exits fires pane-exited, kill-pane fires
# after-kill-pane with no ids at all, kill-window fires window-unlinked and
# kill-session session-closed. Each runs `roost events --reconcile`, which
# writes a closed line for every pane the log knows that the server no longer
# has. Loaded into this throwaway server only.
tmux -S "$s" set-option -g @roost-home "$HERE"
tmux -S "$s" source-file "$HERE/tmux/roost.conf"
closed_n() { "$ROOST" events | fields | grep -c '^closed|' ; }
wait_closed() { local k=0; while [ "$k" -lt 100 ] && [ "$(closed_n)" -lt "$1" ]; do sleep 0.1; k=$((k + 1)); done; }

# A SPLIT, in a window that stays: then only pane-exited fires, and only that
# hook can write the line. As a window's only pane its exit also fired
# window-unlinked, and the test passed with pane-exited removed (review round 2).
p7="$(tmux -S "$s" split-window -d -t "$p1" -P -F '#{pane_id}' 'sleep 2')"; require_pane "$p7" "p7"
hook "$p7" working
wait_closed 1
assert_eq "$("$ROOST" events --pane "$p7" | fields | tail -n 1)" "closed|working|null|null|" \
  "a pane whose program exits writes a closed line, from its last state"
w8="$(tmux -S "$s" new-window -d -P -F '#{window_id}' 'ENV= exec /bin/sh')"
p8a="$(tmux -S "$s" display -p -t "$w8" '#{pane_id}')"
p8b="$(tmux -S "$s" split-window -d -t "$w8" -P -F '#{pane_id}' 'ENV= exec /bin/sh')"; require_pane "$p8b" "p8b"
p8c="$(tmux -S "$s" split-window -d -t "$w8" -P -F '#{pane_id}' 'ENV= exec /bin/sh')"; require_pane "$p8c" "p8c"
hook "$p8a" working; hook "$p8b" working; hook "$p8c" blocked
tmux -S "$s" kill-pane -t "$p8a"
wait_closed 2
assert_eq "$("$ROOST" events --pane "$p8a" | fields | tail -n 1)" "closed|working|null|null|" "kill-pane writes a closed line"
assert_eq "$("$ROOST" events --pane "$p8b" | fields | tail -n 1)" "state|null|working|1|" "...and none for the pane beside it"
assert_eq "$("$ROOST" events --pane "$p8a" | field window | tail -n 1)" "$w8" "...naming the window it was in"
tmux -S "$s" kill-window -t "$w8"
wait_closed 4
assert_eq "$("$ROOST" events --pane "$p8c" | fields | tail -n 1)" "closed|blocked|null|null|" "kill-window writes a closed line for each agent pane in it"
tmux -S "$s" new-session -d -s two 'ENV= exec /bin/sh'
p9="$(tmux -S "$s" display -p -t two: '#{pane_id}')"
hook "$p9" working
tmux -S "$s" kill-session -t two
wait_closed 5
assert_eq "$("$ROOST" events --pane "$p9" | fields | tail -n 1)" "closed|working|null|null|" "kill-session writes a closed line"
sleep 1
assert_eq "$("$ROOST" events | fields | grep '^closed|' | wc -l | tr -d ' ')" "5" \
  "five panes closed, five closed lines: no pane twice, though several hooks fired for some"
assert_eq "$("$ROOST" events | field pane | sort -u | while read -r x; do "$ROOST" events --pane "$x" | fields | grep -c '^closed|' ; done | sort | uniq -c | awk '{print $2":"$1}' | tr '\n' ' ')" "0:2 1:5 " \
  "...and the two open panes the log still knows (forget --all cleared the rest) have none"

# The close check takes turns through a lock directory. One left behind by a
# run that was killed is taken over only when it is old, and by one run only:
# a pane alone in its window fires after-kill-pane AND window-unlinked, and
# when both runs took over the same stale lock the pane was logged twice
# (review round 2).
lockd="$EVDIR/.reconcile"
mkdir "$lockd"; touch -t 202001010000 "$lockd"
w10="$(tmux -S "$s" new-window -d -P -F '#{window_id}' 'ENV= exec /bin/sh')"
p10="$(tmux -S "$s" display -p -t "$w10" '#{pane_id}')"
hook "$p10" working
tmux -S "$s" kill-pane -t "$p10"
wait_closed 6
sleep 7
assert_eq "$("$ROOST" events --pane "$p10" | fields | grep -c '^closed|')" "1" \
  "an old lock left behind is taken over, and the close is logged once"
[ ! -d "$lockd" ]; assert_true $? "...and no lock is left behind"
# A lock that is NOT old belongs to a run that is still working: it is never
# taken, and the waiting run gives up quietly.
mkdir "$lockd"
w11="$(tmux -S "$s" new-window -d -P -F '#{window_id}' 'ENV= exec /bin/sh')"
p11="$(tmux -S "$s" display -p -t "$w11" '#{pane_id}')"
hook "$p11" working
tmux -S "$s" kill-window -t "$w11"
sleep 7
[ -d "$lockd" ]; assert_true $? "a lock that is not old is never taken over"
assert_eq "$("$ROOST" events --pane "$p11" | fields | grep -c '^closed|')" "0" "...and the run that waited on it wrote nothing"
rmdir "$lockd"
"$ROOST" events --reconcile "$s" "$boot"
assert_eq "$("$ROOST" events --pane "$p11" | fields | grep -c '^closed|')" "1" "...until the next run logs the close"

# A socket and a boot key that do not belong together: the server at the
# socket answers with its OWN boot key, so it cannot say anything about
# another boot's panes, and nothing is written.
bash -c '. "$1"; roost_events_write "$2"' _ "$LIB" \
  '{"schema":1,"ts":1,"server":"123-456","pane":"%1","window":"@1","session_id":null,"event":"state","from":null,"to":"working","turn":1,"reason":""}'
"$ROOST" events --reconcile "$s" 123-456
assert_eq "$(cat "$EVDIR"/[0-9]* | grep '"server":"123-456"' | grep -c '"event":"closed"')" "0" \
  "--reconcile with a boot key the server does not answer to writes nothing"

# The close check never makes a log. A run still waiting when the log is
# removed (forget --all) would otherwise bring it back with its own lines.
ROOST_EVENTS="$work/no-log" bash -c '. "$1"; roost_events_write "$2" nocreate' _ "$LIB" "$(line_n 1)"
[ ! -e "$work/no-log" ]; assert_true $? "a write that may not create leaves a missing log missing"

# --- 8. --follow prints new lines, sleeps, and ends with its server ---------------

# A sleep shim first on the follower's PATH counts its polls. CPU time cannot
# show a spin: a loop with no pause spends its time in forked tmux and wc,
# which ps does not count for the parent.
shim="$work/shim"; mkdir -p "$shim"
real_sleep="$(command -v sleep)"
printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$work/polls" "$real_sleep" > "$shim/sleep"
chmod +x "$shim/sleep"; : > "$work/polls"
PATH="$shim:$PATH" "$ROOST" events --follow > "$work/follow" 2> "$work/follow-err" &
follow_pid=$!
hook "$p4" idle
k=0; while [ "$k" -lt 50 ] && ! grep -q '"to":"idle"' "$work/follow"; do sleep 0.1; k=$((k + 1)); done
assert_eq "$(fields < "$work/follow" | tail -n 1)" "state|working|idle|1|" "--follow prints a line written after it started"
n0="$(wc -l < "$work/polls")"
sleep 3
polls=$(( $(wc -l < "$work/polls") - n0 ))
[ "$polls" -ge 3 ] && [ "$polls" -le 12 ]; r=$?
assert_true "$r" "--follow does not spin: it slept $polls times in ~3 s (want 3 to 12)"
tmux -S "$s" kill-server 2>/dev/null
k=0; while [ "$k" -lt 50 ] && kill -0 "$follow_pid" 2>/dev/null; do sleep 0.1; k=$((k + 1)); done
kill -0 "$follow_pid" 2>/dev/null; assert_eq "$?" 1 "--follow exits when its server is gone"
# A follower that did not end is killed before the wait, so a regression fails
# here instead of hanging the suite.
kill -0 "$follow_pid" 2>/dev/null && kill "$follow_pid" 2>/dev/null
wait "$follow_pid"; rc=$?; follow_pid=""
assert_eq "$rc" 0 "...at exit 0"
assert_contains "$(cat "$work/follow-err")" "stopped" "...and says the server stopped"
"$ROOST" events > /dev/null 2> "$work/err"; rc=$?
assert_eq "$rc" 2 "roost events with no server running exits 2"

# --- 9. nothing reached the real home ---------------------------------------------

assert_eq "$(find "$HOME" "$XDG_STATE_HOME" -mindepth 1 2>/dev/null | head -1)" "" \
  "nothing was written under HOME or XDG_STATE_HOME"
