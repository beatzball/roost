#!/usr/bin/env bash
# #247 part 2: a literal live %N that is another live pane's @roost-was
# must never choose an agent, even without saving or an alias map. Exercise
# real verbs and their effects, including the split route outside target().
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
. tests/lib-shape.sh
# Setup can exit after starting its server; arm teardown before it can fail.
trap shape_test_teardown EXIT
shape_test_setup
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
  assert_contains "$out" "${ambig_raw:-$live} is ambiguous" "...reports ambiguity"
  assert_contains "$out" "$live ($live_addr current worker)" "...identifies current pane and name"
  assert_contains "$out" "$other ($other_addr restored worker)" "...identifies restored pane and name"
  assert_contains "$out" 'Use a name, or a session:window.pane target' "...offers an unambiguous address"
  case "$out" in *KEPT-REPLY*) rc=1 ;; *) rc=0 ;; esac
  assert_eq "$rc" 0 '...no reply content read out'
  after="$(TL list-panes -a -F '#{pane_id} #{window_layout} #{@agent_state} #{@roost-name}')"
  assert_eq "$after" "$before" "...no pane, layout, badge or name mutation"
  assert_eq "$(cat "$record/replies/000001" 2>/dev/null)" KEPT-REPLY "...kept reply untouched"
}

echo '== tmux numeric aliases must not bypass the same shared check =='
alias_cases() {
  local live="$1" other="$2" live_addr other_addr record alias marker seq=0
  local ambig_raw before_ids id v out rc got
  TL set -p -t "$live" @roost-name 'current worker'
  TL set -p -t "$other" @roost-name 'restored worker'
  TL set -p -t "$other" @roost-was "$live"
  TL set -p -t "$live" @roost-reply KEPT-REPLY
  live_addr="$(TL display -p -t "$live" '#{session_name}:#{window_index}.#{pane_index}')"
  other_addr="$(TL display -p -t "$other" '#{session_name}:#{window_index}.#{pane_index}')"
  record="$ROOST_RECORD_DIR/$boot/${live#%}"
  mkdir -p "$record/replies"
  printf '1\n' > "$record/schema"
  printf 'KEPT-REPLY\n' > "$record/replies/000001"
  # A rejected split must leave the fixture intact. On the red run it really
  # creates a pane; remove only those extra panes so later aliases still have
  # room to exercise a successful tmux split rather than a size-limit error.
  alias_refused() {
    local before_ids id
    before_ids=" $(TL list-panes -a -F '#{pane_id}' | tr '\n' ' ') "
    refused "$@"
    for id in $(TL list-panes -a -F '#{pane_id}'); do
      case "$before_ids" in *" $id "*) ;; *) TL kill-pane -t "$id" ;; esac
    done
  }
  for alias in "%00${live#%}" "%+${live#%}" "% ${live#%}"; do
    assert_eq "$(TL display -p -t "$alias" '#{pane_id}')" "$live" "(control) tmux accepts '$alias' as $live"
    ambig_raw="$alias"; seq=$((seq+1)); marker="ALIAS-DELIVERY-${live#%}-$seq"
    alias_refused send --force "$alias" "echo $marker"
    TL capture -p -t "$live" | grep -qF "$marker"; assert_eq "$?" 1 "'$alias': nothing delivered to current pane"
    TL capture -p -t "$other" | grep -qF "$marker"; assert_eq "$?" 1 "'$alias': nothing delivered to restored pane"
    alias_refused read "$alias"
    alias_refused split -h -t "$alias" 'sleep 600'
    alias_refused spawn relative-alias -a -t "$alias" 'sleep 600'
    alias_refused split -t "$live_addr" -- -t "$alias" 'sleep 600'
    AMBIG_CALLER="$live" alias_refused view -- -t "$alias" 'sleep 600'
  done
  # Canonicalization belongs only to the guard: accepted unambiguous aliases
  # still work, and JSON still reports the target exactly as the user typed it.
  TL set -pu -t "$other" @roost-was
  for alias in "%00${live#%}" "%+${live#%}" "% ${live#%}"; do
    out="$(R read --json "$alias" 2>"$SHAPE_TMP/err")"; rc=$?
    assert_eq "$rc" 0 "unambiguous '$alias': read --json succeeds"
    got="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["target"] == sys.argv[1] and d["pane"] == sys.argv[2] and d["text"] == "KEPT-REPLY")' "$alias" "$live")"
    assert_eq "$got" True "unambiguous '$alias': typed JSON target, canonical pane and reply preserved"
    v="$(R split -h -t "$alias" 'sleep 600' 2>"$SHAPE_TMP/err")"; rc=$?
    assert_eq "$rc" 0 "unambiguous '$alias': split succeeds"
    assert_eq "$(TL display -p -t "$v" '#{window_id}')" "$(TL display -p -t "$live" '#{window_id}')" "unambiguous '$alias': split reaches the correct window"
    [ -z "$v" ] || TL kill-pane -t "$v"
  done
}
zero_other="$(TL new-window -d -P -F '#{pane_id}' -t '=fresh:' -n zero-restored 'ENV= exec /bin/sh')"
alias_cases '%0' "$zero_other"
TL kill-pane -t "$zero_other"
# Use an id containing decimal 8 or 9: shell octal arithmetic would reject a
# padded spelling such as %008, even though tmux itself accepts it.
while :; do
  decimal="$(TL new-window -d -P -F '#{pane_id}' -t '=fresh:' -n decimal 'ENV= exec /bin/sh')"
  require_pane "$decimal" 'numeric alias fixture'
  case "$decimal" in *8|*9) break ;; *) TL kill-pane -t "$decimal" ;; esac
