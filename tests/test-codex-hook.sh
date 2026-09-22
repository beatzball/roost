#!/usr/bin/env bash
# The Codex adapter's event mapping, tested without running codex.
#
# Real codex needs a model, a proxy in front of ollama and a human at a trust
# prompt, so it is far too slow and too interactive for CI; tests/live/ has the
# hand-run test that drives it for real. This one covers the whole mapping
# table offline in milliseconds, against a throwaway tmux server, including the
# three traps the live driving turned up — the SessionEnd that lands 22ms after
# Stop, the frozen registration, and a hook exit code that codex reads as a
# veto.
#
# Every payload below is a REAL one, captured from codex-cli 0.151.0 driven
# against a local ollama, and kept verbatim except for the two path fields:
# transcript_path and cwd are rewritten to /tmp/roost-codex-fixture/... because
# the capture ran under an absolute home path and AGENTS.md §1 keeps those out
# of this repository. session_id and turn_id are the recorded ones.
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HERE/adapters/codex/roost-codex-hook"

# roost-agent-state only acts on a socket whose path ends in /roost, so build
# one directly rather than via roost_test_server (whose socket lacks that
# suffix) — the same reason tests/test-agent-state.sh does.
sdir="$(mktemp -d /tmp/amx.XXXX)"; s="$sdir/roost"
shimdir="$(mktemp -d /tmp/amx.XXXX)"
lonedir="$(mktemp -d /tmp/amx.XXXX)"
trap 'tmux -S "$s" kill-server 2>/dev/null; rm -rf "$sdir" "$shimdir" "$lonedir"' EXIT
tmux -S "$s" -f /dev/null new-session -d -x 400 -y 200
pane="$(tmux -S "$s" display -p '#{pane_id}')"

# hook EVENT [PAYLOAD] — run the shim exactly as codex runs it: one argv word
# naming the event, the JSON payload on stdin, $TMUX/$TMUX_PANE inherited from
# the pane codex is running in. Codex passes a payload to EVERY hook, not only
# to Stop, so the default here is a payload rather than /dev/null.
hook() {
  printf '%s' "${2-{\}}" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" "$1"
}
pstate() { tmux -S "$s" show-options -pqv -t "${1:-$pane}" @agent_state; }
preply() { tmux -S "$s" show-options -pqv -t "${1:-$pane}" @roost-reply; }

