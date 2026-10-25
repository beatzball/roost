#!/usr/bin/env bash
# The pane whose agent died (#105 part 2, step 5 of docs/airig/specs/
# 2026-09-29-turn-over-design.md, §4.4): `send`, `read` and `wait-done` share
# ONE check -- roost_died_pane in scripts/lib/roost-unblock.sh -- and on a
# `died` it UNSETS the badge and records @roost-ended "<stamp> died" (the
# recovery channel: unset only). `status` does NOT call it: a read command
# stays a read command (the human's Q6).
#
# The death is the #64 one, from tests/test-wait-done-shell.sh: an agent typed
# at a shell prompt and killed there leaves the pane alive at its prompt and
# the badge busy, and no hook says otherwise. The stand-ins, the cleanup and
# the helpers below are that file's, copied rather than shared, for the
# reason its header gives: job control is the whole mechanism, and each file
# owns the processes it starts.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
SINK="$HERE/scripts/roost-agent-state"

# The sink acts only on a socket whose path ends in /roost, so the server is
# built here rather than through roost_test_server, as tests/test-agent-state.sh
# does. The short mktemp path keeps under the ~104-char socket limit.
sdir="$(mktemp -d /tmp/amx.XXXX)"; sock="$sdir/roost"
work="$sdir/w"; mkdir -p "$work"
# Every stand-in job this file starts writes its process group to $work/jobs,
# and cleanup kills exactly those groups — never a kill by name. Two copies of
# this file can run at once (two worktrees, a reviewer beside a developer), and
# a name match would kill the other run's live stand-ins, which that run then
# reports as died. A group is killed only while it still holds one of THIS
# run's stand-ins (a command naming $work), so a group id reused by an
# unrelated process after ours ended is left alone.
cleanup() {
  local g
  if [ -f "$work/jobs" ]; then
    while read -r g; do
      case "$g" in ''|*[!0-9]*) continue ;; esac
      # The path must be the process's FIRST ARGUMENT, not anywhere in the
      # line: this very pipeline carries $work in its own awk argv and runs in
      # the test's own process group, so a looser match would let a $work/jobs
      # line naming the test's own pgid satisfy the guard with no stand-in
      # alive — and kill the test, and under tests/run.sh the runner with it.
      # Unreachable today (every stand-in's pgid is a live pane child), so this
      # keeps it unreachable. Found by review (flock round 2).
      ps -A -o pgid=,command= | awk -v g="$g" -v w="$work/" '$1 == g && index($3, w) == 1' | grep -q . \
        && kill -9 -- "-$g" 2>/dev/null
    done < "$work/jobs"
  fi
  tmux -S "$sock" kill-server 2>/dev/null
  rm -rf "$sdir"
}
trap cleanup EXIT
tmux -S "$sock" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
T() { tmux -S "$sock" "$@"; }
export ROOST_SOCKET="$sock"   # bin/roost talks to the isolated test server
unset TMUX TMUX_PANE

# --- stand-in agents ----------------------------------------------------------
# agent: stamps working through the sink, then works. It `exec`s $work/idle,
#   so the job keeps the script's pid and the command line still names this
#   run; idle is a loop, so the job is two processes (the sh and a one-second
#   sleep child), not one.
cat > "$work/agent" <<EOF
#!/bin/sh
ps -o pgid= -p \$\$ | tr -d ' ' >> "$work/jobs"
"$SINK" working </dev/null
echo "\$\$" > "$work/agent.pid"
exec "$work/idle"
EOF
# idle: the stand-ins' long-running work. A script under $work, not a bare
# `sleep`, so its command line (`/bin/sh <dir>/w/idle`) names this run and
# cleanup can tell it is ours. A loop of short sleeps rather than one `exec
# sleep`, which would replace that command line with sleep's own.
cat > "$work/idle" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod +x "$work/agent" "$work/idle"

