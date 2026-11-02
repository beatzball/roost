#!/usr/bin/env bash
# Saving on change (#51, #191 Part 4): the saver of spec §3.5 — one saver per
# server, a want per cause, the owner rule on `lock/`, the ring of
# ROOST_SHAPE_KEEP saves, and R3's `save.err`. Design:
# docs/airig/specs/2026-10-24-persistent-sessions-design.md §3.4, §3.5, §3.6;
# the plan's Task 4.5 (and 4.7, 4.11, which add to this file).
#
# Every case calls `roost save --auto` the way a hook will, and reads the
# shape directory; the hooks themselves are tests/test-shape-closed.sh's.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap 'kill_holds; shape_test_teardown' EXIT
. scripts/lib/roost-shape.sh

ROOST="$PWD/bin/roost"
R() { ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"
HOLDS=""
# Every background sleeper a case starts to stand for a live owner, killed at
# the end whatever happened.
kill_holds() { local p; for p in $HOLDS; do kill "$p" 2>/dev/null; done; }
# gen_of — the gen file, or "-" when there is none.
gen_of() { cat "$1/gen" 2>/dev/null || printf -- '-'; }
# nhist DIR — how many history files.
nhist() { ls "$1/history" 2>/dev/null | wc -l | tr -d ' '; }
# wait_at FILE — until a seam marked FILE.at.<pid> (the saver reached it), at
# most 10 s.
wait_at() { local i=0; while [ "$i" -lt 100 ]; do ls "$1".at.* >/dev/null 2>&1 && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# a live process with a known pid, and its start time as the owner rule reads it
live_pid() { sleep 600 & LIVE=$!; disown "$LIVE" 2>/dev/null; HOLDS="$HOLDS $LIVE"; LIVE_ST="$(roost_shape__lstart "$LIVE")"; }
# a pid that is certainly not running: a child that has exited and been reaped
dead_pid() { sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null; }

TL set -g base-index 1
TL new-session -d -s main -x 200 -y 50 'ENV= exec /bin/sh'
TL kill-session -t '=shp:' 2>/dev/null

echo "== the first --auto save =="
R save --auto --trigger after-new-window; rc=$?
assert_eq "$rc|$(gen_of "$SD")" "0|1" "save --auto publishes the first shape, exit 0"
assert_eq "$(sed -n 's/^trigger //p;/^$/q' "$SD/shape")" "after-new-window" "...its trigger is the one passed"
[ ! -e "$SD/want" ] && [ ! -e "$SD/lock" ]; assert_true $? "...and leaves no want/ and no lock/"
out="$(R save --auto --trigger after-new-window 2>&1)"; rc=$?
assert_eq "$rc|$out|$(gen_of "$SD")" "0||1" "no change: nothing written, nothing printed"

echo "== restoring/ held by a live restore: the want waits (§3.5 step 4) =="
live_pid
mkdir -p "$SD/restoring"; ln -s "$LIVE $LIVE_ST" "$SD/restoring/owner"
TL rename-window -t '=main:1' during-restore
R save --auto --trigger after-rename-window; rc=$?
assert_eq "$rc|$(gen_of "$SD")" "0|1" "save --auto writes nothing while restoring/ has a live owner"
[ -e "$SD/want/after-rename-window" ]; assert_true $? "...and its want is left for the restore's own save"
[ ! -e "$SD/lock" ]; assert_true $? "...and it took no lock"
rm -rf "$SD/restoring"
R save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD")|$(sed -n 's/^trigger //p;/^$/q' "$SD/shape")" "2|after-rename-window" \
  "once restoring/ is gone the next save publishes, its trigger kept"
mkdir -p "$SD/restoring"; dead_pid; ln -s "$DEAD Thu Jan  1 00:00:00 1970" "$SD/restoring/owner"
TL rename-window -t '=main:1' dead-restore
R save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD")" "3" "a restoring/ whose owner is dead does not hold the saver"
rm -rf "$SD/restoring"

echo "== the owner rule on lock/ (§3.5 step 1) =="
dead_pid
mkdir -p "$SD/lock"; ln -s "$DEAD Thu Jan  1 00:00:00 1970" "$SD/lock/owner"
TL rename-window -t '=main:1' dead-lock
R save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD")" "4" "a lock/ whose pid is dead is taken over and the save published"
[ ! -e "$SD/lock" ]; assert_true $? "...and released"
live_pid
mkdir -p "$SD/lock"; ln -s "$LIVE not-its-start-time" "$SD/lock/owner"
TL rename-window -t '=main:1' reused-pid
R save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD")" "5" "a lock/ whose pid runs with another start time (a reused pid) is taken over"
[ ! -e "$SD/lock" ]; assert_true $? "...and released"
live_pid
mkdir -p "$SD/lock"; ln -s "$LIVE $LIVE_ST" "$SD/lock/owner"
TL rename-window -t '=main:1' live-lock
R save --auto --trigger after-rename-window; rc=$?
assert_eq "$rc|$(gen_of "$SD")" "0|5" "a lock/ with a live owner: exit 0 at once, nothing written"
[ -e "$SD/want/after-rename-window" ]; assert_true $? "...its want is there for that owner"
assert_eq "$(readlink "$SD/lock/owner")" "$LIVE $LIVE_ST" "...and the live owner's lock is untouched"
rm -rf "$SD/lock" "$SD/want"

echo "== an owner held past 10 s keeps its lock: never by age =="
H="$SHAPE_TMP/hold1"
TL rename-window -t '=main:1' held-a
ROOST_TEST_SAVE_HOLD="$H" R save --auto --trigger after-rename-window & hp=$!
wait_at "$H"; assert_true $? "the first saver holds lock/"
sleep 15
TL rename-window -t '=main:1' held-b
held="$(readlink "$SD/lock/owner")"
t0=$(date +%s)
R save --auto --trigger after-select-layout; rc=$?
t1=$(date +%s)
assert_eq "$rc|$(gen_of "$SD")" "0|5" "held 15 s: a second save --auto takes no lock and writes nothing"
[ $((t1 - t0)) -lt 5 ]; assert_true $? "...and returns at once ($((t1 - t0)) s)"
[ -e "$SD/want/after-select-layout" ]; assert_true $? "...its want is there"
assert_eq "$(readlink "$SD/lock/owner")" "$held" "...and the lock is still the first saver's"
kill -0 "$(printf '%s' "$held" | cut -d' ' -f1)" 2>/dev/null; assert_true $? "...a live process"
: > "$H"; wait "$hp"
assert_eq "$(gen_of "$SD")" "6" "released: the held saver publishes once more"
w="$(sed -n "s/^name //p" "$SD/shape" | head -1)"
assert_eq "$w|$(sed -n 's/^trigger //p;/^$/q' "$SD/shape")" "held-b|after-rename-window after-select-layout" \
  "...the newest listing, with every cause of the round in its trigger"
[ ! -e "$SD/lock" ] && [ ! -e "$SD/want" ]; assert_true $? "...and leaves no lock/ and no want/"

echo "== the ring: history keeps ROOST_SHAPE_KEEP saves =="
i=0
while [ "$i" -lt 6 ]; do
  i=$((i + 1)); TL rename-window -t '=main:1' "ring-$i"
  ROOST_SHAPE_KEEP=3 R save --auto --trigger after-rename-window
done
assert_eq "$(nhist "$SD")" "3" "ROOST_SHAPE_KEEP=3: history holds 3 files after six more saves"
newest="$(ls "$SD/history" | sed 's/.*-//' | sort -n | tail -1)"
assert_eq "$newest" "$(( $(gen_of "$SD") - 1 ))" "...the newest ones: the last is the save before shape"
oldest="$(ls "$SD/history" | sed 's/.*-//' | sort -n | head -1)"
assert_eq "$oldest" "$(( $(gen_of "$SD") - 3 ))" "...and the oldest kept is three before shape"
ROOST_SHAPE_KEEP=junk R save --auto --trigger after-rename-window
TL rename-window -t '=main:1' ring-junk
ROOST_SHAPE_KEEP=junk R save --auto --trigger after-rename-window
assert_eq "$(nhist "$SD")" "4" "an unreadable ROOST_SHAPE_KEEP is the default (100), not 0"

echo "== saving off, relative, read-only: silent, exit 0 within 5 s (§8.1 test 10b) =="
for v in "" "rel/dir"; do
  t0=$(date +%s)
  out="$(ROOST_SHAPE_DIR="$v" R save --auto --trigger after-new-window 2>&1)"; rc=$?
  t1=$(date +%s)
  assert_eq "$rc|$out" "0|" "ROOST_SHAPE_DIR=[$v]: exit 0, prints nothing"
  [ $((t1 - t0)) -lt 5 ]; assert_true $? "...within 5 s ($((t1 - t0)) s)"
done
[ ! -e rel ]; assert_true $? "...and no relative directory was made"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$SHAPE_TMP/ro/roost"; chmod 500 "$SHAPE_TMP/ro/roost"
  out="$(ROOST_SHAPE_DIR="$SHAPE_TMP/ro" R save --auto --trigger after-new-window 2>&1)"; rc=$?
  assert_eq "$rc|$out|$(ls -A "$SHAPE_TMP/ro/roost")" "0||" "a read-only shape directory: exit 0, silent, nothing in it (no save.err either)"
  chmod 700 "$SHAPE_TMP/ro/roost"
else
  printf '  SKIP: a read-only shape directory (running as root, which writes into it anyway)\n'
fi

echo "== a restore --dry-run never sees a refusal while saves land =="
( i=0; while [ "$i" -lt 20 ]; do i=$((i + 1)); TL rename-window -t '=main:1' "dry-$i"; R save --auto --trigger after-rename-window; done ) &
sp=$!
bad=0; n=0
while kill -0 "$sp" 2>/dev/null; do
  n=$((n + 1))
  R restore --dry-run >/dev/null 2>"$SHAPE_TMP/dry.err" || { grep -q 'refused\|no readable\|nothing done' "$SHAPE_TMP/dry.err" && bad=$((bad + 1)); }
done
wait "$sp"
assert_eq "$bad" "0" "no --dry-run of $n was refused while 20 saves landed"

echo "== a second server for the destructive cases =="
# The cases below kill the server they save, so they run on one of their own,
# a -S server under this file's TMUX_TMPDIR (keyed path-<cksum>, §3.1).
S2="$TMUX_TMPDIR/s2"
start_s2() { tmux -S "$S2" -f /dev/null new-session -d -s two -x 120 -y 40 'ENV= exec /bin/sh'; }
R2() { ROOST_SOCKET="$S2" "$ROOST" "$@"; }
SD2="$ROOST_SHAPE_DIR/$(roost_shape_key -S "$S2")"
start_s2
R2 save --auto --trigger after-new-session
assert_eq "$(gen_of "$SD2")" "1" "the second server has its own first save"

echo "== a listing that fails mid-round: nothing published; save.err (R3) =="
cp -Rp "$SD2" "$SHAPE_TMP/sd2-before"
tmux -S "$S2" rename-window -t '=two:' gone-soon
H="$SHAPE_TMP/hold-drain"
ROOST_TEST_SAVE_HOLD_AFTER_DRAIN="$H" R2 save --auto --trigger after-rename-window >"$SHAPE_TMP/drain.out" 2>&1 & hp=$!
wait_at "$H"; assert_true $? "the saver is held after its drain"
tmux -S "$S2" kill-server
: > "$H"; wait "$hp"; rc=$?
assert_eq "$rc|$(cat "$SHAPE_TMP/drain.out")" "0|" "the server killed mid-round: save --auto is silent, exit 0"
assert_eq "$(gen_of "$SD2")|$(nhist "$SD2")" "1|0" "...gen and history unchanged"
cmp -s "$SD2/shape" "$SHAPE_TMP/sd2-before/shape"; assert_true $? "...and shape unchanged"
[ -f "$SD2/save.err" ]; assert_true $? "...and save.err is there"
assert_eq "$(ls -l "$SD2/save.err" | cut -c1-10)" "-rw-------" "...0600"
e="$(cat "$SD2/save.err" 2>/dev/null)"
assert_contains "$e" "step list" "...naming the failing step"
case "$(printf '%s\n' "$e" | sed -n 's/^saved //p')" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) r=0 ;; *) r=1 ;; esac
assert_true $r "...its stamp"
case "$(printf '%s\n' "$e" | sed -n 's/^exit //p')" in [1-9]*) r=0 ;; *) r=1 ;; esac
assert_true $r "...and its exit code ($(printf '%s\n' "$e" | sed -n 's/^exit //p'))"
start_s2
# A fresh server lists the same ids and names as the first one did, so its
# body would equal the saved one and nothing would be published: a change.
tmux -S "$S2" rename-window -t '=two:' back
R2 save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD2")" "2" "the next save publishes"
[ ! -e "$SD2/save.err" ]; assert_true $? "...and removes save.err"

