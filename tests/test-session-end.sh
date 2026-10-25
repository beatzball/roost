#!/usr/bin/env bash
# Claude's SessionEnd releases a pane held by background work (#188).
#
# Since #97 a Claude Stop whose background_tasks lists running work holds the
# pane at working until the Stop that releases it. A Claude that exits first
# fires SessionEnd and no Stop (measured on 2.1.310: `/exit`, Ctrl-C twice,
# TERM, HUP and `respawn-pane -k`; tests/fixtures/claude-session-end.json is
# that payload's shape, scrubbed), so before this the pane read working for
# ever. `--session-end-hook` unsets the badge, records outcome `died`, and
# keeps the held main reply as the prompt's turn -- and changes NOTHING on a
# pane that is not held, or held by another session. The session that holds
# a pane is named by @roost-background-session, which the held Stop writes;
# a late SessionEnd from an older session (after `respawn-pane -k`) must not
# release the newer one's turn, and a SessionEnd that loses a race files no
# turn (flock round 1 on #188, sections 6 and 7). `clear` and `resume` end the
# session but not the agent, so they record `interrupted` (section 8).
#
# No real Claude: fixture payloads into scripts/roost-agent-state, on a
# throwaway -S socket, with every home pointed at a canary.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
DOC="$HERE/scripts/roost-doctor"
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
edit() { python3 -c 'import json,sys
d=json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(d))' "$1" "$2"; }
# Every pane option, for "changed nothing": the whole set, compared before and after.
snap() { X show-options -p -t "$1" 2>/dev/null | sort; }

SHELL1="$(cat "$FIX/claude-stop-bg-shell.json")"
SEND="$(cat "$FIX/claude-session-end.json")"
# The prompt of the same session: SessionEnd names the transcript this records.
UPS="$(edit "$SEND" 'd["hook_event_name"]="UserPromptSubmit"; d["prompt"]="hello"; d["permission_mode"]="default"; del d["reason"]')"
# held PANE [REPLY] -- a prompt, then a Stop with one running shell: held.
held() {
  hook "$1" working --prompt-hook <<< "$UPS"
  hook "$1" done --stop-hook <<< "$(edit "$SHELL1" "d['last_assistant_message']='${2-MAIN-ANSWER}'")"
}

# --- 1. a held pane is released as died --------------------------------------
p="$(newpane)"; require_pane "$p" held
held "$p"
since="$(opt "$p" @agent_since)"
assert_eq "$(opt "$p" @agent_state)|$(opt "$p" @roost-background)" "working|$since 1" "setup: the pane is held for its stamp"
hook "$p" --session-end-hook <<< "$SEND"; rc=$?
assert_eq "$rc" "0" "the SessionEnd hook exits 0"
pane_has "$p" @agent_state; assert_eq "$?" "1" "a held pane's badge is UNSET by SessionEnd -- not done"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "...with outcome died for the stamp it held"
pane_has "$p" @roost-background; assert_eq "$?" "1" "...the hold record cleared"
pane_has "$p" @roost-background-types; assert_eq "$?" "1" "...and its types"
pane_has "$p" @roost-background-session; assert_eq "$?" "1" "...and its owner"
pane_has "$p" @roost-transcript; assert_eq "$?" "1" "...and the transcript record, the session is over"
assert_eq "$(turns_in "$p")" "1" "the prompt has ONE turn file"
assert_eq "$(cat "$(recdir "$p")/replies/000001" 2>/dev/null)" "MAIN-ANSWER" "...holding the held main reply"
assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome" 2>/dev/null)" "died" "...whose outcome is died"
assert_eq "$(opt "$p" @roost-reply)|$(opt "$p" @roost-reply-turn)" "MAIN-ANSWER|1" "the main reply stays on the pane, pointing at that turn"
"$ROOST" wait-done "$p" 3 >/dev/null 2>"$work/wd.err"; rc=$?
assert_eq "$rc" "2" "wait-done on the released pane exits 2 (died), not 0 and not a timeout"
assert_contains "$(cat "$work/wd.err")" "background work still ran" "...and says why"
"$ROOST" wait-done --turn 1 "$p" 3 >/dev/null 2>"$work/wd.err"; rc=$?
assert_eq "$rc" "2" "wait-done --turn 1 exits 2 from the turn's own outcome"
"$ROOST" wait-done --json "$p" 3 > "$work/wd.json" 2>/dev/null
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outcome"])' "$work/wd.json" 2>/dev/null)" "died" "wait-done --json says outcome died"
out="$("$ROOST" read "$p" 2>"$work/read.err")"
assert_eq "$out" "MAIN-ANSWER" "read prints the main reply"
assert_contains "$(cat "$work/read.err")" "died: the agent exited before its background work finished" "...and says on stderr the work never reported back"
"$ROOST" read --turn 1 "$p" >/dev/null 2>"$work/read.err"
assert_contains "$(cat "$work/read.err")" "turn 1 of '$p' died" "read --turn 1 says that turn died"
ev="$(cat "$ROOST_RECORD_DIR"/events/* 2>/dev/null | grep "\"pane\":\"$p\"" | tail -1)"
assert_contains "$ev" '"from":"working","to":null,"turn":1' "the event log has the release: working to no badge, turn 1"

