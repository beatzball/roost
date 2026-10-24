#!/usr/bin/env bash
# The edges of the turn-over steps 1 to 3 that review found (fix loop 1 of
# docs/airig/plans/2026-10-24-turn-over-steps-1-3-plan.md): races between two
# recoveries, a release with no reply of its own, a numbered wait that read
# the pane's newest outcome, an outcome that leaked into the next turn, a
# plain `working` that read stdin, an interrupt or a dialog during a hold, a
# sidecar that could not be written. Each section names its finding and is
# what turned red before the fix.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
FIX="$HERE/tests/fixtures"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file builds payloads with it)"
  exit 0
fi

work="$(mktemp -d /tmp/amx.XXXX)"
s="$work/roost"
export ROOST_RECORD_DIR="$work/rec"
export HOME="$work/canary" XDG_CONFIG_HOME="$work/canary/config" \
       XDG_STATE_HOME="$work/canary/state" XDG_DATA_HOME="$work/canary/data"
mkdir -p "$work/canary"
trap 'tmux -S "$s" kill-server 2>/dev/null; chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
spid="$(tmux -S "$s" display -p '#{pid}')"
boot="$(tmux -S "$s" display -p '#{start_time}-#{pid}')"
export ROOST_SOCKET="$s"
unset TMUX TMUX_PANE

X() { tmux -S "$s" "$@"; }
newpane() { X new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
opt() { X show-options -pqv -t "$1" "$2" 2>/dev/null; }
pane_has() { X show-options -p -t "$1" 2>/dev/null | grep -q "^$2 "; }
hook() { local p="$1"; shift; env TMUX="$s,$spid,0" TMUX_PANE="$p" "$HOOK" "$@"; }
recdir() { printf '%s/%s/%s' "$ROOST_RECORD_DIR" "$boot" "${1#%}"; }
turns_in() { ls "$(recdir "$1")/replies" 2>/dev/null | grep -c '^[0-9][0-9]*$'; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
edit() { python3 -c 'import json,sys
d=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(d))' "$1" "$2"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

STREAM_SINCE=1792814859
NO_SINCE=1789398932
UPS='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-000000000002","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"hello"}'
SHELL1="$(cat "$FIX/claude-stop-bg-shell.json")"
EMPTY="$(cat "$FIX/claude-stop-bg-empty.json")"
for f in interrupt-stream interrupt-tool no; do cp "$FIX/claude-transcript-$f.jsonl" "$work/$f.jsonl"; done

# --- 1. concurrent recoveries record ONE turn (finding 1) --------------------------
# Several callers recover one pane at once -- a wait-done poll, a read, a send.
# Each must not append its own empty turn: only the caller whose compare-and-
# clear landed may.
for trial in 1 2 3; do
  p="$(newpane)"; require_pane "$p" "race/interrupt $trial"
  X set-option -p -t "$p" @agent_since "$STREAM_SINCE"
  X set-option -p -t "$p" @agent_state working
  X set-option -p -t "$p" @roost-transcript "$STREAM_SINCE $work/interrupt-stream.jsonl"
  for i in 1 2 3 4; do "$ROOST" read "$p" >/dev/null 2>&1 & done; wait
  assert_eq "$(turns_in "$p")" "1" "4 concurrent reads recover ONE interrupted turn, not one each (trial $trial)"
done
for trial in 1 2 3; do
  p="$(newpane)"; require_pane "$p" "race/decline $trial"
  X set-option -p -t "$p" @agent_since "$NO_SINCE"
  X set-option -p -t "$p" @agent_state blocked
  X set-option -p -t "$p" @roost-transcript "$NO_SINCE $work/no.jsonl"
  for i in 1 2 3 4; do "$ROOST" read "$p" >/dev/null 2>&1 & done; wait
  assert_eq "$(turns_in "$p")" "1" "4 concurrent reads recover ONE declined turn, not one each (trial $trial)"
done
# The decline's empty turn itself (a single recovery), pinned.
p="$(newpane)"; require_pane "$p" decline-empty-turn
X set-option -p -t "$p" @agent_since "$NO_SINCE"
X set-option -p -t "$p" @agent_state blocked
X set-option -p -t "$p" @roost-transcript "$NO_SINCE $work/no.jsonl"
"$ROOST" read "$p" >/dev/null 2>&1
assert_eq "$(turns_in "$p")" "1" "a declined dialog's recovery records one turn file"
assert_eq "$(wc -c < "$(recdir "$p")/replies/000001" | tr -d ' ')" "0" "...an empty one"
assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome" 2>/dev/null)" "interrupted" "...whose outcome is interrupted"
case "$(opt "$p" @roost-unblocked)" in
  *" since=$NO_SINCE by="*) r=tokened ;; *) r="$(opt "$p" @roost-unblocked)" ;;
