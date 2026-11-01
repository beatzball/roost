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
ROOST_TEST_LOOP_HOLD="$HOLD" R restore >/dev/null 2>"$SHAPE_TMP/err" &
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
[ -e "$PEND/$pb" ]; assert_true $? "...a pane with no transcript path is still resumed (its file is there)"
R restore --recent x >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "--recent needs a number of days: usage, exit 2"
kill_saved; rm -f "$PEND"/*

echo "== §8.1 test 2 (i), the keyed half: a keyed pane taken during placement =="
: > "$HOME/shells.log"; : > "$STUB_LOG"
PHOLD="$SHAPE_TMP/place.hold"; rm -f "$PHOLD"
ROOST_TEST_PLACE_HOLD="$PHOLD" R restore --only ka >/dev/null 2>"$SHAPE_TMP/err" &
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

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
