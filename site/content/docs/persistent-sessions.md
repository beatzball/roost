---
title: Persistent Sessions
description: Save your fleet's sessions, windows and panes as a plain file, put them back after a reboot or a crash with roost restore, and bring one agent's conversation back with roost revive.
sidebar:
  order: 12
---

## What this does today

`roost save` writes your fleet's **shape** — every session, window and pane,
with their names, directories and layouts, and which agent conversation each
pane was running — to a plain text file. `roost restore` reads it back and
puts the sessions, windows and panes where they were, each pane a shell in
its saved directory.

`roost revive` brings **one** pane's agent conversation back — an agent that
crashed, or that you `/exit`ed — in the same pane, with the same `%N`.

**Restore does not resume agents yet.** A pane that was running Claude Code or
codex comes back as a shell in its directory; its conversation key stays in
the file, for a later roost that resumes it, and `roost revive` can bring a
conversation back by hand. Saving is also manual for now: run `roost save`
when you want one.

## Save

```sh
roost save
```

It prints where it wrote, and a one-line count on stderr:

```
~/.local/state/roost/shapes/roost/shape
3 sessions, 7 windows, 14 panes, 5 with a conversation, 1 stale
```

The file lives in `${XDG_STATE_HOME:-~/.local/state}/roost/shapes/<server>/`,
one directory per roost server (`roost` for the default one). The last save is
`shape`; every earlier one is kept in `history/`. Each is readable only by you
(mode 0600), because it lists every project directory and every conversation
id, and a conversation id is enough to resume that conversation.

- `roost save --to FILE` writes a copy anywhere else and leaves `shape` alone.
- `ROOST_SHAPE_DIR=/some/dir` puts the shapes somewhere else;
  `ROOST_SHAPE_DIR=` (empty) saves nothing.
- `rm -rf ~/.local/state/roost/shapes` forgets every shape and nothing else.

A save that finds nothing changed since the last one writes nothing.

## Restore

```sh
roost restore
```

Run it **from a plain terminal, not from inside roost**. If no roost server is
running, restore starts one and places your first saved session into it. If
you run `roost` first and then `roost restore` inside it, the session `roost`
made has the same name as a saved one, and restore will not touch a session
that already exists — so that saved session is skipped.

What it does:

- Every saved session that does not exist is made again, with its windows at
  their saved indices and names, its panes split to the saved count, and the
  saved layout applied. A zoomed window comes back zoomed.
- Every pane becomes a shell in its saved directory. A directory that is gone
  gives a shell in your home directory instead, with one line saying so.
- A saved session whose name already exists is **skipped and named**, with
  everything in it. Restore never adds windows to a session you have.
- Exit code: `0` everything placed, `12` something was skipped as existing,
  `13` a window could not hold every saved pane (each one left out is named,
  with its conversation), `16` the file was refused, `2` there is nothing to
  restore.

While restore is placing panes, each new pane shows `roost restore is
placing this session - press any key for a shell`. That is a placeholder, not
a shell. If you attach and press a key in it, the pane becomes your shell and
restore leaves it alone. If restore got there first, the pane says `roost
restore is placing this pane` and becomes a shell a moment later.

### Look before you restore

```sh
roost restore --dry-run
```

prints what restore would do, as a tree, and starts nothing:

```
from 20261024T205102Z-4182 (the newest save; saved 2 h ago)
session roost
  window 1 roost
    pane 1 promo        /home/me/w/roost               claude   shell, not resumed: this roost places panes only
    pane 2 -            /home/me/w/roost               -        shell
  window 2 build
    pane 1 api          /home/me/w/gone                codex    shell in ~, not resumed: directory gone
session litro (exists - skipped, 9 panes not restored)
```

`roost restore --list` shows every save with its stamp, what caused it and
its counts, and marks the one a plain `roost restore` uses.

### Pick a save, or part of one

- `roost restore --from 20261024T205102Z-4182` restores an earlier save from
  the list.
- `roost restore --from FILE` restores a copy, from anywhere. A file saved on
  another machine says so in one line, then restores. It places the panes; it
  cannot bring back conversations whose harness store is not on this machine.
- `--only NAME`, `--only NAME:WINDOW` or `--only %N` (a pane id from the save)
  restores just that, and can be given more than once.

## Revive one conversation

```sh
roost revive %5
```

brings back the conversation pane `%5` was having, in `%5` itself. It is for
the everyday case: an agent crashed, or you typed `/exit`, and the pane is
back at its shell with the conversation's id still on it. `revive` runs the
harness's own resume command in the pane:

| harness | what `revive` runs |
|---|---|
| Claude Code | `claude --resume ID` |
| codex | `codex resume ID` |
| GitHub Copilot CLI | `copilot --resume=ID` |
| pi | `pi --session FILE` (the session file), or `pi --session ID` |
| opencode | nothing: the command is **printed** for you to run (see below) |

