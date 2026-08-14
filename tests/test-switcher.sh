#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

# prefix a target script exists and is executable
[ -x "$HERE/scripts/amux-switch" ] && assert_eq ok ok "amux-switch is executable" \
  || assert_eq "" exec "amux-switch is executable"

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
out="$(AMUX_STATUS_SOCK="$AMUX_TEST_SOCK" "$HERE/scripts/amux-status" 2>/dev/null || true)"
assert_contains "$out" "🛑 1" "rollup shows one blocked (🛑 1)"
assert_contains "$out" "⏳ 1" "rollup shows one working (⏳ 1)"
assert_contains "$out" "💤 1" "rollup counts the idle AGENT pane, not the plain shells"
# emoji self-colour: the rollup must emit NO raw #[fg=...] colour codes
case "$out" in *'#[fg='*) assert_eq "has-codes" "none" "rollup emits no raw colour codes" ;;
  *) assert_eq ok ok "rollup emits no raw colour codes" ;; esac

# --- switcher rows (fzf needs a tty, so dump the composed rows instead) ---
T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-idle    "I"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"

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
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
assert_contains "$(prows "$p0b")" "apiwin·" "a pane row names its window, so filtered rows keep context"

# ...and the suffix is SUPPRESSED when the pane's resolved label equals the
# window name — the pairing `amux spawn NAME` produces, since it names the
# window and the pane from the same NAME. Reproduce that pairing directly
# (explicit rename + explicit @amux-name) rather than hoping automatic-rename
# happens to land on a matching value.
w3="$(T new-window -d -PF '#{window_id}')"
p3="$(T display-message -p -t "$w3" '#{pane_id}')"
T rename-window -t "$w3" samename
T set-option -p -t "$p3" @amux-name samename
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
prow3="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p3" '$3==p')"
assert_contains "$prow3" "samename" "a pane row whose label equals its window name still shows the name"
case "$prow3" in
  *"samename·samename"*) assert_eq "doubled" "single" "the ·suffix is suppressed when the label equals the window name" ;;
  *) assert_eq ok ok "the ·suffix is suppressed when the label equals the window name" ;;
esac

# a non-agent pane shows the idle glyph and no state word
T new-window -d
plain="$(T list-panes -a -F '#{pane_id} #{@agent_state}' | awk '$2==""{print $1; exit}')"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
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

# --- switcher prefers @amux-name over the process name ---
T set-option -p -t "$p0" @amux-name "planner"
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')" "planner" \
  "a named pane's switcher row shows the name"
T set-option -pu -t "$p0" @amux-name
rows="$(AMUX_SWITCH_SOCK="$AMUX_TEST_SOCK" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch")"
cmd="$(T display-message -p -t "$p0" '#{pane_current_command}')"
assert_contains "$(printf '%s\n' "$rows" | awk -F'\t' -v p="$p0" '$3==p')" "$cmd" \
  "an unnamed pane's switcher row falls back to the command"
