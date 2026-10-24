#!/usr/bin/env bash
# An interrupted turn is `interrupted`, not `done` and not `working for ever`
# (#95, step 2 of docs/airig/specs/2026-09-29-turn-over-design.md).
#
# Measured on Claude Code 2.1.283 and again on 2.1.310 (docs/known-gaps.md,
# "When a Claude turn is over", M5 and M6): Esc while the model streams, and
# Esc while a foreground tool runs, fire NO hook at all, so the badge
# UserPromptSubmit stamped stays ⏳ working until the next prompt. What Claude
# does write is its transcript:
#
#   mid-stream   assistant (the partial text)
#                user      text "[Request interrupted by user]"
#   mid-tool     user      tool_result "The user doesn't want to proceed…",
#                          toolDenialKind "user-rejected"
#                user      text "[Request interrupted by user for tool use]"
#
# and, unlike the declined dialog of #38, NO `system turn_duration` after
# either. tests/fixtures/claude-transcript-interrupt-{stream,tool}.jsonl are
# those two tails from the 2.1.310 run, whole lines in order from the turn's
# prompt record, with ids and paths replaced; the SINCE values below are the
# marker records' own timestamps, in whole seconds.
#
# The reader lives beside the decline reader in scripts/lib/roost-unblock.sh
# and follows its rules: the marker must be the NEWEST conversation record,
# no older than @agent_since, after skipping only the metadata types the
# decline reader skips; anything else is "could not tell" and changes nothing.
# It is consulted by send, read and wait-done for a `working` pane, and NEVER
# by status (Q6). It only UNSETS, and records @roost-ended "<since>
# interrupted" and an EMPTY turn file with an `outcome` sidecar, so turn
# numbers stay aligned with prompts (§5.4).
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
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$work"' EXIT
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
wait_for() { # wait_for PANE PATTERN
  local n=25
  while [ "$n" -gt 0 ]; do
    X capture-pane -p -t "$1" 2>/dev/null | grep -q "$2" && return 0
    sleep 0.2; n=$((n - 1))
  done
  return 1
}

STREAM_SINCE=1792814859   # the [Request interrupted by user] record: 04:07:39.513Z
TOOL_SINCE=1792814807     # the [Request interrupted by user for tool use] record: 04:06:47.296Z
ESC_SINCE=1789399020      # tests/test-claude-decline.sh's Esc-at-a-dialog capture
for f in interrupt-stream interrupt-tool no esc yes round3-running; do
  cp "$FIX/claude-transcript-$f.jsonl" "$work/$f.jsonl"
done
grep '"type":"queue-operation"' "$FIX/claude-transcript-round3-running.jsonl" | head -n 1 > "$work/queue-op.line"
[ -s "$work/queue-op.line" ]; assert_true $? "the round-3 capture holds a real queue-operation record"
cat "$work/interrupt-stream.jsonl" "$work/queue-op.line" > "$work/stream-then-unknown.jsonl"
{ cat "$work/interrupt-tool.jsonl"; printf 'not json at all\n'; } > "$work/tool-then-garbage.jsonl"
# The marker alone, with no record before it: a file that is only the
# interrupt text is not a turn roost saw.
tail -n 1 "$work/interrupt-stream.jsonl" > "$work/marker-only.jsonl"

# stamp PANE TRANSCRIPT SINCE [RECORD_SINCE] — what UserPromptSubmit leaves on a
# pane whose turn was then interrupted: working, the stamp, the transcript
# record, and the PREVIOUS turn's reply that no Stop ever replaced.
stamp() {
  X set-option -p -t "$1" @agent_since "$3"
  X set-option -p -t "$1" @agent_state working
  X set-option -p -t "$1" @roost-transcript "${4:-$3} $2"
  X set-option -p -t "$1" @roost-reply "PREVIOUS-TURN-REPLY"
}

