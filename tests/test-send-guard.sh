#!/usr/bin/env bash
# Every editor is inert and records the exact bytes it would interpret as keys.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
. "$HERE/scripts/lib/roost-send-guard.sh"
work="$(mktemp -d /tmp/amx.XXXX)"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state"
export CODEX_HOME="$work/codex-home" COPILOT_HOME="$work/copilot" PI_CODING_AGENT_DIR="$work/pi"
export CLAUDE_SETTINGS="$work/claude/settings.json" CLAUDE_CONFIG_DIR="$work/claude"
unset ZDOTDIR NO_COLOR TMUX TMUX_PANE ROOST_SOCKET ROOST_SELF_SOCK
mkdir -p "$HOME"
sender="" holder=""
trap '[ -z "$sender" ] || kill "$sender" 2>/dev/null; [ -z "$holder" ] || kill "$holder" 2>/dev/null; roost_test_teardown; rm -rf "$work"' EXIT
roost_test_server || exit 1
export ROOST_SOCKET="$ROOST_TEST_SOCK"
T set-option -g @roost-send-enter-delay 0.1
T set-option -g @roost-send-idle-timeout 8
T set-option -g @roost-send-ready-timeout 1
T set-option -g @roost-send-lock-timeout 8

# Give the process a distinctive executable basename on both ps variants.
# Its child reports identity as a harness hook would, using the real writer
# and the ancestry walk. Copying a system binary to rename it can make macOS
# refuse to run it, so build a small launcher and keep it in the test directory.
if ! command -v cc >/dev/null 2>&1; then
  echo '  SKIP: the guarded send process fixture needs a C compiler'
  exit 0
fi
cat > "$work/launcher.c" <<'C'
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        execv(argv[1], argv + 1);
        _exit(127);
    }
    int status;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
C
cc -o "$work/codex" "$work/launcher.c" && cp "$work/codex" "$work/node" || exit 1
cat > "$work/editor" <<'SH'
if [ "$3" != none ]; then
  /bin/bash -c '. "$1/scripts/lib/roost-identity.sh"; roost_identity_stamp "$ROOST_TEST_SOCK" "$TMUX_PANE" shared-session "$2" "$3" ""' \
    reporter "$1" "$2" "$3"
fi
ROOST_TEST_INPUT_HARNESS=codex ROOST_TEST_INPUT_BRACKETS="${4:-1}" python3 "$1/tests/fixtures/input-box.py" "$2"
exit $?
SH
cat > "$work/job-shell" <<'SH'
set -m
"$1" /bin/bash "$2" "$3" "$4" "$5"
if [ "$6" = handoff ]; then
  "$1" /bin/bash "$2" "$3" "$4-replacement" none
fi
printf '\nshell returned\n'
IFS= read -r unused
SH

wait_for() {
  local n
  for ((n=0; n<120; n++)); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}
screen_has() { T capture-pane -p -t "$1" 2>/dev/null | grep -Fq "$2"; }
launch() {
  local name="$1" draft="$2" harness="${3:-codex}" exe="${4:-codex}" into="${5:-}"
  local cmd="exec '$work/$exe' /bin/bash '$work/editor' '$HERE' '$work/$name' '$harness'"
  case "${6:-}" in
    handoff) cmd="exec /bin/bash '$work/job-shell' '$work/$exe' '$work/editor' '$HERE' '$work/$name' '$harness' handoff" ;;
    no-brackets) cmd="$cmd 0" ;;
  esac
  printf '%s' "$draft" > "$work/$name.draft"
  if [ -n "$into" ]; then
    T respawn-pane -k -t "$into" "$cmd" || exit 1
    p="$into"
  else
    p="$(T new-window -d -P -F '#{pane_id}' "$cmd")" || exit 1
  fi
  wait_for screen_has "$p" "${draft:-Ask Codex}" || exit 1
}
token() { "$ROOST" send --agent-token "$1"; }
send_rc() {
  "$ROOST" send "$@" > "$work/out" 2> "$work/err"
  rc=$?
}
send_bg() {
  ( "$@" > "$work/out" 2> "$work/err"; echo $? > "$work/rc" ) &
  sender=$!
}
finish() { wait "$sender"; sender=""; rc="$(cat "$work/rc")"; }
err_has() { grep -q "$1" "$work/err"; }
key_hex() { od -An -tx1 -v "$1" | tr -d ' \n'; }
paste_hex() { printf '\033[200~%s\033[201~' "$1" | od -An -tx1 -v | tr -d ' \n'; }

