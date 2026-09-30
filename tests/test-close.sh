#!/usr/bin/env bash
# tests/test-close.sh — `roost close [--force] [--json] TGT [TIMEOUT_SEC]` (#143):
# end one agent the harness's own way, then close its pane and no other.
#
# Every agent here is a stand-in written into this run's own directory. It runs
# roost's real scripts/roost-agent-state, so the badge, the reply record and
# @roost-agent-job are the ones a real harness leaves behind. What it models is
# the part a real harness owns: what it does when its exit command arrives.
#
#   exit    leaves at once, as a harness at rest does
#   dialog  stamps `blocked` instead, as a harness that asks "background work
#           is running, quit anyway?" does
#   ignore  does nothing, so the bounded wait has to run out
#
# Each line it reads goes into its own log first, so a test can prove what was
# typed into it — and, as much, what was not.
#
# The harness is named through @roost-harness, the option the identity lane
# (#141) adds. It is set by hand here: `close` must prefer it when it is set,
# and the fallback it takes when it is not is tested on its own, below.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"

# Records ON, so the test can prove closing keeps them. HOME and the XDG dirs
# point at a canary directory under this run, so nothing a hook writes can
# reach the developer's real home.
work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"          # a PATH ending in /roost: the hook acts only on those
export ROOST_RECORD_DIR="$work/rec"
export HOME="$work/canary" XDG_CONFIG_HOME="$work/canary/config" \
       XDG_STATE_HOME="$work/canary/state" XDG_DATA_HOME="$work/canary/data"
mkdir -p "$work/canary"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT

tmux -S "$s" -f /dev/null new-session -d -s main -x 200 -y 50 'ENV= exec /bin/sh'
export ROOST_SOCKET="$s"
unset TMUX TMUX_PANE
T() { tmux -S "$s" "$@"; }
state() { T display-message -p -t "$1" '#{@agent_state}' 2>/dev/null; }
# alive PANE -> 0 while the pane exists. list-panes -a, not display-message:
# tmux 3.6 answers display-message for a gone pane with exit 0 and empty
# formats (see record_for in bin/roost).
alive() { T list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$1"; }
win_alive() { T list-windows -a -F '#{window_id}' 2>/dev/null | grep -qx "$1"; }
sess_alive() { T has-session -t "=$1" 2>/dev/null; }

cat > "$work/agent" <<EOF
#!/bin/sh
# agent MODE TAG — see the header of tests/test-close.sh.
MODE="\$1"; LOG="$work/log.\$2"
: > "\$LOG"
"$HOOK" working </dev/null
printf '{"last_assistant_message":"HELLO-%s"}' "\$2" | "$HOOK" done --stop-hook
echo READY
while IFS= read -r line; do
  [ -n "\$line" ] || continue
  printf '%s\n' "\$line" >> "\$LOG"
  case "\$line" in
    /exit)
      case "\$MODE" in
        exit) exit 0 ;;
        dialog) "$HOOK" blocked </dev/null ;;
      esac ;;
    work) "$HOOK" working </dev/null ;;
    block) "$HOOK" blocked </dev/null ;;
  esac
done
EOF
chmod +x "$work/agent"

# settle PANE -> wait, bounded, until the stand-in is at rest and badged done.
settle() {
  local n=100
  while [ "$n" -gt 0 ]; do
    T capture-pane -p -t "$1" 2>/dev/null | grep -q READY && [ "$(state "$1")" = done ] && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}
# wait_state PANE STATE — bounded.
wait_state() {
  local n=100
  while [ "$n" -gt 0 ]; do
    [ "$(state "$1")" = "$2" ] && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}
# agent_win MODE TAG -> %N of a new window whose pane IS the stand-in, the way
# `roost spawn NAME CMD` starts an agent.
agent_win() {
  local p
  p="$(T new-window -d -P -F '#{pane_id}' "exec /bin/sh $work/agent $1 $2")"
  require_pane "$p" "agent $2"
  T set-option -p -t "$p" @roost-harness claude
  settle "$p" || { printf '  FAIL: stand-in %s never settled\n' "$2"; exit 1; }
  printf '%s' "$p"
}
# agent_in_shell MODE TAG -> %N of a new window running an INTERACTIVE shell,
# with the stand-in typed at its prompt. This is the roost-pane-shell shape: a
# wired pane starts a login shell and the agent is a job of it, so when the
# agent leaves, the shell is left holding the pane.
agent_in_shell() {
  local p
  # HISTFILE off: an interactive shell writes its history into HOME, and the
  # canary at the end of this file counts that as a leak.
  p="$(T new-window -d -P -F '#{pane_id}' 'ENV= HISTFILE=/dev/null exec /bin/sh -i')"
  require_pane "$p" "shell for $2"
  T set-option -p -t "$p" @roost-harness claude
  sleep 0.3
  T send-keys -t "$p" "$work/agent $1 $2" Enter
  settle "$p" || { printf '  FAIL: stand-in %s never settled\n' "$2"; exit 1; }
  printf '%s' "$p"
}
# run_close ARGS... -> $rc, $out, $err
run_close() {
  "$ROOST" close "$@" >"$work/out" 2>"$work/err"; rc=$?
  out="$(cat "$work/out")"; err="$(cat "$work/err")"
}
logged() { cat "$work/log.$1" 2>/dev/null; }

