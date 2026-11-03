#!/usr/bin/env bash
# R2 — never start a second server under a live one's name (#192; the plan's
# coordinator ruling R2, Task 5.4).
#
# Field lesson: an autostart tool, a reconnecting client and an over-eager
# start path each started a SECOND tmux server under the same name while the
# first still ran with its socket file gone (a temp cleaner, a crash of the
# socket's directory). The new server took the name, and the live fleet in the
# old one became unreachable. roost starts a server in three places —
# ensure_session, restore's Server step and (Task 5.6) `persist --at-login` —
# and each must first ask whether the newest save's server is still alive.
#
# The positive case runs a real lost socket: the server roost started, its
# socket file removed by hand, then `spawn` and `restore` must refuse and name
# the pid; `kill -USR1 N` (tmux recreates its socket on SIGUSR1) must bring
# the old fleet back. The controls are the three ways a recorded pid can be
# something else, each of which must start a server as today: a dead pid, a
# live pid that is not tmux, and a tmux whose start time is not the boot's (a
# pid reused after a reboot must never block).
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh

shape_test_setup
# `roost wiring apply` runs when roost starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary, as
# tests/test-shape-place.sh does.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
# `spawn` puts a helper in the CALLER's session when TMUX_PANE is set; a run
# from inside a roost pane would hand it a pane of another server.
unset TMUX TMUX_PANE
LOST_PID=""
OTHER_SOCK=""
SLEEP_PID=""
# The lost-socket server cannot be reached by its socket path once that file
# is gone, so teardown cannot kill it with `kill-server`. Its pid was read
# from THIS file's own server, so a TERM to that pid touches nothing else.
cleanup() {
  if [ -n "$LOST_PID" ] && kill -0 "$LOST_PID" 2>/dev/null; then
    # A second server that took the socket (what this file catches when the
    # guard is broken) is killed first, by the path, or it outlives the run.
    [ -n "${SHAPE_SOCK:-}" ] && tmux -S "$SHAPE_SOCK" kill-server 2>/dev/null
    kill -USR1 "$LOST_PID" 2>/dev/null; sleep 0.3
    [ -n "${SHAPE_SOCK:-}" ] && tmux -S "$SHAPE_SOCK" kill-server 2>/dev/null
    kill "$LOST_PID" 2>/dev/null
  fi
  [ -n "$OTHER_SOCK" ] && tmux -S "$OTHER_SOCK" kill-server 2>/dev/null
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  shape_test_teardown
}
trap cleanup EXIT

R="$PWD/bin/roost"
SD="$ROOST_SHAPE_DIR/roost"

