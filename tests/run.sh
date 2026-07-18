#!/usr/bin/env bash
# Run every tests/test-*.sh and sum results.
set -u
cd "$(dirname "$0")"
pass=0 fail=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  printf '\n== %s ==\n' "$t"
  # each test file sources lib.sh and prints PASS/FAIL lines; capture counts via env
  out="$(AMUX_TESTS_PASS=0 AMUX_TESTS_FAIL=0 bash "$t" 2>&1; )"
  printf '%s\n' "$out"
  pass=$((pass + $(printf '%s' "$out" | grep -c '^  PASS')))
  fail=$((fail + $(printf '%s' "$out" | grep -c '^  FAIL')))
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
