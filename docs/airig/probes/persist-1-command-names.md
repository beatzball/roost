# Probe 1.6 — what `#{pane_current_command}` reads for pi, copilot and opencode

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.6.
Date: 2026-10-27. This Mac, tmux 3.6. Run count: twice per harness (the
first run's "is the tool's command running" detector was wrong; see Method).

## Method

One throwaway `-S` server (socket in a temp directory ending in `/roost`,
`tmux/roost.conf` sourced, `@roost-home` this checkout), the way
`tests/live/pi-smoke.sh` and `tests/live/copilot-smoke.sh` build theirs. Each
harness ran in its own window with every home redirected: `HOME`,
`XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `ROOST_SHAPE_DIR`, `CLAUDE_SETTINGS`,
`CODEX_HOME`, `PI_CODING_AGENT_DIR` and `COPILOT_HOME` all under the temp
directory.

- **pi 0.81.1**: `PI_CODING_AGENT_DIR` holding one ollama provider and the
  roost extension (symlink), `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`.
- **copilot 1.0.103**: BYOK (`COPILOT_PROVIDER_BASE_URL` at the local
  ollama), `COPILOT_OFFLINE=true`, `COPILOT_HOME` with the roost extension
  and the `EXTENSIONS` flag; its trust and extension dialogs and one tool
  permission dialog answered with the first (this-session-only) choice.
- Model: `ornith-1.5:9b` on the local ollama (the smokes' default
  `granite4.2:3b` is not pulled on this machine; the probe needs only a tool
  call, not a good answer).

Reads: 3 at the prompt, then one every ~0.5 s from the prompt's Enter until
the pane's `@agent_state` read `done`, then 3 more. Each read is
`#{pane_current_command}`, `@agent_state`, and whether the tool's command is
running. The prompt asked for one bash tool call running `sleep 7.25`; the
detector is `ps -axo command=` matching `sleep 7.25` anywhere. (Run 1 used
`sleep 5` and looked only on the pane's tty; it never saw the sleep although
both harnesses ran it — their tool shells are not on the pane's terminal —
so run 1 proves the prompt and turn reads only, and run 2 the tool-call
reads.)

## Result

| harness | at the prompt | mid-turn (`working`) | while the tool's `sleep` runs | after (`done`) | reads |
|---|---|---|---|---|---|
| pi 0.81.1 | `node` ×3 | `node` every read | `node` (6 reads with the sleep alive) | `node` ×3 | run 1: 33, run 2: 14 |
| copilot 1.0.103 | `copilot` ×3 | `copilot` every read | `copilot` (11 reads with the sleep alive) | `copilot` ×3 | run 1: 66, run 2: 128 |
| opencode | **not measured** | | | | |

Excerpt, run 2 (the reads with the tool's `sleep` alive):

```
=== pi 0.81.1
  turn read=1 cmd=node state=working sleep7.25=1
  turn read=1 cmd=node state=done sleep7.25=1
=== copilot 1.0.103
  turn read=1 cmd=copilot state=working sleep7.25=1
  ... (11 such lines, every one cmd=copilot)
```

(In run 2 pi's model started the sleep in the background and ended its turn,
so five of its six sleep-alive reads are at `done`; run 1's 26 `working`
reads spanned a foreground 5 s sleep pi reported as "Took 5.0s".)

No read on either harness was a shell name (`sh`, `bash`, `zsh`, `fish`,
`dash`) or another harness's.

**opencode: not measured.** opencode 2.x cannot run beside the user's own
background service on this machine (§2.5), and this probe does not stop it.

## Outcome

- **copilot reads `copilot`**: a stable name, not a shell, not another
  harness's, and **distinctive**. Task 1.9 adds `copilot` to
  `roost_close_harness`'s `case` as copilot's command.
- **pi reads `node`**: stable and not a shell, but **not distinctive** — any
  Node program reads `node`, and two harnesses could. Task 1.9 does not add
  it; pi stays on presence alone, as §3.2 allows.
- **opencode is not measured**: presence alone, as §3.2 says until measured;
  Task 1.16's known-gaps entry says so.
