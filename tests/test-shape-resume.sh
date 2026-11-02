#!/usr/bin/env bash
# Restore resumes (#191 Part 3): the pending record between placement and
# launch, the placeholder's pending modes, the pane side (`send` refuses,
# `close` cancels) and the resume engine. Design:
# docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.6 (the pending
# record and the loop), §4.7 (who owns a pane: the states and arrows T1–T19).
# Plan: Part 3, Tasks 3.1–3.5.
#
# The library cases source scripts/lib/roost-pending.sh directly. The verb's
# cases drive bin/roost against this file's own named server (tests/lib-shape.sh
# says why it is `-L roost` under a guarded TMUX_TMPDIR) with stub harnesses.
#
# WORKER-ONLY. The `client-attached` hook is Part 5. Every case here that the
# spec's §8.1 words as "attach a real client so the worker runs" is run by
# calling `roost restore --resume` directly, and does NOT cover the hook
# (§8.1 test 11 allows this; the hook's own cases are Part 5's).
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT

. scripts/lib/roost-pending.sh

U1=3fa3c0de-1111-4abc-8def-000000000001
U2=3fa3c0de-2222-4abc-8def-000000000002

# The file's lines, joined with `|`, for one-line comparisons.
flat() { tr '\n' '|' < "$1" | sed 's/|$//'; }
mode_of() { ls -l "$1" | cut -c1-10; }

echo "== roost_pending_write: the resume block, before its placeholder (§4.6) =="
SD="$SHAPE_TMP/sd"; mkdir -p "$SD"
BOOT="1761000000-4242"
f="$(roost_pending_write "$SD" "$BOOT" %12 %930 claude "$U1" /t/one.jsonl /w/a.b /w/s main 2 3)"; rc=$?
assert_eq "$rc|$f" "0|$SD/pending/$BOOT/%12" "it prints the file it wrote: pending/<boot>/%N, exit 0"
assert_eq "$(flat "$f")" "was %930|harness claude|session_id $U1|transcript /t/one.jsonl|cwd /w/a.b|session_cwd /w/s|session main|window 2|order 3" \
  "the resume block, in a fixed order, starting with its was line"
assert_eq "$(mode_of "$f")" "-rw-------" "the file is 0600 (a session id is enough to resume a conversation)"
assert_eq "$(ls -ld "$SD/pending/$BOOT" | cut -c1-10)" "drwx------" "its directory is 0700"
f2="$(roost_pending_write "$SD" "$BOOT" %13 %931 codex "$U2" "" /w/b "" main 2 4)"
assert_eq "$(flat "$f2")" "was %931|harness codex|session_id $U2|cwd /w/b|session main|window 2|order 4" \
  "an empty transcript or session_cwd is no line at all"
assert_eq "$(ls -a "$SD/pending/$BOOT" | grep -c '^\.')" "2" "no temp file is left beside them"
roost_pending_write "$SD" "$BOOT" 12 %930 claude "$U1" "" /w "" main 2 3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a pane that is not %N is refused (it names a file)"
roost_pending_write "$SD" "$BOOT" %14 %930 claude "$U1" "" "/w
x" "" main 2 3 >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(ls "$SD/pending/$BOOT" | grep -c '%14')" "1|0" "a value holding a newline is refused, nothing written (one line per key)"

echo "== roost_pending_take: a rename, then origin only when it won (T5, T14, T16, T17) =="
P="$SD/pending/$BOOT"
roost_pending_take "$P/%12" "$P/%12.launching" waiting; rc=$?
assert_eq "$rc|$(ls "$P" | tr '\n' ' ')" "0|%12.launching %13 " "the rename won: exit 0, the file has its new name"
assert_eq "$(tail -1 "$P/%12.launching")" "origin waiting" "...and gains origin waiting, after the rename"
assert_eq "$(grep -c '^origin ' "$P/%12.launching")" "1" "...one origin line"
roost_pending_take "$P/%12" "$P/%12.launching" waiting; rc=$?
assert_eq "$rc|$(grep -c '^origin ' "$P/%12.launching")" "1|1" "a lost rename (the file is gone): exit 1, nothing appended anywhere"
cp "$P/%13" "$SHAPE_TMP/keep13"
printf 'store miss\n' | cat - "$SHAPE_TMP/keep13" > "$P/%13.failed"; rm -f "$P/%13"; chmod 600 "$P/%13.failed"
roost_pending_take "$P/%13.failed" "$P/%13.launching" "failed store miss"
assert_eq "$(tail -1 "$P/%13.launching")" "origin failed store miss" "from failed: origin failed REASON (the old first line)"

echo "== roost_pending_take never writes into a file it no longer owns (review round 1, Opus N2) =="
# Held between the rename and the origin append (the seam a caller names in
# ROOST_PENDING_SEAM), the file is moved away, as a T8b put-back would: the
# append must not create a stray %N.launching, and the take reports it lost.
# The seam helper is roost-shape.sh's, which every caller of this library has
# sourced (bin/roost, restore, revive); this file sources it here.
. scripts/lib/roost-shape.sh
f9="$(roost_pending_write "$SD" "$BOOT" %19 %939 claude "$U1" "" /w "" main 2 9)"
TH="$SHAPE_TMP/take.hold"; rm -f "$TH" "$TH".at.*
( TAKE_SEAM="$TH" ROOST_PENDING_SEAM=TAKE_SEAM roost_pending_take "$f9" "$f9.launching" waiting; echo "rc=$?" > "$SHAPE_TMP/take.rc" ) &
TP=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$TH".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
mv "$f9.launching" "$f9.failed"
touch "$TH"; wait "$TP"
assert_eq "$(cat "$SHAPE_TMP/take.rc")|$(ls "$P" | grep -c '^%19\.launching$')" "rc=1|0" \
  "the file moved away before the origin line: no stray .launching is made, and the take is lost (exit 1)"
assert_eq "$(grep -c '^origin' "$f9.failed")" "0" "...and nothing was written into the file at its new name"
rm -f "$P/%19".* "$P"/.%19.by.* 2>/dev/null

echo "== roost_pending_leave_launching: origin removed, then the rename (revision 10, C B1) =="
roost_pending_leave_launching "$P/%12.launching" "$P/%12"; rc=$?
assert_eq "$rc|$(ls "$P" | tr '\n' ' ')" "0|%12 %13.launching " "back to %N: exit 0"
assert_eq "$(grep -c '^origin ' "$P/%12")" "0" "a %N it produced has no origin line"
assert_eq "$(head -1 "$P/%12")" "was %930" "...and starts with its was line again"
assert_eq "$(mode_of "$P/%12")" "-rw-------" "...still 0600 (the rewrite kept the mode)"
roost_pending_leave_launching "$P/%13.launching" "$P/%13.failed" "duplicate of %40"
assert_eq "$(flat "$P/%13.failed")" "duplicate of %40|was %931|harness codex|session_id $U2|cwd /w/b|session main|window 2|order 4" \
  "to .failed with a REASON: the reason is the first line, the old one replaced, no origin"
roost_pending_take "$P/%13.failed" "$P/%13.launching" "failed duplicate of %40"
roost_pending_leave_launching "$P/%13.launching" "$P/%13.taken"
assert_eq "$(flat "$P/%13.taken")" "was %931|harness codex|session_id $U2|cwd /w/b|session main|window 2|order 4" \
  "to .taken with no REASON: no reason line and no origin line"
# A dead pane's file keeps `died` first; a later failed check is extra text (T7
# from origin failed died, revision 5, C B2(a)).
roost_pending_take "$P/%13.taken" "$P/%13.launching" taken
roost_pending_leave_launching "$P/%13.launching" "$P/%13.failed" died
roost_pending_take "$P/%13.failed" "$P/%13.launching" "failed died"
roost_pending_leave_launching "$P/%13.launching" "$P/%13.failed" died "store miss"
assert_eq "$(flat "$P/%13.failed")" "died|was %931|harness codex|session_id $U2|cwd /w/b|session main|window 2|order 4|note store miss" \
  "died stays the first line; the new reason is a note line after the keys"
roost_pending_leave_launching "$P/%13.launching" "$P/%13" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "leaving a .launching file that is not there: exit 1"
roost_pending_take "$P/%13.failed" "$P/%13.launching" "failed died"
printf 'origin waiting\n' >> "$P/%13.launching"
roost_pending_leave_launching "$P/%13.launching" "$P/%13.failed" "pane changed"
assert_eq "$(grep -c '^origin ' "$P/%13.failed")" "0" "every origin line goes, two of them included"
assert_eq "$(ls -a "$P" | grep -c '\.tmp')" "0" "no temp file is left beside the files"

