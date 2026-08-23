#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_SOCKET="$sock"   # bin/roost talks to the isolated test server (path → -S)

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
"$ROOST" send "$recv" "printf 'MARK-%s\n' DONE"
wait_for "$recv" 'MARK-DONE' \
  && assert_eq ok ok "send delivers text AND submits (two-step Enter works)" \
  || assert_eq no-exec executed "send delivers text AND submits (two-step Enter works)"

# literal text: a message containing the word Enter is typed as text, executed once
"$ROOST" send "$recv" "echo hi-Enter-bye"
wait_for "$recv" 'hi-Enter-bye' \
  && assert_eq ok ok "message text is literal (the word Enter is not a keypress)" \
  || assert_eq no-exec executed "message text is literal (the word Enter is not a keypress)"

# validation: a bogus target fails loudly (exit 2), delivers nothing
out="$("$ROOST" send "nope:99" "x" 2>&1)"; rc=$?
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
out="$("$ROOST" send "$dead" "x" 2>&1)"; rc=$?
assert_eq "$rc" "2" "send to a dead pane exits 2, not a false 0"
assert_contains "$out" "dead pane" "send to a dead pane explains why"
T set-option -gu remain-on-exit 2>/dev/null || true

# --- blocked target ------------------------------------------------------
#
# A blocked pane is showing a permission dialog. send types text, then presses
# Enter; against a dialog the text lands IN the dialog and the Enter activates
# whatever option is highlighted -- so one agent driving another could answer a
# prompt that existed to ask a human. The old behaviour was a clean exit 0,
# because the dialog consumes the text and the submit verification is satisfied.
recvpane="$(T display-message -p -t "$recv" '#{pane_id}')"
T set-option -p -t "$recvpane" @agent_state blocked

out="$("$ROOST" send "$recv" "echo SHOULD-NOT-RUN" 2>&1)"; rc=$?
assert_eq "$rc" "3" "send to a blocked pane exits 3 (not a false 0)"
assert_contains "$out" "permission dialog" "send to a blocked pane explains why"
# Exit 3 is distinct from 2 on purpose: the target is RIGHT and retrying later
# is correct, whereas 2 means pick a different target.
assert_eq "$("$ROOST" send "nope:99" x >/dev/null 2>&1; echo $?)" "2" \
  "a bad target still exits 2, so the caller can tell the two apart"

# refusing is only defensible if it delivered nothing at all
sleep 0.5
T capture-pane -p -t "$recv" 2>/dev/null | grep -q 'SHOULD-NOT-RUN' \
  && assert_eq delivered nothing "a refused send types nothing into the pane" \
  || assert_eq nothing nothing "a refused send types nothing into the pane"

# --force is the escape hatch: same target, same state, now it goes through
"$ROOST" send --force "$recv" "printf 'FORCED-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send --force overrides the blocked guard"
wait_for "$recv" 'FORCED-OK' \
  && assert_eq ok ok "send --force still delivers and submits" \
  || assert_eq no-exec executed "send --force still delivers and submits"

# --force must not be mistaken for the target
out="$("$ROOST" send --force "nope:99" x 2>&1)"; rc=$?
assert_eq "$rc" "2" "send --force still validates the target after it"

T set-option -pu -t "$recvpane" @agent_state 2>/dev/null || true

# every other state is fine to send into -- only `blocked` means a dialog.
# Without this the guard could silently widen and break normal fleet driving.
for st in working done error idle; do
  T set-option -p -t "$recvpane" @agent_state "$st"
  "$ROOST" send "$recv" "printf 'ST-%s\n' $st" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "send into a '$st' pane is allowed"
done
T set-option -pu -t "$recvpane" @agent_state 2>/dev/null || true

# an agent that has never reported has NO @agent_state at all; an empty value
# must read as "not blocked", not trip the guard.
"$ROOST" send "$recv" "printf 'UNSET-%s\n' OK" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "send into a pane with no reported state is allowed"

