#!/usr/bin/env bash
# A Claude Code permission dialog answered No, or dismissed with Esc (#38).
#
# Measured on Claude Code 2.1.270 with a logger on all 32 hook events: a
# decline fires NO hook at all — not PostToolUse, not PostToolUseFailure, not
# PermissionDenied, not Stop — so the 🛑 the Notification hook stamped is never
# cleared by an event. What Claude DOES do is write the decline into its own
# transcript, the JSONL file named by `transcript_path` in every hook payload:
#
#   user    tool_result "The user doesn't want to proceed with this tool use…"
#           toolDenialKind "user-rejected"
#   user    text "[Request interrupted by user for tool use]"
#   system  turn_duration
#
# followed only by untimestamped metadata records. The Notification hook now
# records that path beside its stamp, and `send`, `read` and `wait-done` read
# the transcript on demand and clear the badge only when those three records
# are the newest conversation records AND are no older than the stamp.
#
# THE FIXTURES ARE REAL CAPTURES, TRIMMED BUT NOT EDITED
# (tests/fixtures/claude-transcript-*.jsonl). Each is a run of whole lines
# copied in order from a live transcript, starting at the transcript's line 17.
# Lines were DROPPED, never changed, and only for one reason: they carry an
# absolute home path, a personal name or address, or account ids, which
# AGENTS.md §1 keeps out of this repository. Dropped: every `bridge-session`
# record (account and organisation ids), the `attachment` records holding the
# system prompt (line 26 in the no/esc/yes captures sits BETWEEN the
# tool_result and the interrupt text), and `stop_hook_summary` records (hook
# command paths). The live test tests/live/claude-decline-smoke.sh runs the
# same reader against untrimmed transcripts, which is what covers the dropped
# in-between attachment.
#
#   claude-transcript-no.jsonl              `3. No`   (lines 17-33)
#   claude-transcript-esc.jsonl             Esc       (lines 17-33)
#   claude-transcript-yes.jsonl             `1. Yes`, the tool ran (17-37)
#   claude-transcript-round3-running.jsonl  turn 1 declined, turn 2 background
#                                           tool, turn 3 APPROVED and its tool
#                                           still running at copy time (17-61)
#
# The SINCE values below are the real Notification hook times (whole seconds)
# from the same captures' hook logs.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
STATE="$HERE/scripts/roost-agent-state"
FIX="$HERE/tests/fixtures"

# roost-agent-state only acts on a socket whose path ends in /roost, so build
# one directly rather than via roost_test_server, as tests/test-codex-hook.sh
# does.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
work="$(mktemp -d /tmp/amx.XXXX)"
trap 'tmux -S "$s" kill-server 2>/dev/null; chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$sdir" "$work"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'ENV= exec /bin/sh'
export ROOST_SOCKET="$s"

X() { tmux -S "$s" "$@"; }
newpane() { X new-window -d -P -F '#{pane_id}' 'ENV= exec /bin/sh'; }
opt() { X show-options -pqv -t "$1" "$2" 2>/dev/null; }
# pane_has PANE OPTION -> 0 if OPTION is set at PANE scope at all. An unset is
# the only clear this design allows, so "is it empty" is not the question: a
# value of "" or "idle" written by mistake is a SET, and must fail here.
pane_has() { X show-options -p -t "$1" 2>/dev/null | grep -q "^$2 "; }
wait_for() { # wait_for PANE PATTERN
  local n=25
  while [ "$n" -gt 0 ]; do
    X capture-pane -p -t "$1" 2>/dev/null | grep -q "$2" && return 0
    sleep 0.2; n=$((n - 1))
  done
  return 1
}

# Real Notification times, from the hook logs of the same captures.
NO_SINCE=1789398932        # decline records at 15:15:41Z = 1789398941
ESC_SINCE=1789399020       # decline records at 15:17:04Z = 1789399024
YES_SINCE=1789399020
R3_SINCE=1789402420        # turn 3's dialog; turn 1's decline was 1789402311
NO_DECLINE_SECOND=1789398941

for f in no esc yes round3-running; do
  cp "$FIX/claude-transcript-$f.jsonl" "$work/$f.jsonl"
