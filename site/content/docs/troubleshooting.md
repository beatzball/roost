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

It checks your tmux version, truecolor support, `fzf`, the notifier, the Claude hooks, the opencode plugin link, and the GitHub Copilot CLI extension link — and prints the exact fix command for your checkout. For copilot it also checks the feature flag that extensions sit behind, and reminds you of a consent prompt it cannot check from disk (see below).

## Badges never appear

The view works without badges; badges need a hook. Check, in order:

1. `roost hooks` output is merged into `~/.claude/settings.json` under `"hooks"`. See [State Badges](/docs/state-badges).
2. You are running the agent **inside** a roost pane. `scripts/roost-agent-state` is a deliberate no-op outside one.
3. For opencode or GitHub Copilot CLI, the adapter is linked — run `roost doctor`, which prints the exact `ln -s` for your checkout. See [State Badges](/docs/state-badges).
4. For any other agent, it must call `roost state <state>` itself.

## A copilot pane never badges, and copilot says nothing

Two gates stand in front of the copilot extension, and **neither one tells you when it is not met** — the turn runs normally and the pane just stays blank. `roost doctor` checks the first; the second it can only remind you about.

1. **Extensions are off by default.** Launch your panes as `copilot --experimental`, or put `{"enabledFeatureFlags": {"EXTENSIONS": true}}` in `~/.copilot/settings.json`. Without one of them copilot never reads the adapter.
2. **Copilot asks once per directory** to approve the extension — *"wants to: handle permission requests"*. Answer **Yes**. Denying it stops the extension loading, and choosing "Yes" persists nothing, so a new worktree asks again. There is no global pre-approval.

Take the blank badge seriously rather than living with it. `roost send` refuses a 🛑 blocked target so one agent cannot type into another's permission dialog — and an unbadged pane is not blocked, so that refusal never fires. A copilot pane whose extension never loaded, sitting at a permission prompt, will take a `roost send` straight into that dialog.

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

## doctor warns about the error glyph

There are two different warnings here, and each says only what it found in your config.

**"has no `@roost-glyph-error` line"** — you picked `ascii` or `nerd` glyphs before the `error` state existed, so your config has four glyph lines and the error badge falls back to the built-in 💥: an emoji in a bar you chose not to have emoji in. Fix: re-pick your glyph set in `roost settings`, which writes all five.

**"sets `@roost-glyph-error` to ... where the set's own error glyph is ..."** — your config has an error glyph that is not the one your set uses. If you chose it yourself, there is nothing to fix. If you did not, re-pick your glyph set in `roost settings`.

Neither ever fails doctor.

`roost init` fills the missing glyph in for you when it migrates an old `~/.config/amux/amux.conf` — but only when your other four glyphs exactly match one of the named sets, so a hand-picked set is never overwritten with something you did not choose.

## Notifications never fire

Only `blocked` and `error` notify. `done` fires every turn and would be noise, so it is deliberately silent.

If neither fires, set `@roost-notify-backend` explicitly (`tmux` always uses the in-tmux message) or plug in your own `@roost-notify-cmd`. See [Notifications](/docs/setup).

## Still stuck

Open an issue at [github.com/beatzball/roost](https://github.com/beatzball/roost/issues). Maintainer-facing notes on shipped risks live in `docs/known-gaps.md` in the repo.