# shell_pane: a new window running an INTERACTIVE shell, which has job control.
shell_pane() {
  local p; p="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh -i')"
  printf '%s' "$p"
}
win_of() { T display-message -p -t "$1" '#{window_id}'; }
record() { T show-options -pqv -t "$1" @roost-agent-job; }
pstate() { T show-options -pqv -t "$1" @agent_state; }
pane_pid() { T display-message -p -t "$1" '#{pane_pid}'; }
fg_job() { ps -o tpgid= -p "$(pane_pid "$1")" | tr -d ' '; }
# type CMD at the pane's prompt, as a human or another agent would
type_cmd() { sleep 0.3; T send-keys -t "$1" "$2" Enter; }
wait_state() { # PANE STATE — up to ~5s
  local n=50; while [ "$(pstate "$1")" != "$2" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  [ "$(pstate "$1")" = "$2" ]
}
wait_record() { # PANE — up to ~5s for a non-empty record
  local n=50; while [ -z "$(record "$1")" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  [ -n "$(record "$1")" ]
}
wait_shell_fg() { # PANE — up to ~5s until the shell holds its terminal
  local n=50; while [ "$(fg_job "$1")" != "$(pane_pid "$1")" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  [ "$(fg_job "$1")" = "$(pane_pid "$1")" ]
}
bg_wait() { # TARGET TIMEOUT TAG
  ( "$ROOST" wait-done "$1" "$2" 2>"$work/$3.err" >/dev/null; echo $? > "$work/$3.rc" ) &
}
bg_result() { # PID TAG -> sets rc, err
  wait "$1"; rc="$(cat "$work/$2.rc")"; err="$(cat "$work/$2.err")"
}
pgid_of_record() { local r; r="$(record "$1")"; printf '%s' "${r%%:*}"; }

opt() { T show-options -pqv -t "$1" "$2"; }
# dead_agent -> a shell pane whose stand-in agent stamped working, recorded
# its job, and was then killed -9 at the prompt: the #64 death, with the
# shell holding its terminal again. Every check below starts from one.
dead_agent() {
  local p; p="$(shell_pane)"
  type_cmd "$p" "$work/agent"; wait_state "$p" working; wait_record "$p"
  kill -9 -- "-$(pgid_of_record "$p")"; wait_shell_fg "$p"
  printf '%s' "$p"
}

# --- control: the death is the one #64 sees ------------------------------------------
p="$(dead_agent)"
assert_eq "$(pstate "$p")" "working" "control: the dead agent's badge still reads working"
[ -n "$(record "$p")" ]; assert_true $? "control: ...and its job is recorded"
assert_eq "$(fg_job "$p")" "$(pane_pid "$p")" "control: ...and the shell holds the terminal again"

# --- status does not write (Q6) --------------------------------------------------------
"$ROOST" status >/dev/null 2>&1
"$ROOST" status --json >/dev/null 2>&1
assert_eq "$(pstate "$p")" "working" "status leaves a dead agent's badge as it is stored (Q6)"
assert_eq "$(opt "$p" @roost-ended)" "" "...and records no outcome"
st="$("$ROOST" status --json)"
case "$st" in *"\"id\":\"$p\""*"\"state\":\"working\""*) r=0 ;; *) r=1 ;; esac
assert_true "$r" "...and status --json shows what is stored: working"

# --- read unsets it --------------------------------------------------------------------
since="$(opt "$p" @agent_since)"
T set-option -p -t "$p" @roost-reply "an earlier turn's answer"
"$ROOST" read "$p" >"$work/r.out" 2>"$work/r.err"
assert_eq "$(pstate "$p")" "" "read: a dead agent's badge is unset"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "read: ...and the outcome is died, tied to the stamp"
assert_eq "$(record "$p")" "" "read: ...and the job record goes with it"
assert_eq "$(opt "$p" @roost-reply)" "" "read: ...and the previous turn's reply is not served as this turn's"
assert_contains "$(cat "$work/r.err")" "no recorded reply" "read: ...so read falls back to the screen and says so"
T kill-window -t "$(win_of "$p")"

# --- send unsets it ---------------------------------------------------------------------
p="$(dead_agent)"; since="$(opt "$p" @agent_since)"
"$ROOST" send "$p" "true" >/dev/null 2>"$work/s.err"
assert_eq "$(pstate "$p")" "" "send: a dead agent's badge is unset"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "send: ...and the outcome is died"
T kill-window -t "$(win_of "$p")"

# A dead agent that was BLOCKED: before, send refused it with exit 3 for ever,
# since no dialog will ever be answered there.
p="$(dead_agent)"; T set-option -p -t "$p" @agent_state blocked; since="$(opt "$p" @agent_since)"
"$ROOST" send "$p" "true" >/dev/null 2>"$work/sb.err"; rc=$?
[ "$rc" != 3 ]; assert_true $? "send: a dead agent left blocked is not refused as a dialog (rc $rc)"
assert_eq "$(pstate "$p")" "" "send: ...and its badge is unset"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "send: ...as died"
T kill-window -t "$(win_of "$p")"

# --- wait-done shares it ----------------------------------------------------------------
p="$(dead_agent)"; since="$(opt "$p" @agent_since)"
"$ROOST" wait-done "$p" 10 >/dev/null 2>"$work/w.err"; rc=$?
assert_eq "$rc" "2" "wait-done: still exits 2 for a dead agent"
assert_eq "$(pstate "$p")" "" "wait-done: ...and now unsets the badge too"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "wait-done: ...as died"
# A second wait finds no badge and the record: still 2, and the reason is the
# shell, not background work (that wording is SessionEnd's, #188).
"$ROOST" wait-done "$p" 5 >/dev/null 2>"$work/w2.err"; rc=$?
assert_eq "$rc" "2" "wait-done again on the cleared pane: still exits 2"
assert_contains "$(cat "$work/w2.err")" "exited inside its shell" "...and says the agent exited inside its shell"
case "$(cat "$work/w2.err")" in *"background work"*) r=1 ;; *) r=0 ;; esac
assert_true "$r" "...not that background work was cut off"
T kill-window -t "$(win_of "$p")"

