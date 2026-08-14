#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AMUX="$HERE/bin/amux"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
export AMUX_SOCKET="$sock"   # bin/amux talks to the isolated test server (path → -S)

# a shell window to receive input; capture its canonical target
recv="$(T new-window -P -F '#{session_name}:#{window_index}' -n recv)"

# Poll the pane for a pattern (up to ~4s) instead of a fixed sleep — the receiving
# shell's execution+render can lag on a loaded machine, which would flake a
# fixed `sleep 1`.
wait_for() { # wait_for TARGET PATTERN
  local tgt="$1" pat="$2" n=20
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$tgt" 2>/dev/null | grep -q "$pat" && return 0
    sleep 0.2; n=$((n - 1))
  done
  return 1
}

# send reliability: a two-step submit must actually EXECUTE the command.
# "MARK-DONE" (contiguous) can only appear from execution, not from the typed line.
"$AMUX" send "$recv" "printf 'MARK-%s\n' DONE"
wait_for "$recv" 'MARK-DONE' \
  && assert_eq ok ok "send delivers text AND submits (two-step Enter works)" \
  || assert_eq no-exec executed "send delivers text AND submits (two-step Enter works)"

# literal text: a message containing the word Enter is typed as text, executed once
"$AMUX" send "$recv" "echo hi-Enter-bye"
wait_for "$recv" 'hi-Enter-bye' \
  && assert_eq ok ok "message text is literal (the word Enter is not a keypress)" \
  || assert_eq no-exec executed "message text is literal (the word Enter is not a keypress)"

# validation: a bogus target fails loudly (exit 2), delivers nothing
out="$("$AMUX" send "nope:99" "x" 2>&1)"; rc=$?
assert_eq "$rc" "2" "send to a bad target exits 2"
assert_contains "$out" "no such target" "send to a bad target explains why"

# validation: a DEAD pane (remain-on-exit) fails loudly too, delivers nothing.
# The bug this guards: with remain-on-exit on, a pane whose command has
# already exited still resolves #{window_id} fine — the "no such target"
# check alone lets it through — and send-keys against it then silently
# no-ops. The frozen screen never gains the message, so `pending()` sees
# before==cur with no match and reports a clean send that delivered nothing.
# Measured against the pre-fix binary (commit 89a3975): `amux send` exits 0.
T set-option -g remain-on-exit on
dead="$(T new-window -d -PF '#{pane_id}' true)"
n=20
while [ "$n" -gt 0 ]; do
  [ "$(T display-message -p -t "$dead" '#{pane_dead}' 2>/dev/null)" = "1" ] && break
  sleep 0.2; n=$((n - 1))
done
out="$("$AMUX" send "$dead" "x" 2>&1)"; rc=$?
assert_eq "$rc" "2" "send to a dead pane exits 2, not a false 0"
assert_contains "$out" "dead pane" "send to a dead pane explains why"
T set-option -gu remain-on-exit 2>/dev/null || true

# a non-numeric @amux-send-enter-delay must NOT break send — it falls back to 0.3
# and still submits (no abort with the text left unsent).
T set-option -g @amux-send-enter-delay "not-a-number"
"$AMUX" send "$recv" "printf 'DELAY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a garbage @amux-send-enter-delay (exit 0)"
wait_for "$recv" 'DELAY-OK' \
  && assert_eq ok ok "send still submits despite a garbage delay value" \
  || assert_eq no-exec executed "send still submits despite a garbage delay value"
T set-option -gu @amux-send-enter-delay 2>/dev/null || true

# a dot-heavy delay (e.g. "1.2.3") slips a char-class guard but must NOT leave the
# prompt half-delivered — it falls back to 0.3 and the sleep can't abort.
T set-option -g @amux-send-enter-delay "1.2.3"
"$AMUX" send "$recv" "printf 'DOT-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a dot-heavy delay value (exit 0)"
wait_for "$recv" 'DOT-OK' \
  && assert_eq ok ok "send still submits with a dot-heavy delay value" \
  || assert_eq no-exec executed "send still submits with a dot-heavy delay value"
T set-option -gu @amux-send-enter-delay 2>/dev/null || true

# --- whoami ---
pane="$(T display-message -p -t "$recv" '#{pane_id}')"
me="$(TMUX_PANE="$pane" "$AMUX" whoami)"
assert_eq "$me" "$pane" "whoami prints the caller's pane id (%N)"

