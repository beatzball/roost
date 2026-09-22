#!/usr/bin/env bash
# A Claude Code permission dialog badges 🛑 blocked the moment it opens, not
# six seconds later (#91).
#
# WHAT WAS MEASURED, and every number in this file comes from it. Claude Code
# 2.1.278, a throwaway tmux socket, an isolated HOME/XDG, and a local stand-in
# for the Messages API so a real dialog opens with no account behind it. One
# logger on all 18 hook events this version accepts.
#
#   dialog              UserPromptSubmit -> PermissionRequest -> permission_prompt
#   Bash                                              167 ms            + 6.002 s
#   Edit                                              126 ms            + 6.001 s
#   Write                                             144 ms            + 5.996 s
#   WebFetch                                          114 ms            + 6.003 s
#   mcp__probe__ping                                  147 ms            + 5.997 s
#   Bash, asked by a subagent                         259 ms            + 6.055 s
#
# So the Notification roost badged on until now arrives a flat six seconds
# after the event that opens the dialog, and a dialog answered inside those six
# seconds fires no Notification at all — which is why a fast answer was never
# badged. PermissionRequest lands within 11-16 ms of the dialog appearing on
# screen (four samples, by polling capture-pane at ~5-9 ms per frame; the
# hook's own timestamp is taken after it has read stdin, so the true figure is
# a little smaller than that).
#
# THE HOOK MUST NOT DECIDE, and it does not have to. Measured both ways: a hook
# that prints nothing and exits 0, and one that prints `{}`. Each left the
# dialog open for the human — nothing was auto-allowed, nothing auto-denied.
# Claude does not wait for it either: with every hook sleeping 3 s, the dialog
# was already on screen 16 ms BEFORE the PermissionRequest hook started.
# (UserPromptSubmit and PreToolUse DO hold the turn up — 3.09 s and 3.07 s in
# that same run — which is why roost wires neither of them to anything slow.)
# So roost-agent-state prints nothing here, as it does on every other event.
#
# AFTER THE DIALOG nothing has moved since #38 measured 2.1.270: Yes fires
# PostToolUse (+109 ms) and then Stop, No fires nothing at all, Esc fires
# nothing at all. `blocked` therefore still clears through PostToolUse on a
# Yes, and through scripts/lib/roost-unblock.sh's transcript read on a No or an
# Esc — which is why this hook records transcript_path exactly as the
# Notification hook does, and why a payload with no usable path removes an
# older record instead of leaving it.
#
# A SUBAGENT'S DIALOG IS THIS PANE'S DIALOG. PermissionRequest fires for it too,
# with `agent_id` and `agent_type` added, and the dialog is drawn on the main
# pane — text sent to the pane lands in it. So it badges blocked like any
# other. That is the OPPOSITE call from StopFailure (#55), where a subagent's
# API error leaves the main turn running and must be ignored, and the reason is
# the difference between the two events, not a preference: an error that does
# not stop the pane must not badge it, and a dialog that does hold the pane
# must. What also arrives is the main turn's own Stop, within a millisecond and
# carrying no agent_id, because the main turn has ended and is waiting on the
# background agent — see "the race" and "the guard is bounded" below. An
# earlier version of this file said that Stop "cannot strand the pane"; round 1
# of the flock review showed two ways it could, and both are cases here now.
#
# END TO END, with roost's own hooks rather than a logger, on the same rig:
# from the frame where the dialog first appears to @agent_state reading
# blocked was +0.072 s (18 polls at ~4 ms), @roost-blocked-on held
# "Bash: mkdir /tmp/roost-probe-dir", @roost-transcript held the session file,
# and `roost send` exited 3. Pressing Esc then left the pane blocked, and the
# next `roost send` cleared it through scripts/lib/roost-unblock.sh and exited
# 0 — #38's recovery is untouched, and it unsets @roost-blocked-on with the
# rest. Before this change the same pane read `working` for the first six
# seconds and `send` delivered into the dialog.
#
# The rig itself is not committed: it needs a stand-in server for the Messages
# API, and tests/live/ already holds the two live smoke tests that guard this
# area against a Claude upgrade.
#
# The payloads are the real captures with every id replaced by a fake of the
# same shape and the home path dropped.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOST="$HERE/bin/roost"
HOOK="$HERE/scripts/roost-agent-state"
DOC="$HERE/scripts/roost-doctor"

# The payloads below are built and edited with python3. Without it several
# assertions would pass on empty payloads, so skip loudly instead — the same
# call tests/test-claude-stop-failure.sh makes. The hook's own no-python3 path
# is covered by the jq section at the bottom and in docs/known-gaps.md.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available (this file builds its payloads with it)"
  exit 0
fi

# roost-agent-state only acts on a socket path ending in /roost.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 200 -y 50 'sh -c "while :; do sleep 5; done"'
pane="$(tmux -S "$s" display -p '#{pane_id}')"
export ROOST_SOCKET="$s"

# A transcript for the pane to point at. Its CONTENTS never matter here: every
# assertion about it is about the pointer, and reading a real one is
# tests/test-unblock.sh's subject.
tr_path="$sdir/transcript.jsonl"
: > "$tr_path"

pstate()   { tmux -S "$s" show-options -pqv -t "$pane" @agent_state; }
psince()   { tmux -S "$s" show-options -pqv -t "$pane" @agent_since; }
ptrans()   { tmux -S "$s" show-options -pqv -t "$pane" @roost-transcript; }
pblocked() { tmux -S "$s" show-options -pqv -t "$pane" @roost-blocked-on; }
preply()   { tmux -S "$s" show-options -pqv -t "$pane" @roost-reply; }
# The hook exactly as `roost hooks` wires it: the command, and the payload on a
# stdin that is not a tty.
hook() { # hook ARGS... <<< PAYLOAD
  env TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" "$@"
}
pr() { hook blocked --permission-request-hook <<< "$1"; }