# a non-numeric @roost-send-enter-delay must NOT break send — it falls back to 0.3
# and still submits (no abort with the text left unsent).
T set-option -g @roost-send-enter-delay "not-a-number"
"$ROOST" send "$recv" "printf 'DELAY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a garbage @roost-send-enter-delay (exit 0)"
wait_for "$recv" 'DELAY-OK' \
  && assert_eq ok ok "send still submits despite a garbage delay value" \
  || assert_eq no-exec executed "send still submits despite a garbage delay value"
T set-option -gu @roost-send-enter-delay 2>/dev/null || true

# a dot-heavy delay (e.g. "1.2.3") slips a char-class guard but must NOT leave the
# prompt half-delivered — it falls back to 0.3 and the sleep can't abort.
T set-option -g @roost-send-enter-delay "1.2.3"
"$ROOST" send "$recv" "printf 'DOT-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a dot-heavy delay value (exit 0)"
wait_for "$recv" 'DOT-OK' \
  && assert_eq ok ok "send still submits with a dot-heavy delay value" \
  || assert_eq no-exec executed "send still submits with a dot-heavy delay value"
T set-option -gu @roost-send-enter-delay 2>/dev/null || true

# --- whoami ---
pane="$(T display-message -p -t "$recv" '#{pane_id}')"
me="$(TMUX_PANE="$pane" "$ROOST" whoami)"
assert_eq "$me" "$pane" "whoami prints the caller's pane id (%N)"

out="$(env -u TMUX_PANE "$ROOST" whoami 2>&1)"; rc=$?
assert_eq "$rc" "1" "whoami outside a roost pane exits 1"
assert_contains "$out" "not inside a roost session" "whoami explains it's outside roost"

# --- spawn ---
active_win() { T list-windows -F '#{window_active} #{window_index}' | awk '$1==1{print $2}'; }
before="$(T list-windows | wc -l | tr -d ' ')"
active_before="$(active_win)"
new="$(TMUX_PANE="$pane" "$ROOST" spawn helper)"
after="$(T list-windows | wc -l | tr -d ' ')"
assert_eq "$after" "$((before + 1))" "spawn creates a new window"
# spawn must NOT steal focus — the session's active window is unchanged (-d).
assert_eq "$(active_win)" "$active_before" "spawn creates in the background (does not switch the active window)"
assert_eq "$(T display-message -p -t "$new" '#{window_name}')" "helper" "spawn names the window"

# regression (Fix 1): spawn sets @roost-name to the SAME string it already used
# to name the window, so every window-scoped label site (status, the tab
# formats, the switcher) must suppress the "·LABEL"/"/LABEL" suffix when it
# would just echo the window name back ("helper/helper"). The pre-fix bug
# rendered exactly that duplicate; assert_contains "reviewer" elsewhere does
# NOT catch this because that fixture names a pane differently from its window.
statusline="$("$ROOST" status | grep "^    $new ")"
case "$statusline" in
  *"helper/helper"*) assert_eq "helper/helper" "helper" "spawn: status does not duplicate the label (no window/window echo)" ;;
  *) assert_eq ok ok "spawn: status does not duplicate the label (no window/window echo)" ;;
esac
assert_contains "$statusline" " helper " "spawn: status still shows the (single) label"

# same check against the REAL rendered tab formats, not just the status list —
# resolve window-status-format/-current-format the way tmux itself would.
# roost status alone doesn't load tmux/roost.conf onto the test server (it only
# sets pane options), so the tab formats source it here before being resolved.
T source-file "$HERE/tmux/roost.conf"
tab="$(T display-message -p -t "$new" '#{E:window-status-format}')"
tabcur="$(T display-message -p -t "$new" '#{E:window-status-current-format}')"
case "$tab$tabcur" in
  *"helper·helper"*) assert_eq "helper·helper" "helper" "spawn: window-status formats do not duplicate the label" ;;
  *) assert_eq ok ok "spawn: window-status formats do not duplicate the label" ;;
esac
assert_contains "$tab" "helper" "spawn: window-status-format still shows the (single) label"

# and the switcher row
switchrow="$(ROOST_SWITCH_SOCK="$sock" ROOST_SWITCH_DUMP=1 "$HERE/scripts/roost-switch" | awk -F'\t' -v p="$new" '$3==p')"
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
new2="$(TMUX_PANE="$pane" "$ROOST" spawn helper2 true)"
assert_contains "$new2" "%" "spawn NAME CMD prints a target"

