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
rm -f "$PROJ/${LF:0:200}-ab12cd/$U1.jsonl"

echo "== roost_resume_listing codex: rollouts whose session_meta cwd is the directory (§5.6, Task 6.4) =="
CX1=019a0f0f-6a8b-7c71-9d2e-0000000000c1
CX2=019a0f0f-6a8b-7c71-9d2e-0000000000c2
CX3=019a0f0f-6a8b-7c71-9d2e-0000000000c3
CX4=019a0f0f-6a8b-7c71-9d2e-0000000000c4
CX5=019a0f0f-6a8b-7c71-9d2e-0000000000c5
CX9=019a0f0f-6a8b-7c71-9d2e-0000000000c9
# rollout DAY ID CWD-AS-WRITTEN STAMP [SECOND-LINE] — one rollout the way
# codex files it: sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl, whose first
# line is the session_meta naming its cwd. With SECOND-LINE, the first line is
# something else and the session_meta comes second.
rollout() {
  local d="$CODEX_HOME/sessions/2026/11/$1" f
  mkdir -p "$d"; f="$d/rollout-2026-11-$1T08-00-00-$2.jsonl"
  local meta="{\"timestamp\":\"2026-11-$1T08:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$2\",\"timestamp\":\"2026-11-$1T08:00:00Z\",\"cwd\":\"$3\",\"originator\":\"codex_cli_rs\",\"cli_version\":\"0.163.0\"}}"
  if [ -n "${5:-}" ]; then printf '%s\n' '{"type":"event_msg","payload":{"type":"other"}}' "$meta" > "$f"
  else printf '%s\n' "$meta" '{"type":"response_item","payload":{"cwd":"/elsewhere"}}' > "$f"; fi
  touch -t "$4" "$f"
}
rollout 01 "$CX1" "$DIR" 202611010201
rollout 02 "$CX2" "$DIR" 202611020202
rollout 02 "$CX3" "$DOT" 202611020203
rollout 03 "$CX4" "${DIR%?}\\u0031" 202611030204
rollout 03 "$CX5" "$DIR" 202611030205 second
got="$(roost_resume_listing codex "$DIR")"; rc=$?
assert_eq "$rc|$(printf '%s\n' "$got" | lines)" "0|codex resume $CX2 codex resume $CX1" \
  "two lines, newest first; another directory's, an escaped cwd and a session_meta not on the first line are not listed"
got="$(roost_resume_listing codex "$DIR" "$CX1")"
assert_eq "$(printf '%s\n' "$got" | lines)" "codex resume $CX1 codex resume $CX2" "a stale codex id first, once"
got="$(roost_resume_listing codex "$EMPTY")"; rc=$?
assert_eq "$rc|$got" "1|" "a directory with no rollout: exit 1, nothing printed"

echo "== a rollout that cannot be read, a symlinked store, a directory with no path shape (fix round 1) =="
# A rollout no one may read: skipped in silence, never a raw shell error on
# the person's screen. root reads a mode-000 file anyway (the container runs
# as root), so the case is skipped there and says so.
UNREAD="$CODEX_HOME/sessions/2026/11/04/rollout-2026-11-04T08-00-00-$CX9.jsonl"
if [ "$(id -u)" != 0 ]; then
  rollout 04 "$CX9" "$DIR" 202611040206
  chmod 000 "$UNREAD"
  got="$(roost_resume_listing codex "$DIR" 2>"$SHAPE_TMP/lerr")"
  assert_eq "$(printf '%s\n' "$got" | lines)|$(cat "$SHAPE_TMP/lerr")" "codex resume $CX2 codex resume $CX1|" \
    "an unreadable rollout is skipped, and nothing is written to stderr"
  chmod 600 "$UNREAD"; rm -f -- "$UNREAD"
else
  echo "  (skipped: running as root, which reads a mode-000 file)"