esac
assert_eq "$r" "tokened" "@roost-unblocked names the stamp and the caller that cleared it"

# --- 2. a release with no reply of its own keeps the held turn (finding 2) ----------
p="$(newpane)"; require_pane "$p" release-empty
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["last_assistant_message"]="MAIN-ANSWER"')"
hook "$p" done --stop-hook <<< "$(edit "$EMPTY" 'd["last_assistant_message"]=""')"
assert_eq "$(opt "$p" @agent_state)" "done" "a release whose own reply is empty releases"
assert_eq "$(turns_in "$p")" "1" "...and the prompt keeps its ONE turn file"
assert_eq "$(cat "$(recdir "$p")/replies/000001" 2>/dev/null)" "MAIN-ANSWER" "...holding the held main reply, the agent's answer"
assert_eq "$("$ROOST" read "$p" 2>/dev/null)" "MAIN-ANSWER" "...which read serves as the turn's reply"
assert_eq "$(opt "$p" @roost-reply-turn)" "1" "...with the pointer set"
pane_has "$p" @roost-background; assert_eq "$?" "1" "...and the hold record cleared"
hook "$p" working <<< "$UPS"
printf '{"last_assistant_message":"NEXT","background_tasks":[]}' | hook "$p" done --stop-hook
assert_eq "$(cat "$(recdir "$p")/replies/000002" 2>/dev/null)" "NEXT" "the next prompt is turn 2, not turn 1"

p="$(newpane)"; require_pane "$p" release-absent
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["last_assistant_message"]="MAIN-TWO"')"
hook "$p" done --stop-hook <<< "$(edit "$EMPTY" 'del d["last_assistant_message"]')"
assert_eq "$(cat "$(recdir "$p")/replies/000001" 2>/dev/null)" "MAIN-TWO" "a release with NO reply field keeps the held main reply as the turn"

p="$(newpane)"; require_pane "$p" release-nothing
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["last_assistant_message"]=""')"
hook "$p" done --stop-hook <<< "$(edit "$EMPTY" 'd["last_assistant_message"]=""')"
assert_eq "$(turns_in "$p")" "1" "no held reply and no final reply: an EMPTY turn file keeps the numbering"
assert_eq "$(wc -c < "$(recdir "$p")/replies/000001" 2>/dev/null | tr -d ' ')" "0" "...and it is empty"
pane_has "$p" @roost-background; assert_eq "$?" "1" "...and the hold record is cleared"

p="$(newpane)"; require_pane "$p" not-held
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$EMPTY" 'd["last_assistant_message"]=""')"
assert_eq "$(turns_in "$p")" "0" "an ordinary turn with no reply (never held) still records nothing, as before"

# The records-off arms: the release clears the hold whether it had a reply or not.
for rel in 'd["last_assistant_message"]="FINAL"' 'd["last_assistant_message"]=""'; do
  p="$(newpane)"; require_pane "$p" records-off
  ROOST_RECORD_DIR="" hook "$p" working <<< "$UPS"
  ROOST_RECORD_DIR="" hook "$p" done --stop-hook <<< "$SHELL1"
  assert_eq "$(opt "$p" @roost-background)" "$(opt "$p" @agent_since) 1" "records off: the hold is recorded [$rel]"
  ROOST_RECORD_DIR="" hook "$p" done --stop-hook <<< "$(edit "$EMPTY" "$rel")"
  assert_eq "$(opt "$p" @agent_state)" "done" "records off: released [$rel]"
  pane_has "$p" @roost-background; assert_eq "$?" "1" "records off: the hold record is cleared [$rel]"
  pane_has "$p" @roost-background-types; assert_eq "$?" "1" "records off: ...and its types [$rel]"
done

