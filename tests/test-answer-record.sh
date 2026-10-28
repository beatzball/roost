#!/usr/bin/env bash
# The dialog record `roost answer` reads (#142, step 1 of
# docs/airig/specs/2026-09-30-roost-answer-design.md §10): @roost-dialog, from
# Claude's PermissionRequest hook and from the codex adapter, removed wherever
# @roost-blocked-on is removed, and `dialog` in `status --json`.
#
# The payloads are built in the shape of the design's captures (Claude Code
# 2.1.283, codex-cli 0.157.1) with every id replaced by a fake of the same
# shape and the home path dropped, as tests/test-claude-permission-request.sh
# does for 2.1.278. The raw captures were kept with the design work and never
# committed. What the record says for each shape is the design's §4.2:
#
#   Bash, Write, Edit (Claude)                    permission
#   AskUserQuestion, one question, single select,
#     two to four options, no preview             question N
#   codex's command approval (`Bash`)             permission
#   everything else                               other
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
CODEX="$HERE/adapters/codex/roost-codex-hook"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file builds its payloads with it)"
  exit 0
fi

# Every home a hook or adapter could reach, at a canary nothing may write to
# (the shape of tests/test-install.sh). Nothing here should write anywhere but
# the tmux server.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
CANARY="$sdir/canary"
export HOME="$CANARY/home" XDG_CONFIG_HOME="$CANARY/xdg-config" \
       XDG_STATE_HOME="$CANARY/xdg-state" XDG_DATA_HOME="$CANARY/xdg-data" \
       CLAUDE_CONFIG_DIR="$CANARY/claude-config" CLAUDE_SETTINGS="$CANARY/claude/settings.json" CODEX_HOME="$CANARY/codex" \
       COPILOT_HOME="$CANARY/copilot" PI_CODING_AGENT_DIR="$CANARY/pi/agent"
export ROOST_RECORD_DIR=""
export ROOST_EVENTS=""
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d -s main -x 200 -y 50 'sh -c "while :; do sleep 5; done"'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
export ROOST_SOCKET="$s"
unset TMUX TMUX_PANE

