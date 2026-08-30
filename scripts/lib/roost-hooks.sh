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
# VALUE in the parsed struct, so a changed command string, a changed argument
# or a changed timeout still takes the handler down silently. Reflow freely;
# edit nothing.
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
roost_hooks_claude() {
  local target
  if [ $# -ge 1 ]; then target="$1"
  else target="$(_roost_hooks_root)/scripts/roost-agent-state"; fi
  cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$target working" } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt",
        "hooks": [ { "type": "command", "command": "$target blocked" } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "$target working" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$target done --stop-hook" } ] }
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
    ]
  }
}
JSON
}