# --- 3. wait-done --turn N answers for turn N only (finding 3) ----------------------
p="$(newpane)"; require_pane "$p" turn-authority
hook "$p" working <<< "$UPS"
printf '{"last_assistant_message":"TURN-ONE","background_tasks":[]}' | hook "$p" done --stop-hook
sleep 1
hook "$p" working </dev/null
hook "$p" idle --interrupted </dev/null
assert_eq "$(cat "$(recdir "$p")/replies/000002.outcome" 2>/dev/null)" "interrupted" "setup: turn 2 was interrupted"
"$ROOST" wait-done --turn 1 "$p" 3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done --turn 1 exits 0: turn 1 finished, whatever turn 2 did"
"$ROOST" wait-done --json --turn 1 "$p" 3 > "$work/j" 2>/dev/null
assert_eq "$(jget 'd["outcome"], d["turn"]' < "$work/j")" "('done', 1)" "...and --json says done for turn 1"
"$ROOST" wait-done --turn 2 "$p" 3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "5" "...while --turn 2 exits 5"

# --- 4. an outcome does not leak into the next turn (finding 4) ---------------------
p="$(newpane)"; require_pane "$p" no-leak
hook "$p" working </dev/null
hook "$p" idle --interrupted </dev/null
hook "$p" working </dev/null
pane_has "$p" @roost-ended; assert_eq "$?" "1" "a new working stamp clears the previous turn's interrupted outcome"
printf '{"last_assistant_message":"TURN TWO DONE","background_tasks":[]}' | hook "$p" done --stop-hook
"$ROOST" wait-done "$p" 3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "interrupt, prompt, finish in one second: wait-done exits 0 for the finished turn"
p="$(newpane)"; require_pane "$p" no-leak-blocked
hook "$p" working </dev/null
hook "$p" idle --interrupted </dev/null
hook "$p" blocked </dev/null
pane_has "$p" @roost-ended; assert_eq "$?" "1" "a blocked stamp clears it too"

# --- 5. a plain `working` never reads stdin (finding 5) ----------------------------
p="$(newpane)"; require_pane "$p" stdin
got="$(printf 'one\ntwo\nthree\n' | while read -r l; do hook "$p" working; hook "$p" done; printf '%s,' "$l"; done)"
assert_eq "$got" "one,two,three," "a read loop that badges itself keeps every line of its input"
X set-option -pu -t "$p" @agent_state
# The pipeline as a whole waits for `sleep 4`, so the badge is read while it
# still runs: the hook must have stamped already, not after the writer closed.
( sleep 4 | hook "$p" working ) &
bgpid=$!
sleep 1.5
assert_eq "$(opt "$p" @agent_state)" "working" "a plain working with a stdin still open lands the badge at once, not when the writer closes"
wait "$bgpid"
p="$(newpane)"; require_pane "$p" prompt-hook
hook "$p" working --prompt-hook <<< "$UPS"
assert_eq "$(opt "$p" @roost-transcript)" "$(opt "$p" @agent_since) /tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl" \
  "the UserPromptSubmit hook, with --prompt-hook, still records the transcript"
p="$(newpane)"; require_pane "$p" no-flag
hook "$p" working <<< "$UPS"
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "without the flag nothing is read and nothing recorded (an older wiring: no recovery, as before)"
hooks_ups="$("$ROOST" hooks claude | sed -n '/^{/,$p' | python3 -c 'import json,sys; print(json.load(sys.stdin)["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"])')"
assert_contains "$hooks_ups" "working --prompt-hook" "roost hooks claude wires UserPromptSubmit with --prompt-hook"

# --- 6. Esc during a hold keeps the main reply (lead 6) -----------------------------
p="$(newpane)"; require_pane "$p" esc-held
X set-option -p -t "$p" @agent_since "$STREAM_SINCE"
X set-option -p -t "$p" @agent_state working
X set-option -p -t "$p" @roost-transcript "$STREAM_SINCE $work/interrupt-stream.jsonl"
hook "$p" done --stop-hook <<< "$SHELL1"
assert_eq "$(opt "$p" @roost-background)" "$STREAM_SINCE 1" "setup: the pane is held"
"$ROOST" read "$p" >/dev/null 2>&1
pane_has "$p" @agent_state; assert_eq "$?" "1" "the Esc is recovered"
pane_has "$p" @roost-background; assert_eq "$?" "1" "...and the hold record goes with the badge"
"$ROOST" status --json > "$work/sj" 2>/dev/null
assert_eq "$(jget '[x["background"] for x in d["panes"] if x["id"]=="'"$p"'"][0]' < "$work/sj")" "None" "...so status --json says background null"
assert_eq "$(cat "$(recdir "$p")/replies/000001" 2>/dev/null)" "AFTER-TOOL" "...and the turn file keeps the held main reply"
assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome" 2>/dev/null)" "interrupted" "...with outcome interrupted"