tr_path="$sdir/transcript.jsonl"; : > "$tr_path"
opt()     { tmux -S "$s" show-options -pqv -t "$pane" "$1"; }
pstate()  { opt @agent_state; }
pdialog() { opt @roost-dialog; }
hook() { env TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" "$@"; }
pr()   { hook blocked --permission-request-hook <<< "$1"; }
reset() { hook working <<< '{}'; }
# fp -> the first word of the record; tail -> the other four.
fp()   { local d; d="$(pdialog)"; printf '%s' "${d%% *}"; }
tailw() { local d; d="$(pdialog)"; printf '%s' "${d#* }"; }

# payload TOOL INPUT-JSON [EXTRA-JSON] -> a PermissionRequest payload.
payload() {
  local extra="${3:-}"; [ -n "$extra" ] || extra='{}'
  python3 - "$tr_path" "$1" "$2" "$extra" <<'PY'
import json, sys
tp, tool, inp, extra = sys.argv[1:5]
d = {
    "session_id": "00000000-0000-4000-8000-000000001421",
    "transcript_path": tp,
    "cwd": "/tmp/roost-fixture/proj",
    "prompt_id": "00000000-0000-4000-8000-0000000014a1",
    "permission_mode": "default",
    "hook_event_name": "PermissionRequest",
    "tool_name": tool,
    "tool_input": json.loads(inp),
    "permission_suggestions": [],
}
d.update(json.loads(extra))
sys.stdout.write(json.dumps(d))
PY
}
# question N [MULTI] [PREVIEW] -> an AskUserQuestion tool_input with N options.
question() {
  python3 - "$1" "${2:-false}" "${3:-}" <<'PY'
import json, sys
n, multi, prev = int(sys.argv[1]), sys.argv[2] == "true", sys.argv[3]
opts = [{"label": l, "description": "the colour " + l} for l in ["Red", "Green", "Blue", "Cyan", "Pink"][:n]]
if prev:
    opts[0]["preview"] = prev
sys.stdout.write(json.dumps({"questions": [{"question": "Which color do you want?", "header": "Color",
                                            "options": opts, "multiSelect": multi}]}))
PY
}

BASH_PR="$(payload Bash '{"command":"mkdir cxdir-a1","description":"make a directory"}')"
WRITE_PR="$(payload Write '{"file_path":"/tmp/roost-fixture/proj/new.txt","content":"hello"}')"
EDIT_PR="$(payload Edit '{"file_path":"/tmp/roost-fixture/proj/edit-me.txt","old_string":"a","new_string":"b"}')"
FETCH_PR="$(payload WebFetch '{"url":"https://example.com/","prompt":"What is here?"}')"
MCP_PR="$(payload mcp__probe__ping '{"note":"probe"}')"
Q3_PR="$(payload AskUserQuestion "$(question 3)")"
Q2_PR="$(payload AskUserQuestion "$(question 2)")"
Q4_PR="$(payload AskUserQuestion "$(question 4)")"
Q5_PR="$(payload AskUserQuestion "$(question 5)")"
QM_PR="$(payload AskUserQuestion "$(question 3 true)")"
QP_PR="$(payload AskUserQuestion "$(question 3 false 'a preview')")"
QQ_PR="$(payload AskUserQuestion "$(python3 -c 'import json; q={"question":"Q?","header":"H","options":[{"label":"a","description":"a"},{"label":"b","description":"b"}],"multiSelect":False}; print(json.dumps({"questions":[q,q]}))')")"
SUB_PR="$(payload Bash '{"command":"mkdir sub","description":"subagent"}' '{"agent_id":"a12cf0d033cc6c71d","agent_type":"general-purpose"}')"
# codex's PermissionRequest, in the shape tests/test-codex-hook.sh pins for
# 0.157.1: tool_name Bash, tool_input.command, a turn_id, a rollout path.
CODEX_PR='{"session_id":"01a04fc5-e328-7af1-89c5-6977a6571605","turn_id":"01a04fc5-ea7d-7802-9a79-c1e6e457863b","transcript_path":"'"$sdir"'/rollout.jsonl","cwd":"/tmp/roost-fixture/work","hook_event_name":"PermissionRequest","model":"fake","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"mkdir cxdir-a1","description":"Need to write outside the sandbox"}}'

# is_fp VALUE -> 0 when VALUE is exactly 12 lowercase hex characters.
is_fp() { case "$1" in ''|*[!0123456789abcdef]*) return 1 ;; esac; [ "${#1}" -eq 12 ]; }

# shape NAME PAYLOAD WANT-TAIL-PREFIX
shape() {
  reset; pr "$2"
  assert_eq "$(pstate)" blocked "$1: badges blocked"
  assert_prefix "$(tailw)" "$3 " "$1: the record reads '$3 …'"
  is_fp "$(fp)"; assert_true $? "$1: the fingerprint is 12 lowercase hex (got '$(fp)')"
}

# --- 1. what each dialog shape records ----------------------------------------
shape "Claude Bash"              "$BASH_PR"  "claude permission 0"
shape "Claude Write"             "$WRITE_PR" "claude permission 0"
shape "Claude Edit (2.1.309)"    "$EDIT_PR"  "claude permission 0"
shape "Claude WebFetch (not measured)" "$FETCH_PR" "claude other 0"
shape "an MCP tool (not measured)" "$MCP_PR"  "claude other 0"
shape "a question with 3 options" "$Q3_PR"   "claude question 3"
shape "a question with 2 options" "$Q2_PR"   "claude question 2"
shape "a question with 4 options" "$Q4_PR"   "claude question 4"
shape "a question with 5 options" "$Q5_PR"   "claude other 0"
shape "a multi-select question"  "$QM_PR"   "claude other 0"
shape "an option with a preview" "$QP_PR"   "claude other 0"
shape "two questions"            "$QQ_PR"   "claude other 0"
shape "a subagent's dialog"      "$SUB_PR"  "claude other 0"
shape "a payload that is not JSON" 'not json' "claude other 0"
reset
assert_eq "$(pdialog)" "" "leaving blocked removes the record"
# F3 of the design: a question's description names what it asks, not just
# the tool.
reset; pr "$Q3_PR"
assert_eq "$(opt @roost-blocked-on)" "AskUserQuestion: Which color do you want?" \
  "a question records its question's text as the description"

