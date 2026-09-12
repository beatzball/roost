---
title: Writing an Extension
description: The manifest, the environment your command is handed, and how to test one on your own machine before you publish it.
sidebar:
  order: 9
---

## What you are building

An extension is a git repository with a manifest at its root and one executable per command. Roost clones it at a commit the user agreed to, and `exec`s your program when they type your command. That is the whole mechanism — there is no plugin API to learn, no build step, nothing to register, and no roost library to link against. If your command can run from a shell, it can be an extension.

This page is for the person writing one. If you are deciding whether to *install* one, the page you want is [Extensions](/docs/extensions).

## A complete extension

Here is one, whole. Copy it and it works.

```
roost-mark/
├── roost-ext.json
├── bin/
│   └── roost-mark        # executable; runs as `roost mark`
└── README.md
```

`roost-ext.json`, at the repository root:

```json
{
  "name": "mark",
  "contract": 1,
  "roost": ">=0.1.0 <0.2.0",
  "needs": ["fleet"],
  "commands": ["mark"],
  "description": "Bookmark a spot in an agent pane, with a note."
}
```

`bin/roost-mark`, with the executable bit set:

```sh
#!/usr/bin/env bash
set -euo pipefail

# Handed to you on every run. The directory already exists.
notes="$ROOST_EXT_STATE/notes"

# Handed to you ONLY because the manifest declared "needs": ["fleet"].
# Both variables, always — see "Addressing the fleet" below.
pane="$(tmux "$ROOST_SOCKET_FLAG" "$ROOST_SOCKET" display-message -p '#{pane_id}')"

printf '%s\t%s\n' "$pane" "$*" >> "$notes"
echo "marked $pane"
```

Roost keeps a larger working example in its own repository, at `tests/fixtures/ext-status/`: a full command rebuilt from scratch on this contract, using nothing but the variables below. It is a test fixture and is deliberately never published — it re-implements a command roost already ships, which is exactly the duplication the extension seam exists to avoid. It is there to prove the contract is rich enough to build on, and to read when you want a longer example than the one above.

## The repository layout

Three rules, and nothing else about your repository is roost's business.

- **`roost-ext.json` at the repository root.** Not in a subdirectory, not named anything else. That file is what makes a repository an extension.
- **`bin/roost-<cmd>` for every command you declare**, and it must be executable. Git records the executable bit, so `chmod +x` before you commit, and check it survived: a declared command with no executable behind it is refused at install time.
- **Everything else is yours.** Sources, tests, a Makefile, a vendored dependency — roost clones the repository and never looks at the rest of it.

## The manifest

Six fields. Two are required.

| Field | Required | What it is |
|---|---|---|
| `name` | yes | `[a-z][a-z0-9-]*`, at most 32 characters. The install directory name — and the name your users type. |
| `contract` | yes | The version of the seam your extension is written against. `1` is the only one; a mismatch refuses the install. |
| `roost` | no | An advisory version range: `>=A.B.C <D.E.F`, `*`, or leave the field out. A range that does not match warns and installs anyway. |
| `needs` | no | The authority you ask for. `["fleet"]` or nothing — and it changes what your users are asked, so read *What `needs: ["fleet"]` costs your users*, below, before you declare it. |
| `commands` | yes | The subcommands you claim. Same grammar as `name`, one executable each. |
| `description` | no | One line. Shown by `roost ext info` — **not** by `roost ext list`, and **not** in the block a user is asked to approve at install. |

Two of those carry a trap worth spelling out.

**`name` is not your repository path.** A user installs `you/roost-mark` and then manages it as `mark`, because `name` is what roost writes into its lockfile and what every other verb takes: `roost ext info mark`, `roost ext update mark`, `roost ext remove mark`. If those two differ, your users will type the repository name first and be told there is no such extension. Roost prints the name to type after a successful install, but say it in your README too, and consider simply naming the manifest after the repository.

**`description` is quieter than it looks.** It is one line in `roost ext info` and nowhere else. Nobody reads it while deciding to install you; put what matters in your README, which they can read on the repository page before they type anything.

`contract` is a hard gate and `roost` is only advice — the difference, and what a user sees for each, is on the [Extensions](/docs/extensions) page.

