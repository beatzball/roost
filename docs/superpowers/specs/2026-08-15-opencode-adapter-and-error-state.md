# opencode adapter + an `error` state

**Date:** 2026-08-15
**Status:** approved

## Problem

amux badges each pane with its agent's state, and that state comes from Claude
Code lifecycle hooks calling `scripts/amux-agent-state`. Every other agent CLI
shows up as an unbadged pane. The bar answers "which agent needs me?" only for
Claude.

This is increment 1 of multi-harness support: prove the model ports to a second
harness end to end, and let the first real adapter tell us what the design got
wrong before committing to more.

## What was already true

`scripts/amux-agent-state` is **already harness-agnostic**. Its whole contract:
take `working|blocked|done|idle`, read `TMUX`/`TMUX_PANE` from the environment
to find the pane, and no-op unless the tmux socket path ends in `/amux`. Nothing
in the mechanism knows what Claude is.

The Claude coupling is only four things: `amux hooks` prints Claude's
`settings.json` shape, `amux doctor` looks in `~/.claude/settings.json`,
`@amux-name-default` is `"claude"`, and the docs. The state **sink** is generic
and finished. Every harness needs a state **source**.

## Spike findings

Four harnesses were investigated before choosing. Recording the results here
because they were expensive to obtain and two of them are counter-intuitive.

| harness | verdict | states | enablement | verified by |
| --- | --- | --- | --- | --- |
| Claude Code | shipped | 4 | `settings.json` hooks | in production |
| **opencode** | viable | **4** | drop a file in `plugin/` | **live test** |
| pi | viable | 3 | drop a `.ts` in `extensions/` | docs + types |
| GitHub Copilot CLI | **not viable today** | 4 documented, 0 functional | `hooks/*.json` | **live test** |
| aider | likely | 1 | `--notifications-command` | CLI surface only |

Three findings drove the decisions below.

**ACP is a red herring.** Both opencode (`opencode acp`) and Copilot CLI
(`--acp`) can start as Agent Client Protocol servers, which initially looked
like a way to support several harnesses with one adapter. It is not: in ACP mode
the agent is a protocol server driven by an editor, with **no TUI in the pane**.
amux's premise is that you watch an agent's TUI. Adopting ACP would make amux an
ACP client rendering its own UI — a different product. The filter that matters
is therefore: *the state source must work while the agent runs as a TUI.*

**Copilot CLI's hooks are documented but unshipped.** GitHub documents 14 hook
events including `permissionRequest`, explicitly marked "Interactive: Yes for
Copilot CLI". A correctly-schema'd hook in an isolated `COPILOT_HOME` never
fired on v1.0.80, and `--log-level debug` shows plugin activation categories for
`[agents]` and `[skills]` only — there is no `[hooks]` category in the binary.
Sequencing off the documentation would have built increment 1 against a feature
that does not exist. Re-test after `copilot update`; do not advertise support.

**pi has no permission model at all.** Its extensions can express `working` and
`done`, but `blocked` is not an unobserved state — it is inapplicable, because
pi never stops to ask. A three-state harness is not a degraded four-state one.
This shapes increment 2, not this one.

**opencode was verified live.** A plugin dropped into a scratch project's
`.opencode/plugin/` fired at startup in default TUI mode, ran in the *same OS
process* as the TUI (confirmed via `ps`, no detached server), and read
`TMUX_PANE=%0` out of `process.env`, matching the pane it was launched in. A
separate probe confirmed opencode follows **symlinks** when discovering plugins,
and that `import.meta.url` resolves to the real target path.

**opencode needs no account.** A later probe confirmed it runs against a local
ollama model with every XDG home redirected to a scratch directory, so no stored
credential is reachable. This is what makes the live test in §4 possible, and it
is worth recording because "the agent CLI needs auth" is the assumption that
would otherwise rule live testing out for every future adapter.

Known limitation: `opencode attach <url>` against a pre-existing
`opencode serve` breaks the process/pane correspondence — the plugin would run
in the detached server, not the viewing pane. Default TUI launch does not do
this. Documented, not handled.

