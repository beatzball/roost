#!/usr/bin/env bash
# The per-pane record (#74) and the durable reply history built on it (#42).
#
# Design, and every measurement behind it:
# docs/airig/specs/2026-09-16-pane-record-design.md.
#
# A pane option can hold one turn, capped at 12 KB, and dies with the pane.
# The record keeps each turn whole, as one raw file, in a directory keyed by the
# server's boot and the pane number. The pane option stays the truth while the
# pane lives: `read` serves a file only when it agrees with @roost-reply.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"

# Everything under one throwaway directory. HOME and XDG_STATE_HOME point at
# canaries nothing may write to: the last block of this file checks them, so a
# record that ignored ROOST_RECORD_DIR and fell through to the default path
# fails here instead of landing in the developer's real state directory.
work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"
REC="$work/rec"
export ROOST_RECORD_DIR="$REC"
export HOME="$work/home" XDG_STATE_HOME="$work/xdg-state"
mkdir -p "$HOME" "$XDG_STATE_HOME"
cleanup() {
  tmux -S "$s" kill-server 2>/dev/null
  tmux -S "$work/b/roost" kill-server 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# roost-agent-state acts only on a socket path ending in /roost, and bin/roost
# takes its socket from $ROOST_SOCKET — tests/test-reply-channel.sh's shape.
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
boot="$(tmux -S "$s" display -p '#{start_time}-#{pid}')"
export ROOST_SOCKET="$s"

# A fresh pane per scenario, in its own window: turn numbers belong to a pane,
# and a split can run out of room and return an empty id (tests/lib.sh).
new_pane() { tmux -S "$s" new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
as_pane() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$@"; }
recdir()  { printf '%s/%s/%s' "$REC" "$boot" "${1#%}"; }
turns_in() { ls "$(recdir "$1")/replies" 2>/dev/null | grep -c '^[0-9][0-9]*$'; }

# One Claude turn through the real hook: working, then Stop with a JSON payload
# whose last_assistant_message is the bytes of file $2. python3 builds the JSON
# from the file, so no shell quoting touches the text on the way in.
claude_turn() {
  local p="$1" f="$2"
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"last_assistant_message": open(sys.argv[1],"rb").read().decode("utf-8")}))' \
    "$f" > "$work/payload"
  as_pane "$p" "$HOOK" working </dev/null
  as_pane "$p" "$HOOK" done --stop-hook < "$work/payload"
}

# What `read` prints for a reply of these bytes: the bytes with trailing
# newlines dropped (the hook's $(...) drops them before either store), then one
# newline — the existing `printf '%s\n'`.
expect_file() { local v; v="$(cat "$1")"; printf '%s\n' "$v" > "$2"; }

# --- 1. a reply larger than the 12 KB cap round-trips whole -----------------

big="$work/big.txt"
awk 'BEGIN{for(i=0;i<1500;i++) printf "line %05d: some padding text to make the reply long\n", i}' > "$big"
p1="$(new_pane)"; require_pane "$p1" "big reply"
claude_turn "$p1" "$big"
"$ROOST" read "$p1" > "$work/out" 2> "$work/err"; rc=$?
expect_file "$big" "$work/want"
cmp -s "$work/out" "$work/want"; assert_true $? "a 78 KB reply through the Stop hook reads back whole"
assert_eq "$rc" 0 "...at exit 0"
assert_eq "$(cat "$work/err")" "" "...with nothing on stderr"
case "$(tmux -S "$s" show-options -pqv -t "$p1" @roost-reply)" in
  *"reply truncated"*) assert_true 0 "the pane option still holds the capped value — the record did not grow it" ;;
  *) assert_true 1 "the pane option still holds the capped value — the record did not grow it" ;;
esac

p1b="$(new_pane)"; require_pane "$p1b" "big reply via roost reply"
as_pane "$p1b" "$ROOST" reply "$(cat "$big")"
"$ROOST" read "$p1b" > "$work/out" 2>/dev/null
cmp -s "$work/out" "$work/want"; assert_true $? "a 78 KB reply through \`roost reply\` reads back whole"

# --- 2. a second turn does not destroy the first ----------------------------

