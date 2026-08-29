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

## pi

**pi** has an adapter in this repo. Symlink it into place:

```sh
mkdir -p ~/.pi/agent/extensions
ln -s "$HOME/path/to/roost/adapters/pi/roost.ts" ~/.pi/agent/extensions/roost.ts
```

A symlink rather than a copy, so updating roost updates the extension. `roost doctor` prints this exact command with the real path for your checkout.

The file name is yours; the `.ts` is not — pi discovers `*.ts` (and `*/index.ts`) and loads it through jiti, so there is no build step. Install it globally under `~/.pi/agent/` rather than in a project's `.pi/extensions/`: a project-local extension loads only after you have trusted that project, so a fresh worktree would badge nothing and say nothing about why.

| pi signal | state |
|-----------|-------|
| `agent_start` | ⏳ working |
| a `confirm` / `select` / `input` / `editor` dialog opening mid-turn | 🛑 blocked |
| that dialog closing | ⏳ working |
| `agent_settled`, last assistant message `stopReason: "error"` | 💥 error |
| `agent_settled`, anything else | ✅ done |

`roost read` returns the agent's own last answer, not a scrape of its screen — pi is a full-screen TUI, so a scrape returns its input box and token counter.

### 🛑 blocked will not appear on a stock pi

**pi ships no permission prompts.** That is a deliberate design choice, not a gap — [pi's own docs](https://github.com/earendil-works/pi) list "permission popups" among the things it intentionally omits, alongside MCP, sub-agents and plan mode. pi runs `bash` without asking.

So nothing on a stock pi install ever asks you a question mid-turn, and a pi pane never goes 🛑. What that costs you, precisely:

- **`roost next-blocked` will never find a pi pane.** Nothing is waiting for you, so there is nothing to jump to.
- **`roost send` will never refuse a pi pane with exit 3.** That refusal exists so one agent cannot type into another's permission dialog. A pi pane has no dialog to type into, so a pi pane is always safe to send to — the refusal is not missing, it is not needed.

If you install a permission gate of your own — pi ships `examples/extensions/permission-gate.ts` as the pattern — roost sees its dialog and badges the pane 🛑 for as long as it is open. That works because pi hands every extension the same `ctx.ui` object, so roost can watch a dialog it did not raise. **roost never answers one.** It calls your gate's dialog and returns exactly what your gate returned; you still choose.

### A `pi -p` or `--mode json` pane is not badged

The adapter reports only when a human is attached to the pane (pi's `ctx.hasUI`, which is true in interactive and RPC mode and false in `-p` print mode and `--mode json`).

That is not caution about drawing to a headless terminal. pi's sub-agent pattern — its shipped `examples/extensions/subagent/` — runs each sub-agent as a **separate `pi --mode json -p` process**, and a child process inherits its parent's `$TMUX_PANE` and loads the same global extensions. Without the gate every sub-agent would badge the pane it was launched from, stamping ✅ done while the real agent was still working, and publishing its own answer as the pane's reply.

The price is that a pane where you type `pi -p "…"` yourself stays unbadged. Report state by hand there, the way any other harness does:

```sh
roost state working && pi -p "…" && roost state done
```

`tests/live/pi-smoke.sh` drives real pi against a local model to check the adapter end to end. It is not part of `tests/run.sh` — run it by hand after a pi upgrade. It needs no account: it points pi at a local ollama.
