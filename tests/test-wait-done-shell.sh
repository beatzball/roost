#!/usr/bin/env bash
# `roost wait-done` on an agent typed at a shell prompt that then dies (#64).
#
# Measured on tmux 3.6 before this fix, with a stand-in agent and with a real
# Claude Code killed mid-turn: the pane stays alive at its prompt, pane_dead
# stays 0, no hook rewrites the badge, and wait-done waited out its whole
# timeout and exited 1 — a caller could not tell "timed out" from "died".
#
# The fix (docs/airig/specs/2026-09-15-agent-identity-design.md) records the
# pane terminal's FOREGROUND JOB when the hook stamps a busy state, and calls
# the pane died only when that job has no process left AND the pane's shell
# holds the terminal again. Everything here runs the real sink,
# scripts/roost-agent-state, from inside a real interactive /bin/sh, because
# job control is the whole mechanism: a shell without it creates no job.
#
# The stand-in agents stamp through the sink as a CHILD, the way every
# measured harness reaches it (Claude and codex run the hook as a child
# process; opencode, pi and copilot run `roost state` as one). None of them
# leads the foreground job itself.
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
      ps -A -o pgid=,command= | awk -v g="$g" -v w="$work/" '$1 == g && index($0, w)' | grep -q . \
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
# agent: stamps working through the sink, then works. `exec sleep` keeps the
#   script's pid, so the job is exactly one process.
cat > "$work/agent" <<EOF
#!/bin/sh
ps -o pgid= -p \$\$ | tr -d ' ' >> "$work/jobs"
"$SINK" working </dev/null
echo "\$\$" > "$work/agent.pid"
exec "$work/idle"
EOF
# outliver: a wrapper that runs the agent as a child and keeps running after it
#   dies — one of the two cases the design says it misses.
cat > "$work/outliver" <<EOF
#!/bin/sh
"$work/agent"
exec "$work/idle"
EOF
# restarter: stamps, starts its replacement as a child, and exits — a stand-in
#   for a harness that restarts itself. The job lives on in the child.
cat > "$work/restarter" <<EOF
#!/bin/sh
ps -o pgid= -p \$\$ | tr -d ' ' >> "$work/jobs"
"$SINK" working </dev/null
"$work/idle" &
sleep 1
exit 0
EOF
# idle: the stand-ins' long-running work. A script under $work, not a bare
# `sleep`, so its command line (`/bin/sh <dir>/w/idle`) names this run and
# cleanup can tell it is ours. A loop of short sleeps rather than one `exec
# sleep`, which would replace that command line with sleep's own.
cat > "$work/idle" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod +x "$work/agent" "$work/outliver" "$work/restarter" "$work/idle"

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

# --- the record ---------------------------------------------------------------
p="$(shell_pane)"
type_cmd "$p" "$work/agent"
wait_state "$p" working; assert_true $? "record: the stand-in agent stamped working from inside the shell"
wait_record "$p"; assert_true $? "record: a busy stamp from a job at a shell prompt records the foreground job"
assert_eq "$(record "$p")" "$(fg_job "$p"):$(pane_pid "$p")" "record: ...as PGID:PANE_PID of the job holding the terminal"
[ "$(fg_job "$p")" != "$(pane_pid "$p")" ]; assert_true $? "record: control — the job really is not the shell itself"

# --- killed inside a shell: died, promptly -------------------------------------
s=$SECONDS; bg_wait "$p" 20 kill; bgpid=$!
sleep 1.5; kill -9 -- "-$(pgid_of_record "$p")"
bg_result "$bgpid" kill
assert_eq "$rc" "2" "an agent killed inside a shell: wait-done on the pane exits 2"
[ $((SECONDS - s)) -le 5 ]; assert_true $? "...promptly, not after its 20s timeout (took $((SECONDS - s))s)"
assert_contains "$err" "died: " "...saying it died"
assert_contains "$err" "working" "...and what it last read"
assert_contains "$err" "terminal" "...and why: the shell has its terminal back"
assert_eq "$(fg_job "$p")" "$(pane_pid "$p")" "control: the shell really holds the terminal again"
assert_eq "$(T display-message -p -t "$p" '#{pane_dead}')" "0" "control: the pane itself is alive, as #54 could not see"

# Already dead when wait-done starts: the same answer at once.
s=$SECONDS; err="$("$ROOST" wait-done "$p" 10 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "an agent that died inside a shell before the wait: exits 2"
[ $((SECONDS - s)) -le 2 ]; assert_true $? "...at once"

# Window target, beside a live sibling agent that keeps the window busy.
w="$(win_of "$p")"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$p" 'ENV= exec /bin/sh -i')"
type_cmd "$sib" "$work/agent"; wait_record "$sib"
s=$SECONDS; err="$("$ROOST" wait-done "$w" 10 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "2" "a WINDOW holding an agent that died inside a shell exits 2"
[ $((SECONDS - s)) -le 2 ]; assert_true $? "...at once"
assert_contains "$err" "$p" "...naming the pane that died, not its live sibling"
T kill-window -t "$w"

p="$(shell_pane)"; w="$(win_of "$p")"
type_cmd "$p" "$work/agent"; wait_record "$p"
s=$SECONDS; bg_wait "$w" 20 killw; bgpid=$!
sleep 1.5; kill -TERM -- "-$(pgid_of_record "$p")"
bg_result "$bgpid" killw
assert_eq "$rc" "2" "a WINDOW whose agent is killed (SIGTERM) inside a shell mid-wait exits 2"
[ $((SECONDS - s)) -le 5 ]; assert_true $? "...promptly"
T kill-window -t "$w"

