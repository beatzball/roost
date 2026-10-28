#!/usr/bin/env bash
# Placement (#51, #191): the placeholder a placed pane runs, and `roost
# restore` putting a saved shape back as shells. Design:
# docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.3 (placement),
# §4.7 (the placeholder and who owns a pane), §2.10 (what it rests on).
#
# "A shell started in this pane" is read from $HOME/shells.log, which the
# redirected HOME's .bash_profile and .bashrc append to (tests/lib-shape.sh),
# never from #{pane_current_command}: on macOS that reads `bash` for the
# placeholder too (§2.10).
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT
HERE="$PWD"
PH="$HERE/scripts/roost-placeholder"
# A bash the handover can start, so the rc files above run in it. The server's
# default-shell otherwise comes from the developer's $SHELL (zsh here), which
# reads neither file.
BASH_BIN="$(command -v bash)"
TL set -g default-shell "$BASH_BIN"
# A server restore starts takes its default-shell from $SHELL; bash, so a
# shell it hands over reads the rc files above too.
export SHELL="$BASH_BIN"

# wait_screen PANE TEXT [TENTHS] — until TEXT is on the pane's screen.
wait_screen() {
  local i=0 n="${3:-20}"
  while [ "$i" -lt "$n" ]; do
    TL capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}