# The save lands from a hook in the background (§3.4): wait until `shape`
# names this server's boot before a case reads it.
wait_boot() {
  local want="$1" i=0
  while [ "$i" -lt 100 ]; do
    [ "$(sed -n 's/^boot //p;/^$/q' "$SD/shape" 2>/dev/null)" = "$want" ] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

# set_boot VALUE — the newest save's `boot` header line, rewritten in place.
set_boot() {
  sed "s/^boot .*/boot $1/" "$SD/shape" > "$SD/shape.t" && mv "$SD/shape.t" "$SD/shape"
}

echo "== a lost socket: spawn and restore start nothing, and name the pid =="
TL kill-server
sleep 0.2
out="$("$R" spawn a sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "roost spawn a starts the server (exit $rc: $out)"
LOST_PID="$(TL display -p '#{pid}')"
boot="$(TL display -p '#{start_time}-#{pid}')"
wait_boot "$boot"
assert_eq "$(sed -n 's/^boot //p;/^$/q' "$SD/shape")" "$boot" "a save landed with this server's boot"
shape_settle "$SD" || true

rm -f "$SHAPE_SOCK"
assert_eq "$(TL ls >/dev/null 2>&1 && echo up || echo down)" "down" "with its socket file gone, the server no longer answers"

out="$("$R" spawn b sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "roost spawn b exits 1"
assert_eq "$out" "roost: the tmux server (pid $LOST_PID) is still running but its socket is gone; kill -USR1 $LOST_PID recreates it" \
  "spawn prints R2's line with the real pid"
assert_eq "$([ -e "$SHAPE_SOCK" ] && echo made || echo none)" "none" "no second server bound the socket path"
assert_eq "$(kill -0 "$LOST_PID" 2>/dev/null && echo alive || echo gone)" "alive" "the first server is still running"

out="$("$R" restore 2>&1)"; rc=$?
assert_eq "$rc" "1" "roost restore exits 1"
assert_eq "$out" "roost: the tmux server (pid $LOST_PID) is still running but its socket is gone; kill -USR1 $LOST_PID recreates it" \
  "restore prints the same line"
assert_eq "$([ -e "$SHAPE_SOCK" ] && echo made || echo none)" "none" "restore bound no socket either"

out="$("$R" 2>&1 </dev/null)"; rc=$?
assert_eq "$rc" "1" "a bare roost (attach) exits 1 too"
assert_contains "$out" "kill -USR1 $LOST_PID recreates it" "...with the same line"

kill -USR1 "$LOST_PID"
i=0; while [ ! -S "$SHAPE_SOCK" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$(TL display -p '#{pid}' 2>/dev/null)" "$LOST_PID" "kill -USR1 brings the socket back to the same server"
assert_eq "$(TL list-windows -t =main -F '#{window_name}' | grep -c '^a$')" "1" "...with the fleet in it (window a)"
assert_eq "$(TL list-windows -a -F '#{session_name}' | grep -c .)" "2" "...and nothing was placed by the refused restore (main's two windows)"
out="$("$R" spawn b sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "now roost spawn b works (exit $rc: $out)"
TL kill-server
LOST_PID=""
sleep 0.3

echo "== controls: a recorded pid that is not that server starts one as today =="
# control 1: the recorded pid is dead.
sleep 0 & dead=$!; wait "$dead" 2>/dev/null
set_boot "$(date +%s)-$dead"
out="$("$R" spawn c1 sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "a dead pid: spawn starts a server (exit $rc: $out)"
assert_eq "$(TL ls >/dev/null 2>&1 && echo up || echo down)" "up" "...and it answers"
shape_settle "$SD" || true
TL kill-server; sleep 0.3

# control 2: the recorded pid is alive, with the boot's start time, but is
# not tmux (this file's own sleep).
sleep 60 & SLEEP_PID=$!
sleep 0.2
set_boot "$(date +%s)-$SLEEP_PID"
out="$("$R" spawn c2 sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "a live pid that is not tmux: spawn starts a server (exit $rc: $out)"
assert_eq "$(TL ls >/dev/null 2>&1 && echo up || echo down)" "up" "...and it answers"
shape_settle "$SD" || true
TL kill-server; sleep 0.3
kill "$SLEEP_PID" 2>/dev/null; wait "$SLEEP_PID" 2>/dev/null; SLEEP_PID=""

# control 3: the recorded pid is a live tmux server, but it started at
# another time than the boot names — what a pid reused after a reboot looks
# like. A throwaway server on a socket of this file's own.
OTHER_SOCK="$SHAPE_TMP/other.sock"
tmux -S "$OTHER_SOCK" -f /dev/null new-session -d 'sleep 60'
op="$(tmux -S "$OTHER_SOCK" display -p '#{pid}')"
ost="$(tmux -S "$OTHER_SOCK" display -p '#{start_time}')"
set_boot "$((ost - 100))-$op"
out="$("$R" spawn c3 sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "a tmux with another start time: spawn starts a server (exit $rc: $out)"
assert_eq "$(TL ls >/dev/null 2>&1 && echo up || echo down)" "up" "...and it answers"
shape_settle "$SD" || true
TL kill-server; sleep 0.3

# control 3, the other half: the SAME live tmux, with its own start time,
# does block — the one thing the start-time compare is allowed to decide.
set_boot "$ost-$op"
out="$("$R" spawn c4 sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "the same tmux with its own start time blocks (it IS a live server of that boot)"
assert_contains "$out" "(pid $op)" "...and names it"
tmux -S "$OTHER_SOCK" kill-server 2>/dev/null; OTHER_SOCK=""

# No save at all: nothing to read, nothing blocks.
rm -f "$SD/shape"
out="$("$R" spawn c5 sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "no save: spawn starts a server (exit $rc: $out)"
shape_settle "$SD" || true

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
