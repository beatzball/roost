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
# TMUX and TMUX_PANE cleared: a run from inside a roost pane would otherwise
# hand `spawn` and `split` a pane id of the live server (test-revive.sh's R).
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
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

echo "== a hook's save never saves the NEXT server on the same socket (fix round 2) =="
# CI caught it: a hook's background save from a server that had just been
# killed ran late, listed the new server at the same socket, and published
# it over the shape a test had written. A hook names its boot (--boot); its
# save is about that server only.
cp -Rp "$SD2" "$SHAPE_TMP/sd2-hook"
B2OLD="$(tmux -S "$S2" display -p '#{start_time}-#{pid}')"
tmux -S "$S2" rename-window -t '=two:' old-server
H="$SHAPE_TMP/hold-boot"
ROOST_TEST_SAVE_HOLD_AFTER_DRAIN="$H" R2 save --auto --trigger after-rename-window --boot "$B2OLD" >"$SHAPE_TMP/hb.out" 2>&1 & hp=$!
wait_at "$H"; assert_true $? "a hook's saver of the old server is held after its drain"
tmux -S "$S2" kill-server; sleep 0.3
start_s2; tmux -S "$S2" rename-window -t '=two:' new-server
: > "$H"; wait "$hp"; rc=$?
assert_eq "$rc|$(cat "$SHAPE_TMP/hb.out")" "0|" "released after a new server took the socket: silent, exit 0"
assert_eq "$(gen_of "$SD2")" "$(gen_of "$SHAPE_TMP/sd2-hook")" "...gen unchanged: the new server was not saved by the old server's hook"
grep -q '^name new-server$' "$SD2/shape"; assert_eq "$?" "1" "...and the shape does not hold the new server"
[ ! -e "$SD2/save.err" ]; assert_true $? "...and no save.err: a gone server is not a failed save"
R2 save --auto --trigger after-rename-window --boot "$B2OLD"
assert_eq "$(gen_of "$SD2")|$( [ -e "$SD2/save.err" ] && echo err)" "$(gen_of "$SHAPE_TMP/sd2-hook")|" \
  "a hook save that starts after its server is gone: nothing written, no save.err"
R2 save --auto --trigger after-rename-window
grep -q '^name new-server$' "$SD2/shape"; assert_true $? "the new server's own save (no old boot) is written as usual"

echo "== an old hook's saver never drops the NEW server's wants (fix round 3, A) =="
# Round 3 jury (Opus probe): the old server's hook saver holds lock/; the
# server is replaced on the socket; the new server's own saves find lock/
# held and leave their wants; the old saver drains them. Only the old hook's
# OWN want may be dropped; the rest must land in a save of the live server.
OLDB="$(tmux -S "$S2" display -p '#{start_time}-#{pid}')"
H="$SHAPE_TMP/hold-lockA"
ROOST_TEST_SAVE_HOLD="$H" R2 save --auto --trigger after-rename-window --boot "$OLDB" >/dev/null 2>&1 & hp=$!
wait_at "$H"; assert_true $? "(fixture) the old server's hook saver holds lock/"
tmux -S "$S2" kill-server; sleep 0.3
start_s2; tmux -S "$S2" rename-window -t '=two:' newserver-a
NEWB="$(tmux -S "$S2" display -p '#{start_time}-#{pid}')"
R2 save --auto --trigger spawn
R2 save --auto --trigger after-rename-window --boot "$NEWB"
: > "$H"; wait "$hp"
grep -q '^name newserver-a$' "$SD2/shape"; assert_true $? "released: the new server's wants were saved (the shape holds newserver-a)"
assert_eq "$(ls "$SD2/want" 2>/dev/null | tr '\n' ' ')" "" "...and no want is left behind"
case " $(sed -n 's/^trigger //p;/^$/q' "$SD2/shape") " in *" spawn "*) r=0 ;; *) r=1 ;; esac
assert_true $r "...the verb's own cause is in that save's trigger"

