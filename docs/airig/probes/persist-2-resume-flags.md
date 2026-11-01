# Probe 2.1 — what `claude --resume` keeps of the launch flags

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 2.1.
Spec: §2.1 ("*Not measured* here: whether `--resume` keeps the model and
permission mode"), Appendix A's launch-flags row.

## Method

The rig of `tests/live/claude-background-smoke.sh`, copied into a probe
script outside the repository (the spec's rule: probe scripts are not
committed):

- a throwaway `-S` socket under `mktemp -d /tmp/amx.XXXX`, never `-L roost`;
- `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp directories, a fake
  API key and the project trust seeded in the throwaway `.claude.json`;
- a local stand-in for the Messages API that answers every request with one
  text block and logs, per request, the `model` field and the message count;
- `--setting-sources local --settings <file>` with this checkout's hooks
  (`roost hooks claude`) plus one extra `SessionStart` hook that writes
  `HOME` and `CLAUDE_CONFIG_DIR` from its own environment to a file;
- the real `~/.claude/settings.json` and `~/.codex/config.toml` hashed before
  and after, and the project keys of the real `~/.claude.json` listed before
  and after.

Claude Code 2.1.316, macOS, tmux 3.6. Each run once.

Claude runs in a bash pane (so the shell is there after `/exit`). Each run:
start, one prompt, `/exit`, then `claude --setting-sources local --settings
<file> --resume ID` with **no** `--model` and **no** `--permission-mode`, one
prompt. The model is read from the next request the fake API receives; the
mode from the footer on screen.

Three runs, because a resume that "kept" a value means nothing until the
value a flag-less start gets is known:

| run | start flags | model sent, first prompt | mode on screen at start | model sent after resume | mode on screen after resume |
|---|---|---|---|---|---|
| control | none | `claude-opus-5-5` | `⏵⏵ auto mode on` | `claude-opus-5-5` | `⏵⏵ auto mode on` |
| A | `--model haiku --permission-mode default` | `claude-haiku-5-5` | (no mode line: default) | `claude-haiku-5-5` | (no mode line: default) |
| B | `--model haiku --permission-mode plan` | `claude-sonnet-5-5` | `⏸ plan mode on` | `claude-sonnet-5-5` | `⏸ plan mode on` |

Raw excerpts (run A, then run B):

```
REQ model=claude-haiku-5-5 messages=2 plan_in_msgs=False path=/v1/messages?beta=true
== resume: claude --resume ID (no model, no mode flags)
▝▜██████▀  Haiku 5.5 · API Usage Billing
REQ model=claude-haiku-5-5 messages=5 plan_in_msgs=False path=/v1/messages?beta=true
```

```
▝▜██████▀  Haiku 5.5 · API Usage Billing
  ⏸ plan mode on (shift+tab to cycle) · ← for agents
REQ model=claude-sonnet-5-5 messages=2 plan_in_msgs=True path=/v1/messages?beta=true
== resume: claude --resume ID (no model, no mode flags)
  ⏸ plan mode on (shift+tab to cycle) · ← for agents
REQ model=claude-sonnet-5-5 messages=4 plan_in_msgs=True path=/v1/messages?beta=true
```

Run B's request model is `claude-sonnet-5-5` while the banner says Haiku 5.5:
this Claude sends plan-mode turns of a haiku session to a larger model. It
does so the same way before and after the resume, so it does not change the
answer. The message count grows after each resume (the old conversation is
carried).

## Result

**Both kept.** A flag-less `claude --resume ID` came back with the model and
the permission mode the session was started with, against a control whose
flag-less start gets Opus and auto mode.

Per the plan's table: **nothing to build**. The resume table's `claude
--resume ID` stays as it is, and the launch command stays a hint.

## The two extra reads (recorded only; nothing in the plan is built on them)

1. **`CLAUDE_CONFIG_DIR` in the `SessionStart` hook's environment.** Started
   with `CLAUDE_CONFIG_DIR=$D/cfg`, the hook's environment carried
   `CLAUDE_CONFIG_DIR=$D/cfg` (and `HOME`). Started without it, the hook saw
   no `CLAUDE_CONFIG_DIR`. So an identity hook could record it; today roost
   does not, and the store check reads the variable of the shell `revive`
   runs in.

   ```
   --- envdump (run WITH CLAUDE_CONFIG_DIR)
   HOME=$D/home
   CLAUDE_CONFIG_DIR=$D/cfg
   ```

2. **A live-session registry file per process.** Yes:
   `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json`, beside a
   `<pid>.<hex>.key` file. The JSON holds, among others, `pid`, `sessionId`,
   `cwd`, `procStart`, `kind` (`interactive`), `entrypoint` (`cli`), `tmux`
   (`<session>:@<window>.%<pane>` — the pane it runs in), `status` and
   `version`. Keys seen:

   ```
   asksForConvertedSkills cwd entrypoint kind messagingSocketPath name nameSince
   nameSource peerFeatures peerProtocol pid pidDomain procStart sessionId
   startedAt status statusUpdatedAt tmux updatedAt version
   ```

   - `/exit` **removes** both files.
   - `kill -9` **leaves** both files behind (the pid is then dead, so a
     reader would have to check the pid and `procStart`, as roost's owner
     rule does).
   - With `CLAUDE_CONFIG_DIR` set, the directory is `$CLAUDE_CONFIG_DIR/sessions/`.

   This is the only place found where roost could see the same conversation
   open outside roost (its `sessionId`, with a live `pid` whose start time is
   `procStart`). Not a contract: an undocumented file of 2.1.316.

## Guard lines

```
GUARD: settings.json and codex config.toml unchanged
GUARD: no project key added to ~/.claude.json
```

The same two lines closed each of the three runs.
