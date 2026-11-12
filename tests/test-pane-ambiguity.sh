#!/usr/bin/env bash
# #247 part 2: a literal live %N that is another live pane's @roost-was
# must never choose an agent, even without saving or an alias map. Exercise
# real verbs and their effects, including the split route outside target().
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
shape_test_setup; trap shape_test_teardown EXIT
export XDG_CONFIG_HOME="$SHAPE_TMP/config"
export ROOST_RECORD_DIR="$SHAPE_TMP/records"
ROOST="$PWD/bin/roost"
R() { env -u TMUX TMUX_PANE="${AMBIG_CALLER:-}" ROOST_SOCKET=roost "$ROOST" "$@"; }
TL set -g default-shell "$(command -v bash)"
live="$(TL new-session -d -P -F '#{pane_id}' -s fresh -n agents 'ENV= exec /bin/sh')"
other="$(TL new-window -d -P -F '#{pane_id}' -t '=fresh:' -n restored 'ENV= exec /bin/sh')"
TL set -p -t "$live" @roost-name 'current worker'
TL set -p -t "$other" @roost-name 'restored worker'
TL set -p -t "$other" @roost-was "$live"
boot="$(TL display -p '#{start_time}-#{pid}')"
record="$ROOST_RECORD_DIR/$boot/${live#%}"
mkdir -p "$record/replies"
printf '1\n' > "$record/schema"
printf '%s\n' "$SHAPE_SOCK" > "$record/socket"
printf 'KEPT-REPLY\n' > "$record/replies/000001"
live_addr="$(TL display -p -t "$live" '#{session_name}:#{window_index}.#{pane_index}')"
other_addr="$(TL display -p -t "$other" '#{session_name}:#{window_index}.#{pane_index}')"

refused() {
  local out rc before after
  before="$(TL list-panes -a -F '#{pane_id} #{window_layout} #{@agent_state} #{@roost-name}')"
  out="$(R "$@" 2>&1)"; rc=$?
  assert_eq "$rc" 2 "$*: collision exits 2"
  assert_contains "$out" "$live is ambiguous" "...reports ambiguity"
  assert_contains "$out" "$live ($live_addr current worker)" "...identifies current pane and name"
  assert_contains "$out" "$other ($other_addr restored worker)" "...identifies restored pane and name"
  assert_contains "$out" 'Use a name, or a session:window.pane target' "...offers an unambiguous address"
  case "$out" in *KEPT-REPLY*) rc=1 ;; *) rc=0 ;; esac
  assert_eq "$rc" 0 '...no reply content read out'
  after="$(TL list-panes -a -F '#{pane_id} #{window_layout} #{@agent_state} #{@roost-name}')"
  assert_eq "$after" "$before" "...no pane, layout, badge or name mutation"
  assert_eq "$(cat "$record/replies/000001" 2>/dev/null)" KEPT-REPLY "...kept reply untouched"
}

echo '== every explicit pane route refuses before acting, without an alias map =='
refused send --force "$live" 'echo AMBIGUOUS-DELIVERY'
TL capture -p -t "$live" | grep -q AMBIGUOUS-DELIVERY
assert_eq "$?" 1 'send delivered nothing to current pane'
TL capture -p -t "$other" | grep -q AMBIGUOUS-DELIVERY
assert_eq "$?" 1 'send delivered nothing to restored pane'
refused read "$live"
refused read --json "$live"
refused read --turn 1 "$live"
refused screen "$live"
refused wait-done "$live" 1
refused wait "$live" 1
refused answer --force "$live" --deny
refused revive --force "$live"
refused split -h -t "$live" 'sleep 600'
refused spawn relative -a -t "$live" 'sleep 600'
refused spawn relative -bt"$live" 'sleep 600'
refused split -t "$live_addr" -- -t "$live" 'sleep 600'
AMBIG_CALLER="$live" refused view -- -t "$live" 'sleep 600'
refused events --pane "$live"
refused forget "$live"
# Recreate the record so a red forget cannot hide a later action's effect.
mkdir -p "$record/replies"; printf 'KEPT-REPLY\n' > "$record/replies/000001"
refused close --force "$live"