# The next prompt in that pane is a new turn, and the outcome does not leak.
hook "$p" working --prompt-hook <<< "$UPS"
pane_has "$p" @roost-ended; assert_eq "$?" "1" "a new prompt clears the died outcome"
printf '{"last_assistant_message":"NEXT","background_tasks":[]}' | hook "$p" done --stop-hook
assert_eq "$(cat "$(recdir "$p")/replies/000002" 2>/dev/null)" "NEXT" "...and the next prompt is turn 2"
"$ROOST" wait-done "$p" 3 >/dev/null 2>&1; assert_eq "$?" "0" "...which wait-done calls done"

# --- 2. a pane that is not held is left alone ---------------------------------
p="$(newpane)"; require_pane "$p" working-not-held
hook "$p" working --prompt-hook <<< "$UPS"
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(snap "$p")" "$before" "a working pane with no hold: SessionEnd changes no option"
assert_eq "$(turns_in "$p")" "0" "...and records nothing"

p="$(newpane)"; require_pane "$p" done-pane
hook "$p" working --prompt-hook <<< "$UPS"
printf '{"last_assistant_message":"FIN","background_tasks":[]}' | hook "$p" done --stop-hook
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(snap "$p")" "$before" "a done pane: SessionEnd changes no option"
assert_eq "$(turns_in "$p")" "1" "...and records nothing more"

# A hold record from an OLDER stamp is not a hold.
p="$(newpane)"; require_pane "$p" stale-hold
hook "$p" working --prompt-hook <<< "$UPS"
X set-option -p -t "$p" @roost-background "1000000000 1"
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(snap "$p")" "$before" "a hold record for another stamp: SessionEnd changes nothing"

# --- 3. another session's SessionEnd changes nothing --------------------------
p="$(newpane)"; require_pane "$p" other-session
held "$p"
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$(edit "$SEND" 'd["session_id"]="00000000-0000-4000-8000-000000000999"; d["transcript_path"]="/tmp/roost-fixture/home/.claude/projects/-tmp-roost-fixture-proj/00000000-0000-4000-8000-000000000999.jsonl"')"
assert_eq "$(snap "$p")" "$before" "a SessionEnd from another session (session id mismatch): the hold stays"
assert_eq "$(turns_in "$p")" "0" "...and nothing is recorded"
for bad in 'del d["session_id"]' 'd["session_id"]=7' 'd["session_id"]="a b"' 'd["session_id"]=""' 'd=[]'; do
  hook "$p" --session-end-hook <<< "$(edit "$SEND" "$bad")"
  assert_eq "$(snap "$p")" "$before" "a SessionEnd that names no session cannot release: [$bad]"
done
hook "$p" --session-end-hook <<< "not json"
assert_eq "$(snap "$p")" "$before" "an unreadable SessionEnd payload changes nothing"
# The session's own SessionEnd still releases it afterwards.
hook "$p" --session-end-hook <<< "$SEND"
pane_has "$p" @agent_state; assert_eq "$?" "1" "...and the session's own SessionEnd then releases it"