# --- 1. the reader, both engines --------------------------------------------------
. "$HERE/scripts/lib/roost-unblock.sh"
engines="py"
command -v jq >/dev/null 2>&1 && engines="py jq"
for e in $engines; do
  fn="roost_claude_interrupted_$e"
  "$fn" "$work/interrupt-stream.jsonl" "$STREAM_SINCE"; assert_eq "$?" "0" "$e: Esc mid-stream is read as interrupted"
  "$fn" "$work/interrupt-tool.jsonl" "$TOOL_SINCE"; assert_eq "$?" "0" "$e: Esc mid-tool is read as interrupted"
  "$fn" "$work/interrupt-stream.jsonl" $((STREAM_SINCE - 30)); assert_eq "$?" "0" "$e: a stamp from before the turn's marker counts"
  "$fn" "$work/interrupt-stream.jsonl" $((STREAM_SINCE + 1)); assert_eq "$?" "1" "$e: a marker older than the stamp is an earlier turn's"
  "$fn" "$work/interrupt-tool.jsonl" $((TOOL_SINCE + 1)); assert_eq "$?" "1" "$e: ...for the tool shape too"
  "$fn" "$work/esc.jsonl" "$ESC_SINCE"; assert_eq "$?" "1" "$e: a declined dialog (its newest record is turn_duration) is not this"
  "$fn" "$work/no.jsonl" 1789398932; assert_eq "$?" "1" "$e: a No at a dialog is not this"
  "$fn" "$work/yes.jsonl" "$ESC_SINCE"; assert_eq "$?" "1" "$e: an approved dialog is not this"
  "$fn" "$work/round3-running.jsonl" 1789402300; assert_eq "$?" "1" "$e: a tool still running is not this"
  "$fn" "$work/stream-then-unknown.jsonl" "$STREAM_SINCE"; assert_eq "$?" "1" "$e: an unknown record after the marker means cannot tell"
  "$fn" "$work/tool-then-garbage.jsonl" "$TOOL_SINCE"; assert_eq "$?" "1" "$e: an unparseable line after the marker means cannot tell"
  "$fn" "$work/marker-only.jsonl" "$STREAM_SINCE"; assert_eq "$?" "1" "$e: the marker with nothing before it is not a turn"
  "$fn" "$work/absent.jsonl" "$STREAM_SINCE"; assert_eq "$?" "1" "$e: a missing transcript is not an interrupt"
  "$fn" "$work/interrupt-stream.jsonl" "abc"; assert_eq "$?" "1" "$e: a stamp that is not a number is refused"
done

# --- 2. send recovers an interrupted pane, and only by unsetting -------------------
p="$(newpane)"; require_pane "$p" send/stream
stamp "$p" "$work/interrupt-stream.jsonl" "$STREAM_SINCE"
out="$("$ROOST" send "$p" "printf 'SENT-%s\n' OK" 2>&1)"; rc=$?
assert_eq "$rc" "0" "send reaches a pane whose turn was interrupted mid-stream"
wait_for "$p" 'SENT-OK'; assert_true $? "the send is delivered"
pane_has "$p" @agent_state; assert_eq "$?" "1" "recovery UNSETS @agent_state — it never writes a value"
pane_has "$p" @roost-reply; assert_eq "$?" "1" "the previous turn's reply is cleared with it"
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "the transcript record is cleared with it"
assert_eq "$(opt "$p" @roost-ended)" "$STREAM_SINCE interrupted" "@roost-ended records '<since> interrupted'"
assert_eq "$(opt "$p" @roost-unblocked | sed 's/^[0-9]* //; s/ by=[0-9.]*$//')" "since=$STREAM_SINCE" "the clear is recorded, naming the stamp"
assert_eq "$(turns_in "$p")" "1" "ONE turn file was written for the interrupted turn"
assert_eq "$(wc -c < "$(recdir "$p")/replies/000001" | tr -d ' ')" "0" "...and it is EMPTY: the turn has no reply"
assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome")" "interrupted" "...with an outcome sidecar saying interrupted"
"$ROOST" read --turn 1 "$p" > "$work/out" 2>"$work/err"; rc=$?
assert_eq "$rc" "0" "read --turn 1 of the interrupted turn exits 0"
assert_eq "$(cat "$work/out")" "" "...prints the empty reply"
assert_contains "$(cat "$work/err")" "interrupted" "...and says on stderr the turn was interrupted"
# The next prompt is numbered after it, so "turn N = the Nth prompt" holds.
hook "$p" working </dev/null
printf '{"last_assistant_message":"NEXT"}' | hook "$p" done --stop-hook
assert_eq "$(turns_in "$p")" "2" "the next turn is recorded as turn 2"
assert_eq "$("$ROOST" read --turn 2 "$p" 2>/dev/null)" "NEXT" "...and read --turn 2 is its reply"
pane_has "$p" @roost-ended; assert_eq "$?" "1" "the next turn's working stamp clears @roost-ended: it described the interrupted turn"

