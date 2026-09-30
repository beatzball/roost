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
| `prefix a` | **agent switcher** — fzf popup of all agents + state + elapsed time, with a live preview (see [below](#the-agent-switcher)) |
| `prefix b` | **go to the most urgent agent** (error, else blocked) |
| `prefix r` | reload roost config |
| `prefix S` | **settings** — change theme/glyphs/separator/notifications, live |

## At-a-glance signals

### Status bar counts

The top-right shows the whole herd rolled up, for example `💥1 🛑4 ⏳1 ✅3` (error / blocked / working / done), so you see the picture even when the window tabs scroll off.

Counts are ordered by how much they want your attention, and the glyphs are read back off the windows, so they can never disagree with the tabs.

### Desktop notification

When an agent you are *not* looking at becomes blocked, roost pings you. See [Notifications](/docs/setup) for backends and how to plug in your own.

### Elapsed time

The `prefix a` switcher shows how long each agent has been in its current state, so a stuck agent stands out. It is computed only while the switcher is open — nothing extra runs on the status tick.

### The agent switcher

`prefix a` opens a popup that lists every pane on the server, grouped by session and window. Each agent's state is coloured: red is blocked, magenta is error, yellow is working, green is done.

- **It stays current.** The list reloads every two seconds while it is open, so a badge that changes shows up without reopening it.
- **It shows the screen.** The right-hand side is the screen of the row under the cursor, so you can read what a blocked agent is asking before you jump to it. In a narrow terminal the preview moves below the list.
- **Type to search**, as before. `Enter` jumps to the row; `Esc` closes the popup.

| Key | Does |
|-----|------|
| `Ctrl-f` | step the state filter: all → needs you (blocked or error) → working → done |
| `Ctrl-o` | show agents only, hiding plain shells; again to show them |

The line above the list names the filter in force.

The cursor keeps its *position* across a reload, not its row. If a pane opens or closes above it, the cursor is on a neighbouring row afterwards — the preview always shows where `Enter` will land.

Set `NO_COLOR` to turn the colours off. The reload, the preview and the two keys need a reasonably recent fzf — they are tested on 0.44 and 0.74. With an fzf too old for them the switcher is a plain list, and `roost doctor` says so.