echo '== saving and kept replies can both be off: pane options still decide =='
ROOST_SHAPE_DIR= ROOST_RECORD_DIR= R screen "$live" >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 2 'saving off: screen refuses'
assert_contains "$(cat "$SHAPE_TMP/err")" 'is ambiguous' 'saving off: reports the collision'
ROOST_SHAPE_DIR= ROOST_RECORD_DIR= R forget "$live" >"$SHAPE_TMP/out" 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 2 'records off: forget still refuses the ambiguous target'

echo '== explicit addresses and was: remain choices; no false ambiguity =='
# Self context is known, even when the caller's id also belonged to another
# agent before restore. View forwards a current address to its child split.
v="$(AMBIG_CALLER="$live" ROOST_VIEW_MIN_COLS=1 R view -n own-view sleep 600 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc" 0 'view uses implicit caller despite its historical collision'
assert_eq "$(TL display -p -t "$v" '#{window_id}')" "$(TL display -p -t "$live" '#{window_id}')" 'view splits beside its actual caller'
[ -z "$v" ] || TL kill-pane -t "$v"
v="$(AMBIG_CALLER="$live" R split sleep 600 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc" 0 'split without -t uses known caller context'
[ -z "$v" ] || TL kill-pane -t "$v"
v="$(R spawn command-data sh -c 'sleep 600' -- -t "$live" 2>"$SHAPE_TMP/err")"; rc=$?
assert_eq "$rc" 0 'spawn does not treat command arguments as pane targets'
[ -z "$v" ] || TL kill-pane -t "$v"
third="$(TL new-window -d -P -F '#{pane_id}' -t '=fresh:' -n third 'sleep 600')"
TL set -p -t "$third" @roost-was "$live"
out="$(R screen "$live" 2>&1)"; rc=$?
assert_eq "$rc" 2 'multiple historical matches refuse'
assert_contains "$out" "$other ($other_addr restored worker)" 'multiple matches: first candidate named'
assert_contains "$out" "$third (fresh:" 'multiple matches: additional candidate named'
TL kill-pane -t "$third"
# The red close may have killed the fixture; make the remaining checks name
# the restored pane, which is never the direct target above.
TL set -pu -t "$other" @roost-was
TL set -p -t "$other" @roost-was "$other"
R screen "$other" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 0 'same-pane @roost-was is not ambiguous'
TL set -pu -t "$other" @roost-was
TL set -g @roost-was "$live"
R screen "$live" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 0 'an inherited global option is not a pane restore stamp'
TL set -gu @roost-was
TL set -p -t "$other" @roost-was "$live"
R screen "$other_addr" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 0 'session:window.pane bypasses a bare-id collision'
R screen 'fresh:restored' >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 0 'window name selects the restored pane without bare-id ambiguity'
mkdir -p "$ROOST_SHAPE_DIR/roost/aliases"
printf '%s old-boot %s\n' "$live" "$other" > "$ROOST_SHAPE_DIR/roost/aliases/$boot"
R screen "was:$live" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$rc" 0 'explicit was: resolves the historical pane despite collision'
TL set -w -t "$other" remain-on-exit on
TL respawn-pane -k -t "$other" 'exit 0'
for i in {1..30}; do
  [ "$(TL display -p -t "$other" '#{pane_dead}')" = 1 ] && break
  sleep 0.1
done
R screen "$live" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
# A red close removed the current pane, so use the diagnostic as the check:
# it must not blame a dead restored pane, regardless of ordinary gone handling.
assert_eq "$(grep -c 'is ambiguous' "$SHAPE_TMP/err")" 0 'dead restored pane does not cause ambiguity'
assert_eq "$rc" 0 'current live pane remains addressable when the restored pane is dead'
TL kill-pane -t "$other"
R screen "$live" >/dev/null 2>"$SHAPE_TMP/err"; rc=$?
assert_eq "$(grep -c 'is ambiguous' "$SHAPE_TMP/err")" 0 'gone restored pane and stale map do not cause ambiguity'
assert_eq "$rc" 0 'current live pane remains addressable after the restored pane is gone'

canary_check
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
