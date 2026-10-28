#!/usr/bin/env bash
# tests/test-stop-confirm.sh — a bare `roost stop` / `kill` / `down` asks
# before it ends the whole server (#207).
#
# The bare form is `kill-server`: every session and every agent on it ends.
# "stop" reads like a fix for one stuck pane, so on a terminal it now prints
# what will end and waits for `y`; off a terminal it refuses unless `--yes`.
# `roost kill NAME` names one session and is unchanged.
#
# Two kinds of throwaway server, never the live one:
#
#   the DRIVER  roost_test_server from tests/lib.sh. Its panes are the real
#               ptys the terminal cases type into: `[ -t 0 ]` and `[ -t 2 ]`
#               are only true on a real terminal, so a pipe cannot stand in.
#   a TARGET    one fresh server per case, at $work/xN/s, which the command
#               under test is pointed at through $ROOST_SOCKET. A case that
#               stops it ends only that server, never the driver pane that
#               typed the command, so the pane stays there to be read.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"

# HOME and every harness home at a canary nothing may write to (the shape of
# tests/test-install.sh). Nothing here should write at all; the canary is what
# proves it rather than an assumption. Exported BEFORE the driver server
# starts, so its panes inherit the same redirects.
work="$(mktemp -d /tmp/amx.XXXX)"
CANARY="$work/canary"
mkdir -p "$CANARY"
export HOME="$CANARY" XDG_CONFIG_HOME="$CANARY/config" \
       XDG_STATE_HOME="$CANARY/state" XDG_DATA_HOME="$CANARY/data" \
       CLAUDE_SETTINGS="$CANARY/claude-settings.json" CODEX_HOME="$CANARY/codex" \
       COPILOT_HOME="$CANARY/copilot" PI_CODING_AGENT_DIR="$CANARY/pi"
unset ZDOTDIR TMUX TMUX_PANE ROOST_SOCKET ROOST_SELF_SOCK || true
# The driver panes' shell is macOS /bin/sh, which is bash, and an interactive
# bash writes ~/.bash_history when it exits. That is the shell, not roost, so
# its history goes to the run's own directory rather than tripping the canary.
export HISTFILE="$work/history"

roost_test_server
targets=""
cleanup() {
  for x in $targets; do tmux -S "$x" kill-server 2>/dev/null; done
  roost_test_teardown
  rm -rf "$work"
}
trap cleanup EXIT

# mk_target N — start target server N with two sessions, three panes, and two
# of those panes stamped as agents, so the count reads "2 agents in 2
# sessions". An agent pane is one with @agent_state set: the same test the
# `roost status` listing uses for its [state] column.
n=0
mk_target() {
  n=$((n+1))
  X="$work/x$n/s"
  mkdir -p "$work/x$n"
  targets="$targets $X"
  tmux -S "$X" -f /dev/null new-session -d -s alpha -x 120 -y 30 'ENV= exec /bin/sh'
  tmux -S "$X" new-session -d -s beta -x 120 -y 30 'ENV= exec /bin/sh'
  tmux -S "$X" split-window -d -t '=alpha:' 'ENV= exec /bin/sh'
  tmux -S "$X" set -p -t '=alpha:.0' @agent_state working
  tmux -S "$X" set -p -t '=beta:.0' @agent_state done
}
alive() { tmux -S "$1" has-session 2>/dev/null && echo alive || echo gone; }

# wait_screen PANE TEXT — poll the driver pane's screen for TEXT, bounded at
# 10 s, and print the screen either way so a failing assert shows it.
wait_screen() {
  local i=0 scr
  while [ $i -lt 100 ]; do
    scr="$(T capture-pane -p -t "$1" 2>/dev/null)"
    case "$scr" in *"$2"*) break ;; esac
    sleep 0.1; i=$((i+1))
  done
  printf '%s' "$scr"
}
# wait_file F — bounded at 10 s; prints the file's contents (the exit code).
wait_file() {
  local i=0
  while [ $i -lt 100 ] && [ ! -s "$1" ]; do sleep 0.1; i=$((i+1)); done
  cat "$1" 2>/dev/null
}

# on_tty ARGS... — open a fresh driver window, type the command into its pty,
# and wait for the question (or, with --yes, for the exit code). Sets PANE and
# RC_FILE for the caller.
on_tty() {
  PANE="$(T new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh')"
  RC_FILE="$work/rc.$n"
  T send-keys -t "$PANE" -l "ROOST_SOCKET='$X' '$ROOST' $*; echo \$? > '$RC_FILE'"
  T send-keys -t "$PANE" Enter
}

# --- tty: `n` keeps the server ----------------------------------------------
mk_target; on_tty stop
scr="$(wait_screen "$PANE" "Type y to stop the roost server:")"
assert_contains "$scr" "This ends 2 agents in 2 sessions." "tty: the question counts agents and sessions"
assert_contains "$scr" "Type y to stop the roost server:" "tty: bare stop asks"
T send-keys -t "$PANE" n Enter
rc="$(wait_file "$RC_FILE")"
assert_eq "$rc" "1" "tty n: exits 1"
assert_eq "$(alive "$X")" "alive" "tty n: server kept"
assert_contains "$(wait_screen "$PANE" "not stopped")" "roost: not stopped." "tty n: says not stopped"