# payload TOOL INPUT-JSON [EXTRA-JSON] -> one PermissionRequest payload, with
# this run's transcript path in it.
payload() {
  local extra="${3:-}"; [ -n "$extra" ] || extra='{}'
  python3 - "$tr_path" "$1" "$2" "$extra" <<'PY'
import json, sys
tp, tool, inp, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {
    "session_id": "00000000-0000-4000-8000-000000000911",
    "transcript_path": tp,
    "cwd": "/tmp/roost-fixture/proj",
    "prompt_id": "00000000-0000-4000-8000-0000000009a1",
    "permission_mode": "default",
    "hook_event_name": "PermissionRequest",
    "tool_name": tool,
    "tool_input": json.loads(inp),
    "permission_suggestions": [
        {"type": "addDirectories", "directories": ["/tmp"], "destination": "session"},
    ],
}
d.update(json.loads(extra))
sys.stdout.write(json.dumps(d))
PY
}

# The two events that bracket a dialog, built the same way.
other() { # other EVENT [EXTRA-JSON]
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  python3 - "$tr_path" "$1" "$extra" <<'PY'
import json, sys
tp, ev, extra = sys.argv[1], sys.argv[2], sys.argv[3]
d = {
    "session_id": "00000000-0000-4000-8000-000000000911",
    "transcript_path": tp,
    "cwd": "/tmp/roost-fixture/proj",
    "prompt_id": "00000000-0000-4000-8000-0000000009a1",
    "permission_mode": "default",
    "hook_event_name": ev,
}
d.update(json.loads(extra))
sys.stdout.write(json.dumps(d))
PY
}

UPS="$(other UserPromptSubmit '{"prompt":"make a directory please"}')"
STOP="$(other Stop '{"stop_hook_active":false,"last_assistant_message":"PONG","background_tasks":[],"session_crons":[]}')"
STOP2="${STOP/\"PONG\"/\"PONG AGAIN\"}"

BASH_PR="$(payload Bash '{"command":"mkdir /tmp/roost-probe-dir","description":"make a directory"}')"
EDIT_PR="$(payload Edit '{"file_path":"/tmp/roost-fixture/proj/edit-me.txt","old_string":"alpha","new_string":"beta"}')"
FETCH_PR="$(payload WebFetch '{"url":"https://example.com/","prompt":"What is on this page?"}')"
MCP_PR="$(payload mcp__probe__ping '{"note":"probe"}')"
SUB_PR="$(payload Bash '{"command":"mkdir /tmp/roost-probe-sub","description":"subagent directory"}' \
  '{"agent_id":"a12cf0d033cc6c71d","agent_type":"general-purpose"}')"
assert_contains "$SUB_PR" '"agent_id": "a12cf0d033cc6c71d"' "the subagent fixture really carries an agent_id"

# --- the wiring --------------------------------------------------------------
hooks_out="$("$ROOST" hooks)"
assert_contains "$hooks_out" '"PermissionRequest"' "roost hooks wires Claude's PermissionRequest event"
assert_contains "$hooks_out" "$HOOK blocked --permission-request-hook" \
  "...to roost-agent-state blocked --permission-request-hook"
assert_contains "$hooks_out" '"matcher": "permission_prompt"' \
  "...and keeps the permission_prompt Notification as the fallback for an older Claude"
# No matcher. The matcher on this event is a TOOL NAME, and roost badges every
# dialog whatever asked for it — an MCP tool's name is not knowable in advance,
# and a list would miss whichever tool Claude adds next.
pr_matcher="$(printf '%s' "$hooks_out" | sed -n '/^{/,$p' | python3 -c 'import json,sys
h = json.load(sys.stdin)["hooks"]
print([e.get("matcher") for e in h.get("PermissionRequest", [])])' 2>/dev/null)"
assert_eq "$pr_matcher" "[None]" "the PermissionRequest entry has no matcher, so every tool's dialog reaches it"
# The hook body and the installer share one copy of these bytes
# (scripts/lib/roost-hooks.sh), so an install picks the new entry up with no
# code of its own — but only while these two outputs agree.
assert_contains "$("$ROOST" hooks claude)" "blocked --permission-request-hook" \
  "roost hooks claude prints the same entry"

# --- a dialog is badged at once ----------------------------------------------
hook working <<< "$UPS"
assert_eq "$(pstate)" "working" "a turn that will open a dialog starts working"
pr "$BASH_PR"; rc=$?
assert_eq "$rc" "0" "the PermissionRequest hook exits 0"
assert_eq "$(pstate)" "blocked" "a Bash dialog badges blocked from PermissionRequest alone"
assert_contains "$(ptrans)" " $tr_path" "...and records the transcript, so a decline can still be recovered (#38)"
assert_eq "$(ptrans)" "$(psince) $tr_path" "...stamped with the same @agent_since roost-unblock.sh checks"
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-dir" "...and records what the dialog is about, for #93"

# The whole point of the event: `send` refuses the pane from the first
# instant, instead of pasting into the dialog for six seconds.
"$ROOST" send "$pane" "this must not be delivered" >/dev/null 2>&1
assert_eq "$?" "3" "roost send refuses the pane the moment the dialog opens"