echo "== roost_pending_state: the name and the first line give §4.7's row =="
st() { # NAME FIRSTLINE -> the state of a planted file
  local d="$SHAPE_TMP/st"; rm -rf "$d"; mkdir -p "$d"
  { [ -n "$2" ] && printf '%s\n' "$2"; printf 'was %%1\nharness claude\n'; } > "$d/$1"
  roost_pending_state "$d/$1"
}
assert_eq "$(st %7 "")" "waiting" "%N: waiting"
assert_eq "$(st %7.launching "")" "launching" "%N.launching: launching"
assert_eq "$(st %7.taken "")" "taken" "%N.taken: taken"
assert_eq "$(st %7.taken "store miss")" "taken" "%N.taken with a reason first (T15 renames without a rewrite): taken"
for r in "harness missing" "directory gone" "store miss" "duplicate of %40"; do
  assert_eq "$(st %7.failed "$r")" "failed-waiting" "%N.failed $r: failed-waiting"
done
assert_eq "$(st %7.failed died)" "failed-dead" "%N.failed died: failed-dead"
assert_eq "$(st %7.failed exited)" "failed-exited" "%N.failed exited: failed-exited"
assert_eq "$(st %7.failed interrupted)" "failed-interrupted" "%N.failed interrupted: failed-interrupted"
assert_eq "$(st %7.failed "pane changed")" "failed-changed" "%N.failed pane changed: failed-changed"
assert_eq "$(st %7.failed replaced)" "failed-replaced" "%N.failed replaced: failed-replaced"
assert_eq "$(st %7.failed "")" "failed-interrupted" "a .failed file with no reason line proves nothing: failed-interrupted (never retried)"
assert_eq "$(st %7.failed "lunch")" "failed-interrupted" "...nor one whose reason is not in the table"
roost_pending_state "$SHAPE_TMP/st/%7.other" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a name that is no state (or no file): exit 1"