## When you get it wrong

Roost validates your manifest after cloning and before it asks the user anything, so a mistake here surfaces as a refusal at install time rather than as a command that breaks weeks later. These are the refusals, in roost's own words, so you recognise yours when you meet it.

```
roost ext install: you/roost-mark at 3f9a1c2 has no roost-ext.json
roost ext install: that file, at the repository root, is what makes a repository an extension
```

```
roost ext install: refusing: the manifest name Mark is not usable
roost ext install: a name is [a-z][a-z0-9-]*, at most 32 characters — it is the install directory
```

```
roost ext install: refusing mark: it speaks contract 2, this roost speaks 1
```

```
roost ext install: refusing mark: it asks for an authority this roost does not know: network
roost ext install: contract 1 knows one authority: fleet
```

An unknown value in `needs` is refused rather than ignored, so a future authority can never be quietly dropped by an older roost.

```
roost ext install: refusing mark: it claims mark but has no executable bin/roost-mark
```

The commonest one, and it means either the file is missing or its executable bit is not committed.

```
roost ext install: refusing mark: it claims send, which is a roost command
roost ext install: core commands can never be shadowed by an extension
```

Roost's own commands always win, and two extensions cannot claim the same command either — the second is refused, naming the one that already holds it. Check your command names against `roost help` before you publish, because renaming a command after people are using it is their problem as well as yours.

## The environment your command is handed

Your command is `exec`'d with the remaining arguments in `"$@"`. Its exit status passes through unchanged, and roost wraps neither stdout nor stderr — your program's output is what the user sees, byte for byte.

Every extension gets these:

```sh
ROOST_HOME        # the roost checkout
ROOST_VERSION     # the product version, so you can adapt
ROOST_CONTRACT    # the seam version
ROOST_EXT_DIR     # your own install directory — read-only by convention
ROOST_EXT_STATE   # your own state directory, created before your command runs
```

And these **only** if your manifest declared `"needs": ["fleet"]`:

```sh
ROOST_SOCKET      # which tmux server your user's fleet is on
ROOST_SOCKET_FLAG # "-L" if that is a socket NAME, "-S" if it is a PATH
PATH              # with $ROOST_HOME/scripts prepended, so `roost read`, `roost send` are on it
```

Read `ROOST_SOCKET` **unguarded** — no `${ROOST_SOCKET:-}`, no fallback. Without `fleet` it is unset rather than empty, so under `set -u` you get a loud failure on the line that wanted it. That is deliberate: the fallback you would otherwise write ends up addressing the user's own everyday tmux, which is the one thing roost exists to leave alone.

## Addressing the fleet

If your command talks to the agents, write it exactly like this, every time:

```sh
tmux "$ROOST_SOCKET_FLAG" "$ROOST_SOCKET" list-panes -a
```

Both variables. This is not decoration, and it is the single mistake most likely to make your extension work perfectly for you and do nothing for anyone else.

tmux takes `-L` for a socket **name** and `-S` for a socket **path**, and they are not interchangeable. A production roost server's socket is the *name* `roost` — so the obvious `tmux -L "$ROOST_SOCKET"` works on it, and everywhere else, where the socket is a path, `-L` quietly starts or addresses a **different server**. The failure has no error in it: exit 0, no output, nothing to search for. Roost has had that outage once already, in its own code, before extensions existed.

So roost hands you the flag alongside the value rather than making you derive it. This was found by building an extension against the contract, not by reading the source — the first draft of contract 1 handed over `ROOST_SOCKET` on its own, and the first program written against it had to re-derive the rule to work at all.

With `fleet` you also get roost's scripts on your `PATH`, so `roost read %3` and `roost send %3 "..."` work from inside your command without your knowing where roost is installed.

## Where your data goes

Write everything you keep under `ROOST_EXT_STATE`. Roost creates that directory before your command runs, so it is there on your first line.

Two consequences follow, and both are worth a sentence in your own README.