# wait_file PATH [TENTHS] — until PATH exists.
wait_file() { local i=0 n="${2:-30}"; while [ "$i" -lt "$n" ]; do [ -e "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# shells_wait PANE — until shells.log has a line for PANE (3 s).
shells_wait() { local i=0; while [ "$i" -lt 30 ]; do [ -n "$(shells_for "$1")" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
PLACING='roost restore is placing this session - press any key for a shell'
CLAIMED='roost restore is placing this pane'
RD="$SHAPE_TMP/restoring"; mkdir -p "$RD"
# placeholder FILE -> a new pane running the placeholder by its own path, as argv.
placeholder() {
  local p
  p="$(TL new-window -d -P -F '#{pane_id}' -t shp: 'sleep 600')"
  TL set -p -t "$p" remain-on-exit failed
  TL respawn-pane -k -t "$p" "$PH" "$1" --placing
  printf '%s\n' "$p"
}

echo "== the placing placeholder (Task 1.11) =="
F="$RD/place.1"; : > "$F"
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"; assert_true $? "within 2 s the screen shows the placing line"
assert_eq "$(shells_for "$p")" "" "no shell has started in it"
pid="$(TL display -p -t "$p" '#{pane_pid}')"
TL send-keys -t "$p" x
wait_file "$F.taken"; assert_true $? "one key: the placeholder wins F -> F.taken"
[ ! -e "$F" ]; assert_true $? "...F is gone"
shells_wait "$p"; assert_eq "$(shells_for "$p" | wc -l | tr -d ' ')" "1" "...and a shell started in the pane (one shells.log line)"
assert_eq "$(TL display -p -t "$p" '#{pane_pid}')" "$pid" "...in the same process: the placeholder exec'd it"
assert_eq "$(TL show -pqv -t "$p" remain-on-exit)" "" "remain-on-exit is unset on the pane after a winning key"

F="$RD/place.2"; : > "$F"
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"
mv "$F" "$F.used"     # restore won T2 first
TL send-keys -t "$p" x
wait_screen "$p" "$CLAIMED"; assert_true $? "F.used first, then a key: the screen says restore is placing this pane"
sleep 1
assert_eq "$(shells_for "$p")" "" "...no shell started (never a shell after a lost rename)"
[ -e "$F.used" ] && [ ! -e "$F.taken" ]; assert_true $? "...and F.used is still there"

F="$RD/place.3"; : > "$F"
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"
TL send-keys -t "$p" -l 'echo keep-me'; TL send-keys -t "$p" C-a
shells_wait "$p"; sleep 0.5
TL send-keys -t "$p" -l 'echo LINE-WAS-['; TL send-keys -t "$p" C-e; TL send-keys -t "$p" -l ']'; TL send-keys -t "$p" Enter
wait_screen "$p" 'LINE-WAS-[]' 30; assert_true $? "typed text then C-a: the first byte ends the wait and the rest is thrown away (an empty line)"
TL capture-pane -p -t "$p" | grep -q 'keep-me'; assert_eq "$?" "1" "...keep-me never reached the shell"

F="$RD/place.4"; : > "$F"
TL set -g default-command 'exec /bin/sh'
p="$(placeholder "$F")"
wait_screen "$p" "$PLACING"
TL send-keys -t "$p" x
wait_file "$F.taken"; sleep 0.5
assert_eq "$(ps -o args= -p "$(TL display -p -t "$p" '#{pane_pid}')" | sed 's/^ *//')" "/bin/sh" \
  "a user's own default-command: the key hands over to it (exec, read at that moment)"
TL set -gu default-command

# --- restore: server, sessions, the bootstrap (Task 1.12) ---------------------
# `roost wiring apply` runs when restore starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary (tests/lib-shape.sh points
# it at the canary only because no earlier case starts a roost server).
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
ROOST="$HERE/bin/roost"
R() { ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
# mkshape NAME:CWD ... -> a shape at $SD/shape with one session per argument,
# each one window (index 1) of one pane (index 0) in CWD, 200x50.
mkshape() {
  local a n=0
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" 'boot 1-1' \
      'saved 2026-10-28T12:00:00Z' 'gen 1' 'trigger save' 'roost 0.10.0' 'tmux 3.6' 'host h' ''
    for a in "$@"; do
      printf '%s\n' "session ${a%%:*}" "id \$$n" '' "window ${a%%:*}:1" "id @$n" \
        "layout b25d,200x50,0,0,$n" 'active 1' '' "pane ${a%%:*}:1.0" "id %$n" "cwd ${a#*:}" ''
      n=$((n+1))
    done; } > "$SD/shape"
}
# server_pid — the test server's pid, empty when it is not running.
server_pid() { TL display -p '#{pid}' 2>/dev/null; }
stop_server() { TL kill-server 2>/dev/null; local i=0; while [ "$i" -lt 30 ] && [ -n "$(server_pid)" ]; do sleep 0.1; i=$((i+1)); done; }
# first_pane SESSION -> the pane id of the session's first window's first pane
first_pane() { TL list-panes -s -t "=$1:" -F '#{pane_id}' 2>/dev/null | head -1; }
# A second throwaway server whose pane runs a REAL client of the test server
# (the tests/test-notify-osc.sh way, through a pty): an attach is not a key.
OUTER="$SHAPE_TMP/outer.sock"
OT() { tmux -S "$OUTER" "$@"; }
attach_client() { # SESSION WIDTH HEIGHT -> the outer pane
  OT -f /dev/null new-session -d -x "$2" -y "$3" -s outer \
    "env -u TMUX TMUX_TMPDIR=$TMUX_TMPDIR tmux -S $SHAPE_SOCK attach -t =$1"
  local i=0; while [ "$i" -lt 30 ] && [ -z "$(TL list-clients 2>/dev/null)" ]; do sleep 0.1; i=$((i+1)); done
  OT display -p -t outer: '#{pane_id}'
}
detach_client() { OT kill-server 2>/dev/null; }
mkdir -p "$SHAPE_TMP/d1" "$SHAPE_TMP/d2" "$SHAPE_TMP/d3"

echo "== a saved session that exists is skipped; the others placed (§8.1 test 2 base) =="
TL new-session -d -s keep -c "$SHAPE_TMP" 'ENV= exec /bin/sh'
kp="$(first_pane keep)"; TL set -p -t "$kp" @roost-name keeper
mkshape "keep:$SHAPE_TMP/d1" "s2:$SHAPE_TMP/d2"
R restore >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "exit 12 when a session was skipped as existing"
assert_contains "$(cat "$SHAPE_TMP/err")" "session 'keep' exists — skipped, 1 panes not restored" "...and it is named"
assert_eq "$(TL list-panes -s -t '=keep:' -F x | wc -l | tr -d ' '):$(TL show -pqv -t "$kp" @roost-name)" "1:keeper" "nothing was added to the live session"
s2p="$(first_pane s2)"
assert_eq "$(TL display -p -t "$s2p" '#{pane_current_path}')" "$SHAPE_TMP/d2" "the other session is placed, its pane in the saved directory"
shells_wait "$s2p"; assert_eq "$(shells_for "$s2p" | wc -l | tr -d ' ')" "1" "...as a shell (one shells.log line)"
[ ! -e "$SD/restoring" ]; assert_true $? "restoring/ is removed once restore is done"
TL kill-session -t '=s2'

echo "== sessions a person made are never replaced (§8.1 test 2 a-e) =="
# Each case: a server running, the saved session's name taken by a session a
# person uses; restore skips it, exit 12, its pane's process untouched.
mkshape "ca:$SHAPE_TMP/d1" "cb:$SHAPE_TMP/d1" "cc:$SHAPE_TMP/d1" "cd:$SHAPE_TMP/d1" "ce:$SHAPE_TMP/d1"
TL new-session -d -s ca -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=ca:' 'sleep 60 &' Enter
TL new-session -d -s cb -c "$SHAPE_TMP" "$BASH_BIN"
TL new-session -d -s cc -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=cc:' 'sleep 60' Enter
TL new-session -d -s cd -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=cd:' -l 'echo keep-me'; TL send-keys -t '=cd:' C-a
TL new-session -d -s ce -c "$SHAPE_TMP" "$BASH_BIN"; TL send-keys -t '=ce:' 'cd /tmp' Enter; TL send-keys -t '=ce:' 'true' Enter
sleep 1
for s in ca cb cc cd ce; do eval "pid_$s=\$(TL display -p -t \"\$(first_pane $s)\" '#{pane_pid}')"; done
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "(a)-(e) exit 12"
for s in ca cb cc cd ce; do
  eval "want=\$pid_$s"
  assert_eq "$(TL display -p -t "$(first_pane $s)" '#{pane_pid}')" "$want" "($s) skipped, its pane_pid unchanged"
done
TL capture-pane -p -t '=cd:' | grep -q 'echo keep-me'; assert_true $? "(d) the screen still shows the pending echo keep-me"
for s in ca cb cc cd ce; do TL kill-session -t "=$s" 2>/dev/null; done

echo "== a stopped server: restore's own bootstrap is placed into =="
mkshape "first:$SHAPE_TMP/d1" "second:$SHAPE_TMP/d2"
stop_server
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "exit 0 (the bootstrap was replaceable)"
fp="$(first_pane first)"
assert_eq "$(TL display -p -t "$fp" '#{pane_current_path}')" "$SHAPE_TMP/d1" "the first pane's cwd is the saved first pane's"
assert_eq "$(TL list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" "first second " "every saved session exists, none twice"
assert_eq "$(TL display -p -t "$fp" '#{window_width}x#{window_height}')" "200x50" "the server was made at the saved size, not 80x24"
assert_eq "$(TL show -gqv @roost-home)" "$HERE" "the server got ensure_session's globals"

echo "== (f) a key in the held bootstrap: taken, the saved session skipped =="
# Pane ids restart at %0 with every server, so a line an earlier server's %0
# left in shells.log would count for this one: start the log empty.
stop_server; rm -rf "$SD/restoring"; : > "$HOME/shells.log"
H="$SHAPE_TMP/hold"; rm -f "$H"
ROOST_TEST_RESTORE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_file "$SD/restoring/bootstrap" 50
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane first)" ]; do sleep 0.1; i=$((i+1)); done
bp="$(first_pane first)"
wait_screen "$bp" "$PLACING" 30
attach_client first 80 20 >/dev/null
TL send-keys -t "$bp" x
wait_file "$SD/restoring/bootstrap.taken"; assert_true $? "the key won: bootstrap.taken"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "12" "...the saved session of that name is skipped, exit 12"
assert_contains "$(cat "$SHAPE_TMP/err")" "the bootstrap pane was taken by a key" "...and the reason is named"
shells_wait "$bp"; assert_eq "$(shells_for "$bp" | wc -l | tr -d ' ')" "1" "...the pane is the person's shell"
detach_client

echo "== (g) a held bootstrap with a client attached at another size, no key: placed =="
stop_server; rm -rf "$SD/restoring"; rm -f "$H"
ROOST_TEST_RESTORE_HOLD="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
i=0; while [ "$i" -lt 50 ] && [ -z "$(first_pane first)" ]; do sleep 0.1; i=$((i+1)); done
attach_client first 80 20 >/dev/null
sleep 0.5; : > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "an attach is not a key: exit 0, the bootstrap placed into"
detach_client

echo "== (h) a key after restore has won the bootstrap =="
stop_server; rm -rf "$SD/restoring"; rm -f "$H"; : > "$HOME/shells.log"
ROOST_TEST_PLACE_HOLD_AFTER_USED="$H" R restore >/dev/null 2>"$SHAPE_TMP/err" &
rpid=$!
wait_file "$SD/restoring/bootstrap.used" 50
bp="$(first_pane first)"
attach_client first 100 30 >/dev/null
TL send-keys -t "$bp" x
wait_screen "$bp" "$CLAIMED"; assert_true $? "while held: the screen says restore is placing this pane"
sleep 0.5
assert_eq "$(shells_for "$bp")" "" "...no shell started"
[ -e "$SD/restoring/bootstrap.used" ]; assert_true $? "...the file is still bootstrap.used"
: > "$H"; wait "$rpid"; rc=$?
assert_eq "$rc" "0" "released: exit 0, the session placed into"
shells_wait "$bp"; assert_eq "$(shells_for "$bp" | wc -l | tr -d ' ')" "1" "...one shell, started by restore's own respawn"
detach_client

echo "== the restored server survives a resize storm from a real client =="
# Another tool's users crashed tmux this way on a server made by
# `new-session -x -y`: a client attached at a different size, then resized fast.
stop_server; rm -rf "$SD/restoring"
R restore >/dev/null 2>&1
op="$(attach_client first 80 20)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  OT resize-window -t outer: -x 100 -y 30 2>/dev/null; sleep 0.025
  OT resize-window -t outer: -x 80 -y 20 2>/dev/null; sleep 0.025
done
sleep 0.5
TL ls >/dev/null 2>&1; assert_true $? "20 resizes in one second: the restored server is still running"
detach_client

echo "== the owner rule (§3.5): restoring/ held by a live restore =="
mkshape "first:$SHAPE_TMP/d1"
mkdir -p "$SD/restoring"; printf 'pid %s\nlstart %s\n' "$$" "$(ps -o lstart= -p $$)" > "$SD/restoring/owner"
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "1" "a live owner: a second restore refuses, exit 1"
assert_contains "$(cat "$SHAPE_TMP/err")" "pid $$" "...naming the pid"
printf 'pid %s\nlstart %s\n' "$$" "Thu Jan  1 00:00:00 1970" > "$SD/restoring/owner"
R restore >/dev/null 2>&1; rc=$?
assert_eq "$rc" "12" "a live pid with another start time is a reused pid: taken over (first exists: exit 12)"
[ ! -e "$SD/restoring" ]; assert_true $? "...and restoring/ is dropped at the end"
echo "== T2b: a dead run's bootstrap is settled into a shell =="
stop_server; mkshape "first:$SHAPE_TMP/d1" "second:$SHAPE_TMP/d2"
mkdir -p "$SD/restoring"; : > "$SD/restoring/bootstrap"
sh -c 'exit 0' & dead=$!; wait "$dead"
printf 'pid %s\nlstart %s\n' "$dead" "Thu Jan  1 00:00:00 1970" > "$SD/restoring/owner"
TL -f /dev/null new-session -d -s first -c "$SHAPE_TMP/d3" -x 200 -y 50 "$PH" "$SD/restoring/bootstrap" --placing
TL set -g default-shell "$BASH_BIN"
bp="$(first_pane first)"; wait_screen "$bp" "$PLACING" 30
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "a dead owner: taken over; the dead run's session exists, so it is skipped (exit 12)"
shells_wait "$bp"; assert_eq "$(TL display -p -t "$bp" '#{pane_current_path}')" "$SHAPE_TMP/d3" "...its bootstrap is now a shell in that pane's directory"
assert_eq "$(TL list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" "first second " "...and the other saved session is placed"

echo "== dotted and numeric session names (probe 1.4) =="
TL new-session -d -s v3.69-x 'ENV= exec /bin/sh'
mkshape "v3_69-x:$SHAPE_TMP/d1" "v3.69-x:$SHAPE_TMP/d1" "1:$SHAPE_TMP/d2" 2>/dev/null
R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "12" "a saved v3_69-x that exists is skipped (exit 12)"
assert_eq "$(TL list-sessions -F '#{session_name}' | grep -c '^v3_69-x$')" "1" "...never made twice (the dotted saved name is the same session)"
assert_eq "$(TL display -p -t "$(first_pane 1)" '#{pane_current_path}')" "$SHAPE_TMP/d2" "a session named 1 is placed, its pane in its saved directory"
TL kill-session -t '=v3_69-x'; TL kill-session -t '=1'
mkshape "v3.69-x:$SHAPE_TMP/d1"
R restore >/dev/null 2>&1; rc=$?
assert_eq "$rc:$(TL display -p -t "$(first_pane v3_69-x)" '#{pane_current_path}')" "0:$SHAPE_TMP/d1" \
  "a saved dotted name that does not exist is placed (tmux stores it with _)"

echo "== session names with a backslash or \$ do not drift (R8.3) =="
stop_server
TL -f /dev/null new-session -d -s 'a\b' -c "$SHAPE_TMP/d1" 'ENV= exec /bin/sh'
TL new-session -d -s 'a$b' -c "$SHAPE_TMP/d1" 'ENV= exec /bin/sh'
before="$(TL list-sessions -F '#{session_name}' | sort)"
for cycle in 1 2; do
  R save >/dev/null 2>&1; stop_server; R restore >/dev/null 2>&1
  assert_eq "$(TL list-sessions -F '#{session_name}' | sort)" "$before" "cycle $cycle: the session names a person sees are the same, not grown ($(TL display -p '#{version}'))"
done

echo "== a session group comes back as a group (R7) =="
stop_server
TL -f /dev/null new-session -d -s gm -c "$SHAPE_TMP/d1" -x 200 -y 50 'ENV= exec /bin/sh'
TL new-session -d -t '=gm' -s gv
TL new-session -d -t '=gm' -s gw
R save >/dev/null 2>&1; npanes="$(grep -c '^pane ' "$SD/shape")"
stop_server; R restore >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" "0" "a three-member group restores, exit 0"
assert_eq "$(TL list-sessions -F '#{session_name} #{session_group}' | sort | tr '\n' ',')" "gm gm,gv gm,gw gm," "every member is back, in one group"
assert_eq "$(TL list-panes -a -F '#{pane_id}' | sort -u | wc -l | tr -d ' ')" "$npanes" "one copy of each saved pane, not one per member"
TL new-window -d -t '=gm:'
assert_eq "$(TL list-windows -t '=gv:' -F x | wc -l | tr -d ' ')" "2" "a window made in one member is visible in another"
stop_server

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
