---
title: Driving a Fleet
description: Script your agents with send, read, screen and wait-done — from your shell, from inside roost, or over ssh.
sidebar:
  order: 4
---

## From your shell

roost exposes tmux's scripting as small agent-shaped commands, so you (or a script, or one agent) can drive the others:

```sh
roost send api "run the tests"   # type a prompt + Enter into the "api" agent
roost read api                   # print the reply that agent just gave
roost screen api 20              # print what is ON its screen: last 20 non-blank lines
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
- `roost send TARGET "…"` — reliably type a prompt into an agent and submit it (refuses a 🛑 blocked target; see below)
- `roost wait-done TARGET` / `roost read TARGET` — wait for it to finish, then read the reply
- `roost screen TARGET` — what is on that pane's screen, chrome and all
- `roost reply "…"` — record what *you* just said, so another agent's `read` gets it

`spawn` (window) is for a co-agent you `wait-done` on independently. `split` (pane) is for a helper you `send` / `read` in-place. State is **per-pane**, so `wait-done %N` waits on that one pane whichever way it was created; give it a window target instead and it waits for every agent pane in that window.

## `read` returns the reply, not the screen

`roost read` is not a screenshot. Each agent records its last message onto its own pane as the turn ends — the Claude Code hook and the opencode plugin both do this — and `read` returns that recording, whole. No line count is needed, and none is applied.

This matters because a full-screen agent draws furniture. The bottom of a Claude Code or opencode pane is an input box and status bars, so scraping the last few lines returns those, not the answer.

When nothing has been recorded, `read` falls back to scraping the screen and **says so on stderr**:

```
roost read: no recorded reply for 'api' — showing the pane's screen instead.
```

The notice goes to stderr, so `roost read api | grep …` and loops over several agents stay clean. Two things cause it:

- **The target is not an agent** — a shell, a log tail, a pager. Nothing is wrong; use `roost screen` for those.
- **The target is an agent that cannot record.** Its harness has no roost adapter, or its Claude `Stop` hook predates this feature. Run `roost doctor` on that machine — it names the exact fix.
- **The target answered only through a subagent.** A subagent's output is never published as the pane's reply — it was not addressed to the caller — so a turn that delegated and then said nothing itself records nothing.

Never treat a fallback result as an agent's answer. If the notice appeared, the reply was not collected.

### Agents with no adapter

An agent whose harness roost has no plugin for can still take part, the same way it can badge itself with `roost state`:

```sh
roost reply "the tests pass; two lint warnings in src/api.ts"
roost state done
```

Record the reply **before** reporting `done`. `wait-done` returns the moment the badge stops being `working`, so the other order leaves a gap in which a reader gets a screen scrape instead of the answer.

A reply longer than 12 KB is stored truncated, keeping the beginning, with a marker line saying how much was dropped.

### Exit codes for `roost send`

`roost send` verifies its own submit rather than trusting a fire-and-forget `send-keys`, and its exit code says what went wrong:

| exit | meaning | what to do |
|------|---------|------------|
| `3` | the target is 🛑 **blocked** — a permission dialog is open | wait and retry the **same** target, or pass `--force` |
| `2` | the target is unusable — it does not exist, or its pane is dead | re-resolve the target |
| `1` (`roost send:` message) | delivery to a valid target failed — the text never reached the pane, or it was typed but never left the input line even after retrying extra Enters | retry the same target, or `roost screen` it to see what is stuck; do **not** re-resolve |
| `1` (`usage:` message) | a missing argument | caller bug, not a delivery failure |

### Why a blocked target is refused

`send` types your text, waits a beat, then presses Enter. If a permission
dialog is open at that moment, the text goes **into the dialog** and the Enter
activates whatever option is highlighted. One agent driving another could
therefore answer a prompt that existed to ask *you* — silently, because the
dialog swallows the text and the submit verification is satisfied.

So `send` refuses when the target's badge is 🛑 `blocked`. That is not screen
scraping: the agent reports its own state through a hook, so the signal is
exact.

```sh
roost send api "run the tests"          # exits 3 if api is blocked
roost send --force api "run the tests"  # send anyway
```

`--force` must come **before** the target. Anywhere later it would be
indistinguishable from a message that happens to start with that word.

In a loop, exit 3 is the one code worth retrying on:

```sh
while :; do
  roost send api "run the tests" && break
  rc=$?
  [ "$rc" -eq 3 ] || exit "$rc"   # 1 and 2 will not fix themselves
  sleep 10                        # blocked: wait for the human, then retry
done
```

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
