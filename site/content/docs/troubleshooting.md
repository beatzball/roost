---
title: Troubleshooting
description: Start with roost doctor, then the handful of things that actually go wrong.
sidebar:
  order: 7
---

## Start here

```sh
roost doctor
```

It checks your tmux version, truecolor support, `fzf`, the notifier, the Claude hooks, and the opencode plugin link — and prints the exact fix command for your checkout.

## Badges never appear

The view works without badges; badges need a hook. Check, in order:

1. `roost hooks` output is merged into `~/.claude/settings.json` under `"hooks"`. See [State Badges](/docs/state-badges).
2. You are running the agent **inside** a roost pane. `scripts/roost-agent-state` is a deliberate no-op outside one.
3. For a non-Claude agent, it must call `roost state <state>` itself.

## A finished agent shows red

Your `Notification` hook is missing the `permission_prompt` matcher. Unmatched, it also fires for `idle_prompt` and `auth_success`, so a finished agent goes blocked. Re-run `roost hooks` and compare.

## A window stays red after you approve a permission

Your `PostToolUse` hook is missing. No hook fires when you answer a permission dialog, so `PostToolUse` is the first observable event after approval — it is what clears 🛑.

## `roost send` fails

The exit code tells you which failure it is:

- **exit 2** — the target does not exist or its pane is dead. Re-resolve the target.
- **exit 1** with a `roost send:` message — delivery to a valid target failed. Retry the same target or look at the pane; do not re-resolve.
- **exit 1** with a `usage:` message — a missing argument. That is a caller bug.

## `roost wait-done` exits non-zero

A non-zero exit means **error or timeout**, distinguished by the message. An errored pane prints `roost: '<target>' is in error state, not done` and exits 1. `wait-done` deliberately does not count "stopped being busy" as success.

## `prefix a` does nothing

The agent switcher needs `fzf`. Without it, the binding degrades to a hint. Install `fzf` and it works.

## The tab separators look wrong

You need a powerline or Nerd Font. Or run `roost settings` and pick the plain-separator style — it applies live, no restart.

## doctor warns about a glyph mismatch

If you picked `ascii` or `nerd` glyphs before the `error` state existed, your config has four glyph lines and no `@roost-glyph-error`, so it inherits the default 💥 — an emoji in a bar you chose not to have emoji in.

Fix: re-pick your glyph set in `roost settings`, which writes all five.

This warning names one likely cause and can be wrong for you — if you set a custom error glyph on purpose, it is a warning, not a failure.

## Notifications never fire

Only `blocked` and `error` notify. `done` fires every turn and would be noise, so it is deliberately silent.

If neither fires, set `@roost-notify-backend` explicitly (`tmux` always uses the in-tmux message) or plug in your own `@roost-notify-cmd`. See [Notifications](/docs/setup).

## Still stuck

Open an issue at [github.com/beatzball/roost](https://github.com/beatzball/roost/issues). Maintainer-facing notes on shipped risks live in `docs/known-gaps.md` in the repo.