## Design

### 1. An `error` state

opencode emits `session.error`, and amux's vocabulary has no way to express it.
Rather than folding it into `blocked` or `done`, `error` becomes a fifth
first-class state.

**Urgency ordering.** The tab badge renders one glyph per distinct state present
in a window, ordered by urgency. `error` sorts **first**, ahead of `blocked`: an
agent that fell over is worse news than one waiting on an answer. So a window
holding a crashed agent and a running one reads `💥⏳`.

**Notification.** `error` shares `blocked`'s desktop-notification path — a
transition into `error` on a pane whose window is not active fires
`amux-notify`. Without this, a crash in a background window is silent, which
defeats the point of adding the state.

**Not every harness can report it.** Claude Code's hooks have no error event, so
Claude panes never show `💥`. The state means "this harness told us it broke",
not "nothing is broken elsewhere". This asymmetry is accepted deliberately.

**What "broke" means in practice.** The obvious reading — the agent crashed — is
not the common case. For opencode the dominant trigger is an agent stuck in a
retry loop against a provider it cannot reach, which upstream does not surface as
an error at all (see §3). So `error` is better read as *this agent is not going
to make progress without you*, which is also why it belongs on `blocked`'s
notification path rather than beside `done`.

**Blast radius**, all of which is mechanical:
`@amux-glyph-error` (with a default in `tmux/amux.conf`), the `@amux-tab-badge`
and `@amux-tab-busy` format chains, `@amux-pane-border`'s state→glyph chain,
`scripts/amux-switch`'s glyph function, `scripts/amux-status`'s rollup counters,
all four glyph sets in `scripts/lib/amux-config.sh` (`emoji`, `orbs`, `ascii`,
`nerd`), `scripts/amux-agent-state`'s state normalisation, and the settings TUI's
glyph preview.

### 2. `amux state` as a public command

`scripts/amux-agent-state` becomes reachable as `amux state <state>`, a
documented public interface rather than an internal hook target.

This is the single contract every state source uses: the opencode plugin, a
future pi extension, an agent told to report its own state by
`skills/amux/SKILL.md`, or a user's own script. The existing script stays where
it is — `amux state` dispatches to it — so Claude's configured hooks keep
working untouched.

Its behaviour is unchanged: no-op outside an amux pane, degrade silently on a
dead server, bail early when the state is unchanged.

### 3. The opencode adapter

**Delivery.** The plugin is a tracked file in the repo at
`adapters/opencode/amux.js`. The user symlinks it into opencode's plugin
directory:

```sh
ln -s "$AMUX_HOME/adapters/opencode/amux.js" ~/.config/opencode/plugin/amux.js
```

A symlink rather than a copy so that updating amux updates the plugin — it calls
`amux state`, so a stale copy breaks the moment that interface changes. Verified
that opencode follows the symlink and that `import.meta.url` resolves to the
real file.

**Invocation.** The plugin shells out via opencode's `PluginInput.$` (Bun's shell
API) to `amux state <state>`. It relies on `amux` being on `PATH` inside
opencode's process, which holds for a normal install because opencode inherits
the launching shell's environment. If `amux` is absent the shell-out fails
harmlessly and the pane simply goes unbadged — the plugin must never throw into
opencode's event loop.

**Event mapping.** Everything arrives through the single `event` hook. The
mapping below is what a live opencode 1.18.15 was *observed* to emit, not what
the type definitions suggest — the two disagree in ways that matter.

| signal | amux state |
| --- | --- |
| `session.status`, `status.type === "busy"` | `working` |
| `session.status`, `status.type === "retry"`, 2nd consecutive | `error` |
| `permission.asked` | `blocked` |
| `permission.replied` | `working` |
| `session.idle` | `done` |
| `session.error`, `error.name === "MessageAbortedError"` | `done` |
| `session.error`, any other error | `error` |

Four things in that table were wrong in the first draft of this design, and each
was corrected against a live run or a tracked upstream issue.