# --- restore: placement writes the pending record (Task 3.3) ------------------
# `roost wiring apply` runs when restore starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
HERE="$PWD"
ROOST="$HERE/bin/roost"
PH="$HERE/scripts/roost-placeholder"
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
# The same, as a SIMPLE command for a background run: `R … &` forks a
# subshell for the function, so `$!` would be that subshell and a kill would
# leave the real restore running. `"${RB[@]}" … &` execs straight into it.
RB=(env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST")
BASH_BIN="$(command -v bash)"
TL set -g default-shell "$BASH_BIN"
export SHELL="$BASH_BIN"
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
BOOT="$(TL display -p '#{start_time}-#{pid}')"
PEND="$SD/pending/$BOOT"
CX=019a0f0f-6a8b-7c71-9d2e-0000000000c1
D1="$SHAPE_TMP/w/one.d"; D2="$SHAPE_TMP/w/two.d"; D3="$SHAPE_TMP/w/three"
mkdir -p "$D1" "$D2" "$D3"
OLDT="$SHAPE_TMP/old.jsonl"; : > "$OLDT"; touch -t 202001010000 "$OLDT"

wait_screen() { # PANE TEXT [TENTHS]
  local i=0 n="${3:-30}"
  while [ "$i" -lt "$n" ]; do
    TL capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}
wait_file() { local i=0 n="${2:-50}"; while [ "$i" -lt "$n" ]; do [ -e "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
wait_gone() { local i=0 n="${2:-100}"; while [ "$i" -lt "$n" ]; do [ -e "$1" ] || return 0; sleep 0.1; i=$((i+1)); done; return 1; }
shells_wait() { local i=0; while [ "$i" -lt 30 ]; do [ -n "$(shells_for "$1")" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
first_pane() { TL list-panes -s -t "=$1:" -F '#{pane_id}' 2>/dev/null | head -1; }
startcmd() { TL display -p -t "$1" '#{pane_start_command}' | tr -d '"\\'; }
kill_saved() { local s; for s in ka kb kst knone kgone; do TL kill-session -t "=$s" 2>/dev/null; done; return 0; }

# A shape: five sessions, one window of one pane each, in this order —
#   ka     claude U1 in a dotted directory, with an old transcript
#   kb     codex CX
#   kst    a stale claude key (exited)
#   knone  no key
#   kgone  claude U2 in a directory that is gone
mkshape() {
  local n=0
  pane_block() { # SESSION ID CWD EXTRA-LINES
    printf '%s\n' "session $1" "id \$$n" '' "window $1:1" "id @$n" "layout b25d,200x50,0,0,$n" 'active 1' '' \
      "pane $1:1.0" "id $2" "cwd $3"
    [ -n "$4" ] && printf '%s\n' "$4"
    printf '\n'
    n=$((n+1))
  }
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' \
      'saved 2026-10-28T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
    pane_block ka %930 "$D1" "harness claude
session_id $U1
transcript $OLDT"
    pane_block kb %931 "$D2" "harness codex
session_id $CX"
    pane_block kst %932 "$D3" "stale_reason exited
stale_harness claude
stale_session_id $U2"
    pane_block knone %933 "$D3" ""
    pane_block kgone %934 "$SHAPE_TMP/w/gone" "harness claude
session_id $U2"
  } > "$SD/shape"
}
mkshape

echo "== restore --no-resume: no pending file, keyed panes are shells (§4.3, Task 3.3) =="
: > "$HOME/shells.log"
R restore --no-resume >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "restore --no-resume: exit 0"
assert_eq "$(ls "$PEND" 2>/dev/null | wc -l | tr -d ' ')" "0" "...no pending file"
for s in ka kb; do
  p="$(first_pane "$s")"; shells_wait "$p"
  assert_eq "$(shells_for "$p" | wc -l | tr -d ' ')" "1" "...$s's keyed pane is a shell"
done
kill_saved

echo "== restore: every resumable keyed pane waits in a placeholder, its file first (§4.6, T3) =="
: > "$HOME/shells.log"; : > "$STUB_LOG"
HOLD="$SHAPE_TMP/loop.hold"; rm -f "$HOLD"
ROOST_TEST_LOOP_HOLD="$HOLD" "${RB[@]}" restore >/dev/null 2>"$SHAPE_TMP/err" &
RPID=$!
# Placement is over when every saved session exists and restoring/ is gone
# (the owner drops it before the hold); up to 15 s.
i=0
while [ "$i" -lt 150 ]; do
  [ -n "$(first_pane kgone)" ] && [ ! -e "$SD/restoring" ] && [ "$(ls "$PEND" 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && break
  sleep 0.1; i=$((i+1))
done
pa="$(first_pane ka)"; pb="$(first_pane kb)"
assert_eq "$(ls "$PEND" 2>/dev/null | sort | tr '\n' ' ')" "$(printf '%s\n' "$pa" "$pb" | sort | tr '\n' ' ')" \
  "pending/<boot>/ holds one file per resumable keyed pane, named by its new %N"
kill -0 "$RPID" 2>/dev/null; assert_true $? "...restore is still running: held after placement (ROOST_TEST_LOOP_HOLD)"
for p in "$pa" "$pb"; do
  case "$(startcmd "$p")" in
    *roost-placeholder\ "$PEND/$p"\ claude|*roost-placeholder\ "$PEND/$p"\ codex) r=0 ;; *) r=1 ;; esac
  assert_true $r "$p runs the placeholder by path with its file and harness ($(startcmd "$p"))"
  assert_eq "$(shells_for "$p")" "" "...no shell has started in $p"
done
wait_screen "$pa" "waiting to resume claude - press any key for a shell"
assert_true $? "the claude pane shows the waiting line (its file was there when it started)"
assert_eq "$(sed -n 's/^was //p' "$PEND/$pa")|$(sed -n 's/^harness //p' "$PEND/$pa")|$(sed -n 's/^session_id //p' "$PEND/$pa")|$(sed -n 's/^cwd //p' "$PEND/$pa")|$(sed -n 's/^session //p' "$PEND/$pa")|$(sed -n 's/^window //p' "$PEND/$pa")" \
  "%930|claude|$U1|$D1|ka|1" "the file holds the saved block's keys, session and window"
oa="$(sed -n 's/^order //p' "$PEND/$pa")"; ob="$(sed -n 's/^order //p' "$PEND/$pb")"
[ -n "$oa" ] && [ -n "$ob" ] && [ "$oa" -lt "$ob" ]; assert_true $? "order follows the shape's pane order ($oa < $ob)"
assert_eq "$(ls -l "$PEND/$pa" | cut -c1-10)" "-rw-------" "...0600"
for s in kst knone kgone; do
  p="$(first_pane "$s")"; shells_wait "$p"
  assert_eq "$(shells_for "$p" | wc -l | tr -d ' ')|$( [ -e "$PEND/$p" ] && echo file)" "1|" "$s: a shell, no pending file (stale, no key, directory gone)"
done
touch "$HOLD"; wait "$RPID"
assert_eq "$(cat "$STUB_LOG")" "" "placement launched nothing"
kill_saved; rm -f "$PEND"/*

echo "== --recent 0: an old transcript's pane is a shell, no pending file (§4.3, revision 10) =="
: > "$HOME/shells.log"
R restore --recent 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
pa="$(first_pane ka)"; pb="$(first_pane kb)"
shells_wait "$pa"
assert_eq "$(shells_for "$pa" | wc -l | tr -d ' ')|$( [ -e "$PEND/$pa" ] && echo file)" "1|" \
  "--recent 0: the pane whose transcript is old is a shell, with no file under pending/<boot>/"
ls "$PEND" | grep -q -- "^$pb\(\.\|$\)"; assert_true $? "...a pane with no transcript path is still resumed (its file is there, in whatever state the loop left it)"
R restore --recent x >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "--recent needs a number of days: usage, exit 2"
kill_saved; rm -f "$PEND"/*

echo "== §8.1 test 2 (i), the keyed half: a keyed pane taken during placement =="
: > "$HOME/shells.log"; : > "$STUB_LOG"
PHOLD="$SHAPE_TMP/place.hold"; rm -f "$PHOLD"
ROOST_TEST_PLACE_HOLD="$PHOLD" "${RB[@]}" restore --only ka >/dev/null 2>"$SHAPE_TMP/err" &
RPID=$!
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane ka)" ]; do sleep 0.1; i=$((i+1)); done
pa="$(first_pane ka)"
wait_screen "$pa" "roost restore is placing this session"
TL send-keys -t "$pa" x
shells_wait "$pa"
touch "$PHOLD"; wait "$RPID"
assert_eq "$(ls "$PEND" | tr '\n' ' ')" "$pa.taken " "its file is %N.taken, nothing waiting"
case "$(startcmd "$pa")" in *"$PEND/"*) r=1 ;; *) r=0 ;; esac
assert_true $r "...no waiting placeholder was started in it"
assert_eq "$(grep -c "roost revive $pa" "$SHAPE_TMP/err")" "1" "one stderr line names roost revive $pa"
assert_eq "$(shells_for "$pa" | wc -l | tr -d ' ')|$(cat "$STUB_LOG")" "1|" "...the person's shell, and no launch"
kill_saved; rm -f "$PEND"/*

# --- the pane side: send refuses, close cancels (Task 3.4) -------------------
echo "== roost_send_policy: §4.7's roost send column, per row =="
for row in "placing refuse allow" "placing-claimed refuse allow" "placing-taken allow allow" \
  "waiting refuse allow" "launching refuse allow" "launched refuse allow" \
  "failed-waiting refuse allow" "failed-dead refuse allow" "failed-interrupted refuse allow" \
  "failed-changed allow allow" "failed-replaced allow allow" "failed-exited allow allow" \
  "taken allow allow" "none allow allow"; do
  set -- $row
  assert_eq "$(roost_send_policy "$1" 0)|$(roost_send_policy "$1" 1)" "$2|$3" "$1: $2 without --force, $3 with it"
done

# own_pane NAME [ARGS...] -> a new window in session `own` whose pane runs the
# placeholder with ARGS (a pending file and harness, or a placing file).
TL new-session -d -s own -x 200 -y 50 'ENV= exec /bin/sh'
own_pane() {
  local p
  p="$(TL new-window -d -P -F '#{pane_id}' -t own: 'sleep 600')"
  TL set -p -t "$p" remain-on-exit failed
  TL respawn-pane -k -t "$p" "$PH" "$@"
  printf '%s\n' "$p"
}
# plant %N NAME [REASON] -> a pending file for the pane under pending/<boot>/,
# under NAME (%N, %N.launching, %N.failed, %N.taken), its reason first.
plant() {
  mkdir -p "$PEND"
  { [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'was %%900\nharness claude\nsession_id %s\ncwd %s\nsession own\nwindow 1\norder 1\n' "$U1" "$D1"; } > "$PEND/$2"
}
sendq() { R send "$@" </dev/null >/dev/null 2>"$SHAPE_TMP/serr"; }

echo "== send and answer refuse the rows the table refuses; the file is unchanged =="
: > "$HOME/shells.log"
# Each refused row: a pane, its file, then send and answer.
refused_row() { # STATE PANE FILE-NAME
  sendq "$2" hello; rc=$?
  assert_eq "$rc" "3" "$1: send is refused with the blocked-target exit code (3)"
  assert_contains "$(cat "$SHAPE_TMP/serr")" "$1" "...and the message names the state"
  [ -e "$3" ]; assert_true $? "...the file is unchanged ($3)"
  R answer "$2" --deny </dev/null >/dev/null 2>"$SHAPE_TMP/aerr"; rc=$?
  assert_eq "$rc" "3" "$1: answer is refused the same way, before any dialog lookup"
  assert_contains "$(cat "$SHAPE_TMP/aerr")" "$1" "...naming the state"
}
p="$(TL new-window -d -P -F '#{pane_id}' -t own: 'sleep 600')"; plant "$p" "$p"
TL set -p -t "$p" remain-on-exit failed; TL respawn-pane -k -t "$p" "$PH" "$PEND/$p" claude
wait_screen "$p" "waiting to resume claude"
refused_row waiting "$p" "$PEND/$p"
assert_eq "$(shells_for "$p")" "" "§8.1 test 11 (f): the waiting placeholder took no key, and the file is still %N"
WP="$p"
p="$(TL new-window -d -P -F '#{pane_id}' -t own: 'sleep 600')"; plant "$p" "$p.launching"
TL set -p -t "$p" remain-on-exit failed; TL respawn-pane -k -t "$p" "$PH" "$PEND/$p" claude
wait_screen "$p" "resuming claude now"
refused_row launching "$p" "$PEND/$p.launching"
TL kill-pane -t "$p"
for r in "failed-waiting|store miss" "failed-interrupted|interrupted"; do
  p="$(TL new-window -d -P -F '#{pane_id}' -t own: 'sleep 600')"; plant "$p" "$p.failed" "${r#*|}"
  TL set -p -t "$p" remain-on-exit failed; TL respawn-pane -k -t "$p" "$PH" "$PEND/$p" claude
  wait_screen "$p" "claude was not resumed"
  refused_row "${r%%|*}" "$p" "$PEND/$p.failed"
  TL kill-pane -t "$p"
done
p="$(TL new-window -d -P -F '#{pane_id}' -t own: 'sleep 600')"
TL set -p -t "$p" remain-on-exit failed; TL respawn-pane -k -t "$p" 'exit 3'
i=0; while [ "$i" -lt 30 ] && [ "$(TL display -p -t "$p" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
plant "$p" "$p.failed" died
refused_row failed-dead "$p" "$PEND/$p.failed"
R answer --force "$p" --deny </dev/null >/dev/null 2>"$SHAPE_TMP/aerr"; rc=$?
assert_eq "$rc" "2" "answer --force to a failed, dead pane: today's dead-pane refusal (exit 2) — --force bypassed only the new check"
FD="$p"
R answer --force "$WP" --deny </dev/null >/dev/null 2>"$SHAPE_TMP/aerr"; rc=$?
assert_eq "$rc" "6" "answer --force to the waiting row: today's 'not blocked … nothing to answer' (exit 6)"
assert_contains "$(cat "$SHAPE_TMP/aerr")" "is not blocked" "...in today's words"

echo "== the rows the table allows: as for any pane =="
for r in "taken|" "failed-changed|pane changed" "failed-replaced|replaced"; do
  st="${r%%|*}"; sfx=".${st#failed-}"; [ "$st" = taken ] || sfx=.failed
  p="$(TL new-window -d -P -F '#{pane_id}' -t own: -c "$SHAPE_TMP" 'ENV= exec /bin/sh')"; plant "$p" "$p$sfx" "${r#*|}"
  sendq "$p" "echo SENT-$st"; rc=$?
  assert_eq "$rc" "0" "$st: send delivers as to any pane"
  wait_screen "$p" "SENT-$st"; assert_true $? "...and the text reached the pane"
  TL kill-pane -t "$p"
done
# A shell taken during a placement that has since finished: its placing line
# survives the exec, and no restoring/ file has it in any name -> no file.
FF="$SD/restoring/place.gone-run.1"; mkdir -p "$SD/restoring"; : > "$FF"
p="$(own_pane "$FF" --placing)"; wait_screen "$p" "placing this session"
TL send-keys -t "$p" x; shells_wait "$p"; rm -rf "$SD/restoring"
sendq "$p" "echo SENT-finished"; rc=$?
assert_eq "$rc" "0" "a shell taken in a placement that has finished: send delivers as to any pane"
TL kill-pane -t "$p"

echo "== the placing rows, under Part 1's seams =="
PHOLD="$SHAPE_TMP/p.hold"; UHOLD="$SHAPE_TMP/u.hold"; rm -f "$PHOLD" "$UHOLD"
ROOST_TEST_PLACE_HOLD="$PHOLD" "${RB[@]}" restore --no-resume --only knone >/dev/null 2>&1 &
RPID=$!
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane knone)" ]; do sleep 0.1; i=$((i+1)); done
p="$(first_pane knone)"; wait_screen "$p" "placing this session"
sendq "$p" hello; rc=$?
assert_eq "$rc" "3" "placing: send is refused (exit 3)"
assert_eq "$(shells_for "$p")" "" "...and nothing reached the placeholder"
touch "$PHOLD"; wait "$RPID"; kill_saved
ROOST_TEST_PLACE_HOLD_AFTER_USED="$UHOLD" "${RB[@]}" restore --no-resume --only knone >/dev/null 2>&1 &
RPID=$!
i=0; while [ "$i" -lt 50 ] && [ -z "$(ls "$SD/restoring" 2>/dev/null | grep '\.used$')" ]; do sleep 0.1; i=$((i+1)); done
p="$(first_pane knone)"
sendq "$p" hello; rc=$?
assert_eq "$rc" "3" "placing, claimed (F.used): send is refused (exit 3)"
touch "$UHOLD"; wait "$RPID"; kill_saved

echo "== send --force to the waiting row: the placeholder takes it as a key (T6) =="
sendq --force "$WP" hello
i=0; while [ "$i" -lt 50 ] && [ ! -e "$PEND/$WP.taken" ]; do sleep 0.1; i=$((i+1)); done
[ -e "$PEND/$WP.taken" ]; assert_true $? "the ownership refusal is bypassed: the file is %N.taken"
shells_wait "$WP"; assert_eq "$(shells_for "$WP" | wc -l | tr -d ' ')" "1" "...and a shell started in the pane"
TL kill-pane -t "$WP"

echo "== forced delivery into a real dialog: a launched pane (§4.7, launched) =="
if command -v python3 >/dev/null 2>&1; then
  HOOK="$HERE/scripts/roost-agent-state"
  python3 - "$SHAPE_TMP/payload" "$SHAPE_TMP/tr.jsonl" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({"session_id": "00000000-0000-4000-8000-000000001422",
  "transcript_path": sys.argv[2], "cwd": "/tmp/roost-fixture/proj", "prompt_id": "00000000-0000-4000-8000-0000000014a2",
  "permission_mode": "default", "hook_event_name": "PermissionRequest",
  "tool_name": "Bash", "tool_input": {"command": "mkdir build-x", "description": "x"}, "permission_suggestions": []}))
PY
  : > "$SHAPE_TMP/tr.jsonl"
  # The dialog stand-in of tests/test-answer.sh, `state` mode: stamps 🛑
  # through the real hook, draws the marker lines, logs each key as hex.
  cat > "$SHAPE_TMP/dialog" <<EOF
#!/bin/sh
: > "$SHAPE_TMP/keys"
"$HOOK" working </dev/null
"$HOOK" blocked --permission-request-hook < "$SHAPE_TMP/payload"
printf '\033[2J\033[H Bash command\n\n   mkdir build-x\n\n Do you want to proceed?\n > 1. Yes\n   2. Yes, and always allow access\n   3. No\n\n Esc to cancel - Tab to amend\n'
stty raw -echo 2>/dev/null
while :; do
  k="\$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ -n "\$k" ] || continue
  printf '%s\n' "\$k" >> "$SHAPE_TMP/keys"
  printf '\033[2J\033[H (the dialog has closed)\n'; "$HOOK" working </dev/null
done
EOF
  chmod +x "$SHAPE_TMP/dialog"
  TL set -g @roost-notify-backend none
  p="$(TL new-window -d -P -F '#{pane_id}' -t own: "$SHAPE_TMP/dialog")"
  i=0; while [ "$i" -lt 100 ]; do
    [ "$(TL show -pqv -t "$p" @agent_state)" = blocked ] && TL capture-pane -p -t "$p" | grep -q 'Esc to cancel' && break
    sleep 0.05; i=$((i+1))
  done
  plant "$p" "$p.launching"
  fp="$(R status --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
p = [x for x in d["panes"] if x["id"] == sys.argv[1]][0]
print(p["dialog"]["fingerprint"])' "$p" 2>/dev/null)"
  [ -n "$fp" ]; assert_true $? "(fixture) status --json gives the launched pane's dialog fingerprint"
  R answer --expect "$fp" "$p" --approve </dev/null >/dev/null 2>"$SHAPE_TMP/aerr"; rc=$?
  assert_eq "$rc|$(cat "$SHAPE_TMP/keys")" "3|" "answer --approve without --force: the ownership refusal, and no key logged"
  R answer --force --expect "$fp" "$p" --approve </dev/null >/dev/null 2>"$SHAPE_TMP/aerr"; rc=$?
  assert_eq "$rc|$(cat "$SHAPE_TMP/keys")" "0|31" "answer --force --approve: the key is delivered and logged"
  TL kill-pane -t "$p"; rm -f "$PEND/$p.launching"
else
  echo "  SKIP: python3 not available (the dialog payload is built with it)"
fi

echo "== §8.1 test 11: close on a waiting pane cancels its resume with kill-pane (T19) =="
: > "$HOME/shells.log"
for r in "%|" ".failed|store miss" ".failed|died"; do
  p="$(TL new-window -d -P -F '#{pane_id}' -t own: 'sleep 600')"
  sfx="${r%%|*}"; [ "$sfx" = % ] && sfx=""
  plant "$p" "$p$sfx" "${r#*|}"
  TL set -p -t "$p" remain-on-exit failed
  if [ "${r#*|}" = died ]; then
    TL respawn-pane -k -t "$p" 'exit 3'
    i=0; while [ "$i" -lt 30 ] && [ "$(TL display -p -t "$p" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
  else
    TL respawn-pane -k -t "$p" "$PH" "$PEND/$p" claude; wait_screen "$p" "claude"
  fi
  R close "$p" </dev/null >/dev/null 2>"$SHAPE_TMP/cerr"; rc=$?
  assert_eq "$rc|$(cat "$SHAPE_TMP/cerr")" "0|" "close on $p$sfx (${r#*|}): exit 0, nothing on stderr"
  assert_eq "$(TL list-panes -a -F '#{pane_id}' | grep -cx -- "$p")" "0" "...the pane is gone"
  assert_eq "$(ls "$PEND" | grep -c -- "^$p\(\.\|$\)")" "0" "...its pending file removed"
  assert_eq "$(shells_for "$p")" "" "...and no shell ever started in it (kill-pane, not a key)"
done
TL kill-pane -t "$FD" 2>/dev/null; rm -f "$PEND/$FD.failed"
TL kill-session -t '=own'

# --- the resume engine (Task 3.5) ---------------------------------------------
# A codex store for this section; the canary still guards the rest.
export CODEX_HOME="$SHAPE_TMP/h-codex"
mkdir -p "$CODEX_HOME/sessions/2026/10/31"
: > "$CODEX_HOME/sessions/2026/10/31/rollout-2026-10-31T08-00-00-$CX.jsonl"
U3=3fa3c0de-3333-4abc-8def-000000000003
U4=3fa3c0de-4444-4abc-8def-000000000004
U5=3fa3c0de-5555-4abc-8def-000000000005
U6=3fa3c0de-6666-4abc-8def-000000000006
U7=3fa3c0de-7777-4abc-8def-000000000007
U8=3fa3c0de-8888-4abc-8def-000000000008
U9=3fa3c0de-9999-4abc-8def-000000000009
U10=3fa3c0de-aaaa-4abc-8def-00000000000a
REPO="$SHAPE_TMP/w/repo.d"; WT="$REPO/.claude/worktrees/w1"; mkdir -p "$WT"
# tfile ID -> the stub store's transcript path for ID (stub_store_add's).
tfile() { ls "$CLAUDE_CONFIG_DIR"/projects/*/"$1.jsonl" 2>/dev/null | head -1; }
for u in "$U1" "$U3" "$U8" "$U9" "$U10"; do stub_store_add "$u" "$D1"; done
# U4: filed under the WORKTREE's folder, its first cwd the repository root
# (Task 2.2's worktree case): the resume runs in the root.
f4d="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$WT" | tr '/.' '--')"; mkdir -p "$f4d"
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$REPO" "$U4" > "$f4d/$U4.jsonl"
# U5: its first cwd removed since.
stub_store_add "$U5" "$SHAPE_TMP/w/removed"
# U6: a cwd holding a JSON escape: refused, not decoded.
f6d="$CLAUDE_CONFIG_DIR/projects/-x6"; mkdir -p "$f6d"
printf '{"cwd":"/a\\\\b","sessionId":"%s"}\n' "$U6" > "$f6d/$U6.jsonl"
# U7: two cwd values on one line: the first.
f7d="$CLAUDE_CONFIG_DIR/projects/-x7"; mkdir -p "$f7d"
printf '{"cwd":"%s","parent":{"cwd":"%s"}}\n' "$D2" "$D3" > "$f7d/$U7.jsonl"

# shape_of BLOCK... -> $SD/shape: one session per BLOCK, "SESSION|%OLD|CWD|K V;K V",
# each one window (index 1) of one pane.
shape_of() {
  local b n=0 se id cw ex
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' \
      'saved 2026-10-28T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
    for b in "$@"; do
      IFS='|' read -r se id cw ex <<< "$b"
      printf '%s\n' "session $se" "id \$$n" '' "window $se:1" "id @$n" "layout b25d,200x50,0,0,$n" 'active 1' '' \
        "pane $se:1.0" "id $id" "cwd $cw"
      [ -n "$ex" ] && printf '%s\n' "$ex" | tr ';' '\n'
      printf '\n'
      n=$((n+1))
    done; } > "$SD/shape"
}
kill_sess() { local s; for s in "$@"; do TL kill-session -t "=$s" 2>/dev/null; done; return 0; }
reset_run() { : > "$STUB_LOG"; : > "$HOME/shells.log"; rm -rf "$PEND" "$XDG_STATE_HOME/roost/launch-claims"; }
logline() { grep -- "$1" "$STUB_LOG" | head -1; }
wait_log() { local i=0; while [ "$i" -lt "${2:-100}" ]; do grep -q -- "$1" "$STUB_LOG" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

echo "== §8.1 test 4: the resume runs in its directory, agents --pace apart, shells first =="
reset_run
shape_of "r1|%940|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")" \
         "r2|%941|$D1|harness claude;session_id $U3;transcript $(tfile "$U3")" \
         "r3|%942|$D3|harness codex;session_id $CX;session_cwd $D2" \
         "r4|%943|$D3|"
