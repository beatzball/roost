#!/usr/bin/env bash
# The window tab badge summarises the PANES in a window: one glyph per distinct
# agent state, urgency-ordered and deduplicated. A pane is an agent only if its
# pane-scoped @agent_state is non-empty, so a plain shell never badges a tab.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"
T set-option -g @amux-glyph-blocked "B"
T set-option -g @amux-glyph-working "W"
T set-option -g @amux-glyph-done    "D"
T set-option -g @amux-glyph-idle    "I"

hold='sh -c "while :; do sleep 5; done"'
badge() { T list-windows -a -F "#{window_id}|#{E:@amux-tab-badge}" | grep "^$1|" | cut -d'|' -f2; }
busy()  { T list-windows -a -F "#{window_id}|#{E:@amux-tab-busy}"  | grep "^$1|" | cut -d'|' -f2; }

# window 1: a plain shell + one blocked agent
w1="$(T display-message -p '#{window_id}')"
p1a="$(T display-message -p '#{pane_id}')"
p1b="$(T split-window -d -P -F '#{pane_id}' -t "$p1a" "$hold")"
T set-option -p -t "$p1b" @agent_state blocked
assert_eq "$(badge "$w1")" "B" "a plain shell alongside an agent adds no idle glyph"

# window 2: no agents at all -> the idle glyph, so a fresh tab looks unchanged
w2="$(T new-window -d -P -F '#{window_id}' "$hold")"
assert_eq "$(badge "$w2")" "I" "a window with no agents falls back to the idle glyph"
assert_eq "$(busy "$w2")"  "0" "a window with no agents is not busy"

# window 3: working + done -> both glyphs, urgency-ordered
w3p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w3="$(T display-message -p -t "$w3p" '#{window_id}')"
w3b="$(T split-window -d -P -F '#{pane_id}' -t "$w3p" "$hold")"
T set-option -p -t "$w3p" @agent_state working
T set-option -p -t "$w3b" @agent_state done
assert_eq "$(badge "$w3")" "WD" "distinct states render urgency-ordered"
assert_eq "$(busy "$w3")"  "1" "a window with a working agent is busy"

# window 4: two working agents dedupe to ONE glyph
w4p="$(T new-window -d -P -F '#{pane_id}' "$hold")"
w4="$(T display-message -p -t "$w4p" '#{window_id}')"
w4b="$(T split-window -d -P -F '#{pane_id}' -t "$w4p" "$hold")"
T set-option -p -t "$w4p" @agent_state working
T set-option -p -t "$w4b" @agent_state working
assert_eq "$(badge "$w4")" "W" "duplicate states dedupe to one glyph"

# all three urgent states together, in order
T set-option -p -t "$w4b" @agent_state done
w4c="$(T split-window -d -P -F '#{pane_id}' -t "$w4p" "$hold")"
T set-option -p -t "$w4c" @agent_state blocked
assert_eq "$(badge "$w4")" "BWD" "blocked sorts before working before done"

# the tab formats must go through #{E:}, or the option renders as literal text
fmt="$(T show-options -gqv window-status-format)"
assert_contains "$fmt" '#{E:@amux-tab-badge}' "window-status-format expands the badge option"
cfmt="$(T show-options -gqv window-status-current-format)"
assert_contains "$cfmt" '#{E:@amux-tab-badge}' "active tab format expands the badge option"
assert_contains "$(T display-message -p -t "$w1" "$fmt")" "B" "the rendered tab carries the badge"

# regression guard: a literal comma inside #{P:...} is parsed as the
# active/inactive separator, silently changing what the loop emits
conf="$(cat "$HERE/tmux/amux.conf")"
case "$conf" in
  *'#{P:#{@agent_state},'*) assert_eq comma space "no literal comma inside a #{P:} loop body" ;;
  *)                        assert_eq ok ok       "no literal comma inside a #{P:} loop body" ;;
esac

# --- pane borders: each pane badges its own state ---
border() { T list-panes -a -F "#{pane_id}|#{E:@amux-pane-border}" | grep "^$1|" | cut -d'|' -f2; }

assert_contains "$(border "$p1b")" "B" "an agent pane's border shows its state glyph"
assert_contains "$(border "$p1b")" "blocked" "an agent pane's border names its state"
assert_contains "$(border "$p1b")" "$p1b" "a pane's border shows its stable %N id"

# a non-agent pane gets no glyph and no state word
nb="$(border "$p1a")"
assert_contains "$nb" "$p1a" "a non-agent pane's border still shows its %N id"
case "$nb" in *blocked*|*working*|*done*|*idle*)
    assert_eq "has-state" "none" "a non-agent pane's border names no state" ;;
  *) assert_eq ok ok "a non-agent pane's border names no state" ;;
esac

# a half-stamped pane (state but no @agent_since) must not render garbage
T set-option -p -t "$p1a" @agent_state working
T set-option -pu -t "$p1a" @agent_since
assert_contains "$(border "$p1a")" "working" "a pane with no @agent_since still renders its state"

# borders are on, so panes are distinguishable inside a split window
# -g, not -w: pane-border-status is set globally (setw -g), never overridden
# per-window, so -w alone (without -A) sees no window-scoped value to show.
assert_eq "$(T show-options -gqv pane-border-status)" "top" "pane border status is enabled"