# A hold with no owner -- written before #188, or by a Stop with no usable
# session id: could not tell.
p="$(newpane)"; require_pane "$p" no-owner
hook "$p" working --prompt-hook <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'del d["session_id"]')"
pane_has "$p" @roost-background-session; assert_eq "$?" "1" "setup: a held Stop with no session id writes no owner"
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(snap "$p")" "$before" "no owner to match: the hold stays (the safe direction)"
# A held pane with no transcript record (a wiring older than --prompt-hook)
# is still owned by its Stop's session, and released by it.
p="$(newpane)"; require_pane "$p" no-record
hook "$p" working <<< "$UPS"
hook "$p" done --stop-hook <<< "$SHELL1"
hook "$p" --session-end-hook <<< "$SEND"
pane_has "$p" @agent_state; assert_eq "$?" "1" "no @roost-transcript: the owner the held Stop wrote still releases it"

# A hand-typed flag at a terminal must not wait on stdin, nor release.
p="$(newpane)"; require_pane "$p" tty
held "$p"
before="$(snap "$p")"
if [ -r /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
  hook "$p" --session-end-hook < /dev/tty
  assert_eq "$(snap "$p")" "$before" "a tty stdin: nothing is read and nothing changes"
fi

# --- 4. the other shapes of a held turn ---------------------------------------
# A hold whose main Stop carried no reply: an EMPTY died turn keeps the number.
p="$(newpane)"; require_pane "$p" held-empty
held "$p" ""
hook "$p" --session-end-hook <<< "$SEND"
pane_has "$p" @agent_state; assert_eq "$?" "1" "a hold with no main reply is released too"
assert_eq "$(turns_in "$p")" "1" "...with ONE turn file"
assert_eq "$(wc -c < "$(recdir "$p")/replies/000001" | tr -d ' ')" "0" "...an empty one"
assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome" 2>/dev/null)" "died" "...whose outcome is died"
pane_has "$p" @roost-reply-turn; assert_eq "$?" "1" "...and no pointer, since there is no reply to pair it with"

# Records off: the release still happens, and the main reply stays on the pane.
p="$(newpane)"; require_pane "$p" records-off
ROOST_RECORD_DIR="" hook "$p" working --prompt-hook <<< "$UPS"
ROOST_RECORD_DIR="" hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["last_assistant_message"]="KEPT"')"
since="$(opt "$p" @agent_since)"
ROOST_RECORD_DIR="" hook "$p" --session-end-hook <<< "$SEND"
pane_has "$p" @agent_state; assert_eq "$?" "1" "records off: released"
assert_eq "$(opt "$p" @roost-ended)" "$since died" "records off: outcome died"
assert_eq "$(opt "$p" @roost-reply)" "KEPT" "records off: the main reply stays on the pane"
ROOST_RECORD_DIR="" "$ROOST" wait-done "$p" 3 >/dev/null 2>&1; assert_eq "$?" "2" "records off: wait-done exits 2"

# A count roost could not read (`?`) holds, and releases the same way.
p="$(newpane)"; require_pane "$p" held-unknown
hook "$p" working --prompt-hook <<< "$UPS"
hook "$p" done --stop-hook <<< "$(edit "$SHELL1" 'd["background_tasks"]="nonsense"')"
assert_eq "$(opt "$p" @roost-background)" "$(opt "$p" @agent_since) ?" "setup: a '?' hold"
hook "$p" --session-end-hook <<< "$SEND"
pane_has "$p" @agent_state; assert_eq "$?" "1" "a ? hold is released by SessionEnd"

# A hold record that is not one the hook wrote cannot reach the tmux format.
p="$(newpane)"; require_pane "$p" forged
hook "$p" working --prompt-hook <<< "$UPS"
X set-option -p -t "$p" @roost-background "$(opt "$p" @agent_since) 1},x"
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(snap "$p")" "$before" "a hold count that is not digits or ? changes nothing"

# --- 6. a late SessionEnd from an OLD session after a respawn (flock round 1) --
# Session A holds the pane; `respawn-pane -k` starts session B in it; B's
# prompt lands on a pane that already reads working (the unchanged-state
# bail); A's SessionEnd arrives seconds later. It must release nothing.
SID_B="00000000-0000-4000-8000-0000000000bb"
TR_B="/tmp/roost-fixture/home/.claude/projects/-tmp-roost-fixture-proj/$SID_B.jsonl"
UPS_B="$(edit "$UPS" "d['session_id']='$SID_B'; d['transcript_path']='$TR_B'")"
SEND_B="$(edit "$SEND" "d['session_id']='$SID_B'; d['transcript_path']='$TR_B'; d['reason']='other'")"
SEND_A="$(edit "$SEND" 'd["reason"]="other"')"
SHELL_B="$(edit "$SHELL1" "d['session_id']='$SID_B'; d['transcript_path']='$TR_B'; d['last_assistant_message']='B MAIN'")"

for when in after-prompt after-held-stop; do
  p="$(newpane)"; require_pane "$p" "respawn-$when"
  held "$p" "A MAIN"
  since="$(opt "$p" @agent_since)"
  assert_eq "$(opt "$p" @roost-background-session)" "$since 00000000-0000-4000-8000-000000000001" "[$when] setup: the held Stop names session A as the owner"
  X respawn-pane -k -t "$p" 'ENV= exec /bin/sh'
  hook "$p" working --prompt-hook <<< "$UPS_B"
  assert_eq "$(opt "$p" @agent_state)|$(opt "$p" @agent_since)" "working|$since" "[$when] setup: B's prompt bails on the working pane, stamp unchanged"
  assert_eq "$(opt "$p" @roost-background-session)" "$since $SID_B" "[$when] B's prompt on the held pane names B as the owner"
  if [ "$when" = after-held-stop ]; then
    hook "$p" done --stop-hook <<< "$SHELL_B"
    assert_eq "$(opt "$p" @roost-reply)|$(opt "$p" @roost-background-session)" "B MAIN|$since $SID_B" "[$when] setup: B holds the pane with its own main reply"
  fi
  before="$(snap "$p")"
  hook "$p" --session-end-hook <<< "$SEND_A"
  assert_eq "$(snap "$p")" "$before" "[$when] A's late SessionEnd releases nothing: B's turn stays held"
  assert_eq "$(turns_in "$p")" "0" "[$when] ...and files no turn"
  hook "$p" --session-end-hook <<< "$SEND_B"
  assert_eq "$(opt "$p" @agent_state)|$(opt "$p" @roost-ended)" "|$since died" "[$when] B's own SessionEnd then releases it"
  assert_eq "$(turns_in "$p")" "1" "[$when] ...as ONE turn"
done

# A prompt with no usable session id on a held pane: the owner is removed,
# not kept, so no SessionEnd can release the hold.
p="$(newpane)"; require_pane "$p" prompt-no-id
held "$p"
hook "$p" working --prompt-hook <<< "$(edit "$UPS" 'del d["session_id"]')"
pane_has "$p" @roost-background-session; assert_eq "$?" "1" "a prompt with no session id on a held pane unsets the owner"
before="$(snap "$p")"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(snap "$p")" "$before" "...and then even the first session's SessionEnd changes nothing"
# A prompt on a working pane that is NOT held writes no owner.
p="$(newpane)"; require_pane "$p" prompt-not-held
hook "$p" working --prompt-hook <<< "$UPS"
hook "$p" working --prompt-hook <<< "$UPS_B"
pane_has "$p" @roost-background-session; assert_eq "$?" "1" "a repeat prompt on a pane that is not held writes no owner"

# A dialog inside the held turn moves the stamp; the owner moves with it.
PR='{"session_id":"00000000-0000-4000-8000-000000000001","transcript_path":"/tmp/roost-fixture/00000000-0000-4000-8000-000000000001.jsonl","cwd":"/tmp/roost-fixture/proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"mkdir x","description":"d"}}'
p="$(newpane)"; require_pane "$p" dialog-held
held "$p"
sleep 1
hook "$p" blocked --permission-request-hook <<< "$PR"
sleep 1
hook "$p" working --tool-hook <<< '{"tool_name":"Bash","tool_input":{"command":"mkdir x"},"tool_response":{}}'
since="$(opt "$p" @agent_since)"
assert_eq "$(opt "$p" @roost-background-session)" "$since 00000000-0000-4000-8000-000000000001" "a dialog in a held turn carries the owner onto the new stamp"
hook "$p" --session-end-hook <<< "$SEND"
assert_eq "$(opt "$p" @agent_state)|$(opt "$p" @roost-ended)" "|$since died" "...and the session's SessionEnd still releases it"

# --- 7. a SessionEnd that loses the race files nothing (flock round 1) ---------
# A tmux shim pauses A's SessionEnd at its reply read -- after it has read the
# pane and matched the owner, before the release. In that pause A's final
# Stop records turn 1 and a new prompt holds the pane with a newer stamp. The
# release must then be refused, and with it the turn: no file, no number.
shim="$work/shim"; mkdir -p "$shim"
real_tmux="$(command -v tmux)"
ORIG_PATH="$PATH"
cat > "$shim/tmux" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *" show-options -pqv -t "*" @roost-reply "*)
    if [ ! -e "$work/raced" ]; then
      : > "$work/raced"
      PATH="$ORIG_PATH" bash "$work/race.sh" >/dev/null 2>&1
    fi ;;