# --- the real captures -------------------------------------------------------
FIX_DIR=/tmp/roost-codex-fixture
# codex exec, "Reply with exactly one word: charlie", 3 events in 2.6s.
UPS_PAYLOAD='{"session_id":"01a04fb5-68ef-7020-b6e6-87058953ee62","turn_id":"01a04fb5-6911-7c43-9b6f-31e65ca640dc","transcript_path":"'"$FIX_DIR"'/rollout.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"UserPromptSubmit","model":"granite4.2:3b","permission_mode":"bypassPermissions","prompt":"Reply with exactly one word: charlie"}'
STOP_PAYLOAD='{"session_id":"01a04fb5-68ef-7020-b6e6-87058953ee62","turn_id":"01a04fb5-6911-7c43-9b6f-31e65ca640dc","transcript_path":"'"$FIX_DIR"'/rollout.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"Stop","model":"granite4.2:3b","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"charlie"}'
# ...and the SessionEnd that followed that Stop 22 MILLISECONDS later. Both
# timestamps are in the capture: Stop at 1788043686.736942, SessionEnd at
# 1788043686.759258.
SESSIONEND_PAYLOAD='{"session_id":"01a04fb5-68ef-7020-b6e6-87058953ee62","transcript_path":"'"$FIX_DIR"'/rollout.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"SessionEnd","reason":"other"}'
# The second turn of a TUI session — proof Stop is per TURN, not per session.
STOP2_PAYLOAD='{"session_id":"01a04fc1-6a96-7380-bd86-9f9ec3e848fc","turn_id":"01a04fc5-4c40-7320-bfe2-b0c4543819ff","transcript_path":"'"$FIX_DIR"'/rollout2.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"Stop","model":"granite4.2:8b","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"foxtrot"}'
# A reply with newlines, a fenced block and escaped double quotes, so the JSON
# unescaping in scripts/roost-agent-state is exercised on something a `cut` or
# a `sed` would mangle.
STOP_MULTILINE_PAYLOAD='{"session_id":"01a04fc6-ea13-7c61-943f-fad71aa9031d","turn_id":"01a04fc6-ea36-70f3-8a3d-d2e906949fd7","transcript_path":"'"$FIX_DIR"'/rollout3.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"Stop","model":"granite4.2:3b","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"```\nline one has a \"quoted\" word\nline two ends here\n```"}'
# The real escalation dialog: read-only sandbox, -a on-request, granite4.2:8b,
# with "Would you like to run the following command?" on screen at the moment
# this fired.
PERM_PAYLOAD='{"session_id":"01a04fc5-e328-7af1-89c5-6977a6571605","turn_id":"01a04fc5-ea7d-7802-9a79-c1e6e457863b","transcript_path":"'"$FIX_DIR"'/rollout4.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"PermissionRequest","model":"granite4.2:8b","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"echo escalate-me > /tmp/cx-esc.txt","description":"Need to write to /tmp which is outside the workspace sandbox root due to read-only filesystem restriction."}}'
POST_PAYLOAD='{"session_id":"01a04fb7-b117-7e62-9cb5-160cba0b5dfa","turn_id":"01a04fb7-b137-7750-86f5-15ae85c229a5","transcript_path":"'"$FIX_DIR"'/rollout5.jsonl","cwd":"'"$FIX_DIR"'/work","hook_event_name":"PostToolUse","model":"granite4.2:8b","permission_mode":"bypassPermissions","tool_name":"Bash","tool_input":{"command":"echo hi > out.txt"},"tool_response":""}'

# --- 1. the mapping table ----------------------------------------------------

hook UserPromptSubmit "$UPS_PAYLOAD"
assert_eq "$(pstate)" "working" "UserPromptSubmit reports working"

hook PostToolUse "$POST_PAYLOAD"
assert_eq "$(pstate)" "working" "PostToolUse reports working"

hook PermissionRequest "$PERM_PAYLOAD"
assert_eq "$(pstate)" "blocked" "PermissionRequest reports blocked"

# The clear, and the whole reason PostToolUse is registered at all. No hook
# fires when the human answers the dialog, so PostToolUse is the first
# observable event afterwards — measured on 0.151.0, 1s after "1. Yes,
# proceed": PreToolUse -> PermissionRequest -> (human) -> PostToolUse.
hook PostToolUse "$POST_PAYLOAD"
assert_eq "$(pstate)" "working" "PostToolUse clears blocked"

hook Stop "$STOP_PAYLOAD"
assert_eq "$(pstate)" "done" "Stop reports done"
assert_eq "$(preply)" "charlie" "Stop records the turn's reply"

# --- 2. the SessionEnd trap --------------------------------------------------
#
# The scout's costing table mapped SessionEnd -> idle, and in a TUI pane that
# looks right: SessionEnd fires only when codex exits (measured — a two-turn
# TUI session fired Stop twice and SessionEnd once, on ^C).
#
# Under `codex exec` it is a different event entirely. Measured twice on this
# machine, SessionEnd lands 22ms and 25ms after Stop, in the SAME process:
#
#   1788043686.736942 Stop
#   1788043686.759258 SessionEnd
#
# So SessionEnd -> idle overwrites the ✅ this turn just earned with 💤, a
# frame later, and the fleet loses the one badge that says "there is something
# to look at here". `roost read` still returns the reply, which is what makes
# this quiet rather than loud.
#
# It is not reported at all. spec §1 is explicit that idle is a DEFAULT rather
# than a report — neither shipped adapter has ever reported it — and an unstamped
# pane already renders as idle, so there is nothing to gain against this cost.
hook SessionEnd "$SESSIONEND_PAYLOAD"
assert_eq "$(pstate)" "done" "the SessionEnd 22ms after Stop does not overwrite done"
assert_eq "$(preply)" "charlie" "...and does not disturb the recorded reply"