echo "== a killed server's late hook never touches the next server's pending panes (fix round 3, B) =="
# Round 3 jury (Fable replay): a late hook of a killed server wrote
# want/<trigger>.%N for its kill difference before its boot check, and the
# next server's saver ran the arrow for its own %N: it cancelled that
# server's pending resume.
AB="$(tmux -S "$S2" display -p '#{start_time}-#{pid}')"
tmux -S "$S2" kill-server; sleep 0.3
start_s2; BB="$(tmux -S "$S2" display -p '#{start_time}-#{pid}')"
R2 save --auto --trigger after-kill-pane --boot "$AB" --ids-before "x%0 %1 " --ids-after "x%0 "
[ -n "$(ls "$SD2/closed/$AB"/kill.* 2>/dev/null)" ]; assert_true $? "a late hook of the killed server still writes its kill file under its own boot"
assert_eq "$(ls "$SD2/want" 2>/dev/null | grep -c '%1')" "0" "...but leaves no per-pane want"
mkdir -p "$SD2/pending/$BB"; printf 'was %%9\nharness claude\nsession_id 3fa3c0de-0000-4abc-8def-000000000901\ncwd /tmp\n' > "$SD2/pending/$BB/%1"
# The second guard: a foreign per-pane want that got into want/ anyway (a
# server that died between a hook's check and the drain) carries its boot.
mkdir -p "$SD2/want"; : > "$SD2/want/after-kill-pane.%1@$AB"
tmux -S "$S2" rename-window -t '=two:' newserver-b
R2 save --auto --trigger after-rename-window --boot "$BB"
[ -f "$SD2/pending/$BB/%1" ]; assert_true $? "the next server's pending %1 is still there after its own save"
grep -q '^name newserver-b$' "$SD2/shape"; assert_true $? "...and that save was published"

echo "== a publish that fails: save.err (R3, ROOST_TEST_PUBLISH_FAIL) =="
tmux -S "$S2" rename-window -t '=two:' pubfail
gpf="$(gen_of "$SD2")"
out="$(ROOST_TEST_PUBLISH_FAIL=1 R2 save --auto --trigger after-rename-window 2>&1)"; rc=$?
assert_eq "$rc|$out|$(gen_of "$SD2")" "0||$gpf" "a refused publish: silent, exit 0, gen unchanged"
assert_contains "$(cat "$SD2/save.err" 2>/dev/null)" "step publish" "...save.err names the publish step"
assert_eq "$(ls -A "$SD2" | grep -c '^\.shape\.')" "0" "...and no temp file is left"
R2 save --auto --trigger after-rename-window
assert_eq "$(gen_of "$SD2")" "$((gpf + 1))" "the next save publishes"
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

