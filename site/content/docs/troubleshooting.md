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

The view works without badges; badges need a hook or an adapter. **The one
command that fixes most of this is `roost install`** — it wires every installed
harness to your checkout, is safe to re-run, and `roost doctor` ends every
warning it can resolve with `, or run: roost install`. A warning without that
tail is one no installer may fix: something that is not roost's sitting at an
adapter path, a hook pointing at a different checkout, or a prompt only you can
answer. What it does **not** do is fetch new roost code — if the adapter you
need shipped in a later release, upgrade first by re-running the install
command ([Getting started](/docs/getting-started)). Run that from a directory
that is not itself a roost clone, and check that the path in its first two
lines is the checkout your agents are wired to. If `roost install` has been run
and a pane still does not badge, check, in order:

1. `roost hooks` output is merged into `~/.claude/settings.json` under `"hooks"`. See [State Badges](/docs/state-badges).
2. You are running the agent **inside** a roost pane. `scripts/roost-agent-state` is a deliberate no-op outside one.
3. For opencode, pi or GitHub Copilot CLI, the adapter is linked — run `roost doctor`, which prints the exact `ln -s` for your checkout. See [State Badges](/docs/state-badges).
4. For codex, `~/.codex/hooks.json` is written **and** you have answered *"Trust all and continue"* at codex's own `Hooks need review` prompt. That answer is one of the two steps `roost install` cannot do for you.
5. For any other agent, it must call `roost state <state>` itself.

## A copilot pane never badges, and copilot says nothing

Two gates stand in front of the copilot extension, and **neither one tells you when it is not met** — the turn runs normally and the pane just stays blank. `roost doctor` checks the first; the second it can only remind you about.

1. **Extensions are off by default.** `roost install` turns the flag on for you. By hand: launch your panes as `copilot --experimental`, or put `{"enabledFeatureFlags": {"EXTENSIONS": true}}` in `~/.copilot/settings.json`. Without one of them copilot never reads the adapter.
2. **Copilot asks once per directory** to approve the extension — *"wants to: handle permission requests"*. Answer **Yes**. Denying it stops the extension loading, and choosing "Yes" persists nothing, so a new worktree asks again. There is no global pre-approval, and this is the one copilot gate no installer can pass for you.

Take the blank badge seriously rather than living with it. `roost send` refuses a 🛑 blocked target so one agent cannot type into another's permission dialog — and an unbadged pane is not blocked, so that refusal never fires. A copilot pane whose extension never loaded, sitting at a permission prompt, will take a `roost send` straight into that dialog.

## A finished agent shows red

Your `Notification` hook is missing the `permission_prompt` matcher. Unmatched, it also fires for `idle_prompt` and `auth_success`, so a finished agent goes blocked. Re-run `roost hooks` and compare.

## A window stays red after you approve a permission

Your `PostToolUse` hook is missing. No hook fires when you answer a permission dialog, so `PostToolUse` is the first observable event after approval — it is what clears 🛑.

## `roost send` fails

The exit code tells you which failure it is:

- **exit 3** — the target's badge says 🛑 blocked, so `send` refused rather than typing into a permission dialog. Answer the dialog and retry the same target. If the pane has no dialog on it, see [A pane refuses every send but has no dialog](#a-pane-refuses-every-send-but-has-no-dialog) below.
- **exit 2** — the target does not exist or its pane is dead. Re-resolve the target.
- **exit 1** with a `roost send:` message — delivery to a valid target failed. Retry the same target or look at the pane; do not re-resolve.
- **exit 1** with a `usage:` message — a missing argument. That is a caller bug.

## A pane refuses every send but has no dialog

`roost send` exits 3 and says a permission dialog is open, but the pane is sitting at an empty prompt.

The badge is stale. A Claude Code turn that ends **at** a permission dialog — you answered `No`, or pressed Esc — fires no `PostToolUse` and no `Stop`, so the 🛑 that the `Notification` hook stamped is never cleared. Answering **Yes** does clear it, because the tool then runs and `PostToolUse` fires.

Check it rather than assuming, and read the badge and the screen in the *same* moment — a badge you read seconds before a screen tells you nothing:

```sh
roost status | grep '%12'    # the badge
roost screen %12 20          # what is actually on the pane
```

If there is no dialog on the screen, any of these clears it:

- type anything into the pane yourself — the next `UserPromptSubmit` re-stamps it
- `roost send --force %12 "…"` — safe *once you have looked* and seen no dialog
- `roost state working` from inside that pane

`roost wait-done` will not rescue you here: it counts `blocked` as busy, so it waits out its timeout. This is a known gap, recorded in `docs/known-gaps.md` in the repo.

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

```sh
roost validate
```

`roost doctor` reads your configuration. `roost validate` **drives** it, and writes the report for you — the environment and every version, `roost doctor` verbatim, both offline test suites with their exit codes, and a real end-to-end drive of every agent harness you have installed: it starts each one in a throwaway roost server, asks it a question, samples the badge over time, checks that `roost read` returns the reply where `roost screen` returns the screen, and drives a permission dialog where the harness has one. It ends by printing one file to send us. Nothing in it needs filling in.

**Each harness runs the way you normally run it** — your own configuration, your provider, your account. That is the point: a small local model barely calls tools, and tool calls are what drive `PostToolUse`, permission dialogs and the ⏳→🛑→⏳ transitions the badges are almost entirely about. So the run **costs you a little money** — roughly three one-line prompts per harness — and it says so before it starts.

**No accounts at all?** `roost validate --opencode-cloud` drives opencode against one of opencode's own free cloud models. Those need **no account and no key** — `opencode auth list` can report zero credentials and they still work — and they are a real remote provider, so unlike a local model they have real network latency and call tools readily. For opencode this is the better fallback: measured, a free cloud model reached a permission dialog in 3–4 seconds where a local 3B model took 55 and often would not call a tool at all. It affects opencode only, and costs nothing.

`roost validate --local` drives a local [ollama](https://ollama.com) instead and spends nothing. It is the fallback for a machine with no accounts wired, and it tests our rig rather than your setup; the report records which mode each harness actually used, because a report that does not say that is nearly worthless to us.

It takes a while, so start it and walk away. Every wait is bounded, so it cannot sit there forever, and it writes the report even when something fails. A wait that runs out is reported as a **timeout**, not as a failure — against a real account a turn with tool calls can take minutes.

It asks **one** question first. If a roost adapter symlink is missing — the install step `roost doctor` already prints — it lists what it would create and asks once, for all of them together. Say yes and it links them and tests those harnesses; say nothing and after 60 seconds it takes that as no and skips them, exactly as before. It creates **symlinks and nothing else**: no hooks file, no codex trust, no settings change, no provider configuration. The report lists every link it made with a one-line `rm` to undo it. `--install` and `--no-install` answer it up front for an unattended run, which otherwise defaults to no.

What it will not do:

- **Touch your tmux.** It runs its own server on its own socket in a temp directory and tears it down at the end, including when it fails.
- **Replace a file you put there.** If something that is not this checkout's adapter already sits where a symlink would go — your own extension, or a link to a checkout you deleted — it leaves it alone, names it in the report, and skips that harness.
- **Change your configuration beyond those symlinks.** It reads what each harness already has and writes none of it. A missing **provider** is never something it arranges: that is your account, and the harness is skipped with that as the reason.
- **Log in to anything.** It uses the credential already on your machine and never asks for one. The free cloud tier needs none in the first place.
- **Send your home directory to us.** Absolute paths, your username and your hostname are substituted before anything is written, and the report says so. Pass `--keep-home-paths` if you would rather send it raw.

Claude Code is the one harness it will not drive: there is no way to isolate its configuration without taking the credential with it.

One thing worth knowing before you read your own report: **the real-provider path has never run on our machines**, because none of them has an account wired for these harnesses. Everything we tested took the `--local` path. If a result looks odd, treat it as a genuine finding and tell us rather than assuming it is your setup.

`roost validate --quick` skips the slowest part (this repo's own ollama-based smoke suites) and still produces a full report.

Then open an issue at [github.com/beatzball/roost](https://github.com/beatzball/roost/issues) and attach it. Maintainer-facing notes on shipped risks live in `docs/known-gaps.md` in the repo.
