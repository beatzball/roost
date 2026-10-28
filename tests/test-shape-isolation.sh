#!/usr/bin/env bash
# No test saves a shape by accident (#191). Once saving is always on (spec
# §3.4a) and every spawn and split saves (Part 4), any test that runs a roost
# verb would write a shape into the developer's real
# ~/.local/state/roost/shapes unless something switches saving off for it.
# tests/lib.sh does, for the whole suite, the way it already does for pane
# records: ROOST_SHAPE_DIR is ASSIGNED empty, not defaulted, so a value
# exported in the developer's shell cannot leak in.
#
# This file pins that, before any automatic save exists, and is re-run by the
# task that makes spawns save (the plan's Task 4.7): today the two existing
# files below write no shape whatever lib.sh says, so their half is a
# regression net for later, and the `[]` line is what is red without the
# export.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
TMP="$(mktemp -d)"
TMP="$(cd -P "$TMP" && pwd)"
trap 'rm -rf "$TMP"' EXIT

# This file's own sandbox, as every new test file has (plan, Global
# constraints): the homes a roost verb or the files below could write into
# point at the canary, which must stay empty; ZDOTDIR is cleared.
CANARY="$TMP/canary"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export XDG_DATA_HOME="$CANARY/xdg-data"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"
export CODEX_HOME="$CANARY/codex"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CLAUDE_CONFIG_DIR="$CANARY/claude-config"
unset ZDOTDIR
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
mkdir -p "$HOME" "$XDG_STATE_HOME"
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

echo "== tests/lib.sh switches saving off =="
# env -i: nothing from this shell — not even this file's own sourcing of
# lib.sh — can make the answer right by accident.
got="$(env -i HOME="$HOME" PATH="$PATH" bash -c '. tests/lib.sh; printf "[%s]" "${ROOST_SHAPE_DIR-unset}"')"
assert_eq "$got" "[]" "lib.sh sets ROOST_SHAPE_DIR to empty (set, not unset)"
got="$(env -i HOME="$HOME" PATH="$PATH" ROOST_SHAPE_DIR=/somewhere/real bash -c '. tests/lib.sh; printf "[%s]" "${ROOST_SHAPE_DIR-unset}"')"
assert_eq "$got" "[]" "...even when the developer's shell exports a real one"

echo "== existing files write no shape =="
# Each run with ROOST_SHAPE_DIR exported at a directory of its own: if lib.sh
# stopped clearing it, a saving verb inside would write there.
for f in test-panes.sh test-view.sh; do
  sd="$TMP/shapes-${f%.sh}"
  mkdir -p "$sd"
  ROOST_SHAPE_DIR="$sd" bash "tests/$f" > "$TMP/${f%.sh}.out" 2>&1
  rc=$?
  assert_eq "$rc" "0" "tests/$f still passes (exit $rc) with ROOST_SHAPE_DIR exported"
  assert_eq "$(find "$sd" -mindepth 1 2>/dev/null | sort)" "" "tests/$f wrote nothing into the exported shape directory"
done

# The detector is checked before it is trusted (tests/test-install.sh).
mkdir -p "$CANARY"; : > "$CANARY/detector-check"
assert_contains "$(canary_leaks)" "detector-check" "the sandbox canary reports a file when there is one"
rm -f "$CANARY/detector-check"
assert_eq "$(canary_leaks)" "" "nothing was written to a real-home stand-in (the canary)"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