# --- what the dialog is about, per tool --------------------------------------
# The value is #93's data and nothing displays it yet. It is one tmux option:
# "<tool_name>: <command or path or url>", control characters removed and the
# detail cut to 120 characters.
for probe in "EDIT_PR|Edit: /tmp/roost-fixture/proj/edit-me.txt" \
             "FETCH_PR|WebFetch: https://example.com/" \
             "MCP_PR|mcp__probe__ping"; do
  name="${probe%%|*}"; want="${probe#*|}"
  hook working <<< "$UPS"
  pr "${!name}"
  assert_eq "$(pstate)" "blocked" "a ${want%%:*} dialog badges blocked"
  assert_eq "$(pblocked)" "$want" "...and records [$want]"
done

# --- a turn with no dialog in it is never badged -----------------------------
hook working <<< "$UPS"
assert_eq "$(pstate)" "working" "a turn with no dialog starts working"
assert_eq "$(pblocked)" "" "...with no record of a dialog"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "done" "...and reaches done"
assert_eq "$(preply)" "PONG" "...with its reply"
assert_eq "$(pblocked)" "" "...and still no record of a dialog"

# --- Yes: PostToolUse clears both the badge and the record -------------------
hook working <<< "$UPS"
pr "$BASH_PR"
assert_eq "$(pstate)" "blocked" "the dialog is badged"
hook working <<< "$(other PostToolUse '{"tool_name":"Bash"}')"
assert_eq "$(pstate)" "working" "answering Yes (PostToolUse) leaves the pane working"
assert_eq "$(pblocked)" "" "...and clears the record of what it was blocked on"
hook done --stop-hook <<< "$STOP2"
assert_eq "$(pstate)" "done" "...and the turn then finishes"
assert_eq "$(preply)" "PONG AGAIN" "...with its own reply"

# --- a Stop while a dialog is open ------------------------------------------
# A subagent's dialog opens on the main pane and the MAIN turn's Stop follows
# 7 ms later, because that turn has ended and is waiting on the background
# agent. Measured on 2.1.278: PermissionRequest (agent_id set) at
# 1790058350.889319, Stop (no agent_id) at 1790058350.896507, and the dialog
# stayed open on screen for another 47 s until it was answered by hand.
#
# So a Stop must not move a pane out of blocked. Nothing else can reach this
# arm: a Yes fires PostToolUse first, so the pane reads working by the time
# Stop lands, and a No or an Esc fires no Stop at all. It cannot strand the
# pane either — when the background agent finishes, the main loop starts a new
# turn and UserPromptSubmit stamps working, which is the case below.
hook working <<< "$UPS"
pr "$SUB_PR"; rc=$?
assert_eq "$rc" "0" "a subagent's PermissionRequest exits 0"
assert_eq "$(pstate)" "blocked" "a subagent's dialog badges the pane blocked — it is drawn on this pane"
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-sub" "...and records what that dialog is about"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "blocked" "the main turn's Stop does not clear a dialog that is still open"
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-sub" "...and leaves the record alone"
# The reply IS still recorded: that turn really did end and really did answer,
# and `roost read` should find it. Only the STATE is held.
assert_eq "$(preply)" "PONG" "...but the turn's reply is still recorded, since the turn did end"
"$ROOST" send "$pane" "this must not be delivered" >/dev/null 2>&1
assert_eq "$?" "3" "...so send still refuses the pane"
# ...and the next turn recovers it completely.
hook working <<< "$UPS"
assert_eq "$(pstate)" "working" "the turn after the subagent finishes starts working"
assert_eq "$(pblocked)" "" "...and clears the record"

# --- the Notification for the SAME dialog, six seconds later -----------------
# It carries no tool_name — measured, the payload is session_id,
# transcript_path, cwd, prompt_id, hook_event_name and
# notification_type: "permission_prompt", and nothing else. So it must move the
# stamp (a repeat blocked is a new dialog as far as that path knows) and leave
# the description alone. Blanking it would lose the description of a dialog
# that is still open, six seconds after it opened.
hook working <<< "$UPS"
pr "$BASH_PR"
notif_since="$(psince)"
sleep 1
hook blocked --notification-hook <<< "$(other Notification '{"message":"Claude needs your permission","notification_type":"permission_prompt"}')"
assert_eq "$(pstate)" "blocked" "the permission_prompt Notification leaves the pane blocked"
[ "$(psince)" != "$notif_since" ]; assert_true $? "...and moves the stamp, as it did before #91"
assert_eq "$(ptrans)" "$(psince) $tr_path" "...and moves the transcript record with it"
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-dir" \
  "...and does NOT blank the description of the dialog that is still open"

# --- Yes, and then the tool FAILS --------------------------------------------
# Round 1 of the flock found the first version of this guard could leave a pane
# 🛑 for ever with no dialog on screen. Re-measured on 2.1.278 on the
# account-free rig, a Bash that exits non-zero after a Yes:
#
#   1790061918.885311  UserPromptSubmit
#   1790061919.001582  PermissionRequest        <- 🛑
#   ...the human answers Yes...
#   1790061923.942409  PostToolUseFailure       <- the only event for the tool
#   1790061924.056971  Stop                     (+114 ms)
#
# PostToolUse fires only on SUCCESS. So for a failing tool the pane never left
# blocked, and then the one Stop of the turn was swallowed: `send` exited 3 for
# ever, `wait-done` burned its whole timeout, `read` called the reply stale.
# The fix is to wire the event Claude actually sends. It badges `working` for
# the same reason PostToolUse does — the turn is still going.
assert_contains "$hooks_out" '"PostToolUseFailure"' "roost hooks wires Claude's PostToolUseFailure event"
ptuf_cmds="$(printf '%s' "$hooks_out" | sed -n '/^{/,$p' | python3 -c 'import json,sys
h = json.load(sys.stdin)["hooks"]
print(sorted(x["command"] for e in h.get("PostToolUseFailure", []) for x in e["hooks"]))' 2>/dev/null)"
assert_eq "$ptuf_cmds" "['$HOOK working']" "...to roost-agent-state working, exactly as PostToolUse is"