fi
# A store reached through a symbolic link (a home kept on another disk):
# `find` does not descend into a starting point that is a link unless told to.
LH="$SHAPE_TMP/linked"; mkdir -p "$LH/codex" "$LH/claude"
ln -s "$CODEX_HOME/sessions" "$LH/codex/sessions"
ln -s "$PROJ" "$LH/claude/projects"
got="$(CODEX_HOME="$LH/codex" roost_resume_listing codex "$DIR")"
assert_eq "$(printf '%s\n' "$got" | lines)" "codex resume $CX2 codex resume $CX1" "codex: a sessions/ that is a symbolic link is read"
got="$(CLAUDE_CONFIG_DIR="$LH/claude" roost_resume_listing claude "$DIR")"
assert_eq "$(printf '%s\n' "$got" | lines)" "claude --resume $U2 claude --resume $U3 claude --resume $U1" "claude: a projects/ that is a symbolic link is read"
# The printer names the directory only when it is one roost would use: an
# absolute path with no control character (a newline would forge a line).
got="$(roost_resume_print_listing "roost revive" claude "relative/dir")"
assert_eq "$got" "" "print_listing: a relative directory prints nothing"
got="$(roost_resume_print_listing "roost revive" claude "$DIR$(printf '\nroost revive: forged')")"
assert_eq "$got" "" "print_listing: a directory holding a newline prints nothing"

# --- the verbs print it: revive, the restore report, --dry-run (Task 6.4) ----
ROOST="$PWD/bin/roost"
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
# `roost wiring apply` runs when restore starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary (tests/test-shape-resume.sh).
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
# No shutdown record unless a case sets one: on a Mac `last reboot` would
# otherwise decide which save a restore picks (tests/test-shape-attach.sh).
export ROOST_SHUTDOWN_AT=""
popt() { TL show-options -pqv -t "$1" "$2" 2>/dev/null; }
ppid_of() { TL display -p -t "$1" '#{pane_pid}'; }
stubpane() { TL new-window -d -P -F '#{pane_id}' -t shp: -c "$2" "$STUB_BIN/$1 600"; }
wait_cmd() { # PANE NAME — up to 5 s for the pane's foreground to be NAME
  local i=0
  while [ "$i" -lt 50 ]; do [ "$(TL display -p -t "$1" '#{pane_current_command}')" = "$2" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
# log_quiet -> prints the stub log after watching it stay empty for 1 s. A
# launch is asynchronous (a respawn, a background job), so a log read at once
# can be empty while a launch is still on its way; a mutant that ran the
# newest line in the background passed an immediate read (Task 6.6). A line
# that lands in that second ends the wait and is printed, so the assertion
# fails on it.
log_quiet() {
  local i=0
  while [ "$i" -lt 10 ] && [ ! -s "$STUB_LOG" ]; do sleep 0.1; i=$((i+1)); done
  cat "$STUB_LOG"
}
# after FILE TEXT N — the N lines right after the first line of FILE holding
# TEXT (a fixed string), one per line.
after() { awk -v t="$2" -v n="$3" 'f && n-- > 0 { print; next } !f && index($0, t) { f = 1 }' "$1"; }
CL="  claude --resume $U2
  claude --resume $U3
  claude --resume $U1"

echo "== revive of a no-key pane prints the listing after its exit-13 line, and runs nothing =="
: > "$STUB_LOG"
P="$(stubpane claude "$DIR")"; wait_cmd "$P" claude
TL set-option -p -t "$P" @roost-harness claude
pid0="$(ppid_of "$P")"
R revive "$P" >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "no session id: still exit 13"
assert_eq "$(head -n 1 "$SHAPE_TMP/err")" "roost revive: '$P' has no recorded conversation (harness claude, no session id)" "...its exit-13 line first"
assert_eq "$(after "$SHAPE_TMP/err" "no session id)" 4)" \
  "roost revive: claude holds these conversations for $DIR, newest first (printed, not run; pick one):
$CL" "...then every conversation of the pane's directory, newest first"
assert_eq "$(cat "$SHAPE_TMP/out")" "" "...nothing on stdout"
assert_eq "$(log_quiet)|$(ppid_of "$P")" "|$pid0" "...nothing launched (the stub log is empty), the pane untouched"
TL kill-pane -t "$P"

: > "$STUB_LOG"
P="$(stubpane claude "$DIR")"; wait_cmd "$P" claude
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(head -n 1 "$SHAPE_TMP/err")" "13|roost revive: '$P' has no recorded conversation (no harness, no session id)" \
  "a Claude pane with no identity at all: exit 13, as before"
assert_eq "$(after "$SHAPE_TMP/err" "no session id)" 4)" \
  "roost revive: claude holds these conversations for $DIR, newest first (printed, not run; pick one):
