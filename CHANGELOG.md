# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

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