launch success ''
first_id="$(TMUX_PANE="$p" "$ROOST" whoami)" || exit 1
T set -p -t %0 @roost-was "$p"
confirmed="$(token "$first_id")" || exit 1
send_rc --json --agent-only "$confirmed" "$first_id" 'inert notes reference'
assert_eq "$rc" 0 'a stable ID reaches a confirmed agent even when its tmux number is ambiguous'
T set -pu -t %0 @roost-was
assert_contains "$(cat "$work/out")" "\"pane\":\"$p\"" 'guarded send keeps existing JSON output'
assert_contains "$(cat "$work/out")" "\"target\":\"$first_id\"" 'the guarded send JSON keeps the stable ID as typed'
assert_eq "$(cat "$work/success")" '"inert notes reference"' 'a one-line message is submitted whole exactly once'

for mode in brackets no-brackets; do
  launch "lf-$mode" '' codex codex '' "$mode"
  confirmed="$(token "$p")" || exit 1
  send_rc --agent-only "$confirmed" "$p" $'first inert line\nsecond inert line'
  assert_eq "$rc" 2 "$mode: LF is refused before delivery"
  assert_file_absent "$work/lf-$mode.keys" "$mode: refused multiline sends issue zero terminal bytes"
  assert_file_absent "$work/lf-$mode" "$mode: no line was submitted"
  if [ "$mode" = no-brackets ]; then
    send_rc --agent-only "$confirmed" "$p" 'one inert line'
    assert_eq "$rc" 0 'an unbracketed editor can receive a guarded one-line message'
    expected="$(printf '%s\r' 'one inert line' | od -An -tx1 -v | tr -d ' \n')"
    assert_eq "$(key_hex "$work/lf-$mode.keys")" "$expected" 'the unbracketed fixture gets literal text and exactly one Enter'
  fi
done

launch no-identity '' none
send_rc --agent-token "$p"
assert_eq "$rc" 7 'an unreported editor has no usable token'
assert_file_absent "$work/no-identity.keys" 'inspection is read-only'
launch generic-node '' pi node
assert_eq "$(T show-options -pqv -t "$p" @roost-harness)" pi 'the generic process has Pi metadata'
send_rc --agent-token "$p"
assert_eq "$rc" 7 'a generic node process is insufficient evidence for Pi'
assert_file_absent "$work/generic-node.keys" 'node receives no terminal input'

launch blocked ''
confirmed="$(token "$p")" || exit 1
T set-option -p -t "$p" @agent_state blocked
send_rc --agent-only "$confirmed" "$p" ''
assert_eq "$rc" 7 'a blocked target refuses even bare Enter'
assert_file_absent "$work/blocked.keys" 'a blocked target receives no Enter, paste or cleanup key'
T set-option -pu -t "$p" @agent_state
send_rc --agent-only "$confirmed" "$p" $'invalid\rtext'
assert_eq "$rc" 2 'literal terminal controls in guarded text are refused'
send_rc --agent-only "$confirmed" "$p" $'invalid\ttext'
assert_eq "$rc" 2 'a guarded send cannot type Tab into an unbracketed editor'
send_rc --agent-only "$confirmed" --force "$p" 'inert'
assert_eq "$rc" 2 'force and guarded send are mutually exclusive'
assert_file_absent "$work/blocked.keys" 'invalid guarded sends issue no keys'

alias_pane="$(T new-window -d -P -F '#{pane_id}' 'exec /bin/sh')"
T set-option -p -t "$alias_pane" @roost-was "$p"
send_rc --agent-token "$p"
assert_eq "$rc" 7 'an ambiguous current and historical pane id has no token'
send_rc --agent-only "$confirmed" "$p" 'inert'
assert_eq "$rc" 7 'an id made ambiguous after confirmation is refused'
send_rc --agent-only "$confirmed" "was:$p" 'inert'
assert_eq "$rc" 7 'an explicit historical id cannot route a guarded send'
assert_file_absent "$work/blocked.keys" 'prior-id refusals issue no keys to the live agent'
T kill-pane -t "$alias_pane"