$CL" "...and the harness its command names gets the listing"
assert_eq "$(log_quiet)" "" "...nothing launched"
TL kill-pane -t "$P"

: > "$STUB_LOG"
P="$(stubpane codex "$DIR")"; wait_cmd "$P" codex
TL set-option -p -t "$P" @roost-harness codex
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a codex pane with no key (#145): exit 13"
assert_eq "$(after "$SHAPE_TMP/err" "no session id)" 3)" \
  "roost revive: codex holds these conversations for $DIR, newest first (printed, not run; pick one):
  codex resume $CX2
  codex resume $CX1" "...then its rollouts, newest first"
assert_eq "$(log_quiet)" "" "...nothing launched"
TL kill-pane -t "$P"

: > "$STUB_LOG"
P="$(stubpane claude "$EMPTY")"; wait_cmd "$P" claude
TL set-option -p -t "$P" @roost-harness claude
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc|$(sed -n 2p "$SHAPE_TMP/err")" "13|roost revive: claude holds no conversation for $EMPTY" \
  "a directory the store has nothing for: said in one line"
TL kill-pane -t "$P"

echo "== revive of a pane with a STALE key prints its own harness's listing too (fix round 1) =="
# Spec §9 Q4, revision 1: a stale key counts as none. A Claude pane carrying a
# nested codex key: the stale line, then CLAUDE's listing (the pane's own
# command), never the nested agent's.
: > "$STUB_LOG"
P="$(stubpane claude "$DIR")"; wait_cmd "$P" claude
TL set-option -p -t "$P" @roost-harness codex \; set-option -p -t "$P" @roost-session "$CX9" \; set-option -p -t "$P" @roost-cwd "$DIR"
pid0="$(ppid_of "$P")"
R revive "$P" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "13" "a nested key: exit 13"
assert_contains "$(head -n 1 "$SHAPE_TMP/err")" "its codex key $CX9 is stale" "...its stale line first"
assert_eq "$(sed -n '2,5p' "$SHAPE_TMP/err")" \
  "roost revive: claude holds these conversations for $DIR, newest first (printed, not run; pick one):
$CL" "...then the listing of the harness the pane runs (claude), newest first"
assert_eq "$(log_quiet)|$(ppid_of "$P")" "|$pid0" "...nothing launched, the pane untouched"
TL kill-pane -t "$P"

echo "== the restore report and --dry-run print it under a pane with a stale or missing key =="
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
# Five sessions of one pane each, every pane in DIR:
#   lnk    harness claude, no session id            -> no key: the listing.
#          Defensive: the writer never produces this block (it writes
#          `harness` only beside a `session_id`), but a hand-edited or older
#          file can, and it must not read as anything else.
#   lcmd   no identity, command Claude's version    -> no key: the listing
#   lst    stale claude key, exited                 -> its own id first
#   lnest  a claude pane carrying a nested codex key -> CLAUDE's listing, no
#          stale id first: the key is the nested agent's, not the pane's
#   lcx    no identity, command codex (#145)        -> the rollouts
mkshape() {
  local n=0
  blk() { # SESSION ID EXTRA-LINES
    printf '%s\n' "session $1" "id \$$n" '' "window $1:1" "id @$n" "layout b25d,200x50,0,0,$n" 'active 1' '' \
      "pane $1:1.0" "id $2" "cwd $DIR" "$3" ''
    n=$((n+1))
  }
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' \
      'saved 2026-11-06T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
    blk lnk %940 "harness claude"
    blk lcmd %941 "command 2.1.319"
    blk lst %942 "stale_reason exited
stale_harness claude
stale_session_id $US
command bash"
    blk lnest %943 "stale_reason nested
stale_harness codex
stale_session_id $CX9
command claude"
    blk lcx %944 "command codex"
  } > "$SD/shape"
}
mkshape
out="$(R restore --dry-run 2>"$SHAPE_TMP/err")"; rc=$?
printf '%s\n' "$out" > "$SHAPE_TMP/dry"
assert_eq "$(after "$SHAPE_TMP/dry" "session lnk" 5 | sed 's/  */ /g')" \
  " window 1 -
 pane 0 - $DIR claude shell, not resumed: no key
 claude --resume $U2
 claude --resume $U3
 claude --resume $U1" "--dry-run: a harness with no session id says 'no key', its listing indented under it"
