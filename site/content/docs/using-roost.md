---
title: Using roost
description: Sessions, windows, key bindings, and the at-a-glance status signals.
sidebar:
  order: 3
---

## Commands

```sh
roost             # start/attach the default session ("main")
roost session a   # start/attach a named session — as many as you like
roost session b   # a second workspace, sharing the same server
roost new api     # open a new agent window named "api" and attach
roost status      # list running sessions + agents and their states
roost kill a      # kill session "a" (omit the name to stop the whole server)
roost settings    # change theme/glyphs/separator/notifications, live
```

Detach with the prefix then `d`, like any tmux. Inside `roost`, run your agents as windows (`claude`, `codex`, `aider`, …) and the status bar shows one badged tab per agent — so you can see who is blocked at a glance.

## Sessions

**Sessions** all share one server, so the status counts and the `prefix a` switcher roll up across every session. `roost session a` and `roost session b` give you separate workspaces you attach and reattach independently, while still seeing the whole herd in one place.

## Window names

**Window names** auto-follow each agent's project (the basename of its working directory), so an agent in `~/work/api` shows up as `api`. Give a window an explicit name with `roost new NAME` or the rename key and it sticks.

## Keys

The prefix is **`Ctrl-s`** and the bindings mirror a typical GNU-Screen-style tmux config, so there is nothing new to learn:

| key | action |
|-----|--------|
| `prefix c` | new agent window |
| `prefix -` / `prefix _` | split stacked / side-by-side |
| `prefix h j k l` | move between panes |
| `prefix H J K L` | resize pane (repeatable) |
| `prefix > / <` | swap pane forward / back |
| `prefix C-c` | new session |
| `prefix a` | **agent switcher** — fzf popup of all agents + state + elapsed time |
| `prefix b` | **jump to the agent that needs you** (error, else blocked) |
| `prefix r` | reload roost config |
| `prefix S` | **settings** — change theme/glyphs/separator/notifications, live |

## At-a-glance signals

### Status bar counts

The top-right shows the whole herd rolled up, for example `💥1 🛑4 ⏳1 ✅3` (error / blocked / working / done), so you see the picture even when the window tabs scroll off.

Counts are ordered by how much they want your attention, and the glyphs are read back off the windows, so they can never disagree with the tabs.

### Desktop notification

When an agent you are *not* looking at becomes blocked, roost pings you. See [Notifications](/docs/setup) for backends and how to plug in your own.

### Elapsed time

The `prefix a` switcher shows how long each agent has been in its current state, so a stuck agent stands out. It is computed only when you open the switcher — nothing extra runs on the status tick.