# --- 3. events roost deliberately does not map -------------------------------
#
# These four are real codex events (the binary's own enum has twelve:
# PreToolUse PermissionRequest PostToolUse PreCompact PostCompact SessionStart
# SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt) and
# roost registers none of them, so codex never invokes the shim with these
# names. The assertion is that the shim is still inert if one arrives — a
# hooks.json a user extended by hand must not badge from a signal nobody
# measured.
#
# SubagentStop is the one that matters: it is how a child's end is announced,
# which is why Stop cannot be a subagent's (spec §5 T1). If codex ever routed a
# child's end through Stop instead, this file would go on passing and the badge
# would go `done` mid-turn — so the live smoke test drives a real subagent turn.
#
# Interrupt left this list in #38: it is now registered, and section 11 holds
# what it does.
for ev in SubagentStart SubagentStop PreCompact PostCompact SessionStart; do
  hook "$ev" "{}"
  assert_eq "$(pstate)" "done" "$ev leaves the badge alone"
done

# --- 4. a hook may never fail -------------------------------------------------
#
# Codex reads a hook's exit code. Its own error strings name the contract —
# "UserPromptSubmit hook exited with code 2 but did not write a blocking reason
# to stderr", "PreToolUse hook returned unsupported continue:false" — so a
# non-zero exit out of this shim is a veto on the user's tool call, delivered by
# their status bar. That is the one failure mode an adapter must not have: spec
# "It must never throw" says an adapter that cannot badge must leave the agent
# WORKING.
for ev in UserPromptSubmit PostToolUse PermissionRequest Stop SessionEnd Nonsense; do
  hook "$ev" "$STOP_PAYLOAD" >/dev/null 2>&1
  assert_eq "$?" "0" "$ev exits 0"
done

# ...including when the sink is not where the shim expects it. A copy outside
# the checkout has no ../../scripts/roost-agent-state to call, which stands in
# for every way that call can fail (a half-finished `git pull`, a checkout moved
# after hooks.json was written, a permission change).
cp "$HOOK" "$lonedir/roost-codex-hook"
printf '%s' "$STOP_PAYLOAD" | env TMUX="$s,0,0" TMUX_PANE="$pane" "$lonedir/roost-codex-hook" Stop >/dev/null 2>&1
assert_eq "$?" "0" "a shim that cannot reach roost-agent-state still exits 0"

# --- 5. reply BEFORE done, asserted on the write order -----------------------
#
# spec §2: `roost wait-done` returns the instant the badge stops being
# working/blocked, and the documented idiom is wait-done then read — so a state
# stamped before the reply opens a window where the reader falls back to
# scraping the screen. Asserting the two VALUES cannot see that; only the order
# of the writes can, which is what tests/opencode-plugin-harness.mjs:313 checks
# as `state,reply,state`.
#
# The recorder is a `tmux` on PATH ahead of the real one: roost-agent-state
# calls tmux by bare name, so this sees every call it makes, in order.
tmuxlog="$shimdir/tmux.log"
realtmux="$(command -v tmux)"
cat > "$shimdir/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmuxlog"
exec "$realtmux" "\$@"
EOF
chmod +x "$shimdir/tmux"
: > "$tmuxlog"
# From `working`, so the Stop below is a real transition rather than a no-op.
hook UserPromptSubmit "$UPS_PAYLOAD"
: > "$tmuxlog"
printf '%s' "$STOP2_PAYLOAD" | env PATH="$shimdir:$PATH" TMUX="$s,0,0" TMUX_PANE="$pane" "$HOOK" Stop
# Only set-option lines: the state READ is a display-message whose format
# string contains the literal "#{@agent_state}", and counting that as a write
# would make this assertion pass no matter which order the writes happened in.
#
# `uniq` collapses ADJACENT repeats, and only those. Since #91 the state write
# can be a single `if-shell` whose argv names @agent_state twice — once in the
# condition it is tested against, once in the branch that writes it — and that
# is still one write, in one place, at one instant. Collapsing adjacent repeats
# keeps this assertion about ORDER: the failure it exists to catch is
# state,reply,state, and neither that nor reply,state,reply has adjacent
# repeats to lose.
order="$(grep 'set-option' "$tmuxlog" | grep -oE '@roost-reply|@agent_state' | uniq | paste -sd, -)"
assert_eq "$order" "@roost-reply,@agent_state" "Stop writes the reply BEFORE the state"
# The same log, read for what must NOT be there. A healthy working -> done
# transition on a pane that was never error has no @roost-error-reason to
# clear, and roost-agent-state is the hook every live Claude agent runs, so a
# tmux call spent clearing nothing is paid on every transition of every agent.
assert_eq "$(grep -c 'roost-error-reason' "$tmuxlog")" "0" \
  "a healthy Stop on a pane that was not error spends no tmux call on @roost-error-reason"
