#!/usr/bin/env bash
# tests/test-background-badge.sh — a pane held only by its own background work
# shows a badge of its own (#193), and is still `working` underneath.
#
# Since #187 a Claude pane whose turn has ended while a `run_in_background`
# command, a background agent or a `Monitor` still runs stays `working`, with
# @roost-background "<@agent_since> N" beside it. It read ⏳, the same as an
# agent in the middle of a turn. This file pins what a person now sees -- the
# background glyph and the word `background (N)` on the pane border, the tab,
# the status-bar rollup, the switcher and `roost status` -- and that nothing
# a program waits on moved: the state is still `working`, `wait-done` still
# waits, `send --when-idle` still holds.
#
# Badges and hold records are set BY HAND on a throwaway server, in the
# record's real shape (scripts/roost-agent-state writes it with
# `set-option -F @roost-background "#{@agent_since} N"`), so the test owns the
# timing. tests/test-turn-over-hold.sh pins that the hook writes that shape.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# Every home a roost command could write to points at a canary directory the
# last block checks (tests/test-install.sh's shape). Nothing here should write
# anywhere at all, so the canary must stay empty.
work="$(mktemp -d /tmp/amx.XXXX)"
canary="$work/canary"
mkdir -p "$canary"
export HOME="$canary/home" XDG_CONFIG_HOME="$canary/config" \
       XDG_STATE_HOME="$canary/state" XDG_DATA_HOME="$canary/data" \
       CLAUDE_SETTINGS="$canary/claude-settings.json" CODEX_HOME="$canary/codex" \
       COPILOT_HOME="$canary/copilot" PI_CODING_AGENT_DIR="$canary/pi"
unset ZDOTDIR TMUX TMUX_PANE
roost_test_server
trap 'roost_test_teardown; rm -rf "$work"' EXIT
export ROOST_SOCKET="$ROOST_TEST_SOCK"
T source-file "$HERE/tmux/roost.conf"
T set-option -g @roost-home "$HERE"
# One letter per glyph, so a substring check cannot pass on the wrong badge.
T set-option -g @roost-glyph-error      "E"
T set-option -g @roost-glyph-blocked    "B"
T set-option -g @roost-glyph-working    "W"
T set-option -g @roost-glyph-background "G"
T set-option -g @roost-glyph-done       "D"
T set-option -g @roost-glyph-idle       "I"

hold='sh -c "while :; do sleep 5; done"'
border() { T list-panes -a -F "#{pane_id}|#{E:@roost-pane-border}" | grep "^$1|" | cut -d'|' -f2; }
badge()  { T list-windows -a -F "#{window_id}|#{E:@roost-tab-badge}" | grep "^$1|" | cut -d'|' -f2; }
busy()   { T list-windows -a -F "#{window_id}|#{E:@roost-tab-busy}"  | grep "^$1|" | cut -d'|' -f2; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
# jbg PANE -> that pane's `background` in `status --json`, as Python prints it.
jbg() { "$ROOST" status --json | jget '[x["background"] for x in d["panes"] if x["id"]=="'"$1"'"][0]'; }
jstate() { "$ROOST" status --json | jget '[x["state"] for x in d["panes"] if x["id"]=="'"$1"'"][0]'; }
# held PANE COUNT: the pane as a held Stop leaves it.
held() {
  T set-option -p -t "$1" @agent_state working \; set-option -p -t "$1" @agent_since 1789000000 \; \
    set-option -p -t "$1" -F @roost-background "#{@agent_since} $2"
}

# Window A: one held pane, alone.
pa="$(T new-window -d -P -F '#{pane_id}' "$hold")"; require_pane "$pa" "held pane"
wa="$(T display-message -p -t "$pa" '#{window_id}')"
held "$pa" 2

# --- 1. the held pane's own badge ---------------------------------------------
b="$(border "$pa")"
assert_contains "$b" "G $pa" "a held pane's border shows the background glyph"
assert_contains "$b" "· background (2)" "...and the word background with the count"
case "$b" in *W*) assert_eq "$b" "no W" "...and not the working glyph" ;;
  *) assert_eq ok ok "...and not the working glyph" ;; esac
assert_eq "$(badge "$wa")" "G" "a window of one held pane badges G, not W"
assert_eq "$(busy "$wa")" "1" "...and still reads busy"
assert_eq "$(T show-options -pqv -t "$pa" @agent_state)" "working" "the state underneath is still working"

