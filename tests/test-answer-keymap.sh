#!/usr/bin/env bash
# The key map `roost answer` sends from (#142): one row per measurement, and a
# refusal for everything else. No tmux, no harness: roost_answer_keys and the
# record parsers are pure functions (scripts/lib/roost-answer.sh), so every
# row and every refusal is checked here directly.
#
# The rows are docs/airig/specs/2026-09-30-roost-answer-design.md §5, measured
# on Claude Code 2.1.283, and Edit on 2.1.309. codex's rows (M3) are measured but held back until
# #145 is understood, so codex is refused here like a harness with no map.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Nothing here runs a harness, a hook or tmux. Every home is still pointed at a
# canary, as tests/test-install.sh does, so a later edit that adds one cannot
# reach a real home, and the check at the bottom says if anything landed.
work="$(mktemp -d /tmp/amx.XXXX)"
trap 'rm -rf "$work"' EXIT
CANARY="$work/canary"
export HOME="$CANARY/home" XDG_CONFIG_HOME="$CANARY/xdg-config" \
       XDG_STATE_HOME="$CANARY/xdg-state" XDG_DATA_HOME="$CANARY/xdg-data" \
       ROOST_RECORD_DIR="" CLAUDE_SETTINGS="$CANARY/claude/settings.json" \
       CODEX_HOME="$CANARY/codex" COPILOT_HOME="$CANARY/copilot" \
       PI_CODING_AGENT_DIR="$CANARY/pi/agent"
. "$HERE/scripts/lib/roost-answer.sh"

# row HARNESS KIND ACTION N OPTIONS -> "KEY|MARK1|MARK2", or "refused: WHY".
row() {
  if roost_answer_keys "$@"; then
    printf '%s|%s|%s' "$ROOST_ANSWER_KEY" "$ROOST_ANSWER_MARK1" "$ROOST_ANSWER_MARK2"
  else
    printf 'refused: %s' "$ROOST_ANSWER_REFUSAL"
  fi
}

# --- every measured row -------------------------------------------------------
assert_eq "$(row claude permission approve "" 0)" "1|Esc to cancel|Do you want to" \
  "Claude permission, approve: the digit 1, which confirms alone (M1)"
assert_eq "$(row claude permission deny "" 0)" "Escape|Esc to cancel|Do you want to" \
  "Claude permission, deny: Escape, never a digit (M1)"

for n in 1 2 3; do
  assert_eq "$(row claude question option "$n" 3)" "$n|Esc to cancel|Enter to select" \
    "Claude question with 3 options, --option $n: the digit $n, which picks and submits (M2)"
done
assert_eq "$(row claude question option 4 4)" "4|Esc to cancel|Enter to select" \
  "Claude question with 4 options, --option 4: the digit 4"
assert_eq "$(row claude question deny "" 3)" "Escape|Esc to cancel|Enter to select" \
  "Claude question, deny: Escape (M2)"

# --- every refusal -------------------------------------------------------------
assert_eq "$(row claude question approve "" 3)" "refused: this is a question with 3 options. Use --option N, or --deny" \
  "Claude question, --approve: refused, and says what to use"
for n in 0 4 5 10; do
  assert_eq "$(row claude question option "$n" 3)" "refused: option $n is not one of the 3 options the agent gave" \
    "Claude question with 3 options, --option $n: refused (Claude's own rows are not the agent's)"
done
assert_eq "$(row claude question option 2 x)" "refused: option 2 is not one of the 0 options the agent gave" \
  "Claude question, an option count that is not a digit is no options at all"
assert_eq "$(row claude permission option 2 0)" "refused: this is a permission prompt. Use --approve or --deny" \
  "Claude permission, --option: refused, and says what to use"
for a in approve deny option; do
  assert_eq "$(row claude other "$a" 1 0)" "refused: no measured keys for this claude dialog. Answer at the pane" \
    "Claude kind other, $a: no measured keys"
  assert_eq "$(row codex permission "$a" 1 0)" "refused: no measured keys for this codex dialog. Answer at the pane" \
    "codex permission, $a: no row in this cut (#145)"
  assert_eq "$(row codex other "$a" 1 0)" "refused: no measured keys for this codex dialog. Answer at the pane" \
    "codex kind other, $a: no measured keys"
  for h in opencode copilot pi; do
    assert_eq "$(row "$h" permission "$a" 1 0)" "refused: no measured keys for this $h dialog. Answer at the pane" \
      "$h, $a: no map at all"
  done