# --- a held main reply survives ---------------------------------------------------------
# A pane held by background work (#97) keeps its turn's main reply on the
# pane only; the death must not throw it away.
p="$(dead_agent)"; since="$(opt "$p" @agent_since)"
T set-option -p -t "$p" @roost-background "$since 1" \; set-option -p -t "$p" @roost-reply "THE MAIN REPLY"
out="$("$ROOST" read "$p" 2>"$work/h.err")"
assert_eq "$(pstate "$p")" "" "held: a dead agent's badge is unset"
assert_eq "$(opt "$p" @roost-background)" "" "held: ...and the hold record with it"
assert_eq "$out" "THE MAIN REPLY" "held: ...and read still prints the main reply"
assert_contains "$(cat "$work/h.err")" "died" "held: ...saying the agent died"
T kill-window -t "$(win_of "$p")"

# --- a live agent is never cleared ------------------------------------------------------
p="$(shell_pane)"; type_cmd "$p" "$work/agent"; wait_state "$p" working; wait_record "$p"
"$ROOST" read "$p" >/dev/null 2>&1
assert_eq "$(pstate "$p")" "working" "a live agent: read leaves working"
"$ROOST" send "$p" "" >/dev/null 2>&1
assert_eq "$(pstate "$p")" "working" "a live agent: send leaves working"
assert_eq "$(opt "$p" @roost-ended)" "" "a live agent: ...and records no outcome"
T kill-window -t "$(win_of "$p")"

# --- a replacement that reports between the check and the clear wins ----------------------
# Fix round 1 (found by review, reproduced): the clear compares the state,
# the stamp and the job record, and a replacement agent typed at the same
# prompt between job_gone and the clear reported `working` onto a pane that
# already read working -- the sink's unchanged-state bail, which wrote
# nothing. All three still matched, and the live replacement's badge was
# unset and recorded as died. The sink now re-records the job when the one
# it finds has no process left, and that is what the clear loses to.
#
# The interleaving is forced, not hoped for: roost_died_pane runs here, in
# this shell, with a `t` that starts the replacement and waits for its
# report to finish just before the clear's one tmux command goes out. The
# library is sourced and job_gone is taken from bin/roost itself, so the code
# under test is the shipped code; the subshell keeps the `t` to itself.
p="$(dead_agent)"; since="$(opt "$p" @agent_since)"
rm -f "$work/agent.pid"
(
  ROOST_HOME="$HERE"
  . "$HERE/scripts/lib/roost-unblock.sh"
  eval "$(sed -n '/^job_gone() {$/,/^}$/p' "$ROOST")"
  eval "$(sed -n '/^record_for() {$/,/^}$/p' "$ROOST")"
  injected=0
  t() {
    if [ "$1" = if-shell ] && [ "$injected" = 0 ]; then
      injected=1
      type_cmd "$p" "$work/agent"
      local n=50; while [ ! -s "$work/agent.pid" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
    fi
    tmux -S "$sock" "$@"
  }
  roost_died_pane "$p"
); rc=$?
[ -s "$work/agent.pid" ]; assert_true $? "race: control: the replacement started and reported before the clear"
[ "$rc" != 0 ]; assert_true $? "race: the clear loses to a replacement that reported in between (rc $rc)"
assert_eq "$(pstate "$p")" "working" "race: ...so the replacement's badge still reads working"
case "$(opt "$p" @roost-ended)" in *died) r=1 ;; *) r=0 ;; esac
assert_true "$r" "race: ...and no death is recorded against it"
kill -0 "$(cat "$work/agent.pid" 2>/dev/null)" 2>/dev/null; assert_true $? "race: control: the replacement is alive"
"$ROOST" wait-done "$p" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "race: wait-done on the live replacement times out, not died"
T kill-window -t "$(win_of "$p")"