**`permission.ask` is a hook that does not fire.** `Hooks` declares
`"permission.ask"?: (input: Permission, output: {status}) => Promise<void>`, and
a plugin registering it sees nothing when a permission dialog appears on screen.
The `permission.asked` **event** is what actually arrives. This is the same trap
Copilot CLI set — a documented interface that is not wired up — caught the same
way, by running it.

**`session.status` is the `working` source, not `tool.execute.before`.**
`tool.execute.before` does fire, but only when a tool runs, and it fires after
the turn has already begun. A turn that answers without calling a tool emits no
`tool.execute.before` at all, so the pane would jump `idle → done` and never show
that the agent was busy. `session.status → busy` fires at prompt submit in both
cases. Verified with a deliberately tool-free turn.

**`session.error` misses the failures that matter.** It is real — a production
plugin, `Mte90/opencode-auto-resume`, handles it and tests it — but it does not
cover the two failures a user actually hits. An unreachable provider produces an
*unbounded retry loop* and no error event
([opencode#17648](https://github.com/anomalyco/opencode/issues/17648), open:
"retries indefinitely with unbounded exponential backoff — no max retries or
circuit breaker"; emitting `Session.Event.Error` there is a *proposed* fix).
Rate-limit 429s produce nothing either
([opencode#10432](https://github.com/anomalyco/opencode/issues/10432), closed
not-planned, the reporter having tried this exact approach). Consecutive `retry`
statuses are therefore the primary `error` source, with `session.error` retained
for the streaming failures it does cover.

**A user abort must not read as a crash.** `session.error` fires with
`error.name === "MessageAbortedError"` when the user presses Esc.
`opencode-auto-resume` special-cases it as `"User abort (ESC)"`. Mapping it to
`error` would badge the user's own keystroke as a crash *and* fire a desktop
notification about it. It maps to `done`.

**Debouncing.** `session.status → busy` fires several times per turn. The plugin
holds the last state it reported and skips the shell-out when unchanged, so a
turn costs one `amux state` call per real transition rather than one per event.
This is separate from `amux state`'s own unchanged-state early-bail; that guards
the tmux round trip, this guards the process spawn.

Debouncing on its own is not enough against a retry loop, though: `busy` and
`retry` interleave (`busy, retry, busy, retry, ...`, see below), and each
`busy` is a distinct event from the `retry` before it, so a `busy` arm that
unconditionally reports `working` produces a *new* transition — `working` —
every time it follows the `error` that the prior `retry` reported. That is a
real transition, not a duplicate, so debouncing does not collapse it: the
badge would flap `working, error, working, error, ...` for the whole loop, and
because a transition *into* `error` notifies, the desktop would ping on every
retry cycle. The fix is not in the debounce; the `busy` arm only reports
`working` while the retry counter is still below `RETRY_THRESHOLD`. Once the
threshold is reached, `busy` reports nothing further and the pane holds at
`error` until a genuine turn boundary (`session.idle` → `done`) resets the
counter. That is what actually keeps a retry loop to one `amux state error`
call: not the debounce alone, but `busy` declining to re-report `working`
after the threshold.

**The retry threshold is two consecutive retries.** The first stays `working`, on
the grounds that a single retry may be a blip that self-heals, and `error`
notifies. The counter resets at turn boundaries (`session.idle`, `session.error`)
and on permission events, not on `busy`: the live test found that opencode fires
`session.status → busy` immediately before every retry, so the observed stream
against a dead provider is `busy, retry, busy, retry, ...`, not retries separated
by unrelated busy events. Resetting on `busy`, as an earlier draft of this plugin
did, made the threshold unreachable — the counter was zeroed before every
increment, so `error` never fired no matter how long the provider stayed dead.
The offline harness did not catch this because its synthetic events modelled
`busy` and `retry` as alternatives; the live test did, on its first real run.
It is a single named constant in the plugin.

`session.idle` maps to `done` rather than `idle` to match Claude's `Stop` hook:
`done` means "finished, awaiting your next prompt", while `idle` is the resting
state of a pane that has not worked.

**Failure posture.** Every handler wraps its shell-out so that a failure — amux
missing, tmux gone, a pane that died — is swallowed. A badging plugin must never
be able to break the agent it is badging. This mirrors the `|| true` discipline
already in `scripts/amux-agent-state`.

### 4. Testing

Three layers, two of which run in CI.

**Layer 1 — the `error` state, in bash, in CI.** Exactly like the four existing
states: badge rendering including urgency ordering, pane border, switcher row,
rollup counting, and the notification firing for an off-screen pane. This is the
bulk of the work and it needs no harness that does not already exist.

**Layer 2 — the plugin's event mapping, in Node, in CI.** A small harness
imports `adapters/opencode/amux.js`, fires synthetic events at it, and asserts
which `amux state` calls result — with a recording shim earlier on `PATH`
standing in for `amux`. That covers the whole mapping table, deterministically
and offline. Node is present on both CI runners, but the harness is gated on
`command -v node` in the same style as the existing `python3`-gated tests, so the
suite degrades to a skip rather than a failure if it is ever absent.

Layer 2's weakness is that it tests the plugin against *our idea* of opencode's
events. Two things narrow that gap — the handlers stay thin, so there is little
behaviour to get wrong beyond the mapping, and the event names are pinned against
`@opencode-ai/plugin`'s type definitions rather than invented — but neither
closes it. Layer 3 is what closes it.

**Layer 3 — real opencode against a local model, on a developer machine.**

Running opencode in CI is not an option, but the reason usually given — that it
needs auth and burns quota — turns out to be wrong. Verified live: with
`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME` all pointed at a scratch
directory, so no stored credential is reachable, opencode 1.18.15 drove
`ornith:35b` through a local ollama and completed a turn cleanly. No login, no
network, no quota. The model reports the `tools` capability, which is the only
model property this test depends on — the plugin needs a tool call to produce
`tool.execute.before` and a gated tool to produce `permission.ask`.

What actually rules CI out is size: the model is 21 GB, and a hosted runner can
neither hold it nor fetch it per run.

So layer 3 lives at **`tests/live/opencode-smoke.sh`**, deliberately outside
`tests/`'s flat `test-*.sh` glob so `tests/run.sh` cannot pick it up. It builds an
isolated XDG home, symlinks the plugin, launches opencode in an isolated tmux
server whose socket path ends in `/amux`, sends a prompt that forces a gated tool
call, and asserts the pane's `@agent_state` moves `working → blocked → working →
done`. A second case points the provider at a dead port and asserts the pane
reaches `error` — the retry path from §3, which is the only way `error` can be
produced on demand. It skips with a clear message — never fails — when ollama is
not running or the model is absent, so it is safe to run on any machine.

This layer is not optional polish. Every one of the four mapping corrections in
§3 came from running opencode; none were visible in the type definitions, and one
of them (`permission.ask`) is contradicted by them.

It is run by hand: before merging the adapter, and after any opencode upgrade.
`README.md` says so, because an undocumented manual test is one nobody runs.

**Every new assertion needs a negative control** — demonstrated failing against
the unfixed behaviour before it is accepted. Three assertions in this project
have shipped with no discriminating power; that is now a standing requirement,
not a nicety.

### 5. Docs and doctor

`amux doctor` currently reports on Claude hooks only. It gains an opencode
check: is the plugin symlinked into place, and does it point at this
installation. The check is informational — an absent opencode adapter is not a
failure, since most users will not have opencode installed.

`README.md` documents `amux state` as the public interface and the opencode
setup line. `skills/amux/SKILL.md` gains a note that an agent can report its own
state, which is the self-report half of the coverage model.

## Out of scope

- pi, aider, and Copilot CLI adapters. Increment 2 decides between them, and pi
  is the natural next one because its missing `blocked` stresses the design.
- ACP support in any form.
- `opencode attach` against a detached `opencode serve` — documented as a known
  limitation.
- Publishing an npm package. The symlink covers the repo-clone install, which is
  the only install amux has today.