launch shell-replacement ''
confirmed="$(token "$p")" || exit 1
T respawn-pane -k -t "$p" 'ENV= exec /bin/sh'
assert_eq "$(T show-options -pqv -t "$p" @roost-session)" shared-session 'a respawn keeps stale session metadata'
send_rc --agent-token "$p"
assert_eq "$rc" 7 'a live shell with stale metadata has no usable token'
send_rc --agent-only "$confirmed" "$p" 'inert'
assert_eq "$rc" 7 'a shell replacing the confirmed agent refuses delivery'
assert_eq "$(T capture-pane -p -t "$p" | grep -c inert)" 0 'no text reached the replacement shell'

printf '%s' 'replacement draft' > "$work/shell-handoff-replacement.draft"
launch shell-handoff '' codex codex '' handoff
shell_candidate="$(T display-message -p -t "$p" "$ROOST_SEND_GUARD_FORMAT")"
parent_pid="$(T display-message -p -t "$p" '#{pane_pid}')"
stamp="$(T show-options -pqv -t "$p" @roost-agent-process)"
IFS=- read -r bound_pane_pid foreground_pid agent_pid birth <<< "$stamp"
[ "$bound_pane_pid" = "$parent_pid" ] && [ "$foreground_pid" != "$parent_pid" ] || exit 1
assert_eq "$(T display-message -p -t "$p" '#{pane_current_command}')" codex 'a shell-launched agent advertises the same command name'
send_rc --agent-token "$p"
assert_eq "$rc" 7 'the job-control shell cannot produce a guarded token'
send_rc --agent-only "$shell_candidate" "$p" 'inert'
assert_eq "$rc" 7 'a former token for a shell-launched job refuses paste'
send_rc --agent-only "$shell_candidate" "$p" ''
assert_eq "$rc" 7 'a former token for a shell-launched job refuses bare Enter'
assert_file_absent "$work/shell-handoff.keys" 'the first shell job receives zero terminal bytes'
kill -TERM -- "-$foreground_pid"
wait_for screen_has "$p" 'replacement draft' || exit 1
assert_eq "$(T display-message -p -t "$p" '#{pane_pid}/#{pane_current_command}')" "$parent_pid/codex" 'the same-name shell handoff preserves pane PID and command'
assert_eq "$(T show-options -pqv -t "$p" @roost-agent-process)" "$stamp" 'the original stamp survives the handoff'
send_rc --agent-only "$shell_candidate" "$p" ''
assert_eq "$rc" 7 'the same-name replacement cannot inherit the former token'
assert_file_absent "$work/shell-handoff-replacement.keys" 'the same-name shell replacement receives zero bytes'
assert_file_absent "$work/shell-handoff-replacement" 'the replacement draft stays unsubmitted'

launch dead ''
confirmed="$(token "$p")" || exit 1
T set-option -w -t "$p" remain-on-exit on
kill -TERM -- "-$(T display-message -p -t "$p" '#{pane_pid}')"
wait_for screen_has "$p" 'Pane is dead' || exit 1
send_rc --agent-only "$confirmed" "$p" 'inert'
assert_eq "$rc" 7 'a dead pane with retained identity refuses delivery'
assert_file_absent "$work/dead.keys" 'no bytes reached the dead fixture'

launch lock-old ''
confirmed="$(token "$p")" || exit 1
lock="$ROOST_TEST_SOCKDIR/roost-send-lock.s.${p#%}"
/bin/bash -c 'while :; do sleep 1; done' roost-test-holder & holder=$!
mkdir "$lock"
printf '%s\n' "$holder" > "$lock/pid"
send_bg /bin/bash -x "$ROOST" send --agent-only "$confirmed" "$p" 'inert'
wait_for err_has '^++* sleep 0\.1' || { cat "$work/err"; exit 1; }
assert_file_absent "$work/lock-old.keys" 'waiting for the lock issues no keys before replacement'
launch lock-new '' codex codex "$p"
new_token="$(token "$p")" || exit 1
[ "$new_token" != "$confirmed" ]; assert_true $? 'resuming the same harness session creates a new token'
rm "$lock/pid"; rmdir "$lock"
kill "$holder"; wait "$holder" 2>/dev/null; holder=""
finish
assert_eq "$rc" 7 'replacing the agent while a send waits for the lock is refused'
# tmux closing the old PTY can wake the reader with an empty read, which
# creates the receipt file without any bytes from the sender.
[ ! -s "$work/lock-old.keys" ]; assert_true $? 'lock wait never touched the old editor'
assert_file_absent "$work/lock-new.keys" 'lock wait never touched its replacement'