# --- 3. read and wait-done recover too; status never does --------------------------
p="$(newpane)"; require_pane "$p" read/tool
stamp "$p" "$work/interrupt-tool.jsonl" "$TOOL_SINCE"
err="$("$ROOST" read "$p" 2>&1 >/dev/null)"
out="$("$ROOST" read "$p" 2>/dev/null)"
case "$err" in *"previous turn"*) r=stale ;; *) r=fresh ;; esac
assert_eq "$r" "fresh" "read does not call an interrupted pane working"
case "$out" in *PREVIOUS-TURN-REPLY*) r=served ;; *) r=not-served ;; esac
assert_eq "$r" "not-served" "read does not serve the previous turn's reply as this one's"
assert_contains "$err" "no recorded reply" "read falls back to the screen and says so"
pane_has "$p" @agent_state; assert_eq "$?" "1" "read's recovery unsets the badge too"
assert_eq "$(opt "$p" @roost-ended)" "$TOOL_SINCE interrupted" "...and records interrupted"

p="$(newpane)"; require_pane "$p" wait-done/stream
stamp "$p" "$work/interrupt-stream.jsonl" "$STREAM_SINCE"
"$ROOST" wait-done "$p" 5 >"$work/out" 2>"$work/err"; rc=$?
assert_eq "$rc" "5" "wait-done exits 5 on an interrupted pane: not done, not a timeout"
assert_eq "$(cat "$work/err")" "roost: '$p' was interrupted, not done" "...with the one stderr line"
assert_eq "$(cat "$work/out")" "" "...and nothing on stdout"
pane_has "$p" @agent_state; assert_eq "$?" "1" "wait-done's recovery unsets the badge too"
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "5" "a second wait-done on the same interrupted turn exits 5 again (the record outlives the clear)"
"$ROOST" wait-done --turn 1 "$p" 5 >/dev/null 2>"$work/err"; rc=$?
assert_eq "$rc" "5" "wait-done --turn 1 on the interrupted turn exits 5 (its outcome sidecar)"
assert_contains "$(cat "$work/err")" "turn 1 of '$p' was interrupted" "...naming the turn"
hook "$p" working </dev/null
printf '{"last_assistant_message":"NEXT"}' | hook "$p" done --stop-hook
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "after the next turn finishes, wait-done exits 0: the stamp moved, the record is stale"
"$ROOST" wait-done --turn 2 "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "...and --turn 2 (the finished turn) exits 0"
"$ROOST" wait-done --turn 1 "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "5" "...while --turn 1 (the interrupted one) still exits 5"

w="$(X new-window -d -P -F '#{window_id}' 'ENV= exec /bin/sh')"
wp="$(X display-message -p -t "$w" '#{pane_id}')"
stamp "$wp" "$work/interrupt-tool.jsonl" "$TOOL_SINCE"
"$ROOST" wait-done "$w" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "5" "wait-done on a WINDOW target recovers its interrupted pane and exits 5"

p="$(newpane)"; require_pane "$p" status
stamp "$p" "$work/interrupt-stream.jsonl" "$STREAM_SINCE"
"$ROOST" status >/dev/null 2>&1
"$ROOST" status --json >/dev/null 2>&1
assert_eq "$(opt "$p" @agent_state)" "working" "status never recovers: a read command stays a read command (Q6)"
pane_has "$p" @roost-ended; assert_eq "$?" "1" "...and records nothing"

