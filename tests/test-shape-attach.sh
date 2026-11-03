#!/usr/bin/env bash
# The login half of persistent sessions (#192, Part 5): `roost persist
# --at-login` places the fleet and stops, every key kept for the first attach
# (Task 5.6); the first attach resumes them (Task 5.7, client-attached[98]);
# and ensure_session waits for, or runs, the login restore (Task 5.8).
# Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md §4.4,
# §4.6; §8.1 tests 1, 8 (e), 9 and 11.
#
# Driven against this file's own named server (tests/lib-shape.sh says why it
# is `-L roost` under a guarded TMUX_TMPDIR) with stub harnesses. No real
# launchctl or systemctl: `on` runs through the recording stubs.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh

shape_test_setup
# `roost wiring apply` runs when roost starts a server, and writes under
# XDG_CONFIG_HOME: a temp dir here, not the canary.
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
unset TMUX TMUX_PANE
# No shutdown record anywhere in this file unless a case sets one: on a Mac
# `last reboot` would otherwise decide which save a restore picks.
export ROOST_SHUTDOWN_AT=""
LOST_PID=""
cleanup() {
  if [ -n "$LOST_PID" ] && kill -0 "$LOST_PID" 2>/dev/null; then
    [ -n "${SHAPE_SOCK:-}" ] && tmux -S "$SHAPE_SOCK" kill-server 2>/dev/null
    kill -USR1 "$LOST_PID" 2>/dev/null; sleep 0.3
    [ -n "${SHAPE_SOCK:-}" ] && tmux -S "$SHAPE_SOCK" kill-server 2>/dev/null
    kill "$LOST_PID" 2>/dev/null
  fi
  shape_test_teardown
}
trap cleanup EXIT

ROOST="$PWD/bin/roost"
PH="$PWD/scripts/roost-placeholder"
R() { env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost "$ROOST" "$@"; }
SD="$ROOST_SHAPE_DIR/roost"; mkdir -p "$SD"
STUBS="$SHAPE_TMP/persist-stubs"
persist_stubs "$STUBS"
export PERSIST_LOG="$SHAPE_TMP/persist.log"; : > "$PERSIST_LOG"
OSBOOT="$(. scripts/lib/roost-shape.sh; ROOST_HOME="$PWD"; . scripts/lib/roost-persist.sh; roost_persist_os_boot)"
. scripts/lib/roost-shape.sh
. scripts/lib/roost-pending.sh

# The user's conf sets a default-command: unkeyed panes run it, and a key in a
# placeholder hands over to it (§8.1 test 1).
mkdir -p "$XDG_CONFIG_HOME/roost"
printf '%s\n' "set -g default-command 'exec /bin/sh'" > "$XDG_CONFIG_HOME/roost/roost.conf"

U1=3fa3c0de-5151-4abc-8def-000000000001
U2=3fa3c0de-5252-4abc-8def-000000000002
U3=3fa3c0de-5353-4abc-8def-000000000003
D1="$SHAPE_TMP/w/one"; D2="$SHAPE_TMP/w/two"; D3="$SHAPE_TMP/w/three"; DN="$SHAPE_TMP/w/none"
mkdir -p "$D1" "$D2" "$D3" "$DN"
stub_store_add "$U1" "$D1"; stub_store_add "$U2" "$D2"; stub_store_add "$U3" "$D3"