# regression: a short-lived CMD's pane can be reaped by tmux before the
# subsequent `set-option @roost-name` runs. Under `set -euo pipefail` that
# failing set-option used to abort the whole `spawn` before its `printf`, so
# spawn returned nothing and exited 1 for a window that was actually created.
# One run passing is not proof (the race doesn't always land) — repeat it.
spawn_fail=0
for i in 1 2 3 4 5 6 7 8; do
  out="$(TMUX_PANE="$pane" "$ROOST" spawn "quickie$i" true 2>&1)"; rc=$?
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

# --- skill integrity: it must reference only real roost subcommands ---
# Check each `roost <cmd>` the skill names is a real subcommand, by word-matching
# it in bin/roost (matches its dispatch branch and/or the usage synopsis). This
# sidesteps dispatch-syntax quirks like `wait-done|wait)`.
SKILL="$HERE/skills/roost/SKILL.md"
[ -f "$SKILL" ] && assert_eq ok ok "skills/roost/SKILL.md exists" || assert_eq "" exists "skills/roost/SKILL.md exists"
for cmd in whoami spawn split send wait-done read status; do
  if grep -q "roost $cmd" "$SKILL" 2>/dev/null && grep -qw "$cmd" "$HERE/bin/roost" 2>/dev/null; then
    assert_eq ok ok "skill uses a real subcommand: roost $cmd"
  else
    assert_eq "" real "skill uses a real subcommand: roost $cmd"
  fi
done

# --- stable-id targets: send/read accept %N (pane) and @N (window) ---
recvpane="$(T display-message -p -t "$recv" '#{pane_id}')"   # %N
"$ROOST" send "$recvpane" "printf 'PID-%s\n' OK"
wait_for "$recvpane" 'PID-OK' \
  && assert_eq ok ok "send routes a %N pane-id target" \
  || assert_eq no-exec executed "send routes a %N pane-id target"
"$ROOST" read "$recvpane" 5 | grep -q 'PID-OK' \
  && assert_eq ok ok "read routes a %N pane-id target" \
  || assert_eq "" read "read routes a %N pane-id target"
recvwin="$(T display-message -p -t "$recv" '#{window_id}')"  # @N
"$ROOST" send "$recvwin" "printf 'WID-%s\n' OK"
wait_for "$recvwin" 'WID-OK' \
  && assert_eq ok ok "send routes an @N window-id target" \
  || assert_eq no-exec executed "send routes an @N window-id target"

# status leads each window row with the stable %N target
"$ROOST" status | grep -qE '%[0-9]' \
  && assert_eq ok ok "roost status shows a stable %N target" \
  || assert_eq "" pane-id "roost status shows a stable %N target"

# --- wait-done is pane-precise ---
# The regression this guards: pane options are invisible to `show-options -wqv`,
# which returns empty — so a window-scoped read reports every agent "done".
wpane="$(T display-message -p -t "$recv" '#{pane_id}')"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$wpane")"
T set-option -p -t "$sib" @agent_state working

# the busy pane blocks; a 1s timeout must fail rather than return success
"$ROOST" wait-done "$sib" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "wait-done on a working pane times out (does not read window scope)"

# its sibling is not an agent, so it is already done
"$ROOST" wait-done "$wpane" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a non-agent pane returns immediately"

# a window target aggregates: one working pane keeps the whole window busy
wid="$(T display-message -p -t "$recv" '#{window_id}')"
"$ROOST" wait-done "$wid" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "wait-done on a window waits for every agent pane"

# once that pane finishes, the window target returns
T set-option -p -t "$sib" @agent_state done
"$ROOST" wait-done "$wid" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a window returns once all agent panes are done"

# --- wait-done understands the error state ---
# An errored agent will never become done, so treating it as still-busy would
# hang to timeout, and falling through to the default arm (as working|blocked's
# absence used to) reported it as successfully finished — the one wrong answer
# a coordinating agent cannot recover from.
T set-option -p -t "$sib" @agent_state done
"$ROOST" wait-done "$sib" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a done pane exits 0"