done

# stamp PANE TRANSCRIPT SINCE [RECORD_SINCE] — what the Notification hook
# leaves on a pane, plus the previous turn's reply that a declined turn never
# replaces (Stop does not fire).
stamp() {
  X set-option -p -t "$1" @agent_since "$3"
  X set-option -p -t "$1" @agent_state blocked
  X set-option -p -t "$1" @roost-transcript "${4:-$3} $2"
  X set-option -p -t "$1" @roost-reply "PREVIOUS-TURN-REPLY"
}

# --- 1. the transcript reader, both engines ---------------------------------
. "$HERE/scripts/lib/roost-unblock.sh"
engines="py"
command -v jq >/dev/null 2>&1 && engines="py jq"
for e in $engines; do
  fn="roost_claude_declined_$e"
  "$fn" "$work/no.jsonl" "$NO_SINCE"; assert_eq "$?" "0" "$e: a real No is read as declined"
  "$fn" "$work/esc.jsonl" "$ESC_SINCE"; assert_eq "$?" "0" "$e: a real Esc is read as declined"
  "$fn" "$work/no.jsonl" "$NO_DECLINE_SECOND"; assert_eq "$?" "0" "$e: a decline in the stamp's own second counts"
  "$fn" "$work/yes.jsonl" "$YES_SINCE"; assert_eq "$?" "1" "$e: an approved dialog is not a decline"
  "$fn" "$work/round3-running.jsonl" "$R3_SINCE"; assert_eq "$?" "1" \
    "$e: round 3 — an old decline under an approved, still-running tool is not a decline"
  "$fn" "$work/round3-running.jsonl" 1789402300; assert_eq "$?" "1" \
    "$e: round 3 stays refused even with a stamp older than the old decline"
  "$fn" "$work/no.jsonl" $((NO_DECLINE_SECOND + 1)); assert_eq "$?" "1" \
    "$e: a decline older than the stamp belongs to an earlier dialog"
  "$fn" "$work/absent.jsonl" "$NO_SINCE"; assert_eq "$?" "1" "$e: a missing transcript is not a decline"
done

# Records appended to a real decline. Whole real lines only: a queue-operation
# record from the round-3 capture (a record type the reader does not know), and
# a line that is not JSON.
grep '"type":"queue-operation"' "$FIX/claude-transcript-round3-running.jsonl" | head -n 1 > "$work/queue-op.line"
[ -s "$work/queue-op.line" ]; assert_true $? "the round-3 capture holds a real queue-operation record"
cat "$work/no.jsonl" "$work/queue-op.line" > "$work/no-then-unknown.jsonl"
{ cat "$work/no.jsonl"; printf 'not json at all\n'; } > "$work/no-then-garbage.jsonl"
for e in $engines; do
  fn="roost_claude_declined_$e"
  "$fn" "$work/no-then-unknown.jsonl" "$NO_SINCE"; assert_eq "$?" "1" \
    "$e: an unknown record type after the decline means cannot tell"
  "$fn" "$work/no-then-garbage.jsonl" "$NO_SINCE"; assert_eq "$?" "1" \
    "$e: an unparseable line after the decline means cannot tell"
done

# --- 2. send clears a declined pane, and only by unsetting ------------------
p="$(newpane)"; require_pane "$p" "send/no"
stamp "$p" "$work/no.jsonl" "$NO_SINCE"
out="$("$ROOST" send "$p" "printf 'SENT-%s\n' OK" 2>&1)"; rc=$?
assert_eq "$rc" "0" "send reaches a pane whose dialog was declined (No)"
wait_for "$p" 'SENT-OK'; assert_true $? "the send after a declined dialog is delivered"
pane_has "$p" @agent_state; assert_eq "$?" "1" "recovery UNSETS @agent_state — it never writes a value"
pane_has "$p" @roost-reply; assert_eq "$?" "1" "the previous turn's reply is cleared with it"
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "the transcript record is cleared with it"
assert_eq "$(opt "$p" @roost-unblocked | sed 's/^[0-9]* //')" "since=$NO_SINCE" \
  "the clear is recorded on the pane, naming the stamp it cleared"

