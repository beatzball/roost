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

Claude hooks call `scripts/roost-agent-state <state>`, which stamps the **pane** identified by `$TMUX_PANE`, then repaints. Pane scope is what lets two agents share one window — `roost split` puts a second agent beside the first without either clobbering the other's badge.

A pane is an agent only if it has been stamped, so a plain shell or a `tail -f` never badges anything.

## Repo layout

```
bin/roost                   # launcher / CLI (up, new, ssh, send, read, wait-done,
                            #   hooks, doctor, init, settings, status, kill)
tmux/roost.conf             # the isolated agent-view config
scripts/roost-agent-state   # hook target that records agent state
                            #   (+ elapsed-time stamp, block notify)
scripts/roost-status        # status-bar roll-up of agent-pane counts
scripts/roost-switch        # fzf agent switcher, panes grouped by window (prefix a)
scripts/roost-notify        # cross-platform desktop notification delivery
scripts/roost-doctor        # preflight checks (tmux version, truecolor, hooks, notifier)
scripts/roost-init          # setup wizard (theme, glyphs, separator style, prints hooks)
scripts/roost-settings      # live settings TUI (prefix S)
scripts/roost-next-blocked  # select the pane that needs you: error, else blocked (prefix b)
scripts/roost-themes.sh     # built-in theme palettes
scripts/lib/roost-config.sh # shared config helpers
                            #   (surgical writer, glyph/sep maps, live-apply)
```

Requires `fzf` for the `prefix a` switcher (it degrades to a hint if missing); everything else is plain tmux and bash.
