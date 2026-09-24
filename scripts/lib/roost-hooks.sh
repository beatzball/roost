# roost-hooks.sh — the claude and codex hook JSON bodies. Sourced by bin/roost
# and about to be sourced by the installer, so there is exactly one copy of
# these bytes rather than two that can drift.
#
# Each function prints ONLY the JSON object, no comment lines: bin/roost
# prints its own explanatory prose around the object, and hooks.json/
# settings.json are strict JSON with no comment syntax for the installer to
# write comments into anyway.
#
# THE FOUR CODEX HANDLER OBJECTS BELOW ARE FROZEN, and that is not a style
# note. Codex stores a hash of each normalised handler in
# $CODEX_HOME/config.toml and SKIPS any handler whose hash no longer matches
# — with nothing printed on stdout, on stderr, or in the TUI. Measured on
# codex-cli 0.150.1: appending one argument to a command string took 8 of 8
# hooks down, and changing a single timeout from 10 to 11 took 7 of 8 down.
# Moved here verbatim from bin/roost — do not edit a command or a timeout in
# roost_hooks_codex, ever.
#
# WHITESPACE IS NOT PART OF WHAT IS HASHED, and knowing that saves the next
# person a wasted round. The hash covers the PARSED handler struct, not the
# file bytes — so indentation, line breaks and key order in hooks.json are all
# free, and a caller that reflows this object to fit its own output
# (scripts/roost-install prints it indented inside a list) changes nothing
# codex can see. Measured on codex-cli 0.151.0 by calling its `hooks/list`
# app-server method against a scratch $CODEX_HOME, the same path both times so
# that only the file bytes varied: an unindented and a 2-space-indented
# hooks.json returned identical HookMetadata.currentHash for all four
# handlers, while changing a single timeout from 10 to 11 moved all four —
# the positive control proving the probe was sensitive to real drift. Codex's
# own generated schema puts currentHash alongside the deserialized fields,
# which is the mechanism behind the measurement.
#
# This narrows the rule above; it does not soften it. What is hashed is every
# VALUE in the parsed struct, so a changed command string or a changed argument
# still takes the handler down silently. Reflow freely; edit nothing.
#
# THE TIMEOUT STOPPED BEING HASHED SOMEWHERE BETWEEN 0.151.0 AND 0.154.0, and
# the two measurements above are both still right about the version each names.
# Re-measured on codex-cli 0.154.0 the same way — `hooks/list` over the
# app-server, one scratch $CODEX_HOME, one field changed at a time, a two-event
# hooks.json whose Stop handler never moves and is the negative control:
#
#   A  command "/bin/true Interrupt"      timeout 10  -> 06e8ee7caa7ca69f664e4a...
#   B  command "/bin/true Interrupt"      timeout  3  -> 06e8ee7caa7ca69f664e4a...
#   C  command "/bin/true Interrupt --x"  timeout  3  -> 0db7877522cf5461c283b3...
#      Stop, untouched throughout                     -> 5e9fc7fe549e9f615c9353...
#
# B is A with one digit changed and the hash does not move. C is the positive
# control: one appended argument moves it, so the probe is not blind. The
# command is still hashed; the timeout is not, on this version.
#
# What that does NOT license. The rule stands, because the rule is about what
# roost can PROMISE across versions: an old codex hashes the timeout, a new one
# does not, and roost does not get to pick which one a user runs. A timeout
# edit is safe on 0.154.0 and silently un-badges 0.151.0. Treat every value in
# here as frozen, and if a later version must differ, measure it again — in
# both directions, with the control — rather than trusting this note.
#
# THE ONE EDIT EVER MADE, and the bar the next one has to clear. Interrupt
# asks for 3, not 10, because 10 was never a number codex honoured: codex caps
# an Interrupt hook at 3 seconds, clamps anything larger, and prints
# `warning: clamping Interrupt hook timeout to 3s in <path>/hooks.json` on
# every single start — naming a home directory on the user's screen, which is
# the same thing AGENTS.md §1 keeps out of commits. docs/known-gaps.md quotes
# that warning verbatim from an unedited `codex exec` stderr, so the cap is
# measured rather than inferred, and SessionEnd is capped the same way.
#
# What made it worth making is that the BEHAVIOUR was already 3s. The hook
# fired with a 3-second budget before this change and fires with one after it;
# only the warning stops. An edit that also changed what the hook does would
# not clear that bar, because it would trade a working badge on every
# already-trusted machine for the fix.
#
# It was shipped expecting to cost every codex user one "Hooks need review",
# and on 0.154.0 it costs nothing at all: the timeout is not hashed there, so
# `roost install` rewrites the number and the trust entry still matches. On an
# older codex, which does hash it, the re-trust is real. So the user-facing
# wording says "if codex asks" rather than "codex will ask" — which is the only
# form true on both. scripts/roost-doctor still detects the old value, because
# the stale number is what brings the warning back whatever the version does
# about hashing.
#
# Resolves its own checkout root rather than trusting an inherited
# $ROOST_HOME, for the same reason scripts/lib/roost-adapters.sh does (see its
# _roost_adapter_root comment): bin/roost exports ROOST_HOME into every pane
# of the session it starts, so a caller running inside a roost session could
# otherwise print a hook pointing at a DIFFERENT checkout than the one whose
# `roost hooks` it just ran.
#
# Both functions take an OPTIONAL explicit target-script path. With no
# argument they self-resolve, which is what `roost hooks` wants and is why its
# output is byte-identical either way. The argument exists because
# scripts/lib/roost-json.sh's `roost_json_merge FILE claude-hooks
# TARGET_SCRIPT` is handed the script path by its caller (and by its tests,
# which inject a fixed one) rather than a checkout root — and it takes the
# SCRIPT path, not the root, precisely so an injected path that does not look
# like `<root>/scripts/roost-agent-state` still works. A path is passed
# through verbatim; nothing here derives one from the other.
_roost_hooks_root() {
  local source dir root
  source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  root="$(cd -P "$(dirname "$source")/../.." && pwd)"
  printf '%s' "${root%/}"
}

