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

## You never choose a server

`roost` always talks to its own tmux server. You do **not** pass a socket, do
not use `-L` or `-S`, and do not try to work out which server you are on. Every
command below is complete as written.

If a command seems to target the wrong place, the answer is never a socket
flag — re-check the target id from `roost whoami` or `roost status`. Agents
that start reasoning about sockets go in circles; there is nothing there to
solve.

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
roost read "$helper" 40
```

`roost spawn NAME [CMD]` creates a window WITHOUT attaching and prints its
`%N`. Omit CMD to open a shell you can `roost send` into later. Spawned agents
are real and cost tokens — only spawn what you need.

## Message an agent

`roost send TARGET "text"` types the text and submits it reliably. Until roost
adds sender attribution, prefix who you are so the receiver can reply (as
above). Exit codes tell you WHAT to do next, so branch on `$?`:

- **exit 2** — the target itself is bad (doesn't exist, or its pane is dead).
  Re-resolve it: check `roost status` or the id you captured.
- **exit 1** — delivery to a valid target failed: either the text never
  reached the pane (typing itself failed, e.g. the pane died mid-send) or it
  was typed but never left the input line even after retrying extra Enters
  (a cold TUI swallowed the submit). Do NOT re-resolve the target — `roost
  send` the same target again, or `roost read` it to see what's stuck. A
  missing TARGET/TEXT argument also exits 1, but with a `usage:` message
  instead of a `roost send:` one — that's a caller bug, not a delivery
  failure; fix the call instead of retrying.
- **exit 0** — delivered and submitted. Nothing to do.

## Wait for the reply, then read it

```sh
roost wait-done "$helper" 120     # block until $helper is done/idle (120s timeout)
roost read "$helper" 40           # print its last 40 non-blank lines
```

## Helpers in your current window

`roost split` opens a pane beside you in your *own* window (not a new window) —
useful for a log tail, a build watcher, or a small worker you'll poll rather
than a full co-agent:

```sh
logs="$(roost split htop)"            # a helper pane beside you → its %N
roost send "$logs" "…" ; roost read "$logs"
```

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

## The coordination idiom

1. `roost whoami` — confirm you're in roost and learn your address.
2. `roost status` — find a target, or `roost spawn`/`roost split` a helper.
3. `roost send TARGET "[from <you>] <task>"`.
4. `roost wait-done TARGET [timeout]` — pane-precise on a `%N`, aggregates
   the window's agent panes otherwise. Exits 0 when done; exits 1 on error
   or timeout — check the message to know which.
5. `roost read TARGET` — collect the result.

Send **one** prompt at a time, then wait — don't fire a second before the first
completes. Don't message yourself. Don't spam.