launch occupied 'human draft'
confirmed="$(token "$p")" || exit 1
send_bg "$ROOST" send --agent-only "$confirmed" "$p" 'inert'
wait_for err_has 'waiting.*input box' || exit 1
T set-option -p -t "$p" @roost-session new-conversation
printf '' > "$work/occupied.draft"
finish
assert_eq "$rc" 7 'changing conversation while occupied input clears is refused'
assert_file_absent "$work/occupied.keys" 'the occupied editor received no paste, Enter or cleanup key'

launch paste-boundary ''
confirmed="$(token "$p")" || exit 1
# Run the ordinary foreground probe, then set the badge before the server
# evaluates the format branch. This pins which check actually gates the paste.
export REAL_TMUX="$(command -v tmux)"
mkdir "$work/shim"
cat > "$work/shim/tmux" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -S ] && [ "$2" = "$ROOST_TEST_SOCK" ] && [ "${3:-}" = if-shell ]; then
  case "${7:-}" in
    *"${AFTER_ACTION:-paste-buffer}"*)
      if [ -n "${AFTER_DISPATCH:-}" ]; then
        "$REAL_TMUX" "$@" || exit $?
        exec /bin/bash -c "$AFTER_DISPATCH"
      fi
      if [ -n "${AFTER_PROBE:-}" ]; then
        change="$AFTER_PROBE"
      else
        printf -v change '%q -S %q set-option -p -t %q @agent_state blocked' "$REAL_TMUX" "$2" "$5"
      fi
      exec "$REAL_TMUX" "$1" "$2" "$3" "$4" "$5" "${6#exec } && $change" "$7" "$8" ;;
  esac
fi
exec "$REAL_TMUX" "$@"
SH
chmod +x "$work/shim/tmux"
PATH="$work/shim:$PATH" send_rc --agent-only "$confirmed" "$p" 'inert'
assert_eq "$(T show-options -pqv -t "$p" @agent_state)" blocked 'the badge changed between the process probe and paste branch'
assert_eq "$rc" 7 'the server format check refuses a last-moment block before paste'
assert_file_absent "$work/paste-boundary.keys" 'a refused paste issues no terminal keys, including cleanup'

cat > "$work/replace-pane" <<'SH'
"$1" -S "$2" respawn-pane -k -t "$3" "$4" || exit 1
for ((n=0; n<100; n++)); do
  if "$1" -S "$2" capture-pane -p -t "$3" | grep -q 'replacement draft'; then
    : > "$5"
    exit 0
  fi
  sleep 0.02