# --- 3. wait-done and read ---------------------------------------------------
p="$(newpane)"; require_pane "$p" "wait-done/esc"
stamp "$p" "$work/esc.jsonl" "$ESC_SINCE"
"$ROOST" wait-done "$p" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done returns on a pane whose dialog was dismissed (Esc)"
pane_has "$p" @agent_state; assert_eq "$?" "1" "wait-done's recovery unsets the badge too"

p="$(newpane)"; require_pane "$p" "read/no"
stamp "$p" "$work/no.jsonl" "$NO_SINCE"
err="$("$ROOST" read "$p" 2>&1 >/dev/null)"
out="$("$ROOST" read "$p" 2>/dev/null)"
case "$err" in *"is blocked"*) r=stale ;; *) r=fresh ;; esac
assert_eq "$r" "fresh" "read does not call a declined pane blocked"
case "$out" in *PREVIOUS-TURN-REPLY*) r=served ;; *) r=not-served ;; esac
assert_eq "$r" "not-served" "read does not serve the previous turn's reply as this one's"
pane_has "$p" @agent_state; assert_eq "$?" "1" "read's recovery unsets the badge too"

w="$(X new-window -d -P -F '#{window_id}' 'ENV= exec /bin/sh')"
wp="$(X display-message -p -t "$w" '#{pane_id}')"
stamp "$wp" "$work/esc.jsonl" "$ESC_SINCE"
"$ROOST" wait-done "$w" 5 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "wait-done on a WINDOW target recovers its declined pane"

# --- 4. everything that must stay blocked -----------------------------------
# refused PANE LABEL — send must exit 3, and the pane must be untouched.
refused() {
  "$ROOST" send "$1" "echo should-not-arrive" >/dev/null 2>&1
  assert_eq "$?" "3" "send refuses: $2"
  assert_eq "$(opt "$1" @agent_state)" "blocked" "the badge stays: $2"
  assert_eq "$(opt "$1" @roost-reply)" "PREVIOUS-TURN-REPLY" "the reply stays: $2"
  pane_has "$1" @roost-unblocked; assert_eq "$?" "1" "no clear is recorded: $2"
}

p="$(newpane)"; stamp "$p" "$work/yes.jsonl" "$YES_SINCE"
refused "$p" "an approved dialog (the real Yes capture)"

p="$(newpane)"; stamp "$p" "$work/round3-running.jsonl" "$R3_SINCE"
refused "$p" "round 3 — old decline, new approved tool still running"
"$ROOST" wait-done "$p" 2 >/dev/null 2>&1
assert_eq "$?" "1" "wait-done keeps waiting on round 3 (times out)"
err="$("$ROOST" read "$p" 2>&1 >/dev/null)"
assert_contains "$err" "is blocked" "read still calls round 3 blocked"

p="$(newpane)"; stamp "$p" "$work/no.jsonl" $((NO_DECLINE_SECOND + 1))
refused "$p" "a decline older than the stamp"

p="$(newpane)"; stamp "$p" "$work/no.jsonl" "$NO_SINCE" $((NO_SINCE - 1))
refused "$p" "a transcript record made for a different stamp"

p="$(newpane)"; stamp "$p" "$work/no.jsonl" "$NO_SINCE"
X set-option -pu -t "$p" @roost-transcript
refused "$p" "no transcript record at all (a hook wired before #38)"

p="$(newpane)"; stamp "$p" "$work/absent.jsonl" "$NO_SINCE"
refused "$p" "a transcript that does not exist"

p="$(newpane)"; stamp "$p" "no.jsonl" "$NO_SINCE"
refused "$p" "a relative transcript path"

p="$(newpane)"; stamp "$p" "$work/no-then-garbage.jsonl" "$NO_SINCE"
refused "$p" "an unparseable transcript tail"

p="$(newpane)"; stamp "$p" "$work/no-then-unknown.jsonl" "$NO_SINCE"
refused "$p" "an unknown record after the decline"