hook working <<< "$UPS"
pr "$BASH_PR"
assert_eq "$(pstate)" "blocked" "a dialog for a tool that will fail badges blocked"
hook working <<< "$(other PostToolUseFailure '{"tool_name":"Bash","tool_response":{"success":false}}')"
assert_eq "$(pstate)" "working" "answering Yes to a tool that then FAILS leaves the pane working"
assert_eq "$(pblocked)" "" "...and clears the record of the dialog"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "done" "...and the turn reaches done rather than sticking at blocked"
"$ROOST" send "$pane" "" >/dev/null 2>&1
assert_eq "$?" "0" "...so send reaches the pane again"

# --- the guard is bounded: only ONE Stop per dialog is ever swallowed --------
# The belt to PostToolUseFailure's braces. Whatever event roost has not wired,
# and whatever Claude adds next, a pane may lose exactly one Stop to an open
# dialog — never every Stop that follows. Without this the guard had no way
# out at all for a turn that fired no clearing event.
hook working <<< "$UPS"
pr "$BASH_PR"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "blocked" "the first Stop under an open dialog is swallowed"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "done" "the NEXT Stop is not — one dialog swallows one Stop, never two"
assert_eq "$(pblocked)" "" "...and the second one clears the record"
# ...and a NEW dialog gets its own one, rather than inheriting the spent mark.
hook working <<< "$UPS"
pr "$EDIT_PR"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "blocked" "a later dialog swallows a Stop of its own"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "done" "...and only one"

# --- a subagent's dialog, DECLINED -------------------------------------------
# The round-1 reviewers reasoned this left a pane stuck: the subagent's
# PermissionRequest stamps @roost-transcript with the MAIN session file, the
# decline records go somewhere roost-unblock.sh cannot match, and the main
# turn's real Stop is swallowed. Re-measured on 2.1.278 on the rig, pressing 3
# at a subagent dialog:
#
#   1790062069.510626  (the key)
#   1790062069.562646  PostToolBatch      (+52 ms)
#   1790062069.612588  SubagentStop
#   1790062069.668211  UserPromptSubmit   (+158 ms)  <- this is the rescue
#   1790062069.737361  Stop               (+227 ms)
#
# Claude re-enters the main loop with a prompt of its own, and roost already
# wires UserPromptSubmit to `working`, so the pane leaves blocked BEFORE the
# real Stop arrives and nothing is stuck. So the reviewers' sequence does not
# occur on this version — but it was right about the shape, and the bounded
# guard above means the pane would recover even if that UserPromptSubmit ever
# stopped arriving. Both halves are asserted here.
hook working <<< "$UPS"
pr "$SUB_PR"
hook done --stop-hook <<< "$STOP"     # the main turn's Stop, ~0 ms after
assert_eq "$(pstate)" "blocked" "a subagent dialog holds the pane through the main turn's Stop"
hook working <<< "$UPS"               # Claude's own prompt after the decline
assert_eq "$(pstate)" "working" "...the prompt Claude submits after a decline releases it"
assert_eq "$(pblocked)" "" "...and clears the record"
hook done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "done" "...and the real Stop then lands"
"$ROOST" send "$pane" "" >/dev/null 2>&1
assert_eq "$?" "0" "...so the pane is not stuck"

# --- the race: both hooks started together -----------------------------------
# Round 1 of the flock caught the first version of the guard reading
# @agent_state ~35 lines before the write it protected. Measured there, both
# hooks as `roost hooks` runs them, 40 runs each: with the 7 ms gap this file's
# header records, 40 of 40 stayed blocked; started at the SAME instant, 28 of
# 40 came back `done` — the pane reading ✅ under an open dialog, which is the
# #91 bug again and now intermittent.
#
# It is not a theoretical gap. Re-measured on 2.1.278 on a real subagent
# dialog, the two events INVERTED: Stop's hook ran at 1790062049.316559 and
# PermissionRequest's at 1790062049.316824 — Stop first, by 0.265 ms. Nothing
# may depend on which arrives first.
#
# Two assertions, because each catches something the other does not.
#
# FIRST, deterministically: a tmux shim that answers the hot-path read with a
# STALE value. That is precisely what losing the race looks like from inside
# the hook — the pane is blocked, the read says otherwise — and it needs no
# timing at all, so it cannot flake and it fails the moment the write stops
# being conditional.
shim="$sdir/stale-tmux"; mkdir -p "$shim"
realtmux="$(command -v tmux)"
cat > "$shim/tmux" <<SHIM
#!/bin/sh
# Answer ONE call with a stale value — the hook's hot-path read — and hand
# everything else to the real tmux. Both conditions matter: the write this test
# is about also names @agent_state, and a shim that swallowed it too would make
# the assertion below pass without the pane ever being written to.
# An exec wrapper, never a symlink: a later \`>\` into a shim entry would
# follow a symlink and overwrite the real tool.
_read=0 _state=0
for a in "\$@"; do
  case "\$a" in
    display-message) _read=1 ;;
    *@agent_state*)  _state=1 ;;
  esac