# The same sink change, alone: a `working` onto a pane whose recorded job has
# no process left re-records the job from the terminal, while one whose job is
# alive bails as before (the PostToolUse hot path: no ps there).
p="$(dead_agent)"; old="$(record "$p")"
rm -f "$work/agent.pid"; type_cmd "$p" "$work/agent"
n=50; while [ ! -s "$work/agent.pid" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
new="$(record "$p")"
[ -n "$new" ] && [ "$new" != "$old" ]; assert_true $? "sink: a stale job record is replaced by the reporter's ($old -> $new)"
assert_eq "${new%%:*}" "$(fg_job "$p")" "sink: ...with the job that holds the terminal now"
T kill-window -t "$(win_of "$p")"

# --- the death is filed against its turn number -------------------------------------
# Fix round 1 (found by review, reproduced): the clear removed the evidence
# job_gone needs and filed no turn, so the FIRST `wait-done --turn 1` exited 2
# and the second timed out -- or, with no bound, waited for a later agent's
# turn 1. The death is now filed as turn N with its own outcome word, and its
# own sentence: the agent exited inside its shell, which is not #188's
# "before its background work finished".
export ROOST_RECORD_DIR="$work/records"
p="$(dead_agent)"
"$ROOST" wait-done --json --turn 1 "$p" 2 >"$work/t1.json" 2>"$work/t1.err"; rc=$?
assert_eq "$rc" "2" "turn: the first wait-done --turn 1 on a dead agent exits 2"
assert_contains "$(cat "$work/t1.json")" '"outcome":"died"' "turn: ...outcome died"
"$ROOST" wait-done --json --turn 1 "$p" 2 >"$work/t2.json" 2>"$work/t2.err"; rc=$?
assert_eq "$rc" "2" "turn: the second wait-done --turn 1, after the clear, still exits 2"
assert_contains "$(cat "$work/t2.json")" '"outcome":"died"' "turn: ...outcome died"
assert_contains "$(cat "$work/t2.err")" "exited inside its shell" "turn: ...and says the agent exited inside its shell"
case "$(cat "$work/t2.err")" in *"background work"*) r=1 ;; *) r=0 ;; esac
assert_true "$r" "turn: ...not #188's background-work sentence"
"$ROOST" read --turn 1 "$p" >"$work/t3.out" 2>"$work/t3.err"; rc=$?
assert_eq "$rc" "0" "turn: read --turn 1 finds the filed death"
assert_contains "$(cat "$work/t3.err")" "exited inside its shell" "turn: ...and says how the turn ended"
assert_contains "$(cat "$work/t3.err")" "recorded no reply" "turn: ...with no reply"
case "$(cat "$work/t3.err")" in *"background work"*) r=1 ;; *) r=0 ;; esac
assert_true "$r" "turn: ...and not in #188's words"
# The numbering (§5.4): the next turn is 2, so turn 1 keeps its answer.
"$ROOST" wait-done --turn 2 "$p" 1 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "turn: turn 2 is not answered by the death of turn 1"
T kill-window -t "$(win_of "$p")"

# A HELD turn's main reply is the filed turn's text.
p="$(dead_agent)"; since="$(opt "$p" @agent_since)"
T set-option -p -t "$p" @roost-background "$since 1" \; set-option -p -t "$p" @roost-reply "THE HELD REPLY"
"$ROOST" wait-done --turn 1 "$p" 2 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "turn, held: wait-done --turn 1 exits 2"
out="$("$ROOST" read --turn 1 "$p" 2>"$work/t4.err")"
assert_eq "$out" "THE HELD REPLY" "turn, held: turn 1's text is the held main reply"
assert_contains "$(cat "$work/t4.err")" "this is the main reply it had given" "turn, held: ...and read says so"
T kill-window -t "$(win_of "$p")"