assert_eq "$(preply)" "foxtrot" "the second turn's reply replaces the first"

# --- 6. a re-entrant Stop still records its reply ----------------------------
#
# The pane already reads `done` here, so roost-agent-state's unchanged-state
# early bail is live. Its reply write sits deliberately ABOVE that bail, and
# this is the fixture for it: without that placement `roost read` serves the
# PREVIOUS turn's answer for the rest of the session.
assert_eq "$(pstate)" "done" "the pane is already done before the re-entrant Stop"
hook Stop "$STOP_MULTILINE_PAYLOAD"
want="$(printf '```\nline one has a "quoted" word\nline two ends here\n```')"
assert_eq "$(preply)" "$want" "a Stop arriving on an already-done pane still records the new reply"

# --- 7. the pane names itself codex, not claude ------------------------------
#
# spec §5 T9. Without ROOST_AGENT_NAME the fallback is @roost-name-default,
# whose honest built-in value is "claude" because scripts/roost-agent-state IS
# Claude Code's hook — so every codex pane would read "claude" on its border
# and in the switcher. A FRESH pane, because the one above was labelled by the
# first assertion in this file and the labelling branch never runs twice.
fresh="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$fresh" fresh
printf '%s' "$UPS_PAYLOAD" | env TMUX="$s,0,0" TMUX_PANE="$fresh" "$HOOK" UserPromptSubmit
assert_eq "$(tmux -S "$s" show-options -pqv -t "$fresh" @roost-name)" "codex" \
  "an unnamed codex pane labels itself codex"

# A name the human chose still wins, exactly as it does for Claude.
named="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane" 'sh -c "while :; do sleep 5; done"')"
require_pane "$named" named
tmux -S "$s" set-option -p -t "$named" @roost-name "reviewer"
printf '%s' "$UPS_PAYLOAD" | env TMUX="$s,0,0" TMUX_PANE="$named" "$HOOK" UserPromptSubmit
assert_eq "$(tmux -S "$s" show-options -pqv -t "$named" @roost-name)" "reviewer" \
  "a human-chosen pane name outranks ROOST_AGENT_NAME"

# --- 8. inert outside roost --------------------------------------------------
#
# The property that makes it safe to leave ~/.codex/hooks.json wired while
# running codex anywhere else. It is inherited from roost_self_socket rather
# than re-implemented, and it is asserted here because the shim is a new entry
# point into that guard.
outside="$(mktemp -d /tmp/amx.XXXX)"
tmux -S "$outside/plain" -f /dev/null new-session -d
opane="$(tmux -S "$outside/plain" display -p '#{pane_id}')"
printf '%s' "$UPS_PAYLOAD" | env TMUX="$outside/plain,0,0" TMUX_PANE="$opane" "$HOOK" UserPromptSubmit
assert_eq "$(tmux -S "$outside/plain" show-options -pqv -t "$opane" @agent_state)" "" \
  "a tmux server whose socket is not named roost is left unstamped"
printf '%s' "$UPS_PAYLOAD" | env -u TMUX -u TMUX_PANE "$HOOK" UserPromptSubmit
assert_eq "$?" "0" "outside tmux entirely, the shim exits 0 and does nothing"
tmux -S "$outside/plain" kill-server 2>/dev/null

