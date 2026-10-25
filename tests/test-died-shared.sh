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

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
