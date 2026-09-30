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

# --- colour: the state word is painted, and NO_COLOR turns it off ---
# printf builds the escape byte, so this file never has to hold a raw one.
esc="$(printf '\033')"
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_contains "$(prows "$p0")" "${esc}[31m" "a blocked pane's row is painted red"
assert_contains "$(prows "$p1")" "${esc}[33m" "a working pane's row is painted yellow"
rows="$(NO_COLOR=1 ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
case "$rows" in
  *"$esc"*) assert_eq "has-escapes" "none" "NO_COLOR leaves no escape codes in any row" ;;
  *) assert_eq ok ok "NO_COLOR leaves no escape codes in any row" ;;
esac
# The control for the assertion above: the pane's row is still there, so "no
# escape codes" is not just "no rows".
assert_eq "$(prows "$p0" | wc -l | tr -d ' ')" "1" "NO_COLOR still emits the pane's row"

# --- the state filter and the agents-only switch ---
# These go through the same two helper commands and the same state directory
# the popup's keys use, rather than a test-only variable: the keys are the
# thing that must work.
sw_state="$(mktemp -d)"
sw() { ROOST_SWITCH_STATE="$sw_state" ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" "$HERE/scripts/roost-switch" "$@"; }
sw_rows() { rows="$(ROOST_SWITCH_DUMP=1 sw)"; }
npanes() { printf '%s\n' "$rows" | awk -F'\t' '$3!=""' | wc -l | tr -d ' '; }

sw_rows; all_n="$(npanes)"
sw --cycle-filter; sw_rows
assert_eq "$(npanes)" "1" "the first filter step shows only panes that need you"
assert_eq "$(prows "$p0" | wc -l | tr -d ' ')" "1" "the blocked pane is the one the needs-you filter keeps"
# w0 holds three panes but only one is shown, so it collapses to a flat row —
# a header above a single row is the doubling the layout exists to avoid.
assert_eq "$(hdrs "$w0")" "0" "a window showing one of its panes under a filter emits no header"
assert_contains "$(sw --rows status | head -1)" "needs you" "the sticky header names the filter in force"

T set-option -p -t "$p0b" @agent_state error
sw_rows
assert_eq "$(npanes)" "2" "an errored pane needs you too"
T set-option -p -t "$p0b" @agent_state idle

sw --cycle-filter; sw_rows
assert_eq "$(npanes)" "1" "the second filter step shows only working panes"
assert_eq "$(prows "$p1" | wc -l | tr -d ' ')" "1" "the working pane is the one the working filter keeps"
sw --cycle-filter; sw_rows
assert_eq "$(npanes)" "0" "the third filter step shows only done panes, and none is done"
sw --cycle-filter; sw_rows
assert_eq "$(npanes)" "$all_n" "the fourth filter step is back to every pane"

sw --toggle-agents; sw_rows
assert_eq "$(prows "$plain" | wc -l | tr -d ' ')" "0" "agents-only hides a pane that has no state"
assert_eq "$(prows "$p0b" | wc -l | tr -d ' ')" "1" "agents-only keeps an idle AGENT pane"
sw --toggle-agents; sw_rows
assert_eq "$(npanes)" "$all_n" "toggling agents-only again shows every pane"
rm -rf "$sw_state"

# With no state directory (a person or a script calling a helper by hand), the
# helper must write nowhere and the rows must stay unfiltered.
ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" "$HERE/scripts/roost-switch" --cycle-filter
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_eq "$(npanes)" "$all_n" "a filter step with no state directory changes nothing"

# --- preview: the screen of the row under the cursor ---
pv="$(T new-window -d -P -F '#{pane_id}' 'sh -c "echo PREVIEW-MARK; exec sleep 600"')"
# Bounded gate on the echo landing — deterministic, unlike racing it.
for _ in $(seq 1 50); do
  T capture-pane -p -t "$pv" | grep -q PREVIEW-MARK && break
  sleep 0.05
done
pvw="$(T display-message -p -t "$pv" '#{window_id}')"
pvs="$(T display-message -p -t "$pv" '#{session_id}')"
out="$(sw --preview "$pvs" "$pvw" "$pv")"
assert_contains "$out" "PREVIEW-MARK" "the preview shows the pane's screen"
# The pane printed one line; the rest of its screen is blank and must be cut,
# or the preview (which follows the bottom) would show only the blank part.
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "the preview drops the blank lines under the output"
T select-window -t "$pvw"
assert_contains "$(sw --preview "$pvs" "$pvw" "")" "PREVIEW-MARK" "a window header previews the window's active pane"
assert_eq "$(sw --preview "" "" "")" "" "a row with no ids previews nothing"

# --- what the installed fzf can do, asked of fzf itself ---
# Stand-in fzf programs that answer the probe the three possible ways. PATH is
# ONLY the stand-in directory, so the real fzf on this machine cannot answer
# instead; bash is named by path because nothing else is on that PATH.
fz="$(mktemp -d)"
tier() { PATH="$1" "$BASH" "$HERE/scripts/roost-switch" --fzf-tier; }
assert_eq "$(tier "$fz")" "none" "no fzf on PATH reads as tier none"
printf '#!/bin/sh\nexit 2\n' > "$fz/fzf"; chmod +x "$fz/fzf"
assert_eq "$(tier "$fz")" "basic" "an fzf that rejects the live bindings reads as tier basic"
printf '#!/bin/sh\nexit 1\n' > "$fz/fzf"; chmod +x "$fz/fzf"
assert_eq "$(tier "$fz")" "live" "an fzf that accepts the live bindings reads as tier live"
rm -rf "$fz"

# --- sessions: a header per session, but only when there is more than one ---
# Last in the file on purpose: a second session changes every row above it.
shdr_rows() { printf '%s\n' "$rows" | awk -F'\t' '$1!="" && $2=="" && $3==""'; }
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_eq "$(shdr_rows | grep -c .)" "0" "one session emits no session header"
T new-session -d -s second
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch")"
assert_eq "$(shdr_rows | grep -c .)" "2" "two sessions emit one header each"
assert_contains "$(shdr_rows)" "second" "a session header names its session"
# each session's rows form one contiguous run, its header first
assert_eq "$(printf '%s\n' "$rows" | cut -f1 | uniq | wc -l | tr -d ' ')" "2" \
  "each session's rows form one contiguous run"