# --- 2. a working pane that is not held is unchanged --------------------------
pb="$(T split-window -d -P -F '#{pane_id}' -t "$pa" "$hold")"; require_pane "$pb" "working pane"
T set-option -p -t "$pb" @agent_state working \; set-option -p -t "$pb" @agent_since 1789000100
assert_contains "$(border "$pb")" "W $pb" "a working pane with no hold still shows the working glyph"
assert_contains "$(border "$pb")" "· working" "...and the word working"
assert_eq "$(badge "$wa")" "WG" "working and held in one window: both glyphs, working first"

# A record from another stamp says nothing about this turn: plain working.
T set-option -p -t "$pb" @roost-background "1788999999 3"
assert_contains "$(border "$pb")" "W $pb" "a hold record from an earlier stamp is ignored"
assert_eq "$(badge "$wa")" "WG" "...on the tab too: the window still shows both glyphs"
assert_eq "$(jbg "$pb")" "None" "...and status --json says background null for it"
# A pane with no @agent_since cannot be matched to a record at all.
pc="$(T split-window -d -P -F '#{pane_id}' -t "$pa" "$hold")"; require_pane "$pc" "no-since pane"
T set-option -p -t "$pc" @agent_state working \; set-option -p -t "$pc" @roost-background " 1"
assert_contains "$(border "$pc")" "W $pc" "a record on a pane with no stamp is ignored"
T set-option -p -t "$pb" @agent_state done
assert_eq "$(badge "$wa")" "WGD" "...on the tab too: the stampless pane is working, not background"
T set-option -p -t "$pb" @agent_state working
T kill-pane -t "$pc"

# --- 3. a count roost could not read ------------------------------------------
pq="$(T new-window -d -P -F '#{pane_id}' "$hold")"; require_pane "$pq" "? pane"
held "$pq" "?"
bq="$(border "$pq")"
assert_contains "$bq" "G $pq" "a hold with count ? still shows the background glyph"
assert_contains "$bq" "· background " "...and the word background"
case "$bq" in *"("*) assert_eq "$bq" "no count" "...with no count in brackets" ;;
  *) assert_eq ok ok "...with no count in brackets" ;; esac

# --- 4. status --json --------------------------------------------------------
assert_eq "$(jbg "$pa")" "2" "status --json: background is the count"
assert_eq "$(jstate "$pa")" "working" "status --json: state is still working"
assert_eq "$(jbg "$pq")" "None" "status --json: a ? count is null"
T set-option -p -t "$pb" -u @roost-background
assert_eq "$(jbg "$pb")" "None" "status --json: a pane that is not held is null"
assert_eq "$("$ROOST" status --json | jget 'd["schema"]')" "1" "status --json: schema stays 1"

# --- 5. roost status (human) --------------------------------------------------
st="$("$ROOST" status)"
assert_contains "$(printf '%s\n' "$st" | grep "^    $pa ")" "[background (2)]" "roost status names the held pane background (2)"
assert_contains "$(printf '%s\n' "$st" | grep "^    $pq ")" "[background]" "roost status: a ? hold reads [background]"
assert_contains "$(printf '%s\n' "$st" | grep "^    $pb ")" "[working]" "roost status: a working pane still reads [working]"

# --- 6. the status-bar rollup and the switcher --------------------------------
out="$(ROOST_STATUS_SOCK="$ROOST_TEST_SOCK" "$HERE/scripts/roost-status" 2>/dev/null || true)"
assert_contains "$out" "W 1  G 2  " "rollup: one working, two background, in that order"
rows="$(ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 NO_COLOR=1 "$HERE/scripts/roost-switch")"
prow() { printf '%s\n' "$rows" | awk -F'\t' -v p="$1" '$3==p'; }
assert_contains "$(prow "$pa")" "G background (2) " "switcher: the held pane's row"
assert_contains "$(prow "$pq")" "G background " "switcher: the ? pane's row"
assert_contains "$(prow "$pb")" "W working " "switcher: the working pane's row is unchanged"
# The state column is as wide as its widest word, so the rows still line up.
ca="$(prow "$pa" | cut -f4)"; cb="$(prow "$pb" | cut -f4)"
assert_eq "$(printf '%s' "${ca%%$pa*}" | wc -m | tr -d ' ')" "$(printf '%s' "${cb%%$pb*}" | wc -m | tr -d ' ')" "switcher: the pane id starts in the same column on both rows"
# With no held pane at all, the column is the old 8 wide: nothing moves.
rows_plain="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$pb" '$3==p')"
assert_contains "$rows_plain" "W working " "switcher: a working row reads as before"
T set-option -g @roost-switch-filter "" 2>/dev/null || true
mkdir -p "$work/sw"; printf 'working\n' > "$work/sw/filter"
rows_w="$(ROOST_SWITCH_STATE="$work/sw" ROOST_SWITCH_SOCK="$ROOST_TEST_SOCK" ROOST_SWITCH_DUMP=1 NO_COLOR=1 "$HERE/scripts/roost-switch")"
printf '%s\n' "$rows_w" | awk -F'\t' -v p="$pa" '$3==p' | grep -q background
assert_true $? "switcher: the working filter keeps a held pane (it is working underneath)"