done

# --- the keys roost must never send to a permission prompt --------------------
# 2 and p grant a standing permission on the dialogs measured, Enter follows a
# cursor a person may have moved, Tab amends (§5). Swept over every harness and
# action, so a row added later that sends one of them turns this red.
bad=""
for h in claude codex opencode copilot pi; do
  for a in approve deny option; do
    for n in "" 1 2 3 4; do
      if roost_answer_keys "$h" permission "$a" "$n" 4; then
        case "$ROOST_ANSWER_KEY" in 2|p|Tab|Enter|'') bad="$bad $h/$a/$n=$ROOST_ANSWER_KEY" ;; esac
      fi
    done
  done
done
assert_eq "$bad" "" "no permission row sends 2, p, Tab, Enter or nothing"

# --- the marker ---------------------------------------------------------------
roost_answer_keys claude permission approve
roost_answer_marked " Do you want to proceed?
 > 1. Yes
   3. No
 Esc to cancel · Tab to amend"; assert_true $? "the marker: a Claude permission dialog on screen"
roost_answer_marked " Do you want to proceed?"; [ $? -ne 0 ]; assert_true $? "the marker: one line alone is not the dialog"
roost_answer_marked " Esc to cancel"; [ $? -ne 0 ]; assert_true $? "the marker: the other line alone is not the dialog"
roost_answer_marked ""; [ $? -ne 0 ]; assert_true $? "the marker: an empty screen is not the dialog"
roost_answer_keys claude question option 2 3
roost_answer_marked " Which color do you want?
 > 1. Red
   2. Green
 Enter to select · ↑/↓ to navigate · Esc to cancel"; assert_true $? "the marker: a Claude question on screen"
roost_answer_marked " Do you want to proceed?
 Esc to cancel · Tab to amend"; [ $? -ne 0 ]; assert_true $? "the marker: a permission prompt is not a question"

# --- the hex check every fingerprint passes through --------------------------
roost_answer_hex 3f9c1a2b7d4e 12; assert_true $? "hex: 12 lowercase hex is a fingerprint"
for bad in 3F9C1A2B7D4E 3f9c1a2b7d4 3f9c1a2b7d4e0 3f9c1a2b7d4g '' '3f9c1a2b7d4 ' '*'; do
  roost_answer_hex "$bad" 12; [ $? -ne 0 ]; assert_true $? "hex: '$bad' is not a fingerprint"
done

# --- the answered record ------------------------------------------------------
roost_answer_answered_parse "3f9c1a2b7d4e 1790748772 approve terminal" 3f9c1a2b7d4e
assert_eq "$?|$ROOST_ANSWERED_AT|$ROOST_ANSWERED_ACTION|$ROOST_ANSWERED_OPTION|$ROOST_ANSWERED_BY" \
  "0|1790748772|approve||terminal" "answered: approve from a terminal"
roost_answer_answered_parse "3f9c1a2b7d4e 1790748772 option3 pane:%12" 3f9c1a2b7d4e
assert_eq "$?|$ROOST_ANSWERED_ACTION|$ROOST_ANSWERED_OPTION|$ROOST_ANSWERED_BY" \
  "0|option|3|pane:%12" "answered: an option from a pane"
for bad in "3f9c1a2b7d4e 1790748772 approve terminal extra" "3f9c1a2b7d4e 01790748772 approve terminal" \
           "3f9c1a2b7d4e 1790748772 option0 terminal" "3f9c1a2b7d4e 1790748772 yes terminal" \
           "3f9c1a2b7d4e 1790748772 deny pane:%x" "3f9c1a2b7d4e 1790748772 deny human" \
           "000000000000 1790748772 deny terminal"; do
  roost_answer_answered_parse "$bad" 3f9c1a2b7d4e; [ $? -ne 0 ]; assert_true $? "answered: '$bad' is no answer to this dialog"
done

assert_eq "$(find "$CANARY" -mindepth 1 2>/dev/null | sort)" "" "nothing was written under the canary homes"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
