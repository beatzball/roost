#!/usr/bin/env bash
# tests/test-hook-source.sh — pins `roost hooks` to printing exactly what it
# always has, once the claude and codex JSON bodies move into
# scripts/lib/roost-hooks.sh.
#
# Why this file exists at all: codex stores a hash of each normalised handler
# object in $CODEX_HOME/config.toml and silently SKIPS any handler whose hash
# no longer matches — nothing printed on stdout, on stderr, or in the TUI.
# Measured on codex-cli 0.150.1: appending one argument to a command string
# took 8 of 8 hooks down, and changing a single timeout from 10 to 11 took 7
# of 8 down. If bin/roost's copy of these bytes and the installer's copy (the
# next caller of scripts/lib/roost-hooks.sh) ever differ by one byte, one of
# them silently un-badges every machine that had already granted trust. This
# suite is the thing that would catch that.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# --- roost hooks (no argument) must still mean claude -----------------------
# Documented in bin/roost's own header, in site/content/docs/state-badges.md
# and in scripts/roost-doctor's advice ("run: roost hooks"); a refactor that
# quietly changed the default would break every one of those at once.
bare_out="$("$HERE/bin/roost" hooks)"
claude_out="$("$HERE/bin/roost" hooks claude)"
assert_eq "$claude_out" "$bare_out" \
  "'roost hooks' and 'roost hooks claude' produce identical output"

# --- byte-identical to the pre-refactor behaviour ---------------------------
# tests/fixtures/hooks-claude.txt and hooks-codex.txt were captured by running
# bin/roost as it stood at 3a1934e — the commit immediately before this file's
# own, and before the claude/codex JSON bodies moved into
# scripts/lib/roost-hooks.sh — inside this same checkout. @@ROOST_HOME@@ is a
# placeholder for this checkout's own absolute path, the only thing that can
# differ between a fixture and a live run; AGENTS.md §1 forbids committing an
# absolute home path, which is why the fixture carries a token instead of one.
expected_claude="$(sed "s|@@ROOST_HOME@@|$HERE|g" "$HERE/tests/fixtures/hooks-claude.txt")"
assert_eq "$claude_out" "$expected_claude" \
  "'roost hooks claude' is byte-identical to what 3a1934e printed"

codex_out="$("$HERE/bin/roost" hooks codex)"
expected_codex="$(sed "s|@@ROOST_HOME@@|$HERE|g" "$HERE/tests/fixtures/hooks-codex.txt")"
assert_eq "$codex_out" "$expected_codex" \
  "'roost hooks codex' is byte-identical to what 3a1934e printed"

# --- one copy of the bytes, not two -----------------------------------------
# A test that only compared printed output cannot tell "sourced from the
# shared lib" from "duplicated inline and kept in sync by hand" — and a
# hand-kept duplicate is exactly the failure mode this task exists to close
# (see the header). So pin the SOURCE as well as the output: bin/roost must
# source scripts/lib/roost-hooks.sh and call its two functions, and must not
# carry a second copy of the frozen codex handler command literal.
# grep -q, not assert_contains on the whole file: assert_contains prints its
# full first argument on a FAIL, and that argument here would be bin/roost's
# entire source — noise that would bury the one line worth reading.
grep -q 'lib/roost-hooks.sh' "$HERE/bin/roost" && s=yes || s=no
assert_eq "$s" "yes" "bin/roost sources scripts/lib/roost-hooks.sh"
grep -q 'roost_hooks_claude' "$HERE/bin/roost" && s=yes || s=no
assert_eq "$s" "yes" "bin/roost calls roost_hooks_claude"
grep -q 'roost_hooks_codex' "$HERE/bin/roost" && s=yes || s=no
assert_eq "$s" "yes" "bin/roost calls roost_hooks_codex"
bin_codex_copies="$(grep -c 'adapters/codex/roost-codex-hook.*timeout' "$HERE/bin/roost" 2>/dev/null || true)"
assert_eq "${bin_codex_copies:-0}" "0" \
  "bin/roost no longer carries its own copy of the frozen codex handler objects"

# --- the four frozen codex handler objects, individually --------------------
# Checked on each handler separately, and for both facts named in the task
# (the path and the timeout), so a regression in either survives being caught
# even if it only hits one of the four.
for ev in UserPromptSubmit PostToolUse PermissionRequest Stop; do
  line="$(printf '%s\n' "$codex_out" | grep "\"$ev\"" -A 1 | tail -n 1)"
  assert_contains "$line" "adapters/codex/roost-codex-hook" \
    "the $ev codex handler still names roost-codex-hook"
  assert_contains "$line" '"timeout": 10' \
    "the $ev codex handler still has timeout 10"
done

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