p2="$(new_pane)"; require_pane "$p2" "two turns"
printf 'FIRST TURN\nsecond line' > "$work/t1"; printf 'SECOND TURN' > "$work/t2"
claude_turn "$p2" "$work/t1"; claude_turn "$p2" "$work/t2"
assert_eq "$("$ROOST" read "$p2")" "SECOND TURN" "read returns the newest turn"
assert_eq "$("$ROOST" read --turn 1 "$p2")" $'FIRST TURN\nsecond line' "read --turn 1 returns the first turn"
assert_eq "$("$ROOST" read --turn -2 "$p2")" $'FIRST TURN\nsecond line' "read --turn -2 counts back from the newest"
assert_eq "$("$ROOST" read --turn -1 "$p2")" "SECOND TURN" "read --turn -1 is the newest"
assert_eq "$("$ROOST" read --turn 2 --json "$p2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["source"], d["turn"], d["text"])')" \
  "record 2 SECOND TURN" "--turn with --json says source record, the turn, and the text"
assert_eq "$("$ROOST" read --json --turn 1 "$p2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["turn"])')" \
  "1" "--json before --turn works too"
assert_eq "$("$ROOST" read --json "$p2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["source"], d["turn"])')" \
  "reply 2" "plain --json on a recorded pane keeps source reply and names the turn"
"$ROOST" read --turn 0 "$p2" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "--turn 0 is refused"
assert_contains "$(cat "$work/err")" "--turn" "...naming the flag"
"$ROOST" read --turn 1 --turn 2 "$p2" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "a repeated --turn is refused"
"$ROOST" read --turn abc "$p2" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "a --turn that is not a number is refused"

# --- 3. hostile bytes round-trip byte-identically ---------------------------

# Built with printf octal escapes, never typed as literal characters: an editor
# or tool that normalises text would otherwise change the fixture silently.
emoji="$(printf '\360\237\230\200')"; eacute="$(printf '\303\251')"
i=0
for spec in 'return 0;' 'case x;;' "quotes \" ' \\ \$HOME \`x\`" "caf${eacute} ${emoji} tab	here" \
            '#{pane_id} #[fg=red] 100%' $'multi\nline\n\n\ntrailing newlines\n\n'; do
  i=$((i + 1))
  printf '%s' "$spec" > "$work/h$i"
  ph="$(new_pane)"; require_pane "$ph" "hostile $i"
  claude_turn "$ph" "$work/h$i"
  expect_file "$work/h$i" "$work/want"
  "$ROOST" read "$ph" > "$work/out" 2>/dev/null
  cmp -s "$work/out" "$work/want"; assert_true $? "hostile reply $i reads back byte-identical"
  "$ROOST" read --turn -1 "$ph" > "$work/out" 2>/dev/null
  cmp -s "$work/out" "$work/want"; assert_true $? "hostile reply $i reads back byte-identical through --turn"
  file="$(recdir "$ph")/replies/000001"
  cmp -s "$file" "$work/h$i" || { v="$(cat "$work/h$i")"; printf '%s' "$v" | cmp -s "$file" -; }
  assert_true $? "hostile reply $i is stored as raw bytes, no escaping"
done
# The same hostile tail past the cap: non-ASCII, emoji, and a trailing `;`.
{ cat "$big"; printf 'caf%s %s end;' "$eacute" "$emoji"; } > "$work/bigh"
ph="$(new_pane)"; require_pane "$ph" "hostile big"
as_pane "$ph" "$ROOST" reply "$(cat "$work/bigh")"
expect_file "$work/bigh" "$work/want"
"$ROOST" read "$ph" > "$work/out" 2>/dev/null
cmp -s "$work/out" "$work/want"; assert_true $? "a reply past the cap ending in non-ASCII and \`;\` reads back byte-identical"

# --- 4. a gone pane still has its replies -----------------------------------

pg="$(new_pane)"; require_pane "$pg" "gone pane"
printf 'GONE ONE' > "$work/g1"; printf 'GONE TWO' > "$work/g2"
claude_turn "$pg" "$work/g1"; claude_turn "$pg" "$work/g2"
tmux -S "$s" kill-pane -t "$pg"
out="$("$ROOST" read "$pg" 2>"$work/err")"; rc=$?
assert_eq "$out" "GONE TWO" "read on a closed pane prints its last recorded reply"
assert_eq "$rc" 0 "...at exit 0"
assert_eq "$(cat "$work/err")" "roost read: '$pg' is gone — this is its last recorded reply (turn 2)." \
  "...and says on stderr that the pane is gone"
