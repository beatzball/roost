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
# Requires $ROOST_HOME set by the caller (bin/roost and the installer both
# resolve their own before sourcing this).

roost_hooks_claude() {
  cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/scripts/roost-agent-state working" } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt",
        "hooks": [ { "type": "command", "command": "$ROOST_HOME/scripts/roost-agent-state blocked" } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/scripts/roost-agent-state working" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/scripts/roost-agent-state done --stop-hook" } ] }
    ]
  }
}
JSON
}

roost_hooks_codex() {
  cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/adapters/codex/roost-codex-hook UserPromptSubmit", "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/adapters/codex/roost-codex-hook PostToolUse", "timeout": 10 } ] }
    ],
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/adapters/codex/roost-codex-hook PermissionRequest", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$ROOST_HOME/adapters/codex/roost-codex-hook Stop", "timeout": 10 } ] }
    ]
  }
}
JSON
}
