---
title: Extensions
description: Add commands to roost from a git repository — pinned to a commit, with what it asks for shown before you agree.
sidebar:
  order: 8
---

## What an extension is

An extension is a git repository that adds subcommands to `roost`. Install one and its commands work like any built-in:

```sh
roost ext install beatzball/roost-mark
roost mark            # a command that did not exist before
```

Roost's own commands always win. An extension can never take over `send`, `read`, `status` or any other built-in — a manifest claiming one is refused at install time, naming the collision. Two extensions claiming the same command are refused for the same reason.

## Read this before you install one

> An extension is a program you install and run. Roost pins it to an exact
> commit, tells you what authority it asks for, and asks before installing — so
> you know what you are getting and it cannot change under you. Roost does not
> confine what the program can do once you run it, and it does not check
> whether the code is honest. Install extensions from people you would take a
> shell script from.

Three things follow from that, and none of them is hedged.

**Roost pins, and asks.** The repository reference you give is resolved to a full commit SHA before anything is fetched, and that SHA is what is cloned, compared against the pin after the clone, and written down. Nothing updates itself: a pin that moved on its own would not be a pin. When you do run `roost ext update`, you are shown the diff between the old commit and the new one and asked again.

**Roost does not confine an extension.** Once you type one of its commands, the code in it runs as you, with everything you can reach: your files, your keys, your network, your shell. Roost has no sandbox and does not attempt one.

**Roost does not check whether the code is honest, and it cannot.** There is no scanner, no lint, no review, and no output anywhere in roost that reads as a verdict on an extension's code. Shell code can fetch its payload at run time. Roost checks two things only — that this is the exact commit you agreed to, and what the extension declared it wants to reach. Neither is a statement about what the code does.

## Installing

```sh
roost ext install <org>/<repo>              # the default branch, resolved to a commit
roost ext install <org>/<repo> --ref v0.1.0 # a tag, branch, or SHA
```

Roost resolves the reference, clones that commit into a temporary directory, reads the manifest, and then stops and shows you what it found:

```
  repo     github.com/beatzball/roost-mark
  ref      v0.1.0
  commit   a3f91c2...  (pinned)
  contract 1                       (roost speaks 1)     ok
  roost    >=0.1.0 <0.2.0          (you have 0.1.0)     ok
  claims   roost mark, roost marks

  This extension asks to drive your agents. If you install it, the code
  in it can read any pane's screen and send prompts to any agent, the
  same as you can.

  An extension that did NOT ask can still reach them if it tries. This
  line tells you what it declared, not what it is stopped from doing.

  Roost has checked that this is the exact commit named above. It has
  NOT checked whether the code is honest. It cannot.

  Nothing runs during install. Code runs when you type those commands.

  Install? [y/N]
```

Read the `commit` line: that is what you are agreeing to, and it is the only thing about this extension that roost can hold still for you.

Nothing from the extension executes during the install. Its code runs when you type one of the commands under `claims`, and not before — no post-install script is ever run, submodules are not fetched, LFS smudge filters are skipped, and git's hooks are pointed at `/dev/null` on the way in.

Two smaller things the block will tell you when they apply. `contract` is a hard gate: an extension written for a seam version this roost does not speak is refused, with the reason. The `roost` line is advisory — a version range that does not match your roost prints a note and continues, because a hard product-version gate would make every roost release a compatibility event.

If roost is not attached to a terminal it refuses instead of assuming yes. Pass `--yes` to install from a script, which means you have read the same block somewhere else first.

One qualification on "nothing runs during install", because it is yours rather than the extension's: roost hashes the extension's tree with `git`, and `git` runs any clean filter your own `~/.gitconfig` configures. That is your code, on your machine, and roost has no switch that turns it off.

## `needs`: what an extension asks to reach

An extension's manifest can declare `needs`. There is one value in this contract, `fleet`, and it is about your agents:

