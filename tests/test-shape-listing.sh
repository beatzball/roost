#!/usr/bin/env bash
# The printed store listings (#191 Part 6, §5.6, §2.8's "source if roost has
# no key" column, §9 Q4 = A): for a Claude or codex pane roost has no key
# for, every conversation of that pane's directory as a ready-to-type
# `claude --resume <id>` / `codex resume <id>` line, newest first — PRINTED,
# NEVER RUN. A guessed resume into the wrong pane is what §5.1 exists to stop.
#
# Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md §5.6.
# Plan: Tasks 6.3 and 6.4. The folder rule is measured, not invented:
# docs/airig/probes/persist-6-claude-folders.md (Probe 6.1).
#
# The library cases source scripts/lib/roost-resume.sh directly. The verb's
# cases drive bin/roost against this file's own named server (tests/lib-shape.sh
# says why it is `-L roost` under a guarded TMUX_TMPDIR) with stub harnesses,
# and every one of them ends on the stub log: empty, nothing launched.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT

# A listing READS a store, so codex gets a temp home of its own here, as in
# tests/test-revive.sh; the canary still guards the other homes.
# CLAUDE_CONFIG_DIR is already a temp dir (lib-shape.sh).
export CODEX_HOME="$SHAPE_TMP/h-codex"
mkdir -p "$CODEX_HOME"

. scripts/lib/roost-resume.sh

U1=3fa3c0de-1111-4abc-8def-000000000001
U2=3fa3c0de-2222-4abc-8def-000000000002
U3=3fa3c0de-3333-4abc-8def-000000000003
U4=3fa3c0de-4444-4abc-8def-000000000004
U5=3fa3c0de-5555-4abc-8def-000000000005
U6=3fa3c0de-6666-4abc-8def-000000000006
U7=3fa3c0de-7777-4abc-8def-000000000007
U8=3fa3c0de-8888-4abc-8def-000000000008
US=3fa3c0de-9999-4abc-8def-0000000000ee

PROJ="$CLAUDE_CONFIG_DIR/projects"

# claude_folder PATH — Claude's project folder name for PATH, as Probe 6.1
# MEASURED it, written here independently of roost's own code so the test
# does not grade roost against itself: every byte that is not an ASCII
# letter or digit is `-`, except that a whole non-ASCII character is one
# `-` (two for a four-byte one, which is two UTF-16 code units). Only the
# paths this file builds go through it: ASCII, `é` and one four-byte emoji.
claude_folder() {
  local e f
  e="$(printf '\303\251')"; f="$(printf '\360\237\220\224')"
  printf '%s' "$1" | LC_ALL=C sed -e "s/$f/--/g" -e "s/$e/-/g" -e 's/[^A-Za-z0-9]/-/g'
}
# transcript ID CWD-AS-WRITTEN FOLDER STAMP — one stub transcript, the way
# Claude writes one: a first line with no `cwd`, then the `cwd` line (§2.1:
# "from line 5 on" in a real one). CWD-AS-WRITTEN goes into the JSON as
# given, so a test can write an escape into it. STAMP is touch -t's
# [[CC]YY]MMDDhhmm, which GNU and BSD touch both take.
transcript() {
  mkdir -p "$PROJ/$3"
  printf '%s\n' '{"type":"summary","leafUuid":"x"}' \
    "{\"type\":\"user\",\"cwd\":\"$2\",\"sessionId\":\"$1\"}" > "$PROJ/$3/$1.jsonl"
  touch -t "$4" "$PROJ/$3/$1.jsonl"
}
lines() { tr '\n' ' ' | sed 's/ $//'; }

# Every directory dotted AND with an underscore: `w_1` shares Claude's
# folder with `w.1` and `w 1` (Probe 6.1), so a folder holds transcripts of
# directories that are not this one, and only each file's own first `cwd`
# can tell them apart.
DIR="$SHAPE_TMP/work/repo/.claude/worktrees/w_1"
DOT="$SHAPE_TMP/work/repo/.claude/worktrees/w.1"
mkdir -p "$DIR" "$DOT"
DIR="$(cd -P "$DIR" && pwd)"; DOT="$(cd -P "$DOT" && pwd)"
F1="$(claude_folder "$DIR")"

echo "== the stub store's folder is the measured one (control) =="
case "$F1" in *_*|*.*) r=1 ;; *) r=0 ;; esac
assert_true $r "the folder for a dotted, underscored path holds no '.' and no '_' ($F1)"
assert_eq "$(claude_folder "$DOT")" "$F1" "...and w.1 shares it with w_1 (Probe 6.1)"

