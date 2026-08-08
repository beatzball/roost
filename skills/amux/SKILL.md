---
name: amux
description: Coordinate AI agents running as windows inside an amux tmux session — discover peers, spawn helpers, send prompts, and collect replies. Use when you are running inside amux and need to drive or talk to another agent.
---

# Driving agents with amux

You are (possibly) an agent running inside **amux** — a tmux "agent view" where
each agent is a window. These commands let you coordinate with sibling agents.

## Preflight — are you inside amux?

Run `amux whoami`. If it prints an id (e.g. `%7`), that is YOUR address and
you're inside amux. If it errors ("not inside an amux session"), **stop** —
you are not in amux; tell the user and do not run the rest.

## Discover the fleet

`amux status` lists every session and window with its state, e.g.:

```
    %3  main:1 api/claude  [working]
    %7  main:2 web/claude  [blocked]
```

## Targets are stable ids

`spawn`, `split`, and `whoami` each print a stable id (e.g. `%7`) for the
thing they just created or for you — capture it in a variable and use it for
every later command. Ids don't drift if windows get renamed or reordered.
Friendly `session:index` forms (e.g. `main:2`) or window names still work
too — handy when a human is typing the target — but prefer the captured id in
scripts.

## Spawn a co-agent (a new window, no focus stealing)

```sh
me="$(amux whoami)"
helper="$(amux spawn claude)"        # a co-agent in its own window → its %N
amux send "$helper" "[from $me] review the diff and reply with issues"
amux wait-done "$helper" 120
amux read "$helper" 40
```

`amux spawn NAME [CMD]` creates a window WITHOUT attaching and prints its
`%N`. Omit CMD to open a shell you can `amux send` into later. Spawned agents
are real and cost tokens — only spawn what you need.

## Message an agent

`amux send TARGET "text"` types the text and submits it reliably. Until amux
adds sender attribution, prefix who you are so the receiver can reply (as
above). A bad target fails loudly (exit 2) — check the target from
`amux status` or the id you captured.

## Wait for the reply, then read it

```sh
amux wait-done "$helper" 120     # block until $helper is done/idle (120s timeout)
amux read "$helper" 40           # print its last 40 non-blank lines
```

## Helpers in your current window

`amux split` opens a pane beside you in your *own* window (not a new window) —
useful for a log tail, a build watcher, or a small worker you'll poll rather
than a full co-agent:

```sh
logs="$(amux split htop)"            # a helper pane beside you → its %N
amux send "$logs" "…" ; amux read "$logs"
```

Compose layouts by splitting a specific pane with `-t`:

```sh
# agent full-left, a stack of helpers on the right:
r1="$(amux split -h claude)"          # right column
r2="$(amux split -v -t "$r1" claude)" # stacked below r1
```

**Boundary — `spawn` vs `split`:** `spawn` opens a *window* for a co-agent you
`wait-done` on independently. `split` opens a *pane* for a helper you
`send`/`read` — pane state is shared with its window, so `wait-done` on a
split pane is not per-pane (it reflects the whole window).

## The coordination idiom

1. `amux whoami` — confirm you're in amux and learn your address.
2. `amux status` — find a target, or `amux spawn`/`amux split` a helper.
3. `amux send TARGET "[from <you>] <task>"`.
4. `amux wait-done TARGET [timeout]` — window co-agents only.
5. `amux read TARGET` — collect the result.

Send **one** prompt at a time, then wait — don't fire a second before the first
completes. Don't message yourself. Don't spam.