T set-option -p -t "$sib" @agent_state error
errout="$("$ROOST" wait-done "$sib" 1 2>&1)"; rc=$?
assert_eq "$rc" "1" "wait-done on an errored pane exits non-zero"
assert_contains "$errout" "error" "wait-done on an errored pane names the state"

# a window with no agents at all returns immediately
empty="$(T new-window -d -PF '#{window_id}')"
"$ROOST" wait-done "$empty" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a window with no agents returns immediately"

# --- status lists panes ---
T set-option -p -t "$sib" @agent_state blocked
out="$("$ROOST" status)"
assert_contains "$out" "$sib" "status lists the helper pane by its %N"
assert_contains "$out" "blocked" "status shows each pane's own state"

# --- send verifies its submit ---
# The failure this guards: a cold TUI swallows the Enter, the text sits in the
# input box, and send exits 0 anyway — so a caller waits forever on a message
# that was never delivered.

# a normal shell submits on the first Enter and still exits 0
"$ROOST" send "$recv" "printf 'VERIFY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send exits 0 when the text submits"
wait_for "$recv" 'VERIFY-OK' \
  && assert_eq ok ok "send still delivers normally" \
  || assert_eq no-exec executed "send still delivers normally"

# a garbage retry count falls back to the default rather than aborting
T set-option -g @roost-send-retries "not-a-number"
"$ROOST" send "$recv" "printf 'RETRY-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send survives a garbage @roost-send-retries"
wait_for "$recv" 'RETRY-OK' \
  && assert_eq ok ok "send still submits with a garbage retry count" \
  || assert_eq no-exec executed "send still submits with a garbage retry count"
T set-option -gu @roost-send-retries 2>/dev/null || true

# zero retries is honoured (one Enter, no verification loop) and still works
T set-option -g @roost-send-retries "0"
"$ROOST" send "$recv" "printf 'ZERO-%s\n' OK"; rc=$?
assert_eq "$rc" "0" "send with zero retries exits 0"
T set-option -gu @roost-send-retries 2>/dev/null || true

