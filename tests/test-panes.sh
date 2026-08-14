#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AMUX="$HERE/bin/amux"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_SOCKET="$sock"
# Load amux's pane-border format (@amux-pane-border) onto the test server so
# the named-pane border assertions below have something real to check.
T source-file "$HERE/tmux/amux.conf"

wait_for() { local t="$1" p="$2" n=20; while [ "$n" -gt 0 ]; do T capture-pane -p -t "$t" 2>/dev/null | grep -q "$p" && return 0; sleep 0.2; n=$((n-1)); done; return 1; }

w="$(T display-message -p '#{window_id}')"
agent="$(T display-message -p '#{pane_id}')"

# split adds a background pane to the current window, prints %N, no focus steal
before="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
active_before="$(T display-message -p -t "$w" '#{pane_id}')"
p="$(TMUX_PANE="$agent" "$AMUX" split)"
after="$(T list-panes -t "$w" | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "split adds a pane to the current window"
case "$p" in %*) assert_eq ok ok "split prints a stable pane id (%N)" ;; *) assert_eq "$p" "%..." "split prints a stable pane id (%N)" ;; esac
[ -n "$(T display-message -p -t "$p" '#{pane_id}')" ] \
  && assert_eq ok ok "split's target resolves to a live pane" || assert_eq "" live "split's target resolves to a live pane"
assert_eq "$(T display-message -p -t "$w" '#{pane_id}')" "$active_before" "split does not steal focus (active pane unchanged)"

# send/read work against the split pane's %N
"$AMUX" send "$p" "printf 'SPLIT-%s\n' OK"
wait_for "$p" 'SPLIT-OK' \
  && assert_eq ok ok "send/read reach a split pane by %N" || assert_eq no-exec executed "send/read reach a split pane by %N"

# CMD form runs and still prints a pane id
p2="$(TMUX_PANE="$agent" "$AMUX" split true)"
case "$p2" in %*) assert_eq ok ok "split CMD prints a pane id" ;; *) assert_eq "$p2" "%..." "split CMD prints a pane id" ;; esac

# guard: outside amux (no TMUX_PANE, no -t) exits 1
out="$(env -u TMUX_PANE "$AMUX" split 2>&1)"; rc=$?
assert_eq "$rc" "1" "split outside amux exits 1"
assert_contains "$out" "not inside an amux session" "split explains it's outside amux"

# layout: full-left agent + stacked-right via -h then -v -t <right>
w2="$(T new-window -P -F '#{window_id}')"
a2="$(T display-message -p -t "$w2" '#{pane_id}')"
r1="$(TMUX_PANE="$a2" "$AMUX" split -h)"
r2="$(TMUX_PANE="$a2" "$AMUX" split -v -t "$r1")"
assert_eq "$(T display-message -p -t "$a2" '#{pane_left}')" "0" "layout: agent pane on the left edge"
[ "$(T display-message -p -t "$r1" '#{pane_left}')" -gt 0 ] \
  && assert_eq ok ok "layout: right column is right of the agent" || assert_eq "" right "layout: right column is right of the agent"
[ "$(T display-message -p -t "$r2" '#{pane_top}')" -gt "$(T display-message -p -t "$r1" '#{pane_top}')" ] \
  && assert_eq ok ok "layout: right panes stack (r2 below r1)" || assert_eq "" stacked "layout: right panes stack (r2 below r1)"

# --- named panes: a stable label beats a churning process name ---
# #{pane_current_command} reports a version string for some agents, so a pane
# can carry an explicit @amux-name that every label site prefers.
base="$(T display-message -p '#{pane_id}')"
named="$(TMUX_PANE="$base" "$AMUX" split -n reviewer)"
assert_eq "$(T show-options -pqv -t "$named" @amux-name)" "reviewer" \
  "split -n sets @amux-name on the new pane"
assert_eq "$(T show-options -pqv -t "$base" @amux-name)" "" \
  "split -n does not touch the source pane"

# without -n the option stays unset, so the label falls back to the command
plain="$(TMUX_PANE="$base" "$AMUX" split)"
assert_eq "$(T show-options -pqv -t "$plain" @amux-name)" "" \
  "split without -n leaves @amux-name unset"

# a name with a space survives (it is a label, not a token)
spaced="$(TMUX_PANE="$base" "$AMUX" split -n 'code reviewer')"
assert_eq "$(T show-options -pqv -t "$spaced" @amux-name)" "code reviewer" \
  "a pane name may contain spaces"

# Fix 4: a name containing a tab or newline corrupts amux status (which emits
# one line PER PANE, so a `\n` splits one pane into two lines) and the
# switcher's tab-delimited awk rows (a `\t` shifts every field after it,
# producing a selectable row with empty session/window/pane key fields —
# selecting it would run `switch-client -t ""`, the hazard
# scripts/amux-switch's own comment warns about). Reject outright.
out="$(TMUX_PANE="$base" "$AMUX" split -n "$(printf 'a\nb')" 2>&1)"; rc=$?
assert_eq "$rc" "2" "split -n rejects a name containing a newline"
assert_contains "$out" "NAME may not contain a tab or newline" "split -n names the tab/newline guard"

