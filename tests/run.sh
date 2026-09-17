#!/usr/bin/env bash
# Run every tests/test-*.sh and sum results.
set -u
cd "$(dirname "$0")"
pass=0 fail=0
crashed=""
# Pane records (#42): nothing in the suite may land in the developer's real
# record directory. tests/lib.sh switches records off for every file, and this
# checks that it held. A record made during the run whose socket no longer
# exists came from a test server — the suite tears every server down — while a
# live agent's record, made by the developer's own roost during a long run,
# names a socket that is still there, and is not a failure. The marker is
# created before the first file runs, so only records made during the run count.
case "${XDG_STATE_HOME:-}" in /*) rec_real="$XDG_STATE_HOME/roost/panes" ;; *) rec_real="${HOME:-/nonexistent}/.local/state/roost/panes" ;; esac
rec_marker="$(mktemp /tmp/amx.XXXX)"
for t in test-*.sh; do
  [ -e "$t" ] || continue
  printf '\n== %s ==\n' "$t"
  # each test file sources lib.sh and prints PASS/FAIL lines; capture counts via env
  out="$(ROOST_TESTS_PASS=0 ROOST_TESTS_FAIL=0 bash "$t" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  pass=$((pass + $(printf '%s' "$out" | grep -c '^  PASS')))
  fail=$((fail + $(printf '%s' "$out" | grep -c '^  FAIL')))
  # A file's PASS/FAIL lines are silent about a hard death mid-run (syntax
  # error, an unexpected `set -e` abort, a killed server): it just
  # contributes fewer PASS lines and NO FAIL lines, so the counts above
  # would silently under-report and this script could still exit 0. Test
  # files are expected to exit 0 on success, so a non-zero exit here means
  # something died that no PASS/FAIL line accounts for — name it and fail
  # the suite even if every line it did print was a PASS.
  if [ "$rc" -ne 0 ]; then
    printf 'RUNNER: %s exited %d before finishing — treating the run as failed\n' "$t" "$rc"
    crashed="$crashed $t"
  fi
done
rec_leaked=""
if [ -d "$rec_real" ]; then
  while IFS= read -r d; do
    sock=""
    [ -f "$d/socket" ] && IFS= read -r sock < "$d/socket"
    [ -S "$sock" ] || rec_leaked="$rec_leaked $d"
  done < <(find "$rec_real" -mindepth 2 -maxdepth 2 -type d -newer "$rec_marker" 2>/dev/null)
fi
rm -f "$rec_marker"
if [ -n "$rec_leaked" ]; then
  printf 'RUNNER: the suite wrote pane records into the real %s:%s\n' "$rec_real" "$rec_leaked"
  crashed="$crashed (real-record-dir)"
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ -n "$crashed" ]; then
  printf 'RUNNER: these test files died mid-run (non-zero exit):%s\n' "$crashed"
fi
[ "$fail" -eq 0 ] && [ -z "$crashed" ]