It runs in the conversation's **own** directory, never another one. For
Claude Code that is the directory written inside the conversation's own
transcript; for the others it is the directory the agent reported. A harness
resumed from a different directory moves the conversation there (Claude Code)
or asks about it, so `revive` would rather refuse than guess.

Before it touches the pane, `revive` checks that the harness still has the
conversation, so an old pane cannot be killed for nothing. Claude Code, for
example, deletes transcripts after 30 days by default.

- **Exit `0` means launched, not resumed.** `revive` prints the pane id and
  one line on stderr with the command it ran. It does not wait for the
  harness's prompt, and it answers nothing the harness asks. A dialog the
  resume opens stays on screen for you: Claude Code's folder trust in a
  folder you never trusted, codex's "Working directory" choice or its hooks
  review, copilot's folder trust and extension permission, pi's "Fork this
  session into current directory?". The badge comes back with the harness's
  first event.
- **Exit `13`: not resumed, and the reason is printed.** The pane has no
  recorded conversation; its key belongs to another program than the one
  running in it now (a stale key); the harness no longer holds that
  conversation (`claude no longer holds 3fa3…; the pane is untouched`);
  another pane has the same conversation open, or is still launching it —
  one conversation is never open in two panes. The pane is left exactly as
  it was.
- **Exit `14`:** the harness is not on your `PATH`.
- **Exit `15`:** the conversation's directory no longer exists. `revive`
  will not resume it somewhere else.
- **Exit `1`:** the pane is ⏳ working or 🛑 blocked, or it is a shell
  running something of yours (an editor, a build). `--force` replaces it
  anyway. A shell sitting at its prompt is **not** refused: it is replaced,
  and a command you typed there but did not run is lost.
- **Exit `2`:** the target is gone, and nothing about it was kept.

**A pane that is gone.** `roost revive %5` of a pane you closed brings the
conversation back in a **new window** in the same session, as long as the
roost server has not restarted since (pane ids start again at `%0` on every
start). It reads what roost kept about the pane when the agent started. The
new pane has its own `%N`, which `revive` prints; `@roost-was` on it names
the old one. `--new-window` asks for the same thing for a pane that is still
there, but a conversation is never open in two panes, so it refuses one
whose agent still has it.

**opencode** creates a new, empty session when you resume an id it does not
know, and roost cannot yet check which ids it knows. So for opencode `revive`
prints the command (`cd DIR && opencode -s ID`) and exits `13` without
running it.

`--json` prints `{"pane","was","harness","session_id","command","cwd"}` for
a program.

## The file

One `key value` per line, blocks separated by a blank line. A short example:

```
roost-shape 1
server roost
saved 2026-10-24T20:51:02Z
gen 4182
...

session roost
id $0

window roost:1
id @0
name roost
layout 2774,381x86,0,0{95x86,0,0,88,94x86,96,0,91,190x86,191,0,90}

pane roost:1.1
id %88
name promo
cwd /home/me/w/roost
harness claude
session_id 3fa32375-68cd-43c9-8bcf-fbb876b2db1e
```

To change what comes back, **copy** `shape` and edit the copy — the next save
overwrites `shape` itself. You can delete a pane block, change a `cwd`, or
rename a session (rename its windows' and panes' addresses with it). Then:

```sh
roost restore --dry-run --from mycopy
roost restore --from mycopy
```

Restore reads the whole file first. A malformed line refuses the whole file,
naming the line, and nothing is changed.

## What is saved, and what is not

- **Saved:** sessions, windows (index, name when you set one, layout, zoom),
  panes (name, directory), and each pane's agent conversation key when the
  agent is still running in it.
- **Marked stale, never resumed:** a key whose agent has exited to its shell,
  or a pane now running a different program. The file keeps it as
  `stale_reason` so you can see what was there.
- **Not saved:** scrollback, on purpose; the conversations themselves, which
  belong to each harness; credentials. A shape copied to another machine
  places panes there and resumes nothing.
- **A `cd` is not seen until the next save.** The directory saved is the one
  the shell was in when you saved.
- **A window linked into two sessions** (`tmux link-window`) comes back as
  two separate windows.
- **A session group** (`tmux new-session -t`) comes back as a group: the
  first member with its windows, and each other member joined to it.

### Odd names and directories

Names and directories with spaces, quotes, `$`, `#`, a trailing space or a
non-ASCII character come back exactly. Two things the file cannot hold:

- A pane name with a control character in it (a tab, a newline, an escape
  byte) is not saved; the pane comes back unnamed, and `roost save` says so.
  On tmux 3.4 a name containing the four characters `\033` is treated the
  same way, because that tmux prints escape bytes that way.
- A directory with a control character in it is saved as your home
  directory, and `roost save` says so.