# --- 2. a token is new for each dialog, and kept for one dialog ---------------
reset; pr "$BASH_PR"; a="$(fp)"
pr "$BASH_PR"; b="$(fp)"
assert_eq "$b" "$a" "the same hook twice for one dialog keeps the token (Claude runs a hook once per settings source)"
hook blocked --notification-hook <<< '{"transcript_path":"'"$tr_path"'","message":"Claude needs your permission"}'
assert_eq "$(fp)" "$a" "the permission_prompt Notification six seconds later does not change it"
reset; pr "$BASH_PR"; c="$(fp)"
[ "$c" != "$a" ]; assert_true $? "the SAME tool and input as a new dialog, after the pane left blocked, gets a new token (M4)"
pr "$WRITE_PR"; d="$(fp)"
[ "$d" != "$c" ]; assert_true $? "a different dialog on a pane that still reads blocked gets a new token"
tmux -S "$s" set -p -t "$pane" @roost-answered "$d 1790000000 approve terminal"
pr "$WRITE_PR"
assert_eq "$(opt @roost-answered)" "$d 1790000000 approve terminal" "a repeat of the same dialog's hook keeps who answered it"
pr "$BASH_PR"
assert_eq "$(opt @roost-answered)" "" "a new dialog removes who answered the old one"
# Two copies started together: tmux runs one client's command list at a time,
# so exactly one token survives and both calls leave the same record.
reset
pr "$BASH_PR" & pr "$BASH_PR" & wait
e="$(fp)"; pr "$BASH_PR"
assert_eq "$(fp)" "$e" "two copies of the hook racing on one dialog leave one token"