# A pane that read done before its agent exited keeps its old answer.
p="$(shell_pane)"
type_cmd "$p" "$work/agent"; wait_record "$p"
T set-option -p -t "$p" @agent_state done
kill -9 -- "-$(pgid_of_record "$p")"; wait_shell_fg "$p"
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1
assert_eq "$?" "0" "an agent that finished and then exited in its shell still exits 0"
T kill-window -t "$(win_of "$p")"

# --- live agents must never read as died ----------------------------------------
# Each of these is a busy pane whose agent is alive; a 2-second wait must time
# out with exit 1, never exit 2.
expect_timeout() { # PANE LABEL
  local e r
  e="$("$ROOST" wait-done "$1" 2 2>&1 >/dev/null)"; r=$?
  assert_eq "$r" "1" "$2: times out with exit 1, never died"
  assert_contains "$e" "timed out" "$2: ...saying timed out"
}

p="$(shell_pane)"; type_cmd "$p" "$work/agent"; wait_record "$p"
expect_timeout "$p" "a live agent at a shell prompt"
T kill-window -t "$(win_of "$p")"

p="$(shell_pane)"; type_cmd "$p" "bash -c '$work/agent; true'"; wait_record "$p"
expect_timeout "$p" "a live agent under bash -c"
T kill-window -t "$(win_of "$p")"

p="$(shell_pane)"; type_cmd "$p" "$work/restarter"; wait_record "$p"
sleep 2   # the restarter has exited; its child holds the job
wait_shell_fg "$p"; assert_true $? "restart: control — the shell holds the terminal once the first process exits"
expect_timeout "$p" "an agent that restarted itself as a child"
T kill-window -t "$(win_of "$p")"

# One case the design misses, pinned so the limit is visible: a wrapper
# that outlives its agent keeps the job alive and keeps the terminal.
p="$(shell_pane)"; type_cmd "$p" "$work/outliver"; wait_record "$p"
apid="$(cat "$work/agent.pid")"
kill -9 "$apid"
n=30; while kill -0 "$apid" 2>/dev/null && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
kill -0 "$apid" 2>/dev/null; assert_eq "$?" "1" "outliver: control — the agent itself really is dead"
kill -0 -- "-$(pgid_of_record "$p")"; assert_true $? "outliver: control — its wrapper still holds the job"
expect_timeout "$p" "an agent whose wrapper outlives it (the documented miss)"
T kill-window -t "$(win_of "$p")"

# A stale record from an earlier agent, with a newer job holding the terminal:
# the newer job may be an agent that has not stamped yet, so it is not a death.
p="$(shell_pane)"; type_cmd "$p" "$work/agent"; wait_record "$p"
old="$(record "$p")"
kill -9 -- "-$(pgid_of_record "$p")"; wait_shell_fg "$p"
type_cmd "$p" "$work/idle"
n=50; while [ "$(fg_job "$p")" = "$(pane_pid "$p")" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
assert_eq "$(record "$p")" "$old" "stale: control — the old record is still in place"
expect_timeout "$p" "a stale record while a newer job holds the terminal"
T kill-window -t "$(win_of "$p")"

# respawn-pane -k keeps pane options but starts a new pane process: the record
# names the old one and must be ignored.
p="$(shell_pane)"; type_cmd "$p" "$work/agent"; wait_record "$p"
T respawn-pane -k -t "$p" 'ENV= exec /bin/sh -i'
sleep 0.5
assert_contains "$(record "$p")" ":" "respawn: control — the record survived the respawn"
expect_timeout "$p" "a record left over from before respawn-pane"
T kill-window -t "$(win_of "$p")"

# --- no record: exactly #54's behaviour -----------------------------------------
# The agent IS the pane's command: its job is the pane process itself.
p="$(T new-window -d -P -F '#{pane_id}' "$work/agent")"
wait_state "$p" working
assert_eq "$(record "$p")" "" "no record when the agent is the pane's own command"

# `roost state working` typed at the prompt: the stamp's own process leads the
# foreground job and exits at once, so it names no agent.
p="$(shell_pane)"; type_cmd "$p" "$ROOST state working"; wait_state "$p" working
sleep 0.5
assert_eq "$(record "$p")" "" "no record when the stamp itself was typed at the prompt"
expect_timeout "$p" "a hand-typed roost state working"
T kill-window -t "$(win_of "$p")"

# An agent started in the background with &: the shell keeps the terminal.
p="$(shell_pane)"; type_cmd "$p" "$work/agent &"; wait_state "$p" working
sleep 0.5
assert_eq "$(record "$p")" "" "no record for an agent started with &"
T kill-window -t "$(win_of "$p")"

# A shell without job control runs the agent in its own process group.
p="$(T new-window -d -P -F '#{pane_id}' "ENV= exec /bin/sh -c '$work/agent'")"
wait_state "$p" working
assert_eq "$(record "$p")" "" "no record when the pane's shell has no job control"
T kill-window -t "$(win_of "$p")"

# A busy stamp from a pane that later reads done clears nothing it should not:
# a pane with no record at all times out exactly as before.
p="$(shell_pane)"; T set-option -p -t "$p" @agent_state working
expect_timeout "$p" "a busy pane with no record"
T kill-window -t "$(win_of "$p")"

true