# --- 7. blocked during a hold reads blocked, not background --------------------
T set-option -p -t "$pq" @agent_state blocked
assert_contains "$(border "$pq")" "B $pq" "a held pane that opens a dialog shows the blocked glyph"
assert_contains "$(border "$pq")" "· blocked" "...and the word blocked"
T set-option -p -t "$pq" @agent_state working

# --- 8. the hold released: a normal done --------------------------------------
T set-option -p -t "$pa" @agent_state done \; set-option -p -t "$pa" -u @roost-background
assert_contains "$(border "$pa")" "D $pa" "the released pane shows done"
assert_contains "$(border "$pa")" "· done" "...and the word done"
assert_eq "$(jbg "$pa")" "None" "...and status --json background null"
held "$pa" 1
assert_contains "$(border "$pa")" "· background (1)" "a count of 1 reads background (1)"

# --- 9. the glyph is overridable, and every set has one -----------------------
T set-option -g @roost-glyph-background "ZZ"
assert_contains "$(border "$pa")" "ZZ $pa" "an override of @roost-glyph-background shows on the border"
assert_contains "$(badge "$wa")" "ZZ" "...and on the tab"
T set-option -g @roost-glyph-background "G"
. "$HERE/scripts/roost-themes.sh"
. "$HERE/scripts/lib/roost-config.sh"
assert_eq "$(roost_glyph_background ascii)" "[&]" "the ascii set's background glyph is [&]"
assert_eq "$(roost_glyph_background orbs)" "⚪" "the orbs set's background glyph"
assert_eq "$(roost_glyph_background emoji)" "🔄" "the emoji set's background glyph"
assert_eq "$(roost_glyph_background nosuch)" "🔄" "an unknown set falls back to emoji, as roost_glyphset does"
# Compare BYTES for the nerd glyph: a Private Use codepoint can render zero
# width in a capture, so a screenshot or a pane read proves nothing.
assert_eq "$(roost_glyph_background nerd | od -An -tx1 | tr -d ' \n')" "ef879a" "the nerd set's background glyph is U+F1DA (fa-history)"
assert_eq "$(sed -n 's/^set -g @roost-glyph-background *"\(.*\)"$/\1/p' "$HERE/tmux/roost.conf")" "🔄" "tmux/roost.conf's default is the emoji set's"
for set in emoji orbs ascii nerd; do
  g="$(roost_glyph_background "$set")"
  set -f; set -- $(roost_glyphset "$set"); set +f
  case " $* " in *" $g "*) assert_eq "$g" "unique" "[$set] the background glyph is not one of the five" ;;
    *) assert_eq ok ok "[$set] the background glyph is not one of the five" ;; esac
done
ROOST_CONFIG_SOCK="$ROOST_TEST_SOCK" roost_preview_apply glyphs ascii
assert_eq "$(T show-options -gqv @roost-glyph-background)" "[&]" "previewing the ascii set sets the background glyph too"
case " $(roost_preview_keys glyphs) " in *" @roost-glyph-background "*) assert_eq ok ok "the glyph preview snapshots the background glyph" ;;
  *) assert_eq "$(roost_preview_keys glyphs)" "has @roost-glyph-background" "the glyph preview snapshots the background glyph" ;; esac
T set-option -g @roost-glyph-background "G"

# --- 10. no behaviour change: a held pane still blocks the waiters ------------
held "$pa" 2
"$ROOST" wait-done "$pa" 1 >/dev/null 2>"$work/wd.err"; rc=$?
assert_eq "$rc" "1" "wait-done on a held pane times out with exit 1 (stderr: $(cat "$work/wd.err"))"
assert_contains "$(cat "$work/wd.err")" "timed out" "...saying it timed out"
T set-option -g @roost-send-idle-timeout 1
"$ROOST" send --when-idle "$pa" "hello" >/dev/null 2>"$work/wi.err"; rc=$?
assert_eq "$rc" "6" "send --when-idle to a held pane holds, then exits 6 (stderr: $(cat "$work/wi.err"))"
assert_eq "$(T show-options -pqv -t "$pa" @agent_state)|$(T show-options -pqv -t "$pa" @roost-background)" "working|1789000000 2" "...and the pane and its hold record are untouched"

# --- 11. nothing was written to any home --------------------------------------
left="$(find "$canary" -mindepth 1 2>/dev/null | head -5)"
assert_eq "$left" "" "nothing was written under the canary homes"