done
[ "\$_read" = 1 ] && [ "\$_state" = 1 ] && { printf '1 working\n'; exit 0; }
exec $realtmux "\$@"
SHIM
chmod +x "$shim/tmux"
# Two controls, because this shim has to be wrong in exactly one way. It is
# always pointed at THIS test's socket, never a bare tmux: a shim that stopped
# matching would otherwise exec the real tmux against the default server.
assert_eq "$(PATH="$shim:$PATH" tmux -S "$s" display-message -p -t "$pane" '#{@agent_state}')" "1 working" \
  "control: the shim answers the hook's state READ with a stale value"
PATH="$shim:$PATH" tmux -S "$s" set-option -p -t "$pane" @roost-shim-probe live 2>/dev/null
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @roost-shim-probe)" "live" \
  "control: ...and passes every other call through, so a write still lands"
tmux -S "$s" set-option -pu -t "$pane" @roost-shim-probe 2>/dev/null

hook working <<< "$UPS"
pr "$BASH_PR"
assert_eq "$(pstate)" "blocked" "the dialog is badged before the racing Stop"
env PATH="$shim:$PATH" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" done --stop-hook <<< "$STOP"
assert_eq "$(pstate)" "blocked" \
  "a Stop whose read missed the dialog still does not move the pane — the write, not the read, decides"
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-dir" "...and the description survives it"
"$ROOST" send "$pane" "this must not be delivered" >/dev/null 2>&1
assert_eq "$?" "3" "...so send still refuses"

# SECOND, the real thing: both hooks running at once, with real payloads and
# real values, and the window between the Stop hook's read and its write held
# open so the result does not depend on how the machine happens to schedule
# three processes. The shim here does NOT lie — it runs the real tmux, prints
# the real answer, and only then waits. That is the one property a timing test
# has to have to be worth keeping: it is red every run on the old code and
# green every run on the new one, rather than red seven times in ten.
slow="$sdir/slow-tmux"; mkdir -p "$slow"
cat > "$slow/tmux" <<SLOW
#!/bin/sh
# Widen the gap between the hook's state READ and the write it guards. Real
# answer, real exit status, then 0.4 s. Every other call is untouched, so the
# writes this test is about happen at full speed.
_read=0 _state=0
for a in "\$@"; do
  case "\$a" in
    display-message) _read=1 ;;
    *@agent_state*)  _state=1 ;;
  esac
done
if [ "\$_read" = 1 ] && [ "\$_state" = 1 ]; then
  out="\$($realtmux "\$@")"; rc=\$?
  printf '%s\n' "\$out"
  sleep 0.4
  exit \$rc
fi
exec $realtmux "\$@"
SLOW
chmod +x "$slow/tmux"
# Control: it still answers correctly, and it really does take its time.
tmux -S "$s" set-option -p -t "$pane" @agent_state working
slow_t0="$(python3 -c 'import time; print(time.time())')"
assert_eq "$(PATH="$slow:$PATH" tmux -S "$s" display-message -p -t "$pane" '#{@agent_state}')" "working" \
  "control: the slow shim gives the REAL value, not a made-up one"
# Seconds with a fraction, not `date +%s`: a 0.4 s wait is usually 0 whole
# seconds apart, so a whole-second check would pass for a shim that had
# stopped waiting at all — and then the race below would prove nothing.
python3 -c 'import sys, time; sys.exit(0 if time.time() - float(sys.argv[1]) >= 0.3 else 1)' "$slow_t0"
assert_true $? "control: ...and it really does hold the call open"

race_bad=0
for i in 1 2 3; do
  hook working <<< "$UPS"
  # Stop first: it reads `working`, then waits inside the shim. The dialog
  # opens during that wait, exactly as it does when the two events land
  # within a millisecond of each other on a real pane.
  { env PATH="$slow:$PATH" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" done --stop-hook <<< "$STOP" ; } &
  stoppid=$!
  sleep 0.15
  pr "$BASH_PR"
  wait "$stoppid"
  case "$(pstate)" in blocked) ;; *) race_bad=$((race_bad+1)) ;; esac
done
assert_eq "$race_bad" "0" \
  "3 rounds of a Stop and a PermissionRequest overlapping: the pane never left blocked"

# --- a dialog is stamped in ONE tmux command ---------------------------------
# The second half of the same race, and it is not hypothetical either: with the
# stamp written as separate calls, the racing Stop's own write landed in the
# window between @roost-blocked-on and @agent_state, read a pane that was not
# blocked YET, and took the branch that unsets the description. Measured live
# on 2.1.278, three subagent dialogs out of three came back with @agent_state
# blocked, @roost-transcript set and @roost-blocked-on GONE.
#
# A window that small cannot be hit on demand, so this asserts the property
# that closes it instead of the symptom: every option a dialog stamps is
# written by ONE tmux invocation. A counting shim records each call's whole
# argv; splitting the group again puts @agent_state and @roost-blocked-on on
# different lines and this fails.
count="$sdir/count-tmux"; mkdir -p "$count"
calls="$sdir/tmux-calls.log"
cat > "$count/tmux" <<COUNT
#!/bin/sh
# One line per invocation, then the real tmux. An exec wrapper, never a
# symlink: a later \`>\` into a shim entry would follow a symlink and
# overwrite the real tool.
printf '%s\\n' "\$*" >> $calls
exec $realtmux "\$@"
COUNT
chmod +x "$count/tmux"
hook working <<< "$UPS"
: > "$calls"
env PATH="$count:$PATH" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" blocked --permission-request-hook <<< "$BASH_PR"
assert_eq "$(pstate)" "blocked" "control: the counted run really stamped the dialog"
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-dir" "control: ...description and all"
[ "$(grep -c . "$calls")" -gt 0 ]; assert_true $? "control: the counting shim really saw the hook's tmux calls"
together="$(grep -c '@agent_state.*@roost-blocked-on\|@roost-blocked-on.*@agent_state' "$calls")"
assert_eq "$together" "1" "the badge and the dialog's description are written by ONE tmux command"
# set-option only: the hot-path READ names @agent_state too, and counting it
# would make this assertion about the wrong thing.
split_state="$(grep -c 'set-option.*@agent_state' "$calls")"
assert_eq "$split_state" "1" "...and @agent_state is WRITTEN exactly once, so there is no second write to race with"