esac
exec "$real_tmux" "\$@"
SHIM
chmod +x "$shim/tmux"
p="$(newpane)"; require_pane "$p" race
held "$p" "A MAIN"
sleep 1
cat > "$work/race.sh" <<RACE
printf '%s' '{"session_id":"00000000-0000-4000-8000-000000000001","last_assistant_message":"A FINAL","background_tasks":[]}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p" ROOST_RECORD_DIR="$ROOST_RECORD_DIR" "$HOOK" done --stop-hook
sleep 1
printf '%s' '$UPS_B' | env TMUX="$s,$spid,0" TMUX_PANE="$p" ROOST_RECORD_DIR="$ROOST_RECORD_DIR" "$HOOK" working --prompt-hook
printf '%s' '$SHELL_B' | env TMUX="$s,$spid,0" TMUX_PANE="$p" ROOST_RECORD_DIR="$ROOST_RECORD_DIR" "$HOOK" done --stop-hook
RACE
rm -f "$work/raced"
PATH="$shim:$PATH" hook "$p" --session-end-hook <<< "$SEND_A"
[ -e "$work/raced" ]; assert_true $? "setup: the shim ran the race inside A's SessionEnd"
nsince="$(opt "$p" @agent_since)"
assert_eq "$(opt "$p" @agent_state)|$(opt "$p" @roost-background)|$(opt "$p" @roost-background-session)" "working|$nsince 1|$nsince $SID_B" "the stale release is refused: B's hold is intact"
pane_has "$p" @roost-ended; assert_eq "$?" "1" "...no outcome is written"
assert_eq "$(turns_in "$p")" "1" "...and the turns are unchanged: only A's final turn"
assert_eq "$(cat "$(recdir "$p")/replies/000001" 2>/dev/null)" "A FINAL" "...turn 1 is A's final reply"
[ ! -e "$(recdir "$p")/replies/000001.outcome" ]; assert_true $? "...with no died outcome"
printf '%s' '{"session_id":"'"$SID_B"'","last_assistant_message":"B FINAL","background_tasks":[]}' | hook "$p" done --stop-hook
assert_eq "$(cat "$(recdir "$p")/replies/000002" 2>/dev/null)" "B FINAL" "B's release is turn 2, the number its prompt had"
"$ROOST" wait-done --turn 2 "$p" 3 >/dev/null 2>&1; assert_eq "$?" "0" "...and wait-done --turn 2 calls it done"