assert_eq "$("$ROOST" read --turn 1 "$pg" 2>/dev/null)" "GONE ONE" "read --turn works on a closed pane"
assert_eq "$("$ROOST" read --json "$pg" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["source"], d["state"], d["turn"], d["text"])')" \
  "record None 2 GONE TWO" "--json on a closed pane: source record, state null"

# A closed pane that never had a record keeps today's failure exactly.
pn="$(new_pane)"; require_pane "$pn" "gone pane, no record"
tmux -S "$s" kill-pane -t "$pn"
"$ROOST" read "$pn" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "a closed pane with no record still fails"
assert_contains "$(cat "$work/err")" "no recorded reply for '$pn'" "...with today's notice"

# --- 5. the per-pane bound, and a pruned turn is reported -------------------

pk="$(new_pane)"; require_pane "$pk" "keep bound"
for n in 1 2 3 4 5; do ROOST_RECORD_KEEP=3 as_pane "$pk" "$ROOST" reply "TURN $n"; done
assert_eq "$(turns_in "$pk")" 3 "ROOST_RECORD_KEEP=3 keeps three turn files"
assert_eq "$(ls "$(recdir "$pk")/replies" | tr '\n' ' ')" "000003 000004 000005 " "...the three newest"
ROOST_RECORD_KEEP=3 "$ROOST" read --turn 1 "$pk" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "reading a pruned turn fails"
assert_eq "$(cat "$work/err")" "roost read: turn 1 of '$pk' was pruned — turns 3 to 5 are kept (ROOST_RECORD_KEEP=3)." \
  "...and says it was pruned, and what is kept"
ROOST_RECORD_KEEP=3 "$ROOST" read --turn -5 "$pk" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "counting back past the oldest kept turn fails"
assert_contains "$(cat "$work/err")" "was pruned — turns 3 to 5 are kept" "...and is reported as pruned too"
"$ROOST" read --turn 9 "$pk" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "a turn past the newest fails"
assert_eq "$(cat "$work/err")" "roost read: turn 9 of '$pk' is not recorded — turns 3 to 5 are kept." \
  "...and says it is not recorded"
pz="$(new_pane)"; require_pane "$pz" "no turns"
"$ROOST" read --turn -1 "$pz" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "--turn on a pane with no record fails"
assert_eq "$(cat "$work/err")" "roost read: no recorded turns for '$pz'." "...and says so"

# --- 6. roost forget removes exactly what it says ---------------------------

pf1="$(new_pane)"; pf2="$(new_pane)"; require_pane "$pf2" "forget"
as_pane "$pf1" "$ROOST" reply "KEEP ME"; as_pane "$pf2" "$ROOST" reply "FORGET ME"
[ -d "$(recdir "$pf2")" ]; assert_true $? "the record forget is about to remove exists (control)"
out="$("$ROOST" forget "$pf2")"; rc=$?
assert_eq "$rc" 0 "forget TARGET exits 0"
assert_contains "$out" "removed the record for '$pf2' (1 turn" "...and says what it removed"
assert_file_absent "$(recdir "$pf2")" "forget TARGET removes that pane's record"
[ -d "$(recdir "$pf1")" ]; assert_true $? "...and leaves another pane's record"
assert_eq "$("$ROOST" read "$pf2" 2>/dev/null)" "FORGET ME" "forget never touches the pane option: the pane still reads"
"$ROOST" forget "$pf2" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" 1 "forget on a pane with no record fails"
assert_eq "$(cat "$work/err")" "roost forget: no record for '$pf2'." "...and says so"