out="$(env -u TMUX_PANE "$AMUX" whoami 2>&1)"; rc=$?
assert_eq "$rc" "1" "whoami outside an amux pane exits 1"
assert_contains "$out" "not inside an amux session" "whoami explains it's outside amux"

# --- spawn ---
active_win() { T list-windows -F '#{window_active} #{window_index}' | awk '$1==1{print $2}'; }
before="$(T list-windows | wc -l | tr -d ' ')"
active_before="$(active_win)"
new="$(TMUX_PANE="$pane" "$AMUX" spawn helper)"
after="$(T list-windows | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "spawn creates a new window"
# spawn must NOT steal focus — the session's active window is unchanged (-d).
assert_eq "$(active_win)" "$active_before" "spawn creates in the background (does not switch the active window)"
assert_eq "$(T display-message -p -t "$new" '#{window_name}')" "helper" "spawn names the window"

# regression (Fix 1): spawn sets @amux-name to the SAME string it already used
# to name the window, so every window-scoped label site (status, the tab
# formats, the switcher) must suppress the "·LABEL"/"/LABEL" suffix when it
# would just echo the window name back ("helper/helper"). The pre-fix bug
# rendered exactly that duplicate; assert_contains "reviewer" elsewhere does
# NOT catch this because that fixture names a pane differently from its window.
statusline="$("$AMUX" status | grep "^    $new ")"
case "$statusline" in
  *"helper/helper"*) assert_eq "helper/helper" "helper" "spawn: status does not duplicate the label (no window/window echo)" ;;
  *) assert_eq ok ok "spawn: status does not duplicate the label (no window/window echo)" ;;
esac
assert_contains "$statusline" " helper " "spawn: status still shows the (single) label"

# same check against the REAL rendered tab formats, not just the status list —
# resolve window-status-format/-current-format the way tmux itself would.
# amux status alone doesn't load tmux/amux.conf onto the test server (it only
# sets pane options), so the tab formats source it here before being resolved.
T source-file "$HERE/tmux/amux.conf"
tab="$(T display-message -p -t "$new" '#{E:window-status-format}')"
tabcur="$(T display-message -p -t "$new" '#{E:window-status-current-format}')"
case "$tab$tabcur" in
  *"helper·helper"*) assert_eq "helper·helper" "helper" "spawn: window-status formats do not duplicate the label" ;;
  *) assert_eq ok ok "spawn: window-status formats do not duplicate the label" ;;
esac
assert_contains "$tab" "helper" "spawn: window-status-format still shows the (single) label"

# and the switcher row
switchrow="$(AMUX_SWITCH_SOCK="$sock" AMUX_SWITCH_DUMP=1 "$HERE/scripts/amux-switch" | awk -F'\t' -v p="$new" '$3==p')"
case "$switchrow" in
  *"helper·helper"*) assert_eq "helper·helper" "helper" "spawn: switcher row does not duplicate the label" ;;
  *) assert_eq ok ok "spawn: switcher row does not duplicate the label" ;;
esac
assert_contains "$switchrow" "helper" "spawn: switcher row still shows the (single) label"

# the printed target resolves (proves format + that spawn returned, i.e. did not attach)
case "$new" in %*) assert_eq ok ok "spawn prints a stable pane id (%N)" ;; *) assert_eq "$new" "%..." "spawn prints a stable pane id (%N)" ;; esac
[ -n "$(T display-message -p -t "$new" '#{pane_id}')" ] \
  && assert_eq ok ok "spawn's printed target resolves to a live pane" \
  || assert_eq "" live "spawn's printed target resolves to a live pane"

# spawn with a CMD runs it in the new window
new2="$(TMUX_PANE="$pane" "$AMUX" spawn helper2 true)"
assert_contains "$new2" "%" "spawn NAME CMD prints a target"

# regression: a short-lived CMD's pane can be reaped by tmux before the
# subsequent `set-option @amux-name` runs. Under `set -euo pipefail` that
# failing set-option used to abort the whole `spawn` before its `printf`, so
# spawn returned nothing and exited 1 for a window that was actually created.
# One run passing is not proof (the race doesn't always land) — repeat it.
spawn_fail=0
for i in 1 2 3 4 5 6 7 8; do
  out="$(TMUX_PANE="$pane" "$AMUX" spawn "quickie$i" true 2>&1)"; rc=$?
  case "$out" in
    %*) : ;;
    *) spawn_fail=$((spawn_fail + 1)) ;;
  esac
  [ "$rc" -eq 0 ] || spawn_fail=$((spawn_fail + 1))