# @roost-send-retries clamping: pin the EXACT retry count a given value
# expands to, not just "some fallback happened". A pane that NEVER accepts
# Enter (swallow-all-enters.py) exhausts the whole retry loop every time and
# reports "tried N extra Enter(s)" with the real N in it, so N in that
# message is a direct read of what the clamp produced.
# The bug this guards: `case "$retries" in ???*) retries=20 ;; esac` matches
# on STRING LENGTH, so a perfectly ordinary "007" (3 characters) used to be
# clamped to 20 instead of read as 7.
if command -v python3 >/dev/null 2>&1; then
  T set-option -g @roost-send-enter-delay "0.05"   # keep the retry loop fast

  stuck_send() { # stuck_send RETRIES-VALUE -> sets $out $rc against a fresh stuck pane
    local val="$1" p
    p="$(T new-window -P -F '#{pane_id}' -n stuck "python3 -u $HERE/tests/fixtures/swallow-all-enters.py")"
    # Wait for the fixture's own readiness marker instead of a fixed sleep: at
    # the shortened 0.05s @roost-send-enter-delay below, a fixed sleep narrows
    # the window for python3's cold start to reach tty.setraw() before typing
    # begins. Miss it and the tty is still in cooked mode when "abc" + Enter
    # arrive, so the kernel echoes/interprets the newline itself and the
    # assertion silently inverts instead of failing loudly.
    wait_for "$p" 'READY'
    if [ -n "$val" ]; then T set-option -g @roost-send-retries "$val"
    else T set-option -gu @roost-send-retries 2>/dev/null || true
    fi
    out="$("$ROOST" send "$p" "abc" 2>&1)"; rc=$?
    T set-option -gu @roost-send-retries 2>/dev/null || true
    [ -n "$p" ] && T kill-window -t "$p" 2>/dev/null || true
  }

  stuck_send "007"
  assert_eq "$rc" "1" "send against a permanently stuck pane exits 1"
  assert_contains "$out" "tried 7 extra Enter(s)" \
    "@roost-send-retries \"007\" is read as 7, not clamped to 20 by its length"

  # "000" must land somewhere sane (0), not on the empty string that would
  # break the later `[ "$n" -gt 0 ]` guard, and not on the 3-digit-length
  # clamp either. retries=0 skips the whole verification path (same as the
  # already-tested "0" case above), so a permanently stuck pane is reported
  # as a clean exit 0 rather than a failure — that IS the "0 retries" contract,
  # just confirming "000" reaches the identical code path as "0".
  stuck_send "000"
  assert_eq "$rc" "0" '@roost-send-retries "000" behaves like 0, not empty/garbage'
  # rc alone can't tell "000" -> "0" apart from "000" -> "" collapsing: both put
  # `[ "$n" -gt 0 ]` in while/if condition position, where `set -e` exempts it,
  # so an empty $retries just skips the retry loop silently and rc is still 0
  # either way. The only observable difference is bash printing "integer
  # expression expected" to stderr for the empty case, and $out already
  # captured stderr (2>&1) above — so a clamp regression back to "" shows up
  # here as non-empty $out even though rc stays 0.
  assert_eq "$out" "" '@roost-send-retries "000" produces no stderr (rules out the empty-string regression)'

  # a very long digit string is still clamped (to 20) and does not hang: the
  # whole call — including the up-to-20-iteration retry loop at a shortened
  # 0.05s delay — must finish in well under the time an actual hang or an
  # unclamped multi-thousand-iteration loop would take.
  long_digits="$(printf '9%.0s' $(seq 1 500))"
  t0=$SECONDS
  stuck_send "$long_digits"
  elapsed=$((SECONDS - t0))
  assert_eq "$rc" "1" "send against a stuck pane with an absurd retries value still exits 1"
  assert_contains "$out" "tried 20 extra Enter(s)" \
    "a 500-digit @roost-send-retries value is clamped to 20, not left as-is"
  [ "$elapsed" -le 10 ] \
    && assert_eq ok ok "a 500-digit @roost-send-retries value does not hang the length clamp" \
    || assert_eq "took ${elapsed}s" "<=10s" "a 500-digit @roost-send-retries value does not hang the length clamp"

  # existing fallback still works, pinned to its exact count too: unset ->
  # default 3.
  stuck_send ""
  assert_eq "$rc" "1" "send against a stuck pane with unset retries still exits 1"
  assert_contains "$out" "tried 3 extra Enter(s)" \
    "unset @roost-send-retries still falls back to the default of 3"

  T set-option -gu @roost-send-enter-delay 2>/dev/null || true
else
  assert_eq ok ok "@roost-send-retries clamping tests skipped (no python3)"
fi

# an empty message is a legitimate bare Enter, not "still pending" forever.
# The bug this guards: `case "$last" in *""*)` collapses to `*)`, which
# matches ANY pane content, so a naive pending() would call an empty send
# "still pending" forever and fire every retry (4 Enters instead of 1) before
# exiting 1 for a message that had nothing to submit in the first place.
# Prove the exact count with a reader that stamps one countable line per
# Enter it receives — not just that "an" Enter arrived, but exactly one.
counter="$(T new-window -P -F '#{pane_id}' -n counter "sh $HERE/tests/fixtures/count-enters.sh")"
"$ROOST" send "$counter" ""; rc=$?
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

# `roost send TARGET` with no text argument at all (not even "") behaves the
# same way — raw="${2:?...}" only requires the target, so this is reachable.
"$ROOST" send "$counter"; rc=$?
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

# regression: a command that is genuinely submitted but stays SILENT longer
# than the retry window must not be reported as "never submitted". Screen
# text alone can't tell "Enter was never accepted" apart from "Enter was
# accepted and the command hasn't printed anything yet" — both look like an
# unchanged screen. The retry loop also fires spurious Enters at the pane
# while it waits. Delay is shortened here (not the default 0.3s) purely to
# keep the suite fast.
# The receiving pane runs a plain `sh`, NOT the tester's own $SHELL: an
# interactive login shell can carry a decorated prompt (git status, a live
# clock, timers) that redraws on its own during the silence, which changes
# the screen for reasons that have nothing to do with the command and masks
# the very bug this test exists to catch. `sh` gives a static, portable
# prompt so the only thing that can change the screen is the command itself.
T set-option -g @roost-send-enter-delay "0.1"
silent="$(T new-window -P -F '#{pane_id}' -n silent sh)"
sleep 0.3   # let the freshly-spawned sh settle to its prompt before typing
# default retries=3 * delay=0.1 = a 0.3s verification window; stay silent
# for 1.5s (5x that) before printing, well past the margin above.
"$ROOST" send "$silent" "sh -c 'sleep 1.5; printf \"SILENT-MARK-%s\n\" DONE'"; rc=$?
assert_eq "$rc" "0" "send does not report false failure for a command silent past the retry window"
wait_for "$silent" 'SILENT-MARK-DONE' \
  && assert_eq ok ok "send: the silent command actually executed" \
  || assert_eq no-exec executed "send: the silent command actually executed"