# --gone: one record of each kind that is NOT live, and a live one.
plant() { # plant DIR SOCKET — a minimal schema-1 record with one turn
  mkdir -p "$1/replies"; printf '1\n' > "$1/schema"; printf '%s\n' "$2" > "$1/socket"; printf 'x' > "$1/replies/000001"
}
pdead="$(new_pane)"; require_pane "$pdead" "dead"; as_pane "$pdead" "$ROOST" reply "DEAD"
tmux -S "$s" kill-pane -t "$pdead"
[ -d "$(recdir "$pdead")" ]; assert_true $? "the closed pane's record exists before --gone (control)"
plant "$REC/1000000000-1/0" "$s"                 # this socket, an earlier boot: a restarted server
plant "$REC/1000000000-2/0" "$work/no-such/roost" # a socket that is gone
plant "$REC/1000000000-3/0" ""                    # no socket recorded at all
out="$("$ROOST" forget --gone)"; rc=$?
assert_eq "$rc" 0 "forget --gone exits 0"
assert_file_absent "$(recdir "$pdead")" "forget --gone removes a closed pane's record"
assert_file_absent "$(recdir "$pg")" "...including the one section 4 closed"
assert_file_absent "$REC/1000000000-1" "forget --gone removes a restarted server's record"
assert_file_absent "$REC/1000000000-2" "forget --gone removes a record whose socket is gone"
assert_file_absent "$REC/1000000000-3" "forget --gone removes a record with no socket"
[ -d "$(recdir "$pf1")" ]; assert_true $? "forget --gone keeps a live pane's record"
assert_contains "$out" "removed 5 records, kept" "forget --gone totals what it removed"

# --all removes every record, and nothing that is not one.
# A file AND a directory that roost did not write: the loop skips files by
# itself, so only the directory proves the boot-key shape check is there.
printf 'not a record\n' > "$REC/keep-me.txt"
mkdir -p "$REC/notes/1"; printf 'mine\n' > "$REC/notes/1/file"
out="$("$ROOST" forget --all)"; rc=$?
assert_eq "$rc" 0 "forget --all exits 0"
assert_eq "$(ls "$REC" | tr '\n' ' ')" "keep-me.txt notes " "forget --all removes every record and only records"
assert_contains "$out" "removed" "forget --all says what it removed"
rm -rf "$REC/keep-me.txt" "$REC/notes"
"$ROOST" forget >/dev/null 2>&1; rc=$?
assert_eq "$rc" 1 "forget with no argument is a usage error"

# --- 7. the 30-day sweep, when a new pane record is created -----------------

old_stamp="$(python3 -c 'import time; print(time.strftime("%Y%m%d%H%M", time.localtime(time.time() - 31*86400)))')"
psw="$(new_pane)"; require_pane "$psw" "sweep live"
as_pane "$psw" "$ROOST" reply "OLD BUT LIVE"
plant "$REC/1000000000-9/7" "$s"                  # history, old
plant "$REC/1000000000-9/8" "$s"                  # history, fresh
touch -t "$old_stamp" "$(recdir "$psw")/replies" "$REC/1000000000-9/7/replies"
pnew="$(new_pane)"; require_pane "$pnew" "sweep trigger"
as_pane "$pnew" "$ROOST" reply "NEW PANE"
assert_file_absent "$REC/1000000000-9/7" "a record that is not live and 31 days old is swept when a new pane record is made"
[ -d "$REC/1000000000-9/8" ]; assert_true $? "a record that is not live but fresh is kept"
[ -d "$(recdir "$psw")" ]; assert_true $? "a live pane's record is never swept, however old"
rm -rf "$REC/1000000000-9"

# --- 8. no record: read behaves exactly as today ----------------------------

# Every line below is the output of the code BEFORE the record existed, copied
# here, so a change to any of it is a failure rather than a judgement call.
pt="$(new_pane)"; require_pane "$pt" "today"
tmux -S "$s" set-option -p -t "$pt" @roost-reply "SET BY HAND"
tmux -S "$s" set-option -p -t "$pt" @agent_state done
"$ROOST" read "$pt" > "$work/out" 2> "$work/err"; rc=$?
printf 'SET BY HAND\n' > "$work/want"
cmp -s "$work/out" "$work/want"; assert_true $? "no record: a reply prints exactly as before"
assert_eq "$(cat "$work/err")|$rc" "|0" "no record: nothing on stderr, exit 0"
tmux -S "$s" set-option -p -t "$pt" @agent_state working
"$ROOST" read "$pt" 2> "$work/err" >/dev/null
assert_eq "$(cat "$work/err")" "roost read: '$pt' is working — this reply is from its previous turn." \
  "no record: the stale notice is unchanged"
tmux -S "$s" set-option -p -t "$pt" @agent_state error
tmux -S "$s" set-option -p -t "$pt" @roost-error-reason "a reason"
tmux -S "$s" set-option -pu -t "$pt" @roost-reply
"$ROOST" read "$pt" 2> "$work/err" >/dev/null; rc=$?
assert_eq "$(cat "$work/err")|$rc" "roost read: no recorded reply for '$pt' — showing the pane's screen instead.
roost read: ('$pt' is in error state: a reason; roost screen reads the screen without this notice)|0" \
  "no record: the error fallback is unchanged"