- **`roost ext remove --purge` deletes `ROOST_EXT_STATE` and nothing else.** A user who purges you and still has your files in `~/.config` somewhere has been surprised by your extension, not by roost. If you must write outside it, say where, in your README, in plain words.
- **Do not write into `ROOST_EXT_DIR`.** That is the clone, and `roost ext verify` compares it against what was recorded at install — an extension that edits its own install directory reports itself as changed on disk, which is the signal a user is meant to take seriously.

## What `needs: ["fleet"]` costs your users

Declaring `fleet` is what gets you `ROOST_SOCKET`, `ROOST_SOCKET_FLAG` and roost's scripts on your `PATH`. It also changes what your user is asked before they install you. Their prompt gains a paragraph saying that the code in your extension can read any pane's screen and send prompts to any agent, the same as they can.

That is a real cost to them, so do not ask for it unless your command needs it. Reading a pane means everything that has scrolled past in it — keys, tokens, `.env` contents, source. Sending a prompt means an agent that writes files and runs commands does what your code told it to. An extension that asks for `fleet` is asking to be trusted with all of that.

Be honest about the other half too, because your users are told it at the same prompt: **`needs` is a declaration, not a boundary.** Not declaring it does not stop your code reaching the fleet — it only means you did not say so. Roost withholds the convenient route and nothing more. So if your command talks to the agents, declare it; an extension that reaches them without declaring it is doing something its users were not shown.

If you add `fleet` in a later version, roost calls that out on its own line when a user runs `roost ext update`, and asks them again. Growing your authority is visible. Plan for it rather than being surprised by it.

## Testing it before you publish

You do not have to push anything anywhere to install your own extension. Roost takes the base it clones from as an environment variable, so a bare repository on your own disk installs by exactly the route GitHub would: the same reference resolution, the same hardened clone, the same pin.

```sh
# 1. Commit your extension.
cd ~/src/roost-mark
git init -q && git add -A && git commit -m "roost-mark"

# 2. Publish it as a BARE repository, at the <org>/<repo> path
#    you want to install it by.
mkdir -p /tmp/roost-remotes/you
git clone --bare ~/src/roost-mark /tmp/roost-remotes/you/roost-mark

# 3. Install from that base instead of from github.com.
ROOST_EXT_GIT_BASE="file:///tmp/roost-remotes/" roost ext install you/roost-mark

# 4. Run it.
roost mark "a note"
```

`ROOST_EXT_GIT_BASE` replaces `https://github.com/`, and roost appends the `<org>/<repo>` you typed. Bare and over `file://` is what makes `git` take the same transfer path it takes against a real remote; a plain directory clone hardlinks the objects and would prove less.

To iterate, commit again, refresh the bare copy, and move the pin — roost shows you the diff, the same one your users would see:

```sh
git -C ~/src/roost-mark commit -am "fix the socket call"
rm -rf /tmp/roost-remotes/you/roost-mark
git clone --bare ~/src/roost-mark /tmp/roost-remotes/you/roost-mark
ROOST_EXT_GIT_BASE="file:///tmp/roost-remotes/" roost ext update mark
```

Test the negative case too, because it is the one you cannot see by running your command on your own machine: take `needs` out of your manifest, install it again, and make sure your extension fails loudly on the line that reads `ROOST_SOCKET` instead of silently talking to your own tmux. Then `roost ext remove mark --purge` puts the machine back.

## Publishing

Publishing is just pushing the repository somewhere a user's `git` can reach. `roost ext install <org>/<repo>` reaches `https://github.com/` by default, so a public repository there needs nothing further from you.

Tag your releases. A user can pin any reference — `roost ext install you/roost-mark --ref v0.1.0` — and a tag is what lets them pin something they can read a changelog for, rather than whatever your default branch happened to be that afternoon. Roost resolves whatever they give it to a full commit SHA and pins that, so a moved tag never moves an installation; your users see the diff and are asked again.

One thing to get right in your own README, and it is not a style note: **do not describe your extension as checked, screened, reviewed or vouched for.** Roost makes no such claim about any extension, and it cannot — there is no scanner and no verdict anywhere in it. What roost gives your users is that they got the exact commit they agreed to, and that they were told what you declared. What they are extending to you is the trust they would extend to anyone handing them a shell script. Earn it the ordinary way: a README that says what your code does, releases they can read, and a repository they can look at before they type yes.