# "Does nothing" includes spending nothing. Since #39 the shim reads and parses
# the Stop payload itself, and ~/.codex/hooks.json is GLOBAL, so a parse ahead
# of the tmux guard would spawn an interpreter on every codex turn anywhere on
# the machine — including, on a Mac without the Command Line Tools, the
# /usr/bin/python3 stub. Counted with a python3 on PATH that logs each call.
# A real file that execs the real one, never a symlink: a `>` through a
# symlink in a shim directory overwrites the binary it points at.
if command -v python3 >/dev/null 2>&1; then
  pylog="$outside/python3.log"
  mkdir -p "$outside/pybin"
  cat > "$outside/pybin/python3" <<EOF
#!/bin/sh
printf 'x\n' >> "$pylog"
exec "$(command -v python3)" "\$@"
EOF
  chmod +x "$outside/pybin/python3"
  : > "$pylog"
  printf '%s' "$STOP_PAYLOAD" | env -u TMUX -u TMUX_PANE PATH="$outside/pybin:$PATH" "$HOOK" Stop
  assert_eq "$(grep -c x "$pylog")" "0" "outside tmux, a Stop spawns no JSON reader at all"
  : > "$pylog"
  printf '%s' "$STOP_PAYLOAD" | env -u TMUX_PANE TMUX="$s,0,0" PATH="$outside/pybin:$PATH" "$HOOK" Stop
  assert_eq "$(grep -c x "$pylog")" "0" "...nor with TMUX set but no TMUX_PANE"
  # Detector honesty: inside roost the same Stop MUST reach the logger, or both
  # zeros above only prove the wrapper was never on PATH.
  : > "$pylog"
  printf '%s' "$STOP_PAYLOAD" | env TMUX="$s,0,0" TMUX_PANE="$pane" PATH="$outside/pybin:$PATH" "$HOOK" Stop
  [ "$(grep -c x "$pylog")" -ge 1 ]
  assert_true $? "...while inside roost the logging python3 really is the one called"
else
  echo "  SKIP: python3 not found — the no-spawn-outside-roost check needs it to count"
fi
rm -rf "$outside"

# --- 9. the registration is frozen -------------------------------------------
#
# spec §4, and this is the assertion that enforces it. Codex stores a
# trusted_hash per handler, keyed
# <hooks.json path>:<snake_case event>:<group>:<handler>, and skips any handler
# whose hash no longer matches — silently, with a successful-looking turn.
# Measured on 0.150.1 by the scout: appending ` --extra-arg` to the command
# broke 0 of 8 hooks into firing, and changing ONLY a timeout from 10 to 11
# broke 7 of 8.
#
# So these strings are a public interface with the same status as @agent_state's
# name (AGENTS.md §6). Changing one here does not fail a user's install loudly;
# it turns their badges off. If this assertion fails, the fix is to revert the
# change, not to update the expectation.
#
# Measured on 0.151.0 and this is why only four events are registered: ADDING a
# new event key to hooks.json does NOT invalidate the handlers already trusted.
# A 4-event file was trusted, SessionEnd was added, and the original two still
# fired on the next run (the new one did not). Registration can therefore grow
# later; it can never be edited.
hooks_out="$("$HERE/bin/roost" hooks codex)"
# The command carries the event name and NOTHING else — no --stop-hook, no
# flags. Claude's hooks spell --stop-hook out because that config is a text file
# a user edits and re-prints at will; this one is hashed, so every word in it is
# a word roost can never take back. Which events want a reply is the shim's
# business.
#
# #38 grew the registration by one, Interrupt, in exactly the shape of the other
# four: the event name as the only argument, timeout 10. The four already
# trusted are asserted unchanged below, which is what keeps their trust.
for ev in UserPromptSubmit PostToolUse PermissionRequest Stop Interrupt; do
  assert_contains "$hooks_out" \
    "{ \"type\": \"command\", \"command\": \"$HERE/adapters/codex/roost-codex-hook $ev\", \"timeout\": 10 }" \
    "the frozen $ev handler object is byte-for-byte what it always was"
done
assert_eq "$(printf '%s' "$hooks_out" | grep -c '"timeout"')" "5" \
  "exactly five handlers are registered"