# --- 9. a new session inside the release-to-file gap (flock round 2) ------------
# A's SessionEnd release LANDS; a respawned Claude B then prompts and finishes
# before A has filed the ended turn. Three pauses, all after the release:
#   before-confirm  at A's read-back of its own release
#   after-confirm   at the turn file's temp file, after the read-back passed
#   after-file      at the last tmux command, after the turn file landed
# Each runs B to completion INSIDE the pause, synchronously, which is the
# hardest schedule: A cannot move until B is done. In every one, turn 1 is
# A's main reply with outcome died and B's answer is turn 2. Before the fix,
# before-confirm lost A's turn (the read-back saw B's badge and filed
# nothing) and after-confirm filed it as turn 2, under B's turn 1.
cat > "$shim/tmux" <<SHIM
#!/usr/bin/env bash
case "\$GAP_MODE: \$* " in
  "before-confirm:"*" display-message -p -t "*"#{@agent_state}|#{@roost-ended}|#{@roost-session-ended}"*|\
  "after-file:"*" if-shell -F -t "*"#{==:#{@roost-session-ended},"*)
    if [ ! -e "$work/gapped" ]; then
      : > "$work/gapped"
      PATH="$ORIG_PATH" bash "$work/gap.sh" >/dev/null 2>&1
    fi ;;