done
assert_eq "$spawn_fail" "0" "spawn NAME CMD returns a %N and exits 0 every time, even when CMD exits instantly"

# --- switcher target column (unit-check the row format; fzf needs a tty) ---
# fields: sid \t wid \t state \t since \t name \t cmd \t path \t glyph \t idleglyph \t %N
row="$(printf '$0\t@1\tidle\t\tapi\tzsh\tapi\t💤\t💤\t%%7\n')"
line="$(printf '%s' "$row" | awk -F'\t' -v now=100 '
  { st=$3; since=$4; el=(since==""?0:now-since); m=int(el/60);
    dot=($8!=""?$8:($9!=""?$9:"💤")); tgt=$10;
    printf "%s %-8s %3dm  %-14s %s  (%s/%s)\n", dot, st, m, tgt, $5, $6, $7 }')"
assert_contains "$line" "%7" "switcher row shows the %N send-target"
assert_contains "$line" "api" "switcher row still shows the window name"

# --- skill integrity: it must reference only real amux subcommands ---
# Check each `amux <cmd>` the skill names is a real subcommand, by word-matching
# it in bin/amux (matches its dispatch branch and/or the usage synopsis). This
# sidesteps dispatch-syntax quirks like `wait-done|wait)`.
SKILL="$HERE/skills/amux/SKILL.md"
[ -f "$SKILL" ] && assert_eq ok ok "skills/amux/SKILL.md exists" || assert_eq "" exists "skills/amux/SKILL.md exists"
for cmd in whoami spawn split send wait-done read status; do
  if grep -q "amux $cmd" "$SKILL" 2>/dev/null && grep -qw "$cmd" "$HERE/bin/amux" 2>/dev/null; then
    assert_eq ok ok "skill uses a real subcommand: amux $cmd"
  else
    assert_eq "" real "skill uses a real subcommand: amux $cmd"
  fi
done

# --- stable-id targets: send/read accept %N (pane) and @N (window) ---
recvpane="$(T display-message -p -t "$recv" '#{pane_id}')"   # %N
"$AMUX" send "$recvpane" "printf 'PID-%s\n' OK"
wait_for "$recvpane" 'PID-OK' \
  && assert_eq ok ok "send routes a %N pane-id target" \
  || assert_eq no-exec executed "send routes a %N pane-id target"
"$AMUX" read "$recvpane" 5 | grep -q 'PID-OK' \
  && assert_eq ok ok "read routes a %N pane-id target" \
  || assert_eq "" read "read routes a %N pane-id target"
recvwin="$(T display-message -p -t "$recv" '#{window_id}')"  # @N
"$AMUX" send "$recvwin" "printf 'WID-%s\n' OK"
wait_for "$recvwin" 'WID-OK' \
  && assert_eq ok ok "send routes an @N window-id target" \
  || assert_eq no-exec executed "send routes an @N window-id target"

# status leads each window row with the stable %N target
"$AMUX" status | grep -qE '%[0-9]' \
  && assert_eq ok ok "amux status shows a stable %N target" \
  || assert_eq "" pane-id "amux status shows a stable %N target"

# --- wait-done is pane-precise ---
# The regression this guards: pane options are invisible to `show-options -wqv`,
# which returns empty — so a window-scoped read reports every agent "done".
wpane="$(T display-message -p -t "$recv" '#{pane_id}')"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$wpane")"
T set-option -p -t "$sib" @agent_state working

# the busy pane blocks; a 1s timeout must fail rather than return success
"$AMUX" wait-done "$sib" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "wait-done on a working pane times out (does not read window scope)"

# its sibling is not an agent, so it is already done
"$AMUX" wait-done "$wpane" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a non-agent pane returns immediately"

# a window target aggregates: one working pane keeps the whole window busy
wid="$(T display-message -p -t "$recv" '#{window_id}')"
"$AMUX" wait-done "$wid" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "wait-done on a window waits for every agent pane"

# once that pane finishes, the window target returns
T set-option -p -t "$sib" @agent_state done
"$AMUX" wait-done "$wid" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a window returns once all agent panes are done"

# a window with no agents at all returns immediately
empty="$(T new-window -d -PF '#{window_id}')"
"$AMUX" wait-done "$empty" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a window with no agents returns immediately"

# --- status lists panes ---
T set-option -p -t "$sib" @agent_state blocked
out="$("$AMUX" status)"
assert_contains "$out" "$sib" "status lists the helper pane by its %N"
assert_contains "$out" "blocked" "status shows each pane's own state"