# --- a second dialog on a pane that still reads blocked ----------------------
# The same case the Notification hook already handles (flock round 1 on #38):
# the stamp must move and the record must follow, or roost-unblock.sh would
# judge a new, open dialog by the old transcript and clear it.
hook working <<< "$UPS"
pr "$BASH_PR"
first_since="$(psince)"
sleep 1
pr "$EDIT_PR"
assert_eq "$(pstate)" "blocked" "a second dialog leaves the pane blocked"
[ "$(psince)" != "$first_since" ]; assert_true $? "...with the stamp moved to the new dialog"
assert_eq "$(ptrans)" "$(psince) $tr_path" "...and the transcript record moved with it"
assert_eq "$(pblocked)" "Edit: /tmp/roost-fixture/proj/edit-me.txt" "...and the record naming the NEW dialog"

# --- the record is data, never something roost can be made to run ------------
# tool_input is model output. It reaches a tmux option value, and `roost
# status` renders pane options into tab-delimited rows, so a tab or a newline
# in it would split a row the same way a bad @roost-name does. Control
# characters go and the detail is cut to 120 characters. A trailing `;` is
# KEPT, through lib/roost-reply.sh's measured escape — tmux's command parser
# eats one from any option value, and a command ending in `;` is ordinary
# shell rather than an edge case.
#
# The awkward bytes are built inside python with chr(), never written here as
# escape text: an editor can turn that text into the real byte, and then the
# shell drops it before the test runs. Each case asserts the EXACT value that
# should be stored, so a check that silently stopped checking would show.
bad_case() { # bad_case PYTHON-EXPR EXPECTED LABEL
  local cmd want label payload
  cmd="$(python3 -c "import sys; sys.stdout.write($1)")"
  want="$2"; label="$3"
  payload="$(payload Bash "$(python3 -c 'import json,sys; sys.stdout.write(json.dumps({"command": sys.argv[1]}))' "$cmd")")"
  hook working <<< "$UPS"
  pr "$payload"
  assert_eq "$(pstate)" "blocked" "an awkward command still badges blocked [$label]"
  assert_eq "$(pblocked)" "$want" "...and is stored as [$want] [$label]"
}
bad_case '"echo a" + chr(9) + "b"'  "Bash: echo ab"   "tab"
bad_case '"echo a" + chr(10) + "b"' "Bash: echo ab"   "newline"
bad_case '"echo a" + chr(0) + "b"'  "Bash: echo ab"   "NUL"
bad_case '"echo a" + chr(7) + "b"'  "Bash: echo ab"   "bell"
bad_case '"echo hi;"'               "Bash: echo hi;"  "trailing semicolon"
bad_case '"echo a;b"'               "Bash: echo a;b"  "semicolon inside"
bad_case '"x"*400'                  "Bash: $(python3 -c 'print("x"*120)')" "400 characters"
# The detector proves the fixture really carries the byte the case is about;
# without it every one of these would pass on a command the shell had already
# cleaned (the trap tests/test-claude-stop-failure.sh documents).
nul_payload="$(payload Bash "$(python3 -c 'import json,sys; sys.stdout.write(json.dumps({"command":"echo a"+chr(0)+"b"}))')")"
nulesc="$(printf 'echo a\\u%sb' 0000)"
assert_contains "$nul_payload" "$nulesc" "the NUL fixture really carries an escaped NUL"

# A tool_name is roost's own key, so it is checked too: anything that is not
# the shape Claude uses records nothing at all rather than a value roost would
# then print as its own.
for badtool in 'Bash; set-option -g status off' "$(printf 'Ba\nsh')" "$(python3 -c 'print("T"*80)')" ''; do
  hook working <<< "$UPS"
  pr "$(payload "$(python3 -c 'import sys;sys.stdout.write(sys.argv[1])' "$badtool")" '{"command":"mkdir /tmp/x"}')" 2>/dev/null
  assert_eq "$(pstate)" "blocked" "an unexpected tool_name still badges blocked [${badtool:0:14}]"
  assert_eq "$(pblocked)" "" "...and records nothing [${badtool:0:14}]"
done

# --- a payload nothing can read still badges the pane ------------------------
# PermissionRequest is itself the report that a dialog is open. A machine with
# no python3 and no jq, or a payload that is not JSON, loses the detail and the
# transcript — never the badge, which is the part `send` depends on.
for payload_bad in '{}' '["PermissionRequest"]' 'not json at all' ''; do
  hook working <<< "$UPS"
  pr "$payload_bad"; rc=$?
  assert_eq "$rc" "0" "an unreadable PermissionRequest payload exits 0 [${payload_bad:0:20}]"
  assert_eq "$(pstate)" "blocked" "...and still badges blocked [${payload_bad:0:20}]"
  assert_eq "$(pblocked)" "" "...with no record of what it is about [${payload_bad:0:20}]"
  assert_eq "$(ptrans)" "" "...and no transcript record from an earlier dialog left behind [${payload_bad:0:20}]"
