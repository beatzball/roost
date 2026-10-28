# Probe 1.5 — a headless Claude in the pane's own shell writes over its key

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.5
(coordinator ruling R4). Date: 2026-10-27. Claude Code 2.1.312, this Mac
(tmux 3.6). Run count: once.

## Method

The rig of `tests/live/claude-background-smoke.sh`, unchanged in its guards:
a throwaway `-S` server whose socket ends in `/roost`, `HOME`,
`XDG_CONFIG_HOME` and `XDG_STATE_HOME` in a temp directory with the fake key
and the project trust seeded there, a local fake Messages API, and the
before/after hash of the real `~/.claude/settings.json` and project keys of
the real `~/.claude.json`.

One change from the smoke: the hooks went into the redirected HOME's
`.claude/settings.json` (user settings) instead of `--settings`, so a child
`claude -p` started from the Bash tool — which passes no `--settings` — loads
the same hooks an installed roost gives it. Those hooks were this checkout's
`roost hooks claude` plus one logger on `SessionStart` (`"matcher": "*"`)
that wrote the **names** of every `CLAUDE*` variable, the values of
`CLAUDE_CODE_ENTRYPOINT` and `CLAUDE_CODE_SESSION_ATTENDED` and no other
environment value, and the payload's `source` and `session_id`. Permission
rule `Bash(claude:*)`, so no dialog opened. The pane ran interactive `claude
--model haiku --permission-mode default`.

The fake API scripted three prompts, each one Bash tool call:
1. `claude -p hi --output-format json`
2. `claude -p hi --resume <the id from step 1's JSON> --output-format json`
3. `claude --bg -p hi` (2.1.312 offers `--bg`)

`@roost-session` was read with `show-options -pqv` after the interactive
start and 3 s after each step's reply.

## Result

Ids below are replaced by fake ids of the same shape.

| moment | `@roost-session` | `@roost-harness` |
|---|---|---|
| interactive start | `11111111-1111-4111-8111-111111111111` (the pane's own) | `claude` |
| after `claude -p hi` | **`22222222-2222-4222-8222-222222222222`** (the child's) | `claude` |
| after `claude -p --resume <child>` | `22222222-…` (unchanged: the same child id) | `claude` |
| after `claude --bg -p hi` | `22222222-…` | `claude` |

`SessionStart` as the logger saw it:

```
SessionStart (the pane's own Claude)
  names: CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_MAX_RETRIES CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PID CLAUDE_PROJECT_DIR CLAUDECODE
  CLAUDE_CODE_ENTRYPOINT=cli
  CLAUDE_CODE_SESSION_ATTENDED=1
  payload: source=startup session_id=11111111-1111-4111-8111-111111111111
SessionStart (claude -p hi, from the Bash tool)
  names: CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_MAX_RETRIES CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_SESSION_ID CLAUDE_EFFORT CLAUDE_ENV_FILE CLAUDE_PID CLAUDE_PROJECT_DIR CLAUDECODE
  CLAUDE_CODE_ENTRYPOINT=sdk-cli
  CLAUDE_CODE_SESSION_ATTENDED=0
  payload: source=startup session_id=22222222-2222-4222-8222-222222222222
SessionStart (claude -p hi --resume <child>)
  (same names as the line above)
  CLAUDE_CODE_ENTRYPOINT=sdk-cli
  CLAUDE_CODE_SESSION_ATTENDED=0
  payload: source=resume session_id=22222222-2222-4222-8222-222222222222
```

`claude --bg -p hi` fired no `SessionStart` that the pane's hooks saw and did
not move `@roost-session`; its own output was not captured in this run, so
whether it started a background session at all is not recorded. No process
from it was alive after the run.

The guard line the rig printed at the end:

```
  guard: ~/.claude/settings.json unchanged, and no project key was added to ~/.claude.json
```

## Outcome

**Row 2 of the task's table:** `@roost-session` moved to the child's id, and
the child's `SessionStart` environment carries values the interactive
session's does not: `CLAUDE_CODE_ENTRYPOINT=sdk-cli` (interactive: `cli`)
and `CLAUDE_CODE_SESSION_ATTENDED=0` (interactive: `1`). Both differ, on the
first start and on a resume. Task 1.15 builds R4 on exactly these names and
values: the Claude identity path ignores a report whose environment has
`CLAUDE_CODE_ENTRYPOINT=sdk-cli` or `CLAUDE_CODE_SESSION_ATTENDED=0`.

The variable names alone do not tell the two apart (the child also has
`CLAUDE_CODE_EXECPATH` and `CLAUDE_EFFORT`, but `CLAUDE_EFFORT` depends on how
the parent was started), so the rule rests on the two values, not on names.