# The comment block above the JSON is prose for the human, so the JSON has to be
# extractable on its own. `roost hooks codex > ~/.codex/hooks.json` would write
# the comments too, which is why the printed instructions say to copy the object.
if command -v python3 >/dev/null 2>&1; then
  json="$(printf '%s' "$hooks_out" | sed -n '/^{/,$p')"
  printf '%s' "$json" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null
  assert_eq "$?" "0" "the printed block parses as JSON once the comments are dropped"
else
  echo "  SKIP: python3 not found — JSON validity of roost hooks codex not checked"
fi

# `roost hooks` with no argument must keep printing the CLAUDE config. It is
# documented in site/content/docs/state-badges.md, in bin/roost's own header,
# and in scripts/roost-init's output; a new subcommand that stole the default
# would break every one of them at once.
claude_out="$("$HERE/bin/roost" hooks)"
assert_contains "$claude_out" "roost-agent-state working" "bare 'roost hooks' still prints the Claude config"
assert_contains "$claude_out" "permission_prompt" "...including the Notification matcher"

# --- 10. a dead turn is not done (#39) ---------------------------------------
#
# Codex has no error event, and a turn that never reaches its model still fires
# Stop. What that Stop does NOT carry is a reply: known-gaps records that for a
# dead turn `last_assistant_message` is empty. That is a field codex genuinely
# emits, so it is the signal — an inference, announced in docs/known-gaps.md
# and in site/content/docs/state-badges.md, not a screen scrape.
#
# These three payloads are NOT captures. Each is the real STOP_PAYLOAD above
# with only `last_assistant_message` changed — to "", to null, and removed —
# because the shape a dead turn arrives in was recorded as "empty" without the
# raw bytes, and a reader that only handled one spelling would pass a test
# written in that spelling and miss the other two.
STOP_DEAD_EMPTY="${STOP_PAYLOAD%\"last_assistant_message\":\"charlie\"\}}\"last_assistant_message\":\"\"}"
STOP_DEAD_NULL="${STOP_PAYLOAD%\"last_assistant_message\":\"charlie\"\}}\"last_assistant_message\":null}"
STOP_DEAD_ABSENT="${STOP_PAYLOAD%,\"last_assistant_message\":\"charlie\"\}}}"
# Detector honesty: if the suffix strip above ever misses, all three variables
# are STOP_PAYLOAD unchanged, and every "is not done" assertion below would be
# testing a healthy turn — which fails loudly, but for a reason that reads as a
# broken fix instead of a broken fixture.
assert_contains "$STOP_DEAD_EMPTY" '"last_assistant_message":""}' "the empty-reply fixture really is empty"
assert_contains "$STOP_DEAD_NULL" '"last_assistant_message":null}' "the null-reply fixture really is null"
case "$STOP_DEAD_ABSENT" in
  *last_assistant_message*) assert_eq present absent "the absent-reply fixture really has no reply field" ;;
  *) assert_eq ok ok "the absent-reply fixture really has no reply field" ;;
esac

# A pane in a window of its own, so the window-target wait-done below sees this
# pane and nothing the earlier sections left working.
dead="$(tmux -S "$s" new-window -d -P -F '#{pane_id}' 'sh -c "while :; do sleep 5; done"')"
require_pane "$dead" dead
deadwin="$(tmux -S "$s" display -p -t "$dead" '#{window_id}')"
dhook() { printf '%s' "$2" | env TMUX="$s,0,0" TMUX_PANE="$dead" "$HOOK" "$1"; }
reason() { tmux -S "$s" show-options -pqv -t "$dead" @roost-error-reason; }

# Turn 1 answers, so there is a real reply on the pane for the dead turn to
# leave behind if it forgets to clear it.
dhook UserPromptSubmit "$UPS_PAYLOAD"
dhook Stop "$STOP_PAYLOAD"
assert_eq "$(pstate "$dead")" "done" "a healthy codex turn still reaches done"
assert_eq "$(preply "$dead")" "charlie" "...with its reply"

