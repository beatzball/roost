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
# bin/roost as it stood at d58ba14 — the tip of main this branch merges, and
# the last commit before the claude/codex JSON bodies moved into
# scripts/lib/roost-hooks.sh — inside this same checkout. The claude fixture
# was re-captured at that commit rather than 3a1934e because main added the
# SessionStart context hook in between; re-capturing is what proves the merge
# carried that hook into the shared lib instead of dropping it. @@ROOST_HOME@@ is a
# placeholder for this checkout's own absolute path, the only thing that can
# differ between a fixture and a live run; AGENTS.md §1 forbids committing an
# absolute home path, which is why the fixture carries a token instead of one.
#
# One deliberate edit since that capture: #39 rewrote the COMMENT lines of the
# codex fixture that described Stop, because a Stop with no reply now badges
# error and the old prose told users it could not. Only prose moved. The four
# handler objects — the bytes codex hashes — are untouched, and
# tests/test-codex-hook.sh section 9 holds them separately.
#
# Two deliberate edits for #38, both re-captured from bin/roost rather than
# typed. codex: a FIFTH handler object, Interrupt, appended after the four,
# plus prose; the four existing objects are byte-for-byte what they were,
# because appending an event is measured-safe and editing one is not. claude:
# the Notification command gained --notification-hook, plus prose. Claude does
# not hash its hooks, and `roost install` recognises the older command as
# roost's own and replaces it (tests/test-adapter-install.sh, the customised
# Notification entry).
#
# One deliberate edit for #55, claude only: a SIXTH event, StopFailure, appended
# after Stop, plus one paragraph of prose and "the other four" becoming "the
# other five". Checked against bin/roost's output by this very comparison, not
# typed blind. The five existing objects are untouched, and `roost install`
# adds the new one to a settings.json that has only those five
# (tests/test-adapter-install.sh, "wired before StopFailure existed").
#
# One deliberate edit for #91, claude only: a SEVENTH event, PermissionRequest,
# INSERTED before Notification rather than appended. Position is the one thing
# that is free here and nowhere near free in the codex fixture: Claude stores
# no hash of its hooks, so where an event sits changes nothing it can see, and
# the two dialog hooks are worth reading together. Re-captured from
# `roost hooks claude` and diffed, not typed: the diff is exactly three added
# lines and no existing byte moved. `roost install` adds the new entry to a
# settings.json that has only the other six, by the same generic merge
# (scripts/lib/roost-json.sh) the StopFailure case above relies on, and
# tests/test-claude-permission-request.sh holds the rest.
#
# Round 2 added --tool-hook to both PostToolUse entries. It lets the hook read
# that event's payload, and it reads it only when the pane already reads 🛑 —
# a SUBAGENT's tool result must not clear a dialog a different agent opened on
# the same pane. Re-captured, not typed; the JSON diff is those two argument
# strings and nothing else.
#
# Round 1 of the flock then added the missing prose and an EIGHTH event,
# PostToolUseFailure, beside PostToolUse. That one is an append, and it is the
# event Claude actually sends when a tool fails after the human answered Yes —
# PostToolUse fires only on success, so without it the 🛑 PermissionRequest
# stamped had nothing to clear it. Re-captured the same way; the JSON diff is
# three added lines beside PostToolUse and nothing moved. The prose above the
# object was rewritten in the same round, which is why this fixture's comment
# half changed at once: the lane was granted that block in bin/roost
# (comments and heredoc text only, nothing executable).
expected_claude="$(sed "s|@@ROOST_HOME@@|$HERE|g" "$HERE/tests/fixtures/hooks-claude.txt")"
assert_eq "$claude_out" "$expected_claude" \
  "'roost hooks claude' is byte-identical to the fixture (d58ba14, plus #38's re-capture)"

codex_out="$("$HERE/bin/roost" hooks codex)"
expected_codex="$(sed "s|@@ROOST_HOME@@|$HERE|g" "$HERE/tests/fixtures/hooks-codex.txt")"
assert_eq "$codex_out" "$expected_codex" \
  "'roost hooks codex' is byte-identical to the fixture (d58ba14, plus #39's comment edit and #38's re-capture)"

