#!/usr/bin/env bash
# tests/test-adapter-state.sh — roost_adapter_state's other-checkout value and
# roost_checkout_is_worktree, both in scripts/lib/roost-adapters.sh.
#
# Every link is planted under a scratch home. The developer running this suite
# has live agent configuration in ~/.config/opencode, ~/.pi and ~/.copilot, and
# a state test that reached one of those would be reading (or, in a later
# test, replacing) a real adapter link.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- the sandbox canary -----------------------------------------------------
# Every variable the adapter path table reads, exported at one directory that
# NOTHING below may write to; the cases that need a home set the scratch
# values explicitly for one call. A call that forgets one inherits the canary,
# and the check at the bottom fails. See tests/test-install.sh for the leak
# this guards against (AGENTS.md §8).
CANARY="$TMP/canary"
export ZDOTDIR="$CANARY/zdot"
export XDG_CONFIG_HOME="$CANARY/xdg-config"
export XDG_DATA_HOME="$CANARY/xdg-data"
export COPILOT_HOME="$CANARY/copilot"
export PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export CODEX_HOME="$CANARY/codex"
export CLAUDE_SETTINGS="$CANARY/claude/settings.json"
canary_leaks() { find "$CANARY" -mindepth 1 2>/dev/null | sort; }

. "$HERE/scripts/lib/roost-adapters.sh"

# The scratch homes, applied to one call at a time.
SB="$TMP/sandbox"
sandboxed() { # sandboxed CMD... -> runs CMD with every home redirected
  XDG_CONFIG_HOME="$SB/xdg-config" XDG_DATA_HOME="$SB/xdg-data" \
  COPILOT_HOME="$SB/copilot" PI_CODING_AGENT_DIR="$SB/pi/agent" \
  CODEX_HOME="$SB/codex" ZDOTDIR="$SB/zdot" HOME="$SB/home" \
  CLAUDE_SETTINGS="$SB/claude/settings.json" "$@"
}

# plant H TARGET -> a fresh symlink at H's adapter path
plant() {
  local p; p="$(sandboxed roost_adapter_path "$1")"
  rm -rf "$p"; mkdir -p "$(dirname "$p")"; ln -s "$2" "$p"
}

# A second copy of roost: only its adapters matter to the state check.
co2="$TMP/second-checkout"
mkdir -p "$co2"
cp -R "$HERE/adapters" "$co2/"
printf 'x\n' > "$TMP/stranger.js"
mkdir -p "$co2/elsewhere"; printf 'x\n' > "$co2/elsewhere/roost.js"

for h in opencode opencode2 pi copilot; do
  tail_="$(roost_adapter_tail "$h")"
  [ -n "$tail_" ]; assert_true $? "$h: roost_adapter_tail names a tail"

  plant "$h" "$co2$tail_"
  assert_eq "$(sandboxed roost_adapter_state "$h")" "other-checkout" \
    "$h: a link into a second checkout's adapter is other-checkout"

  if [ "$h" = opencode2 ]; then
    plant "$h" "$co2$tail_/"
    assert_eq "$(sandboxed roost_adapter_state "$h")" "other-checkout" \
      "$h: a trailing slash on the link text does not hide the checkout"
  fi

  plant "$h" "$TMP/stranger.js"
  assert_eq "$(sandboxed roost_adapter_state "$h")" "foreign" \
    "$h: a link to somebody's own file is foreign (control)"

  plant "$h" "$co2/elsewhere/roost.js"
  assert_eq "$(sandboxed roost_adapter_state "$h")" "foreign" \
    "$h: a live link with the wrong tail is foreign"

  if [ "$h" = opencode ]; then
    plant "$h" "$co2/adapters/opencode/v2"
    assert_eq "$(sandboxed roost_adapter_state "$h")" "foreign" \
      "$h: another harness's adapter in the right checkout shape is foreign"
  fi

  plant "$h" "$TMP/gone$tail_"
  assert_eq "$(sandboxed roost_adapter_state "$h")" "dangling" \
    "$h: a link to nothing is still dangling"

  plant "$h" "$(roost_adapter_target "$h")"
  assert_eq "$(sandboxed roost_adapter_state "$h")" "ok" \
    "$h: a link to this checkout's own target is still ok"
done

# --- roost_checkout_is_worktree ----------------------------------------------
repo="$TMP/repo"
mkdir -p "$repo"
(
  cd "$repo" && git init -q && git config user.email t@example.invalid \
    && git config user.name t && git commit -q --allow-empty -m one \
    && git worktree add -q "$TMP/repo-wt" -b wt
) >/dev/null 2>&1

roost_checkout_is_worktree "$repo"; assert_eq "$?" "1" \
  "a primary checkout is not a worktree"
roost_checkout_is_worktree "$TMP/repo-wt"; assert_eq "$?" "0" \
  "a git worktree is one"
mkdir -p "$TMP/plain"
roost_checkout_is_worktree "$TMP/plain"; assert_eq "$?" "1" \
  "a plain directory is not a worktree"

# A PATH with no git: the answer must be "no", not an error. Built the way
# tests/test-adapter-install.sh's make_harness_shim builds its machine, minus
# any harness stubs.
CORE_BINS="bash sh cat cp mv rm mkdir mktemp dirname readlink ln find grep sed date env printf true false chmod stat cmp"
nogit="$(mktemp -d)"
for b in $CORE_BINS; do
  real="$(command -v "$b" 2>/dev/null)" && ln -s "$real" "$nogit/$b" 2>/dev/null
done
( PATH="$nogit"; roost_checkout_is_worktree "$TMP/repo-wt" ); assert_eq "$?" "1" \
  "with no git on PATH a worktree reads as not one"
rm -rf "$nogit"

# --- the canary must be empty ------------------------------------------------
assert_eq "$(canary_leaks)" "" "nothing wrote outside the scratch homes"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