# --- 7. a dialog during a hold keeps it a main reply (lead 7) ---------------------
PR='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"mkdir x","description":"d"}}'
p="$(newpane)"; require_pane "$p" dialog-held
hook "$p" working --prompt-hook <<< "$UPS"
hook "$p" done --stop-hook <<< "$SHELL1"
sleep 1
hook "$p" blocked --permission-request-hook <<< "$PR"
"$ROOST" read --json "$p" > "$work/rj" 2>/dev/null
assert_eq "$(jget 'd["stale"], d["final"], d["background"]' < "$work/rj")" "(False, False, 1)" "blocked during a hold: still this turn's main reply"
sleep 1
hook "$p" working --tool-hook <<< '{"tool_name":"Bash","tool_input":{"command":"mkdir x"},"tool_response":{}}'
assert_eq "$(opt "$p" @agent_state)" "working" "setup: the approved tool goes back to working"
"$ROOST" read --json "$p" > "$work/rj" 2>/dev/null
assert_eq "$(jget 'd["stale"], d["final"], d["background"]' < "$work/rj")" "(False, False, 1)" "back to working after the dialog: still the main reply, still held"
"$ROOST" status --json > "$work/sj" 2>/dev/null
assert_eq "$(jget '[x["background"] for x in d["panes"] if x["id"]=="'"$p"'"][0]' < "$work/sj")" "1" "...and status --json still counts it"

# --- 8. an outcome that cannot be written leaves no false turn (lead 8) -----------
out="$(
  . "$HERE/scripts/lib/roost-record.sh"
  ROOST_RECORD_ROOT="$work/rec8"; d="$work/rec8/1-1/9"
  roost_record_put_turn_field() { return 1; }
  roost_record_append_interrupted "$d" "" ; rc=$?
  n="$(ls "$d/replies" 2>/dev/null | grep -c '^[0-9][0-9]*$')"
  printf '%s %s' "$rc" "$n"
)"
assert_eq "$out" "1 0" "an outcome that cannot be written: non-zero, and the empty turn file is taken back"

# --- 9. a held Stop on a pane that reads blocked (non-blocking) --------------------
p="$(newpane)"; require_pane "$p" held-blocked
hook "$p" working --prompt-hook <<< "$UPS"
hook "$p" blocked --permission-request-hook <<< "$PR"
hook "$p" done --stop-hook <<< "$SHELL1"
assert_eq "$(opt "$p" @agent_state)" "blocked" "a held Stop under an open dialog is swallowed once: still blocked"
assert_eq "$(opt "$p" @roost-background)" "$(opt "$p" @agent_since) 1" "...with the hold recorded against the blocked stamp"
sleep 1
hook "$p" done --stop-hook <<< "$SHELL1"
assert_eq "$(opt "$p" @agent_state)" "working" "a second held Stop moves it to working, not done"
assert_eq "$(opt "$p" @roost-background)" "$(opt "$p" @agent_since) 1" "...and the hold record carries the new stamp"

# --- 10. the second half of each interrupt pair (non-blocking) ---------------------
# The marker newest, with the wrong record before it: the stream marker after
# the user's prompt (no partial answer), the tool marker after a tool_use (no
# rejection). Neither is the measured shape, so neither is an interrupt.
sed '2d' "$work/interrupt-stream.jsonl" > "$work/stream-no-assistant.jsonl"
sed '3d' "$work/interrupt-tool.jsonl" > "$work/tool-no-rejection.jsonl"
. "$HERE/scripts/lib/roost-unblock.sh"
engines="py"; command -v jq >/dev/null 2>&1 && engines="py jq"
for e in $engines; do
  "roost_claude_interrupted_$e" "$work/stream-no-assistant.jsonl" 1792814800; assert_eq "$?" "1" "$e: the stream marker after a user record is not an interrupt"
  "roost_claude_interrupted_$e" "$work/tool-no-rejection.jsonl" 1792814800; assert_eq "$?" "1" "$e: the tool marker after a tool_use is not an interrupt"
done

[ -z "$(find "$work/canary" -type f 2>/dev/null)" ]; assert_true $? "nothing was written under HOME or the XDG dirs"
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