done

# --- the hook decides nothing ------------------------------------------------
# Measured (see the header): Claude leaves the dialog for the human when the
# hook prints nothing, and also when it prints `{}`. roost prints nothing, and
# this asserts that it stays that way — an `allow` or a `deny` on this event
# would answer a dialog on the human's behalf.
hook working <<< "$UPS"
out="$(pr "$BASH_PR" 2>/dev/null)"
assert_eq "$out" "" "the PermissionRequest hook prints nothing at all, so it can decide nothing"

# And again on the path that has a CHILD PROCESS. roost-agent-state pings
# roost-notify when a pane goes blocked in a window that is not on screen, and
# that child inherits the hook's stdout — so it is the one way a byte could
# reach Claude without this file's own code printing it (flock round 1). The
# assertion above ran with the pane's window active, which is exactly the case
# where that child never starts.
#
# The backend is pinned to `tmux` rather than left on `auto`: auto on macOS
# raises a real desktop notification, and `none` would exit before the child
# did anything at all, so the case would test nothing. `tmux` makes it do real
# work — a display-message on this test's own server — with nothing on stdout.
tmux -S "$s" set-option -g @roost-notify-backend tmux
notifwin="$(tmux -S "$s" new-window -d -P -F '#{window_id}' 'sh -c "while :; do sleep 5; done"')"
tmux -S "$s" select-window -t "$notifwin"
assert_eq "$(tmux -S "$s" display-message -p -t "$pane" '#{window_active}')" "0" \
  "control: the badged pane is now in a window that is not on screen, so the notify child runs"
hook working <<< "$UPS"
out="$(pr "$BASH_PR" 2>/dev/null)"
assert_eq "$(pstate)" "blocked" "...the off-screen dialog is still badged"
assert_eq "$out" "" "...and the hook still prints nothing, notify child and all"
tmux -S "$s" kill-window -t "$notifwin" 2>/dev/null
tmux -S "$s" set-option -gu @roost-notify-backend

# --- roost doctor names an install wired before this change ------------------
# Same shape as the StopFailure check (#55): a settings.json copied from
# `roost hooks` before #91 badges every other event correctly, so the only
# symptom is a dialog that is not badged for six seconds — which nobody
# connects to a missing hook entry. The warning is asserted here rather than in
# tests/test-doctor.sh so this change carries its own test file.
prhome="$(mktemp -d /tmp/amx.XXXX)"; mkdir -p "$prhome/.claude"
run_doctor() { # run_doctor HOME_DIR -- every home doctor can be steered by
  env HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" \
      COPILOT_HOME="$1/.copilot" PI_CODING_AGENT_DIR="$1/.pi/agent" \
      CODEX_HOME="$1/.codex" CLAUDE_SETTINGS="$1/.claude/settings.json" \
      COLORTERM=truecolor ROOST_CONFIG_SOCK=/nonexistent/roost-pr-test-sock \
      ROOST_NOTIFY_SOCK=/nonexistent/roost-pr-test-sock \
      "$DOC" 2>&1
}
"$ROOST" hooks claude | sed -n '/^{/,$p' > "$prhome/.claude/settings.json"
prout="$(run_doctor "$prhome")"
case "$prout" in *"has no PermissionRequest hook"*) w=warned ;; *) w=quiet ;; esac
assert_eq "$w" "quiet" "doctor does not warn about PermissionRequest on a settings.json roost wires today"
python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); del d["hooks"]["PermissionRequest"]
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$prhome/.claude/settings.json"
prout="$(run_doctor "$prhome")"
assert_contains "$prout" "Claude hooks wired in" "a pre-#91 settings.json is still reported as wired"
prline="$(printf '%s\n' "$prout" | grep -F 'has no PermissionRequest hook' | head -1)"
[ -n "$prline" ]; assert_true $? "doctor warns about a settings.json with no PermissionRequest hook"
assert_contains "$prline" "six seconds" "...saying how late the badge is without it"
assert_contains "$prline" "or run: roost install" "...and pointing at roost install, which adds it"
rm -rf "$prhome"

# --- the decline path clears the description too -----------------------------
# scripts/lib/roost-unblock.sh is the ONE place a 🛑 is cleared without running
# this script, so it is the one place that could leave @roost-blocked-on
# describing a dialog that is gone. It unsets it inside the same compare-and-
# clear as the rest — and until round 1 of the flock said so, deleting that
# unset left the whole suite green, which is not a test.
#
# Driven through `roost send`, not by calling the function, because that is the
# path a caller takes: send is what reads `blocked`, proves the decline from
# the transcript and clears. The fixture is the real `3. No` capture that
# tests/test-claude-decline.sh pins, with the stamp those records were taken
# under.
unb="$sdir/unblock-no.jsonl"
cp "$HERE/tests/fixtures/claude-transcript-no.jsonl" "$unb"
NO_SINCE=1789398932
tmux -S "$s" set-option -p -t "$pane" @agent_since "$NO_SINCE"
tmux -S "$s" set-option -p -t "$pane" @agent_state blocked
tmux -S "$s" set-option -p -t "$pane" @roost-transcript "$NO_SINCE $unb"
tmux -S "$s" set-option -p -t "$pane" @roost-blocked-on "Bash: mkdir /tmp/roost-probe-dir"
tmux -S "$s" set-option -p -t "$pane" @roost-stop-swallowed 1
assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-dir" "control: the declined pane really carries a description"
"$ROOST" send "$pane" "" >/dev/null 2>&1
assert_eq "$?" "0" "send clears a pane whose dialog was declined"
assert_eq "$(pstate)" "" "...the badge is unset, not written"
assert_eq "$(pblocked)" "" "...and the description of the dialog that is gone is unset with it"
assert_eq "$(tmux -S "$s" show-options -pqv -t "$pane" @roost-stop-swallowed)" "" \
  "...as is the mark that says this dialog has already swallowed a Stop"

