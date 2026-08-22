---
title: State Badges
description: Wire Claude Code hooks, or report state from any other agent, so the tabs show what each agent is doing.
sidebar:
  order: 5
---

## Claude Code (one-time)

The badges are driven by four Claude Code hooks. Print the snippet:

```sh
roost hooks
```

Merge it into your `~/.claude/settings.json` (under `"hooks"`). It wires:

| Claude hook | state |
|-------------|-------|
| `UserPromptSubmit` | ⏳ working |
| `Notification` (matcher: `permission_prompt`) | 🛑 blocked |
| `PostToolUse` | ⏳ working |
| `Stop` | ✅ done |

Two of those are subtler than they look:

- **`Notification` must be scoped to `permission_prompt`.** Unmatched, it also fires for `idle_prompt` and `auth_success` — so a *finished* agent would go red.
- **`PostToolUse` is what clears 🛑.** No hook fires when you answer a permission dialog, so it is the first observable event after you approve. Without it a window stays red from your approval until the whole turn ends.

`scripts/roost-agent-state` is a **no-op unless it runs inside a roost pane**, so it is safe in your global Claude settings — running `claude` elsewhere does nothing. It also returns early when the state is already correct, which keeps it cheap on `PostToolUse` (that fires on every single tool call, and Claude waits for the hook to exit).

## Any other agent

Badges are not Claude-only. Any agent can report its state through one public command:

```sh
roost state working    # or: blocked, done, error, idle
```

It reads `$TMUX_PANE` to find its own pane, and does nothing at all outside a roost session — so it is safe to wire into a global config.

## opencode

**opencode** has an adapter in this repo. Symlink it into place:

```sh
mkdir -p ~/.config/opencode/plugin
ln -s "$HOME/path/to/roost/adapters/opencode/roost.js" ~/.config/opencode/plugin/roost.js
```

A symlink rather than a copy, so updating roost updates the plugin. `roost doctor` prints this exact command with the real path for your checkout, so run that if you are unsure what to fill in — it also confirms once the plugin is linked.

`tests/live/opencode-smoke.sh` drives real opencode against a local model to check the adapter end to end. It is not part of `tests/run.sh` — run it by hand after an opencode upgrade.
