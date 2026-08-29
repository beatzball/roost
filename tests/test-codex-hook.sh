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
for ev in SubagentStart SubagentStop PreCompact PostCompact SessionStart Interrupt; do
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
order="$(grep 'set-option' "$tmuxlog" | grep -oE '@roost-reply|@agent_state' | paste -sd, -)"
assert_eq "$order" "@roost-reply,@agent_state" "Stop writes the reply BEFORE the state"
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
for ev in UserPromptSubmit PostToolUse PermissionRequest Stop; do
  assert_contains "$hooks_out" \
    "{ \"type\": \"command\", \"command\": \"$HERE/adapters/codex/roost-codex-hook $ev\", \"timeout\": 10 }" \
    "the frozen $ev handler object is byte-for-byte what it always was"
done
assert_eq "$(printf '%s' "$hooks_out" | grep -c '"timeout"')" "4" \
  "exactly four handlers are registered"
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

printf '\n%d passed, %d failed\n' "$ROOST_TESTS_PASS" "$ROOST_TESTS_FAIL"