# --- 4. everything that must stay working ------------------------------------------
# untouched PANE LABEL — send is allowed (a working pane queues), and the pane
# must be exactly as it was.
untouched() {
  "$ROOST" send "$1" "echo queued" >/dev/null 2>&1
  assert_eq "$(opt "$1" @agent_state)" "working" "the badge stays: $2"
  assert_eq "$(opt "$1" @roost-reply)" "PREVIOUS-TURN-REPLY" "the reply stays: $2"
  pane_has "$1" @roost-ended; assert_eq "$?" "1" "no outcome is recorded: $2"
  pane_has "$1" @roost-unblocked; assert_eq "$?" "1" "no clear is recorded: $2"
}
p="$(newpane)"; stamp "$p" "$work/interrupt-stream.jsonl" $((STREAM_SINCE + 1))
untouched "$p" "a marker older than the stamp (a newer prompt has started)"
p="$(newpane)"; stamp "$p" "$work/interrupt-stream.jsonl" "$STREAM_SINCE" $((STREAM_SINCE - 1))
untouched "$p" "a transcript record made for a different stamp"
p="$(newpane)"; stamp "$p" "$work/interrupt-stream.jsonl" "$STREAM_SINCE"
X set-option -pu -t "$p" @roost-transcript
untouched "$p" "no transcript record at all"
p="$(newpane)"; stamp "$p" "$work/esc.jsonl" "$ESC_SINCE"
untouched "$p" "a declined-dialog tail on a working pane"
p="$(newpane)"; stamp "$p" "$work/yes.jsonl" "$ESC_SINCE"
untouched "$p" "an approved dialog's tail"
p="$(newpane)"; stamp "$p" "$work/stream-then-unknown.jsonl" "$STREAM_SINCE"
untouched "$p" "an unknown record after the marker"
p="$(newpane)"; stamp "$p" "$work/absent.jsonl" "$STREAM_SINCE"
untouched "$p" "a transcript that does not exist"
p="$(newpane)"; stamp "$p" "interrupt-stream.jsonl" "$STREAM_SINCE"
untouched "$p" "a relative transcript path"
# a blocked pane is the decline reader's, never this one's
p="$(newpane)"; stamp "$p" "$work/interrupt-stream.jsonl" "$STREAM_SINCE"
X set-option -p -t "$p" @agent_state blocked
"$ROOST" send "$p" "echo x" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "3" "a blocked pane with an interrupt tail is still refused: the interrupt reader runs only for working"
assert_eq "$(opt "$p" @agent_state)" "blocked" "...and stays blocked"

# --- 5. the hook records the transcript at UserPromptSubmit ------------------------
UPS='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","prompt_id":"00000000-0000-4000-8000-000000000002","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"hello"}'
edit() { python3 -c 'import json,sys
d=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(d))' "$1" "$2"; }
p="$(newpane)"; require_pane "$p" ups
hook "$p" working --prompt-hook <<< "$UPS"
assert_eq "$(opt "$p" @roost-transcript)" "$(opt "$p" @agent_since) /tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl" \
  "UserPromptSubmit records '<stamp> <transcript_path>' with the working stamp"
