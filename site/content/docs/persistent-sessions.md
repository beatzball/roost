---
title: Persistent Sessions
description: Save your fleet's sessions, windows and panes as a plain file, and put them back after a reboot or a crash with roost restore.
sidebar:
  order: 12
---

## What this does today

`roost save` writes your fleet's **shape** — every session, window and pane,
with their names, directories and layouts, and which agent conversation each
pane was running — to a plain text file. `roost restore` reads it back and
puts the sessions, windows and panes where they were, each pane a shell in
its saved directory.

**Agents are not resumed yet.** A pane that was running Claude Code or codex
comes back as a shell in its directory; its conversation key stays in the file,
for a later roost that resumes it. Saving is also manual for now: run
`roost save` when you want one.

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
