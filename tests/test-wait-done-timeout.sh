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

# now_ms -> milliseconds on a real clock.
#
# The first version of this file counted `sleep 0.1` passes of its own poll
# loop and called that tenths of a second. It is not a clock. On a loaded
# macOS CI runner each pass took longer than 0.1s, so a wait-done that really
# ran for a second was counted as 7 or 8 tenths, and "after about a second"
# failed on correct code (PR #68). Reproduced locally by a `sleep` shim that
# turns only `sleep 0.1` into 0.15s: the counter read 7.
#
# perl, because bash 3.2 (stock macOS) has no sub-second clock, `date +%N` is
# GNU-only, and perl with Time::HiRes ships on both CI images.
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# bounded LIMIT_MS ARGS... -> run `roost ARGS...` in the background, and kill it
# if it is still running after LIMIT_MS milliseconds. Sets $rc (the exit code,
# or "hung"), $err (stderr) and $ms (how long it ran, on the real clock).
# There is no `timeout` binary on stock macOS, so this is the time bound.
#
# A run that is killed has its stderr read BEFORE the kill. Killing wait-done
# mid-poll can leave a child it forked -- the `$(snapshot)` subshell -- writing
# into a pipe whose reader is gone, and bash reports that on the stderr they
# share: `printf: write error: Broken pipe` landed in "...silently" once on CI.
# That line is kill noise, made by this harness, and not wait-done's output.
# Anything wait-done itself printed while it ran is already in the file by
# then, so nothing real is hidden. The process is also stopped first and its
# children killed before it, so fewer writers are left alive at all, and each
# run gets its own file so a straggler cannot write into the next run's.
n_run=0
bounded() {
  local limit="$1" pid start f; shift
  n_run=$((n_run + 1)); f="$work/err.$n_run"
  start="$(now_ms)"
  "$ROOST" "$@" >/dev/null 2>"$f" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ $(( $(now_ms) - start )) -lt "$limit" ]; do
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    err="$(cat "$f")"
    kill -STOP "$pid" 2>/dev/null
    pkill -9 -P "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=hung
    ms=$(( $(now_ms) - start ))
  else
    wait "$pid"; rc=$?
    ms=$(( $(now_ms) - start ))
    err="$(cat "$f")"
  fi
}

# The clock itself, before anything leans on it: a known 300ms sleep reads as
# at least 300ms. A now_ms that printed nothing or a constant would otherwise
# pass every "at once" check below and fail every lower bound for the wrong
# reason.
c0="$(now_ms)"; sleep 0.3; c1="$(now_ms)"
[ $((c1 - c0)) -ge 300 ] && [ $((c1 - c0)) -lt 3000 ]; assert_true $? "control: now_ms measures a 300ms sleep (read $((c1 - c0))ms)"

p="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
w="$(T display-message -p -t "$p" '#{window_id}')"
T set-option -p -t "$p" @agent_state working

# --- bad timeouts are refused at once -----------------------------------------
# Pane and window targets both (the refusal is argument parsing, before either
# kind of target is looked at), and the `wait` alias once.
#
# "At once" is 2s. A refusal touches no tmux at all and takes a few tens of
# milliseconds; the bug it replaces never returned at all, so any finite bound
# tells the two apart, and 2s leaves a loaded runner room to start bash.
for tgt in "$p" "$w"; do
  for bad in abc -5 1.5 "" 99999999999999999999 " 5" +5; do
    bounded 3000 wait-done "$tgt" "$bad"
    assert_eq "$rc" "1" "wait-done $tgt '$bad' exits 1, the usage-error code"
    [ "$ms" -le 2000 ]; assert_true $? "...at once (took ${ms}ms)"
    assert_contains "$err" "'$bad'" "...naming the bad value"
    assert_contains "$err" "$USAGE" "...with the usage line"
    case "$err" in
      *"integer expression"*|*"$HERE"*|*"bin/roost:"*|*"line "[0-9]*) leak=1 ;;
      *) leak=0 ;;
    esac
    assert_eq "$leak" "0" "...and no bash error, path or line number"
  done