echo "== a publish that fails: save.err (R3, ROOST_TEST_PUBLISH_FAIL) =="
tmux -S "$S2" rename-window -t '=two:' pubfail
out="$(ROOST_TEST_PUBLISH_FAIL=1 R2 save --auto --trigger after-rename-window 2>&1)"; rc=$?
assert_eq "$rc|$out|$(gen_of "$SD2")" "0||2" "a refused publish: silent, exit 0, gen unchanged"
assert_contains "$(cat "$SD2/save.err" 2>/dev/null)" "step publish" "...save.err names the publish step"
ls "$SD2"/.shape.* >/dev/null 2>&1; assert_eq "$?" "1" "...and no temp file is left"
R2 save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD2")" "3" "the next save publishes"
[ ! -e "$SD2/save.err" ]; assert_true $? "...and removes save.err"

echo "== the directory removed under a held saver publishes nothing into it =="
tmux -S "$S2" rename-window -t '=two:' late-write
H="$SHAPE_TMP/hold-list"
ROOST_TEST_SAVE_HOLD_AFTER_LIST="$H" R2 save --auto --trigger after-rename-window >"$SHAPE_TMP/list.out" 2>&1 & hp=$!
wait_at "$H"; assert_true $? "the saver is held after its listing"
rm -rf "$SD2"
: > "$H"; wait "$hp"; rc=$?
assert_eq "$rc|$(cat "$SHAPE_TMP/list.out")" "0|" "released: silent, exit 0"
[ ! -e "$SD2" ]; assert_true $? "...and the removed directory was not made again by the late write"
R2 save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD2")|$(nhist "$SD2")" "1|0" "the next save makes a fresh directory whose gen starts at 1"
tmux -S "$S2" kill-server 2>/dev/null

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