# --- 3. removed wherever @roost-blocked-on is ---------------------------------
reset; pr "$BASH_PR"
tmux -S "$s" set -p -t "$pane" @roost-answered "$(fp) 1790000000 approve terminal"
hook working <<< '{}'
assert_eq "$(pdialog)|$(opt @roost-answered)" "|" "leaving blocked removes the record and who answered"
# The Stop guard: the first Stop on a blocked pane is held back and keeps the
# record; the second falls through and removes it with the description.
reset; pr "$BASH_PR"; f="$(fp)"
hook done --stop-hook <<< '{"last_assistant_message":"x"}'
assert_eq "$(pstate) $(fp)" "blocked $f" "a Stop held back while a dialog is open keeps the record"
hook done --stop-hook <<< '{"last_assistant_message":"x"}'
assert_eq "$(pstate)|$(pdialog)|$(opt @roost-blocked-on)" "done||" "the Stop guard's else branch removes the record with the description"
# roost-unblock.sh, after a decline the transcript proves.
reset; pr "$BASH_PR"
since="$(opt @agent_since)"
python3 - "$tr_path" "$since" <<'PY'
import json, sys, datetime
p, since = sys.argv[1], int(sys.argv[2])
ts = datetime.datetime.fromtimestamp(since + 1, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
recs = [
  {"type": "user", "toolDenialKind": "user-rejected", "timestamp": ts,
   "message": {"content": [{"type": "tool_result", "content": "The user doesn't want to proceed with this tool use. x"}]}},
  {"type": "user", "timestamp": ts, "message": {"content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}},
  {"type": "system", "subtype": "turn_duration", "timestamp": ts},
]
open(p, "w").write("".join(json.dumps(r) + "\n" for r in recs))
PY
"$ROOST" send "$pane" "" >/dev/null 2>&1
assert_eq "$(pstate)|$(pdialog)" "|" "a decline cleared from the transcript removes the record"
: > "$tr_path"

# --- 4. codex ---------------------------------------------------------------
reset
printf '%s' "$CODEX_PR" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$CODEX" PermissionRequest
assert_eq "$(pstate)" blocked "codex: PermissionRequest badges blocked"
assert_eq "$(tailw | cut -d' ' -f1-3)" "codex permission 0" "codex: its command approval records a codex permission dialog"
assert_eq "$(opt @roost-blocked-on)" "Bash: mkdir cxdir-a1" "codex: ...and what it is about (the description was Claude's only)"
assert_eq "$(opt @roost-transcript)" "" "codex: ...and no transcript, which only a Claude transcript reader would read"
# Under codex's shared app-server the pane is not known (#145): the flagless
# stamp, as before, and no record. The same stand-in parent as test-identity.
mkdir -p "$sdir/bin"
cat > "$sdir/bin/app-server" <<EOF
#!/usr/bin/env bash
"$CODEX" "\$@"
EOF
chmod +x "$sdir/bin/app-server"
reset
printf '%s' "$CODEX_PR" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$sdir/bin/app-server" PermissionRequest
assert_eq "$(pstate)|$(pdialog)|$(opt @roost-blocked-on)" "blocked||" "codex under its shared app-server: badged, with no record and no description"
reset
printf '%s' "$CODEX_PR" | env TMUX="$s,0,0" TMUX_PANE="$pane" bash -c '"$0" PermissionRequest' "$CODEX"
assert_eq "$(tailw | cut -d' ' -f1-2)" "codex permission" "(control) the same payload through an ordinary parent does record it"
# A harness name the hook does not know records nothing.
reset
env ROOST_DIALOG_HARNESS=opencode TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" blocked --permission-request-hook <<< "$BASH_PR"
assert_eq "$(pstate)|$(pdialog)" "blocked|" "an unknown ROOST_DIALOG_HARNESS records no dialog"

# --- 5. status --json --------------------------------------------------------
sj() { "$ROOST" status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([p["dialog"] for p in d["panes"]][0]))'; }
reset
assert_eq "$(sj)" "null" "status --json: dialog is null for a pane that is not blocked"
pr "$Q3_PR"; g="$(fp)"
assert_eq "$(sj)" '{"fingerprint": "'"$g"'", "harness": "claude", "kind": "question", "options": 3, "answered": null}' \
  "status --json: a blocked pane's dialog, with its fingerprint, kind and options"
tmux -S "$s" set -p -t "$pane" @roost-answered "$g 1790748772 option2 pane:%7"
assert_eq "$(sj)" '{"fingerprint": "'"$g"'", "harness": "claude", "kind": "question", "options": 3, "answered": {"at": 1790748772, "action": "option", "option": 2, "by": "pane:%7"}}' \
  "status --json: answered says when, what and from where"
tmux -S "$s" set -p -t "$pane" @roost-answered "000000000000 1790748772 approve terminal"
assert_eq "$(sj | python3 -c 'import json,sys; print(json.load(sys.stdin)["answered"])')" "None" \
  "status --json: an answer to a DIFFERENT dialog is not this dialog's answer"
# The upper-case case is a FIXED fingerprint with letters (#186). Upper-casing
# the random $g was a valid record whenever $g had no letter a-f, about one
# run in 300, and the case then failed for being right.
uc=abcdef012345
tmux -S "$s" set -p -t "$pane" @roost-dialog "$uc claude question 3 9a0c51e2"
assert_eq "$(sj | python3 -c 'import json,sys; print(json.load(sys.stdin)["fingerprint"])')" "$uc" \
  "(control) status --json: the lower-case form of the upper-case case is a valid record"
for bad in "zz$g" "$g claude question 3" "$g claude question 3 9a0c51e2 extra" "$g bash question 3 9a0c51e2" \
           "$g claude permission 3 9a0c51e2" "$g claude question x 9a0c51e2" "$(printf '%s' "$uc" | tr a-f A-F) claude question 3 9a0c51e2"; do
  tmux -S "$s" set -p -t "$pane" @roost-dialog "$bad"
  assert_eq "$(sj)" "null" "status --json: a record that is not the right shape is null ($bad)"
done
tmux -S "$s" set -p -t "$pane" @roost-dialog "$g claude question 3 9a0c51e2"
tmux -S "$s" set -p -t "$pane" @agent_state done
assert_eq "$(sj)" "null" "status --json: a record on a pane that is not blocked is null"
reset
hum="$("$ROOST" status 2>&1)"
pr "$BASH_PR"; tmux -S "$s" set -p -t "$pane" @agent_state working
assert_eq "$("$ROOST" status 2>&1)" "$hum" "human status is unchanged by a dialog record"

# --- 6. the jq reader, on a PATH with no python3 ------------------------------
# The same shim tests/test-claude-permission-request.sh builds: exec wrappers,
# never symlinks, so a later `>` cannot reach a real binary. cksum is in it
# because the jq path digests with it.
if command -v jq >/dev/null 2>&1; then
  shim="$sdir/jq-only-bin"; mkdir -p "$shim"
  for c in tmux jq cat date dirname readlink sh bash env ps cksum; do
    real="$(command -v "$c")" || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$shim/$c"; chmod +x "$shim/$c"
  done
  env PATH="$shim" sh -c 'command -v python3' >/dev/null 2>&1
  jrc=$?
  [ "$jrc" -ne 0 ]; assert_true $? "the jq-only PATH really has no python3 (probe exit $jrc)"
  jpr() { env PATH="$shim" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" blocked --permission-request-hook <<< "$1"; }
  jshape() {
    reset; jpr "$2"
    assert_prefix "$(tailw)" "$3 " "jq reader, $1: the record reads '$3 …'"
    is_fp "$(fp)"; assert_true $? "jq reader, $1: the fingerprint is 12 lowercase hex (got '$(fp)')"
  }
  jshape "Claude Bash" "$BASH_PR" "claude permission 0"
  jshape "Claude Write" "$WRITE_PR" "claude permission 0"
  jshape "Claude Edit" "$EDIT_PR" "claude permission 0"
  jshape "a question with 3 options" "$Q3_PR" "claude question 3"
  assert_eq "$(opt @roost-blocked-on)" "AskUserQuestion: Which color do you want?" \
    "jq reader: a question records its question's text as the description"
  jshape "a question with 5 options" "$Q5_PR" "claude other 0"
  jshape "a multi-select question" "$QM_PR" "claude other 0"
  jshape "an option with a preview" "$QP_PR" "claude other 0"
  jshape "two questions" "$QQ_PR" "claude other 0"
  jshape "a subagent's dialog" "$SUB_PR" "claude other 0"
  jshape "a payload that is not JSON" 'not json' "claude other 0"
  reset; jpr "$BASH_PR"; ja="$(fp)"; jpr "$BASH_PR"
  assert_eq "$(fp)" "$ja" "jq reader: the same hook twice keeps the token"
  jpr "$WRITE_PR"
  [ "$(fp)" != "$ja" ]; assert_true $? "jq reader: a different dialog gets a new token"
else
  echo "  SKIP: jq not available, so the jq reader is not run here"
fi

leaks="$(find "$CANARY" -mindepth 1 2>/dev/null | sort)"
assert_eq "$leaks" "" "nothing was written under the canary homes"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