echo "== the user manager stopping: a logout's teardown publishes nothing (#235) =="
# Measured (docs/airig/probes/persist-logout.md): a Linux logout without
# linger stops the user manager, which ends every agent's scope about 5 s
# before it kills the server; the server's pane-died save demoted every key,
# and the next login restored shells. Every hook of that teardown reads
# `systemctl --user is-system-running` = stopping; a normal death reads
# running. A stub systemctl on PATH answers from a file, so this runs the
# same on macOS (which has no systemctl) and on Linux.
SC="$SHAPE_TMP/sysctl"; mkdir -p "$SC"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\n[ -s "%s/answer" ] || exit 1\ncat "%s/answer"\n' "$SC" "$SC" "$SC" > "$SC/systemctl"
chmod +x "$SC/systemctl"
S3="$TMUX_TMPDIR/s3"
R3() { PATH="$SC:$PATH" ROOST_SOCKET="$S3" "$ROOST" "$@"; }
SD3="$ROOST_SHAPE_DIR/$(roost_shape_key -S "$S3")"
tmux -S "$S3" -f /dev/null new-session -d -s three -x 120 -y 40 'ENV= exec /bin/sh'
# A pane that reports a claude conversation but runs a shell: what an agent's
# pane is once the agent died (the probe's `command roost-pane-shell`). Its
# save is the demotion, a `stale_reason`.
p3="$(tmux -S "$S3" new-window -d -P -F '#{pane_id}' -t '=three:' 'ENV= exec /bin/sh')"
tmux -S "$S3" set -p -t "$p3" @roost-harness claude \; set -p -t "$p3" @roost-session 3fa3c0de-0000-4abc-8def-000000000235
echo running > "$SC/answer"
R3 save --auto --trigger after-new-window
g3="$(gen_of "$SD3")"
assert_eq "$g3" "1" "the third server's first save"
cp -p "$SD3/shape" "$SHAPE_TMP/sd3-before"
tmux -S "$S3" rename-window -t "$p3" died-in-a-logout
echo stopping > "$SC/answer"; : > "$SC/calls"
out="$(R3 save --auto --trigger pane-died 2>&1)"; rc=$?
assert_eq "$rc|$out|$(gen_of "$SD3")|$(nhist "$SD3")" "0||$g3|0" "stopping: a death save publishes nothing, silent, exit 0"
cmp -s "$SD3/shape" "$SHAPE_TMP/sd3-before"; assert_true $? "...shape is the save before the teardown"
[ ! -e "$SD3/save.err" ]; assert_true $? "...and no save.err: a teardown is not a failed save"
[ ! -e "$SD3/want" ] && [ ! -e "$SD3/lock" ]; assert_true $? "...and no want/ or lock/ is left"
assert_eq "$(cat "$SC/calls")" "--user is-system-running" "...asked the user manager once"
out="$(R3 save --trigger save 2>&1)"; rc=$?
assert_eq "$rc|$(gen_of "$SD3")" "1|$g3" "stopping: roost save by hand writes nothing either, exit 1"
assert_contains "$out" "the user manager is stopping" "...and says why"
# A teardown round touches nothing else either (#239): the check comes
# before the hook's arrows and before the listing. The dying agent's pane
# has a pending resume (pending/<boot>/%N) and a launch claim; a pane-died
# round of a running manager renames the file to %N.failed and drops the
# claim (the control below), a teardown round leaves both as they were.
b3="$(tmux -S "$S3" display -p '#{start_time}-#{pid}')"
pend3="$SD3/pending/$b3"; mkdir -p "$pend3"
printf 'harness claude\nsession_id 3fa3c0de-0000-4abc-8def-000000000235\n' > "$pend3/$p3"; chmod 600 "$pend3/$p3"
cl3="$XDG_STATE_HOME/roost/launch-claims/$(roost_shape_key -S "$S3")/claims/$b3/c235"
live_pid; mkdir -p "$cl3"; printf '%s\n' "$p3" > "$cl3/pane"; ln -s "$LIVE $LIVE_ST" "$cl3/owner"
echo stopping > "$SC/answer"
R3 save --auto --socket "$S3" --boot "$b3" --trigger pane-died --pane "$p3"
assert_eq "$(gen_of "$SD3")|$(ls "$pend3")|$([ -d "$cl3" ] && echo held)" "$g3|$p3|held" \
  "stopping: the death round renames no pending file and drops no claim"
# A teardown round whose listing fails (the server SIGKILLed while the round
# waits, as a logout does about 5 s after the agents die) writes no save.err
# either: the next login would show a stale save error. The round is held
# after its drain (the seam the "listing that fails mid-round" case above
# uses), the server killed, then released; with the manager running the same
# plant writes save.err, as before (the control).
S3b="$TMUX_TMPDIR/s3b"
SD3b="$ROOST_SHAPE_DIR/$(roost_shape_key -S "$S3b")"
R3b() { PATH="$SC:$PATH" ROOST_SOCKET="$S3b" "$ROOST" "$@"; }
for ans in stopping running; do
  tmux -S "$S3b" -f /dev/null new-session -d -s threeb 'ENV= exec /bin/sh'
  echo running > "$SC/answer"; R3b save --auto --trigger after-new-session
  rm -f "$SD3b/save.err"
  tmux -S "$S3b" rename-window -t '=threeb:' "gone-$ans"
  H="$SHAPE_TMP/hold-3b-$ans"
  ROOST_TEST_SAVE_HOLD_AFTER_DRAIN="$H" R3b save --auto --trigger after-rename-window >/dev/null 2>&1 & hp=$!
  wait_at "$H" || echo "  (the $ans saver never reached its drain)"
  tmux -S "$S3b" kill-server 2>/dev/null
  echo "$ans" > "$SC/answer"; : > "$H"; wait "$hp"
  e=none; [ -e "$SD3b/save.err" ] && e=written
  if [ "$ans" = stopping ]; then err_stopping="$e"; else err_running="$e"; fi
done
assert_eq "$err_stopping" "none" "stopping, the server killed mid-round: no save.err"
assert_eq "$err_running" "written" "(control) running, the same plant: save.err is written, as before"
# The control: the same change, the manager running. This is the single
# death of today, and it must still demote.
echo running > "$SC/answer"
R3 save --auto --trigger pane-died --socket "$S3" --boot "$b3" --pane "$p3"
assert_eq "$(gen_of "$SD3")" "$((g3 + 1))" "running: the death save publishes"
assert_eq "$(ls "$pend3")|$([ -d "$cl3" ] && echo held || echo dropped)" "$p3.failed|dropped" \
  "...renames the pending file to %N.failed and drops the claim (the plant works)"
