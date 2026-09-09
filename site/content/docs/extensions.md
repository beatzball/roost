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
| `needs` absent, or `[]` | No `ROOST_SOCKET`, and roost's own scripts are not put on its `PATH`. The consent block says *does not ask for access to your agents*. |
| `"needs": ["fleet"]` | `ROOST_SOCKET` and `ROOST_SOCKET_FLAG`, plus roost's scripts on its `PATH` — which is enough to read any pane's screen and send a prompt to any agent, the same as you can from your own shell. |

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

The lockfile is the record of what is installed, not the clone. A half-deleted clone degrades to "command not found" rather than to running something unexpected.

## Turning extensions off

Three levels, cheapest first.

**1. Turn the whole seam off.** Either of these makes the dispatcher inert, and roost behaves exactly as it did before extensions existed — an extension command becomes the ordinary usage error:

```sh
ROOST_NO_EXT=1 roost mark          # for one command
export ROOST_NO_EXT=1              # for a shell, or from your profile
```

```sh
set -g @roost-ext-enabled off      # in roost.conf, for the whole server
```

`ROOST_NO_EXT` is tested for being **non-empty**, not for a particular value — so `ROOST_NO_EXT=0` turns extensions **off** too, which is the opposite of what `0` usually means. If you want them on, unset the variable rather than setting it to zero.

**2. Remove one extension.** `roost ext remove mark --purge` leaves nothing of it behind, and the roost checkout never held any of it in the first place.

**3. Remove the seam.** It is one pull request, confined to the fallback branch of `bin/roost` plus two scripts of its own, so reverting it is clean. See the [README](https://github.com/beatzball/roost#the-extension-seam).

## Writing one

An extension is a repository with a `roost-ext.json` at its root and an executable `bin/roost-<cmd>` per command it claims. Roost hands it `ROOST_EXT_DIR`, a private `ROOST_EXT_STATE` directory for its data, and — only if it declared `fleet` — the socket to talk to your agents.

The contract, the manifest fields, and the environment an extension is given are written up for extension authors in the [README](https://github.com/beatzball/roost#the-extension-seam).