done
bounded 3000 wait-done
assert_eq "$rc" "1" "a missing target is still need_arg's usage error"
assert_eq "$err" "$USAGE" "...printing only the usage line, as before"
bounded 3000 wait "$p" abc
assert_eq "$rc" "1" "the wait alias refuses a bad timeout too"
assert_contains "$err" "$USAGE" "...with the same usage line"

# Refused BEFORE any polling: a target that does not exist would otherwise
# exit 2 with "gone". A usage error here proves the check runs first.
bounded 3000 wait-done %999999 abc
assert_eq "$rc" "1" "a bad timeout on a missing target is a usage error, not 'gone'"
case "$err" in *gone*) s=polled ;; *) s=refused ;; esac
assert_eq "$s" "refused" "...refused before the target is looked up"

# --- good timeouts behave as before -------------------------------------------
# Omitted, and 0: wait with no limit. Still running when the bound cuts it off.
bounded 1500 wait-done "$p"
assert_eq "$rc" "hung" "no timeout on a working pane still waits with no limit"
assert_eq "$err" "" "...silently"
bounded 1500 wait-done "$p" 0
assert_eq "$rc" "hung" "timeout 0 on a working pane still waits with no limit"
assert_eq "$err" "" "...silently"
bounded 1500 wait-done "$w" 0
assert_eq "$rc" "hung" "timeout 0 on a working WINDOW still waits with no limit"

# A whole number times out after that many seconds, with exit 1.
#
# The LOWER bound is the one that carries weight. wait-done sleeps 0.25s before
# every tick it counts, so timeout 1 cannot end before 1000ms of real time,
# however slow the machine; a loop that stopped a tick early ends near 750ms
# plus its tmux calls. A slow runner only ever makes the number larger, so the
# upper bound is loose on purpose: it is there to catch "timed out" printed
# after some other wait entirely, not to time a busy machine.
one_second() { # LABEL
  [ "$ms" -ge 1000 ] && [ "$ms" -le 4500 ]; assert_true $? "$1 (took ${ms}ms, want 1000 to 4500)"
}
bounded 6000 wait-done "$p" 1
assert_eq "$rc" "1" "timeout 1 on a working pane exits 1"
assert_contains "$err" "timed out" "...saying it timed out"
one_second "...after a second, not before"
bounded 6000 wait-done "$w" 1
assert_eq "$rc" "1" "timeout 1 on a working WINDOW exits 1"
assert_contains "$err" "timed out" "...saying it timed out"
one_second "...after a second, not before"

# A leading zero is decimal, not octal: 08 used to be a bash error, and 010
# used to mean 8 seconds.
bounded 6000 wait-done "$p" 01
assert_eq "$rc" "1" "timeout 01 is one second"
assert_contains "$err" "timed out" "...and times out, not a bash error"
one_second "...after a second, not before"
bounded 1500 wait-done "$p" 00
assert_eq "$rc" "hung" "timeout 00 is 0: no limit"
# 01 and 00 read the same in octal, so these two are what tell a stripped zero
# from an unstripped one. 08 is eight seconds, still waiting when the bound
# cuts it off, where octal made it a bash error after one poll.
bounded 1500 wait-done "$p" 08
assert_eq "$rc" "hung" "timeout 08 on a working pane is eight seconds, not a bash error"
assert_eq "$err" "" "...silently"
# The 15-digit limit counts digits after the zeros: this is one second.
bounded 6000 wait-done "$p" 0000000000000001
assert_eq "$rc" "1" "timeout 0000000000000001 is one second, not refused for its length"
assert_contains "$err" "timed out" "...and times out"
one_second "...after a second, not before"

# A done target returns 0 whatever valid timeout it is given.
T set-option -p -t "$p" @agent_state done
for good in "" 0 5 08; do
  if [ -z "$good" ]; then bounded 3000 wait-done "$p"; else bounded 3000 wait-done "$p" "$good"; fi
  assert_eq "$rc" "0" "a done pane exits 0 with timeout '${good:-omitted}'"
done
