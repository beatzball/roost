---
name: roost
description: Coordinate AI agents running as panes inside a roost tmux session — discover peers, spawn helpers, send prompts, and collect replies. Use when you are running inside roost and need to drive or talk to another agent.
---

# Driving agents with roost

You are (possibly) an agent running inside **roost** — a tmux "agent view" where
each agent is a pane. These commands let you coordinate with sibling agents.

## Preflight — are you inside roost?

Run `roost whoami`. If it prints an id (e.g. `%7`), that is YOUR address and
you're inside roost. If it errors ("not inside a roost session"), **stop** —
you are not in roost; tell the user and do not run the rest.

## Coordinating agents: you never choose a server

Every `roost` command in this skill already targets the right server. `roost`
talks to its own, and finds it without help. Do not add a socket argument to
these commands and do not try to work out which server you are on — every
command below is complete as written.

If one seems to target the wrong place, the answer is never a socket flag: the
id is stale. Re-check it with `roost whoami` or `roost status`.

**This applies to driving agents, not to everything you might do with tmux.**
Writing or running the project's own tests is the opposite case: those must
always name an isolated socket, because a bare `tmux` command targets the
*default* server — the user's ordinary tmux, which this tool exists to leave
alone. See `AGENTS.md`; in particular, never run `tmux kill-server` without
`-S` or `-L` naming a throwaway socket.

## Discover the fleet

`roost status` lists every session and pane with its state, e.g.:

```
    %3  main:1.1 api/claude  [working]
    %7  main:2.1 web/claude  [blocked]
```

## Targets are stable ids

`spawn`, `split`, and `whoami` each print a stable id (e.g. `%7`) for the
thing they just created or for you — capture it in a variable and use it for
every later command. Ids don't drift if windows get renamed or reordered.
Friendly `session:index` forms (e.g. `main:2`) or window names still work
too — handy when a human is typing the target — but prefer the captured id in
scripts.

State is per-pane. A pane opened with `roost split` is a real agent: it has its
own badge, appears in the switcher, and is addressable by its `%N` for `send`,
`read`, and `wait-done`. `roost wait-done %N` waits on that one pane; giving it a
window target instead waits for **every** agent pane in that window.

A pane counts as an agent only once a hook has stamped it. A helper pane running
a shell command, a log tail, or a pager is not an agent and never shows a state.

## Spawn a co-agent (a new window, no focus stealing)

```sh
me="$(roost whoami)"
helper="$(roost spawn claude)"        # a co-agent in its own window → its %N
roost send "$helper" "[from $me] review the diff and reply with issues"
roost wait-done "$helper" 120
roost read "$helper"                  # its actual reply
```

`roost spawn NAME [CMD]` creates a window WITHOUT attaching and prints its
`%N`. Omit CMD to open a shell you can `roost send` into later. Spawned agents
are real and cost tokens — only spawn what you need.

## Message an agent

`roost send TARGET "text"` types the text and submits it reliably. Until roost
adds sender attribution, prefix who you are so the receiver can reply (as
above). Exit codes tell you WHAT to do next, so branch on `$?`:

- **exit 3** — the target's badge says BLOCKED: a permission dialog is open on
  it. Your text would be typed into that dialog and the Enter would activate
  whatever option is highlighted, so you would be answering a prompt meant for
  the human. Do NOT re-resolve and do NOT force. Sleep and retry the SAME
  target until a human answers it. `roost send --force TARGET "text"` overrides
  the refusal, and you should not use it unless the human asked you to.

  **Do not retry forever.** The badge can be stale: a Claude Code turn that
  ended *at* a dialog — declined, or interrupted — leaves 🛑 stamped with
  nothing to clear it, so the target never becomes sendable on its own. After
  a few retries, run `roost screen TARGET 20`. If no dialog is on the screen,
  the badge is stale — **tell the human and stop**, rather than looping or
  forcing on your own initiative. Do not use `roost wait-done` to wait out an
  exit 3: it counts `blocked` as busy, so it just burns its timeout.
