#!/usr/bin/env bash
# `roost wait-done TARGET TIMEOUT` with a TIMEOUT that is not a whole number
# (#66).
#
# Measured before this fix, on a throwaway -S server with a pane badged
# working, each run cut off after 2.5s:
#
#   abc                   never returned; `[: abc: integer expression expected`
#                         on every quarter-second poll, with bin/roost's path
#                         and line number in front of it
#   1.5                   the same
#   99999999999999999999  the same: too big for bash's integers
#   -5                    never returned, silently: `-5 -gt 0` is false, so it
#                         waited as if no timeout had been given
#   '' (an empty string)  never returned, silently: `${3:-0}` read it as 0
#   08                    exit 1 after one poll, on the bash error `value too
#                         great for base`; a leading zero made it octal
#
# EVERY wait-done run in this file goes through bounded(), which kills it after
# a few seconds. The bug under test is a hang, and a regression must turn a
# test red rather than hang the suite.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_SOCKET="$sock"   # bin/roost talks to the isolated test server (path → -S)
unset TMUX TMUX_PANE
work="$ROOST_TEST_SOCKDIR/w"; mkdir -p "$work"

USAGE="usage: roost wait-done [SESSION:]WINDOW [TIMEOUT_SEC]"

# bounded LIMIT_TENTHS ARGS... -> run `roost ARGS...` in the background, and
# kill it if it is still running after LIMIT_TENTHS tenths of a second. Sets
# $rc (the exit code, or "hung"), $err (stderr) and $tenths (how long it ran).
# There is no `timeout` binary on stock macOS, so this is the time bound.
bounded() {
  local limit="$1" pid; shift
  "$ROOST" "$@" >/dev/null 2>"$work/err" &
  pid=$!
  tenths=0
  while kill -0 "$pid" 2>/dev/null && [ "$tenths" -lt "$limit" ]; do
    sleep 0.1; tenths=$((tenths + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=hung
  else
    wait "$pid"; rc=$?
  fi
  err="$(cat "$work/err")"
}

p="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
w="$(T display-message -p -t "$p" '#{window_id}')"
T set-option -p -t "$p" @agent_state working

# --- bad timeouts are refused at once -----------------------------------------
# Pane and window targets both (the refusal is argument parsing, before either
# kind of target is looked at), and the `wait` alias once.
for tgt in "$p" "$w"; do
  for bad in abc -5 1.5 "" 99999999999999999999 " 5" +5; do
    bounded 30 wait-done "$tgt" "$bad"
    assert_eq "$rc" "1" "wait-done $tgt '$bad' exits 1, the usage-error code"
    [ "$tenths" -le 10 ]; assert_true $? "...at once (took ${tenths} tenths)"
    assert_contains "$err" "'$bad'" "...naming the bad value"
    assert_contains "$err" "$USAGE" "...with the usage line"
    case "$err" in
      *"integer expression"*|*"$HERE"*|*"bin/roost:"*|*"line "[0-9]*) leak=1 ;;
      *) leak=0 ;;
    esac
    assert_eq "$leak" "0" "...and no bash error, path or line number"
  done
done
bounded 30 wait-done
assert_eq "$rc" "1" "a missing target is still need_arg's usage error"
assert_eq "$err" "$USAGE" "...printing only the usage line, as before"
bounded 30 wait "$p" abc
assert_eq "$rc" "1" "the wait alias refuses a bad timeout too"
assert_contains "$err" "$USAGE" "...with the same usage line"

# Refused BEFORE any polling: a target that does not exist would otherwise
# exit 2 with "gone". A usage error here proves the check runs first.
bounded 30 wait-done %999999 abc
assert_eq "$rc" "1" "a bad timeout on a missing target is a usage error, not 'gone'"
case "$err" in *gone*) s=polled ;; *) s=refused ;; esac
assert_eq "$s" "refused" "...refused before the target is looked up"

# --- good timeouts behave as before -------------------------------------------
# Omitted, and 0: wait with no limit. Still running when the bound cuts it off.
bounded 15 wait-done "$p"
assert_eq "$rc" "hung" "no timeout on a working pane still waits with no limit"
assert_eq "$err" "" "...silently"
bounded 15 wait-done "$p" 0
assert_eq "$rc" "hung" "timeout 0 on a working pane still waits with no limit"
assert_eq "$err" "" "...silently"
bounded 15 wait-done "$w" 0
assert_eq "$rc" "hung" "timeout 0 on a working WINDOW still waits with no limit"

# A whole number times out after that many seconds, with exit 1.
bounded 50 wait-done "$p" 1
assert_eq "$rc" "1" "timeout 1 on a working pane exits 1"
assert_contains "$err" "timed out" "...saying it timed out"
[ "$tenths" -ge 9 ] && [ "$tenths" -le 25 ]; assert_true $? "...after about a second (${tenths} tenths)"
bounded 50 wait-done "$w" 1
assert_eq "$rc" "1" "timeout 1 on a working WINDOW exits 1"
assert_contains "$err" "timed out" "...saying it timed out"

# A leading zero is decimal, not octal: 08 used to be a bash error, and 010
# used to mean 8 seconds.
bounded 50 wait-done "$p" 01
assert_eq "$rc" "1" "timeout 01 is one second"
assert_contains "$err" "timed out" "...and times out, not a bash error"
[ "$tenths" -le 25 ]; assert_true $? "...after about a second (${tenths} tenths)"
bounded 15 wait-done "$p" 00
assert_eq "$rc" "hung" "timeout 00 is 0: no limit"
# 01 and 00 read the same in octal, so these two are what tell a stripped zero
# from an unstripped one. 08 is eight seconds, still waiting when the bound
# cuts it off, where octal made it a bash error after one poll.
bounded 15 wait-done "$p" 08
assert_eq "$rc" "hung" "timeout 08 on a working pane is eight seconds, not a bash error"
assert_eq "$err" "" "...silently"
# The 15-digit limit counts digits after the zeros: this is one second.
bounded 50 wait-done "$p" 0000000000000001
assert_eq "$rc" "1" "timeout 0000000000000001 is one second, not refused for its length"
assert_contains "$err" "timed out" "...and times out"

# A done target returns 0 whatever valid timeout it is given.
T set-option -p -t "$p" @agent_state done
for good in "" 0 5 08; do
  if [ -z "$good" ]; then bounded 30 wait-done "$p"; else bounded 30 wait-done "$p" "$good"; fi
  assert_eq "$rc" "0" "a done pane exits 0 with timeout '${good:-omitted}'"
done
