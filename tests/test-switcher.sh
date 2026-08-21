#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
roost_test_server; trap roost_test_teardown EXIT
T source-file "$HERE/tmux/roost.conf"
T set-option -g @roost-home "$HERE"

# prefix a target script exists and is executable
[ -x "$HERE/scripts/roost-switch" ] && assert_eq ok ok "roost-switch is executable" \
  || assert_eq "" exec "roost-switch is executable"

# rollup: counts AGENT PANES, not windows. Two agents in one window count twice;
# a plain shell counts not at all.
w0="$(T display -p '#{window_id}')"
p0="$(T display -p '#{pane_id}')"
p0b="$(T split-window -d -P -F '#{pane_id}' -t "$p0" 'sh -c "while :; do sleep 5; done"')"
p1="$(T new-window -d -PF '#{pane_id}')"
T new-window -d              # a window of plain shells — contributes nothing
T set-option -p -t "$p0"  @agent_state blocked
T set-option -p -t "$p0b" @agent_state idle
T set-option -p -t "$p1"  @agent_state working
out="$(ROOST_STATUS_SOCK="$ROOST_TEST_SOCK" "$HERE/scripts/roost-status" 2>/dev/null || true)"
assert_contains "$out" "🛑 1" "rollup shows one blocked (🛑 1)"
assert_contains "$out" "⏳ 1" "rollup shows one working (⏳ 1)"
assert_contains "$out" "💤 1" "rollup counts the idle AGENT pane, not the plain shells"
# emoji self-colour: the rollup must emit NO raw #[fg=...] colour codes
case "$out" in *'#[fg='*) assert_eq "has-codes" "none" "rollup emits no raw colour codes" ;;
  *) assert_eq ok ok "rollup emits no raw colour codes" ;; esac

# --- switcher rows (fzf needs a tty, so dump the composed rows instead) ---
T set-option -g @roost-glyph-blocked "B"
T set-option -g @roost-glyph-working "W"
T set-option -g @roost-glyph-idle    "I"
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"

# Field-match with awk rather than grepping for literal tabs — a tab that gets
# mangled into spaces on edit would make these assertions quietly meaningless.
hdrs()  { printf '%s\n' "$rows" | awk -F'\t' -v w="$1" '$2==w && $3==""'  | wc -l | tr -d ' '; }
prows() { printf '%s\n' "$rows" | awk -F'\t' -v p="$1" '$3==p'; }

# w0 has two panes -> a header row plus one indented row per pane
assert_eq "$(hdrs "$w0")" "1" "a multi-pane window emits exactly one header row"
assert_eq "$(prows "$p0"  | wc -l | tr -d ' ')" "1" "the blocked pane appears as its own row"
assert_eq "$(prows "$p0b" | wc -l | tr -d ' ')" "1" "the sibling pane appears as its own row"

# a single-pane window collapses to ONE flat row — no header
w1id="$(T display-message -p -t "$p1" '#{window_id}')"
assert_eq "$(prows "$p1" | wc -l | tr -d ' ')" "1" "a single-pane window emits one row"
assert_eq "$(hdrs "$w1id")" "0" "a single-pane window emits no header row"

# every pane row carries window·command, so fzf filtering (which hides headers)
# leaves each row still self-describing — UNLESS the label just echoes the
# window name back (see the suppression test below). Both branches depend on
# the relationship between #{window_name} and the pane's resolved label, and
# this test does not get to leave that relationship to chance: tmux's
# automatic-rename recomputes the name asynchronously (observed directly —
# setting automatic-rename-format does not retitle the window until a later,
# separate round-trip to the server lands), so whether a bare `T display` here
# reads the pre- or post-rename value is a race, not a fact about the
# environment. CI happened to read it before the recompute landed (window
# stayed at its startup name, which matched the pane's command, so the
# suppression branch fired); this machine's timing usually let the recompute
# land first. Pin the window name explicitly instead of racing it.
T rename-window -t "$w0" apiwin
# An explicit rename-window turns automatic-rename off for that window (tmux's
# own documented behaviour), so "apiwin" cannot be renamed out from under us
# by a later automatic-rename tick. Confirm rather than assume.
assert_eq "$(T show-options -wqv -t "$w0" automatic-rename)" "off" \
  "an explicit rename-window disables automatic-rename for that window"
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_contains "$(prows "$p0b")" "apiwin·" "a pane row names its window, so filtered rows keep context"