# --- one copy of the bytes, not two -----------------------------------------
# A test that only compared printed output cannot tell "sourced from the
# shared lib" from "duplicated inline and kept in sync by hand" — and a
# hand-kept duplicate is exactly the failure mode this task exists to close
# (see the header). So pin the SOURCE as well as the output: bin/roost must
# CALL scripts/lib/roost-hooks.sh's two functions, and must not carry a second
# copy of either JSON body's command literal.
#
# The call-site checks below strip comment-only lines first and then require
# the function name as a whole word, not a bare substring grep. bin/roost's
# own comment above its `. .../roost-hooks.sh` line names both functions in
# prose ("roost_hooks_claude / roost_hooks_codex print the JSON object..."),
# so a plain `grep -q roost_hooks_claude bin/roost` is true whether or not
# anything actually CALLS it — proven by reintroducing a hand-kept duplicate
# in a scratch copy: the old, unanchored version of this check kept passing
# with the call deleted and only the comment left behind (pasted in the PR
# body). Comment lines are identified the plain-text way (first non-blank
# character is #), which is exactly how every comment in this file is
# written; it does not need to handle a `#` inside a string literal because
# neither bin/roost nor any file this test reads puts one at the start of a
# line.
bin_code="$(grep -v '^[[:space:]]*#' "$HERE/bin/roost")"
word_called() {
  # word_called TEXT NAME -> success if NAME appears in TEXT as a whole word.
  printf '%s' "$1" | grep -Eq "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)"
}
grep -q 'lib/roost-hooks.sh' "$HERE/bin/roost" && s=yes || s=no
assert_eq "$s" "yes" "bin/roost sources scripts/lib/roost-hooks.sh"
word_called "$bin_code" roost_hooks_claude && s=yes || s=no
assert_eq "$s" "yes" "bin/roost actually CALLS roost_hooks_claude (not just mentions it in a comment)"
word_called "$bin_code" roost_hooks_codex && s=yes || s=no
assert_eq "$s" "yes" "bin/roost actually CALLS roost_hooks_codex (not just mentions it in a comment)"
bin_codex_copies="$(grep -c 'adapters/codex/roost-codex-hook.*timeout' "$HERE/bin/roost" 2>/dev/null || true)"
assert_eq "${bin_codex_copies:-0}" "0" \
  "bin/roost no longer carries its own copy of the frozen codex handler objects"
bin_claude_copies="$(grep -c 'roost-agent-state working"' "$HERE/bin/roost" 2>/dev/null || true)"
assert_eq "${bin_claude_copies:-0}" "0" \
  "bin/roost no longer carries its own copy of the claude hook JSON body"

# --- the frozen codex handler objects, individually -------------------------
# Checked on each handler separately, and for both facts named in the task
# (the path and the timeout), so a regression in either survives being caught
# even if it only hits one of them. Interrupt joined the four in #38 and is
# held the same way.
for ev in UserPromptSubmit PostToolUse PermissionRequest Stop; do
  line="$(printf '%s\n' "$codex_out" | grep "\"$ev\"" -A 1 | tail -n 1)"
  assert_contains "$line" "adapters/codex/roost-codex-hook" \
    "the $ev codex handler still names roost-codex-hook"
  assert_contains "$line" '"timeout": 10' \
    "the $ev codex handler still has timeout 10"
done

# Interrupt is the ONE handler whose timeout is not 10, and it is not a style
# choice either. Codex caps an Interrupt hook at 3 seconds and clamps anything
# larger, printing `warning: clamping Interrupt hook timeout to 3s in
# <path>/hooks.json` on every start — the path being a home directory, which
# AGENTS.md §1 keeps off a user's screen as much as out of a commit. The
# warning is already in the record: docs/known-gaps.md quotes it verbatim from
# an unedited `codex exec` stderr. Asking for 10 therefore bought nothing (the
# hook ran with 3 either way) and cost a warning per start, so roost asks for
# the 3 codex would have given it. Writing the real cap here also makes the
# value a measurement rather than a preference: if codex ever raises the cap,
# this assertion is where the next person finds out what the old one was.
line="$(printf '%s\n' "$codex_out" | grep '"Interrupt"' -A 1 | tail -n 1)"
assert_contains "$line" "adapters/codex/roost-codex-hook" \
  "the Interrupt codex handler still names roost-codex-hook"
assert_contains "$line" '"timeout": 3' \
  "the Interrupt codex handler asks for codex's own 3s cap, so nothing is clamped"
assert_eq "$(printf '%s\n' "$codex_out" | grep -c '"timeout": 10')" "4" \
  "only the four uncapped handlers ask for 10"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