out="$(TMUX_PANE="$base" "$AMUX" split -n "$(printf 'a\tb')" 2>&1)"; rc=$?
assert_eq "$rc" "2" "split -n rejects a name containing a tab"

out="$(TMUX_PANE="$base" "$AMUX" spawn "$(printf 'a\nb')" 2>&1)"; rc=$?
assert_eq "$rc" "2" "spawn rejects a name containing a newline"
assert_contains "$out" "NAME may not contain a tab or newline" "spawn names the tab/newline guard"

out="$(TMUX_PANE="$base" "$AMUX" spawn "$(printf 'a\tb')" 2>&1)"; rc=$?
assert_eq "$rc" "2" "spawn rejects a name containing a tab"

# `new` sets a window name from the same unvalidated user input and hits the
# identical corruption (a two-line amux status entry, a switcher row whose
# key fields shift empty). The guard fires before ensure_session/exec attach,
# so this returns instead of trying to attach a real terminal.
out="$(TMUX_PANE="$base" "$AMUX" new "$(printf 'a\nb')" notreal 2>&1)"; rc=$?
assert_eq "$rc" "2" "new rejects a name containing a newline"
assert_contains "$out" "NAME may not contain a tab or newline" "new names the tab/newline guard"

out="$(TMUX_PANE="$base" "$AMUX" new "$(printf 'a\tb')" notreal 2>&1)"; rc=$?
assert_eq "$rc" "2" "new rejects a name containing a tab"

# -n needs an argument. Before -n existed, an unrecognised flag already hit the
# generic `-*) ... exit 2` catch-all, so an exit-code-only assertion here would
# pass identically with or without the explicit guard; check the specific
# message too, so this test actually distinguishes the two code paths.
out="$(TMUX_PANE="$base" "$AMUX" split -n 2>&1)"; rc=$?
assert_eq "$rc" "2" "split -n with no argument exits 2"
assert_contains "$out" "amux split: -n needs a name" "split -n with no argument names the guard, not the generic unknown-flag error"

# spawn names its pane too, from the window name it already takes
sp="$(TMUX_PANE="$base" "$AMUX" spawn api-agent)"
assert_eq "$(T show-options -pqv -t "$sp" @amux-name)" "api-agent" \
  "spawn sets @amux-name from the window name"

# the border prefers the name over the command
border="$(T list-panes -a -F '#{pane_id}|#{E:@amux-pane-border}' | grep "^$named|" | cut -d'|' -f2)"
assert_contains "$border" "reviewer" "the pane border shows @amux-name when set"

# Fix 5 / CI coverage: the tab formats (window-status-format and its -current
# sibling) resolve @amux-name too — not just the border and `amux status`.
# Resolve the ACTUAL installed format option (not a hand-copied string) the
# same way test-window-glyph.sh does, so this is proven on whatever tmux CI
# runs (CI is on 3.4; this machine may be newer) rather than assumed from a
# one-off manual probe. Target the PANE itself, not the window: window-status
# formats read pane-scoped vars (like @amux-name) off whatever pane they're
# asked about, and `named` is a background split (-d, no focus steal), so
# it is not the window's active pane — targeting the window here would
# silently resolve a different (unnamed) pane's label instead.
wsfmt="$(T show-options -gqv window-status-format)"
assert_contains "$(T display-message -p -t "$named" "$wsfmt")" "reviewer" \
  "window-status-format resolves @amux-name for a named pane"
wscfmt="$(T show-options -gqv window-status-current-format)"
assert_contains "$(T display-message -p -t "$named" "$wscfmt")" "reviewer" \
  "window-status-current-format resolves @amux-name for a named pane"
# One list-panes call, one snapshot: the border and the current command must
# come from the same row. Reading them via two separate tmux calls is a race —
# a pane whose shell is still starting can report a different
# #{pane_current_command} between the two reads and flake this assertion.
plainrow="$(T list-panes -a -F '#{pane_id}|#{pane_current_command}|#{E:@amux-pane-border}' | grep "^$plain|")"
plaincmd="$(printf '%s' "$plainrow" | cut -d'|' -f2)"
plainborder="$(printf '%s' "$plainrow" | cut -d'|' -f3)"
assert_contains "$plainborder" "$plaincmd" \
  "an unnamed pane's border falls back to the command"

# status prefers the name too
assert_contains "$("$AMUX" status)" "reviewer" "amux status shows @amux-name"

# regression: a pane named literally "0" must still show "0", not fall back to
# the process name. tmux's #{?...} format truthiness treats the string "0" as
# false, so `#{?@amux-name,#{@amux-name},#{pane_current_command}}` used to
# render the command instead of the name for this one value.
zero="$(TMUX_PANE="$base" "$AMUX" split -n 0)"
assert_eq "$(T show-options -pqv -t "$zero" @amux-name)" "0" \
  "split -n 0 sets @amux-name to the literal string 0"
zeroborder="$(T list-panes -a -F '#{pane_id}|#{E:@amux-pane-border}' | grep "^$zero|" | cut -d'|' -f2)"
assert_contains "$zeroborder" "$zero 0" \
  "the pane border shows a pane named 0 as 0, not the process name"
zerostatus="$(TMUX_PANE="$base" "$AMUX" status | grep "^    $zero ")"
assert_contains "$zerostatus" "/0 " "amux status shows a pane named 0 as 0, not the process name"