- **exit 2** — the target itself is bad (doesn't exist, or its pane is dead).
  Re-resolve it: check `roost status` or the id you captured.
- **exit 1** — delivery to a valid target failed: either the text never
  reached the pane (typing itself failed, e.g. the pane died mid-send) or it
  was typed but never left the input line even after retrying extra Enters
  (a cold TUI swallowed the submit). Do NOT re-resolve the target — `roost
  send` the same target again, or `roost screen` it to see what's stuck
  (`screen`, not `read`: a stuck pane's problem is on its screen, and its
  last recorded reply is from whatever turn finished before it got stuck). A
  missing TARGET/TEXT argument also exits 1, but with a `usage:` message
  instead of a `roost send:` one — that's a caller bug, not a delivery
  failure; fix the call instead of retrying.
- **exit 0** — delivered and submitted. Nothing to do.

## Wait for the reply, then read it

```sh
roost wait-done "$helper" 120     # block until $helper is done/idle (120s timeout)
roost read "$helper"              # print the reply it just gave
```

`roost read` returns **what the agent said**, not a screenshot of its terminal.
Each agent records its last message on its own pane as the turn ends, and `read`
returns that recording whole — so no line count is needed and none is applied.

When there is no recorded reply, `read` falls back to scraping the pane's screen
and **says so on stderr**. Two things cause that, and they need different
responses:

- **The target is not an agent** — a shell, a log tail, a pager. Nothing is
  wrong; a screen scrape is all such a pane has. Use `roost screen` and stop
  expecting a reply.
- **The target is an agent whose harness has no roost adapter**, or whose Stop
  hook was wired before the reply channel existed. Its human should run `roost
  doctor`, which names the fix. You will get TUI furniture — an input box and
  status bars — not the answer, so do not treat what comes back as its reply.
- **The target answered only through a subagent** and wrote nothing itself. A
  subagent's output is deliberately never published as the pane's reply — it
  was not addressed to you. Ask the agent to summarise its own result.

Never quote a fallback result as an agent's answer. If the notice appeared, you
do not have the reply; say so rather than reading meaning into box-drawing
characters.

```sh
roost screen "$helper" 40         # what is ON its screen: last 40 non-blank lines
```

`roost screen` is the honest name for the old behaviour. Use it to see what a
pane is *showing* — which is what you want when an agent looks stuck, and what
you want for any pane that is not an agent.

## Helpers in your current window

`roost split` opens a pane beside you in your *own* window (not a new window) —
useful for a log tail, a build watcher, or a small worker you'll poll rather
than a full co-agent:

```sh
logs="$(roost split htop)"            # a helper pane beside you → its %N
roost send "$logs" "…" ; roost screen "$logs"
```

`screen`, not `read`, for a shell helper: it has no reply channel to record
into, so `read` would fall back to the same scrape and add a notice each time.

Compose layouts by splitting a specific pane with `-t`:

```sh
# agent full-left, a stack of helpers on the right:
r1="$(roost split -h claude)"          # right column
r2="$(roost split -v -t "$r1" claude)" # stacked below r1
```

Both `spawn` and `split -n NAME` can name a pane. The name is what shows on
its border, its tab, and its switcher row — instead of the raw process name
(which for some agents is just a version string). Useful once several
helpers share one window and "claude" no longer tells them apart:

```sh
r1="$(roost split -h -n reviewer claude)"
r2="$(roost split -v -t "$r1" -n tests 'npm test -- --watch')"
```

**Boundary — `spawn` vs `split`:** `spawn` opens a *window* for a co-agent,
with its own tab and badge. `split` opens a *pane* beside you, in your
current window. Both are real agents: each has its own state, its own
border badge, and is addressable by `%N` — including `wait-done %N`, which
waits on that one pane whether it came from `spawn` or `split`.

## Reporting your own state

If you are an agent running in a roost pane and your harness has no adapter,
you can badge yourself:

```sh
roost state working    # or: blocked, done, error, idle
```

Report `working` when you start a task, `blocked` when you need the human,
`error` if you cannot continue, and `done` when you finish. Outside a roost
pane the command does nothing, so it is always safe to call.

## Posting your own reply

The other half of the same story. If your harness has no adapter, record what
you just said so a sibling's `roost read` returns it instead of your terminal:

```sh
roost reply "the tests pass; two lint warnings in src/api.ts"
roost state done                # reply FIRST, then done — see below
```

Record the reply **before** you report `done`. `roost wait-done` returns the
instant your badge stops being `working`, so a coordinator can read you in the
gap between the two commands and get a screen scrape instead of your answer.

Like `roost state`, this does nothing outside a roost pane, so it is always safe
to call. Agents running under Claude Code, opencode or GitHub Copilot CLI with
the roost adapter installed do not need it — their adapter already does this
every turn.

If you are on one of those three and unsure whether the adapter is actually
installed, calling `roost reply` anyway is the safe move: the adapter overwrites
your recording at the end of the turn, so the worst case is one wasted command,
and the worst case of NOT calling it is a coordinator reading your input box
instead of your answer.

## The coordination idiom

1. `roost whoami` — confirm you're in roost and learn your address.
2. `roost status` — find a target, or `roost spawn`/`roost split` a helper.
3. `roost send TARGET "[from <you>] <task>"`.
4. `roost wait-done TARGET [timeout]` — pane-precise on a `%N`, aggregates
   the window's agent panes otherwise. Exits 0 when done; exits 1 on error
   or timeout — check the message to know which.
5. `roost read TARGET` — collect the result. If it warns that it fell back to
   the screen, you did **not** get a reply; report that rather than guessing at
   what came back.

Send **one** prompt at a time, then wait — don't fire a second before the first
completes. Don't message yourself. Don't spam.