tmux -S "$s" set-option -p -t "$pt" @agent_state done
tmux -S "$s" set-option -p -t "$pt" @roost-reply "SET BY HAND"
json="$("$ROOST" read --json "$pt")"
assert_eq "$json" "{\"schema\":1,\"command\":\"read\",\"target\":\"$pt\",\"pane\":\"$pt\",\"source\":\"reply\",\"state\":\"done\",\"stale\":false,\"error_reason\":null,\"turn\":null,\"text\":\"SET BY HAND\",\"lossy\":false}" \
  "no record: --json is unchanged but for the added \"turn\":null"
# With a record and a reply under the cap, the output is the same bytes as a
# pane that has no record at all.
pr="$(new_pane)"; require_pane "$pr" "record, small"
as_pane "$pr" "$ROOST" reply "SET BY HAND"
tmux -S "$s" set-option -p -t "$pr" @agent_state done
"$ROOST" read "$pr" > "$work/out2" 2> "$work/err2"; rc2=$?
"$ROOST" read "$pt" > "$work/out" 2> "$work/err"; rc=$?
cmp -s "$work/out" "$work/out2" && cmp -s "$work/err" "$work/err2" && [ "$rc" = "$rc2" ]
assert_true $? "a small reply reads the same bytes, stderr and exit with a record as without one"
# Records off entirely: ROOST_RECORD_DIR not absolute.
pofft="$(new_pane)"; require_pane "$pofft" "records off"
( cd "$work" && ROOST_RECORD_DIR=relative/dir as_pane "$pofft" "$ROOST" reply "RECORDS OFF" )
assert_eq "$("$ROOST" read "$pofft")" "RECORDS OFF" "a relative ROOST_RECORD_DIR records nothing and read still works"
[ -d "$(recdir "$pofft")" ]; rc=$?; assert_eq "$rc" 1 "...and records nothing under the real root either"
assert_file_absent "$work/relative" "...and creates no directory"
ROOST_RECORD_DIR= as_pane "$pofft" "$ROOST" reply "RECORDS OFF 2"
assert_file_absent "$(recdir "$pofft")" "an empty ROOST_RECORD_DIR records nothing"

# --- 9. the pane wins -------------------------------------------------------

pw="$(new_pane)"; require_pane "$pw" "pane wins"
claude_turn "$pw" "$big"
tmux -S "$s" set-option -pu -t "$pw" @roost-reply
"$ROOST" read "$pw" 5 > "$work/out" 2> "$work/err"
assert_contains "$(cat "$work/err")" "no recorded reply for '$pw'" \
  "a pane whose reply was cleared falls back to the screen, whatever files exist"
tmux -S "$s" set-option -p -t "$pw" @roost-reply "HAND SET"
assert_eq "$("$ROOST" read "$pw")" "HAND SET" "a pane value that disagrees with the file is printed, not the file"
# A truncated pane value whose file no longer agrees: the pane value is printed.
claude_turn "$pw" "$big"
f="$(recdir "$pw")/replies/000002"
printf 'tampered' >> "$f"
out="$("$ROOST" read "$pw")"
assert_contains "$out" "reply truncated" "a truncated pane value is printed when the file's size disagrees"
# Same size, different head.
claude_turn "$pw" "$big"
f="$(recdir "$pw")/replies/000003"
python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[0:4]=b"LINE"; open(p,"wb").write(b)' "$f"
out="$("$ROOST" read "$pw")"
assert_contains "$out" "reply truncated" "a truncated pane value is printed when the file's head disagrees"

# --- 10. a malformed record is a warning, never the cause of a failure ------

pm="$(new_pane)"; require_pane "$pm" "malformed"
as_pane "$pm" "$ROOST" reply "MALFORMED CASE"
for bad in x 2 ''; do
  if [ -n "$bad" ]; then printf '%s\n' "$bad" > "$(recdir "$pm")/schema"; else rm -f "$(recdir "$pm")/schema"; fi
  out="$("$ROOST" read "$pm" 2>"$work/err")"; rc=$?
  assert_eq "$out|$rc" "MALFORMED CASE|0" "schema [$bad]: read prints the pane value at exit 0"
  case "$bad" in
    2) want="roost read: the record for '$pm' was written by a newer roost (schema 2) — ignored." ;;
    *) want="roost read: the record for '$pm' is unreadable (schema: $bad) — ignored." ;;
  esac
  assert_eq "$(cat "$work/err")" "$want" "schema [$bad]: one warning line on stderr"
