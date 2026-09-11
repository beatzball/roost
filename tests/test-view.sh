#!/usr/bin/env bash
# tests/test-view.sh — `roost view`: show a human something, in a pane if there
# is room and a window if there is not, replacing the last view of that name.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_SOCKET="$sock"

# lib.sh starts the server at -x 200, which is above the 180-column default, so
# the plain calls below take the PANE branch. The window branch is reached by
# raising ROOST_VIEW_MIN_COLS rather than by resizing, because a resize races
# the split and this suite must not flake on a busy machine.
w="$(T display-message -p '#{window_id}')"
agent="$(T display-message -p '#{pane_id}')"

# how many panes anywhere on the server carry this @roost-name
named_count() { T list-panes -a -F '#{@roost-name}' | grep -cx "$1" || true; }
alive() { [ -n "$(T display-message -p -t "$1" '#{pane_id}' 2>/dev/null || true)" ]; }

# --- the guard -------------------------------------------------------------
# Outside a roost session there is no pane to measure and no human watching.
out="$(env -u TMUX_PANE "$ROOST" view sleep 600 2>&1)"; rc=$?
assert_eq "$rc" "1" "view outside roost exits 1"
assert_contains "$out" "not inside a roost session" "view explains it's outside roost"

# A $TMUX_PANE from the user's ORDINARY tmux is a valid-looking id that belongs
# to a stranger's pane on this server. It must not be trusted as the caller: it
# would be the one pane spared from the replace step, and the pane whose width
# decides the layout. %999 stands in for an id this server has never issued.
out="$(TMUX_PANE='%999' "$ROOST" view sleep 600 2>&1)"; rc=$?
assert_eq "$rc" "1" "view rejects a \$TMUX_PANE this server does not know"
assert_contains "$out" "not inside a roost session" "view explains the foreign pane id the same way"

# CMD is required: view names no command of its own, so there is no default.
out="$(TMUX_PANE="$agent" "$ROOST" view 2>&1)"; rc=$?
assert_eq "$rc" "1" "view with no CMD exits 1"
assert_contains "$out" "usage: roost view" "view with no CMD prints usage"

out="$(TMUX_PANE="$agent" "$ROOST" view -n 2>&1)"; rc=$?
assert_eq "$rc" "2" "view -n with no argument exits 2"
assert_contains "$out" "roost view: -n needs a name" "view -n with no argument names the guard, not the generic unknown-flag error"

# An empty name would match every pane whose @roost-name was never set — that
# is, every pane a human opened by hand — and the replace step would kill the
# lot. Rejected outright.
out="$(TMUX_PANE="$agent" "$ROOST" view -n '' sleep 600 2>&1)"; rc=$?
assert_eq "$rc" "2" "view -n '' exits 2 rather than matching every unnamed pane"
assert_contains "$out" "non-empty name" "view -n '' says the name must be non-empty"

out="$(TMUX_PANE="$agent" "$ROOST" view -n "$(printf 'a\nb')" sleep 600 2>&1)"; rc=$?
assert_eq "$rc" "2" "view -n rejects a name containing a newline"
assert_contains "$out" "NAME may not contain a tab or newline" "view -n names the tab/newline guard"

# --- a pane, when there is room -------------------------------------------
before="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
active_before="$(T display-message -p -t "$w" '#{pane_id}')"
v1="$(TMUX_PANE="$agent" "$ROOST" view sleep 600 2>/dev/null)"
require_pane "$v1" "view (wide pane)"
assert_eq "$(T list-panes -t "$w" | wc -l | tr -d ' ')" "$((before + 1))" \
  "a wide caller gets a pane in its own window"
assert_eq "$(T display-message -p -t "$v1" '#{window_id}')" "$w" \
  "the view pane lands in the CALLER's window, not a new one"
assert_eq "$(T display-message -p -t "$w" '#{pane_id}')" "$active_before" \
  "view does not steal focus"
[ "$(T display-message -p -t "$v1" '#{pane_left}')" -gt "$(T display-message -p -t "$agent" '#{pane_left}')" ] \
  && assert_eq ok ok "the view pane opens to the RIGHT of the caller" \
  || assert_eq "" right "the view pane opens to the RIGHT of the caller"

