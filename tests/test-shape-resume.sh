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

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
