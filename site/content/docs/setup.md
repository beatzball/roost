---
title: Setup and Settings
description: Run the setup wizard, pick a theme and glyph set, and change settings live.
sidebar:
  order: 2
---

## The setup wizard

```sh
roost doctor   # check tmux version, truecolor, fzf, notifier, hooks
roost init     # pick theme, glyph set, separator style; print the Claude hooks
```

`roost init` writes `~/.config/roost/roost.conf` and is safe to re-run (it backs up the previous file). Reload a running roost with `prefix + r`.

## Themes

`roost`, `catppuccin-mocha`, `catppuccin-latte`, `tokyonight-storm`, `tokyonight-day`, `gruvbox`, `nord`, `rose-pine`.

Pick one in `roost init`, or set `@roost-color-*` options by hand in `~/.config/roost/roost.conf`.

## Changing settings later

`roost settings` opens an fzf menu to change the **theme**, **glyph set**, **separator**, and **notifications** — one at a time. Each pick applies live to the running server (no restart) and is saved to `~/.config/roost/roost.conf`. Inside roost, press **`prefix S`** (`Ctrl-s S`) to open it right where you are.

Unlike `roost init` (which regenerates the whole config), `roost settings` edits just the one line it changes, leaving any hand-added config untouched.

The **theme**, **glyph**, and **separator** pickers preview live: as you move through the list the bar updates on the running server, **Enter** commits the choice, and **Esc** reverts to what you had. The currently-saved option is marked with a `✓`.

## Notifications

When an agent you are *not* looking at becomes blocked (needs input), roost pings you with a native desktop notification. Only `blocked` notifies — `done` fires every turn and would be noise. `error` notifies too: an agent that has stopped making progress needs you just as much as one waiting for an answer.

Delivery is cross-platform, tried in this order:

1. macOS (`osascript`)
2. WSL (`BurntToast` via `powershell.exe`)
3. Linux (`notify-send`, when a display is present)
4. Fallback: an in-tmux `display-message` if nothing else is available (for example a headless remote session with no OS notifier reachable)

Set `@roost-notify-backend` to `tmux` to always use the in-tmux message, or `none` to disable notifications entirely. The default is `auto`.

### Your own notifier

For full control, set `@roost-notify-cmd` to your own command. `%t` is replaced with the title and `%s` with the message:

```sh
set -g @roost-notify-cmd 'notify-send "%t" "%s"'
```

Reference the placeholders double-quoted (`"%s"`) or bare — **never single-quoted**, since `%t` / `%s` are wired to shell positional parameters (`$1` / `$2`) before your command runs, and single quotes would suppress that substitution.

Because the swap is textual, avoid combining the placeholders with a command that needs a *literal* `%t` or `%s` of its own (for example `date +%s`) — the two would collide.
