#!/usr/bin/env bash
# `roost wait-done` on a pane whose agent has died (#54).
#
# Measured on tmux 3.6 before this fix, with a stand-in agent and with a real
# Claude Code killed mid-turn:
#
#   - an agent launched as the pane's command (`roost spawn NAME CMD`) that is
#     killed takes its pane with it, and wait-done exited 0 at once -- a dead
#     agent reported as finished. `display-message -p -t %GONE` exits 0 with
#     every format empty, so the old busy() read "no state" and called it done.
#     `kill-pane` and `kill-window` did the same.
#   - with `remain-on-exit on` the pane stays, `pane_dead` reads 1, the badge
#     stays `working`, and wait-done burned its whole timeout.
#   - an agent killed inside a shell leaves the pane alive at a prompt,
#     `pane_dead` stays 0 and the badge stays `working`. No tmux fact says the
#     agent is gone. #64 catches it from a job the sink RECORDED
#     (tests/test-wait-done-shell.sh); a pane with no record still times out
#     with exit 1 -- pinned below, so nobody "fixes" it later with a guess.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
export ROOST_SOCKET="$sock"   # bin/roost talks to the isolated test server (path → -S)
unset TMUX TMUX_PANE
work="$ROOST_TEST_SOCKDIR/w"; mkdir -p "$work"

exists() { T list-panes -a -F '#{pane_id}' | grep -Fxq "$1"; }
# An exec'd stand-in agent: the pane's own process, so killing it closes the
# pane exactly as a killed `roost spawn` agent does.
agent_window() { T new-window -d -P -F '#{pane_id}' 'exec sleep 600'; }
win_of() { T display-message -p -t "$1" '#{window_id}'; }
gone_within() { # PANE — poll until it is really gone (up to ~4s)
  local n=40; while exists "$1" && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  ! exists "$1"
}
# Run wait-done in the background; its rc and stderr land in $work.
bg_wait() { # TARGET TIMEOUT TAG
  ( "$ROOST" wait-done "$1" "$2" 2>"$work/$3.err" >/dev/null; echo $? > "$work/$3.rc" ) &
}
bg_result() { # PID TAG -> sets rc, err
  wait "$1"; rc="$(cat "$work/$2.rc")"; err="$(cat "$work/$2.err")"
}

# --- controls: the harness sees what it should --------------------------------
p="$(agent_window)"; T set-option -p -t "$p" @agent_state working
exists "$p"; assert_true $? "control: the stand-in agent pane exists"
s=$SECONDS; "$ROOST" wait-done "$p" 2 >/dev/null 2>"$work/c.err"; rc=$?
assert_eq "$rc" "1" "control: a live working pane still times out with exit 1"
assert_contains "$(cat "$work/c.err")" "timed out" "control: ...saying it timed out"
el=$((SECONDS - s))
[ "$el" -ge 2 ] && [ "$el" -le 4 ]; assert_true $? "control: the timeout is still counted in seconds (took ${el}s for 2)"
T set-option -p -t "$p" @agent_state done
"$ROOST" wait-done "$p" 2 >/dev/null 2>&1
assert_eq "$?" "0" "control: a done pane still exits 0"
T kill-window -t "$(win_of "$p")"

# --- (a) the pane is already gone when wait-done starts -----------------------
p="$(agent_window)"; w="$(win_of "$p")"; T set-option -p -t "$p" @agent_state working
T kill-window -t "$w"; gone_within "$p"; assert_true $? "the killed agent's pane is gone"
s=$SECONDS; err="$("$ROOST" wait-done "$p" 10 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "wait-done on a pane that is already gone exits 2, not 0"
[ $((SECONDS - s)) -le 2 ]; assert_true $? "...at once, not after its timeout"
assert_contains "$err" "gone" "...saying the pane is gone"
assert_contains "$err" "cannot tell" "...and that roost cannot tell finished-then-closed from died"
err="$("$ROOST" wait-done "$w" 10 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "wait-done on a WINDOW that is already gone exits 2 too"
assert_contains "$err" "cannot tell" "...with the same caveat"

