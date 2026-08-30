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

One thing to check before you rely on it: the plugin runs **inside the opencode process that owns the pane**, which is how it knows which pane to badge. A plain `opencode` in a roost pane is exactly that. `opencode attach` against a detached `opencode serve` is not — there the plugin runs in the server, and the pane you are looking at is never badged.

| opencode signal | state |
|-----------------|-------|
| `session.status` type `busy` | ⏳ working |
| `permission.asked` | 🛑 blocked |
| `permission.replied` | ⏳ working |
| `session.status` type `retry`, the first in a row | ⏳ working |
| `session.status` type `retry`, the second in a row | 💥 error |
| `session.error` | 💥 error |
| `session.error` because **you** pressed Esc | ✅ done |
| `session.idle` | ✅ done, plus the turn's reply |

`roost read` returns the agent's own last answer, not a scrape of its screen — opencode is a full-screen TUI, so a scrape returns its input box and footer. The reply is the last piece of assistant **text** in the turn. Three things arrive on that same event and are all excluded: the model's reasoning, your own prompt, and text opencode injects itself.

**Four things about this table are unlike the other harnesses,** and they are worth knowing because they change what a badge means.

**One retry is not an error.** opencode retries a failing provider several times inside a single turn. The first retry keeps the pane ⏳ working, because a single retry is often a blip that heals itself; only a second consecutive retry turns it 💥. So a pane that flickers and recovers never goes red, and a pane that is genuinely stuck goes red once and stays there rather than flapping.

**Pressing Esc ends a turn ✅ done, not 💥 error.** opencode reports your interrupt through the same channel as a real failure. Badging your own keystroke as a crash — and sending you a desktop notification about it — would be worse than saying nothing, so roost reads that one case as a finished turn.

**A dead turn stays 💥 and does not flip back to ✅.** opencode emits its ordinary end-of-turn signal *after* it reports the error, a minute or so later. roost swallows that one, so the badge you are left with is the one that tells you to look. The related consequence is in the next section.

**A subagent's work does not badge your pane, but its questions do.** When a turn delegates to a subagent, the child's own start, finish and speech arrive on the same stream as the parent's, and unfiltered they would stamp your pane ✅ done partway through the turn and publish the child's answer as yours. Those are filtered out. A subagent's **permission dialog** is deliberately not filtered: the human who has to answer it is sitting at this pane, so it still badges 🛑.

### What 💥 error means for `roost wait-done`

`roost wait-done` does not treat an errored pane as finished. It prints `roost: '<target>' is in error state, not done` and exits 1, rather than reporting success on a turn that produced nothing.

That matters most in a script. If you loop `roost wait-done` over several agents, a non-zero exit now means **error *or* timeout**, and the message tells you which. Under `set -e` a script will stop on a dead agent rather than carrying on, which is the intended behaviour but a change in flow if you had assumed non-zero meant "still busy, try again".

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
## OpenAI Codex CLI

**Codex** has an adapter in this repo. Unlike the two above it is not a symlink — codex is wired through hooks, like Claude Code. Print the config:

```sh
roost hooks codex
```

Write the JSON object it prints (not the comment lines — `hooks.json` is strict JSON) into `~/.codex/hooks.json`. Then start `codex` once and answer **"Trust all and continue"** at its `Hooks need review` prompt.

**That second step is not optional, and skipping it looks exactly like success.** Until you answer it, codex skips every hook and says nothing about having done so — your turns run normally and the pane simply never badges. `roost doctor` reads the trust entries and tells you which of the four are missing.

| codex hook | state |
|------------|-------|
| `UserPromptSubmit` | ⏳ working |
| `PostToolUse` | ⏳ working |
| `PermissionRequest` | 🛑 blocked |
| `Stop` | ✅ done, plus the turn's reply |

**`PostToolUse` is what clears 🛑.** No hook fires when you answer a permission dialog, so it is the first observable event afterwards — the same mechanism as Claude Code's.

`roost read` returns the agent's own last answer rather than a scrape of its screen: codex's `Stop` payload carries `last_assistant_message`, spelled exactly as Claude Code spells it.

**Two things this adapter cannot do, and you should know both before you trust the badge.**

1. **A dead turn shows as ✅ done, not 💥 error.** Codex has twelve hook events and none of them reports an error, so a turn that cannot reach its model ends looking finished. If a codex pane goes ✅ suspiciously fast, look at it.
2. **A codex pane never shows 💤 idle.** That is deliberate: an unbadged pane already renders as idle, and codex's `SessionEnd` fires within milliseconds of `Stop` under `codex exec`, so reporting it would erase the ✅ that turn just earned.

**Changing the config yourself will switch the badges off.** Codex stores a hash of each hook entry when you trust it and silently skips any entry that no longer matches — a changed command, or even a changed `timeout`. If you edit `hooks.json`, run `codex` and re-trust through `/hooks`. For the same reason, what `roost hooks codex` prints will not change between roost releases; roost changes `adapters/codex/roost-codex-hook` instead, which codex re-reads every run.

One thing that trust prompt does *not* do: it approves a **path**, not the code at that path. Anyone who can write `adapters/codex/roost-codex-hook` changes what runs, with no second review. That is codex's model, not something roost adds.

`tests/live/codex-smoke.sh` drives real codex against a local model to check the adapter end to end. It is not part of `tests/run.sh` — run it by hand after a codex upgrade. It needs no OpenAI account: it points codex at a local ollama through a small proxy, which turns off the requirement.
