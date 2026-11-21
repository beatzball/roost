#!/usr/bin/env bash
# Initial-input hold only: after the first key main's delivery rules apply.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/amx.XXXX)"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state"
export CODEX_HOME="$work/codex" COPILOT_HOME="$work/copilot" PI_CODING_AGENT_DIR="$work/pi"
export CLAUDE_SETTINGS="$work/claude/settings.json" CLAUDE_CONFIG_DIR="$work/claude"
unset ZDOTDIR NO_COLOR
mkdir -p "$HOME"
sender=""
trap '[ -z "$sender" ] || kill "$sender" 2>/dev/null; roost_test_teardown; rm -rf "$work"' EXIT
roost_test_server
export ROOST_SOCKET="$ROOST_TEST_SOCK"
T set-option -g @roost-send-enter-delay 0.1
T set-option -g @roost-send-idle-timeout 5
newbox() {
  printf 'human draft' > "$work/$1.draft"
  p="$(T new-window -d -P -F '#{pane_id}' "exec python3 '$HERE/tests/fixtures/input-box.py' '$work/$1'")"
  require_pane "$p" input-box
  T set-option -p -t "$p" @roost-harness "$2"
  for ((n=0; n<100; n++)); do
    T capture-pane -p -t "$p" | grep -q 'human draft' && return
    sleep 0.05
  done
  exit 1
}
send_bg() {
  ( "$HERE/bin/roost" send "$@" > "$work/out" 2> "$work/err"; echo $? > "$work/rc" ) &
  sender=$!
}
finish() { wait "$sender"; sender=""; }
receipt() {
  python3 - "$work/$1" "$2" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
values = [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []
print("whole once" if values == [sys.argv[2]] else repr(values))
PY
}
for kind in short long; do
  msg="one complete prompt"
  [ "$kind" != long ] || msg="$(python3 -c 'print("a long prompt " * 100 + "\nmore text" * 12)')"
  newbox "$kind" claude
  send_bg "$p" "$msg"
  for ((n=0; n<40; n++)); do grep -q 'waiting.*input' "$work/err" && break; sleep 0.05; done
  assert_file_absent "$work/$kind.keys" "$kind occupied editor receives zero sender keys"
  printf '' > "$work/$kind.draft"
  finish
  assert_eq "$(cat "$work/rc")" 0 "$kind send succeeds after clear"
  assert_eq "$(receipt "$kind" "$msg")" 'whole once' "$kind prompt delivered whole once"
  assert_eq "$(grep -c 'waiting.*input' "$work/err")" 1 "$kind reason printed once"
done
newbox unknown mystery
send_bg "$p" 'immediate unknown'
finish
assert_eq "$(cat "$work/rc")" 0 'unreadable renderer passes through'
assert_eq "$(receipt unknown 'human draftimmediate unknown')" 'whole once' 'unknown input typed without waiting'
newbox force claude
send_bg --force "$p" 'forced prompt'
finish
assert_eq "$(receipt force 'human draftforced prompt')" 'whole once' '--force skips occupied check'
newbox timeout claude
T set-option -g @roost-send-idle-timeout 1
send_bg "$p" 'never typed'
finish
assert_eq "$(cat "$work/rc")" 6 'occupied timeout exits nonzero'
assert_file_absent "$work/timeout.keys" 'timeout receives zero keys including cleanup'
assert_contains "$(cat "$work/err")" 'nothing was typed' 'timeout says no keys'
python3 "$HERE/tests/test-input-parser.py"
parser_rc=$?
assert_eq "$parser_rc" 0 'measured reader parser cases pass'
[ "$ROOST_TESTS_FAIL" -eq 0 ]