# --- a replacement inside the clear's gap does not take the dead turn's number ------
# Fix round 2 (found by review, reproduced): the clear removed the badge and
# the turn file landed after it, so a replacement agent that reported and
# FINISHED in between took turn 1 with its own reply, and the death was filed
# as turn 2 -- `wait-done --turn 1` returned the replacement's answer for the
# dead prompt. If the replacement reported before the clear was read back, the
# clear looked refused and the death was never filed at all. The clear now
# reserves the turn's number in its own tmux command, as #188's SessionEnd
# release does, and files a clear that landed even when a newer turn has
# superseded it.
#
# Both schedules are forced, as the race above: roost_died_pane runs in a
# subshell here with the shipped library and bin/roost's own job_gone and
# record_for, and the replacement is typed at the pane and waited for at the
# one point each schedule names. The replacement is a real agent to the sink:
# it reports working, then a Stop with its reply, from inside the pane's job.
# The sink in the pane writes records too, so the server's environment names
# the record directory before the pane is made.
T set-environment -g ROOST_RECORD_DIR "$ROOST_RECORD_DIR"
cat > "$work/replacement" <<EOF
#!/bin/sh
ps -o pgid= -p \$\$ | tr -d ' ' >> "$work/jobs"
"$SINK" working </dev/null
printf '%s' '{"last_assistant_message":"NEW_REPLY","background_tasks":[]}' | "$SINK" done --stop-hook
echo done > "$work/replacement.done"
EOF
chmod +x "$work/replacement"
# replacement_done -> 0 once the replacement has filed its Stop, up to ~5s
replacement_done() {
  local n=100; while [ ! -s "$work/replacement.done" ] && [ "$n" -gt 0 ]; do sleep 0.05; n=$((n - 1)); done
  [ -s "$work/replacement.done" ]
}
# gap_case WHERE -> $p, a dead agent offered to roost_died_pane with the
# replacement forced in at WHERE:
#   append    after the clear landed and was read back, before the turn is filed
#   readback  after the clear's one tmux command, before it is read back
gap_case() {
  p="$(dead_agent)"; rm -f "$work/replacement.done"
  (
    ROOST_HOME="$HERE"
    . "$HERE/scripts/lib/roost-unblock.sh"
    eval "$(sed -n '/^job_gone() {$/,/^}$/p' "$ROOST")"
    eval "$(sed -n '/^record_for() {$/,/^}$/p' "$ROOST")"
    injected=0
    launch() { injected=1; type_cmd "$p" "$work/replacement"; replacement_done; }
    t() {
      local r=0
      tmux -S "$sock" "$@" || r=$?
      if [ "$1" = if-shell ] && [ "$WHERE" = readback ] && [ "$injected" = 0 ]; then launch; fi
      return "$r"
    }
    eval "$(declare -f roost_unblock_record_turn | sed '1s/roost_unblock_record_turn/real_record_turn/')"
    roost_unblock_record_turn() {
      if [ "$WHERE" = append ] && [ "$injected" = 0 ]; then launch; fi
      real_record_turn "$@"
    }
    roost_died_pane "$p"
  )
}
gap_checks() { # TAG
  replacement_done; assert_true $? "$1: control: the replacement finished inside the gap"
  "$ROOST" wait-done --json --turn 1 "$p" 2 >"$work/g1.json" 2>/dev/null; rc=$?
  assert_eq "$rc" "2" "$1: wait-done --turn 1 is the death, exit 2"
  assert_contains "$(cat "$work/g1.json")" '"outcome":"died"' "$1: ...outcome died"
  case "$(cat "$work/g1.json")" in *NEW_REPLY*) r=1 ;; *) r=0 ;; esac
  assert_true "$r" "$1: ...not the replacement's reply"
  "$ROOST" read --turn 1 "$p" >"$work/g1.out" 2>"$work/g1.err"
  assert_contains "$(cat "$work/g1.err")" "exited inside its shell" "$1: read --turn 1 says the agent exited inside its shell"
  "$ROOST" wait-done --json --turn 2 "$p" 2 >"$work/g2.json" 2>/dev/null; rc=$?
  assert_eq "$rc" "0" "$1: wait-done --turn 2 is the replacement's turn, exit 0"
  assert_eq "$("$ROOST" read --turn 2 "$p" 2>/dev/null)" "NEW_REPLY" "$1: read --turn 2 is the replacement's reply"
  assert_eq "$(opt "$p" @roost-reply-turn)" "2" "$1: the newer turn's pointer is left on its own turn"
  assert_eq "$(opt "$p" @roost-turn-reserved)" "" "$1: the reservation is released"
  ls -a "$ROOST_RECORD_DIR"/*/*/replies 2>/dev/null | grep -q '^\.reserving\.'; r=$?
  [ "$r" != 0 ]; assert_true $? "$1: ...and no .reserving hint is left behind"
  T kill-window -t "$(win_of "$p")"
}
WHERE=append gap_case; rc=$?
# Here the clear was still the pane's when it was read back, so it answers 0;
# the replacement came after that, and only the number had to hold.
assert_eq "$rc" "0" "gap, append: the clear was the pane's when read back, so it answers 0"
gap_checks "gap, append"
WHERE=readback gap_case; rc=$?
assert_eq "$rc" "1" "gap, readback: a superseded clear answers 1 (the pane is the replacement's)"
gap_checks "gap, readback"

