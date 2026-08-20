#!/usr/bin/env bash
# Self-test for the test harness itself.
set -u
. "$(dirname "$0")/lib.sh"

roost_test_server
sock="$ROOST_TEST_SOCK"
trap roost_test_teardown EXIT

# socket path must be short enough for the ~104-char unix limit
[ "${#sock}" -lt 100 ] && assert_eq ok ok "socket path is short" \
  || assert_eq "${#sock}" "<100" "socket path is short"

# server is actually up
T new-window -n probe
assert_contains "$(T list-windows -F '#{window_name}')" probe "server accepts commands"

# path shim records invocation
marker="$(mktemp)"
with_path_shim faketool "$marker" -- sh -c 'faketool arg1'
assert_contains "$(cat "$marker")" faketool "path shim intercepts the call"

# assert_eq fails loudly on mismatch (run in subshell so it can't kill us)
out="$(assert_eq a b "intentional-fail" 2>&1 || true)"
assert_contains "$out" FAIL "assert_eq reports FAIL on mismatch"