sleep 0.5
out="$(T capture-pane -p -t "$silent")"
markcount="$(printf '%s\n' "$out" | grep -o 'SILENT-MARK-DONE' | wc -l | tr -d ' ')"
assert_eq "$markcount" "1" "send: the silent command executed exactly once (no double-run from a caller re-send)"
T set-option -gu @roost-send-enter-delay 2>/dev/null || true

# regression: BLANK PROMPT + ZERO VISIBLE OUTPUT, together. This gap was
# closed for free (not the bug this task targets) when the cursor-position
# conjunct was added to pending(): a pane with PS1='' has no prompt to
# redraw, and a command like ":" prints nothing either, so the screen's
# TEXT can look byte-identical before and after a genuine submit — the
# "silent command" case above alone does not cover this, because that pane
# still has a normal shell prompt that redraws. Text-unchanged could not
# tell "Enter was swallowed" apart from "Enter was accepted into a pane
# with nothing to redraw", but the tty moves the cursor the moment Enter is
# ACCEPTED by the line discipline, independent of prompt or output — that
# is what actually closes this. Pin it here so it cannot silently regress.
# Measured against the current tip in a pane started as `env PS1= PROMPT= sh`:
#   ":"      rc=0 executed=yes
#   "true"   rc=0 executed=yes
#   echo hi  rc=0 executed=yes   (control, has visible output)
# "executed" is proven via a marker FILE, not screen text — the command
# under test must produce nothing on screen, by construction, so a
# screen-based check here would only retest the "silent command" case above.
marker="$(mktemp)"
blankprompt="$(T new-window -P -F '#{pane_id}' -n blankprompt "env PS1= PROMPT= sh")"
sleep 0.3   # let the freshly-spawned, blank-prompt sh settle before typing
"$ROOST" send "$blankprompt" ": ; printf '%s' DONE > $marker"; rc=$?
assert_eq "$rc" "0" "send exits 0 for a zero-output command in a blank-prompt pane"
n=20
while [ "$n" -gt 0 ] && [ "$(cat "$marker" 2>/dev/null)" != "DONE" ]; do
  sleep 0.2; n=$((n - 1))
done
assert_eq "$(cat "$marker" 2>/dev/null)" "DONE" \
  "send: the zero-output command in the blank-prompt pane actually executed"
rm -f "$marker"

# a genuinely swallowed first Enter: a fixture that echoes typed text (like a
# TUI redrawing its input box) but silently drops exactly the first Enter it
# receives, leaving the text sitting unsubmitted — the live bug this task
# fixes, reproduced deterministically instead of asserted by option-plumbing
# alone. Its confirmation marker never contains the sent text, so a stuck
# input line can't be mistaken for delivery.
if command -v python3 >/dev/null 2>&1; then
  swallow="$(T new-window -P -F '#{pane_id}' -n swallow "python3 -u $HERE/tests/fixtures/swallow-first-enter.py")"
  "$ROOST" send "$swallow" "hello world"; rc=$?
  assert_eq "$rc" "0" "send recovers from a genuinely swallowed first Enter (exit 0)"
  wait_for "$swallow" 'SUBMITTED-OK' \
    && assert_eq ok ok "send recovers from a genuinely swallowed first Enter (delivered)" \
    || assert_eq no-exec executed "send recovers from a genuinely swallowed first Enter (delivered)"
else
  assert_eq ok ok "swallowed-Enter recovery test skipped (no python3)"
fi