# --- a replacement that starts before anyone looks ---------------------------------
# Fix round 2 (found by review): nobody offered the dead pane to the clear, and
# a replacement typed at the prompt reported working over the dead job. The
# sink's stale-job check restamped and took the pane, and no turn was filed,
# so the replacement's first reply became turn 1, the dead prompt's number.
# The sink now files the dead turn as `died_in_shell` before it restamps.
p="$(dead_agent)"; rm -f "$work/replacement.done"
type_cmd "$p" "$work/replacement"
p_ok=0; replacement_done && p_ok=1
assert_eq "$p_ok" "1" "stale: control: the replacement ran with nobody looking"
"$ROOST" wait-done --json --turn 1 "$p" 2 >"$work/s1.json" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "stale: wait-done --turn 1 is the death, exit 2"
assert_contains "$(cat "$work/s1.json")" '"outcome":"died"' "stale: ...outcome died"
"$ROOST" read --turn 1 "$p" >/dev/null 2>"$work/s1.err"
assert_contains "$(cat "$work/s1.err")" "exited inside its shell" "stale: read --turn 1 says the agent exited inside its shell"
assert_eq "$("$ROOST" read --turn 2 "$p" 2>/dev/null)" "NEW_REPLY" "stale: the replacement's reply is turn 2"
assert_eq "$(opt "$p" @roost-turn-reserved)" "" "stale: the reservation is released"
# The event log (#98): the replacement's first `working` was a repeat to the
# log's guard, so the log read dead agent working -> replacement done, one
# turn. It now has a line for the restamp, from no state, numbered turn 2.
ev="$(cat "$ROOST_RECORD_DIR"/events/* 2>/dev/null | grep "\"pane\":\"$p\"" | grep '"to":"working"' | tail -1)"
assert_contains "$ev" '"turn":2' "stale: the restamp leaves an event line for the replacement's turn 2 ($ev)"
T kill-window -t "$(win_of "$p")"
T set-environment -g ROOST_RECORD_DIR ""
export ROOST_RECORD_DIR=""

# --- send --when-idle offers the pane too -------------------------------------------
# Fix round 1 (found by review, reproduced): the when-idle hold polled only the
# badge, which a dead agent leaves at `working` for ever, so the send sat out
# the whole bound and exited 6 saying the pane "still reads working". The
# hold now offers the pane to the same check once a second.
p="$(dead_agent)"; since="$(opt "$p" @agent_since)"
T set-option -g @roost-send-idle-timeout 5
t0="$(date +%s)"
"$ROOST" send --when-idle "$p" "true" >/dev/null 2>"$work/wi.err"; rc=$?
took=$(( $(date +%s) - t0 ))
T set-option -gu @roost-send-idle-timeout
assert_eq "$rc" "0" "when-idle: a dead agent does not hold the send (stderr: $(cat "$work/wi.err"))"
[ "$took" -lt 5 ]; assert_true $? "when-idle: ...it is sent before the bound (${took}s)"
assert_eq "$(pstate "$p")" "" "when-idle: ...and the badge is unset"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "when-idle: ...as died"
T kill-window -t "$(win_of "$p")"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