# NAME defaults to `view`, and lands on the new pane the way split/spawn do.
assert_eq "$(T show-options -pqv -t "$v1" @roost-name)" "view" \
  "NAME defaults to 'view' and is set on the new pane"
assert_eq "$(T show-options -pqv -t "$agent" @roost-name)" "" \
  "view does not name the calling pane"

# --- replace, don't stack --------------------------------------------------
# THE REGRESSION THIS FILE EXISTS FOR. The caller is now ~99 columns wide,
# because v1 is holding the other half. If the width were read BEFORE the old
# view is killed, this second call would see 99 < 180 and walk off into a
# window. Measuring after the kill sees the restored 200 and splits again.
v2="$(TMUX_PANE="$agent" "$ROOST" view sleep 600 2>/dev/null)"
require_pane "$v2" "view (second call)"
alive "$v1"; rc=$?
assert_eq "$rc" "1" "a second view kills the first rather than stacking beside it"
assert_eq "$(named_count view)" "1" "exactly one pane is named 'view' after two calls"
assert_eq "$(T display-message -p -t "$v2" '#{window_id}')" "$w" \
  "the width is measured AFTER the old view is killed, so the second call still splits"
assert_eq "$(T list-panes -t "$w" | wc -l | tr -d ' ')" "$((before + 1))" \
  "the window pane count is unchanged by the replacement"

# A pane a HUMAN opened carries no @roost-name, and a pane under a different
# name is somebody else's view. Neither may be collateral.
hand="$(T split-window -h -d -P -F '#{pane_id}' -t "$agent")"
require_pane "$hand" "hand-opened pane"
other="$(TMUX_PANE="$agent" "$ROOST" split -n notes 2>/dev/null)"
require_pane "$other" "differently named pane"
v3="$(TMUX_PANE="$agent" "$ROOST" view -n view sleep 600 2>/dev/null)"
require_pane "$v3" "view (third call)"
alive "$hand"; assert_eq "$?" "0" "a pane opened by hand has no @roost-name and is not killed"
alive "$other"; assert_eq "$?" "0" "a pane under a different name is not killed"
alive "$v2"; assert_eq "$?" "1" "the previous same-named view is killed"
T kill-pane -t "$hand" 2>/dev/null || true
T kill-pane -t "$other" 2>/dev/null || true
T kill-pane -t "$v3" 2>/dev/null || true

# -n names the view, and two names coexist: they only replace their own.
a="$(TMUX_PANE="$agent" "$ROOST" view -n diff sleep 600 2>/dev/null)"
b="$(TMUX_PANE="$agent" "$ROOST" view -n plan sleep 600 2>/dev/null)"
require_pane "$a" "view -n diff"; require_pane "$b" "view -n plan"
assert_eq "$(T show-options -pqv -t "$b" @roost-name)" "plan" "view -n sets @roost-name"
alive "$a"; assert_eq "$?" "0" "a view under another name is left alone"
a2="$(TMUX_PANE="$agent" "$ROOST" view -n diff sleep 600 2>/dev/null)"
require_pane "$a2" "view -n diff (again)"
alive "$a"; assert_eq "$?" "1" "the same name replaces its own previous view"
alive "$b"; assert_eq "$?" "0" "...and still leaves the other name alone"
T kill-pane -t "$a2" 2>/dev/null || true
T kill-pane -t "$b" 2>/dev/null || true

# --- a window, when there is not room --------------------------------------
# ROOST_VIEW_MIN_COLS is the override, so a caller narrower than the threshold
# takes the window branch. Raising the threshold above the pane's real width is
# the same decision as shrinking the pane, without the resize race.
windows_before="$(T list-windows -a | wc -l | tr -d ' ')"
nv="$(TMUX_PANE="$agent" ROOST_VIEW_MIN_COLS=99999 "$ROOST" view -n narrow sleep 600 2>/dev/null)"
require_pane "$nv" "view (narrow caller)"
assert_eq "$(T list-windows -a | wc -l | tr -d ' ')" "$((windows_before + 1))" \
  "a narrow caller gets a WINDOW, not a pane"