# `exited` here, since the pane runs sh (an agent that exited to its shell);
# the probe's pane ran roost-pane-shell and read `other`. Either is a demotion.
assert_eq "$(awk -v p="$p3" '$0=="id "p{f=1} f&&/^stale_reason /{print $2; exit}' "$SD3/shape")" "exited" \
  "...and demotes the dead agent's key, as before"
# No answer (systemctl present, no manager: a container, no session bus):
# saves as today.
tmux -S "$S3" rename-window -t "$p3" no-manager
: > "$SC/answer"
R3 save --auto --trigger pane-died
assert_eq "$(gen_of "$SD3")" "$((g3 + 2))" "systemctl with no answer: the save publishes"
# No systemctl on PATH at all (macOS): not asked, saves as today. Only
# where a PATH without the stub really has none: on Linux /usr/bin holds the
# real one, and the case above (no answer) is what a runner there reaches.
NOSC="$(dirname "$(command -v tmux)"):/usr/bin:/bin"
if ! PATH="$NOSC" command -v systemctl >/dev/null 2>&1; then
  tmux -S "$S3" rename-window -t "$p3" no-systemctl
  : > "$SC/calls"
  PATH="$NOSC" ROOST_SOCKET="$S3" "$ROOST" save --auto --trigger pane-died
  assert_eq "$(gen_of "$SD3")|$(cat "$SC/calls")" "$((g3 + 3))|" "no systemctl: the save publishes, the stub never asked"
else
  echo "  (skip: this machine has a systemctl in /usr/bin; the no-answer case covers it)"
fi
# A user manager that holds its socket but does not answer (#239): the read
# would wait for the D-Bus timeout, about 25 s, holding lock/ while it did,
# and a by-hand `roost save` waits up to 30 s for that lock. Bounded with
# `timeout 2` where `timeout` exists (every Linux, which is the only place a
# systemctl is); a read cut off is "not stopping", so the round saves as
# today. macOS has no `timeout` (nor a systemctl), so there it is not run.
if command -v timeout >/dev/null 2>&1; then
  mkdir -p "$SC/hang"
  printf '#!/bin/sh\necho "$*" >> "%s/calls"\nexec sleep 20\n' "$SC" > "$SC/hang/systemctl"
  chmod +x "$SC/hang/systemctl"
  tmux -S "$S3" rename-window -t "$p3" manager-hangs
  gh="$(gen_of "$SD3")"; : > "$SC/calls"; t0=$SECONDS
  PATH="$SC/hang:$PATH" ROOST_SOCKET="$S3" "$ROOST" save --auto --trigger pane-died
  t1=$((SECONDS - t0))
  assert_eq "$(gen_of "$SD3")|$(cat "$SC/calls")" "$((gh + 1))|--user is-system-running" \
    "a manager that does not answer: the save publishes (asked once)"
  [ "$t1" -lt 12 ]; assert_true $? "...within a bound, not the read's own wait (took ${t1} s; the stub sleeps 20)"
  [ ! -e "$SD3/lock" ]; assert_true $? "...and lock/ is released"
else
  echo "  (skip: no timeout on PATH; the read is not bounded here, and there is no systemctl either)"
fi
tmux -S "$S3" kill-server 2>/dev/null