# --- a clean close: the agent is the pane's own process -----------------------
p="$(agent_win exit clean)"
w="$(T display-message -p -t "$p" '#{window_id}')"
run_close "$p"
assert_eq "$rc" "0" "clean close: exit 0"
assert_eq "$(logged clean)" "/exit" "clean close: the harness's own exit command was typed, once"
alive "$p"; assert_eq "$?" "1" "clean close: the pane is gone"
win_alive "$w"; assert_eq "$?" "1" "clean close: its window, which held only it, is gone"
sess_alive main; assert_true $? "clean close: the session is still there"
assert_contains "$out" "$p" "clean close: stdout names the pane it closed"

# --- the pane record survives the close -----------------------------------------
# `roost forget` is the only thing that deletes a record. A close that took the
# kept replies with it would make #57 impossible.
rec_read="$("$ROOST" read "$p" 2>/dev/null)"
assert_eq "$rec_read" "HELLO-clean" "record kept: a closed pane's last reply still reads back"
n="$(find "$ROOST_RECORD_DIR" -type d -name "${p#%}" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$n" "1" "record kept: its record directory is still on disk"

# --- a clean close at a shell prompt: a shell is left holding the pane ----------
p="$(agent_in_shell exit shell)"
[ -n "$(T show-options -pqv -t "$p" @roost-agent-job)" ]
assert_true $? "shell: control — the sink recorded the agent's job"
run_close "$p"
assert_eq "$rc" "0" "shell: exit 0 once the agent has left its shell"
assert_eq "$(logged shell)" "/exit" "shell: the exit command was typed"
alive "$p"; assert_eq "$?" "1" "shell: the pane, shell and all, is closed"

# --- ...and with no record: the pane's foreground job at the time of the close --
p="$(agent_in_shell exit norec)"
T set-option -pu -t "$p" @roost-agent-job
run_close "$p"
assert_eq "$rc" "0" "no record: exit 0, judged by the foreground job it saw"
alive "$p"; assert_eq "$?" "1" "no record: the pane is closed"

# --- refuse working, and refuse blocked ---------------------------------------
p="$(agent_win exit busy)"
T send-keys -t "$p" work Enter; wait_state "$p" working
run_close "$p"
assert_eq "$rc" "1" "working: refused with exit 1"
assert_contains "$err" "working" "working: the refusal says why"
assert_contains "$err" "--force" "working: ...and names the way past it"
alive "$p"; assert_true $? "working: the pane is still there"
assert_eq "$(logged busy)" "work" "working: nothing was typed into it"
assert_eq "$out" "" "working: nothing on stdout"

p2="$(agent_win exit blk)"
T send-keys -t "$p2" block Enter; wait_state "$p2" blocked
run_close "$p2"
assert_eq "$rc" "1" "blocked: refused with exit 1"
assert_contains "$err" "blocked" "blocked: the refusal says why"
alive "$p2"; assert_true $? "blocked: the pane is still there"
assert_eq "$(logged blk)" "block" "blocked: nothing was typed into the dialog"

# --- --force: no exit command, the pane is closed -------------------------------
run_close --force "$p"
assert_eq "$rc" "0" "--force working: exit 0"
alive "$p"; assert_eq "$?" "1" "--force working: the pane is closed"
assert_eq "$(logged busy)" "work" "--force working: the exit command was skipped"
run_close --force "$p2"
assert_eq "$rc" "0" "--force blocked: exit 0"
alive "$p2"; assert_eq "$?" "1" "--force blocked: the pane is closed"
assert_eq "$(logged blk)" "block" "--force blocked: nothing was typed into the dialog"

# --- blocked WHILE closing: an exit dialog is reported, never answered ---------
p="$(agent_win dialog dlg)"
run_close "$p" 10
assert_eq "$rc" "1" "exit dialog: exit 1"
assert_contains "$err" "blocked" "exit dialog: says the pane went blocked"
alive "$p"; assert_true $? "exit dialog: the pane is left open for a human"
assert_eq "$(logged dlg)" "/exit" "exit dialog: the dialog was not answered"
T kill-pane -t "$p"

# --- the bounded wait runs out ---------------------------------------------------
p="$(agent_win ignore slow)"
s0=$SECONDS
run_close "$p" 1
assert_eq "$rc" "1" "timeout: exit 1"
assert_contains "$err" "timed out" "timeout: says so"
[ $((SECONDS - s0)) -le 4 ]; assert_true $? "timeout: the bound held (took $((SECONDS - s0))s)"
alive "$p"; assert_true $? "timeout: the pane is not closed behind the agent's back"
T kill-pane -t "$p"

# --- already gone ------------------------------------------------------------------
p="$(agent_win exit gone)"
T kill-pane -t "$p"
run_close "$p"
assert_eq "$rc" "2" "gone pane: exit 2"
assert_eq "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "1" "gone pane: one line on stderr"
assert_contains "$err" "gone" "gone pane: saying it is gone"
case "$err" in *"can't find"*|*"not found"*) leak=1 ;; *) leak=0 ;; esac
assert_eq "$leak" "0" "gone pane: no tmux error leaks through"
run_close "nosuchwindow"
assert_eq "$rc" "2" "gone window name: exit 2"
assert_eq "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "1" "gone window name: one line on stderr"