done
printf '2\n' > "$(recdir "$pm")/schema"
before="$(ls -R "$(recdir "$pm")")"
as_pane "$pm" "$ROOST" reply "WRITTEN BY AN OLDER ROOST"
assert_eq "$(ls -R "$(recdir "$pm")")" "$before" "a writer never writes into a record with a newer schema"
assert_eq "$("$ROOST" read "$pm" 2>/dev/null)" "WRITTEN BY AN OLDER ROOST" "...and the pane still takes the reply"
printf 'x\n' > "$(recdir "$pm")/schema"
tmux -S "$s" kill-pane -t "$pm"
"$ROOST" read "$pm" >/dev/null 2>"$work/err"; rc=$?
assert_contains "$(cat "$work/err")" "is unreadable (schema: x) — ignored." "a closed pane with a malformed record warns"
assert_contains "$(cat "$work/err")" "no recorded reply for '$pm'" "...then fails exactly as a closed pane with no record does"

# --- 11. liveness: live, closed, restarted, gone, and a reused pid ----------

. "$HERE/scripts/lib/roost-record.sh"
b="$work/b/roost"; mkdir -p "$work/b"
tmux -S "$b" -f /dev/null new-session -d 'ENV= exec /bin/sh'
bboot="$(tmux -S "$b" display -p '#{start_time}-#{pid}')"
bpane="$(tmux -S "$b" display -p '#{pane_id}')"
roost_record_live "$b" "$bboot" "$bpane"; assert_true $? "a record of a pane that exists is live"
roost_record_live "$b" "$bboot" "%999"; rc=$?; assert_eq "$rc" 1 "a record of a closed pane is history"
sleep 30 & other=$!
roost_record_live "$b" "${bboot%%-*}-$other" "$bpane"; rc=$?
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
assert_eq "$rc" 1 "a boot key whose pid is now an unrelated live process is history"
ROOST_SOCKET="$b" TMUX="$b,${bboot#*-},0" TMUX_PANE="$bpane" "$ROOST" reply "OLD SERVER %0"
tmux -S "$b" kill-server; sleep 1.1
tmux -S "$b" -f /dev/null new-session -d 'ENV= exec /bin/sh'
roost_record_live "$b" "$bboot" "$bpane"; rc=$?
assert_eq "$rc" 1 "after a restart on the same socket, the old boot's record is history"
nboot="$(tmux -S "$b" display -p '#{start_time}-#{pid}')"
roost_record_live "$b" "$nboot" "$bpane"; assert_true $? "...and the new boot's pane of the same id is live (control)"
assert_eq "$(tmux -S "$b" display -p '#{pane_id}')" "$bpane" "the restarted server reuses the pane id (the hazard)"
[ -d "$REC/$bboot/${bpane#%}" ]; assert_true $? "the old server's record exists (control)"
out="$(ROOST_SOCKET="$b" "$ROOST" read "$bpane" 5 2>&1)"
case "$out" in
  *"OLD SERVER"*) assert_true 1 "a restarted server's pane never serves the old server's reply" ;;
  *) assert_true 0 "a restarted server's pane never serves the old server's reply" ;;
esac
ROOST_SOCKET="$b" "$ROOST" read --turn -1 "$bpane" >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc|$(cat "$work/err")" "1|roost read: no recorded turns for '$bpane'." "...not even through --turn"
tmux -S "$b" kill-server
roost_record_live "$b" "$nboot" "$bpane"; rc=$?
assert_eq "$rc" 1 "a record whose socket is gone is history"

# --- 12. concurrent writers on one pane -------------------------------------

pc="$(new_pane)"; require_pane "$pc" "concurrency"
for n in $(seq 1 20); do as_pane "$pc" "$ROOST" reply "CONCURRENT $n $(printf '%04000d' 0)" & done
wait
assert_eq "$(turns_in "$pc")" 20 "twenty writers at once make twenty turns"
assert_eq "$(ls -A "$(recdir "$pc")/replies" | grep -c '^\.' )" 0 "...and leave no temp file"
sizes="$(for f in "$(recdir "$pc")"/replies/0*; do wc -c < "$f" | tr -d ' '; done | sort -u | tr '\n' ' ')"
assert_eq "$sizes" "4013 4014 " "...and every turn file is whole"

