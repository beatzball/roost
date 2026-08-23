---
title: Getting Started
description: What roost is, what it needs, and how to install and launch it.
sidebar:
  order: 1
---

## What roost is

`roost` is an on-demand tmux **agent view** for wrangling multiple AI coding agents — without giving up your normal tmux setup or switching to a different terminal.

It runs on its **own isolated tmux server** with its own config, so your everyday `tmux` (config, sessions, plugins, muscle memory) is **never touched**. Launch it with one command, run your agents as panes or windows inside it, and each is badged with what its agent is doing:

> 💥 error / needs you · 🛑 blocked / needs you · ⏳ working · ✅ done · 💤 idle

State comes from **Claude Code's own lifecycle hooks** — not from scraping process names or terminal output — so it is accurate rather than guessed. No external plugins, no compiled binary, nothing that reaches into `~/.tmux.conf`.

## Requirements

- `tmux` ≥ 3.2 (needs pane options, `#{P:}` pane loops, and `display-popup`)
- `git`
- A powerline/Nerd Font for the tab separators — or run `roost init` and pick the plain-separator fallback
- Claude Code (for the state badges; the view itself works without it)
- Optional: `fzf` (for the `prefix a` agent switcher)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh
```

That clones roost to `~/.local/share/roost` and adds its `bin/` to your `PATH`.

It works out which startup file your shell actually reads, rather than assuming
zsh: `.zshrc` for zsh (honouring `ZDOTDIR`), `.bash_profile` or `.bashrc` for
bash depending on your platform, `config.fish` for fish. Re-running it will not
add the same line twice, and an unrecognised shell gets a line to paste rather
than a guess.

### Options

```sh
./install.sh --dir ~/tools/roost   # clone somewhere else
./install.sh --symlink             # symlink bin/roost into a PATH dir instead
./install.sh --symlink ~/bin       # ...or a specific one
./install.sh --dry-run             # print what it would do, change nothing
```

`--symlink` with no directory picks the first writable directory already on
your `PATH`. It checks rather than assuming: `/usr/local/bin` is the
traditional answer and is frequently root-owned.

### By hand

roost is just a script, so this is all the installer does:

```sh
git clone https://github.com/beatzball/roost.git roost
export PATH="$PWD/roost/bin:$PATH"   # add to your shell's startup file
```

The launcher resolves its own location (following symlinks), so it finds its
config and scripts no matter where you run it from.

## First run

```sh
roost doctor   # check tmux version, truecolor, fzf, notifier, hooks
roost init     # pick theme, glyph set, separator style; print the Claude hooks
roost          # start/attach the default session ("main")
```

Detach with the prefix then `d`, like any tmux. The prefix is `Ctrl-s`.

`roost help` prints the full command list, with the owl on top:

![The roost help output: an ASCII owl above the full command list](/roost-help.png)

Next: [Setup and settings](/docs/setup), then [Enable the state badges](/docs/state-badges).

## Prior art and credit

Watching agent state from inside tmux is a well-trodden idea; `roost` is a deliberately minimal, isolation-first take on it. If you want a richer, sidebar-style experience, these projects pioneered the approach and are worth your time:

- [hiroppy/tmux-agent-sidebar](https://github.com/hiroppy/tmux-agent-sidebar) — a live sidebar with prompts, tool calls, worktrees, subagent trees
- [accessd/tmux-agent-indicator](https://github.com/accessd/tmux-agent-indicator) — pane-border / title / status-icon signals
- [samleeney/tmux-agent-status](https://github.com/samleeney/tmux-agent-status) — sidebar + fzf target switcher
- [craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager) — a popup picker across running Claude sessions
- [flavio87/tap-to-tmux](https://github.com/flavio87/tap-to-tmux) — phone push when an agent needs you

`roost` trades their richness for staying completely out of your primary tmux and owning nothing but a few small shell files you can read end to end.