# --- a window target: one pane is taken, more than one is refused --------------
p="$(agent_win exit named)"
T rename-window -t "$p" solo-agent
run_close solo-agent
assert_eq "$rc" "0" "window target, one pane: closed"
alive "$p"; assert_eq "$?" "1" "window target, one pane: that pane is gone"

p="$(agent_win exit pair)"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$p" 'exec sleep 600')"
require_pane "$sib" "sibling"
w="$(T display-message -p -t "$p" '#{window_id}')"
run_close "$w"
assert_eq "$rc" "1" "window target, two panes: refused"
assert_contains "$err" "%" "window target, two panes: the refusal asks for a %N"
alive "$p" && alive "$sib"; assert_true $? "window target, two panes: both panes are still there"
assert_eq "$(logged pair)" "" "window target, two panes: nothing was typed"

# --- the sibling pane is kept ----------------------------------------------------
run_close "$p"
assert_eq "$rc" "0" "sibling: closing one pane of two exits 0"
alive "$p"; assert_eq "$?" "1" "sibling: the named pane is gone"
alive "$sib"; assert_true $? "sibling: the other pane is still there"
win_alive "$w"; assert_true $? "sibling: so is the window"
T kill-pane -t "$sib"

# --- never the session: its last pane is refused -----------------------------
T new-session -d -s lone -x 200 -y 50 "exec /bin/sh $work/agent exit lone"
lp="$(T list-panes -t '=lone:' -F '#{pane_id}')"
T set-option -p -t "$lp" @roost-harness claude
settle "$lp"
run_close "$lp"
assert_eq "$rc" "1" "last pane of a session: refused"
assert_contains "$err" "roost kill" "last pane of a session: names the command that ends a session"
sess_alive lone; assert_true $? "last pane of a session: the session is still there"
assert_eq "$(logged lone)" "" "last pane of a session: nothing was typed"
T kill-session -t '=lone'

# --- a pane with no badge is not an agent: nothing to ask, just closed ----------
p="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
run_close "$p"
assert_eq "$rc" "0" "no badge: closed"
alive "$p"; assert_eq "$?" "1" "no badge: the pane is gone"