# --- (a) the agent dies DURING the wait ---------------------------------------
p="$(agent_window)"; w="$(win_of "$p")"; T set-option -p -t "$p" @agent_state working
s=$SECONDS; bg_wait "$p" 20 a; pid=$!
sleep 1.5; kill -9 "$(T display-message -p -t "$p" '#{pane_pid}')"
bg_result "$pid" a
assert_eq "$rc" "2" "an agent killed mid-wait: wait-done exits 2"
[ $((SECONDS - s)) -le 6 ]; assert_true $? "...promptly, not after its 20s timeout"
assert_contains "$err" "died" "...saying it died"
assert_contains "$err" "working" "...and what it last read"

# Window target, agent pane beside a sibling shell: the window survives, the
# agent pane does not. The window must agree with the pane.
p="$(agent_window)"; w="$(win_of "$p")"; T set-option -p -t "$p" @agent_state working
T split-window -d -t "$p" 'ENV= exec /bin/sh'
s=$SECONDS; bg_wait "$w" 20 aw; pid=$!
sleep 1.5; T kill-pane -t "$p"
bg_result "$pid" aw
assert_eq "$rc" "2" "a WINDOW whose working agent pane closes mid-wait exits 2"
[ $((SECONDS - s)) -le 6 ]; assert_true $? "...promptly"
assert_contains "$err" "$p" "...naming the pane that died"
T kill-window -t "$w"

# The whole window closes mid-wait.
p="$(agent_window)"; w="$(win_of "$p")"; T set-option -p -t "$p" @agent_state blocked
bg_wait "$w" 20 awg; pid=$!
sleep 1.5; T kill-window -t "$w"
bg_result "$pid" awg
assert_eq "$rc" "2" "a WINDOW that closes while its agent reads blocked exits 2"
assert_contains "$err" "died" "...saying it died"

# A blocked pane that closes between wait-done's two back-to-back snapshots —
# the one before the #62 unblock offer and the one after. Too narrow to hit by
# timing, so a copy of the tree swaps in an unblock helper that closes the pane
# it is offered and declines to clear it. Found by review (flock round 1): the
# window target exited 0, because the second read no longer listed the pane
# and nothing had recorded it as busy yet.
race="$ROOST_TEST_SOCKDIR/race"; mkdir -p "$race"
cp -R "$HERE/bin" "$HERE/scripts" "$race/"
cat >> "$race/scripts/lib/roost-unblock.sh" <<'EOF'

# TEST STUB (tests/test-wait-done-died.sh): close the offered pane, clear nothing.
roost_unblock_pane() { t kill-pane -t "$1" 2>/dev/null; return 1; }
EOF
p="$(agent_window)"; w="$(win_of "$p")"; T set-option -p -t "$p" @agent_state blocked
T split-window -d -t "$p" 'ENV= exec /bin/sh'
err="$("$race/bin/roost" wait-done "$w" 5 2>&1 >/dev/null)"; rc=$?
exists "$p"; assert_eq "$?" "1" "race: the stub really closed the blocked pane"
assert_eq "$rc" "2" "a WINDOW whose blocked pane closes between the unblock snapshots exits 2, not 0"
assert_contains "$err" "$p" "...naming the pane"
T kill-window -t "$w"
p="$(agent_window)"; T set-option -p -t "$p" @agent_state blocked
err="$("$race/bin/roost" wait-done "$p" 5 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "a PANE that closes between the unblock snapshots exits 2"
# `died: ` with the colon: the already-gone message also ends in "...from one
# that died", so the bare word would pass on the wrong message.
assert_contains "$err" "died: " "...saying it died, not that it was already gone"

