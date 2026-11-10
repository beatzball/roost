---
title: Persistent Sessions
description: roost saves your fleet's sessions, windows and panes as a plain file on every change; put them back after a reboot or a crash with roost restore — agents resumed, paced, in their own directories — or turn on roost persist to place them at login, and bring one agent's conversation back with roost revive.
sidebar:
  order: 12
---

## What this does today

`roost save` writes your fleet's **shape** — every session, window and pane,
with their names, directories and layouts, and which agent conversation each
pane was running — to a plain text file. `roost restore` reads it back, puts
the sessions, windows and panes where they were, and then **resumes each
agent** in its own directory, two seconds apart.

`roost revive` brings **one** pane's agent conversation back — an agent that
crashed, or that you `/exit`ed — in the same pane, with the same `%N`.

Saving is automatic: roost saves the shape every time the fleet changes, so
you rarely need `roost save` at all. Restoring is by hand — run `roost
restore` after a reboot or a crash — unless you turn on `roost persist`, which
places the fleet when you log in and resumes the agents when you first attach
(**Bring the fleet back at login** below). With `persist` off, the first
`roost` after a crash **asks** whether to bring the saved fleet back
(**Persist off: roost asks after a crash** below).

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

### Saving is automatic

roost saves on its own whenever the fleet changes shape:

- a session, window or pane is made, closed, killed, renamed or moved
  (`roost spawn`, `split` and `view` too, once the pane has its name);
- a pane's program exits, or dies and stays on screen;
- a layout is chosen or a pane resized **by a command**;
- an agent reports its conversation (`roost identify`), and `roost revive`
  or a restore relaunches one;
- `roost close` takes a pane away, and a restore finishes placing.

Some changes fire nothing roost listens to, so they are saved only with the
**next** change of any other kind: a pane resized by dragging, `swap-pane`,
`swap-window`, a `join-pane` or `move-pane` that leaves its window with
panes, `respawn-pane` by hand, and a shell's `cd`. A crash right after one of
those restores the panes as they were before it.

The saving runs in the background and never shows on screen. Several changes
at once (ten `roost spawn`s in a second) become one or two saves. Each save
says in its first lines what caused it.

`history/` keeps the last **100** saves (`ROOST_SHAPE_KEEP=N` keeps N): enough
for a whole fleet to shut down pane by pane and the save before it to still
be there. `ROOST_SHAPE_DIR=` (empty) turns saving off.

`roost doctor` says whether saving is on and names the last save. It warns
when the server has not saved since it started (a shape directory you cannot
write to shows this way), and quotes the step and exit code when the last save
failed.

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
- Every pane without an agent becomes a shell in its saved directory. A
  directory that is gone gives a shell in your home directory instead, with
  one line saying so; an agent whose directory is gone is not resumed.
- Every pane **with** an agent waits for its turn, then the agent is resumed
  (next section).
- A saved session whose name already exists is **skipped and named**, with
  everything in it. Restore never adds windows to a session you have.
- Exit code: `0` everything placed and every agent launched, `12` something
  was skipped as existing, `13` an agent was not resumed (the reason is
  printed) or a window could not hold every saved pane (each one left out is
  named, with its conversation), `16` the file was refused, `2` there is
  nothing to restore. `12` wins when both happen.

While restore is placing panes, each new pane shows `roost restore is
placing this session - press any key for a shell`. That is a placeholder, not
a shell. If you attach and press a key in it, the pane becomes your shell and
restore leaves it alone. If restore got there first, the pane says `roost
restore is placing this pane` and becomes a shell a moment later.

### Agents are resumed, one at a time

After the panes are placed, restore resumes every agent that had a
conversation, with the harness's own resume command (the table under
**Revive one conversation** below), in the conversation's own directory —
shells first, then agents, `--pace` seconds apart (default `2`), so a large
fleet does not start all at once.

Until its turn, an agent's pane shows

```
waiting to resume claude - press any key for a shell
```

That is a placeholder, not a shell. **Press a key and the pane is yours**: it
becomes a shell, that agent is not resumed, and the pane says so
(`roost revive %N` brings it back later). Whatever else you typed with the key
is thrown away on purpose, so half a command never runs. Once its turn has
come, the pane says `resuming claude now`, and a key does nothing.

`roost send` and `roost answer` **refuse** a pane that is still waiting,
launching or just launched (exit `3`, naming the state), because the text
would land as that key. `--force` sends it anyway. `roost close` on a
waiting pane closes it at once and cancels its resume.

**"Launched", not "resumed".** Restore runs each resume command and moves
on. It does not wait for the harness's prompt and answers nothing the harness
asks: a folder-trust or similar dialog stays on screen for you.