for p in "$STOP_DEAD_EMPTY" "$STOP_DEAD_NULL" "$STOP_DEAD_ABSENT"; do
  dhook UserPromptSubmit "$UPS_PAYLOAD"
  dhook Stop "$p"; rc=$?
  assert_eq "$rc" "0" "a dead turn's Stop still exits 0 [$p]"
  assert_eq "$(pstate "$dead")" "error" "a codex turn that ends with no reply badges error, not done [$p]"
  # read keys its "from its previous turn" notice on error too, but a notice on
  # a reply that should not be there is weaker than the reply not being there.
  assert_eq "$(preply "$dead")" "" "...and turn 1's reply is not left on the pane as this turn's [$p]"
  assert_contains "$(reason)" "no reply" "...and the pane records why it is error [$p]"
done

# `roost wait-done` against the dead pane: non-zero, and a message that says
# why, by pane and by window. Before this fix it exited 0 — success on a corpse.
werr="$(ROOST_SOCKET="$s" "$HERE/bin/roost" wait-done "$dead" 2 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "1" "wait-done on a dead codex pane exits non-zero"
assert_contains "$werr" "error state" "...naming the state"
assert_contains "$werr" "no reply" "...and naming the reason"
werr="$(ROOST_SOCKET="$s" "$HERE/bin/roost" wait-done "$deadwin" 2 2>&1 >/dev/null)"; rc=$?
assert_eq "$rc" "1" "wait-done on a window holding a dead codex pane exits non-zero"
assert_contains "$werr" "no reply" "...and names the reason too"

# `roost read`, the other half of the wait-done-then-read idiom. The dead turn
# cleared its reply, so read falls back to the screen — correctly — but its
# notice used to guess "no roost adapter, or its turn has not finished", both
# false here: the pane has an adapter and its turn finished, badly. The reason
# is on the pane, so read says that instead.
rerr="$(ROOST_SOCKET="$s" "$HERE/bin/roost" read "$dead" 5 2>&1 >/dev/null)"
assert_contains "$rerr" "no recorded reply" "read on a dead codex pane still announces its screen fallback"
assert_contains "$rerr" "no reply" "...and names the reason the turn has none"
case "$rerr" in
  *"no roost adapter"*) assert_eq guessed named "...instead of guessing the pane has no adapter" ;;
  *) assert_eq ok ok "...instead of guessing the pane has no adapter" ;;
esac
# The replaced line also carried the way out of this notice, and an errored
# pane needs that pointer as much as any other: the caller is about to look at
# a screen, and `roost screen` is how to do that without the notice.
assert_contains "$rerr" "roost screen" "...and still points at roost screen"

# The next healthy turn recovers completely: the reason goes with the error, so
# it can never be printed about a later turn it does not describe.
dhook UserPromptSubmit "$UPS_PAYLOAD"
assert_eq "$(pstate "$dead")" "working" "the turn after a dead one starts working"
assert_eq "$(reason)" "" "...and the dead turn's reason is cleared"
dhook Stop "$STOP2_PAYLOAD"
assert_eq "$(pstate "$dead")" "done" "...and a healthy turn after a dead one reaches done"
assert_eq "$(preply "$dead")" "foxtrot" "...with its own reply"
ROOST_SOCKET="$s" "$HERE/bin/roost" wait-done "$dead" 2 >/dev/null 2>&1
assert_eq "$?" "0" "wait-done on the recovered pane exits 0"

# A payload nobody could read is "we cannot tell", not "it died". Badging it
# error would turn every turn on a machine with neither python3 nor jq into a
# desktop notification, so it keeps the old behaviour — done, with the reply
# cleared so `roost read` announces its screen fallback. docs/known-gaps.md
# names this as the part still not covered.
dhook UserPromptSubmit "$UPS_PAYLOAD"
dhook Stop 'not json at all'
assert_eq "$(pstate "$dead")" "done" "an unreadable Stop payload is not guessed to be a dead turn"
assert_eq "$(reason)" "" "...and records no error reason"