# --- send verifies its submit ---
# The failure this guards: a cold TUI swallows the Enter, the text sits in the
# input box, and send exits 0 anyway — so a caller waits forever on a message
# that was never delivered.

# a normal shell submits on the first Enter and still exits 0
"$AMUX" send "$recv" "printf 'VERIFY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send exits 0 when the text submits"
wait_for "$recv" 'VERIFY-OK' \
  && assert_eq ok ok "send still delivers normally" \
  || assert_eq no-exec executed "send still delivers normally"

# a garbage retry count falls back to the default rather than aborting
T set-option -g @amux-send-retries "not-a-number"
"$AMUX" send "$recv" "printf 'RETRY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a garbage @amux-send-retries"
wait_for "$recv" 'RETRY-OK' \
  && assert_eq ok ok "send still submits with a garbage retry count" \
  || assert_eq no-exec executed "send still submits with a garbage retry count"
T set-option -gu @amux-send-retries 2>/dev/null || true

# zero retries is honoured (one Enter, no verification loop) and still works
T set-option -g @amux-send-retries "0"
"$AMUX" send "$recv" "printf 'ZERO-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send with zero retries exits 0"
T set-option -gu @amux-send-retries 2>/dev/null || true

# an empty message is a legitimate bare Enter, not "still pending" forever.
# The bug this guards: `case "$last" in *""*)` collapses to `*)`, which
# matches ANY pane content, so a naive pending() would call an empty send
# "still pending" forever and fire every retry (4 Enters instead of 1) before
# exiting 1 for a message that had nothing to submit in the first place.
# Prove the exact count with a reader that stamps one countable line per
# Enter it receives — not just that "an" Enter arrived, but exactly one.
counter="$(T new-window -P -F '#{pane_id}' -n counter "sh $HERE/tests/fixtures/count-enters.sh")"
"$AMUX" send "$counter" ""; rc=$?
assert_eq "$rc" "0" "send with an empty message exits 0"
wait_for "$counter" 'ENTER-1' \
  && assert_eq ok ok "send with an empty message delivers a bare Enter" \
  || assert_eq no-exec executed "send with an empty message delivers a bare Enter"
sleep 0.5
out="$(T capture-pane -p -t "$counter")"
case "$out" in
  *ENTER-2*) assert_eq extra-enter none "send with an empty message fires exactly one Enter (no ENTER-2)" ;;
  *)         assert_eq ok ok "send with an empty message fires exactly one Enter (no ENTER-2)" ;;
esac

# `amux send TARGET` with no text argument at all (not even "") behaves the
# same way — raw="${2:?...}" only requires the target, so this is reachable.
"$AMUX" send "$counter"; rc=$?
assert_eq "$rc" "0" "send with no text argument at all exits 0"
wait_for "$counter" 'ENTER-2' \
  && assert_eq ok ok "send with no text argument delivers exactly one more bare Enter" \
  || assert_eq no-exec executed "send with no text argument delivers exactly one more bare Enter"
sleep 0.5
out2="$(T capture-pane -p -t "$counter")"
case "$out2" in
  *ENTER-3*) assert_eq extra-enter none "send with no text argument fires exactly one Enter (no ENTER-3)" ;;
  *)         assert_eq ok ok "send with no text argument fires exactly one Enter (no ENTER-3)" ;;
esac

# a genuinely swallowed first Enter: a fixture that echoes typed text (like a
# TUI redrawing its input box) but silently drops exactly the first Enter it
# receives, leaving the text sitting unsubmitted — the live bug this task
# fixes, reproduced deterministically instead of asserted by option-plumbing
# alone. Its confirmation marker never contains the sent text, so a stuck
# input line can't be mistaken for delivery.
if command -v python3 >/dev/null 2>&1; then
  swallow="$(T new-window -P -F '#{pane_id}' -n swallow "python3 -u $HERE/tests/fixtures/swallow-first-enter.py")"
  "$AMUX" send "$swallow" "hello world"; rc=$?
  assert_eq "$rc" "0" "send recovers from a genuinely swallowed first Enter (exit 0)"
  wait_for "$swallow" 'SUBMITTED-OK' \
    && assert_eq ok ok "send recovers from a genuinely swallowed first Enter (delivered)" \
    || assert_eq no-exec executed "send recovers from a genuinely swallowed first Enter (delivered)"
else
  assert_eq ok ok "swallowed-Enter recovery test skipped (no python3)"
fi