gen_of() { cat "$1/gen" 2>/dev/null || printf -- '-'; }
trig() { sed -n 's/^trigger //p;/^$/q' "$1" 2>/dev/null; }
sg() { printf '%s-%s\n' "$(sed -n 's/^saved //p;/^$/q' "$1" | tr -d ':-')" "$(sed -n 's/^gen //p;/^$/q' "$1")"; }
first_pane() { TL list-panes -s -t "=$1:" -F '#{pane_id}' 2>/dev/null | head -1; }
sessions() { TL list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
counts() { printf '%s/%s/%s' "$(TL list-sessions 2>/dev/null | grep -c .)" \
  "$(TL list-windows -a 2>/dev/null | grep -c .)" "$(TL list-panes -a 2>/dev/null | grep -c .)"; }
live_boot() { TL display -p '#{start_time}-#{pid}' 2>/dev/null; }
npend() { ls "$1" 2>/dev/null | grep -c '^%[0-9]*$'; }
wait_screen() { local i=0; while [ "$i" -lt "${3:-30}" ]; do
  TL capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
wait_file() { local i=0; while [ "$i" -lt "${2:-50}" ]; do [ -e "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
# wait_args PANE ARGS: the pane's own process runs exactly ARGS. Not
# #{pane_current_command}: macOS's /bin/sh is bash in sh mode and reads
# `bash` there, the same as a placeholder (#!/bin/sh) would.
wait_args() { local i=0; while [ "$i" -lt "${3:-50}" ]; do
  [ "$(ps -o args= -p "$(TL display -p -t "$1" '#{pane_pid}' 2>/dev/null)" 2>/dev/null)" = "$2" ] && return 0
  sleep 0.1; i=$((i+1)); done; return 1; }
stop_server() { TL kill-server 2>/dev/null; local i=0; while TL ls >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done; sleep 0.2; }
login_runs() { grep -c "login restore for 'roost'" "$SD/login.log" 2>/dev/null || printf 0; }

# A shape of four sessions, one pane each, of an earlier boot:
#   k1 k2 k3   a claude key each (in the stub store, so each is resumable)
#   kn         no key
# SHAPE BOOT FILE: the boot line and the file it goes to.
mkshape() {
  local n=0 boot="${1:-1700000000-11}" out="${2:-$SD/shape}" gen="${3:-1}" saved="${4:-2026-10-30T12:00:00Z}"
  pane_block() { # SESSION ID CWD EXTRA
    printf '%s\n' "session $1" "id \$$n" '' "window $1:1" "id @$n" "layout b25d,200x50,0,0,$n" 'active 1' '' \
      "pane $1:1.0" "id $2" "cwd $3"
    [ -n "$4" ] && printf '%s\n' "$4"
    printf '\n'
    n=$((n+1))
  }
  { printf '%s\n' 'roost-shape 1' 'server roost' "socket $SHAPE_SOCK" "boot $boot" \
      "saved $saved" "gen $gen" 'trigger save' 'roost 0.10.0' 'tmux 3.6' "host $(hostname)" ''
    if [ -n "${MKSHAPE_SESSIONS:-}" ]; then
      for s in $MKSHAPE_SESSIONS; do pane_block "$s" "%9${n}0" "$DN" ""; done
    else
      pane_block k1 %930 "$D1" "harness claude
session_id $U1"
      pane_block k2 %931 "$D2" "harness claude
session_id $U2"
      pane_block k3 %932 "$D3" "harness claude
session_id $U3"
      pane_block kn %933 "$DN" ""
    fi
  } > "$out"
  [ "$out" = "$SD/shape" ] && printf '%s\n' "$gen" > "$SD/gen"
  return 0
}

stop_server
rm -rf "$SD"; mkdir -p "$SD"
mkshape

echo "== §8.1 test 1: --at-login places, every keyed pane a placeholder =="
: > "$STUB_LOG"
out="$(R persist --at-login roost 2>&1)"; rc=$?
assert_eq "$rc" "0" "--at-login exits 0"
assert_eq "$(sessions)" "k1 k2 k3 kn " "...and places every saved session"
BOOT="$(live_boot)"; PEND="$SD/pending/$BOOT"
for s in k1 k2 k3; do
  p="$(first_pane "$s")"
  sc="$(TL display -p -t "$p" '#{pane_start_command}')"
  assert_prefix "$(printf '%s' "$sc" | tr -d '"')" "$PH" "$s: the pane's start command begins with the placeholder's absolute path"
  assert_not_contains "$sc" "'" "$s: ...and holds no '"
done
sleep 1
for s in k1 k2 k3; do
  p="$(first_pane "$s")"
  assert_eq "$(TL display -p -t "$p" '#{pane_dead}')" "0" "$s: one second later the pane is alive"
  wait_screen "$p" "waiting to resume claude"; assert_true $? "$s: ...and shows its waiting line"
done
pn="$(first_pane kn)"
assert_eq "$(TL display -p -t "$pn" '#{pane_start_command}' | tr -d '"')" "exec /bin/sh" "kn (no key): started with the conf's default-command"
wait_args "$pn" /bin/sh; assert_true $? "...and runs /bin/sh"
assert_eq "$(npend "$PEND")" "3" "three keyed panes: three pending files"
assert_eq "$(grep -c . "$STUB_LOG" 2>/dev/null || true)" "0" "...and nothing launched"
assert_eq "$(ls -l "$SD/login.log" | cut -c1-10)" "-rw-------" "login.log is 0600"
assert_contains "$(cat "$SD/login.log")" "agents wait for the first attach" "login.log says what it placed"
assert_contains "$out" "login restore for 'roost'" "run from a terminal, the same lines are printed"
assert_eq "$([ -n "$OSBOOT" ] && [ -f "$SD/login/$OSBOOT" ] && echo yes)" "yes" "the login/<os-boot> marker is written"
assert_eq "$([ -e "$SD/restoring" ] && echo held || echo free)" "free" "restoring/ is released"
p3="$(first_pane k3)"
TL send-keys -t "$p3" x
wait_file "$PEND/$p3.taken"; assert_true $? "a key in a placeholder takes the pane (%N.taken)"
wait_args "$p3" /bin/sh; assert_true $? "...and hands over to the conf's /bin/sh"

echo "== §8.1 test 11: a spawn's save carries the keys; a second login brings them back =="
R spawn x sh >/dev/null 2>&1; shape_settle "$SD"
body="$(cat "$SD/shape")"
for u in "$U1" "$U2" "$U3"; do assert_contains "$body" "session_id $u" "the spawn's save keeps key ${u##*-}"; done
assert_eq "$(grep -c '^resume pending$' "$SD/shape")" "2" "...two with resume pending"
assert_eq "$(grep -c '^resume taken$' "$SD/shape")" "1" "...and the taken one with resume taken"
# Dialog keys survive, the reboot half: one waiting file marked failed (the
# loop's T7), a structural save, then the server goes.
p2="$(first_pane k2)"
{ printf 'store miss\n'; cat "$PEND/$p2"; } > "$PEND/$p2.failed"; rm -f "$PEND/$p2"; chmod 600 "$PEND/$p2.failed"
R spawn y sh >/dev/null 2>&1; shape_settle "$SD"
assert_eq "$(grep -c '^resume failed store miss$' "$SD/shape")" "1" "(fixture) the structural save carries resume failed store miss"
stop_server
R persist --at-login roost >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--at-login after the server went: exit 0"
BOOT2="$(live_boot)"; PEND2="$SD/pending/$BOOT2"
assert_eq "$(npend "$PEND2")" "3" "three pending files again: waiting, taken and failed keys all come back"
o=""; for f in "$PEND2"/%*; do o="$o$(grep -c '^order [0-9]' "$f")"; done
assert_eq "$o" "111" "...each with its order line"
assert_eq "$([ -d "$PEND" ] && echo kept || echo swept)" "swept" "the old boot's pending/ is removed after the new one is written"

echo "== idempotent: three more --at-login runs on a placed fleet =="
c0="$(counts)"; l0="$(login_runs)"
printf 'HOME=/edited\nXDG_STATE_HOME=/edited/state\n' > "$SD/service.env"; cp "$SD/service.env" "$SHAPE_TMP/env.edited"
ok=0
for i in 1 2 3; do R persist --at-login roost >/dev/null 2>&1 && ok=$((ok+1)); done
assert_eq "$ok" "3" "each exits 0"
assert_eq "$(counts)" "$c0" "sessions, windows and panes are unchanged (no second bootstrap session)"
assert_eq "$(login_runs)" "$((l0 + 3))" "three login.log runs"
cmp -s "$SHAPE_TMP/env.edited" "$SD/service.env"; assert_true $? "an edited service.env is byte for byte the same after --at-login"
rm -f "$SD/service.env"

echo "== earlier boots: pending/ and claims/ swept, login.log halved past 1 MB =="
OLDB=1500000000-3
mkdir -p "$SD/pending/$OLDB"; : > "$SD/pending/$OLDB/%7"
CL="$XDG_STATE_HOME/roost/launch-claims/roost/claims"
mkdir -p "$CL/$OLDB/claude-x" "$CL/$BOOT2"
{ echo HEAD-MARK; i=0; while [ "$i" -lt 13000 ]; do printf '%0100d\n' "$i"; i=$((i+1)); done; echo TAIL-MARK; } >> "$SD/login.log"
R persist --at-login roost >/dev/null 2>&1
assert_eq "$([ -e "$SD/pending/$OLDB" ] || echo gone)" "gone" "another boot's pending/ is removed"
assert_eq "$([ -e "$CL/$OLDB" ] || echo gone)" "gone" "...and its launch claims (under the state directory)"
assert_eq "$([ -d "$CL/$BOOT2" ] && [ -d "$PEND2" ] && echo kept)" "kept" "...this boot's are kept"
sz="$(wc -c < "$SD/login.log" | tr -d ' ')"
assert_true "$([ "$sz" -lt 1048576 ] && echo 0 || echo 1)" "login.log is halved past 1 MB ($sz bytes)"
assert_contains "$(cat "$SD/login.log")" "TAIL-MARK" "...keeping its newest half"
assert_not_contains "$(cat "$SD/login.log")" "HEAD-MARK" "...and dropping the oldest"

echo "== R2 at login: a lost socket starts nothing =="
shape_settle "$SD"
LOST_PID="$(TL display -p '#{pid}')"
rm -f "$SHAPE_SOCK"
out="$(R persist --at-login roost 2>&1)"; rc=$?
assert_eq "$rc" "0" "--at-login exits 0"
assert_contains "$out" "roost: the tmux server (pid $LOST_PID) is still running but its socket is gone; kill -USR1 $LOST_PID recreates it" "...and logs R2's line"
assert_eq "$([ -e "$SHAPE_SOCK" ] && echo made || echo none)" "none" "...and starts no server"
kill -USR1 "$LOST_PID"; wait_file "$SHAPE_SOCK"
assert_eq "$(TL display -p '#{pid}')" "$LOST_PID" "(the fleet is still there after kill -USR1)"
LOST_PID=""
stop_server

echo "== the ring: an earlier boot's closed/ stays while a save of it is kept =="
B1=1600000000-7
rm -rf "$SD"; mkdir -p "$SD/history" "$SD/closed/$B1"
MKSHAPE_SESSIONS="r1 r2" mkshape "$B1" "$SHAPE_TMP/b1.shape" 5 2026-10-29T10:00:00Z
B1SG="$(sg "$SHAPE_TMP/b1.shape")"; cp "$SHAPE_TMP/b1.shape" "$SD/history/$B1SG"
r1p="$(awk '/^pane r1:/ { getline; print $2 }' "$SHAPE_TMP/b1.shape")"
printf '%s\n' "$r1p" > "$SD/closed/$B1/close.${r1p#%}"
MKSHAPE_SESSIONS="main work" mkshape 1700000000-11 "$SD/shape" 6 2026-10-30T12:00:00Z
R persist --at-login roost >/dev/null 2>&1
assert_eq "$(sessions)" "main work " "(fixture) the newest save is placed"
assert_eq "$([ -f "$SD/closed/$B1/close.${r1p#%}" ] && echo kept)" "kept" "closed/<B1>/ is kept while a B1 save is in history/"
R restore --no-resume --from "$B1SG" >/dev/null 2>&1
assert_eq "$(sessions)" "main r2 work " "restore --from that B1 save leaves the closed pane out (r1 not placed, r2 placed)"
TL kill-session -t '=r2' 2>/dev/null; shape_settle "$SD"
# The hooks' saves run in the server's environment, so the ring's size is
# set there; a save that finds an equal body publishes (and prunes) nothing.
TL set-environment -g ROOST_SHAPE_KEEP 2
for w in a b c; do TL rename-window -t '=main:1' "ring-$w"; shape_settle "$SD"; done
TL set-environment -gu ROOST_SHAPE_KEEP
assert_eq "$(ls "$SD/history" | grep -c "^$B1SG$")" "0" "(fixture) ROOST_SHAPE_KEEP=2: no B1 save is left in the ring"
R persist --at-login roost >/dev/null 2>&1
assert_eq "$([ -e "$SD/closed/$B1" ] || echo gone)" "gone" "the next --at-login removes closed/<B1>/"
stop_server

echo "== §8.1 test 8 (e): the last session ended on purpose places nothing =="
rm -rf "$SD"; mkdir -p "$SD"
STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist on >/dev/null 2>&1
R spawn solo sh >/dev/null 2>&1; shape_settle "$SD"
R kill main >/dev/null 2>&1
i=0; while TL ls >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
assert_eq "$(TL ls >/dev/null 2>&1 && echo up || echo down)" "down" "(fixture) roost kill of the only session ends the server"
out="$(R persist --at-login roost 2>&1)"; rc=$?
assert_eq "$rc" "0" "--at-login exits 0"
assert_contains "$out" "every saved pane was closed on purpose" "...and says the fleet was closed on purpose"
assert_eq "$(TL ls >/dev/null 2>&1 && echo up || echo down)" "down" "...and starts no server"
# The same, with the last save and the close in one second.
rm -rf "$SD/closed" "$SD/history" "$SD/shape" "$SD/gen"
NOW="$(date +%s)"
ROOST_TEST_NOW="$NOW" R spawn solo sh >/dev/null 2>&1; shape_settle "$SD"
ROOST_TEST_NOW="$NOW" R save >/dev/null 2>&1
ROOST_TEST_NOW="$NOW" R kill main >/dev/null 2>&1
i=0; while TL ls >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
out="$(R persist --at-login roost 2>&1)"; rc=$?
assert_eq "$rc|$(TL ls >/dev/null 2>&1 && echo up || echo down)" "0|down" "the save and the close in one second: still nothing placed, no server"
assert_contains "$out" "closed on purpose" "...and the same line"
# Torn down by its own exits (no close), inside the shutdown window: whole.
rm -rf "$SD/closed" "$SD/history" "$SD/shape" "$SD/gen"
R spawn d1 "sh -c 'while [ ! -e $SHAPE_TMP/go ]; do sleep 0.1; done'" >/dev/null 2>&1
R spawn d2 "sh -c 'while [ ! -e $SHAPE_TMP/go ]; do sleep 0.1; done'" >/dev/null 2>&1
shape_settle "$SD"
# The shell window ensure_session made goes first, by a kill (a kill file,
# so restore leaves it out); its index depends on the conf's base-index.
TL kill-window -t "$(TL list-windows -t '=main' -F '#{window_id}' | head -1)"; shape_settle "$SD"
assert_eq "$(TL list-windows -t '=main' 2>/dev/null | grep -c .)" "2" "(fixture) two windows, each running a command that ends"
: > "$SHAPE_TMP/go"
i=0; while TL ls >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
shape_settle "$SD" || true
rm -f "$SHAPE_TMP/go"
ROOST_SHUTDOWN_AT="$(date +%s)" R persist --at-login roost >/dev/null 2>&1; rc=$?
assert_eq "$rc|$(sessions)|$(TL list-windows -t '=main' 2>/dev/null | grep -c .)" "0|main |2" \
  "torn down by its own exits inside the window: restored whole (both windows)"
stop_server
STUB_UNAME=Darwin PATH="$STUBS:$PATH" ROOST_PERSIST_WRITE_ONLY=1 R persist off >/dev/null 2>&1

echo "== §8.1 test 9: on with the server stopped =="
for os in Darwin Linux; do
  rm -rf "$SD"; mkdir -p "$SD"
  MKSHAPE_SESSIONS="main work" mkshape 1700000000-11 "$SD/shape" 4
  g0="$(gen_of "$SD")"; : > "$PERSIST_LOG"
  out="$(STUB_UNAME=$os PATH="$STUBS:$PATH" \
    PERSIST_ON_LOAD="env -u TMUX -u TMUX_PANE ROOST_SOCKET=roost $ROOST persist --at-login roost" R persist on 2>&1)"; rc=$?
  assert_eq "$rc" "0" "$os: on exits 0 with the server stopped ($out)"
  assert_contains "$(cat "$PERSIST_LOG")" "$([ "$os" = Darwin ] && echo "launchctl bootstrap" || echo "systemctl --user enable")" "$os: ...the load is logged"
  if [ "$os" = Darwin ]; then
    assert_eq "$(gen_of "$SD")|$(trig "$SD/shape")" "$g0|save" "Darwin: shape is still the planted save when on returns"
  fi
  i=0; while [ "$(sessions)" != "main work " ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  assert_eq "$(sessions)" "main work " "$os: the job places both sessions"
  i=0; while ! trig "$SD/shape" | grep -q restore && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  assert_contains "$(trig "$SD/shape")" "restore" "$os: ...and its own --trigger restore save follows"
  assert_eq "$(cat "$SD/shape" "$SD"/history/* 2>/dev/null | grep -c '^trigger.*persist-on')" "0" "$os: ...with no persist-on save in between"
  stop_server
  STUB_UNAME=$os PATH="$STUBS:$PATH" R persist off >/dev/null 2>&1
done

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
