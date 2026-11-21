#!/usr/bin/env bash
# A pre-key hold must not lend an old draft or human turn to the new send.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/amx.XXXX)"
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_STATE_HOME="$work/state"
export CODEX_HOME="$work/codex" COPILOT_HOME="$work/copilot" PI_CODING_AGENT_DIR="$work/pi"
export CLAUDE_SETTINGS="$work/claude/settings.json" CLAUDE_CONFIG_DIR="$work/claude"
unset ZDOTDIR NO_COLOR TMUX TMUX_PANE ROOST_SOCKET ROOST_SELF_SOCK
export TMUX_TMPDIR="$work/tmux" ROOST_RECORD_DIR="$work/records"
mkdir -p "$HOME" "$TMUX_TMPDIR"
sender=""
ROOST_TEST_SOCKDIR="$(mktemp -d /tmp/amx.XXXX)"
export ROOST_TEST_SOCK="$ROOST_TEST_SOCKDIR/roost" ROOST_SOCKET="$ROOST_TEST_SOCKDIR/roost"
trap '[ -z "$sender" ] || kill "$sender" 2>/dev/null; roost_test_teardown; rm -rf "$work"' EXIT
tmux -S "$ROOST_TEST_SOCK" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(T display-message -p '#{pid}')"
T set-option -g @roost-send-enter-delay 0.1
T set-option -g @roost-send-ready-timeout 2
T set-option -g @roost-send-turn-timeout 1
T set-option -g @roost-send-idle-timeout 15
hook() { env TMUX="$ROOST_TEST_SOCK,$spid,0" TMUX_PANE="$p" "$HERE/scripts/roost-agent-state" "$@"; }
newbox() {
  tag="$1"
  printf '%s' "$2" > "$work/$tag.draft"
  p="$(T new-window -d -P -F '#{pane_id}' "exec python3 '$HERE/tests/fixtures/input-box.py' '$work/$tag' ${3:+\"$HERE/scripts/roost-agent-state\"}")"
  require_pane "$p" input-baseline
  T set-option -p -t "$p" @roost-harness claude
  for ((n=0; n<100; n++)); do
    [ "$(python3 "$HERE/scripts/roost-input.py" -S "$ROOST_TEST_SOCK" "$p")" = occupied ] && return
    sleep 0.05
  done
  exit 1
}
start() {
  ( "$HERE/bin/roost" send "$@" > "$work/$tag.out" 2> "$work/$tag.err"; echo $? > "$work/$tag.rc" ) &
  sender=$!
  for ((n=0; n<100; n++)); do grep -q 'waiting.*input' "$work/$tag.err" && return; sleep 0.05; done
  exit 1
}
finish() { wait "$sender"; sender=""; }
receipt() {
  python3 - "$work/$tag" "$1" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
print([json.loads(s) for s in p.read_text().splitlines()] == [sys.argv[2]] if p.exists() else False)
PY
}
field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
reply() { "$HERE/bin/roost" read --json --turn "$1" "$p" 2>/dev/null; }
human_turn() {
  hook working </dev/null
  printf '{"last_assistant_message":"HUMAN REPLY"}' | hook done --stop-hook
  # Use the same sidecar writer as send, to detect any later relabelling.
  . "$HERE/scripts/lib/roost-record.sh"
  boot="$(T display-message -p '#{start_time}-#{pid}')"
  roost_record_put_turn_field "$ROOST_RECORD_DIR/$boot/${p#%}" 1 sent_by human "$ROOST_TEST_SOCK"
}
long="$(python3 -c 'print("long prompt " * 110 + "\nmore" * 12)')"
newbox collapsed "$(python3 -c 'print("human draft " * 110)')"
start "$p" "$long"
assert_file_absent "$work/$tag.keys" 'collapsed old draft gets zero keys while held'
printf '' > "$work/$tag.draft"
finish
assert_eq "$(cat "$work/$tag.rc")" 0 'collapsed draft clears before collapsed long delivery'
assert_eq "$(receipt "$long")" True 'collapsed long prompt delivered whole once'
assert_eq "$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_bytes().count(b"\x1b[200~"))' "$work/$tag.keys")" 1 'collapsed long prompt is pasted once'

for mode in no-turn new-turn busy reserved; do
  newbox "$mode" 'human draft' "$([ "$mode" != new-turn ] || echo hooks)"
  hook idle </dev/null
  start --json --from coordinator "$p" 'sender prompt'
  human_turn
  if [ "$mode" = busy ]; then hook working </dev/null; fi
  if [ "$mode" = reserved ]; then
    # A completed release may reserve its number before its reply file lands.
    T set-option -p -t "$p" @roost-turn-reserved 4
  fi
  assert_file_absent "$work/$tag.keys" "$mode human turn completes before sender keys"
  printf '' > "$work/$tag.draft"
  finish
  expected=4; [ "$mode" = no-turn ] || [ "$mode" = reserved ] || expected=0
  assert_eq "$(cat "$work/$tag.rc")" "$expected" "$mode uses post-hold turn baseline"
  assert_eq "$(receipt 'sender prompt')" True "$mode sender prompt submitted whole once"
  assert_eq "$(reply 1 | field text)" 'HUMAN REPLY' "$mode preserves human reply"
  assert_eq "$(reply 1 | field sent_by)" human "$mode preserves human attribution"
  if [ "$mode" = new-turn ]; then
    assert_eq "$(field turn < "$work/$tag.out")" 2 'real prompt returns its new turn number'
    assert_eq "$(reply 2 | field text)" 'REPLY-TO[sender prompt]' 'new turn has its own reply'
    assert_eq "$(reply 2 | field sent_by)" coordinator 'new turn has coordinator attribution'
  elif [ "$mode" = busy ]; then
    assert_eq "$(field turn < "$work/$tag.out")" None 'currently busy target claims no turn'
    assert_eq "$(field started < "$work/$tag.out")" False 'currently busy target does not watch old idle state'
  else
    assert_eq "$(cat "$work/$tag.out")" '' "$mode cannot claim success JSON"
  fi
done

newbox waited 'human draft'
start --json --when-idle "$p" 'after busy'
T set-option -p -t "$p" @agent_state working
printf '' > "$work/$tag.draft"
sleep 3
assert_file_absent "$work/$tag.keys" 'working interval after input clear still gets zero keys'
T set-option -p -u -t "$p" @agent_state
finish
assert_eq "$(cat "$work/$tag.rc")" 0 'working interval finishes delivery normally'
waited="$(field waited < "$work/$tag.out")"
[ "$waited" -ge 1 ] && [ "$waited" -le 5 ]; assert_true $? 'JSON waited includes the later observed working interval'
[ "$ROOST_TESTS_FAIL" -eq 0 ]