HOLD="$SHAPE_TMP/loop2.hold"; rm -f "$HOLD"
ROOST_TEST_LOOP_HOLD="$HOLD" "${RB[@]}" restore --pace 2 >/dev/null 2>"$SHAPE_TMP/err" &
RPID=$!
i=0; while [ "$i" -lt 150 ]; do [ -n "$(first_pane r4)" ] && [ ! -e "$SD/restoring" ] && break; sleep 0.1; i=$((i+1)); done
p4="$(first_pane r4)"; shells_wait "$p4"
assert_eq "$(shells_for "$p4" | wc -l | tr -d ' ')|$(cat "$STUB_LOG")" "1|" "shells are placed before any agent: the shell pane has its shell, nothing launched yet"
touch "$HOLD"; wait "$RPID"; rc=$?
assert_eq "$rc" "0" "restore: exit 0 (every agent launched)"
assert_eq "$(wc -l < "$STUB_LOG" | tr -d ' ')" "3" "three launches, one per keyed pane"
assert_eq "$(logline "$U1" | cut -d' ' -f2-)" "$D1 claude --resume $U1" "claude: --resume <id> in the transcript's first cwd (a dotted path)"
assert_eq "$(logline "$U3" | cut -d' ' -f2-)" "$D1 claude --resume $U3" "a sibling in the same directory gets its own --resume"
assert_eq "$(logline "$CX" | cut -d' ' -f2-)" "$D2 codex resume $CX" "codex: codex resume <id> in its session_cwd (the shell cwd is the fallback)"
t1="$(sed -n 1p "$STUB_LOG" | cut -d' ' -f1)"; t2="$(sed -n 2p "$STUB_LOG" | cut -d' ' -f1)"; t3="$(sed -n 3p "$STUB_LOG" | cut -d' ' -f1)"
[ $((t2 - t1)) -ge 2 ] && [ $((t3 - t2)) -ge 2 ]; assert_true $? "--pace 2: launches at least 2 s apart ($t1 $t2 $t3)"
assert_eq "$(sed -n 1p "$STUB_LOG" | grep -c "$U1")$(sed -n 3p "$STUB_LOG" | grep -c "$CX")" "11" "...in the shape's pane order"
p1="$(first_pane r1)"
assert_eq "$(TL display -p -t "$p1" '#{pane_current_command}')|$(ls "$PEND" | grep -c "^$p1.launching$")" "claude|1" \
  "the pane now runs the resume, its file %N.launching until identity lands (Part 3's later tasks)"