assert_eq "$(after "$SHAPE_TMP/dry" "session lcmd" 2 | sed 's/  */ /g')" \
  " window 1 -
 pane 0 - $DIR claude shell, not resumed: no key" "--dry-run: a pane whose command is Claude's version, with no identity, is a Claude pane with no key"
assert_eq "$(after "$SHAPE_TMP/dry" "session lst" 6 | sed 's/  */ /g')" \
  " window 1 -
 pane 0 - $DIR - shell, not resumed: stale (exited claude)
 claude --resume $US
 claude --resume $U2
 claude --resume $U3
 claude --resume $U1" "--dry-run: an exited pane's own stale id first"
assert_eq "$(after "$SHAPE_TMP/dry" "session lnest" 3 | sed 's/  */ /g' | tail -n 1)" " claude --resume $U2" \
  "--dry-run: a nested key lists the PANE's harness (claude), not the nested one"
assert_eq "$(after "$SHAPE_TMP/dry" "session lcx" 4 | sed 's/  */ /g')" \
  " window 1 -
 pane 0 - $DIR codex shell, not resumed: no key
 codex resume $CX2
 codex resume $CX1" "--dry-run: a codex pane with no key lists its rollouts"
TL ls -F '#{session_name}' 2>/dev/null | grep -q '^l'; assert_eq "$?" "1" "--dry-run made no session"

: > "$STUB_LOG"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
first_pane() { TL list-panes -s -t "=$1:" -F '#{pane_id}' 2>/dev/null | head -1; }
pnk="$(first_pane lnk)"; pcmd="$(first_pane lcmd)"; pst="$(first_pane lst)"; pnest="$(first_pane lnest)"; pcx="$(first_pane lcx)"
assert_eq "$(after "$SHAPE_TMP/err" "$pnk ran claude with no recorded conversation" 4)" \
  "roost restore: $pnk: claude holds these conversations for $DIR, newest first (printed, not run; pick one):
$CL" "the report: a no-key pane's line, then its listing"
assert_eq "$(after "$SHAPE_TMP/err" "$pcmd ran claude with no recorded conversation" 1)" \
  "roost restore: $pcmd: claude holds these conversations for $DIR, newest first (printed, not run; pick one):" \
  "...a pane whose command was Claude's version is named a Claude pane with no key, and listed"
assert_eq "$(after "$SHAPE_TMP/err" "$pst carries a stale claude key" 2)" \
  "roost restore: $pst: claude holds these conversations for $DIR, newest first (printed, not run; pick one):
  claude --resume $US" "...a stale exited key: its own id first"
assert_eq "$(after "$SHAPE_TMP/err" "$pnest carries a stale codex key" 2)" \
  "roost restore: $pnest: claude holds these conversations for $DIR, newest first (printed, not run; pick one):
  claude --resume $U2" "...a nested key: the pane's own harness's listing"
assert_eq "$(after "$SHAPE_TMP/err" "$pcx ran codex with no recorded conversation" 3)" \
  "roost restore: $pcx: codex holds these conversations for $DIR, newest first (printed, not run; pick one):
  codex resume $CX2
  codex resume $CX1" "...a codex pane with no key: its rollouts"