echo "== roost_resume_listing claude: every conversation of the directory, newest first (§5.6) =="
# Five transcripts in two folders:
#   F1  U1 U2 U3  first cwd DIR, byte for byte    -> listed, newest mtime first
#   F1  U4        first cwd DOT (the same folder)  -> not listed: another directory
#   F1  U5        first cwd DIR written with a `\u` escape for `1` -> refused,
#                 never decoded (§5.1's read): not listed
#   F2  U6        first cwd DIR, but in a folder the rule does not name (a
#                 transcript filed elsewhere) -> not listed: a miss only
#                 shortens the list
transcript "$U1" "$DIR" "$F1" 202611010101
transcript "$U2" "$DIR" "$F1" 202611010103
transcript "$U3" "$DIR" "$F1" 202611010102
transcript "$U4" "$DOT" "$F1" 202611010104
transcript "$U5" "${DIR%?}\\u0031" "$F1" 202611010105
transcript "$U6" "$DIR" "-elsewhere-folder" 202611010106
got="$(roost_resume_listing claude "$DIR")"; rc=$?
assert_eq "$rc|$(printf '%s\n' "$got" | lines)" \
  "0|claude --resume $U2 claude --resume $U3 claude --resume $U1" \
  "three lines, newest mtime first; another directory's, an escaped cwd and a folder the rule misses are not listed"
assert_eq "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" "3" "...one line per conversation"

echo "== an exited pane's own stale id comes first, once =="
got="$(roost_resume_listing claude "$DIR" "$U3")"
assert_eq "$(printf '%s\n' "$got" | lines)" \
  "claude --resume $U3 claude --resume $U2 claude --resume $U1" "the stale id first, then the rest newest first, not repeated"
got="$(roost_resume_listing claude "$DIR" "$US")"
assert_eq "$(printf '%s\n' "$got" | lines)" \
  "claude --resume $US claude --resume $U2 claude --resume $U3 claude --resume $U1" \
  "a stale id the store has no file for is still listed first: it is the pane's own"
got="$(roost_resume_listing claude "$DIR" "not-a-uuid*")"
assert_eq "$(printf '%s\n' "$got" | lines)" \
  "claude --resume $U2 claude --resume $U3 claude --resume $U1" "a stale id that is not a session id is dropped, never printed"

echo "== nothing to list =="
EMPTY="$SHAPE_TMP/work/empty"; mkdir -p "$EMPTY"
got="$(roost_resume_listing claude "$EMPTY")"; rc=$?
assert_eq "$rc|$got" "1|" "a directory with no conversation: exit 1, nothing printed"
got="$(roost_resume_listing claude "relative/dir")"; rc=$?
assert_eq "$rc|$got" "1|" "a relative directory: exit 1, nothing printed"
got="$(roost_resume_listing pi "$DIR")"; rc=$?
assert_eq "$rc|$got" "1|" "a harness with no listing in §5.6 (pi): exit 1, nothing printed"

echo "== the measured folder rule: a space, non-ASCII and a long path (Probe 6.1) =="
SP="$SHAPE_TMP/work/a b"
NA="$SHAPE_TMP/work/a$(printf '\303\251')x$(printf '\360\237\220\224')y"
LONG="$SHAPE_TMP/work/$(printf 'x%.0s' $(seq 1 230))"
mkdir -p "$SP" "$NA" "$LONG"
SP="$(cd -P "$SP" && pwd)"; NA="$(cd -P "$NA" && pwd)"; LONG="$(cd -P "$LONG" && pwd)"
transcript "$U7" "$SP" "$(claude_folder "$SP")" 202611010107
got="$(roost_resume_listing claude "$SP")"
assert_eq "$got" "claude --resume $U7" "a space is written '-'"
transcript "$U8" "$NA" "$(claude_folder "$NA")" 202611010108
got="$(roost_resume_listing claude "$NA")"
assert_eq "$got" "claude --resume $U8" "é is one '-' and a four-byte character two, whatever the locale"
got="$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 roost_resume_listing claude "$NA" 2>/dev/null)"
assert_eq "$got" "claude --resume $U8" "...the same under a UTF-8 locale"
# Past 200 characters Claude cuts the name and adds `-` and a suffix it does
# not let a path derive (Probe 6.1: `-ptxsab`).
LF="$(claude_folder "$LONG")"
transcript "$U1" "$LONG" "${LF:0:200}-ab12cd" 202611010109
got="$(roost_resume_listing claude "$LONG")"
assert_eq "$got" "claude --resume $U1" "a folder name past 200 characters is found by its first 200 and any suffix"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