# --- 11. a declined or interrupted turn leaves blocked (#38) ------------------
#
# Measured on codex-cli 0.154.0 with a logger on all twelve events, local
# ollama granite4.2:8b, `codex -a on-request -s read-only`:
#
#   answer at the dialog   events after the answer
#   3. No                  Interrupt (+42ms), then nothing — no Stop
#   Esc                    Interrupt (+84ms), then nothing — no Stop
#   1. Yes                 PostToolUse (+132ms), no Interrupt, later Stop
#   Esc while streaming    Interrupt (+124ms), no Stop
#
# So Interrupt is the one event that ends a declined turn, and until it was
# registered nothing unstamped 🛑. The payload below is the REAL one from the
# `No` capture, verbatim: its paths are under a scratch /private/tmp directory,
# not a home directory, so nothing needed rewriting.
INTERRUPT_PAYLOAD='{"session_id":"00000000-f246-4fbf-8dab-9e9d161b6d8d","turn_id":"00000000-f972-4701-86d5-4df4890ded59","transcript_path":"/private/tmp/amx.Guig/cx/codexhome/sessions/2026/09/14/rollout-2026-09-14T10-19-34-00000000-f246-4fbf-8dab-9e9d161b6d8d.jsonl","cwd":"/private/tmp/amx.Guig/cx/proj","hook_event_name":"Interrupt","model":"granite4.2:8b","permission_mode":"default"}'
ip="$(tmux -S "$s" split-window -d -P -F '#{pane_id}' -t "$pane")"
require_pane "$ip" "interrupt"
ihook() { printf '%s' "$2" | env TMUX="$s,0,0" TMUX_PANE="$ip" "$HOOK" "$1"; }

ihook UserPromptSubmit "$UPS_PAYLOAD"
ihook Stop "$STOP_PAYLOAD"
assert_eq "$(preply "$ip")" "charlie" "setup: a previous turn left its reply"
ihook UserPromptSubmit "$UPS_PAYLOAD"
ihook PermissionRequest "$PERM_PAYLOAD"
assert_eq "$(pstate "$ip")" "blocked" "setup: the next turn is at a dialog"
ihook Interrupt "$INTERRUPT_PAYLOAD"
assert_eq "$?" "0" "Interrupt exits 0"
assert_eq "$(pstate "$ip")" "idle" "Interrupt after a declined dialog leaves blocked, for idle"
assert_eq "$(preply "$ip")" "" "...and clears the previous turn's reply, which is not this turn's"
assert_eq "$(tmux -S "$s" show-options -pqv -t "$ip" @roost-error-reason)" "" \
  "...and is not an error: no reason is recorded"
ROOST_SOCKET="$s" "$HERE/bin/roost" send "$ip" "true" >/dev/null 2>&1
assert_eq "$?" "0" "send reaches the pane once Interrupt has fired"

# An interrupt while the model is still streaming, with no dialog: the same
# event, the same answer. Measured with no Stop after it.
ihook UserPromptSubmit "$UPS_PAYLOAD"
ihook Interrupt "$INTERRUPT_PAYLOAD"
assert_eq "$(pstate "$ip")" "idle" "Interrupt while working leaves working, for idle"

# It must not fight #39/#53's empty-Stop -> error path. Interrupt never reads
# the Stop verdict, and a later Stop still decides its own turn.
ihook UserPromptSubmit "$UPS_PAYLOAD"
ihook Stop "$STOP2_PAYLOAD"
assert_eq "$(pstate "$ip")" "done" "a healthy turn after an interrupt still reaches done"
assert_eq "$(preply "$ip")" "foxtrot" "...with its own reply"
ihook UserPromptSubmit "$UPS_PAYLOAD"
ihook Stop "$STOP_DEAD_EMPTY"
assert_eq "$(pstate "$ip")" "error" "an empty Stop after an interrupt is still #39's error"
ihook Interrupt "$INTERRUPT_PAYLOAD"
assert_eq "$(pstate "$ip")" "idle" "an Interrupt after an error moves on to idle"
assert_eq "$(tmux -S "$s" show-options -pqv -t "$ip" @roost-error-reason)" "" \
  "...and takes the error's reason with it"

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
