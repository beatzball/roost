---
title: Changelog
description: Every released version of roost, what it added, and what it fixed.
sidebar:
  order: 10
---

<!-- GENERATED FILE — do not edit.
     Source: CHANGELOG.md at the repository root.
     Regenerate: cd site && node scripts/sync-changelog.mjs -->

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [0.6.1]

Two things that were wasting your machine's time. `roost forget --gone` could
hang for ever against a suspended tmux server while pinning a CPU core, because
the two-second bound it enforced gave up by asking politely — and a tmux client
spinning against a stopped server never hears that. And a codex pane printed a
warning naming your own `hooks.json` path on every single start, because roost
asked for a hook timeout codex was quietly clamping down anyway.

One thing to know, and only if you run codex: **run `roost install`** to pick up
the new `Interrupt` timeout, and `roost doctor` will keep saying so until you
do. On codex 0.154.0 that is the whole step. An older codex hashes a hook's
timeout, so it may ask "Hooks need review" once — answer "Trust all and
continue", for `Interrupt` alone. If it asks you nothing, the install worked.

### Fixed

- **`roost forget --gone` no longer hangs for ever on a suspended server**
  (#125). Checking whether a recorded server is still alive asks tmux and gives
  up after two seconds. It gave up by sending the polite signal — and a tmux
  client talking to a *suspended* server (`kill -STOP`, a debugger, a laptop
  resumed mid-connection) does not block; it spins, and while it spins it never
  acts on that signal. So the two-second bound was not a bound: the command
  never returned, and a CPU core stayed pinned at 100% until something else
  killed the client. Measured at 2 minutes 21 seconds of CPU and still running.
  The bound now escalates — polite signal, one second, then the one that cannot
  be ignored — so the worst case is three seconds. A server roost could not
  reach is still reported as "could not ask", never as gone, so no record is
  deleted on the strength of a timeout.

- **codex no longer warns about the `Interrupt` hook timeout on every start**
  (#123). Codex caps an Interrupt hook at 3 seconds. roost asked for 10, so
  codex clamped it and printed `warning: clamping Interrupt hook timeout to 3s
  in <your home>/.codex/hooks.json` every time it started — your home path on
  your screen, on a correct install. roost now asks for the 3 codex was giving
  it anyway.

  **Run `roost install` to pick it up.** On codex 0.154.0 that is the whole
  step: a `timeout` is not part of the hash codex stores when you trust a hook,
  so the new number lands under your existing trust entry and codex asks you
  nothing. An older codex does hash it — if "Hooks need review" appears, answer
  "Trust all and continue" once, for `Interrupt` alone, and until you do a codex
  dialog answered No or Esc leaves the pane 🛑. `roost doctor` reads the timeout
  out of your `hooks.json` and says so while the old number is still there. What
  the hook *does* is unchanged: three seconds before, three seconds now.

  (The first cut of this entry said the re-trust was certain. It was written
  from measurements on codex 0.150.1 and 0.151.0, where a timeout *was* hashed.
  Re-measured on 0.154.0 — with an appended command argument as the control, to
  prove the probe still sees a real change — it is not. `docs/known-gaps.md`
  carries the hashes.)

## [0.6.0]

roost now tells the truth faster and more often. A Claude Code permission
dialog is badged 🛑 as it opens — 72 ms, not six seconds — so `roost send` can
never paste into it, and a subagent's dialog, a failing tool after Yes, or a
background agent's tool result no longer moves or strands the badge.
`roost send` proves the target began a new turn and hands back its number, so
`wait-done --turn` and `read --turn` answer the prompt you sent, not the one
before it. A long reply from an adapter survives Linux by travelling on stdin.
And when you are attached over SSH, a blocked or errored agent reaches your own
terminal's notification, with nothing installed on the near side.

Two things to know: `send` into a pane whose `done`/`idle` badge was set by
hand, or whose agent has exited to a shell, now waits out a bound and exits 4
rather than 0; and existing installs need `roost install` again (or a server
restart for roost-owned wiring) to pick up the two new Claude hook entries —
`roost doctor` says so.

### Added

- **Notifications reach a human attached over SSH** (#46). When an agent is
  `blocked` or hits an `error`, roost now also writes the terminal's own
  notification escape sequence (OSC 9 by default; `777` and `99` are
  available) straight to each attached client's terminal, so a remote
  terminal that reads it raises a desktop banner with no app, no daemon and
  no account in the path. It is on by default only for a remote client (one
  whose session carries `SSH_CONNECTION` or `SSH_TTY`), decided per client
  from tmux's own record; `@roost-notify-osc on|off` overrides, and
  `@roost-notify-osc-codes` picks the sequences. Every write is bounded to
  one second and started in parallel, so a stalled link cannot hold up the
  agent's hook, and each sequence leads with a terminator so a terminal left
  mid-sequence by a killed write heals on the next one. Control-mode clients
  are skipped. A new docs page, Notifications, covers the backend chain and
  the no-vendor phone recipe (`@roost-notify-cmd` plus SSH over a private
  mesh network).
- **`roost send` proves the target began a new turn, and says which one**
  (#92). After the verified submit, `send` waits — bounded, ten seconds by
  default (`@roost-send-turn-timeout`, clamped to 120) — for the target to
  leave its finished badge, and prints one line, `%N TURN`: the pane the text
  reached and the turn it started. `roost wait-done --turn N` and
  `roost read --turn N` then tie the wait and the reply to that exact prompt,
  so a `wait-done` that begins before the target's hook has fired can no
  longer hand back the previous turn's reply as if it were the answer. `send`
  gained `--json` (`target`, `pane`, `turn`, `started`, `state`), and a new
  exit code **4**: the text was submitted but no turn began inside the bound,
  so do not send it again. A pane with no badge is not waited for and prints
  nothing; an errored turn prints no number, because it is never recorded.

### Changed

- `send` into a pane whose `done` or `idle` badge was set by hand, or whose
  agent has exited to a shell, now waits out the bound and exits 4 rather
  than 0.

### Fixed

- **A long reply from an adapter no longer dies on Linux** (#86). `roost reply`
  now also reads the reply from stdin — `roost reply -`, `roost reply --stdin`,
  or a pipe with no argument — and the opencode, pi and copilot adapters
  publish that way. Linux refuses a single command-line argument of 128 KiB or
  more, so a reply that long never reached roost there, while macOS carried it,
  which is why it was never seen on the development machine. The one-argument
  form is unchanged. A reply longer than a few KB, or one built from a file,
  belongs on stdin. The kept turn file holds every byte, trailing newlines
  included, on both paths.
- **A Claude Code permission dialog is badged 🛑 as it opens, not six seconds
  later** (#91). roost learned of a dialog from the `permission_prompt`
  Notification, which arrives 6.00 s after the dialog is drawn — and a dialog
  answered sooner was never badged at all. In that window `roost send` could
  not refuse, and pasted into the open dialog. Claude's `PermissionRequest`
  hook event fires about 10–16 ms after the dialog is drawn; roost now wires
  it (measured: `blocked` in 72 ms), keeps the Notification as the fallback
  for an older Claude, and records what the dialog is asking in
  `@roost-blocked-on` (`<tool>: <command or path>`, 120 characters) for a
  later display. The hook prints nothing: `PermissionRequest` is an event
  Claude acts on, and roost never answers for the human.
- **A subagent's dialog no longer flips the pane to ✅ done while it is still
  open.** A background agent's dialog ends the main turn with a `Stop` — 7 ms
  after, or 0.3 ms before, the dialog event; the order swaps between runs.
  Everything a dialog stamps is now one tmux command, and a `Stop` decides at
  the write, inside tmux, whether the pane is blocked; the first `Stop` under
  an open dialog is held back, a second always moves the pane.
- **A tool that fails after the human answers Yes no longer strands the pane
  at 🛑.** Claude sends `PostToolUseFailure`, not `PostToolUse`, for it; roost
  now wires that event too (eight Claude hook entries). `roost doctor` warns
  about a settings file or a roost-owned wiring file written before this
  change; `roost install` adds the missing entries.
- **A background agent's tool result no longer clears another agent's open
  dialog.** `PostToolUse` and `PostToolUseFailure` read `agent_id` while the
  pane is blocked, and a subagent's event leaves the badge alone.

## [0.5.0]

An agent's replies are now kept on disk, one file per turn. A long reply is no
longer cut short, an older turn can be read back, and a pane you closed still
has its last answer. Nothing you already do changes: the pane is still the truth,
and `roost read` on a pane with nothing kept prints exactly what it printed
before.

### Added

- **Every reply is kept whole** (#74, #42). Each turn is written to
  `${XDG_STATE_HOME:-~/.local/state}/roost/panes/`, beside the pane option roost
  already set. A reply longer than the 12 KB pane limit now reads back in full
  instead of being cut off without saying so.
- **`roost read --turn N`** reads one earlier turn. `N` counts from the first
  turn; `-N` counts back from the newest, so `-1` is the newest. The last **100**
  turns per pane are kept (`ROOST_RECORD_KEEP`).
- **A closed pane still answers.** `roost read %N` prints that pane's last reply,
  with a note saying the pane is gone. It works by pane id, on the same server
  boot that wrote it.
- **`roost forget`** deletes kept replies: `roost forget TGT` for one pane,
  `--gone` for every pane that is closed or whose server has stopped, `--all`
  for all of them. A closed pane's replies also delete themselves **30 days**
  after its last one (`ROOST_RECORD_DAYS`).
- **`--json` gained `turn` and `source`** on `roost read`, so a program can tell
  which turn it got and whether it came from the kept file or the pane. Existing
  fields are unchanged.

### Changed

- `roost read` prints a kept file **only while the pane still holds the reply
  that turn was written from**. If the pane has moved on, the pane wins and you
  get today's output. Nothing kept on disk can override a live pane.
- **A reply now prints as the agent wrote it, not as tmux stored it.** On tmux
  3.4 a `$` before a letter or `{` was stored as `\$`, so `$HOME` came back as
  `\$HOME`; from a shell with no UTF-8 locale, newlines, tabs and non-ASCII came
  back as `_`. Where a reply was kept, `read` now prints the real bytes. Where
  none was kept, it prints exactly what it printed before.
- Files roost writes are private to you: directories `0700`, files `0600`.

### How to turn it off

Set `ROOST_RECORD_DIR=""` and nothing is kept. Set it to a path to keep records
somewhere else. Everything lives under one directory you can delete in one
command.

### Known limits

Full list in `docs/known-gaps.md`. None of them reports a wrong reply as right —
where a limit bites, you get today's behaviour.

- A reply of **131,072 bytes or more** from opencode, pi or copilot is lost
  before roost runs, because Linux refuses an argument that long. The largest
  real reply measured was 24,675 bytes.
- Trailing newlines and NUL bytes are still dropped, as before.
- What ties a turn to its pane is a small record of what tmux stored, not the
  reply's own bytes — they cannot be compared exactly on every tmux version. So
  a turn file **edited by hand** is trusted and printed while the pane is
  unchanged. Only a changed length under a truncation marker is caught.
- Where nothing was kept — records off, or a write that failed — a reply that
  tmux rewrote still prints rewritten, exactly as before.
- A filesystem with no hard links keeps nothing.

## [0.4.1]

### Fixed

- **`roost wait-done` now spots an agent that died at a shell prompt** (#64).
  Before, if you started an agent by typing its name in a pane and it then died,
  the pane stayed alive, the badge stayed ⏳, and `wait-done` waited for its whole
  timeout. It now exits **2** and says the agent died, as it already did when a
  pane closes.

### Known limits

- **A Claude killed in the middle of a reply is not caught quickly.** Claude
  starts a `caffeinate` helper that can outlive it by up to about 5 minutes.
  Until that helper exits, `wait-done` behaves as before: it waits, then times
  out with exit 1. codex is caught in under a second.
- A wrapper program that outlives its agent is never caught.
- **Neither case ever reports a false "died".** The evidence for a quicker rule
  is in issue #72.

## [0.4.0]

Roost can now wire the agents in its own panes, instead of editing your files.
Nothing you already have stops working, and you can turn it off at any level.

### Added

- **Agents started inside a roost pane get roost's wiring** (#58), from files
  roost owns under `~/.config/roost/wiring/`. That includes an agent you type by
  hand, one from `roost spawn`, and one another agent starts. Nothing outside
  roost is affected.
  - **Claude Code** gets it through a small shim on the pane's PATH, which adds
    a hooks-only settings file.
  - **opencode** gets it through `OPENCODE_CONFIG_DIR`, which merges with your
    own config. Its plugin will not load twice.
  - **codex, pi and copilot are unchanged.** They still use `roost install`,
    because none of them can add config without moving your login too.
- **`roost wiring`** turns it on and off: `roost wiring on`, `roost wiring off`,
  `roost wiring off -t SESSION`, and `roost wiring remove`.
- **`roost doctor`** reports which wiring state you are in.

### How to back out

| scope | how |
|---|---|
| one run | `ROOST_NO_SHIM=1 claude` |
| one session | `roost wiring off -t SESSION` |
| the whole server | `roost wiring off`, or `set -g @roost-wiring-enabled off` |
| everything | `roost wiring remove`, then restart the server |

Your own tmux `default-command` also wins over roost's.

### Notes

- **Your existing `roost install` hooks can stay.** They name the same commands
  as the generated file, so each hook still runs once. `roost doctor` warns if
  they point at a different checkout.
- Panes opened before the upgrade keep their old shell until they are reopened.
- Known limits, including a `claude` alias to an absolute path, are in
  `docs/known-gaps.md`.

## [0.3.0]

One new feature: output that programs can read. No upgrade step is needed.

### Added

- **`--json` on `roost status`, `whoami`, `read`, `screen`, and `state`** (#41).
  Every document carries `"schema": 1`. Without `--json`, the output and every
  exit code are exactly as before.
  - `roost state STATE --json` sets the badge as before, then prints what
    actually landed, so a script can see a badge that did not stick.
  - Under `--json`, a command that fails prints nothing on stdout. The exit
    code and the error message are the same as without `--json`.
  - Under `--json`, a blank screen exits 0 with `"text": ""`. Without `--json`
    it still exits 1 for now (#69).

### Known limits

- `roost state STATE --json` reports `"recorded": false` when the badge is set
  for a whole window or globally rather than on the pane.
- `wait-done --json` is not included yet.
- Not yet measured with gawk, or with tmux 3.4.
- The full list is in `docs/known-gaps.md`.

## [0.2.2]

Two small fixes. No upgrade step is needed.

### Added

- **`roost doctor` now starts with the roost version** (#47). That is the
  report people paste into a bug. If the version cannot be read, it says so
  and says what failed.

### Fixed

- **`roost wait-done` no longer loops forever when its timeout is not a whole
  number** (#66). A value like `abc`, `1.5` or `-5` is now refused at once,
  with a message that names the bad value.

### Changed

- An **empty** timeout for `wait-done` is now refused. It used to mean "no
  limit". Leaving the timeout out still means no limit.
- A timeout with leading zeros is read as decimal: `010` is 10 seconds, not 8.

## [0.2.1]

Two more fixes to how roost reports an agent's state. One changes an exit code,
and one needs a step from you after you upgrade.

### Upgrade steps

- **Claude Code:** re-run `roost install`. It adds a `StopFailure` hook to
  Claude's settings. Until you do, a turn that fails on an API error still
  shows ⏳ working, and `roost doctor` says so. Claude hooks need no trust prompt.

### Changed

- **`roost wait-done` exits 2 when its target is gone or its agent died** (#54).
  Before, a pane or window that no longer existed made it exit **0**, so a dead
  helper looked finished. A script that treats any 0 as "finished" will now see
  2 for a dead helper. Exit 0 and 1 keep their meanings: done, and error or
  timeout. A pane seen ✅ done during the wait that then closes is still 0.

### Fixed

- **A Claude Code turn that fails on an API error now shows 💥 error, not ⏳
  working forever** (#55). This covers a rate limit, a server error, an unknown
  model and an unreachable API. `roost wait-done` exits 1 and names the kind of
  error, and `roost read` prints it.
- **`roost wait-done` no longer misses a one-shot agent's ✅ done.** It now
  checks every quarter second, because a one-shot pane can close about half a
  second after it finishes (#54).

### Known limits

- An agent killed **inside a shell** in its pane still makes `wait-done` time
  out with exit 1. The pane stays alive, so tmux cannot see the death. Tracked
  as a follow-up issue.
- Pressing Esc while Claude is still writing a reply leaves ⏳ working. Claude
  fires no hook for it.
- The full list is in `docs/known-gaps.md`.

## [0.2.0]

Two fixes to how roost reports an agent's state. Both change behaviour, and
one needs a step from you after you upgrade.

### Upgrade steps

- **codex:** codex asks "Hooks need review" once more, for a new `Interrupt`
  hook. Answer "Trust all and continue". Until you do, a declined permission
  dialog still leaves 🛑 blocked, and `roost doctor` says so.
- **Claude Code:** re-run `roost install`. It adds `--notification-hook` to the
  `Notification` hook. Without it, a Claude pane does not recover from a
  declined dialog.

### Fixed

- **A declined or dismissed permission dialog no longer leaves a pane 🛑
  blocked forever** (#62). Before, `roost send` refused the pane with exit 3,
  `roost wait-done` ran to its timeout, and `roost read` called a current reply
  stale.
  - codex: the new `Interrupt` hook moves the pane to 💤 idle.
  - Claude Code fires no hook at all when you answer No or press Esc. roost now
    reads Claude's own transcript when a command needs to know, and clears the
    badge only when the newest records are Claude's decline records for that
    same turn. It never reads the screen.
  - copilot 1.0.83 already recovers on Esc by itself.
- **A codex turn that ends with no reply now shows 💥 error, not ✅ done**
  (#53). `roost wait-done` exits 1 and names the reason, and `roost read`
  prints it.

### Added

- `roost doctor` names panes that have been 🛑 blocked for 10 minutes or more
  with no dialog on screen, as "may be stuck". It only reports. It never
  changes a badge.

### Known limits

- The codex 💥 error is inferred from a `Stop` with an empty reply. A real dead
  turn has not yet been captured live.
- Claude's transcript format is not a public contract. If a Claude upgrade
  changes its decline records, recovery quietly stops and the pane stays 🛑, as
  it did before this release. `tests/live/claude-decline-smoke.sh` catches that
  change when it is run.
- A Claude dialog answered in under about 6 seconds is never badged 🛑, because
  Claude's `Notification` hook arrives about 6 seconds after the dialog opens.
- `roost wait-done` exits 0 on an interrupted turn.
- The full list is in `docs/known-gaps.md`.

## [0.1.0]

The first numbered version. There is no earlier versioned history to
summarise: this entry marks where versioning starts, not a reconstruction of
everything that came before it.

Roost is a tmux wrapper for running and coordinating AI coding agents:

- Its own isolated tmux server (`-L roost`) with a badge per pane
  (💥 error · 🛑 blocked · ⏳ working · ✅ done · 💤 idle), driven by hooks for
  Claude Code and Codex and by an adapter for opencode, copilot and pi
- Session and window management (`up`, `session`, `new`, `spawn`, `split`,
  `whoami`, `status`, `kill`) and a status/switcher view that rolls up across
  every session on the server
- Agent-to-agent coordination: `send` (typed and verified, not just fired),
  `read`/`screen`, `reply`, and `wait-done` for blocking on another agent's
  state
- `ssh` to run roost against agents on a remote host, driven from here
- `install`/`update` to wire every installed agent (opencode, pi, copilot,
  claude, codex) to a checkout, `init` for first-time setup, and `settings`
  for live theme/glyph/notification changes
- `doctor` for preflight checks and `validate` for a fuller report a tester
  can hand back

### Extensions

- `roost ext` — install an extension from a GitHub repository, pinned to a full
  commit SHA, with `list`, `info`, `verify`, `update` and `remove`. An extension
  adds subcommands; a core command can never be shadowed by one.
- Extension contract 1: commands only. An extension declares in its manifest
  what authority it asks for, and roost withholds the socket and its own scripts
  unless the manifest asks for `fleet`. The declaration makes intent visible
  when you are asked to install; it does not confine what the extension does
  once it runs.
- Three ways to turn extensions off: `ROOST_NO_EXT` set to any non-empty value,
  `set -g @roost-ext-enabled off` in `roost.conf`, or `roost ext remove`.
- Docs: [Extensions](https://roosting.dev/docs/extensions) — what roost checks
  when you install one (that it is the exact commit you agreed to, and what the
  extension declared it wants to reach) and what it does not check (whether the
  code is honest, and what it does once you run it).
- Docs: [Writing an Extension](https://roosting.dev/docs/writing-an-extension) —
  the manifest schema, the environment a command is handed, the socket idiom,
  what declaring `fleet` costs your users, and how to install your own work from
  a bare repository on your disk before you publish it.