# --- roost's own verbs save, and the hooks save the rest (Task 4.7) ----------
echo "== every structural change makes a new shape; trigger says what (§8.1 test 8) =="
TL set -g @roost-home "$PWD"
TL source-file tmux/roost.conf
settle() { shape_settle "$SD"; }
# saved_since GEN NAME — exit 0 when a save newer than GEN (shape, or a
# history file) carries NAME in its trigger line.
saved_since() {
  local f g
  for f in "$SD/shape" "$SD"/history/*; do
    [ -f "$f" ] || continue
    g="$(sed -n 's/^gen //p;/^$/q' "$f")"
    [ "${g:-0}" -gt "$1" ] 2>/dev/null || continue
    case " $(sed -n 's/^trigger //p;/^$/q' "$f") " in *" $2 "*) return 0 ;; esac
  done
  return 1
}
# verb LABEL TRIGGER CMD... — run a change, settle, and assert a new shape
# whose trigger names TRIGGER.
verb() {
  local label="$1" want="$2" g; shift 2
  settle; g="$(gen_of "$SD")"
  "$@" >/dev/null 2>&1
  settle
  [ "$(gen_of "$SD")" -gt "$g" ] 2>/dev/null; assert_true $? "$label: a new shape"
  saved_since "$g" "$want"; assert_true $? "...its trigger names $want ($(sed -n 's/^trigger //p;/^$/q' "$SD/shape"))"
}
settle
mp="$(TL display -p -t '=main:1' '#{pane_id}')"
verb "roost spawn" spawn R spawn helper1
verb "roost split" split env -u TMUX ROOST_SOCKET=roost TMUX_PANE="$mp" "$ROOST" split -n helper2
verb "rename-window" after-rename-window TL rename-window -t '=main:1' verbs
verb "kill-pane" after-kill-pane TL kill-pane -t "$(TL list-panes -a -F '#{pane_id} #{@roost-name}' | awk '$2 == "helper2" { print $1 }')"
TL new-window -d -t '=main:' -n lone 'ENV= exec /bin/sh'; settle
verb "move-pane of a window's last pane" window-unlinked TL move-pane -d -s '=main:lone' -t "$mp"
x="$(TL split-window -d -P -F '#{pane_id}' -t "$mp" 'ENV= exec /bin/sh')"; settle
verb "break-pane" window-linked TL break-pane -d -s "$x"
TL new-session -d -s other 'ENV= exec /bin/sh'; settle
verb "move-window" window-linked TL move-window -d -s "$(TL display -p -t "$x" '#{window_id}')" -t '=other:'
verb "link-window" window-linked TL link-window -d -s '=other:' -t '=main:'
verb "select-layout" after-select-layout TL select-layout -t "$mp" tiled
ip="$(TL new-window -d -P -F '#{pane_id}' -t '=main:' -c "$SHAPE_TMP" 'ENV= exec /bin/sh')"; settle
UID1=3fa3c0de-7777-4abc-8def-000000000007
verb "identify" identify TL send-keys -t "$ip" "$ROOST identify --session $UID1 --cwd $SHAPE_TMP --harness claude" Enter
stub_store_add 3fa3c0de-8888-4abc-8def-000000000008 "$SHAPE_TMP"
rv="$(TL new-window -d -P -F '#{pane_id}' -t '=main:' -c "$SHAPE_TMP" "$STUB_BIN/claude 600")"
i=0; while [ "$i" -lt 50 ] && [ "$(TL display -p -t "$rv" '#{pane_current_command}')" != claude ]; do sleep 0.1; i=$((i+1)); done
TL set-option -p -t "$rv" @roost-harness claude \; set-option -p -t "$rv" @roost-session 3fa3c0de-8888-4abc-8def-000000000008 \
  \; set-option -p -t "$rv" @roost-cwd "$SHAPE_TMP" \; set-option -p -t "$rv" @agent_state idle
# An option fires no hook: saved by hand, so the shape holds the key that
# revive's respawn clears (§4.1 step 7) and the save after it has a change.
R save >/dev/null 2>&1
verb "roost revive" respawn env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" revive "$rv"
cp_="$(TL split-window -d -P -F '#{pane_id}' -t "$mp" 'ENV= exec /bin/sh')"; settle
verb "roost close" close R close "$cp_"

echo "== 50 roost state working on a working pane write no shape =="
TL set-option -p -t "$mp" @agent_state working; settle
g="$(gen_of "$SD")"; h="$(nhist "$SD")"
i=0; while [ "$i" -lt 50 ]; do TMUX="$SHAPE_SOCK,1,0" TMUX_PANE="$mp" "$ROOST" state working >/dev/null 2>&1; i=$((i+1)); done
settle
assert_eq "$(gen_of "$SD"):$(nhist "$SD")" "$g:$h" "50 roost state working: no new shape"

echo "== restore's final save: trigger restore, the only one during a restore =="
# From a copy taken before the kill, by path: the hooks save the fleet
# without `other` the moment it goes, and its kill file would filter a
# STAMP-GEN pick (§3.6 step 4); a FILE is the caller's own choice.
R save >/dev/null 2>&1; settle; cp "$SD/shape" "$SHAPE_TMP/with-other"
TL kill-session -t '=other'; settle
g="$(gen_of "$SD")"
R restore --no-resume --from "$SHAPE_TMP/with-other" --only other >/dev/null 2>&1; settle
assert_eq "$(gen_of "$SD")" "$((g + 1))" "a restore publishes exactly one save"
case " $(sed -n 's/^trigger //p;/^$/q' "$SD/shape") " in *" restore "*) r=0 ;; *) r=1 ;; esac
assert_true $r "...with trigger restore ($(sed -n 's/^trigger //p;/^$/q' "$SD/shape"))"
TL has-session -t '=other' 2>/dev/null; assert_true $? "...after placing the session"

echo "== ten roost spawns in parallel: one fleet, unique history, gen monotonic =="
settle; g0="$(gen_of "$SD")"; h0="$(ls "$SD/history")"
i=0; while [ "$i" -lt 10 ]; do R spawn "par$i" >/dev/null 2>&1 & i=$((i+1)); done
wait; settle
n=0; i=0; while [ "$i" -lt 10 ]; do grep -q "^name par$i\$" "$SD/shape" && n=$((n+1)); i=$((i+1)); done
assert_eq "$n" "10" "the newest shape holds all ten panes"
new="$(ls "$SD/history" | grep -vxF "$h0" | wc -l | tr -d ' ')"
[ "$new" -le 10 ]; assert_true $? "...at most ten new history files ($new)"
assert_eq "$(ls "$SD/history" | sed 's/.*-//' | sort | uniq -d)" "" "...every history gen unique"
gens="$(for f in "$SD"/history/*; do sed -n 's/^gen //p;/^$/q' "$f"; done | sort -n | tr '\n' ' ')"
names="$(ls "$SD/history" | sed 's/.*-//' | sort -n | tr '\n' ' ')"
assert_eq "$gens" "$names" "...each history file's own gen is its name's gen"
[ "$(gen_of "$SD")" -gt "$g0" ] && [ "$(sed -n 's/^gen //p;/^$/q' "$SD/shape")" = "$(gen_of "$SD")" ]
assert_true $? "...and gen moved forward, shape carrying the newest"

echo "== no process per pane: a save costs the same ps calls at 4 panes as at 40 (Task 4.11) =="
# A recording `ps` first on PATH, for the save only. Half the panes carry a
# key (an exited agent's identity on a shell), so the agreement table runs
# for them: other tools' savers ran a process per pane and pinned whole
# machines after a sleep.
PSB="$SHAPE_TMP/ps-rec"; mkdir -p "$PSB"; REALPS="$(command -v ps)"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\nexec "%s" "$@"\n' "$PSB" "$REALPS" > "$PSB/ps"; chmod +x "$PSB/ps"
ps_calls() { # SOCKET NPANES -> how many times one save --auto called ps
  local s="$1" n="$2" i=1 p
  tmux -S "$s" -f /dev/null new-session -d -s c -x 250 -y 80 'ENV= exec /bin/sh'
  while [ "$i" -lt "$n" ]; do
    p="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' -t '=c:' 'ENV= exec /bin/sh')"
    [ $((i % 2)) = 0 ] && tmux -S "$s" set -p -t "$p" @roost-harness claude \; set -p -t "$p" @roost-session "3fa3c0de-0000-4abc-8def-$(printf '%012d' "$i")"
    i=$((i + 1))
  done
  sleep 0.5; : > "$PSB/calls"
  PATH="$PSB:$PATH" ROOST_SOCKET="$s" "$ROOST" save --auto --trigger save
  wc -l < "$PSB/calls" | tr -d ' '
  tmux -S "$s" kill-server 2>/dev/null
}
c4="$(ps_calls "$TMUX_TMPDIR/p4s" 4)"; c40="$(ps_calls "$TMUX_TMPDIR/p40s" 40)"
assert_eq "$c40" "$c4" "save --auto calls ps the same number of times on 40 panes as on 4 ($c4)"
[ "$c4" -le 2 ]; assert_true $? "...at most 2 (the owner rule's own read, and one for every keyed pane at once)"
n40="$(grep -c '^stale_reason ' "$ROOST_SHAPE_DIR/$(roost_shape_key -S "$TMUX_TMPDIR/p40s")/shape" 2>/dev/null)"
assert_eq "$n40" "19" "...and the 40-pane save did judge its 19 keyed panes"

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