A resume that cannot run leaves the placeholder showing why:

```
claude was not resumed: store miss - press any key for a shell; roost restore --resume --retry tries again
```

The reasons are `harness missing` (not on your `PATH`), `directory gone`,
`store miss` (the harness no longer holds that conversation) and
`duplicate of %M` (another pane has that conversation open, or is launching
it — one conversation is never open in two panes). Fix the cause, then

```sh
roost restore --resume --retry
```

tries those panes again. It never touches a pane you took with a key, one you
replaced with another command, or one now running another conversation.

- `--no-resume` places only: every pane is a shell, no agent is started.
- `--recent DAYS` leaves out an agent whose conversation was last written
  more than DAYS days ago; its pane is a shell. The choice is made when the
  panes are placed, so a later `--resume` does not start it either.
- `--resume` resumes the panes already placed and waiting, without placing
  anything.
- `--pace SECONDS` sets the gap between launches; `0` starts them back to
  back.

**The report.** Restore ends with one line on stderr:

```
roost restore: restored 3 sessions, 7 windows, 14 panes; launched 5 agents; skipped 0 (existing); 1 not resumed (reasons listed above); 1 were working or blocked at the save — re-prompt by hand: %4
```

Above it, one line for each pane not resumed and why; a pane that was started
with a command (`roost view`, `roost spawn NAME CMD`) says what it was
started as, for you to run again. A Claude or codex pane with no recorded
conversation, or a stale one, also gets the resume lines of
[An agent with no recorded conversation](#an-agent-with-no-recorded-conversation):
printed for you, never run. An agent that was mid-turn at the save
comes back at rest: its conversation is back, its turn is not, so re-prompt
it. `--json` prints the same as one document on stdout:
`{"restored":[{"was","pane","session","window","launched","reason"}],"skipped":[…],"from":"STAMP-GEN"}`.

**codex.** When more than one codex pane is resumed, the report says
`N codex panes resumed; until #145 their badges all land on the first (%M)`:
every resumed codex reports its state through the first one's background
process, so their badges all show on that pane until #145 is fixed.

### Which save a restore picks

A plain `roost restore` uses the newest save, `shape`, with two rules on top.

**After a shutdown.** When a machine shuts down, agents can exit one by one
before tmux itself goes, and each exit is saved: the newest saves can be a
fleet shrinking to nothing. So when the system records its last shutdown
(macOS `last reboot`, Linux `last -x`) and the newest save is one of those
exits inside the shutdown's minute or the minute before, restore walks back to
the newest save that is not. With no readable record it uses `shape` and says
so in one line. `roost restore --list` marks the save it would pick.

**Closed stays closed.** A pane you removed on purpose does not come back:

- `roost close` on a pane;
- `tmux kill-pane`, `kill-window`, or `kill-session` of a session that is not
  the last;
- `roost kill NAME` and `roost stop`, which end a session or the whole fleet
  for good.

roost writes down each such removal the moment it happens, and every restore
of a save from that server's run leaves those panes out. A window that lost
panes this way takes tmux's default layout (one line says so), and a window
or session with nothing left is not made. A pane that merely exited is not a
removal: a crash, a shutdown or a lost connection leaves the fleet
restorable.

**After `roost stop` or `roost kill`.** Ending a fleet on purpose means a
plain `roost restore` brings nothing back:

```
roost restore: nothing to restore: every saved pane was closed on purpose
roost restore: to bring back a fleet you stopped: roost restore --from ~/.local/state/roost/shapes/roost/shape
```

The fleet is still on disk. To get it back, restore the file **by path**:

```sh
roost restore --list
roost restore --from ~/.local/state/roost/shapes/roost/history/20261026T101500Z-412
```

(`shape` itself, or any `history/` file `--list` shows.) `--from` with a
`STAMP-GEN` name honours the closes and restores nothing; only a path skips
them. `tmux kill-server`, and `tmux kill-session` of the last session, are
not seen at all: use `roost stop` to end a fleet you do not want back.

### Look before you restore

```sh
roost restore --dry-run
```

prints what restore would do, as a tree, and starts nothing:

```
from 20261024T205102Z-4182 (the newest save; saved 2 h ago)
session roost
  window 1 roost
    pane 1 promo        /home/me/w/roost               claude   resume
    pane 2 -            /home/me/w/roost               -        shell
    pane 3 review       /home/me/w/roost               claude   shell, not resumed: store miss
  window 2 build
    pane 1 api          /home/me/w/gone                codex    shell in ~, not resumed: directory gone
session litro (exists - skipped, 9 panes not restored)
```

A pane reads `resume` only when its harness still holds the conversation:
the preview asks the store the same way the resume itself does, so a
conversation the harness has since deleted reads `store miss` here, and is
not counted in the restore offer's "would resume".

`roost restore --list` shows every save with its stamp, what caused it and
its counts, and marks the one a plain `roost restore` uses. It ends with
every pane still waiting, launching, failed or taken, with its state and,
for a failed one, the reason.

## Bring the fleet back at login: `roost persist`

```sh
roost persist on
```

Run it once, with roost running. From then on, after a reboot:

1. **At login**, a login job places your fleet: every saved session, window
   and pane, each agent's pane waiting in a placeholder that says `waiting to
   resume claude - press any key for a shell`. No agent is started yet.
2. **When you first attach** — `roost`, `roost session NAME`, `roost ssh`, or a
   plain `tmux -L roost attach` — the agents come back, two seconds apart, in
   their own directories, with any dialog in front of you. Detaching never
   starts or stops anything.

If you type `roost` while the login job is still placing, `roost` waits and
says so (`waiting for the login restore (pid N)`, every 10 s), then attaches.
If the login job did not run at all, the first `roost` of that boot does its
work itself before attaching. A server you stop on purpose and start again in
the same boot is left alone.

`roost persist on` installs **one login job per roost server**:

- macOS: `~/Library/LaunchAgents/dev.roosting.roost.<server>.plist`, loaded
  with `launchctl bootstrap`. Run `persist on` from a session where you are
  logged in at the Mac itself: over ssh with nobody logged in at the console,
  loading into your login session fails, and `on` then leaves nothing
  behind. (Not measured yet.)
- Linux: `~/.config/systemd/user/roost-persist-<server>.service`, enabled
  with `systemctl --user enable` (not started: it runs at your next login).
  A systemd user service runs while you are logged in, and stops with your
  last session unless linger is on; to keep the fleet across a logout and
  start it at boot without a login, run `loginctl enable-linger` yourself
  (`persist on` prints the line, it does not run it). Measured on Ubuntu
  24.04: without linger the fleet ends about 10 s after your last session
  does, and your next login brings it back the way a reboot does, agents
  resuming at your first attach; with linger it survives a logout,
  `KillUserProcesses=yes` included.

`roost persist on --name NAME` does the same for another named server.
A name may hold letters, digits, `.`, `_` and `-`.

### Persist off: roost asks after a crash

Which one runs when: with `persist` **on**, the login job places the fleet
and nothing is asked. With it **off**, nothing happens at login, and the next
`roost`, `roost session NAME` or `roost new` you type after a crash or a
reboot asks first, before it starts anything:

```
roost: a saved fleet from 2 h ago (2026-10-24 20:51): 13 sessions, 21 windows, 47 panes; 31 of 35 agents would resume.
  r restore it   p preview   n start fresh, do not ask again   l restore at login from now on: off
  Enter starts fresh (nothing is restored without an r).
```

- **`r`** restores that fleet: the sessions, windows and panes are placed,
  then roost attaches, and the agents come back after the attach, two seconds
  apart, as with the login restore. A fleet with no `main` session is
  attached at its own active session, and roost says which.
- **`p`** prints the plan — exactly what `roost restore --dry-run --from
  STAMP-GEN` prints for that save — then asks again. Nothing is started.
- **`n`** starts fresh and **declines** that save: you are not asked about it
  again, and the login restore will never place it either, even if you turn
  `persist` on later. Nothing is deleted.
- **Enter** starts fresh **without** declining: the same as `n`, except that
  the save is not marked. It is the default, so nothing is restored, and no
  agent is started, without an `r`.
- **`l`** turns "restore at login from now on" on or off. It decides nothing
  by itself: press `r`, `n` or Enter after it. With it on, `roost persist on`
  runs once your choice has built the server, just before the attach. If it
  fails, roost says so and attaches anyway.
- **No key in 60 s**: the same as Enter. The 60 s apply only before the first
  key: after `p`, take as long as you like.
- **Ctrl-C** leaves with nothing started and nothing declined; the next
  `roost` asks again.

It is asked only when the server is not running, saving is on, `persist` is
off, the save was made on this machine, and it holds something worth
restoring (a pane with an agent, or more than one pane; a fleet you closed on
purpose with `roost kill` or `roost stop` holds nothing). Two terminals
opening at once get one question: the other waits (`waiting for the restore
offer in another terminal (pid N)`) and then attaches.

**Who is asked.** A script with no terminal (`roost < /dev/null`, `roost |
cat`) is never asked: `roost` does what it always did. A caller that sets
`ROOST_NO_OFFER=1`, or runs `roost --no-offer` (`roost --no-offer session
NAME`), is not asked either. Neither is a caller with one of these agent
markers set:

| harness | marker |
|---|---|
| Claude Code | `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION` |
| codex | `CODEX_THREAD_ID` |
| GitHub Copilot CLI | `COPILOT_CLI`, `COPILOT_AGENT_SESSION_ID` |
| pi | `PI_CODING_AGENT`, `AI_AGENT` |
| opencode | none known |

Any other caller that attaches through a terminal — an agent of a harness
with no known marker, say — sees the question, and after 60 s with no key is
started fresh with nothing declined.

**After `n`, Enter or no answer**, roost prints the way back before it
attaches, for example:

```
not restored; roost restore --from 20261024T205102Z-4182 brings it back (doctor names it too)
the saved "main" is skipped while a "main" runs: tmux -L roost rename-session -t main main-fresh, then roost restore --from 20261024T205102Z-4182
```

The line names the save by its `STAMP-GEN`, not a bare `roost restore`: the
fresh server saves at once, so a bare restore would pick the fresh fleet. The
second line appears when the saved fleet has a session of the name you just
started (`main`): a restore skips a session that exists, so renaming the
fresh one first frees the name. Renaming kills nothing, and you stay attached
to it.

After `n` and Enter, roost then prints `press any key to go on` and waits
for a key before it attaches, so you can read those lines: the attach takes
the whole screen. It waits at most 60 s. It also waits after `l` (so you see
what `roost persist on` installed, or why it failed), and after `r` when the
restore report names something the restored fleet does not show: a session
skipped because it exists, an agent not resumed, or agents that were busy at
the save. A clean `r` attaches at once. After no answer in 60 s it does not
wait: nobody pressed a key, so nobody is known to be there. Keys you typed
before the prompt appears (an Enter after `n`, say) do not count, so the
prompt always waits for a key pressed after it. Ctrl-C there leaves roost
with the server running; run `roost` to attach.

**The decline** is a file, `declined`, in the shape directory: a hard link to
the save you turned down. `roost restore --from STAMP-GEN` finds it even after
the history ring has dropped that save, `roost restore --list` marks it
`declined` (listing it last when the ring has dropped it), and `roost doctor`
names it. Only the newest decline is kept: a second `n` replaces the first.
To keep an older one, copy `declined` first; `roost restore --from COPY`
restores the copy as a file. `rm` of `declined` forgets the decline.

### What runs, and with what

The job runs `<this checkout>/bin/roost persist --at-login <server>` with the
environment in `~/.local/state/roost/shapes/<server>/service.env`, a 0600
file `persist on` writes: `HOME`, `PATH`, `LANG`/`LC_ALL`, the state, config
and shape roots, `TMUX_TMPDIR`, and the harness homes you have set
(`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`,
`OPENCODE_CONFIG_DIR`). It **never** holds a variable whose name contains
`KEY`, `TOKEN`, `SECRET` or `PASSWORD`: the job needs your roots, not your
credentials. Only `roost persist on` writes it; `status`, `doctor`, `upgrade`
and the login job read it and never rewrite it, so an edit you make there
stays.

What the login job did goes to `login.log` beside it (0600, cut to its newest
half past 1 MB): which save it picked and why, what it placed, and how many
agents wait for the first attach.

The agents are resumed when you attach, inside your login session, not by
the login job: a harness that keeps its credentials in the macOS Keychain
reads them as it would in any terminal. (Not yet checked across a real
reboot.)

### Turn it off, or look at it

```sh
roost persist status
roost persist off
```

`status` says whether it is on, where the job's file is, whether it is loaded
and runs this checkout, whether `service.env`'s roots match yours, the newest
save, how many agents still wait, and the last login line. `roost doctor`
prints the same in one line and warns when something is off.

`off` unloads the job (`launchctl bootout`; `systemctl --user disable`) and
removes its file, the `persist` marker and `service.env`. **It never stops an
agent**: it never runs `stop` or `--now`. Your saves, `history/` and any
waiting resumes stay. Another server's job is not touched.

`roost upgrade` rewrites a job that still runs another checkout to run the
upgraded one, and says so.

### When the old server is still there

If a roost server is still running but its socket file is gone (a temp
cleaner removed it), starting a second server under the same name would hide
your fleet. roost refuses instead — `roost`, `roost spawn`, `roost restore` and
the login job alike:

```
roost: the tmux server (pid 4182) is still running but its socket is gone; kill -USR1 4182 recreates it
```

`kill -USR1` makes tmux create its socket again, and your fleet is back.

### Quitting the terminal app

On macOS 26.3, quitting Terminal.app does not end a tmux server started from
it, attached or not; this was measured, and roost starts its server the
ordinary way. Other terminal apps, and newer macOS versions, have not been
checked.

## Addressing a pane after a restore: `was:%N`

Pane ids start again at `%0` every time the roost server starts, so after a
reboot the pane that was `%930` has a new id, and **an old id like `%1`
usually exists again as some other pane.** So roost never redirects a bare
`%N`: it always means a pane of the server running now.

To reach a pane by the id it had before the restore, write `was:`:

```sh
roost send was:%930 "carry on"     # roost send: was:%930 is %34
roost read was:%930                # the replies %930 gave BEFORE the reboot
```

`send`, `read`, `wait-done`, `screen`, `answer`, `close`, `revive` and
`forget` all take it, and say on stderr which pane it meant. It is looked up
in the map restore wrote for the server running now, and nowhere else. If two
restores into this server both had a `%930`, `was:%930` is refused and names
both long forms, `was:%930@BOOT`, which work.

A bare `%1` that is a live pane **and** was an old id gets one extra line,
`note: %1 was also an old id; the pane that was %1 is now %0 (was:%1)`, and
still goes to the live `%1`.

`roost status` ends a restored pane's line with `(was %930)`, and
`roost status --json` has `was` for every pane (`null` when it was not
restored). A resumed Claude Code is told both ids when it starts: "This pane
is %34 (it was %930 before a restore)".

### Pick a save, or part of one

- `roost restore --from 20261024T205102Z-4182` restores an earlier save from
  the list, still leaving out what was closed on purpose since.
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

### An agent with no recorded conversation

Some panes ran Claude Code or codex but roost never learned which
conversation they had. A Claude pane started before roost recorded ids is
one; most codex panes are another (#145). A pane whose agent left a key
that no longer fits it (a stale key) counts the same. `revive` exits `13`
for such a pane, and `restore` leaves it a shell. Then both print every
conversation the harness still has for the pane's directory, newest first:

```
roost revive: '%34' has no recorded conversation (harness claude, no session id)
roost revive: claude holds these conversations for /home/me/w/roost, newest first (printed, not run; pick one):
  claude --resume 3fa3c0de-2222-4abc-8def-000000000002
  claude --resume 3fa3c0de-3333-4abc-8def-000000000003
```

For codex the lines are `codex resume ID`. `restore` prints the same lines
under the pane's own line in its report, and `restore --dry-run` prints them
under the pane in its plan. In `restore`, when the agent in the pane had
exited, its own last conversation is listed first. (`revive` does not list
for such a pane: it resumes that conversation, as above.) A directory that
is gone gets no lines, since none of them could run there.

**roost prints these lines and never runs them.** Several panes often share
one directory, so the newest conversation there may belong to another pane.
A guess would open the wrong conversation in the wrong pane. Pick the one
you want and type it in the pane, in that directory.

A conversation is listed only when its own file names this exact directory.
For Claude Code, roost reads only the folder Claude keeps for that
directory, so a conversation filed somewhere else is not listed. Missing a
conversation makes the list shorter; it never adds a wrong one.

## The file

It starts with a few notes for you, each line beginning with `#`: what the
fleet was (one line per session — its windows, panes and agents, by the names
you know), when and why it was saved, and the command that prints the whole
tree. roost skips every `#` line, so you can add your own notes to a copy.
After the notes comes the file itself: one `key value` per line, blocks
separated by a blank line. A short example:

```
# A saved roost fleet: server roost, saved 2026-10-24T20:51:02Z, because of: after-split-window
# 1 session, 1 window, 3 panes, 1 agent
#   roost: 1 window ("roost"), 3 panes; agent: claude "promo"
# run `roost restore --dry-run --from <this file>` to see the full tree
# (a line that starts with # is a note for people; roost skips it)
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
naming the line, and nothing is changed. Keep `roost-shape 1` right under the
notes: a blank line between them is refused too.

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
  the shell was in at the last change roost saved.
- **A revived agent that stops in a dialog** is saved without its
  conversation key until it reports in (the save before still has it, in
  `history/`). A pane restore placed and has not resumed yet keeps its key in
  every save, marked `resume pending` (or `resume failed` with the reason).
- **A session skipped because a key took its first pane** comes back with
  `tmux kill-session -t NAME` then `roost restore --from STAMP-GEN --only
  NAME`, with the save restore names in its message: after the kill, the
  newest save no longer has that session.
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