# ...and the suffix is SUPPRESSED when the pane's resolved label equals the
# window name — the pairing `roost spawn NAME` produces, since it names the
# window and the pane from the same NAME. Reproduce that pairing directly
# (explicit rename + explicit @roost-name) rather than hoping automatic-rename
# happens to land on a matching value.
w3="$(T new-window -d -PF '#{window_id}')"
p3="$(T display-message -p -t "$w3" '#{pane_id}')"
T rename-window -t "$w3" samename
T set-option -p -t "$p3" @roost-name samename
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
prow3="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p3" '$3==p')"
assert_contains "$prow3" "samename" "a pane row whose label equals its window name still shows the name"
case "$prow3" in
  *"samename·samename"*) assert_eq "doubled" "single" "the ·suffix is suppressed when the label equals the window name" ;;
  *) assert_eq ok ok "the ·suffix is suppressed when the label equals the window name" ;;
esac

# a non-agent pane shows the idle glyph and no state word
T new-window -d
plain="$(T list-panes -a -F '#{pane_id} #{@agent_state}' | awk '$2==""{print $1; exit}')"
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
prow="$(prows "$plain")"
assert_contains "$prow" "I" "a non-agent pane row shows the idle glyph"
case "$prow" in *blocked*|*working*|*done*|*idle*)
    assert_eq "has-state" "none" "a non-agent pane row names no state" ;;
  *) assert_eq ok ok "a non-agent pane row names no state" ;;
esac

# rows are GROUPED: every window's rows form one contiguous run, so a header is
# never separated from the panes it introduces. If the sort were dropped, the
# runs would interleave and the de-duplicated count would exceed the unique one.
runs="$(printf '%s\n' "$rows" | cut -f2 | uniq | wc -l | tr -d ' ')"
uniq="$(printf '%s\n' "$rows" | cut -f2 | sort -u | wc -l | tr -d ' ')"
assert_eq "$runs" "$uniq" "each window's rows form one contiguous run"

# --- switcher prefers @roost-name over the process name ---
T set-option -p -t "$p0" @roost-name "planner"
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')" "planner" \
  "a named pane's switcher row shows the name"
T set-option -pu -t "$p0" @roost-name

# The fallback is asserted against a pane PINNED to a long-lived command, not
# against a second read of a live value. This used to read
# #{pane_current_command} here and compare it to what roost-switch had read
# moments earlier — two samples of a live value, compared as if they were one.
# It failed 3 times in 400 runs, in BOTH directions. The churn came from the
# pane's shell sourcing its rc files, which tests/lib.sh now avoids, but a
# pane's command is a live value in principle and this assertion should not
# depend on it holding still. A pane running `exec sleep 600` reported "sleep"
# on 6000 consecutive
# reads, so "sleep" can simply be a literal in this file and the comparison
# needs no second read at all.
# tests/live/switcher-read-race.sh is the standing proof: under forced churn the
# old shape mismatched 125 times in 600 read-pairs, this shape 0 times.
pf="$(T split-window -d -P -F '#{pane_id}' -t "$p0" 'exec sleep 600')"
# Bounded gate on the exec landing — deterministic, unlike racing it.
for _ in $(seq 1 50); do
  [ "$(T display-message -p -t "$pf" '#{pane_current_command}')" = sleep ] && break
  sleep 0.05
done
assert_eq "$(T display-message -p -t "$pf" '#{pane_current_command}')" "sleep" \
  "the pinned pane reports a stable command"
# apiwin is not "sleep", so roost-switch's suffix-suppression branch does not
# fire and the row carries the dot-suffix. Asserting "·sleep" rather than bare
# "sleep" also stops this passing on some unrelated substring.
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$pf" '$3==p')" "·sleep" \
  "an unnamed pane's switcher row falls back to the command"