if [ "$(id -u)" != "0" ]; then
  cp "$work/no.jsonl" "$work/locked.jsonl"; chmod 000 "$work/locked.jsonl"
  p="$(newpane)"; stamp "$p" "$work/locked.jsonl" "$NO_SINCE"
  refused "$p" "an unreadable transcript"
fi

# --- 5. the Notification hook records the transcript beside its stamp -------
# The payload's keys are the real Notification payload's (Claude Code 2.1.270,
# the `No` capture). Its path fields are rewritten to the scratch copy, because
# the capture's own transcript_path is under an absolute home path.
p="$(newpane)"; require_pane "$p" "hook"
payload='{"session_id":"00000000-1aea-4f41-85d6-9893b49b6ad7","transcript_path":"'"$work/no.jsonl"'","cwd":"'"$work"'","prompt_id":"00000000-46a9-4e46-8a1a-8fe2b9e945c2","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}'
printf '%s' "$payload" | env TMUX="$s,0,0" TMUX_PANE="$p" "$STATE" blocked --notification-hook
assert_eq "$(opt "$p" @agent_state)" "blocked" "the Notification hook still stamps blocked"
assert_eq "$(opt "$p" @roost-transcript)" "$(opt "$p" @agent_since) $work/no.jsonl" \
  "...and records the transcript under the SAME stamp"

p="$(newpane)"
printf '%s' "$payload" | env TMUX="$s,0,0" TMUX_PANE="$p" "$STATE" blocked
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "without --notification-hook nothing is recorded (codex, roost state)"

p="$(newpane)"
printf '%s' '{"transcript_path":"relative/t.jsonl"}' | env TMUX="$s,0,0" TMUX_PANE="$p" "$STATE" blocked --notification-hook
assert_eq "$(opt "$p" @agent_state)" "blocked" "a bad transcript_path still stamps blocked"
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "...but records no relative path"

p="$(newpane)"
env TMUX="$s,0,0" TMUX_PANE="$p" "$STATE" working
printf '%s' "$payload" | env TMUX="$s,0,0" TMUX_PANE="$p" "$STATE" working --notification-hook
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "--notification-hook records only with blocked"

# --- 6. roost doctor names a long-stuck pane, and changes nothing -----------
now="$(date +%s)"
p_old="$(newpane)"; stamp "$p_old" "$work/yes.jsonl" $((now - 4000))
p_dialog="$(newpane)"; stamp "$p_dialog" "$work/yes.jsonl" $((now - 4000))
X send-keys -t "$p_dialog" "printf '%s\\n' 'Do you want to proceed?' '❯ 1. Yes' '  3. No' 'Esc to cancel'" Enter
wait_for "$p_dialog" '^Do you want to proceed'
p_new="$(newpane)"; stamp "$p_new" "$work/yes.jsonl" "$now"
dhome="$work/dhome"; mkdir -p "$dhome"
dout="$(cd "$work" && env HOME="$dhome" XDG_CONFIG_HOME="$dhome/x" XDG_DATA_HOME="$dhome/d" \
  COPILOT_HOME="$dhome/c" PI_CODING_AGENT_DIR="$dhome/p" CODEX_HOME="$dhome/cx" \
  CLAUDE_SETTINGS="$dhome/s.json" ROOST_CONFIG_SOCK="$s" ROOST_NOTIFY_SOCK=/nonexistent/sock \
  "$HERE/scripts/roost-doctor" 2>&1)"
line="$(printf '%s\n' "$dout" | grep "may be stuck" | grep -F "$p_old" || true)"
assert_contains "$line" "$p_old" "doctor names a pane blocked for over an hour with no dialog on screen"
printf '%s\n' "$dout" | grep "may be stuck" | grep -qF "$p_dialog"
assert_eq "$?" "1" "doctor does not name a pane whose dialog is on screen"
printf '%s\n' "$dout" | grep "may be stuck" | grep -qF "$p_new"
assert_eq "$?" "1" "doctor does not name a freshly blocked pane"
assert_eq "$(opt "$p_old" @agent_state)" "blocked" "doctor changes no state"
assert_eq "$(opt "$p_old" @roost-reply)" "PREVIOUS-TURN-REPLY" "doctor clears no reply"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