assert_eq "$(TL show -pqv -t "$p1" remain-on-exit)" "failed" "...under remain-on-exit failed"
kill_sess r1 r2 r3 r4

echo "== --no-resume, --recent, --only =="
reset_run
R restore --no-resume >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(cat "$STUB_LOG")" "0|" "--no-resume: exit 0, no run"
kill_sess r1 r2 r3 r4
reset_run
touch -t 202001010000 "$(tfile "$U1")"
shape_of "o1|%950|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
R restore --recent 0 >/dev/null 2>&1
assert_eq "$(cat "$STUB_LOG")" "" "--recent 0 with an old transcript: no run"
po="$(first_pane o1)"
R restore --resume --pace 1 >/dev/null 2>&1; sleep 2
assert_eq "$(cat "$STUB_LOG")|$(TL display -p -t "$po" '#{pane_current_command}')" "|bash" \
  "--recent holds at the next attach (worker-only): restore --resume, two --pace intervals, still nothing run and the pane still that shell"
kill_sess o1
touch "$(tfile "$U1")"
reset_run
shape_of "r1|%940|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")" \
         "r2|%941|$D1|harness claude;session_id $U3;transcript $(tfile "$U3")"
R restore --only r2 --pace 0 >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(wc -l < "$STUB_LOG" | tr -d ' ')|$(grep -c "$U3" "$STUB_LOG")" "0|1|1" "--only SESSION: one session placed, one agent run"
kill_sess r1 r2

echo "== §5.1: the directory rule, through the engine =="
reset_run
shape_of "d1|%960|$D3|harness claude;session_id $U4;transcript $f4d/$U4.jsonl" \
         "d2|%961|$D3|harness codex;session_id $CX" \
         "d3|%962|$D3|harness claude;session_id $U5;transcript $(tfile "$U5")" \
         "d4|%963|$D3|harness claude;session_id $U6;transcript $f6d/$U6.jsonl" \
         "d5|%964|$D3|harness claude;session_id $U7;transcript $f7d/$U7.jsonl"
R restore --pace 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a pane not resumed for a listed reason: exit 13"
assert_eq "$(logline "$U4" | cut -d' ' -f2-)" "$REPO claude --resume $U4" "a transcript filed under the worktree's folder, first cwd the repository root: run in the root"
assert_eq "$(logline "$CX" | cut -d' ' -f2-)" "$D3 codex resume $CX" "codex with no session_cwd: the shell cwd"
assert_eq "$(logline "$U7" | cut -d' ' -f2-)" "$D2 claude --resume $U7" "two cwd values on one line: the first"
p3="$(first_pane d3)"; p4="$(first_pane d4)"
assert_eq "$(grep -c "$U5\|$U6" "$STUB_LOG")" "0" "a removed directory and a refused one: not run"
assert_eq "$(head -1 "$PEND/$p3.failed" 2>/dev/null)|$(head -1 "$PEND/$p4.failed" 2>/dev/null)" "directory gone|directory gone" \
  "...each %N.failed directory gone"
wait_screen "$p3" "claude was not resumed: directory gone" 70; assert_true $? "...and its placeholder shows the reason, with no respawn"
assert_contains "$(cat "$SHAPE_TMP/err")" "$p3 (was %962): claude $U5 not resumed: directory gone" "...named on stderr"
kill_sess d1 d2 d3 d4 d5

echo "== duplicate, store miss, a gone cwd with a key, a pane saved working =="
reset_run
shape_of "u1|%970|$D1|harness claude;session_id $U1;transcript $(tfile "$U1");state working" \
         "u2|%971|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")" \
         "u3|%972|$D1|harness claude;session_id $U2;transcript $SHAPE_TMP/nope.jsonl" \
         "u4|%973|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
R restore --pace 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
q1="$(first_pane u1)"; q2="$(first_pane u2)"; q3="$(first_pane u3)"; q4="$(first_pane u4)"
assert_eq "$rc" "13" "a duplicate and a store miss: exit 13"
assert_eq "$(grep -c "$U1" "$STUB_LOG")" "1" "duplicate: the first launched, once"
assert_eq "$(head -1 "$PEND/$q2.failed" 2>/dev/null)" "duplicate of $q1" "...the second %N.failed duplicate of %M"
# Three panes carrying one key, in ONE run: the loop is one process with one
# owner record, so its own claim for the first pane must refuse the third
# too (the same-run case roost_resume_claim now judges by pane).
assert_eq "$(head -1 "$PEND/$q4.failed" 2>/dev/null)" "duplicate of $q1" "...and a third carrying the same key, the same"
wait_screen "$q2" "claude was not resumed: duplicate of $q1" 70; assert_true $? "...showing it"
assert_eq "$(head -1 "$PEND/$q3.failed" 2>/dev/null)" "store miss" "store miss: %N.failed store miss"
case "$(startcmd "$q3")" in *roost-placeholder*) r=0 ;; *) r=1 ;; esac
assert_true $r "...still the placeholder"
assert_contains "$(cat "$SHAPE_TMP/err")" "were working or blocked at the save — re-prompt by hand: $q1" "a pane saved state working is named in the report"
kill_sess u1 u2 u3 u4
reset_run
shape_of "g1|%980|$SHAPE_TMP/w/gone|harness claude;session_id $U1;transcript $(tfile "$U1")"
R restore --pace 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(cat "$STUB_LOG")" "13|" "§8.1 test 3b: a gone cwd with a key: exit 13, nothing run"
assert_contains "$(cat "$SHAPE_TMP/err")" "not resumed: directory gone" "...named"
kill_sess g1

