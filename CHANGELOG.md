# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-09-08

First tagged release. There is no earlier tagged history to summarise: this
entry marks where versioning starts, not a reconstruction of everything that
came before it.

Roost, as of this release, is a tmux wrapper for running and coordinating AI
coding agents:

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
