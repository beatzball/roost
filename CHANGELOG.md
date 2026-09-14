# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

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