# --- roost install adds the one missing entry, and only that ----------------
# The merge is generic (scripts/lib/roost-json.sh walks whatever
# roost_hooks_claude prints), so #91 needed no installer code of its own —
# which is exactly the claim worth pinning, because "no code changed" is the
# shape of a feature that quietly does not ship. The user's own PostToolUse
# formatter is in the fixture because destroying one is the concrete bug that
# merge mode was written after (see its comment).
inst="$(mktemp -d /tmp/amx.XXXX)"
cat > "$inst/strip.py" <<'STRIP'
import json, sys
d = json.load(sys.stdin)
del d["hooks"]["PermissionRequest"]
d["hooks"]["PostToolUse"].insert(0, {"matcher": "Edit",
  "hooks": [{"type": "command", "command": "my-own-formatter"}]})
json.dump(d, open(sys.argv[1], "w"), indent=2)
STRIP
cat > "$inst/count.py" <<'COUNT'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]; t = sys.argv[2]
def n(event, cmd):
    return sum(1 for e in h.get(event, []) for x in e.get("hooks", [])
               if x.get("command") == cmd)
print(n("PermissionRequest", t + " blocked --permission-request-hook"),
      n("PostToolUse", "my-own-formatter"), n("PostToolUse", t + " working"))
COUNT
( . "$HERE/scripts/lib/roost-hooks.sh"; . "$HERE/scripts/lib/roost-json.sh"
  roost_hooks_claude "$HOOK" | python3 "$inst/strip.py" "$inst/settings.json"
  roost_json_merge "$inst/settings.json" claude-hooks "$HOOK" ) >/dev/null 2>&1
assert_eq "$(python3 "$inst/count.py" "$inst/settings.json" "$HOOK")" "1 1 1" \
  "a merge into a pre-#91 settings.json adds the entry once, keeps the user's formatter, and does not duplicate PostToolUse"
rm -rf "$inst"

# --- the jq reader, on a PATH with no python3 --------------------------------
# Every machine this suite has run on has python3, so without this section the
# jq branch is never run — the same gap tests/test-claude-stop-failure.sh
# closes, and for the same reason: a mutation in the jq filter would be green
# everywhere else.
#
# The shim holds small exec wrappers, never symlinks to the real binaries: a
# later `>` into a shim entry would follow a symlink and overwrite the real
# tool. python3 is deliberately not in it.
if command -v jq >/dev/null 2>&1; then
  shim="$sdir/jq-only-bin"; mkdir -p "$shim"
  for c in tmux jq cat date dirname readlink sh bash env ps; do
    real="$(command -v "$c")" || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$real" > "$shim/$c"; chmod +x "$shim/$c"
  done
  # A positive control first: the SAME shim sh, with python3's own directory
  # added after the shim, must FIND python3. Without it, a broken probe would
  # make the absence check below prove nothing. And the absence check accepts
  # ANY non-zero exit, because POSIX does not fix what `command -v` returns for
  # a missing command (bash and macOS sh give 1, dash gives 127 — asserting 1
  # failed PR #63's CI on Ubuntu).
  pydir="$(dirname "$(command -v python3)")"
  env PATH="$shim:$pydir" sh -c 'command -v python3' >/dev/null 2>&1
  assert_eq "$?" "0" "positive control: the shim's sh finds python3 when its directory is on PATH"
  env PATH="$shim" sh -c 'command -v python3' >/dev/null 2>&1
  jrc=$?
  [ "$jrc" -ne 0 ]; assert_true $? "the jq-only PATH really has no python3 (probe exit $jrc)"
  jpr() { env PATH="$shim" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" blocked --permission-request-hook <<< "$1"; }
  hook working <<< "$UPS"
  jpr "$BASH_PR"
  assert_eq "$(pstate)" "blocked" "jq reader: a dialog badges blocked"
  assert_eq "$(pblocked)" "Bash: mkdir /tmp/roost-probe-dir" "jq reader: ...and records what it is about"
  assert_eq "$(ptrans)" "$(psince) $tr_path" "jq reader: ...and records the transcript"
  hook working <<< "$UPS"
  jpr "$EDIT_PR"
  assert_eq "$(pblocked)" "Edit: /tmp/roost-fixture/proj/edit-me.txt" "jq reader: a file path is recorded too"
  hook working <<< "$UPS"
  jpr "$(payload Bash "$(python3 -c 'import json,sys; sys.stdout.write(json.dumps({"command":"echo a\tb"}))')")"
  case "$(pblocked)" in
    *"$(printf '\t')"*) assert_eq split clean "jq reader: a tab in the command is removed" ;;
    *) assert_eq ok ok "jq reader: a tab in the command is removed" ;;
  esac
  hook working <<< "$UPS"
  jpr 'not json at all'
  assert_eq "$(pstate)" "blocked" "jq reader: an unreadable payload still badges blocked"
  assert_eq "$(pblocked)" "" "jq reader: ...and records nothing"
else
  echo "  SKIP: jq not available, so the jq reader is not run here"
fi

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
[ "$ROOST_TESTS_FAIL" -eq 0 ]