esac
exec "$real_tmux" "\$@"
SHIM
cat > "$shim/mktemp" <<SHIM
#!/usr/bin/env bash
case "\$GAP_MODE:\$*" in
  after-confirm:*/replies/.tmp.*)
    if [ ! -e "$work/gapped" ]; then
      : > "$work/gapped"
      PATH="$ORIG_PATH" bash "$work/gap.sh" >/dev/null 2>&1
    fi ;;
esac
PATH="$ORIG_PATH" exec mktemp "\$@"
SHIM
chmod +x "$shim/tmux" "$shim/mktemp"
for mode in before-confirm after-confirm after-file; do
  p="$(newpane)"; require_pane "$p" "gap-$mode"
  held "$p" "A MAIN"
  since="$(opt "$p" @agent_since)"
  cat > "$work/gap.sh" <<GAP
"$real_tmux" -S "$s" respawn-pane -k -t "$p" 'ENV= exec /bin/sh'
sleep 1
printf '%s' '$UPS_B' | env TMUX="$s,$spid,0" TMUX_PANE="$p" ROOST_RECORD_DIR="$ROOST_RECORD_DIR" "$HOOK" working --prompt-hook
printf '%s' '{"session_id":"$SID_B","last_assistant_message":"B FINAL","background_tasks":[]}' \
  | env TMUX="$s,$spid,0" TMUX_PANE="$p" ROOST_RECORD_DIR="$ROOST_RECORD_DIR" "$HOOK" done --stop-hook
GAP
  rm -f "$work/gapped"
  GAP_MODE="$mode" PATH="$shim:$PATH" hook "$p" --session-end-hook <<< "$SEND_A"
  [ -e "$work/gapped" ]; assert_true $? "[$mode] setup: the shim ran B inside A's SessionEnd"
  assert_eq "$(opt "$p" @agent_state)|$(opt "$p" @roost-reply)" "done|B FINAL" "[$mode] setup: B's turn finished, and the pane is B's"
  assert_eq "$(turns_in "$p")" "2" "[$mode] two turns: A's and B's"
  assert_eq "$(cat "$(recdir "$p")/replies/000001" 2>/dev/null)" "A MAIN" "[$mode] turn 1 is A's main reply"
  assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome" 2>/dev/null)" "died" "[$mode] ...with outcome died"
  assert_eq "$(cat "$(recdir "$p")/replies/000002" 2>/dev/null)" "B FINAL" "[$mode] turn 2 is B's answer"
  [ ! -e "$(recdir "$p")/replies/000002.outcome" ]; assert_true $? "[$mode] ...with no outcome sidecar: done"
  "$ROOST" wait-done --turn 1 "$p" 3 >/dev/null 2>&1; assert_eq "$?" "2" "[$mode] wait-done --turn 1 exits 2 (died), not B's 0"
  "$ROOST" wait-done --turn 2 "$p" 3 >/dev/null 2>&1; assert_eq "$?" "0" "[$mode] wait-done --turn 2 exits 0"
  assert_eq "$(opt "$p" @roost-reply-turn)" "2" "[$mode] the pane's pointer is B's turn, not A's"
  pane_has "$p" @roost-turn-reserved; assert_eq "$?" "1" "[$mode] the reservation is gone"
  assert_eq "$(ls -A "$(recdir "$p")/replies" | grep -c '^\.reserving\.')" "0" "[$mode] ...and so is its .reserving file"
  "$ROOST" read --turn 1 "$p" >/dev/null 2>"$work/read.err"
  assert_contains "$(cat "$work/read.err")" "turn 1 of '$p' died" "[$mode] read --turn 1 says A's turn died"