# The other side of that race: a pane that FINISHES and closes while the unblock
# helper is busy with a blocked sibling. The real helper runs python3 over a
# transcript tail, so it can take as long as a one-shot agent's done-to-gone
# gap. The first read saw the pane done, so it must not count as died. Found by
# review (flock round 2): recording history from the first read, without
# dropping panes it saw finished, turned this finish into a death.
#
# The window it needs is one quarter-second tick wide — busy on the poll before
# an offered tick, done on that tick's first read — so timing cannot hit it.
# The copy wraps bin/roost's `t` and counts `list-panes` calls instead. Every
# pass of a window wait takes one; an offered tick takes two. So call 6 is the
# first read of tick 4, the second offered tick: the wrapper stamps X done just
# before it, and the helper then closes X, as a one-shot agent's pane closes.
# Each case's `fired` file proves the wrapper really acted; without it a broken
# stub would report the fix as working.
#
# MODE kill is the same tick with X closed instead of finished, just before that
# first read: the last poll saw it busy, so it died, and the check against the
# first read must catch it before the history is rebuilt without it.
tick4_case() { # MODE (done|kill)
  local mode="$1" dir="$ROOST_TEST_SOCKDIR/tick4-$1" x w y n pid
  mkdir -p "$dir/tree" "$dir/d"
  cp -R "$HERE/bin" "$HERE/scripts" "$dir/tree/"
  x="$(agent_window)"; w="$(win_of "$x")"
  y="$(T split-window -d -P -F '#{pane_id}' -t "$x" 'exec sleep 600')"
  # bin/roost defines `t` AFTER it sources roost-unblock.sh, so the stub is its
  # own file, sourced from the copy right after the `t()` line.
  grep -q '^t() { tmux ' "$dir/tree/bin/roost"; assert_true $? "tick4/$mode: the copy still defines t() where the stub is sourced"
  sed -i.bak '/^t() { tmux /a\
. "$ROOST_HOME/scripts/lib/test-stub.sh"
' "$dir/tree/bin/roost"
  if [ "$mode" = done ]; then act="_real_t set-option -p -t $x @agent_state done"; else act="_real_t kill-pane -t $x"; fi
  cat > "$dir/tree/scripts/lib/test-stub.sh" <<EOF
# TEST STUB (tests/test-wait-done-died.sh). Rename the real t, count list-panes.
eval "\$(declare -f t | sed '1s/^t /_real_t /')"
t() {
  if [ "\$1" = list-panes ]; then
    n=\$(( \$(cat "$dir/d/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$dir/d/n"
    if [ "\$n" = 6 ]; then $act; : > "$dir/d/fired"; fi
  fi
  _real_t "\$@"
}
# The helper clears nothing; in MODE done, on the second offer it closes X.
roost_unblock_pane() {
  [ "$mode" = done ] && [ -f "$dir/d/fired" ] && _real_t kill-pane -t "$x" 2>/dev/null
  return 1
}
EOF
  T set-option -p -t "$x" @agent_state working; T set-option -p -t "$y" @agent_state blocked
  ( "$dir/tree/bin/roost" wait-done "$w" 20 2>"$work/tick4-$mode.err" >/dev/null; echo $? > "$work/tick4-$mode.rc" ) &
  pid=$!
  n=50; while [ ! -f "$dir/d/fired" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  sleep 1.5; T set-option -p -t "$y" @agent_state done
  bg_result "$pid" "tick4-$mode"
  [ -f "$dir/d/fired" ]; assert_true $? "tick4/$mode: the wrapper really acted on tick 4's first read"
  exists "$x"; assert_eq "$?" "1" "tick4/$mode: X really closed"
  if [ "$mode" = done ]; then
    assert_eq "$rc" "0" "a WINDOW pane seen done that closes while the helper works on a sibling exits 0, not died"
    assert_eq "$err" "" "...with nothing on stderr"
  else
    assert_eq "$rc" "2" "a WINDOW pane seen busy that closes just before an offered tick's first read exits 2"
    assert_contains "$err" "$x" "...naming the pane"
  fi
  T kill-window -t "$w" 2>/dev/null
}
tick4_case done
tick4_case kill

# A NON-agent sibling closing mid-wait is not a death: only panes seen busy count.
p="$(agent_window)"; w="$(win_of "$p")"; T set-option -p -t "$p" @agent_state working
sib="$(T split-window -d -P -F '#{pane_id}' -t "$p" 'exec sleep 600')"
bg_wait "$w" 20 sib; pid=$!
sleep 1.2; T kill-pane -t "$sib"; sleep 1; T set-option -p -t "$p" @agent_state done
bg_result "$pid" sib
assert_eq "$rc" "0" "a WINDOW whose non-agent sibling closes mid-wait still exits 0"
assert_eq "$err" "" "...with nothing on stderr"
T kill-window -t "$w"

# --- finished, THEN closed, is success ----------------------------------------
# A one-shot agent stamps done and its pane closes on its own. Measured with
# `claude -p` in a `roost spawn` window: 531ms, 1297ms, 1348ms from done to
# gone. A waiter that saw done during this call must exit 0 when the pane then
# goes. 600ms here: below the 1s the loop used to sleep, so a slow poll would
# usually miss the done and call it died.
p="$(agent_window)"; T set-option -p -t "$p" @agent_state working
bg_wait "$p" 20 fin; pid=$!
sleep 1.2; T set-option -p -t "$p" @agent_state done; sleep 0.6; kill -9 "$(T display-message -p -t "$p" '#{pane_pid}')"
bg_result "$pid" fin
assert_eq "$rc" "0" "a pane that reads done and then closes exits 0, not died"

# Window: one agent finishes and its pane closes while another still works;
# then the other finishes. Success, not died.
p1="$(agent_window)"; w="$(win_of "$p1")"
p2="$(T split-window -d -P -F '#{pane_id}' -t "$p1" 'exec sleep 600')"
T set-option -p -t "$p1" @agent_state working; T set-option -p -t "$p2" @agent_state working
bg_wait "$w" 20 finw; pid=$!
sleep 1.2; T set-option -p -t "$p1" @agent_state done; sleep 0.6; T kill-pane -t "$p1"
sleep 1; T set-option -p -t "$p2" @agent_state done
bg_result "$pid" finw
assert_eq "$rc" "0" "a WINDOW whose finished pane closes before the other finishes exits 0"
T kill-window -t "$w"

# --- (c) remain-on-exit: the pane stays, pane_dead=1 --------------------------
dead_agent() { # STATE -> pane id of a dead, remain-on-exit pane with that badge
  local dp; dp="$(agent_window)"
  T set-option -p -t "$dp" remain-on-exit on
  T set-option -p -t "$dp" @agent_state "$1"
  kill -9 "$(T display-message -p -t "$dp" '#{pane_pid}')"
  local n=40; while [ "$(T display-message -p -t "$dp" '#{pane_dead}')" != 1 ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  printf '%s' "$dp"
}
p="$(dead_agent working)"
assert_eq "$(T display-message -p -t "$p" '#{pane_dead}')" "1" "the remain-on-exit pane really is dead"
s=$SECONDS; err="$("$ROOST" wait-done "$p" 10 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "a dead pane still badged working exits 2"
[ $((SECONDS - s)) -le 2 ]; assert_true $? "...at once"
assert_contains "$err" "dead" "...saying the pane is dead"
err="$("$ROOST" wait-done "$(win_of "$p")" 10 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "a WINDOW holding that dead pane exits 2 too"
assert_contains "$err" "$p" "...naming the pane"
T kill-window -t "$(win_of "$p")"

# A dead pane whose agent finished first keeps its old answer: 0.
p="$(dead_agent done)"
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1
assert_eq "$?" "0" "a dead pane whose badge reads done still exits 0"
T kill-window -t "$(win_of "$p")"

# An errored pane keeps exit 1 even once it is dead: error outranks died.
p="$(dead_agent error)"
err="$("$ROOST" wait-done "$p" 5 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "1" "a dead pane badged error still exits 1"
assert_contains "$err" "error state" "...naming the error state"
T kill-window -t "$(win_of "$p")"

# --- (b) busy inside a shell with NO recorded job: not detected, on purpose ----
# The pane is alive at a prompt and pane_dead is 0. With no @roost-agent-job
# (an older install, or a badge no hook wrote) nothing but a process or screen
# check could tell, and #54 rules both out. It must keep timing out with exit 1
# rather than returning a guess. A pane WITH a record is #64's, in
# tests/test-wait-done-shell.sh.
p="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
T set-option -p -t "$p" @agent_state working
err="$("$ROOST" wait-done "$p" 1 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "1" "a busy shell pane with no recorded job still times out with exit 1"
assert_contains "$err" "timed out" "...and says timed out, not died"
