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

## GitHub Copilot CLI

**GitHub Copilot CLI** has an adapter in this repo. Symlink it into place:

```sh
mkdir -p ~/.copilot/extensions/roost
ln -s "$HOME/path/to/roost/adapters/copilot/extension.mjs" ~/.copilot/extensions/roost/extension.mjs
```

A symlink rather than a copy, so updating roost updates the extension. `roost doctor` prints this exact command with the real path for your checkout.

The directory name is yours; the file name is not — copilot looks for `extension.mjs` and nothing else. User scope (`~/.copilot/`) rather than a project's `.github/extensions/` matters: only user scope is loaded in both interactive and `copilot -p` mode.

**Two things gate it, and both are silent when they are not met.** `roost doctor` checks the first and reminds you of the second.

1. **Extensions are off by default.** Either launch your panes as `copilot --experimental`, or put this in `~/.copilot/settings.json`:

   ```json
   { "enabledFeatureFlags": { "EXTENSIONS": true } }
   ```

   Without one of them copilot never reads the adapter, and says nothing about having skipped it.

2. **Copilot asks once per directory** to approve the extension — *"wants to: handle permission requests"*. Answer **Yes**. Denying it stops the extension loading; there is no global pre-approval, so a new worktree asks again.

That second dialog is the price of the 🛑 badge, and it is worth being clear about why. Copilot only tells an extension a permission dialog has opened if that extension registers a permission handler — so without one, a pane sits on ⏳ working while you stare at a prompt, and `roost send` will happily type into it. roost registers the handler and returns the SDK's observe-only result: it sees the dialog and badges the pane, and **your dialog still opens and you still choose**. roost never answers a permission prompt.

| copilot signal | state |
|----------------|-------|
| `assistant.turn_start` | ⏳ working |
| a permission dialog, or an `ask_user` question | 🛑 blocked |
| your answer to either | ⏳ working |
| `session.error` | 💥 error |
| `session.idle` | ✅ done |

`roost read` returns the agent's own last answer, not a scrape of its screen — copilot is a full-screen TUI, so a scrape returns its input box and footer.

`tests/live/copilot-smoke.sh` drives real copilot against a local model to check the adapter end to end. It is not part of `tests/run.sh` — run it by hand after a copilot upgrade. It needs no GitHub account: it points copilot at a local ollama, which turns off the requirement.
