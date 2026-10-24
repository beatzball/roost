#!/usr/bin/env bash
# `roost wait-done --json` (#110, step 3 of the turn-over design): one JSON
# document per OUTCOME, on stdout, on every outcome -- done, error, timeout,
# died, gone, interrupted -- with the exit code unchanged; nothing on stdout
# for a usage refusal, like every other --json; stderr byte-identical to the
# plain command. docs/airig/specs/2026-09-15-json-output-design.md reserved
# the shape ("Adding wait-done later"); site/content/docs/driving-a-fleet.md
# documents the fields.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
FIX="$HERE/tests/fixtures"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file parses documents with it)"
  exit 0
fi

work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"
export ROOST_RECORD_DIR="$work/rec"
export HOME="$work/canary" XDG_CONFIG_HOME="$work/canary/config" \
       XDG_STATE_HOME="$work/canary/state" XDG_DATA_HOME="$work/canary/data"
mkdir -p "$work/canary"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT
tmux -S "$s" -f /dev/null new-session -d -s main -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
boot="$(tmux -S "$s" display -p '#{start_time}-#{pid}')"
export ROOST_SOCKET="$s"
unset TMUX TMUX_PANE

X() { tmux -S "$s" "$@"; }
newpane() { X new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
opt() { X show-options -pqv -t "$1" "$2" 2>/dev/null; }
hook() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" "$@"; }
recdir() { printf '%s/%s/%s' "$ROOST_RECORD_DIR" "$boot" "${1#%}"; }
# cap NAME CMD... -> $work/NAME.out, .err, .rc
cap() { local p="$work/$1"; shift; "$@" >"$p.out" 2>"$p.err"; printf '%s' "$?" >"$p.rc"; }
rc()  { cat "$work/$1.rc"; }
# jv NAME PYEXPR -> NAME.out must be exactly ONE line of JSON; prints PYEXPR
# with the document bound to d (the shape tests/test-json-output.sh uses).
jv() {
  python3 - "$work/$1.out" "$2" <<'PY'
import sys, json
raw = open(sys.argv[1], 'rb').read()
if not raw.endswith(b'\n') or raw.count(b'\n') != 1:
    print('NOT ONE LINE: %r' % raw[:200]); sys.exit()
try:
    d = json.loads(raw[:-1].decode('utf-8'))
except Exception as e:
    print('INVALID: %s %r' % (e, raw[:200])); sys.exit()
print(eval(sys.argv[2]))
PY
}
# same_stderr A B LABEL -- the plain and the --json run printed the same stderr.
same_stderr() { cmp -s "$work/$1.err" "$work/$2.err"; assert_true $? "$3"; }

UPS='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-000000000002","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"hello"}'

# --- 1. done, with the recorded reply ----------------------------------------------
p="$(newpane)"; require_pane "$p" done
hook "$p" working <<< "$UPS"
printf '{"last_assistant_message":"hello from the pane","background_tasks":[]}' | hook "$p" done --stop-hook
cap d1 "$ROOST" wait-done --json "$p" 5
assert_eq "$(rc d1)" "0" "done: exit 0"
assert_eq "$(jv d1 'd["schema"], d["command"], d["target"], d["pane"], d["state"], d["outcome"]')" "(1, 'wait-done', '$p', '$p', 'done', 'done')" \
  "done: schema 1, command wait-done, the pane, state done, outcome done"
assert_eq "$(jv d1 'd["error_reason"], d["background"], d["turn"]')" "(None, None, None)" "done: error_reason, background and turn are null"
assert_eq "$(jv d1 'type(d["elapsed"]).__name__, d["elapsed"] >= 0')" "('int', True)" "done: elapsed is a non-negative integer"
assert_eq "$(jv d1 'json.dumps(d["reply"], sort_keys=True)')" \
  "$(python3 -c 'import json; print(json.dumps({"source":"reply","state":"done","stale":False,"error_reason":None,"turn":1,"text":"hello from the pane","lossy":False,"sent_by":None,"final":True,"background":None}, sort_keys=True))')" \
  "done: reply is the read --json object for the pane, less schema/command/target/pane"
cap d1h "$ROOST" wait-done "$p" 5
assert_eq "$(cat "$work/d1h.out")" "" "plain wait-done still prints nothing on stdout"
same_stderr d1 d1h "done: stderr is the same with and without --json"
cap d2 "$ROOST" wait-done --json --turn 1 "$p" 5
assert_eq "$(rc d2)" "0" "done --turn 1: exit 0"
assert_eq "$(jv d2 'd["turn"], d["reply"]["turn"], d["outcome"]')" "(1, 1, 'done')" "done --turn 1: turn 1, reply.turn 1"
cap d3 "$ROOST" wait-done --turn 1 --json "$p" 5
assert_eq "$(rc d3)" "0" "the two flags work in either order"
assert_eq "$(jv d3 'd["turn"]')" "1" "...and mean the same"
# a window target: pane is null when no single pane is the outcome's
w="$(X display-message -p -t "$p" '#{window_id}')"
cap d4 "$ROOST" wait-done --json "$w" 5
assert_eq "$(rc d4)" "0" "done on a window target: exit 0"
assert_eq "$(jv d4 'd["pane"], d["reply"], d["outcome"]')" "(None, None, 'done')" "...pane null, reply null (turns belong to one pane)"

# --- 2. error ------------------------------------------------------------------------
p="$(newpane)"; require_pane "$p" error
hook "$p" working <<< "$UPS"
ROOST_ERROR_REASON="the provider went away" hook "$p" error </dev/null
cap e1 "$ROOST" wait-done --json "$p" 5
assert_eq "$(rc e1)" "1" "error: exit 1"
assert_eq "$(jv e1 'd["outcome"], d["state"], d["pane"], d["error_reason"], d["reply"]')" "('error', 'error', '$p', 'the provider went away', None)" \
  "error: outcome error, the reason, no reply"
cap e1h "$ROOST" wait-done "$p" 5
same_stderr e1 e1h "error: stderr is the same with and without --json"
w="$(X display-message -p -t "$p" '#{window_id}')"
cap e2 "$ROOST" wait-done --json "$w" 5
assert_eq "$(jv e2 'd["outcome"], d["pane"]')" "('error', '$p')" "error on a window target names the errored pane"

# --- 3. timeout, and a held pane's background count ---------------------------------
p="$(newpane)"; require_pane "$p" timeout
hook "$p" working <<< "$UPS"
cap t1 "$ROOST" wait-done --json "$p" 1
assert_eq "$(rc t1)" "1" "timeout: exit 1"
assert_eq "$(jv t1 'd["outcome"], d["state"], d["background"], d["reply"], d["elapsed"] >= 1')" "('timeout', 'working', None, None, True)" \
  "timeout: outcome timeout, state working, background null, elapsed counted"
cap t1h "$ROOST" wait-done "$p" 1
same_stderr t1 t1h "timeout: stderr is the same with and without --json"
hook "$p" done --stop-hook < "$FIX/claude-stop-bg-two-shells.json"
assert_eq "$(opt "$p" @agent_state)" "working" "setup: the pane is held by two background shells"
cap t2 "$ROOST" wait-done --json "$p" 1
assert_eq "$(jv t2 'd["outcome"], d["background"]')" "('timeout', 2)" "timeout on a held pane: background 2"
cap t3 "$ROOST" wait-done --json --turn 3 "$p" 1
assert_eq "$(rc t3)" "1" "timeout --turn: exit 1"
assert_eq "$(jv t3 'd["outcome"], d["turn"]')" "('timeout', 3)" "...outcome timeout, turn 3"

# --- 4. died, and gone ------------------------------------------------------------------
p="$(newpane)"; require_pane "$p" died
X set-option -p -t "$p" remain-on-exit on
hook "$p" working <<< "$UPS"
X respawn-pane -k -t "$p" 'exit 0' 2>/dev/null
# respawn-pane keeps the pane options; the pane's process exits at once and
# remain-on-exit leaves the pane dead with its working badge: #54's shape.
sleep 0.5
cap x1 "$ROOST" wait-done --json "$p" 5
assert_eq "$(rc x1)" "2" "died: exit 2"
assert_eq "$(jv x1 'd["outcome"], d["pane"], d["state"], d["reply"]')" "('died', '$p', 'working', None)" "died: outcome died, the pane, its last badge"
cap x1h "$ROOST" wait-done "$p" 5
same_stderr x1 x1h "died: stderr is the same with and without --json"
cap g1 "$ROOST" wait-done --json %999 1
assert_eq "$(rc g1)" "2" "gone: exit 2"
assert_eq "$(jv g1 'd["outcome"], d["pane"], d["state"], d["target"]')" "('gone', None, None, '%999')" "gone: outcome gone, pane and state null"
cap g1h "$ROOST" wait-done %999 1
same_stderr g1 g1h "gone: stderr is the same with and without --json"

# --- 5. interrupted ---------------------------------------------------------------------
p="$(newpane)"; require_pane "$p" interrupted
hook "$p" working <<< "$UPS"
since="$(opt "$p" @agent_since)"
# What the recovery leaves: no badge, and the outcome beside the stamp.
X set-option -pu -t "$p" @agent_state
X set-option -p -t "$p" @roost-ended "$since interrupted"
cap i1 "$ROOST" wait-done --json "$p" 5
assert_eq "$(rc i1)" "5" "interrupted: exit 5"
assert_eq "$(jv i1 'd["outcome"], d["pane"], d["state"], d["reply"]')" "('interrupted', '$p', None, None)" "interrupted: outcome interrupted, no badge, no reply"
cap i1h "$ROOST" wait-done "$p" 5
assert_eq "$(rc i1h)" "5" "plain wait-done exits 5 too"
same_stderr i1 i1h "interrupted: stderr is the same with and without --json"
assert_contains "$(cat "$work/i1h.err")" "was interrupted, not done" "...and names the outcome"
# --turn N on a turn whose outcome sidecar says interrupted
mkdir -p "$(recdir "$p")/replies"; printf '1\n' > "$(recdir "$p")/schema"
: > "$(recdir "$p")/replies/000001"; printf 'interrupted' > "$(recdir "$p")/replies/000001.outcome"
cap i2 "$ROOST" wait-done --json --turn 1 "$p" 5
assert_eq "$(rc i2)" "5" "--turn on an interrupted turn: exit 5"
assert_eq "$(jv i2 'd["outcome"], d["turn"]')" "('interrupted', 1)" "...outcome interrupted, turn 1"

# --- 6. refusals print nothing on stdout -------------------------------------------------
p="$(newpane)"; require_pane "$p" refusals
for args in "$p abc" "--turn 1 main:0" "--turn x $p" "" "--json"; do
  # shellcheck disable=SC2086
  cap r "$ROOST" wait-done --json $args
  assert_eq "$(wc -c < "$work/r.out" | tr -d ' ')" "0" "a refusal prints nothing on stdout [wait-done --json $args]"
  [ "$(rc r)" -ne 0 ]; assert_true $? "...and exits non-zero [wait-done --json $args]"
done
cap r2 "$ROOST" wait-done "$p" --json
assert_eq "$(rc r2)" "1" "--json after the target is a bad timeout, as any word there is"
assert_eq "$(wc -c < "$work/r2.out" | tr -d ' ')" "0" "...and prints nothing on stdout"

[ -z "$(find "$work/canary" -type f 2>/dev/null)" ]; assert_true $? "nothing was written under HOME or the XDG dirs"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