echo "== §8.1 test 11 (a) (b) (c), worker-only: keys and a respawn during the pace =="
# Placement with no loop: a restore held after placement is killed there, so
# the pending files and their placeholders wait as an --at-login placement
# leaves them (Part 5). Then `restore --resume` is the worker (no hook here).
reset_run
shape_of "w1|%990|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")" \
         "w2|%991|$D1|harness claude;session_id $U3;transcript $(tfile "$U3")" \
         "w3|%992|$D1|harness claude;session_id $U8;transcript $(tfile "$U8")" \
         "w4|%993|$D1|harness claude;session_id $U9;transcript $(tfile "$U9")" \
         "w5|%994|$D1|harness claude;session_id $U10;transcript $(tfile "$U10")"
HOLD="$SHAPE_TMP/loop3.hold"; rm -f "$HOLD"
ROOST_TEST_LOOP_HOLD="$HOLD" "${RB[@]}" restore >/dev/null 2>&1 &
RPID=$!
i=0; while [ "$i" -lt 150 ]; do [ "$(ls "$PEND" 2>/dev/null | wc -l | tr -d ' ')" = 5 ] && [ ! -e "$SD/restoring" ] && break; sleep 0.1; i=$((i+1)); done
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
v2="$(first_pane w2)"; v3="$(first_pane w3)"; v4="$(first_pane w4)"
for v in "$v2" "$v3"; do wait_screen "$v" "waiting to resume claude"; done
pid2="$(TL display -p -t "$v2" '#{pane_pid}')"; pid3="$(TL display -p -t "$v3" '#{pane_pid}')"
"${RB[@]}" restore --resume --pace 6 >/dev/null 2>"$SHAPE_TMP/err" &
WPID=$!
wait_log "$U1" 100; assert_true $? "(the worker launched the first agent)"
# (a) typed text then C-a; (b) a command and Enter; (c) a respawn by hand.
TL send-keys -t "$v2" -l 'echo keep-me'; TL send-keys -t "$v2" C-a
TL send-keys -t "$v3" -l 'sleep 60'; TL send-keys -t "$v3" Enter
TL respawn-pane -k -t "$v4" 'sh'
sleep 0.3
spid4="$(TL display -p -t "$v4" '#{pane_pid}')"; scmd4="$(TL display -p -t "$v4" '#{pane_current_command}')"
wait "$WPID"; rc=$?
assert_eq "$rc" "13" "the worker: exit 13 (one pane changed)"
assert_eq "$(wc -l < "$STUB_LOG" | tr -d ' ')|$(grep -c "$U3\|$U8\|$U9" "$STUB_LOG")" "2|0" "two launches: the first and the last; the taken and the changed panes never"
[ -e "$PEND/$v2.taken" ]; assert_true $? "(a) echo keep-me + C-a: %N.taken"
shells_wait "$v2"
assert_eq "$(TL display -p -t "$v2" '#{pane_pid}')" "$pid2" "(a) ...the same pane_pid (the placeholder exec'd the shell)"
TL send-keys -t "$v2" -l 'echo LINE-WAS-['; TL send-keys -t "$v2" C-e; TL send-keys -t "$v2" -l ']'; TL send-keys -t "$v2" Enter
wait_screen "$v2" 'LINE-WAS-[]' 30; assert_true $? "(a) ...and an empty line: keep-me never reached the shell"
[ -e "$PEND/$v3.taken" ]; assert_true $? "(b) sleep 60 + Enter: %N.taken"
shells_wait "$v3"; sleep 0.5
assert_eq "$(TL display -p -t "$v3" '#{pane_pid}')|$(TL display -p -t "$v3" '#{pane_current_command}')" "$pid3|bash" "(b) ...the same pane_pid, and sleep never ran"
assert_eq "$(head -1 "$PEND/$v4.failed" 2>/dev/null)" "pane changed" "(c) respawned by hand before its turn: %N.failed pane changed"
assert_eq "$(TL display -p -t "$v4" '#{pane_pid}')|$(TL display -p -t "$v4" '#{pane_current_command}')" "$spid4|$scmd4" "(c) ...the sh untouched (on macOS /bin/sh reads as bash)"
kill_sess w1 w2 w3 w4 w5

