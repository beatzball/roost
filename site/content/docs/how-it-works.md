---
title: How It Works
description: The isolated tmux server, pane-scoped badges, and what each file in the repo does.
sidebar:
  order: 6
---

## The isolated server

`bin/roost` starts `tmux -L roost -f tmux/roost.conf` — a second tmux server, fully separate from your default one (different socket, different config). Your everyday tmux is never read and never written.

## Pane-scoped badges

`tmux/roost.conf` badges each window from its **panes**: one glyph per distinct agent state present, urgency-ordered and deduplicated, computed live from `#{P:}` so a pane dying never leaves a stale badge.

Glyphs are shape-distinct (not just colour-distinct), so the bar still reads correctly if you are colourblind. Backgrounds mark only which window is **active**, which keeps every tab's text high-contrast.

Claude hooks call `scripts/roost-agent-state <state>`, which stamps the **pane** identified by `$TMUX_PANE`, then repaints. The opencode plugin and the GitHub Copilot CLI extension reach the same stamp through the public `roost state` and `roost reply` commands, so no adapter carries tmux knowledge of its own. Pane scope is what lets two agents share one window — `roost split` puts a second agent beside the first without either clobbering the other's badge.

A pane is an agent only if it has been stamped, so a plain shell or a `tail -f` never badges anything.

## Repo layout

```
bin/roost                   # launcher / CLI (up, session, new, spawn, split, whoami,
                            #   ssh, send, read, screen, reply, wait-done, state,
                            #   hooks, doctor, validate, install, update, init,
                            #   settings, status, kill)
tmux/roost.conf             # the isolated agent-view config
scripts/roost-agent-state   # hook target that records agent state
                            #   (+ elapsed-time stamp, block notify, and the
                            #    turn's reply from the Stop payload)
scripts/roost-status        # status-bar roll-up of agent-pane counts
scripts/roost-switch        # fzf agent switcher, panes grouped by window (prefix a)
scripts/roost-notify        # cross-platform desktop notification delivery
scripts/roost-doctor        # preflight checks (tmux version, truecolor, fzf, JSON
                            #   reader, hooks, adapter links, notifier)
scripts/roost-init          # setup wizard (theme, glyphs, separator style, prints hooks)
scripts/roost-install       # `roost install` / `roost update`: wire every installed
                            #   harness to this checkout (symlinks + hook files)
scripts/roost-settings      # live settings TUI (prefix S)
scripts/roost-next-blocked  # select the pane that needs you: error, else blocked (prefix b)
scripts/roost-themes.sh     # built-in theme palettes
scripts/lib/roost-config.sh # shared config helpers
                            #   (surgical writer, glyph/sep maps, live-apply)
scripts/lib/roost-reply.sh  # how a reply is truncated to fit tmux's command cap
scripts/lib/roost-socket.sh # the one place that answers "which tmux server am I in?"
adapters/opencode/roost.js  # opencode plugin: state + the turn's reply
adapters/copilot/extension.mjs  # GitHub Copilot CLI extension, same two jobs
```

Requires `fzf` for the `prefix a` switcher (it degrades to a hint if missing); everything else is plain tmux and bash.

This layout is also in the repo `README.md`, which is where contributor-facing notes belong — see [Contributing](https://github.com/beatzball/roost#contributing) for building, testing and the live adapter smoke tests.