[ "$(T display-message -p -t "$nv" '#{window_id}')" != "$w" ] \
  && assert_eq ok ok "the narrow-case view is not in the caller's window" \
  || assert_eq "$w" other "the narrow-case view is not in the caller's window"
assert_eq "$(T display-message -p -t "$nv" '#{window_name}')" "narrow" \
  "the new window carries NAME"
assert_eq "$(T show-options -pqv -t "$nv" @roost-name)" "narrow" \
  "the narrow-case pane carries @roost-name too"
assert_eq "$(T display-message -p -t "$w" '#{window_active}')" "1" \
  "opening a window does not steal focus from the caller's window"

# A second narrow call replaces the window view, and the window it emptied
# closes itself — so the count does not grow.
nv2="$(TMUX_PANE="$agent" ROOST_VIEW_MIN_COLS=99999 "$ROOST" view -n narrow sleep 600 2>/dev/null)"
require_pane "$nv2" "view (narrow, second call)"
alive "$nv"; assert_eq "$?" "1" "a second narrow view kills the first"
assert_eq "$(T list-windows -a | wc -l | tr -d ' ')" "$((windows_before + 1))" \
  "the window emptied by the kill closes itself, so windows do not accumulate"
T kill-pane -t "$nv2" 2>/dev/null || true

# The threshold is a number. A typo'd value must not silently mean 180.
out="$(TMUX_PANE="$agent" ROOST_VIEW_MIN_COLS=wide "$ROOST" view sleep 600 2>&1)"; rc=$?
assert_eq "$rc" "2" "a non-numeric ROOST_VIEW_MIN_COLS exits 2"
assert_contains "$out" "ROOST_VIEW_MIN_COLS must be a number" "...and says which variable is wrong"

# --- the directions --------------------------------------------------------
# The pane id is the stdout contract; the directions are for the human, on
# stderr. Check both halves separately so neither can be satisfied by the other.
outerr="$(TMUX_PANE="$agent" "$ROOST" view -n keys sleep 600 2>&1 >/dev/null)"
stdout_only="$(TMUX_PANE="$agent" "$ROOST" view -n keys sleep 600 2>/dev/null)"
assert_prefix "$stdout_only" "%" "stdout is the pane id alone"
assert_eq "$(printf '%s\n' "$stdout_only" | wc -l | tr -d ' ')" "1" "stdout is one line"

# The prefix is read LIVE. This server was started with -f /dev/null, so it is
# still on tmux's own default C-b — which is not roost's C-s, and so proves the
# value is read rather than hardcoded.
assert_contains "$outerr" "ctrl-b then l" "the pane directions render the live prefix as ctrl-<key>"
assert_contains "$outerr" "ctrl-b then h" "the pane directions say how to come back"

T set-option -g prefix C-a
outerr="$(TMUX_PANE="$agent" "$ROOST" view -n keys sleep 600 2>&1 >/dev/null)"
assert_contains "$outerr" "ctrl-a then l" "a rebound prefix changes the pane directions"

# A non-ctrl prefix is already how a human would say it, so it is printed as-is.
T set-option -g prefix M-x
outerr="$(TMUX_PANE="$agent" "$ROOST" view -n keys sleep 600 2>&1 >/dev/null)"
assert_contains "$outerr" "M-x then l" "a non-ctrl prefix is printed unchanged"

# The window case points at the switcher (prefix a) instead.
outerr="$(TMUX_PANE="$agent" ROOST_VIEW_MIN_COLS=99999 "$ROOST" view -n keys sleep 600 2>&1 >/dev/null)"
assert_contains "$outerr" "M-x then a" "the window directions point at the switcher"
assert_contains "$outerr" "named keys" "the window directions name the window"
T set-option -g prefix C-b

# --- help ------------------------------------------------------------------
# `roost help` reads this file's own header, so a missing entry there is a
# missing entry in the help.
assert_contains "$("$ROOST" help 2>&1)" "roost view" "roost help lists view"