printf '{"last_assistant_message":"R"}' | hook "$p" done --stop-hook
sleep 1
hook "$p" working --prompt-hook <<< "$(edit "$UPS" 'd["transcript_path"]="relative.jsonl"')"
assert_eq "$(opt "$p" @roost-transcript)" "" "a relative transcript_path records nothing (the old record goes: it was another stamp's)"
printf '{"last_assistant_message":"R"}' | hook "$p" done --stop-hook
sleep 1
hook "$p" working --prompt-hook <<< "$(edit "$UPS" 'd["transcript_path"]="/tmp/roost-fixture/a\tb.jsonl"')"
assert_eq "$(opt "$p" @roost-transcript)" "" "a path with a tab records nothing"
printf '{"last_assistant_message":"R"}' | hook "$p" done --stop-hook
sleep 1
X set-option -p -t "$p" @roost-transcript "1 /tmp/old"
hook "$p" working --prompt-hook </dev/null
assert_eq "$(opt "$p" @roost-transcript)" "1 /tmp/old" "working with no payload (an adapter's roost state) leaves an existing record alone"
printf '{"last_assistant_message":"R"}' | hook "$p" done --stop-hook
sleep 1
hook "$p" working --tool-hook <<< "$UPS"
assert_eq "$(opt "$p" @roost-transcript)" "1 /tmp/old" "the tool hook (PostToolUse) never reads the payload for this: hot path"
# A dialog in the same turn re-stamps the record with ITS stamp (the decline
# reader needs that); when the tool is approved and the turn goes on, the
# record must follow the new working stamp or an Esc later in the turn would
# never be recovered.
p="$(newpane)"; require_pane "$p" dialog
hook "$p" working --prompt-hook <<< "$UPS"
sleep 1
PR='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"mkdir x","description":"d"}}'
hook "$p" blocked --permission-request-hook <<< "$PR"
assert_eq "$(opt "$p" @roost-transcript)" "$(opt "$p" @agent_since) /tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl" "a dialog re-stamps the record with the blocked stamp"
sleep 1
hook "$p" working --tool-hook <<< '{"tool_name":"Bash","tool_input":{"command":"mkdir x"},"tool_response":{}}'
assert_eq "$(opt "$p" @agent_state)" "working" "the approved tool's PostToolUse clears the dialog"
assert_eq "$(opt "$p" @roost-transcript)" "$(opt "$p" @agent_since) /tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl" \
  "...and the record follows the new working stamp, so a later Esc in this turn can be read"

# --- 6. the sink's `idle --interrupted`: codex and copilot's spelling -----------------
p="$(newpane)"; require_pane "$p" sinkint
hook "$p" working </dev/null
X set-option -p -t "$p" @roost-reply "PREVIOUS-TURN-REPLY"
sleep 1
hook "$p" idle --interrupted </dev/null; rc=$?
assert_eq "$rc" "0" "idle --interrupted exits 0"
assert_eq "$(opt "$p" @agent_state)" "idle" "...and stamps idle"
assert_eq "$(opt "$p" @roost-ended)" "$(opt "$p" @agent_since) interrupted" "...with @roost-ended '<stamp> interrupted', the stamp being the new @agent_since"
pane_has "$p" @roost-reply; assert_eq "$?" "1" "...and the previous turn's reply cleared"
assert_eq "$(turns_in "$p")" "1" "...and one empty turn file"
assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome")" "interrupted" "...with its outcome sidecar"
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "5" "wait-done exits 5 for it"
hook "$p" idle --interrupted </dev/null
assert_eq "$(turns_in "$p")" "1" "a second interrupt with no prompt between is not a second turn"
assert_eq "$(opt "$p" @roost-ended)" "$(opt "$p" @agent_since) interrupted" "...and the record still agrees with the stamp"
p="$(newpane)"; require_pane "$p" statearm
hook "$p" working </dev/null
sleep 1
env TMUX="$s,$spid,0" TMUX_PANE="$p" "$ROOST" state idle --interrupted </dev/null
assert_eq "$(opt "$p" @roost-ended)" "$(opt "$p" @agent_since) interrupted" "roost state idle --interrupted reaches the sink with the flag"
p="$(newpane)"; require_pane "$p" plainidle
hook "$p" working </dev/null
sleep 1
env TMUX="$s,$spid,0" TMUX_PANE="$p" "$ROOST" state idle </dev/null
pane_has "$p" @roost-ended; assert_eq "$?" "1" "a plain idle records no outcome"
assert_eq "$(turns_in "$p")" "0" "...and no turn file"
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "...so wait-done exits 0 for it"
p="$(newpane)"; require_pane "$p" stale-ended
hook "$p" working </dev/null
X set-option -p -t "$p" @roost-ended "1 interrupted"
X set-option -pu -t "$p" @agent_state
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "an @roost-ended whose first word is not @agent_since is ignored: exit 0"

# --- 7. the canaries ------------------------------------------------------------------
[ -z "$(find "$work/canary" -type f 2>/dev/null)" ]; assert_true $? "nothing was written under HOME or the XDG dirs"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