done

# A refused release reserves nothing: the pause lands BEFORE the release, the
# new session takes the pane, and the next appender is not pushed past a
# number nobody filed.
p="$(newpane)"; require_pane "$p" refused-reserves-nothing
held "$p" "A MAIN"
X respawn-pane -k -t "$p" 'ENV= exec /bin/sh'
hook "$p" working --prompt-hook <<< "$UPS_B"
hook "$p" --session-end-hook <<< "$SEND_A"
pane_has "$p" @roost-turn-reserved; assert_eq "$?" "1" "a refused release writes no reservation"
assert_eq "$(ls -A "$(recdir "$p")/replies" 2>/dev/null | grep -c '^\.reserving\.')" "0" "...and leaves no .reserving file"
printf '%s' '{"session_id":"'"$SID_B"'","last_assistant_message":"B FINAL","background_tasks":[]}' | hook "$p" done --stop-hook
assert_eq "$(ls "$(recdir "$p")/replies" | grep '^[0-9]*$' | tr '\n' ' ')" "000001 " "...so B's answer is turn 1"

# --- 10. a prompt on a held pane moves the transcript record with the owner ------
# After a respawn the record still named A's transcript, so an Esc in B was
# looked for in A's file (flock round 2, non-blocking).
p="$(newpane)"; require_pane "$p" transcript-moves
held "$p"
since="$(opt "$p" @agent_since)"
X respawn-pane -k -t "$p" 'ENV= exec /bin/sh'
hook "$p" working --prompt-hook <<< "$UPS_B"
assert_eq "$(opt "$p" @roost-transcript)" "$since $TR_B" "B's prompt on the held pane names B's transcript, on the hold's stamp"
TR_H="/tmp/roost-fixture/a#b/$SID_B.jsonl"
hook "$p" working --prompt-hook <<< "$(edit "$UPS_B" "d['transcript_path']='$TR_H'")"
assert_eq "$(opt "$p" @roost-transcript)" "$since $TR_H" "...a '#' in the path is kept as it is"
hook "$p" working --prompt-hook <<< "$(edit "$UPS_B" "d['transcript_path']=\"/tmp/it's.jsonl\"")"
assert_eq "$(opt "$p" @roost-transcript)|$(opt "$p" @roost-background-session)" "$since $TR_H|$since $SID_B" "...a path with a quote is left out, and the owner is still written"
hook "$p" working --prompt-hook <<< "$(edit "$UPS_B" 'del d["transcript_path"]')"
assert_eq "$(opt "$p" @roost-transcript)" "$since $TR_H" "...a payload with no path leaves the record as it was"
p="$(newpane)"; require_pane "$p" transcript-not-held
hook "$p" working --prompt-hook <<< "$UPS"
tr_before="$(opt "$p" @roost-transcript)"
hook "$p" working --prompt-hook <<< "$UPS_B"
assert_eq "$(opt "$p" @roost-transcript)" "$tr_before" "a repeat prompt on a pane that is not held leaves the transcript record alone"

# --- 8. the reason: clear and resume are not exits ------------------------------
for reason in clear resume logout prompt_input_exit other bogus none; do
  case "$reason" in clear|resume) want=interrupted wrc=5 ;; *) want=died wrc=2 ;; esac
  p="$(newpane)"; require_pane "$p" "reason-$reason"
  held "$p"
  since="$(opt "$p" @agent_since)"
  if [ "$reason" = none ]; then pl="$(edit "$SEND" 'del d["reason"]')"
  else pl="$(edit "$SEND" "d['reason']='$reason'")"; fi
  hook "$p" --session-end-hook <<< "$pl"
  pane_has "$p" @agent_state; assert_eq "$?" "1" "[$reason] the held badge is released"
  assert_eq "$(opt "$p" @roost-ended)" "$since $want" "[$reason] ...recorded as $want"
  assert_eq "$(cat "$(recdir "$p")/replies/000001.outcome" 2>/dev/null)" "$want" "[$reason] ...and the turn's outcome is $want"
  "$ROOST" wait-done "$p" 3 >/dev/null 2>&1; assert_eq "$?" "$wrc" "[$reason] wait-done exits $wrc"
  "$ROOST" wait-done --turn 1 "$p" 3 >/dev/null 2>&1; assert_eq "$?" "$wrc" "[$reason] wait-done --turn 1 exits $wrc"
