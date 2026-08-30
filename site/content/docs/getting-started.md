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

State comes from **each agent's own lifecycle events** — Claude Code hooks, the opencode plugin, the GitHub Copilot CLI extension, or one `roost state` call from anything else — not from scraping process names or terminal output, so it is accurate rather than guessed. No compiled binary, nothing that reaches into `~/.tmux.conf`.

## Requirements

- `tmux` ≥ 3.2 (needs pane options, `#{P:}` pane loops, and `display-popup`)
- `git`
- A powerline/Nerd Font for the tab separators — or run `roost init` and pick the plain-separator fallback
- An agent that can report its state, for the badges — Claude Code, opencode, GitHub Copilot CLI, pi and OpenAI Codex CLI all have adapters in this repo, and the installer wires whichever of them you have; anything else calls `roost state`. The view itself works without any of them
- Optional: `fzf` (for the `prefix a` agent switcher)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh
```

That does two things, and it is worth ten seconds to know which is which,
because **two different things here are called "install"**.

**1. It places roost.** Clones it to `~/.local/share/roost` and adds its `bin/`
to your `PATH`. It works out which startup file your shell actually reads,
rather than assuming zsh: `.zshrc` for zsh (honouring `ZDOTDIR`),
`.bash_profile` or `.bashrc` for bash depending on your platform,
`config.fish` for fish. Re-running it will not add the same line twice, and an
unrecognised shell gets a line to paste rather than a guess.

**2. It wires your agents**, in the same step, by running `roost install` for
you. That is the part that makes the badges work: until a harness has roost's
adapter, its pane is never badged and roost looks broken. It touches only
harnesses you already have, and only their own agent config — one symlink each
for opencode, pi and copilot, roost's hooks merged into Claude's and codex's
settings, and copilot's `EXTENSIONS` flag turned on.

Piped from `curl` it cannot stop to ask you: stdin is the script itself, so a
prompt there would eat the rest of the script. So it prints a block naming
exactly what it will write, says that every file it edits is backed up beside
itself as `<name>.roost-bak-<timestamp>`, and tells you how to skip it — then
goes ahead. Run from a clone in a terminal, it asks first, and only you know
what you answered.

### Options

```sh
./install.sh --dir ~/tools/roost   # clone somewhere else
./install.sh --symlink             # symlink bin/roost into a PATH dir instead
./install.sh --symlink ~/bin       # ...or a specific one
./install.sh --no-wire             # place roost, wire nothing
./install.sh --dry-run             # print what it would do, change nothing
```

`--symlink` with no directory picks the first writable directory already on
your `PATH`. It checks rather than assuming: `/usr/local/bin` is the
traditional answer and is frequently root-owned.

`--no-wire` stops after the `PATH` line. Run `roost install` yourself whenever
you want the second half.

### `roost install` — the other one, for later

`roost install` is that second half on its own, and it is the command to reach
for after the first day:

```sh
roost install    # wire every installed harness to this checkout
roost update     # the same thing — a real alias, not a second command
```

**Neither of them fetches new roost code.** They re-wire the checkout you
already have to whatever is installed on the machine *now*. Run either one
when you:

- install a harness roost had not seen when you first ran it
- move, re-clone, or switch to a different roost checkout
- take a roost release that adds a new adapter

It is safe to run again and again. Hooks you already have are kept and roost's
join them — a `PostToolUse` formatter of your own survives — and a second run
adds no duplicates. Anything sitting at an adapter path that is not roost's is
left exactly as it was found and named in the output, with the command to
replace it yourself if that is what you want. Every file it edits is backed up
beside itself first.

```sh
roost install --dry-run     # print the plan and change nothing
roost install --only pi     # one harness (opencode, pi, copilot, claude, codex)
roost install --print-only  # never edit JSON — print the blocks to paste
roost install --help        # the rest of the flags
```

**Two steps are left for you, and no tool can do either** — both are prompts
somebody has to answer. `roost install` lists whichever apply to your machine
when it finishes:

- **codex** — start `codex` once and answer *"Trust all and continue"* at its
  `Hooks need review` prompt. Until you do, codex silently runs no hook at all.
- **copilot** — the first time you run it in a directory, answer **Yes** to
  *"wants to: handle permission requests"*. Once per directory, and nothing on
  disk records it.

Both are covered in full on [Enable the state badges](/docs/state-badges).

### By hand

roost is just a script, so this is all the placing half does:

```sh
git clone https://github.com/beatzball/roost.git roost
export PATH="$PWD/roost/bin:$PATH"   # add to your shell's startup file
```

Then `roost install` for the wiring half, or wire each harness yourself from
[Enable the state badges](/docs/state-badges).

The launcher resolves its own location (following symlinks), so it finds its
config and scripts no matter where you run it from.

## First run

```sh
roost doctor   # check tmux version, truecolor, fzf, hooks, adapter links, notifier
roost init     # pick theme, glyph set, separator style; print the Claude hooks
roost          # start/attach the default session ("main")
```

`roost doctor` is the one to run if a pane is not badging: it names the harness
that is not wired, and every state `roost install` can resolve ends its line
with `, or run: roost install` — a missing adapter, a dangling one, a codex
`hooks.json` with none of roost's handlers, copilot's `EXTENSIONS` flag, a
Claude Stop hook from before `--stop-hook` existed.

A line **without** that tail is one no installer may fix for you: something
that is not roost's sitting at an adapter path, hooks pointing at a different
checkout, or one of the two prompts a human has to answer.

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
