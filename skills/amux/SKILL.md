---
name: amux
description: Coordinate AI agents running as windows inside an amux tmux session — discover peers, spawn helpers, send prompts, and collect replies. Use when you are running inside amux and need to drive or talk to another agent.
---

# Driving agents with amux

You are (possibly) an agent running inside **amux** — a tmux "agent view" where
each agent is a window. These commands let you coordinate with sibling agents.

## Preflight — are you inside amux?

Run `amux whoami`. If it prints a `session:index` (e.g. `main:2`), that is YOUR
address and you're inside amux. If it errors ("not inside an amux session"),
**stop** — you are not in amux; tell the user and do not run the rest.

## Discover the fleet

`amux status` lists every session and window with its state, e.g.:

```
    main:1 api/claude  [working]
    main:2 web/claude  [blocked]
```

The `session:index` (e.g. `main:2`) is the **target** for every command below.

## Spawn a helper agent (no focus stealing)

```sh
amux spawn reviewer claude    # new window running claude; prints its target, e.g. main:3
```

`amux spawn NAME [CMD]` creates a window WITHOUT attaching and prints its
`session:index`. Omit CMD to open a shell you can `amux send` into later.
Spawned agents are real and cost tokens — only spawn what you need.

## Message an agent

```sh
amux send main:3 "review the diff in ~/work/api and reply with issues"
```

`amux send TARGET "text"` types the text and submits it reliably. Until amux
adds sender attribution, prefix who you are so the receiver can reply:

```sh
me="$(amux whoami)"
amux send main:3 "[from $me] review the diff and reply with issues"
```

A bad target fails loudly (exit 2) — check the target from `amux status`.

## Wait for the reply, then read it

```sh
amux wait-done main:3 120     # block until main:3 is done/idle (120s timeout)
amux read main:3 40           # print its last 40 non-blank lines
```

## The coordination idiom

1. `amux whoami` — confirm you're in amux and learn your address.
2. `amux status` — find or choose a target (or `amux spawn` a helper).
3. `amux send TARGET "[from <you>] <task>"`.
4. `amux wait-done TARGET [timeout]`.
5. `amux read TARGET` — collect the result.

Send **one** prompt at a time, then wait — don't fire a second before the first
completes. Don't message yourself. Don't spam.