done
exit 1
SH
replacement_command() {
  printf '%s' 'replacement draft' > "$work/$1-replacement.draft"
  local cmd="exec '$work/codex' /bin/bash '$work/editor' '$HERE' '$work/$1-replacement' none"
  printf -v replace '/bin/bash %q %q %q %q %q %q' "$work/replace-pane" "$REAL_TMUX" \
    "$ROOST_TEST_SOCK" "$p" "$cmd" "$work/$1-replaced"
}
for phase in paste enter dispatched; do
  launch "$phase-old" ''
  confirmed="$(token "$p")" || exit 1
  stamp="$(T show-options -pqv -t "$p" @roost-agent-process)"
  old_pid="$(T display-message -p -t "$p" '#{pane_pid}')"
  replacement_command "$phase"
  case "$phase" in
    paste) AFTER_PROBE="$replace" PATH="$work/shim:$PATH" send_rc --agent-only "$confirmed" "$p" 'inert'; expected_rc=7 ;;
    enter) AFTER_ACTION=' Enter ;' AFTER_PROBE="$replace" PATH="$work/shim:$PATH" send_rc --agent-only "$confirmed" "$p" 'inert'; expected_rc=8 ;;
    dispatched) AFTER_ACTION=' Enter ;' AFTER_DISPATCH="$replace" PATH="$work/shim:$PATH" send_rc --agent-only "$confirmed" "$p" 'inert'; expected_rc=8 ;;
  esac
  [ -f "$work/$phase-replaced" ]; assert_true $? "$phase: the probe or action completed before the same-name replacement"
  assert_eq "$(T show-options -pqv -t "$p" @roost-agent-process)" "$stamp" "$phase: the same-name replacement retains the old stamp"
  assert_eq "$(T display-message -p -t "$p" '#{pane_current_command}')" codex "$phase: tmux still reports the same command name"
  [ "$(T display-message -p -t "$p" '#{pane_pid}')" != "$old_pid" ]; assert_true $? "$phase: dedicated replacement changes the pane PID"
  assert_eq "$rc" "$expected_rc" "$phase: refusal or uncertainty reflects the delivery boundary"
  assert_file_absent "$work/$phase-replacement.keys" "$phase: replacement gets zero input including cleanup"
  assert_file_absent "$work/$phase-replacement" "$phase: replacement draft stays unsubmitted"
  case "$phase" in
    paste) [ ! -s "$work/$phase-old.keys" ]; assert_true $? 'a pre-paste replacement leaves the old editor untouched' ;;
    enter) assert_eq "$(key_hex "$work/$phase-old.keys")" "$(paste_hex inert)" 'the original editor received only the paste' ;;
  esac
done

# A late claim in a different session must be seen by the final server scan.
# Use a padded historical ID to exercise the ordinary resolver's normalization.
alias_pane="$(T new-session -d -P -F '#{pane_id}' 'exec /bin/sh')"
for phase in paste enter; do
  launch "alias-$phase" ''
  confirmed="$(token "$p")" || exit 1
  claim="%000${p#%}"
  printf -v after_probe '%q -S %q set-option -p -t %q @roost-was %q' "$REAL_TMUX" "$ROOST_TEST_SOCK" "$alias_pane" "$claim"
  if [ "$phase" = paste ]; then action=paste-buffer; expected_rc=7; else action=' Enter ;'; expected_rc=8; fi
  AFTER_ACTION="$action" AFTER_PROBE="$after_probe" PATH="$work/shim:$PATH" send_rc --agent-only "$confirmed" "$p" 'inert'
  assert_eq "$(T show-options -pqv -t "$alias_pane" @roost-was)" "$claim" "$phase: alias appeared after the process probe"
  assert_eq "$rc" "$expected_rc" "$phase: the final condition refuses a new historical alias"
  assert_file_absent "$work/alias-$phase" "$phase: nothing was submitted"
  if [ "$phase" = paste ]; then
    assert_file_absent "$work/alias-$phase.keys" 'the late alias prevents all terminal input'
  else
    assert_eq "$(key_hex "$work/alias-$phase.keys")" "$(paste_hex inert)" 'the late alias prevents Enter and cleanup after paste'
  fi
  T set-option -pu -t "$alias_pane" @roost-was
done
T kill-pane -t "$alias_pane"

launch submit ''
confirmed="$(token "$p")" || exit 1
T set-option -g @roost-send-enter-delay 2
send_bg "$ROOST" send --agent-only "$confirmed" "$p" 'inert before block'
wait_for test -s "$work/submit.keys" || exit 1
T set-option -p -t "$p" @agent_state blocked
finish
assert_eq "$rc" 8 'losing eligibility after paste has a distinct delivery outcome'
assert_eq "$(key_hex "$work/submit.keys")" "$(paste_hex 'inert before block')" 'only the initial paste reached the pane, with no Enter or cleanup key'
assert_file_absent "$work/submit" 'nothing was submitted after the target became blocked'
assert_eq "$(T list-buffers -F '#{buffer_name}' 2>/dev/null)" '' 'refusals leave no send buffer behind'

launch ordinary '' none
T set-option -g @roost-send-enter-delay 0.1
send_rc "$p" $'ordinary send\nstill multiline'
assert_eq "$rc" 0 'ordinary send remains compatible with an unreported editor'
assert_eq "$(cat "$work/ordinary")" '"ordinary send\nstill multiline"' 'ordinary send still submits multiline text exactly once'
[ "$ROOST_TESTS_FAIL" -eq 0 ]