done

# --- 5. wiring and doctor -------------------------------------------------------
hooks_se="$("$ROOST" hooks claude | sed -n '/^{/,$p' | python3 -c 'import json,sys; print(json.load(sys.stdin)["hooks"]["SessionEnd"][0]["hooks"][0]["command"])')"
assert_eq "$hooks_se" "$HOOK --session-end-hook" "roost hooks claude wires SessionEnd to --session-end-hook"
hooks_to="$("$ROOST" hooks claude | sed -n '/^{/,$p' | python3 -c 'import json,sys; print(json.load(sys.stdin)["hooks"]["SessionEnd"][0]["hooks"][0].get("timeout"))')"
assert_eq "$hooks_to" "10" "...with a timeout of 10 s, not Claude's 1.5 s SessionEnd default"

dhome="$work/dhome"; mkdir -p "$dhome/.claude"
run_doctor() {
  env HOME="$dhome" XDG_CONFIG_HOME="$dhome/.config" XDG_DATA_HOME="$dhome/.local/share" \
      COPILOT_HOME="$dhome/.copilot" PI_CODING_AGENT_DIR="$dhome/.pi/agent" \
      CODEX_HOME="$dhome/.codex" CLAUDE_SETTINGS="$dhome/.claude/settings.json" \
      COLORTERM=truecolor ROOST_CONFIG_SOCK=/nonexistent/roost-se-test-sock \
      ROOST_NOTIFY_SOCK=/nonexistent/roost-se-test-sock "$@" \
      "$DOC" 2>&1
}
"$ROOST" hooks claude | sed -n '/^{/,$p' > "$dhome/.claude/settings.json"
case "$(run_doctor)" in *"has no SessionEnd hook"*) w=warned ;; *) w=quiet ;; esac
assert_eq "$w" "quiet" "doctor is quiet about SessionEnd on a settings.json roost wires today"
python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); del d["hooks"]["SessionEnd"]
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$dhome/.claude/settings.json"
dline="$(run_doctor | grep -F 'has no SessionEnd hook' | head -1)"
[ -n "$dline" ]; assert_true $? "doctor warns about a settings.json with no SessionEnd hook"
assert_contains "$dline" "or run: roost install" "...and points at roost install, which adds it"

# The wiring file a server generated before the change.
"$ROOST" hooks claude | sed -n '/^{/,$p' > "$dhome/.claude/settings.json"
wdir="$work/wiring"; mkdir -p "$wdir/claude"
"$ROOST" hooks claude | sed -n '/^{/,$p' > "$wdir/claude/settings.json"
X set-option -g @roost-wiring-active on
wd() { run_doctor TMUX="$s,0,0" ROOST_WIRING_DIR="$wdir" ROOST_TMUX="$(command -v tmux)"; }
case "$(wd)" in *"generated before the SessionEnd hook existed"*) w=warned ;; *) w=quiet ;; esac
assert_eq "$w" "quiet" "doctor is quiet about a wiring file roost generates today"
python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); del d["hooks"]["SessionEnd"]
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$wdir/claude/settings.json"
wout="$(wd)"
wline="$(printf '%s\n' "$wout" | grep -F 'generated before the SessionEnd hook existed' | head -1)"
[ -n "$wline" ]; assert_true $? "doctor warns about a wiring file generated before SessionEnd was wired"
assert_contains "$wline" "roost wiring on" "...and names the command that regenerates it"
case "$wout" in *"has no SessionEnd hook"*) w=alsowarned ;; *) w=only ;; esac
assert_eq "$w" "only" "...while the user's own settings.json is still reported as fine"
X set-option -gu @roost-wiring-active

# Nothing may have landed in the canary home.
[ -z "$(find "$work/canary" -type f 2>/dev/null)" ]; assert_true $? "nothing was written under HOME or the XDG dirs"
printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