# roost_hooks_claude [TARGET_SCRIPT] -- TARGET_SCRIPT defaults to this
# checkout's own scripts/roost-agent-state.
#
# PermissionRequest comes BEFORE Notification here, and the order is the one
# thing about this object's shape that is worth a sentence. Nothing in Claude
# reads it -- events fire when they fire -- but scripts/lib/roost-json.sh
# walks the patch's events in ITS order when it merges, so a reader comparing
# a wired settings.json against this block sees the two dialog hooks together.
# PermissionRequest is the one that fires as the dialog opens; the
# permission_prompt Notification arrives a flat six seconds later (measured on
# 2.1.278, tests/test-claude-permission-request.sh) and stays wired as the
# fallback for a Claude old enough not to have the event at all.
#
# PermissionRequest takes NO matcher. Its matcher would be a TOOL NAME, and
# roost badges a dialog whatever asked for it: an MCP server's tool name is
# not knowable in advance, and a list of the built-in ones would miss whichever
# tool Claude Code adds next.
#
# PostToolUseFailure sits beside PostToolUse and runs the same command, because
# PostToolUse fires only on SUCCESS. Measured on 2.1.278: a Bash that exits
# non-zero after the human answered Yes fires PostToolUseFailure and no
# PostToolUse, so without this entry the 🛑 that PermissionRequest stamped had
# nothing to clear it and the turn ended with the pane still blocked
# (tests/test-claude-permission-request.sh). It badges `working` for exactly
# the reason PostToolUse does: a failed tool call does not end the turn.
#
# --tool-hook on both of them lets the hook read that event's payload, and it
# reads it only when the pane already reads 🛑: a SUBAGENT's tool result must
# not clear a dialog that a different agent opened on the same pane. Leave the
# flag off and every badge is still correct except that one case, which is why
# it is a flag rather than an always-on stdin read — this pair fires on every
# tool call of every live agent.
roost_hooks_claude() {
  local target context
  if [ $# -ge 1 ]; then target="$1"
  else target="$(_roost_hooks_root)/scripts/roost-agent-state"; fi
  # SessionStart runs a DIFFERENT script from the other eight, so it cannot use
  # $target. It is derived as a sibling of $target rather than from
  # _roost_hooks_root because $target may have been injected by a caller (the
  # installer, or a test with a fixed path) and must stay the authority on
  # which directory these hooks point at -- deriving one from the root and one
  # from the argument is how a wired config ends up half-pointing at two
  # different checkouts.
  context="${target%/*}/roost-session-context"
  cat <<JSON
{
  "hooks": {
    "SessionStart": [
      { "matcher": "*",
        "hooks": [ { "type": "command", "command": "$context" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$target working" } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "$target blocked --permission-request-hook" } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt",
        "hooks": [ { "type": "command", "command": "$target blocked --notification-hook" } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "$target working --tool-hook" } ] }
    ],
    "PostToolUseFailure": [
      { "hooks": [ { "type": "command", "command": "$target working --tool-hook" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$target done --stop-hook" } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "command": "$target error --stop-failure-hook" } ] }
    ]
  }
}
JSON
}

# roost_hooks_codex [TARGET_SCRIPT] -- TARGET_SCRIPT defaults to this
# checkout's own adapters/codex/roost-codex-hook.
roost_hooks_codex() {
  local target
  if [ $# -ge 1 ]; then target="$1"
  else target="$(_roost_hooks_root)/adapters/codex/roost-codex-hook"; fi
  cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$target UserPromptSubmit", "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "$target PostToolUse", "timeout": 10 } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "$target PermissionRequest", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$target Stop", "timeout": 10 } ] }
    ],
    "Interrupt": [
      { "hooks": [ { "type": "command", "command": "$target Interrupt", "timeout": 3 } ] }
    ]
  }
}
JSON
}
