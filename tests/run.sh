#!/usr/bin/env bash
# Run every tests/test-*.sh and sum results.
set -u
cd "$(dirname "$0")"
pass=0 fail=0
crashed=""
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
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ -n "$crashed" ]; then
  printf 'RUNNER: these test files died mid-run (non-zero exit):%s\n' "$crashed"
fi
[ "$fail" -eq 0 ] && [ -z "$crashed" ]
