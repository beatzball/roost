#!/usr/bin/env bash
# Forced trigger for the tests/test-switcher.sh "falls back to the command"
# race, and the standing proof that the shipped shape is immune to it.
#
# The natural failure rate is far too low to prove anything: 3 failures in 400
# runs of the real test, and it swung 3/160 in one batch then 0/240 in the next.
# So this drives the pane instead of waiting on it. A pane is made to alternate
# #{pane_current_command} ~50/50 between "sleep" and "perl", and BOTH shapes of
# the assertion are then run against that same churn:
#
#   CONTROL  the pre-fix shape — read the row from amux-switch, then read
#            #{pane_current_command} a second time and compare the two. Two
#            samples of a live value, taken at different instants. Expected to
#            MISMATCH. If it ever stops mismatching the trigger has gone blunt
#            and this script no longer proves anything.
#   SHIPPED  the shape tests/test-switcher.sh actually uses — a pane pinned to
#            a long-lived command, compared against a literal. One live read,
#            against a pane measured at 0 strays in 6000 reads. Expected to be
#            CLEAN.
#
# Exit status reflects SHIPPED only: non-zero means the fix has regressed.
# A blunt CONTROL is reported loudly but is not a failure of the fix.
#
# Not part of tests/run.sh: it needs perl, takes seconds, and is a diagnostic
# rather than a behaviour test. tests/run.sh globs tests/test-*.sh, so living
# here as tests/live/ keeps it out of that sweep.
#
#   N=30 tests/live/switcher-read-race.sh
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
N="${N:-30}"
. "$HERE/tests/lib.sh"
amux_test_server; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

p0="$(T display -p '#{pane_id}')"
T split-window -d -t "$p0" 'sh -c "while :; do sleep 5; done"' >/dev/null
T set-option -p -t "$p0" @agent_state blocked
T rename-window apiwin

# Two externals of roughly equal duration, so each read of this pane is close to
# a coin flip. Measured duty cycle: 40 perl / 37 sleep / 3 shell over 80 reads.
T send-keys -t "$p0" \
  "while :; do /bin/sleep 0.03; /usr/bin/perl -e 'select(undef,undef,undef,0.03)'; done" Enter

# The SHIPPED pane: a long-lived command, so its reported name is a constant.
pf="$(T split-window -d -P -F '#{pane_id}' -t "$p0" 'exec sleep 600')"
# Bounded gate on the exec landing. Deterministic, unlike racing it — and the
# whole point of this file is to stop racing live values.
gated=no
for _ in $(seq 1 50); do
  if [ "$(T display-message -p -t "$pf" '#{pane_current_command}')" = sleep ]; then gated=yes; break; fi
  sleep 0.05
done
if [ "$gated" != yes ]; then
  echo "switcher-read-race: pinned pane never reported 'sleep'; cannot run" >&2
  exit 2
fi

switch_rows() { AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch"; }
row_for() { printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$3==p'; }

control=0
shipped=0
for i in $(seq 1 "$N"); do
  # CONTROL: switcher row vs a SECOND read of the same live value.
  rows="$(switch_rows)"
  cmd="$(T display-message -p -t "$p0" '#{pane_current_command}')"
  row="$(row_for "$rows" "$p0")"
  case "$row" in
    *"$cmd"*) ;;
    *) control=$((control+1))
       printf 'CONTROL  mismatch iter=%s switcher_saw=[%s] second_read=[%s]\n' "$i" "$row" "$cmd" ;;
  esac

  # SHIPPED: switcher row vs a literal. No second read of anything live.
  rows="$(switch_rows)"
  row="$(row_for "$rows" "$pf")"
  case "$row" in
    *"·sleep"*) ;;
    *) shipped=$((shipped+1))
       printf 'SHIPPED  mismatch iter=%s row=[%s] expected to contain [.sleep]\n' "$i" "$row" ;;
  esac
done

printf 'CONTROL (pre-fix, two live reads): %s mismatches in %s\n' "$control" "$N"
printf 'SHIPPED (pinned pane, one read):   %s mismatches in %s\n' "$shipped" "$N"

if [ "$control" -eq 0 ]; then
  echo "switcher-read-race: WARNING the control never fired, so this run proves nothing" >&2
  echo "                    raise N, or the churn no longer moves pane_current_command" >&2
fi
[ "$shipped" -eq 0 ]
