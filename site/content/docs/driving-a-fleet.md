---
title: Driving a Fleet
description: Script your agents with send, read and wait-done — from your shell, from inside roost, or over ssh.
sidebar:
  order: 4
---

## From your shell

roost exposes tmux's scripting as small agent-shaped commands, so you (or a script, or one agent) can drive the others:

```sh
roost send api "run the tests"   # type a prompt + Enter into the "api" agent
roost read api 20                # print that agent's last 20 non-blank lines
roost wait-done api              # block until "api" is done/idle
roost wait-done api 300          # ...with a 5-minute timeout
```

Targets are `[SESSION:]WINDOW` — a bare name (`api`) resolves against the default `main` session; qualify it (`roost send b:api …`, or by index `b:2`) to reach an agent in another session.

Combine them to orchestrate parallel work:

```sh
for w in api web worker; do roost send "$w" "update the changelog"; done
for w in api web worker; do roost wait-done "$w"; done
echo "all three agents finished"
```

## From inside roost

An agent (or you) can coordinate the fleet from inside roost. Targets are stable ids (for example `%12`) captured from `spawn` / `split` / `whoami` — capture them in a variable and reuse them. Friendly `session:index` and name forms still work too.

- `roost whoami` — this agent's own target (its `%N`)
- `roost spawn NAME [cmd]` — open a co-agent **window** without attaching; prints its `%N`
- `roost split [-h|-v] [-t P] [-n NAME] [cmd]` — a helper **pane** in your current window (prints its `%N`); compose layouts by splitting a specific pane, `-n NAME` labels it (border, tab, switcher) instead of showing the raw process name
- `roost send TARGET "…"` — reliably type a prompt into an agent and submit it
- `roost wait-done TARGET` / `roost read TARGET` — wait for it to finish, then read the reply

`spawn` (window) is for a co-agent you `wait-done` on independently. `split` (pane) is for a helper you `send` / `read` in-place — a pane's state is shared with its window, so `wait-done` on it is not per-pane.

### Exit codes for `roost send`

`roost send` verifies its own submit rather than trusting a fire-and-forget `send-keys`, and its exit code says what went wrong:

| exit | meaning | what to do |
|------|---------|------------|
| `2` | the target is unusable — it does not exist, or its pane is dead | re-resolve the target |
| `1` (`roost send:` message) | delivery to a valid target failed — the text never reached the pane, or it was typed but never left the input line even after retrying extra Enters | retry the same target or inspect the pane; do **not** re-resolve |
| `1` (`usage:` message) | a missing argument | caller bug, not a delivery failure |

### `roost wait-done` and errors

`wait-done` does not treat "stopped being busy" as success. An errored pane makes it print `roost: '<target>' is in error state, not done` and exit 1.

If you script against it: a non-zero exit means *error or timeout*, distinguished by the message. A `set -e` script will stop on a dead agent rather than continuing.

## The agent skill

For LLM agents, install the portable skill so they know the loop:

```sh
npx skills add beatzball/roost --skill roost
```

Or copy `skills/roost/SKILL.md` into your agent's instructions.

## Remote agents

Run agents on another machine and drive them from here — tmux-native, no daemon. roost must be installed on the remote:

```sh
roost ssh devbox         # ssh -t devbox roost  → attach the remote agent view
roost ssh devbox new api # forward any subcommand to the remote roost
```