# --- tty: empty input keeps the server --------------------------------------
mk_target; on_tty kill
wait_screen "$PANE" "Type y" >/dev/null
T send-keys -t "$PANE" Enter
rc="$(wait_file "$RC_FILE")"
assert_eq "$rc" "1" "tty empty: exits 1"
assert_eq "$(alive "$X")" "alive" "tty empty: server kept"

# --- tty: EOF keeps the server ----------------------------------------------
mk_target; on_tty down
wait_screen "$PANE" "Type y" >/dev/null
T send-keys -t "$PANE" C-d
rc="$(wait_file "$RC_FILE")"
assert_eq "$rc" "1" "tty EOF: exits 1"
assert_eq "$(alive "$X")" "alive" "tty EOF: server kept"

# --- tty: `y` stops it ------------------------------------------------------
mk_target; on_tty stop
wait_screen "$PANE" "Type y" >/dev/null
T send-keys -t "$PANE" y Enter
rc="$(wait_file "$RC_FILE")"
assert_eq "$rc" "0" "tty y: exits 0"
assert_eq "$(alive "$X")" "gone" "tty y: server stopped"

# --- tty: `Y` stops it too --------------------------------------------------
mk_target; on_tty stop
wait_screen "$PANE" "Type y" >/dev/null
T send-keys -t "$PANE" Y Enter
rc="$(wait_file "$RC_FILE")"
assert_eq "$(alive "$X")" "gone" "tty Y: server stopped"

# --- tty: --yes skips the question ------------------------------------------
mk_target; on_tty stop --yes
rc="$(wait_file "$RC_FILE")"
assert_eq "$rc" "0" "tty --yes: exits 0 with no answer typed"
assert_eq "$(alive "$X")" "gone" "tty --yes: server stopped"
scr="$(T capture-pane -p -t "$PANE")"
case "$scr" in *"Type y"*) asked=yes ;; *) asked=no ;; esac
assert_eq "$asked" "no" "tty --yes: no question shown"

# --- not a tty, no --yes: refused -------------------------------------------
for verb in stop kill down; do
  mk_target
  out="$(ROOST_SOCKET="$X" "$ROOST" "$verb" </dev/null 2>&1)"; rc=$?
  assert_eq "$rc" "1" "no tty, $verb: exits 1"
  assert_eq "$(alive "$X")" "alive" "no tty, $verb: server kept"
  assert_contains "$out" "This ends 2 agents in 2 sessions." "no tty, $verb: prints the count"
  assert_contains "$out" "roost $verb --yes" "no tty, $verb: names the --yes form"
done

# --- not a tty, --yes / -y: stopped -----------------------------------------
for flag in --yes -y; do
  mk_target
  out="$(ROOST_SOCKET="$X" "$ROOST" stop "$flag" </dev/null 2>&1)"; rc=$?
  assert_eq "$rc" "0" "no tty, $flag: exits 0"
  assert_eq "$(alive "$X")" "gone" "no tty, $flag: server stopped"
  assert_contains "$out" "roost: server stopped (all sessions)." "no tty, $flag: today's message"
done

# --- kill NAME: one session, no prompt, unchanged ---------------------------
mk_target
out="$(ROOST_SOCKET="$X" "$ROOST" kill alpha </dev/null 2>&1)"; rc=$?
assert_eq "$rc" "0" "kill NAME: exits 0"
assert_eq "$out" "roost: session 'alpha' killed." "kill NAME: today's message, nothing else"
assert_eq "$(tmux -S "$X" has-session -t '=beta' 2>/dev/null && echo yes)" "yes" "kill NAME: the other session survives"
assert_eq "$(tmux -S "$X" has-session -t '=alpha' 2>/dev/null && echo yes || echo no)" "no" "kill NAME: the named session is gone"
out="$(ROOST_SOCKET="$X" "$ROOST" kill nosuch </dev/null 2>&1)"
assert_eq "$out" "roost: no session 'nosuch'." "kill NAME: a missing session, today's message"
out="$(ROOST_SOCKET="$X" "$ROOST" kill --yes beta </dev/null 2>&1)"
assert_eq "$out" "roost: session 'beta' killed." "kill --yes NAME: --yes accepted and ignored"

# A session named on a tty is not asked about either.
mk_target; on_tty kill beta
rc="$(wait_file "$RC_FILE")"
assert_eq "$rc" "0" "tty kill NAME: no question, exits 0"
assert_eq "$(tmux -S "$X" has-session -t '=alpha' 2>/dev/null && echo yes)" "yes" "tty kill NAME: the other session survives"

# --- server not running: today's message ------------------------------------
X="$work/none/s"; mkdir -p "$work/none"
out="$(ROOST_SOCKET="$X" "$ROOST" stop </dev/null 2>&1)"; rc=$?
assert_eq "$out" "roost: not running." "not running: today's message, no question"
assert_eq "$rc" "0" "not running: exits 0, as today"

# --- the canary -------------------------------------------------------------
found="$(find "$CANARY" -mindepth 1 2>/dev/null | head -n 3)"
assert_eq "$found" "" "nothing was written into HOME/XDG during this file"
