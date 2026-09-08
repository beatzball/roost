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

`roost read` is not a screenshot. Each agent records its last message onto its own pane as the turn ends — the Claude Code hook, the opencode plugin and the GitHub Copilot CLI extension all do this — and `read` returns that recording, whole. No line count is needed, and none is applied.

This matters because a full-screen agent draws furniture. The bottom of a Claude Code, opencode or copilot pane is an input box and status bars, so scraping the last few lines returns those, not the answer. A copilot pane is the starkest case: it draws on the alternate screen, so its last visible lines are a box outline and the footer `← open sidebar · / commands · ? help · tab next tab`, with the agent's answer scrolled out of reach above.

When nothing has been recorded, `read` falls back to scraping the screen and **says so on stderr**:

```
roost read: no recorded reply for 'api' — showing the pane's screen instead.
```

The notice goes to stderr, so `roost read api | grep …` and loops over several agents stay clean. Three things cause it:

- **The target is not an agent** — a shell, a log tail, a pager. Nothing is wrong; use `roost screen` for those.
- **The target is an agent that cannot record.** Its harness has no roost adapter, or its Claude `Stop` hook predates this feature. Run `roost doctor` on that machine — it names the exact fix.
- **The target answered only through a subagent.** A subagent's output is never published as the pane's reply — it was not addressed to the caller — so a turn that delegated and then said nothing itself records nothing.

Never treat a fallback result as an agent's answer. If the notice appeared, the reply was not collected.

### Render the markdown: `roost read --render`

Agents answer in markdown. `roost read` prints it raw, because that is what a
script wants. Add `--render` (or `-r`) when a **person** is reading it, and the
text is piped through [preen](https://github.com/beatzball/preen) instead:

```sh
roost read --render api
roost read -r %12
roost read -r api 20        # the line count still describes the screen
```

The flag goes in front of the target, and **only** in front of it. A flag in
the line-count slot is refused with a usage line rather than quietly read as a
number — `roost read api --render` used to print unrendered text at exit 0 and
say nothing.

It is opt-in and changes nothing else: plain `roost read` still emits the reply
byte for byte, so existing pipelines and `grep`s are unaffected.

**A screen fallback is never rendered.** A recorded reply is markdown because
an agent wrote it; a pane's screen is terminal output, and a markdown renderer
deletes the characters in it that look like syntax — `<ttyUSB0>` disappears,
`2*3*4` becomes `234`, `_low_` becomes `low`. Losing bytes out of the one
output you read to work out what a pane is doing is worse than not colouring
it, so the screen goes through untouched and `--render` says why on stderr.

Neither a missing nor a failing `preen` costs you the text. In both cases the
raw text is printed, the reason goes to stderr, and the exit status is still
zero — the reply is the payload, the rendering is a convenience.
### A reply is never served as fresher than it is

A recorded reply stays on the pane until the next turn replaces it, which is
deliberate — clearing it at the start of a turn would throw away an answer you
were merely slow to collect. So `roost read` says on stderr when what it is
handing you is not current:

- the pane is **working** or **blocked** — the turn this reply would belong to
  has not finished, so the reply is from an earlier one;
- the pane is **errored** — that turn failed and published no answer at all, so
  again the reply predates it.

A turn that finishes having said nothing — it ended on a tool call, or was
interrupted — clears the reply instead, so `roost read` gives you the
self-announcing screen fallback rather than the previous turn's answer wearing
this turn's badge.

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
| `1` (`roost send:` message) | delivery to a valid target failed — the text never reached the pane, could not be confirmed to have reached it, or was delivered but never left the input line even after retrying extra Enters | retry the same target, or `roost screen` it to see what is stuck; do **not** re-resolve |
| `1` (`usage:` message) | a missing argument | caller bug, not a delivery failure |

### Long messages, and why they used to arrive with the front missing

`roost send` delivers your message as a **bracketed paste**, not as typing.

That distinction is the whole reason long messages work. Typed at speed, an
agent's input box could keep only the last chunk of a big message and throw the
front away — measured against Claude Code 2.1.263, a 3502-byte briefing arrived
as its last 436 bytes, with no error and exit 0. The receiving agent answered a
message whose first three thousand bytes it had never seen.

A bracketed paste tells the application "this is one block of pasted text",
which is a different code path in the agent, and the same bytes then arrive
whole. If you have been writing briefings to a file and sending the path
instead, you no longer need to.

Two consequences worth knowing:

- **There is no practical length limit any more.** The old ceiling was about
  16 KB, and it came from the message travelling on a tmux command line; it now
  travels over standard input. A 20 KB message is delivered whole.
- **The pane may show `[Pasted text #1]` instead of your text.** That is the
  agent's rendering of a paste, not a truncation. The full message is submitted.

`roost send` also confirms the message actually reached the pane before it
presses Enter, and retries if it did not — a pane that is still booting can
discard input, which is the other way a briefing used to vanish. If it cannot
confirm delivery it **submits nothing** and exits 1, so a caller in a loop
retries instead of moving on. It gives up after 15 seconds by default:

```sh
tmux -L roost set-option -g @roost-send-ready-timeout 30
```

### Privacy: what a send leaves behind

The message passes through one tmux buffer on the way to the pane, and roost is
deliberate about it:

- **One buffer, reused** (`roost-send`), so sends never pile up.
- **Deleted as it is pasted**, and deleted again on every failure path — a send
  whose pane dies mid-flight leaves nothing in the buffer list.
- **Never copied to your system clipboard.** The tmux flag that would do that
  (`-w`) is never passed.

You can check the first two yourself with `prefix + =`, which lists tmux's
buffers: a send should add nothing to it.

### Why a blocked target is refused

`send` pastes your text, waits a beat, then presses Enter. If a permission
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