done
decimal_other="$(TL new-window -d -P -F '#{pane_id}' -t '=fresh:' -n decimal-restored 'ENV= exec /bin/sh')"
alias_cases "$decimal" "$decimal_other"
TL kill-pane -t "$decimal_other"; TL kill-pane -t "$decimal"

echo '== qualified percent-prefixed addresses choose the current pane explicitly =='
qualified_cases() {
  local live other live_addr other_addr record raw out rc got i ambig_raw
  live="$(TL new-session -d -P -F '#{pane_id}' -s '%scope' -n '%window' 'printf "QUALIFIED-SCREEN\n"; ENV= exec /bin/sh')"
  require_pane "$live" 'qualified session fixture'
  other="$(TL new-window -d -P -F '#{pane_id}' -t '=%scope:' -n restored 'ENV= exec /bin/sh')"
  require_pane "$other" 'qualified session restored candidate'
  TL set -p -t "$live" @roost-name 'current worker'
  TL set -p -t "$other" @roost-name 'restored worker'
  TL set -p -t "$other" @roost-was "$live"
  TL set -p -t "$live" @roost-reply QUALIFIED-REPLY
  TL set -p -t "$other" @roost-reply OTHER-REPLY
  live_addr="$(TL display -p -t "$live" '#{session_name}:#{window_index}.#{pane_index}')"
  other_addr="$(TL display -p -t "$other" '#{session_name}:#{window_index}.#{pane_index}')"
  record="$ROOST_RECORD_DIR/$boot/${live#%}"
  mkdir -p "$record/replies"; printf 'KEPT-REPLY\n' > "$record/replies/000001"
  # A colon selects a session/window; a dot can select a named window's pane
  # without a session prefix. Both remain explicit current addresses even
  # when that session or window name begins with the pane-id sigil.
  for i in {1..30}; do
    TL capture -p -t "$live" | grep -qF QUALIFIED-SCREEN && break
    sleep 0.1
  done
  for raw in "$live_addr" '%scope:0' '%scope:.0' '%window.0'; do
    assert_eq "$(TL display -p -t "$raw" '#{pane_id}')" "$live" "(control) qualified '$raw' selects the current pane"
    out="$(R read "$raw" 2>"$SHAPE_TMP/err")"; rc=$?
    assert_eq "$rc|$out" '0|QUALIFIED-REPLY' "qualified '$raw': read reaches the chosen pane"
    out="$(R screen "$raw" 2>"$SHAPE_TMP/err")"; rc=$?
    assert_eq "$rc" 0 "qualified '$raw': screen succeeds despite the bare-id collision"
    assert_contains "$out" QUALIFIED-SCREEN "qualified '$raw': screen belongs to the chosen pane"
    out="$(R read --json "$raw" 2>"$SHAPE_TMP/err")"; rc=$?
    assert_eq "$rc" 0 "qualified '$raw': read --json succeeds"
    got="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["target"] == sys.argv[1] and d["pane"] == sys.argv[2] and d["text"] == "QUALIFIED-REPLY")' "$raw" "$live")"
    assert_eq "$got" True "qualified '$raw': JSON preserves typed target and selected pane"
  done
  for raw in "$live" "%00${live#%}" "%+${live#%}" "% ${live#%}"; do
    ambig_raw="$raw"; refused read "$raw"
  done
  TL kill-session -t '=%scope'
}
qualified_cases

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
