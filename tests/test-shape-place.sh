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

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