# --- 13. a record that cannot be written never breaks the hook --------------

watch() { # watch SECONDS CMD... -> the command's status, or 124 if it had to be killed
  local secs="$1" pid i=0; shift
  # <&0 is an explicit redirection: without one, bash gives a background job
  # /dev/null for stdin, and the hook would read an empty payload.
  "$@" <&0 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le $((secs * 10)) ] || { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 0.1
  done
  wait "$pid"
}
pd="$(new_pane)"; require_pane "$pd" "degrade"
printf 'a file, not a directory' > "$work/afile"
printf 'DEGRADED' > "$work/d1"
python3 -c 'import json,sys; sys.stdout.write(json.dumps({"last_assistant_message": "DEGRADED"}))' > "$work/dpayload"
as_pane "$pd" "$HOOK" working </dev/null
ROOST_RECORD_DIR="$work/afile/rec" watch 5 env TMUX="$s,$spid,0" TMUX_PANE="$pd" "$HOOK" done --stop-hook < "$work/dpayload"; rc=$?
assert_eq "$rc" 0 "an unwritable record directory: the hook still exits 0, promptly"
assert_eq "$("$ROOST" read "$pd")" "DEGRADED" "...and the pane still takes the reply"
# A filesystem where hard links fail: ln fails and names nothing. The writer
# must give up, not retry forever (the prototype hung exactly here).
shim="$work/shim"; mkdir -p "$shim"; printf '#!/bin/sh\nexit 1\n' > "$shim/ln"; chmod +x "$shim/ln"
as_pane "$pd" "$HOOK" working </dev/null
PATH="$shim:$PATH" watch 5 env TMUX="$s,$spid,0" TMUX_PANE="$pd" "$HOOK" done --stop-hook < "$work/dpayload"; rc=$?
assert_eq "$rc" 0 "ln that always fails: the hook gives up and exits 0 within 5 s"
assert_eq "$(ls -A "$(recdir "$pd")/replies" 2>/dev/null | grep -c '^\.')" 0 "...and leaves no temp file"

# --- 14. the per-tool-call path writes nothing ------------------------------

ph2="$(new_pane)"; require_pane "$ph2" "hot path"
as_pane "$ph2" "$HOOK" working </dev/null
for n in $(seq 1 30); do as_pane "$ph2" "$HOOK" working </dev/null; done
assert_file_absent "$(recdir "$ph2")" "repeated working calls (PostToolUse) create no record"

# --- 15. the default location, and nothing outside it -----------------------

pdf="$(new_pane)"; require_pane "$pdf" "default path"
env -u ROOST_RECORD_DIR HOME="$work/home2" XDG_STATE_HOME="$work/xdg2" TMUX="$s,$spid,0" TMUX_PANE="$pdf" "$ROOST" reply "XDG"
[ -f "$work/xdg2/roost/panes/$boot/${pdf#%}/replies/000001" ]; assert_true $? "unset ROOST_RECORD_DIR records under \$XDG_STATE_HOME/roost/panes"
env -u ROOST_RECORD_DIR HOME="$work/home2" XDG_STATE_HOME=relative TMUX="$s,$spid,0" TMUX_PANE="$pdf" "$ROOST" reply "HOME"
[ -f "$work/home2/.local/state/roost/panes/$boot/${pdf#%}/replies/000001" ]; assert_true $? "a relative XDG_STATE_HOME is ignored: \$HOME/.local/state/roost/panes"
mode="$(ls -ld "$work/home2/.local/state/roost/panes/$boot/${pdf#%}" | cut -c1-10)"
assert_eq "$mode" "drwx------" "a pane record directory is private to the user"
mode="$(ls -l "$work/home2/.local/state/roost/panes/$boot/${pdf#%}/replies/000001" | cut -c1-10)"
assert_eq "$mode" "-rw-------" "a turn file is private to the user"
assert_eq "$(find "$HOME" "$XDG_STATE_HOME" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" 0 \
  "nothing was written to the canary HOME or XDG_STATE_HOME"