| the manifest declares | what roost hands the extension |
|---|---|
| `needs` absent, or `[]` | Nothing to reach your agents with: no socket, and roost's own scripts are not put on its `PATH`. The consent block says *does not ask for access to your agents*. |
| `"needs": ["fleet"]` | The socket to your agents, and roost's scripts on its `PATH` — which is enough to read any pane's screen and send a prompt to any agent, the same as you can from your own shell. The variables that carries are named in the [README](https://github.com/beatzball/roost#the-extension-seam). |

That second row is the whole point of the field. Reading a pane's screen means whatever has scrolled past in it: keys, tokens, `.env` contents, source. Sending a prompt means an agent that writes files and runs commands does what the extension asked it to.

**An extension that did not declare `fleet` is not stopped from reaching your agents.** It is nearly always run from inside a roost pane, and such a pane already carries `$TMUX` — the socket, verbatim — and roost's scripts on its `PATH` before roost's dispatcher does anything. The default socket is the guessable name `roost`, so nothing has to leak at all. Withholding those variables takes away the convenient route and makes the intent visible to you at the moment you are asked. It confines nothing.

So `needs` is a declaration, not a boundary. What it buys you is real but narrow: you see what an extension said it wanted, you see it again if it grows on an update, and an extension that reaches your agents without declaring it has to do something deliberate that shows up in its code.

Treat `fleet` as the line where you slow down. An extension that asks for it is asking for your whole fleet, and the only check that means anything at that point is having read the code — or trusting whoever wrote it the way you would trust someone handing you a shell script.

An unknown value in `needs` refuses the install rather than being ignored, so a future authority cannot be silently dropped on the floor by an older roost.

## Living with what you installed

```sh
roost ext list              # what is installed, the commit each is pinned to, what it claims
roost ext info mark         # the lockfile entry, the manifest, and both directories
roost ext verify            # does what is on disk still match what you agreed to?
roost ext update mark       # move the pin — shows the diff and asks again
roost ext remove mark       # take it off
```

`roost ext verify` re-computes the hash of each installed tree and compares it with what was recorded at install. It prints `ok` per extension, or names every file that differs, and exits non-zero if any do. `ok` means *this matches what was recorded* — nothing more. It does not cover the clone's own `.git` directory, which is excluded so that ordinary git operations inside an extension do not report a change that is not one.

`roost ext update` re-resolves the reference you installed from. If the commit has not moved it says so and stops. If it has, it shows the old and new commit **and the diff between them**, and asks again. You consented to code, not to a repository name. If the extension's `needs` has grown since you installed it, that is called out on its own line above the prompt.

`roost ext remove` deletes the clone and the lockfile entry. The extension's own data directory is **kept** and its path printed, so removing the wrong one does not take a year of its data with it; `--purge` deletes that too.

## Where the files go

Nothing is installed into the roost checkout.

| Path | What it holds |
|---|---|
| `${XDG_DATA_HOME:-$HOME/.local/share}/roost/ext/<name>/` | the clone |
| `${XDG_STATE_HOME:-$HOME/.local/state}/roost/ext/<name>/` | the extension's own data |
| `${XDG_STATE_HOME:-$HOME/.local/state}/roost/ext.lock` | what is installed, and the commit each is pinned to |
| `${XDG_STATE_HOME:-$HOME/.local/state}/roost/ext.index` | the dispatch table roost actually obeys: one line per command, with the authority it runs with |

The lockfile is the record of what is installed, not the clone. If a clone goes missing, its command degrades to the ordinary usage error rather than to running something unexpected — the dispatcher checks that the executable is really there before it hands anything over.

`ext.index` is derived from `ext.lock` and rewritten in the same step by every command that writes the lockfile, so the two cannot drift on their own. It exists because reading it needs no JSON tool: dispatching a command must not depend on `python3` or `jq` being installed. It is the file being obeyed — a hand edit to `ext.lock` alone changes nothing until something regenerates the index, and `roost ext list` warns when the two disagree.

## Turning extensions off

Three switches, cheapest first. The first two make the dispatcher inert, so roost behaves exactly as it did before extensions existed: an extension's command becomes the ordinary usage error, the same one you get for a typo.

**1. For one command, or one shell.**

```sh
ROOST_NO_EXT=1 roost mark          # this command only
export ROOST_NO_EXT=1              # this shell, or from your profile
```

`ROOST_NO_EXT` is tested for being **non-empty**, not for a particular value — so `ROOST_NO_EXT=0` turns extensions **off** too, which is the opposite of what `0` usually means. If you want them on, unset the variable rather than setting it to zero.

**2. For the whole server.** In `roost.conf`:

```sh
set -g @roost-ext-enabled off
```

**3. Take one off the machine.** `roost ext remove mark --purge` leaves nothing of it behind, and the roost checkout never held any of it in the first place.

The seam itself can also be taken out of roost altogether. That is a contributor's job rather than a setting, and it is [one revert](https://github.com/beatzball/roost#the-extension-seam).

## Writing one

Writing one is an author's job rather than a user's, and all of it — the repository layout, every manifest field, and the environment your command is handed — is on one page: [The extension seam](https://github.com/beatzball/roost#the-extension-seam) in the README.