assert_contains "$(cat "$SHAPE_TMP/err")" "launched 0 agents" "...launched 0 agents"
assert_eq "$(log_quiet)" "" "nothing was launched from any listing (the stub log is empty)"
for s in lnk lcmd lst lnest lcx; do TL kill-session -t "=$s" 2>/dev/null; done

echo "== a pane with no key whose directory is gone: the report and --dry-run agree (fix round 1) =="
# Two panes in a directory that is gone: no identity with Claude's version as
# its command, and a harness with no session id. Both runs say "directory
# gone", neither prints a resume line (it would name a directory that does
# not exist), and both exit with the same code. A third, gmix: a stale
# exited key whose harness is NOT the one the pane's command names. The
# listing is the command's harness, and the stale id is not put first: it
# belongs to the other harness's store.
GONE="$SHAPE_TMP/work/gone"
gblk() { # SESSION N CWD EXTRA-LINES
  printf '%s\n' "session $1" "id \$$2" '' "window $1:1" "id @$2" "layout b25d,200x50,0,0,$2" 'active 1' '' \
    "pane $1:1.0" "id %$2" "cwd $3" "$4" ''
}
{ printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' \
    'saved 2026-11-06T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
  gblk gcmd 950 "$GONE" "command 2.1.319"
  gblk gkey 951 "$GONE" "harness claude"
  gblk gmix 952 "$DIR" "stale_reason exited
stale_harness codex
stale_session_id $CX9
command 2.1.319"
} > "$SD/shape"
dry="$(R restore --dry-run 2>/dev/null)"; drc=$?
printf '%s\n' "$dry" > "$SHAPE_TMP/dry2"
assert_eq "$(after "$SHAPE_TMP/dry2" "session gcmd" 2 | sed 's/  */ /g' | tail -n 1)" " pane 0 - $GONE claude shell in ~, not resumed: directory gone" \
  "--dry-run: the no-identity pane in a gone directory says 'directory gone'"
assert_eq "$(after "$SHAPE_TMP/dry2" "session gkey" 2 | sed 's/  */ /g' | tail -n 1)" " pane 0 - $GONE claude shell in ~, not resumed: directory gone" \
  "--dry-run: the harness with no session id in a gone directory says 'directory gone'"
assert_eq "$(after "$SHAPE_TMP/dry2" "session gmix" 3 | sed 's/  */ /g' | tail -n 1)" " claude --resume $U2" \
  "--dry-run: an exited key of ANOTHER harness is not put first; the command's harness is listed"
: > "$STUB_LOG"
R restore >/dev/null 2>"$SHAPE_TMP/err2"; rrc=$?
first_pane() { TL list-panes -s -t "=$1:" -F '#{pane_id}' 2>/dev/null | head -1; }
pg="$(first_pane gcmd)"; pk="$(first_pane gkey)"; pm="$(first_pane gmix)"
assert_eq "$rrc" "$drc" "the real run exits as --dry-run said it would ($drc)"
assert_contains "$(grep -F -- "($pg)" "$SHAPE_TMP/err2")" "directory gone" "the report: the no-identity pane's line says 'directory gone'"
assert_contains "$(grep -F -- "($pk)" "$SHAPE_TMP/err2")" "directory gone" "the report: the harness-with-no-id pane's line says 'directory gone'"
assert_eq "$(grep -c -F -- "--resume" "$SHAPE_TMP/err2" | tr -d ' ')|$(grep -c -F 'holds these conversations for '"$GONE" "$SHAPE_TMP/err2" | tr -d ' ')" "3|0" \
  "...no listing for a directory that is gone (the only resume lines are gmix's three)"
assert_eq "$(after "$SHAPE_TMP/err2" "$pm carries a stale codex key" 2 | tail -n 1)" "  claude --resume $U2" \
  "the report: an exited key of another harness is not put first"
assert_eq "$(log_quiet)" "" "nothing launched"
for s in gcmd gkey gmix; do TL kill-session -t "=$s" 2>/dev/null; done

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