echo "== §8.1 test 11 (e), worker-only: a key after .launching waits to be replaced =="
reset_run
shape_of "e1|%995|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
HOLD="$SHAPE_TMP/loop4.hold"; rm -f "$HOLD"
ROOST_TEST_LOOP_HOLD="$HOLD" "${RB[@]}" restore >/dev/null 2>&1 &
RPID=$!
i=0; while [ "$i" -lt 150 ]; do [ "$(ls "$PEND" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ ! -e "$SD/restoring" ] && break; sleep 0.1; i=$((i+1)); done
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
ve="$(first_pane e1)"; wait_screen "$ve" "waiting to resume claude"
RH="$SHAPE_TMP/resume.hold"; rm -f "$RH"
ROOST_TEST_RESUME_HOLD="$RH" "${RB[@]}" restore --resume >/dev/null 2>&1 &
WPID=$!
wait_file "$PEND/$ve.launching" 50
TL send-keys -t "$ve" x
wait_screen "$ve" "resuming claude now" 70; assert_true $? "(e) a key after .launching: the screen says resuming claude now"
sleep 0.5
assert_eq "$(shells_for "$ve")" "" "(e) ...and no shell started"
touch "$RH"; wait "$WPID"; rc=$?
wait_log "$U1" 50; assert_true $? "(e) the resume replaces it (exit $rc)"
assert_eq "$(TL display -p -t "$ve" '#{pane_current_command}')" "claude" "(e) ...the pane now runs the harness"
kill_sess e1

# --- identity lands: T11, T12, T18 (Task 3.7) ---------------------------------
CLB="$XDG_STATE_HOME/roost/launch-claims/roost/claims/$BOOT"
claim_of() { [ -e "$CLB/claude-$1/owner" ] || [ -L "$CLB/claude-$1/owner" ] && echo held; }
wait_gone2() { local i=0; while [ "$i" -lt 80 ]; do [ -e "$1" ] || return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# The stub reads STUB_IDENTIFY / STUB_IDENTIFY_AS from the pane's environment,
# which a respawned pane takes from the server's global environment.
echo "== T11: identity lands with the same id: the .launching file and the claim go =="
reset_run
TL set-environment -g STUB_IDENTIFY 1
shape_of "i1|%996|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
R restore --pace 0 >/dev/null 2>&1
pi1="$(first_pane i1)"
wait_log "$U1" 50
wait_gone2 "$PEND/$pi1.launching"; assert_true $? "the stub identified with the same id: %N.launching removed (T11)"
assert_eq "$(ls "$PEND" | grep -c "^$pi1")|$(claim_of "$U1")" "0|" "...no file in any name, and the claim released"
assert_eq "$(TL show -pqv -t "$pi1" @roost-session)" "$U1" "...the live @roost-session is the owner now"
echo "== an identify that changes nothing does not touch pending (the one-read bail) =="
plant "$pi1" "$pi1.launching"
env TMUX="$SHAPE_SOCK,1,0" TMUX_PANE="$pi1" "$ROOST" identify --session "$U1" --cwd "$(TL show -pqv -t "$pi1" @roost-cwd)" --harness claude >/dev/null 2>&1
assert_eq "$(TL show -pqv -t "$pi1" @roost-session)|$( [ -e "$PEND/$pi1.launching" ] && echo kept)" "$U1|kept" \
  "the same identity again: nothing written, so the planted file is left alone"
rm -f "$PEND/$pi1.launching"
kill_sess i1
TL set-environment -gu STUB_IDENTIFY

echo "== T12: identity lands with a different id: %N.failed replaced, the claim released =="
reset_run
TL set-environment -g STUB_IDENTIFY_AS "$U3"
shape_of "i2|%997|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
R restore --pace 0 >/dev/null 2>&1
pi2="$(first_pane i2)"
wait_file "$PEND/$pi2.failed" 80
assert_eq "$(head -1 "$PEND/$pi2.failed" 2>/dev/null)|$( [ -e "$PEND/$pi2.launching" ] && echo left)|$(claim_of "$U1")" "replaced||" \
  "another conversation landed: %N.failed replaced (T12), no .launching, the claim released"
assert_eq "$(grep -c '^origin' "$PEND/$pi2.failed")" "0" "...and no origin line left in it"
kill_sess i2
TL set-environment -gu STUB_IDENTIFY_AS

echo "== §8.1 test 11, T18: a taken pane where a person starts an agent =="
reset_run
shape_of "i3|%998|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
HOLD="$SHAPE_TMP/loop5.hold"; rm -f "$HOLD"
ROOST_TEST_LOOP_HOLD="$HOLD" "${RB[@]}" restore >/dev/null 2>&1 &
RPID=$!
i=0; while [ "$i" -lt 150 ]; do [ "$(ls "$PEND" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && [ ! -e "$SD/restoring" ] && break; sleep 0.1; i=$((i+1)); done
pi3="$(first_pane i3)"; wait_screen "$pi3" "waiting to resume claude"
TL send-keys -t "$pi3" x; wait_file "$PEND/$pi3.taken" 50; shells_wait "$pi3"
touch "$HOLD"; wait "$RPID"
TL send-keys -t "$pi3" "STUB_IDENTIFY=1 claude --resume $U3" Enter
wait_gone2 "$PEND/$pi3.taken"; assert_true $? "an agent started by hand in a taken pane identifies: %N.taken removed (T18)"
kill_sess i3

# --- --retry, the worker's takeover, T8b (Task 3.6), worker-only -------------
U11=3fa3c0de-bbbb-4abc-8def-00000000000b
U12=3fa3c0de-cccc-4abc-8def-00000000000c
U13=3fa3c0de-dddd-4abc-8def-00000000000d
# place_only N — placement with no loop: a restore held after placement is
# killed there, leaving N pending files and their placeholders as an
# --at-login placement would (Part 5). `restore --resume` is then the worker.
place_only() {
  local h="$SHAPE_TMP/po.hold" pid i=0
  rm -f "$h"
  ROOST_TEST_LOOP_HOLD="$h" "${RB[@]}" restore >/dev/null 2>&1 &
  pid=$!
  while [ "$i" -lt 150 ]; do
    [ "$(ls "$PEND" 2>/dev/null | wc -l | tr -d ' ')" = "$1" ] && [ ! -e "$SD/restoring" ] && break
    sleep 0.1; i=$((i+1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 0
}
dead_after() { local i=0; while [ "$i" -lt 50 ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done; return 1; }

echo "== retry recovers (A); a .failed file is retried only with --retry =="
reset_run
TL set-environment -g STUB_IDENTIFY 1
shape_of "x1|%1001|$D1|harness claude;session_id $U11"
place_only 1
px="$(first_pane x1)"
R restore --resume >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(head -1 "$PEND/$px.failed" 2>/dev/null)" "13|store miss" "(fixture) the store does not hold it: exit 13, %N.failed store miss"
stub_store_add "$U11" "$D1"
R restore --resume >/dev/null 2>&1
assert_eq "$(cat "$STUB_LOG")|$( [ -e "$PEND/$px.failed" ] && echo failed)" "|failed" "the store repaired, a plain --resume: nothing launched, still .failed (only --retry retries)"
R restore --resume --retry >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(grep -c "$U11" "$STUB_LOG")" "0|1" "(A) --retry: launched once more, exit 0"
assert_eq "$(TL display -p -t "$px" '#{pane_dead}')" "0" "(A) ...pane_dead 0"
wait_gone2 "$PEND/$px.launching"; assert_eq "$(ls "$PEND" | grep -c "^$px")" "0" "(A) ...and the file gone once the stub identified"
kill_sess x1
TL set-environment -gu STUB_IDENTIFY

echo "== (C) a failed pane taken and running a job; (D) pane changed: --retry launches nothing =="
reset_run
shape_of "x2|%1002|$D1|harness claude;session_id $U12" "x3|%1003|$D1|harness claude;session_id $U13"
place_only 2
pc="$(first_pane x2)"; pd="$(first_pane x3)"
TL respawn-pane -k -t "$pd" 'sleep 300'
# U13 is in the store, so x3 passes every read-only check and fails at the
# pane (T9); U12 is not, so x2 fails first (store miss) and is then taken.
stub_store_add "$U13" "$D1"
R restore --resume >/dev/null 2>&1
wait_screen "$pc" "claude was not resumed: store miss" 70
TL send-keys -t "$pc" x; wait_file "$PEND/$pc.taken" 50; shells_wait "$pc"
TL send-keys -t "$pc" 'sleep 60' Enter; i=0; while [ "$i" -lt 30 ] && [ "$(TL display -p -t "$pc" '#{pane_current_command}')" != sleep ]; do sleep 0.1; i=$((i+1)); done
stub_store_add "$U12" "$D1"
assert_eq "$(head -1 "$PEND/$pd.failed" 2>/dev/null)" "pane changed" "(D) (fixture) respawned by hand: %N.failed pane changed"
R restore --resume --retry >/dev/null 2>&1
assert_eq "$(cat "$STUB_LOG")" "" "--retry launches nothing for a taken pane (C) or a changed one (D)"
assert_eq "$(TL display -p -t "$pc" '#{pane_current_command}')|$(TL display -p -t "$pd" '#{pane_current_command}')" "sleep|sleep" \
  "...both sleeps alive"
kill_sess x2 x3

echo "== a crashed placeholder is died (T13a's result), and --retry reaches it (review round 1, Fable N2) =="
reset_run
U16=3fa3c0de-1616-4abc-8def-000000000016; stub_store_add "$U16" "$D1"
shape_of "x7|%1007|$D1|harness claude;session_id $U16"
place_only 1
pc7="$(first_pane x7)"; wait_screen "$pc7" "waiting to resume claude"
kill -9 "$(TL display -p -t "$pc7" '#{pane_pid}')"
i=0; while [ "$i" -lt 30 ] && [ "$(TL display -p -t "$pc7" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$(TL display -p -t "$pc7" '#{pane_dead}')|$(ls "$PEND" | grep "^$pc7")" "1|$pc7" "(fixture) the placeholder crashed: a dead pane, its file still %N"
R restore --resume >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(head -1 "$PEND/$pc7.failed" 2>/dev/null)|$(grep -c "$U16" "$STUB_LOG")" "13|died|0" \
  "the worker finds it dead with its own placeholder line: %N.failed died, not pane changed"
R restore --resume --retry >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(grep -c "$U16" "$STUB_LOG")|$(TL display -p -t "$pc7" '#{pane_dead}')" "0|1|0" "...which --retry relaunches in place (T16)"
kill_sess x7

echo "== --retry checks the pane again: a failed pane a person replaced since (T14 then T9) =="
# The retry arrow (T14) is no pass: the loop then makes the check of the
# state it came from (§4.6 step 4). A failed, waiting pane that a person
# respawned with their own command AFTER the failure has the key in the store
# by now, so every read-only check passes, and only that pane check keeps the
# person's command alive (test 11, retry D's shape).
reset_run
U15=3fa3c0de-ffff-4abc-8def-00000000000f
shape_of "x8|%1008|$D1|harness claude;session_id $U15"
place_only 1
pr="$(first_pane x8)"
R restore --resume >/dev/null 2>&1
assert_eq "$(head -1 "$PEND/$pr.failed" 2>/dev/null)" "store miss" "(fixture) %N.failed store miss"
TL respawn-pane -k -t "$pr" 'sleep 300'; sleep 0.3
spr="$(TL display -p -t "$pr" '#{pane_pid}')"
stub_store_add "$U15" "$D1"
R restore --resume --retry >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(head -1 "$PEND/$pr.failed" 2>/dev/null)|$(grep -c "$U15" "$STUB_LOG")" "13|pane changed|0" \
  "--retry of a failed pane replaced since: %N.failed pane changed, nothing launched"
assert_eq "$(TL display -p -t "$pr" '#{pane_pid}')|$(TL display -p -t "$pr" '#{pane_current_command}')" "$spr|sleep" "...the person's command untouched"
kill_sess x8

echo "== --retry takes only the states with a retry arrow (T14, T16), by the first line =="
# A placeholder whose file is %N.failed interrupted, its key in the store, the
# pane alive: every check a retry makes would PASS, so only the first-line
# rule keeps it out (§4.7: interrupted, changed, replaced and exited have no
# retry arrow; only a person's `revive` reaches interrupted).
reset_run
TL new-session -d -s x9 -x 200 -y 50 'sleep 600'
pq="$(first_pane x9)"
mkdir -p "$PEND"
for r in interrupted replaced; do
  printf '%s\nwas %%1009\nharness claude\nsession_id %s\ntranscript %s\ncwd %s\nsession x9\nwindow 1\norder 1\n' "$r" "$U1" "$(tfile "$U1")" "$D1" > "$PEND/$pq.failed"
  TL set -p -t "$pq" remain-on-exit failed; TL respawn-pane -k -t "$pq" "$PH" "$PEND/$pq" claude
  wait_screen "$pq" "claude was not resumed: $r" 70 >/dev/null
  R restore --resume --retry >/dev/null 2>&1
  assert_eq "$(grep -c "$U1" "$STUB_LOG")|$(head -1 "$PEND/$pq.failed" 2>/dev/null)" "0|$r" \
    "failed with '$r' first, every check passable: --retry launches nothing, the file as it was"
done
kill_sess x9

echo "== a retried dead pane (T16): pane_dead 1 is its check =="
reset_run
TL new-session -d -s x4 -x 200 -y 50 'sleep 600'
pz="$(first_pane x4)"; TL set -p -t "$pz" remain-on-exit failed; TL respawn-pane -k -t "$pz" 'exit 3'
i=0; while [ "$i" -lt 30 ] && [ "$(TL display -p -t "$pz" '#{pane_dead}')" != 1 ]; do sleep 0.1; i=$((i+1)); done
mkdir -p "$PEND"
printf 'died\nwas %%1004\nharness claude\nsession_id %s\ntranscript %s\ncwd %s\nsession x4\nwindow 1\norder 1\n' "$U9" "$(tfile "$U9")" "$D1" > "$PEND/$pz.failed"
R restore --resume >/dev/null 2>&1
assert_eq "$(cat "$STUB_LOG")" "" "failed, dead: a plain --resume leaves it"
R restore --resume --retry >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(grep -c "$U9" "$STUB_LOG")|$(TL display -p -t "$pz" '#{pane_dead}')" "0|1|0" "--retry relaunches a failed, dead pane in place"
kill_sess x4

echo "== a key after a failure is marked (ROOST_TEST_RESUME_HOLD_AFTER_FAILED) =="
reset_run
U14=3fa3c0de-eeee-4abc-8def-00000000000e
shape_of "x5|%1005|$D1|harness claude;session_id $U14"
place_only 1
pk="$(first_pane x5)"; wait_screen "$pk" "waiting to resume claude"
pidk="$(TL display -p -t "$pk" '#{pane_pid}')"
FH="$SHAPE_TMP/failed.hold"; rm -f "$FH" "$FH".at.*
ROOST_TEST_RESUME_HOLD_AFTER_FAILED="$FH" "${RB[@]}" restore --resume >/dev/null 2>&1 &
WPID=$!
i=0; while [ "$i" -lt 50 ] && ! ls "$FH".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
wait_screen "$pk" "claude was not resumed: store miss" 70; assert_true $? "the reason is on screen within 6 s"
assert_eq "$(TL display -p -t "$pk" '#{pane_pid}')|$(shells_for "$pk")" "$pidk|" "...same pane_pid, no shell"
TL send-keys -t "$pk" x; wait_file "$PEND/$pk.taken" 50; assert_true $? "one key: .taken"
shells_wait "$pk"; assert_eq "$(shells_for "$pk" | wc -l | tr -d ' ')" "1" "...and a shell"
TL send-keys -t "$pk" 'sleep 60' Enter; sleep 0.5
touch "$FH"; wait "$WPID"
assert_eq "$(TL display -p -t "$pk" '#{pane_current_command}')" "sleep" "released: the sleep is alive"
kill_sess x5

echo "== §8.1 test 11, interrupted: the next worker takes the dead one's resuming/ =="
reset_run
TL set-environment -g STUB_IDENTIFY 1
shape_of "y1|%1006|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")" \
         "y2|%1007|$D1|harness claude;session_id $U3;transcript $(tfile "$U3")" \
         "y3|%1008|$D1|harness claude;session_id $U8;transcript $(tfile "$U8")"
place_only 3
py1="$(first_pane y1)"
"${RB[@]}" restore --resume --pace 6 >/dev/null 2>&1 &
WPID=$!
wait_log "$U1" 100
kill -9 "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
wait_gone2 "$PEND/$py1.launching"
assert_eq "$(ls "$PEND" | grep -c '^%[0-9]*$')|$(ls "$PEND" | grep -c "^$py1")" "2|0" "killed after the first launch: its file gone (identified), two claimable"
R restore --resume --pace 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(wc -l < "$STUB_LOG" | tr -d ' ')|$(grep -c "$U3" "$STUB_LOG")|$(grep -c "$U8" "$STUB_LOG")" "0|3|1|1" \
  "the next run takes the dead worker's resuming/ and launches exactly those two"
kill_sess y1 y2 y3
TL set-environment -gu STUB_IDENTIFY

echo "== interrupted after the claim (T8b by origin): renamed back, launched once =="
reset_run
shape_of "y4|%1009|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
place_only 1
py4="$(first_pane y4)"
RH="$SHAPE_TMP/resume2.hold"; rm -f "$RH"
ROOST_TEST_RESUME_HOLD="$RH" "${RB[@]}" restore --resume >/dev/null 2>&1 &
WPID=$!
wait_file "$PEND/$py4.launching" 50
i=0; while [ "$i" -lt 50 ] && ! ls "$RH".at.* >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
kill -9 "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
[ -e "$PEND/$py4.launching" ]; assert_true $? "(fixture) the dead worker left %N.launching, its claim held"
R restore --resume --pace 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(grep -c "$U1" "$STUB_LOG")" "0|1" "the next run puts it back by its origin (waiting) and launches it once"
kill_sess y4

echo "== a duplicate across workers =="
reset_run
shape_of "y5|%1010|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")" \
         "y6|%1011|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
place_only 2
py5="$(first_pane y5)"; py6="$(first_pane y6)"
"${RB[@]}" restore --resume --pace 6 >/dev/null 2>&1 &
WPID=$!
wait_log "$U1" 100
kill -9 "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
R restore --resume --pace 0 >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(head -1 "$PEND/$py6.failed" 2>/dev/null)" "13|duplicate of $py5" "run again: the second is %N.failed duplicate of the first"
assert_eq "$(head -1 "$CLB/claude-$U1/pane" 2>/dev/null)" "$py5" "...and the claim names the first"
TL kill-pane -t "$py5"
R restore --resume --retry --pace 0 >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(grep -c "$U1" "$STUB_LOG")|$(TL display -p -t "$py6" '#{pane_current_command}')" "0|2|claude" \
  "the first pane killed: --retry launches the second"
kill_sess y5 y6

# --- the report (Task 3.11) ---------------------------------------------------
echo "== the report: one summary, a line per pane not resumed, the codex note, exit 13 =="
reset_run
CX2=019a0f0f-6a8b-7c71-9d2e-0000000000c3
: > "$CODEX_HOME/sessions/2026/10/31/rollout-2026-10-31T09-00-00-$CX2.jsonl"
STALE=01a16c68-1111-4abc-8def-0000000000f9
shape_of "z1|%2001|$D1|harness claude;session_id $U1;transcript $(tfile "$U1");state working" \
         "z2|%2002|$D2|harness codex;session_id $CX" \
         "z3|%2003|$D2|harness codex;session_id $CX2" \
         "z4|%2004|$D3|stale_reason nested;stale_harness codex;stale_session_id $STALE" \
         "z5|%2005|$D3|launch roost view preen README.md" \
         "z6|%2006|$D1|harness claude;session_id $U2"
R restore --json --pace 0 >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
z1="$(first_pane z1)"; z2="$(first_pane z2)"; z4="$(first_pane z4)"; z5="$(first_pane z5)"; z6="$(first_pane z6)"
assert_eq "$rc" "13" "a pane not resumed for a listed reason: exit 13"
assert_contains "$(cat "$SHAPE_TMP/err")" \
  "restored 6 sessions, 6 windows, 6 panes; launched 3 agents; skipped 0 (existing); 2 not resumed (reasons listed above); 1 were working or blocked at the save — re-prompt by hand: $z1" \
  "the §4.3 report line"
assert_contains "$(cat "$SHAPE_TMP/err")" "$z5 was started as 'roost view preen README.md'" "a pane with a launch hint names it"
assert_contains "$(cat "$SHAPE_TMP/err")" "$z4 carries a stale codex key (01a16c68…) from a nested agent; not resumed" "the §5.6 line for a stale key"
assert_contains "$(cat "$SHAPE_TMP/err")" "2 codex panes resumed; until #145 their badges all land on the first ($z2)" "the codex note (§5.7)"
if command -v python3 >/dev/null 2>&1; then
  got="$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
r = {x["was"]: x for x in d["restored"]}
print(len(d["restored"]), d["skipped"], r["%2001"]["launched"], r["%2001"]["pane"], r["%2006"]["launched"], r["%2006"]["reason"], r["%2001"]["session"], r["%2001"]["window"], d["from"] != "")' "$SHAPE_TMP/out" 2>&1)"
  assert_eq "$got" "6 [] True $z1 False store miss z1 1 True" "--json: restored[] with was, pane, session, window, launched, reason; skipped; from"
fi
echo "== --list shows the pending record, its .launching, .failed and .taken files (§8.1 test 11) =="
printf 'was %%1\nharness claude\nsession_id %s\ncwd /\nsession s\nwindow 1\norder 1\n' "$U9" > "$PEND/%4242.taken"
lst="$(R restore --list 2>&1)"
assert_contains "$lst" "$z6.failed" "--list names the .failed file (a store miss)"
assert_contains "$(printf '%s\n' "$lst" | grep -- "$z6.failed")" "store miss" "...with its reason"
assert_contains "$lst" "$z1.launching" "...a .launching file"
assert_contains "$lst" "%4242.taken" "...and a .taken one"
rm -f "$PEND/%4242.taken"
kill_sess z1 z2 z3 z4 z5 z6
echo "== 12 wins over 13 =="
reset_run
TL new-session -d -s z1 'sleep 600'
R restore --json --pace 0 >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "a session skipped as existing and a pane not resumed: exit 12"
assert_contains "$(cat "$SHAPE_TMP/err")" "skipped 1 (existing)" "...the report counts it"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skipped"])' "$SHAPE_TMP/out")" "['z1']" "--json: skipped names it"
fi
kill_sess z1 z2 z3 z4 z5 z6
reset_run
shape_of "z7|%2007|$D1|harness claude;session_id $U1;transcript $(tfile "$U1")"
R restore --pace 0 >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "every agent launched: exit 0"
assert_contains "$(cat "$SHAPE_TMP/err")" "launched 1 agents; skipped 0 (existing); 0 not resumed" "...and the report says so"
kill_sess z7

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