# --- a dead pane (remain-on-exit) is closed ------------------------------------
# Started on a long sleep, not on `exit 0`: tmux 3.4 had already closed a pane
# that ran `exit 0` before the set-option below could reach it, and the case
# then tested a pane that was gone (found by review, ubuntu 24.04). The
# respawn-pane after remain-on-exit is what makes the pane dead.
p="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
require_pane "$p" "dead pane"
T set-option -p -t "$p" remain-on-exit on 2>/dev/null || T set-option -w -t "$p" remain-on-exit on
T respawn-pane -k -t "$p" 'exit 0'
n=50; while [ "$(T display-message -p -t "$p" '#{pane_dead}')" != 1 ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
T set-option -p -t "$p" @agent_state done
run_close "$p"
assert_eq "$rc" "0" "dead pane: closed"
alive "$p"; assert_eq "$?" "1" "dead pane: the pane is gone"

# --- a harness with no exit command is refused by name ----------------------------
p="$(agent_win exit unk)"
T set-option -p -t "$p" @roost-harness nosuchharness
run_close "$p"
assert_eq "$rc" "1" "unknown harness: refused"
assert_contains "$err" "'nosuchharness'" "unknown harness: named in the refusal"
alive "$p"; assert_true $? "unknown harness: the pane is still there"
assert_eq "$(logged unk)" "" "unknown harness: nothing was typed"
# Nothing to go on: no option, a shell's process name, and a name a human
# chose. (The sink labels an unnamed pane "claude", so the name is set here.)
T set-option -pu -t "$p" @roost-harness
T set-option -p -t "$p" @roost-name mystery
run_close "$p"
assert_eq "$rc" "1" "unidentified harness: refused too"
run_close --force "$p"
assert_eq "$rc" "0" "unknown harness: --force closes it"
alive "$p"; assert_eq "$?" "1" "unknown harness: ...and the pane is gone"

# --- --json -------------------------------------------------------------------
p="$(agent_win exit js)"
run_close --json "$p"
assert_eq "$rc" "0" "--json: exit 0"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "--json: one line"
assert_eq "$out" "{\"schema\":1,\"command\":\"close\",\"target\":\"$p\",\"pane\":\"$p\",\"state\":\"done\",\"harness\":\"claude\",\"exit_command\":\"/exit\",\"forced\":false}" \
  "--json: the document, every field present"
p="$(agent_win exit js2)"
run_close --json --force "$p"
assert_eq "$out" "{\"schema\":1,\"command\":\"close\",\"target\":\"$p\",\"pane\":\"$p\",\"state\":\"done\",\"harness\":\"claude\",\"exit_command\":null,\"forced\":true}" \
  "--json --force: exit_command is null, forced is true"
p="$(T new-window -d -P -F '#{pane_id}' 'exec sleep 600')"
run_close --json "$p"
assert_eq "$out" "{\"schema\":1,\"command\":\"close\",\"target\":\"$p\",\"pane\":\"$p\",\"state\":null,\"harness\":null,\"exit_command\":null,\"forced\":false}" \
  "--json, no badge: the unknown fields are null, not missing"
run_close --json "%9999"
assert_eq "$rc" "2" "--json, gone: exit 2"
assert_eq "$out" "" "--json, gone: nothing on stdout"
p="$(agent_win exit js3)"
T send-keys -t "$p" work Enter; wait_state "$p" working
run_close --json "$p"
assert_eq "$rc" "1" "--json, refused: exit 1"
assert_eq "$out" "" "--json, refused: nothing on stdout"
T kill-pane -t "$p"

# --- a stale `blocked` badge is cleared, then the agent is still asked --------
# A Claude dialog that was declined fires no event, so its `blocked` outlives
# it (#38). roost_unblock_pane clears such a badge by UNSETTING @agent_state,
# and the pane is still an agent at rest: it must be sent its exit command,
# not killed as if it had no badge. The stamp is the one
# tests/test-claude-decline.sh makes, with the same captured transcript.
cp "$HERE/tests/fixtures/claude-transcript-no.jsonl" "$work/no.jsonl"
p="$(agent_win exit declined)"
T set-option -p -t "$p" @agent_since 1789398932
T set-option -p -t "$p" @agent_state blocked
T set-option -p -t "$p" @roost-transcript "1789398932 $work/no.jsonl"
run_close --json "$p"
assert_eq "$rc" "0" "declined dialog: exit 0"
assert_eq "$(logged declined)" "/exit" "declined dialog: the agent was still asked to exit"
assert_eq "$out" "{\"schema\":1,\"command\":\"close\",\"target\":\"$p\",\"pane\":\"$p\",\"state\":\"blocked\",\"harness\":\"claude\",\"exit_command\":\"/exit\",\"forced\":false}" \
  "declined dialog: the document keeps the badge it saw, not null"
alive "$p"; assert_eq "$?" "1" "declined dialog: the pane is gone"

# --- close kills that PANE: a sibling survives the kill itself -----------------
# In the sibling case above the agent closes its own pane on /exit, so close's
# own kill hits nothing and a kill of the whole window would go unseen. These
# two make close's kill land on a live pane with a sibling beside it.
p="$(agent_win exit forcesib)"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$p" 'exec sleep 600')"
require_pane "$sib" "sibling of a forced pane"
w="$(T display-message -p -t "$p" '#{window_id}')"
run_close --force "$p"
assert_eq "$rc" "0" "--force beside a sibling: exit 0"
alive "$p"; assert_eq "$?" "1" "--force beside a sibling: the named pane is gone"
alive "$sib"; assert_true $? "--force beside a sibling: the sibling is still there"
win_alive "$w"; assert_true $? "--force beside a sibling: so is the window"
T kill-pane -t "$sib"

p="$(agent_in_shell exit shellsib)"
sib="$(T split-window -d -P -F '#{pane_id}' -t "$p" 'exec sleep 600')"
require_pane "$sib" "sibling of a shell pane"
w="$(T display-message -p -t "$p" '#{window_id}')"
run_close "$p"
assert_eq "$rc" "0" "shell beside a sibling: exit 0"
assert_eq "$(logged shellsib)" "/exit" "shell beside a sibling: the exit command was typed"
alive "$p"; assert_eq "$?" "1" "shell beside a sibling: the named pane is gone"
alive "$sib"; assert_true $? "shell beside a sibling: the sibling is still there"
win_alive "$w"; assert_true $? "shell beside a sibling: so is the window"
T kill-pane -t "$sib"

# --- a leftover badge on a bare shell: closed, and nothing typed ---------------
# No job is recorded and the shell itself holds the terminal, so no agent is
# there to ask. Typing /exit would run it as a shell command and then wait out
# the whole bound. Found by review.
p="$(T new-window -d -P -F '#{pane_id}' 'ENV= HISTFILE=/dev/null exec /bin/sh -i')"
require_pane "$p" "bare shell"
sleep 0.3
T set-option -p -t "$p" @agent_state done
T set-option -p -t "$p" @roost-harness claude
s0=$SECONDS
run_close --json "$p" 5
assert_eq "$rc" "0" "bare shell: exit 0"
[ $((SECONDS - s0)) -le 2 ]; assert_true $? "bare shell: at once, not after the bound (took $((SECONDS - s0))s)"
assert_contains "$out" "\"exit_command\":null" "bare shell: nothing was typed"
alive "$p"; assert_eq "$?" "1" "bare shell: the pane is gone"

# --- extra arguments are refused, not ignored ----------------------------------
p="$(agent_win exit extra)"
run_close "$p" 5 "$p"
assert_eq "$rc" "1" "extra arguments: refused"
assert_contains "$err" "usage: roost close" "extra arguments: a usage line"
alive "$p"; assert_true $? "extra arguments: the pane is still there"
assert_eq "$(logged extra)" "" "extra arguments: nothing was typed"
T kill-pane -t "$p"

# --- usage ---------------------------------------------------------------------
run_close
assert_eq "$rc" "1" "no target: exit 1"
assert_contains "$err" "usage: roost close" "no target: a usage line"
run_close "%1" abc
assert_eq "$rc" "1" "bad TIMEOUT_SEC: exit 1"
assert_contains "$err" "TIMEOUT_SEC" "bad TIMEOUT_SEC: says which argument"

# --- the harness lookup and the exit-command table -------------------------------
# Unit-level: these are the facts a real pane cannot be made to show in CI
# (a real harness is not installed there), so they are pinned on the lib.
. "$HERE/scripts/lib/roost-close.sh"
h() { roost_close_harness "$1" "$2" "$3"; printf '%s' "$ROOST_CLOSE_HARNESS"; }
assert_eq "$(h '' 2.1.283 '')" "claude" "lookup: Claude Code's version-string process name is claude"
assert_eq "$(h '' codex my-reviewer)" "codex" "lookup: codex by its process name"
assert_eq "$(h '' opencode '')" "opencode" "lookup: opencode by its process name"
assert_eq "$(h '' copilot '')" "copilot" "lookup: copilot by its process name"
assert_eq "$(h '' node pi)" "pi" "lookup: node is ambiguous, so the pane name decides"
assert_eq "$(h '' node copilot)" "copilot" "lookup: ...either way"
assert_eq "$(h '' node my-dev-server)" "" "lookup: node under any other name is unknown"
assert_eq "$(h '' bash claude)" "claude" "lookup: the pane name when the process says nothing"
assert_eq "$(h codex 2.1.283 claude)" "codex" "lookup: @roost-harness wins over both"
e() { roost_close_exit_command "$1" && printf '%s' "$ROOST_CLOSE_EXIT" || printf 'NONE'; }
assert_eq "$(e claude)" "/exit" "table: claude exits with /exit"
assert_eq "$(e codex)" "/quit" "table: codex exits with /quit"
assert_eq "$(e opencode)" "/exit" "table: opencode exits with /exit"
assert_eq "$(e copilot)" "/exit" "table: copilot exits with /exit"
assert_eq "$(e pi)" "/quit" "table: pi exits with /quit"
assert_eq "$(e nosuchharness)" "NONE" "table: a harness not in it has no entry"

# --- the canary -------------------------------------------------------------
found="$(find "$work/canary" -mindepth 1 2>/dev/null | head -n 3)"
assert_eq "$found" "" "nothing was written into HOME/XDG during this file"
