# The roost adapter contract

Status: **reference** — describes what already ships, so a new adapter can be
written without reverse-engineering the two that exist
Date: 2026-08-29, revised the same day to fold in three live harness scouts
(Codex, GitHub Copilot CLI, pi)
Size: **Doc** (no code, no site change, no new command)
Base: `35919d3` — `main` at "live test: default to granite4.2:3b instead of
ornith:35b (#16)"

## Why

`site/pages/index.ts:64` promises three more harnesses:

```js
/** Harnesses with an adapter planned, but not written yet. */
const AGENTS_PLANNED = ['Codex', 'GitHub Copilot CLI', 'pi'] as const;
```

That array is the only record of the promise, and nothing anywhere says what
"an adapter" is. Two exist — `scripts/roost-agent-state` (Claude Code) and
`adapters/opencode/roost.js` — so today the way to write a third is to read
both and infer the rules.

Inferring them is expensive and has already gone wrong once inside this repo:
`#12` shipped a reply channel that published nothing on any turn, and 529 green
assertions did not see it (`docs/known-gaps.md`, "A fixture that stops where
the feature does proves nothing"). The rules that mattered were all present in
the working code; they were simply not written down anywhere a new
implementation would look.

This document is that place. **Everything below is derived from the two
shipped adapters, their tests, the two bug-fix commits against them, and three
live harness scouts** — not from a view about what a good plugin API looks like.
Where a rule exists because something broke, the breakage is named.

The scouts matter to the shape of this document, not just its content. Two of
the traps in §5 and the whole of §4 come from harnesses roost has **not**
adapted yet, found by driving live turns against them. That is the cheap place
to find a trap: §4's rule in particular could not have been recovered after the
fact, because breaking it produces a successful-looking turn on every machine
that had already trusted the adapter. Scout findings are labelled as they were
labelled — **live-verified** or **source-only** — and are not laundered into
fact here.

Where a claim below cites `scout-codex.md`, `scout-copilot.md` or
`scout-pi.md`, that is one of those three reports. **They live in the session
scratchpad and are not in this repository**, so the measurements they contain
are quoted here rather than linked — this document is the durable record, and a
number that is only in a scratchpad is a number that is gone. Versions tested:
`codex-cli 0.150.1`, `GitHub Copilot CLI 1.0.81`, `pi
(@earendil-works/pi-coding-agent) 0.81.1`, all on darwin-arm64 against local
ollama.

## What an adapter is

An adapter is code that:

1. **runs inside the process that occupies the tmux pane**, and
2. **fires on the harness's own turn boundaries**, and
3. **calls two public roost commands**: `roost state STATE` and
   `roost reply TEXT`.

That is the whole surface. An adapter owns **no tmux knowledge**. Both shipped
adapters find their pane from `$TMUX_PANE` alone, and
`adapters/opencode/roost.js` deliberately shells out to `roost` rather than
calling `tmux` itself, so the tmux details (pane options, the 16 KiB command
cap, truncation) live in one place — `scripts/lib/roost-reply.sh` and
`bin/roost`.

Three consequences follow, and each has already caused a real problem:

**It must run in the pane's process.** `roost state` reads `$TMUX_PANE`, so an
adapter running anywhere else badges the wrong pane or no pane. The comment at
`adapters/opencode/roost.js:11-14` records the live case: the plugin works under
a normal `opencode` in a pane, but **not** for `opencode attach` against a
detached `opencode serve`, where the plugin runs in the server. A harness with a
client/server split has to answer this before anything else.

**It must key on turn state, not on tool calls.** `adapters/opencode/roost.js:21-24`
records why: `tool.execute.before` fires only when a tool runs, and only once
the turn is underway, so a turn that answers without calling a tool would never
show `working` at all.

**It must never throw.** A missing `roost`, a dead tmux server, or a pane that
went away must leave the pane unbadged and leave the agent working. The two
adapters do this two ways: every tmux call in `scripts/roost-agent-state`
carries `|| true`, and `adapters/opencode/roost.js:134-150` wraps `execFile` so
`run()` resolves and never rejects. `tests/opencode-plugin-harness.mjs:548`
asserts it: *"a missing roost on PATH does not throw into opencode"*.

An adapter is also a **no-op outside roost**. `roost_self_socket` in
`scripts/lib/roost-socket.sh` exits both `roost state` and `roost reply` 0
unless `$TMUX` names a socket path ending in `/roost`. That is what makes it
safe to wire into a *global* harness config — running the harness anywhere else
does nothing. A new adapter inherits this for free by going through `roost
state`, and must not add a check of its own that fails louder.

That helper is **one rule for both halves**, and it has to stay that way.
`roost state` used to read the socket from `$TMUX` while `roost reply` fell
through to the production `-L roost` default, so on any other roost server the
badge landed and the reply silently did not — no adapter sets `ROOST_SOCKET`,
so every adapter was exposed. `tests/test-reply-socket.sh` is the regression,
and it is the one reply-channel test that never sets `ROOST_SOCKET`.

## 1. The five states

The vocabulary is fixed: `error blocked working done idle`, in that order of
urgency (`scripts/roost-next-blocked:13-18`). `roost state` normalises anything
it does not recognise to `idle` (`scripts/roost-agent-state:54`), so a typo
degrades quietly rather than erroring — which means a typo is also invisible.

| state | what it claims **at a turn boundary** | Claude Code | opencode |
|---|---|---|---|
| `working` | a turn is underway | `UserPromptSubmit`, `PostToolUse` | `session.status` type `busy` |
| `blocked` | **a human is being waited on** | `Notification`, matcher `permission_prompt` | `permission.asked` |
| `error` | the turn ended without an answer and will not progress without you | — (no hook) | 2 consecutive `retry`, or `session.error` |
| `done` | the turn finished; there is something to look at | `Stop` | `session.idle` |
| `idle` | no turn — **the default, not a report** | — | — |

Three of these are subtler than the table.

### `blocked` means a human, not "slow"

`blocked` is not "waiting on something". It is **a human is being waited on and
the agent cannot proceed until they act**. In practice that is a permission
dialog.

It is load-bearing in three places, which is why the precision matters:

- `roost send` **refuses** a blocked target with exit 3
  (`site/content/docs/driving-a-fleet.md`). The reason is concrete: `send`
  types text and then presses Enter, so against an open dialog the text goes
  *into the dialog* and Enter activates whatever is highlighted. One agent
  would silently answer a prompt that existed to ask the human.
- `scripts/roost-next-blocked` jumps to it.
- `scripts/roost-agent-state:192-213` fires a desktop notification for it when
  the window is off-screen.

So a `blocked` that fires for anything else — a long tool call, a network wait —
poisons all three. And an adapter that **cannot** report `blocked` leaves the
fleet reading `working` while the agent sits waiting for a keypress. That is
the "silently stuck" failure, and `adapters/opencode/roost.js:96-105` calls it
out explicitly for the subagent case: a subagent's permission dialog must badge
the pane, because a human still has to answer it.

Claude Code needs one extra rule here, recorded at `bin/roost:220` and in
`site/content/docs/state-badges.md`: the `Notification` hook **must** be scoped
to `permission_prompt`. Unmatched, it also fires for `idle_prompt` and
`auth_success`, so a finished agent goes red.

And `blocked` needs a **clear** as well as a set. No Claude hook fires when a
human answers a dialog, so `PostToolUse` is what clears it — the first
observable event after the approval. Without that clear, the pane stays red
from the approval until the whole turn ends. A new adapter must name its own
clearing event; opencode's is `permission.replied`.

### `error` means this turn is over and produced nothing

Not "a tool failed" — an agent that recovers from a failed tool is working.
`error` claims the turn ended, produced no answer, and will not without you.
`roost wait-done` acts on that claim: it exits 1 with *"is in error state, not
done"* rather than reporting success (`bin/roost:588-600`, and the
`docs/known-gaps.md` entry on it).

Two derived rules, both from live measurement:

- **One retry is not an error.** `adapters/opencode/roost.js:38` sets
  `RETRY_THRESHOLD = 2` because a single retry may be a blip that heals itself,
  and `error` fires a desktop notification.
- **A user abort is not an error.** opencode's `MessageAbortedError` is the
  human pressing Esc. `adapters/opencode/roost.js:374-384` badges it `done`:
  badging someone's own keystroke as a crash, and pinging their desktop about
  it, is worse than saying nothing.

### When the harness cannot say `error` at all

Claude Code reports `error` from **no hook at all** — there is no Claude hook in
`roost hooks` that maps to it. Codex is the same: the scout enumerated all
twelve of its hook events live and **none of them is an error event**
(`reports/scout-codex.md` §4, VERIFIED). A tier is not all-or-nothing per state,
and an adapter may ship with `error` unreachable.

But be exact about what that costs, because it is not a missing badge. A turn
that dies on the provider still ends, and the harness still fires whatever it
fires at the end of a turn — so an adapter with no `error` signal maps that
ending to `done`. **The pane then reports a dead turn as finished.** That is the
`#13` bug, shipped deliberately instead of by accident, and this project has now
fixed a false `done` twice (`#13`, `#14`).

So the rule is not "skip `error` quietly":

- **Say it in `docs/known-gaps.md`**, in that file's own shape — which severity
  heading it sits under, what the wrong output is, and why it was shipped
  anyway. A false `done` is a **Live risk**, not a Behaviour change. The file
  currently has no Live risks section, and its own preamble says the heading
  comes back with the first entry that earns it. This earns it.
- **Say it in the harness's section of `site/content/docs/state-badges.md`**, so
  a user reading the install stanza learns it before they trust the badge.
- **Do not invent one from a weak signal.** The Codex scout found the only
  candidate — a live turn whose tool call failed showed five `PreToolUse`
  against four `PostToolUse`, so an unmatched `PreToolUse` means a failed or
  denied call (VERIFIED). They recommended against building `error` on it, and
  that is right: a heuristic that mislabels a healthy turn `error` re-notifies
  the human's desktop for nothing, and a heuristic that misses is no better than
  the gap it replaced.

A harness that *can* say it directly should, and the shape varies. pi carries
`stopReason === "error"` with an `errorMessage` on the settled assistant message
(`reports/scout-pi.md`, VERIFIED against a dead port), so `error` is a field
read with none of opencode's retry counting. Copilot declares a `session.error`
event and an `onErrorOccurred` hook — **UNVERIFIED**; that scout did not induce
a failing turn and flagged it as read-not-run.

### `idle` is a default, not a report

Neither shipped adapter ever reports `idle`. `tmux/roost.conf:32-42`
deliberately leaves `@agent_state` with **no global default**, so an unstamped
pane reads *empty*, and `tmux/roost.conf:80` renders empty as the idle glyph.
An adapter with nothing to say says nothing.

This matters because a global default would badge every unstamped pane — a
shell, a log tail, a pager — as an agent. The empty string is what
distinguishes "not an agent" from "an idle agent", and roost chooses to render
them the same rather than to invent a difference.

### Report transitions, not events

Both adapters de-duplicate, at two different layers, and a new adapter needs
both:

- **In the adapter**, to avoid a process spawn. `adapters/opencode/roost.js:164`, `:208-212`
  holds `last` and returns early when the state has not changed, because
  opencode emits `session.status` busy several times per turn.
  `tests/opencode-plugin-harness.mjs:116` locks it: *"repeated busy events are
  debounced to one call"*.
- **In `roost state` itself**, to avoid a tmux round trip.
  `scripts/roost-agent-state:138` bails when the state already matches. This is
  the hot path — `PostToolUse` fires on *every* tool call and Claude blocks on
  the hook exiting — so the unchanged case is one tmux read and nothing else.

## 2. The reply channel

`roost read TARGET` returns what the agent last said, not what is on its
screen. The recording is the adapter's job.

### The verb

```sh
roost reply "the tests pass; two lint warnings in src/api.ts"
```

Text comes from **argv**, never stdin. `bin/roost`'s `reply` branch and
`scripts/lib/roost-reply.sh` exist so that no public entry point can block
waiting for input — a human typing `roost state done` at a terminal must not
hang on a `cat` that never sees EOF. `scripts/roost-agent-state:36-40`, `:77-79` makes the
same point from the other side: the Claude hook reads stdin **only** behind an
explicit `--stop-hook` flag, and skips even that when stdin is a tty.

An adapter passes the text and stops there. **Truncation is not the adapter's
decision** — `scripts/lib/roost-reply.sh` caps at 12288 bytes with a visible
marker line, because tmux rejects an over-long *command* at ~16384 bytes
(measured, tmux 3.6 Darwin arm64). One place decides that, so two callers cannot
drift.

### What counts as "the reply"

The last assistant **text** of the turn. Four things must be excluded, and each
exclusion exists because the harness delivers it through the same channel:

| exclude | why | evidence |
|---|---|---|
| the model's *reasoning* | arrives on the identical event with `part.type === "reasoning"`; publishing it posts the model's thinking as its answer | `adapters/opencode/roost.js:274-278`, harness case at `tests/opencode-plugin-harness.mjs:320` |
| the **user's own prompt** | arrives on the same event with the same `partType: "text"`; only the message id separates them | `adapters/opencode/roost.js:240-248`, `:272-273`, harness case `:326` |
| harness-injected text | opencode marks it `part.synthetic` | harness case `:352` |
| a **subagent's** speech | it was never addressed to the caller | harness cases `:481`, `:518` |

Where several text parts are split by tool calls, keep the **last** one. That is
also what Claude Code's `last_assistant_message` returns for that shape
(verified in the read-reply-channel spec), so both harnesses agree on what "the
reply" means. A new adapter must match that definition rather than invent one —
`roost read` has one contract regardless of which harness produced the text.

### The ordering rule: reply **before** `done`

This is the rule most likely to be got backwards, and it is invisible when
wrong — it produces an intermittent screen scrape, not a failure.

The documented idiom is:

```sh
roost wait-done "$helper" 120
roost read "$helper"
```

`roost wait-done` returns **the instant** `@agent_state` stops being
`working`/`blocked` (`bin/roost:567-573`). So if the state is stamped first,
`read` can land in the gap before the reply is written and fall back to
scraping the screen.

Both adapters therefore write the reply first:

- `adapters/opencode/roost.js:356-366` **awaits** `publish(pending)` and only
  then calls `set("done")`. The `await` is part of the rule, not tidiness — the
  publish is a process spawn.
- `scripts/roost-agent-state:76-109` writes `@roost-reply` before the
  `@agent_state` write at line 144.

`tests/opencode-plugin-harness.mjs:313` asserts the order directly:
`verbs()` must be `state,reply,state`.

In the Claude hook there is a second placement rule that is easy to miss: the
reply write sits **above** the unchanged-state early bail at
`scripts/roost-agent-state:138`. A `Stop` arriving when the pane already reads
`done` — a turn with no `UserPromptSubmit`, a re-entrant stop — would otherwise
bail before recording anything, and `roost read` would silently serve the
**previous** turn's reply.

### Drop the pending reply on an error

`adapters/opencode/roost.js:369-373`: a turn that ended in an error has no
answer to publish, and holding a half-built one lets it attach to the next
turn — a stale reply served as fresh.

### It degrades, it does not break

If nothing is recorded, `roost read` falls back to the pane's screen and
**says so on stderr**. An adapter that records no reply is a real adapter at a
lower tier, not a broken one. This is also why no JSON reader is a hard
dependency: `scripts/roost-agent-state:94-101` prefers `python3`, then `jq`, and
records nothing if neither exists — `scripts/roost-doctor:31` holds the standing
decision that python3 is not a runtime dependency.

## 3. Tiers — what a harness can honestly offer

Not every harness can do everything, and roost is designed so that a partial
adapter is useful rather than embarrassing. Three tiers ship today.

### Tier 0 — manual `roost state`, any harness, no code

```sh
roost state working
roost reply "…"
roost state done
```

Documented at `site/content/docs/state-badges.md` ("Any other agent") and
`skills/roost/SKILL.md:177-206`. It needs no extension surface at all: the agent
itself runs the commands, because it can run shell commands.

**What the user loses.** The badge is only as fresh as the agent remembers to
make it, and — the important one — **`blocked` is unreachable in practice**. An
agent stopped at a permission dialog cannot run a command to say so; by the
time it could, it is no longer blocked. So `roost send`'s exit-3 refusal never
protects a Tier 0 pane, and `roost next-blocked` never finds it. A Tier 0 fleet
is a status board, not a safety mechanism.

`skills/roost/SKILL.md` is what makes Tier 0 work: an LLM agent that has read
the skill knows the loop. That is the whole install for a harness with no
extension surface.

### Tier 1 — full badges from a lifecycle surface

An adapter that fires on turn boundaries and reports the states it can reach.

**What the user gains over Tier 0:** freshness without the agent's cooperation,
`roost wait-done` that means something, the desktop ping on `blocked`/`error`,
and `roost next-blocked`.

**The pivot inside this tier is `blocked`.** A harness that can report
`working`/`done` but cannot signal a permission dialog gives a fleet that reads
`working` while a human is being waited on — and `roost send` will happily type
into the dialog, because the badge says the pane is fine. That is worth stating
in the adapter's own docs rather than leaving a user to find it. `error` is a
softer gap: Claude Code's adapter has no `error` path at all and is still the
reference implementation.

### Tier 2 — badges **plus** the reply channel

Tier 1, plus `roost reply` on every turn.

**What the user gains:** `roost read` returns the agent's answer instead of its
screen. `site/content/docs/driving-a-fleet.md` is blunt about why that matters:
a full-screen TUI's last lines are an input box and status bars, so scraping
returns furniture, not the answer.

**What a Tier 1 user loses:** every `roost read` against that pane prints the
stderr notice and returns a screen scrape. Nothing is silently wrong — the
notice names the cause and points at `roost doctor` — but a coordinating agent
gets chrome where it expected content.

| | Tier 0 | Tier 1 | Tier 2 |
|---|---|---|---|
| needs an extension surface | no | yes | yes |
| badge freshness | agent's discipline | automatic | automatic |
| `blocked`, and `send`'s refusal | not in practice | if the harness signals it | if the harness signals it |
| `wait-done` | approximate | exact | exact |
| `roost read` | only if the agent calls `roost reply` | screen scrape + notice | the real reply |

The tiers are a ladder, and the honest thing for a new adapter is to say which
rung it is on. `site/content/docs/driving-a-fleet.md` already documents the
fallback for the rungs below the top, so an adapter does not have to apologise
for landing on one.

### Where each harness stands

Two shipped, three scouted live in August 2026. **Live-verified** means that
scout drove a real turn and pasted the output; **source-only** means they read
it and labelled it unverified. The labels are theirs and are carried through
unchanged.

| harness | tier | `blocked` | `error` | reply | install |
|---|---|---|---|---|---|
| **Claude Code** | **2, shipped** | live | **no hook** | `Stop` payload | 4 hooks in `~/.claude/settings.json`, by absolute path |
| **opencode** | **2, shipped** | live | 2 retries / `session.error` | `message.part.updated` | symlink into `~/.config/opencode/plugin/` |
| **Codex** | 2 reachable | live-verified, and does **not** over-fire on auto-approved calls | **no event at all** | `last_assistant_message`, live-verified | frozen `hooks.json` + a shim; needs a doctor trust check |
| **Copilot CLI** | 2 reachable | live-verified, via a gated handler | `session.error` / `onErrorOccurred`, **source-only** | `assistant.message.content`, live-verified | symlink into `~/.copilot/extensions/roost/extension.mjs` |
| **pi** | 2 reachable | implementable and live-verified, but **never fires on a stock install** | `stopReason === "error"`, live-verified | `message_end` flushed at `agent_settled`, live-verified | symlink into `~/.pi/agent/extensions/` |

Four things in that table are not details.

**Codex would ship a false `done`.** It has no error event, so a dead-provider
turn ends as "finished, go look". See "When the harness cannot say `error` at
all" above — it is a known-gaps entry, not an omission.

**Codex's `blocked` was the one worth checking and it passed.** The worry was a
false `blocked` on every auto-approved tool call. Measured: a real tool call
under `approval: never` fired six hooks and **no** `PermissionRequest`, and a
genuine escalation request in the TUI did fire it, with the dialog on screen at
that moment. Order was `PreToolUse` → `PermissionRequest` → human →
`PostToolUse`, so `working` then `blocked`, never the reverse — and
`PostToolUse` clears it by the identical mechanism `state-badges.md` already
documents for Claude.

**pi's `blocked` gap is a product decision, not a defect.** pi ships no
permission prompts at all, by design — its own docs list "permission popups"
among the things it intentionally omits. So the state is fully implementable and
was demonstrated live end to end (`idle → working → blocked → working → done`,
with the tmux pane option read back at each step), and a **stock pi pane will
never enter it**, because nothing asks. For a fleet view that means a pi pane
never triggers `send`'s exit-3 refusal — not because roost cannot see the
dialog, but because there is no dialog. Whether roost should also ship a
permission gate so pi panes *can* block is a call for the human, not for an
adapter author; the scout recommended shipping four states first.

**Codex cannot drive ollama out of the box, and that changes its smoke test.**
It sends tool definitions ollama rejects (`type: "namespace"`,
`type: "web_search"`; `--disable multi_agent` removes the first,
`[tools] web_search = false` did **not** remove the second), so a live rig needs
a local proxy that strips every tool whose `type` is not `"function"`. Worse,
ollama's HTTP 500 with a precise parse error is reported by Codex as *"We're
currently experiencing high demand, which may cause temporary errors"* — so
anyone debugging it chases the wrong thing. opencode needed no proxy at all.
Budget for it: a Codex smoke test is more scaffolding than
`tests/live/opencode-smoke.sh` was, and `codex exec` additionally blocks on
stdin (pass `< /dev/null`) and forces `approval: never`, so `blocked` can only
be exercised through the TUI, with a model strong enough to request escalation
(`granite4.2:3b` never does; `granite4.2:8b` does).

## 4. How an adapter is registered decides how it can ever be changed

Two shipped adapters made this look like a settled question, because both are
installed the same way: a symlink out of the roost checkout, so **updating roost
updates the adapter for free**. `adapters/opencode/roost.js:3-8` says so in its
own install instructions, and `scripts/roost-doctor:160-174` checks the link is
this checkout rather than a stale copy.

The Codex scout found the opposite model, and it is a different contract, not a
detail of one harness.

### Pinned registration: the harness hashes what you registered

Codex writes a trust entry per handler into `$CODEX_HOME/config.toml`, keyed by
`<hooks.json path>:<event>:<group index>:<handler index>` and holding a
`trusted_hash`. A handler whose hash does not match is **skipped**. Measured
live on `codex-cli 0.150.1`, both directions:

| change | result |
|---|---|
| rewrote the **script body**, `hooks.json` untouched (md5 printed, unchanged) | all 4 fired, running the **new** code, no re-prompt |
| appended ` --extra-arg` to the **command string** | **0 of 8 fired**, the turn still succeeded, Codex said nothing |
| reverted the command string | 4 fired again — trust is hash-keyed and was never revoked |
| changed **only a `timeout`**, 10 → 11 | **7 of 8 broke** |

The last row is the one that settles it. The lone survivor was `SessionEnd`,
which Codex was already clamping to 3s — so its *effective* definition never
changed. The exception proves the rule: **the hash covers the whole normalised
handler object, not just its `command`.**

### The rule

**Where a harness pins its registration, the adapter freezes the entire
registration at v1 and puts every future change inside a shim script.**

The registration becomes a permanent public interface, on the same footing as
`@agent_state`'s name (`AGENTS.md` §6). What roost emits on day one it emits
forever; all churn lives behind it.

For Codex concretely, `roost hooks codex` emits handler objects that never
change again:

```json
{"type": "command", "command": "/abs/path/to/roost-codex-hook Stop", "timeout": 10}
```

and `roost-codex-hook` is where behaviour is allowed to move. Two consequences
fall out of the timeout row above:

- **Never tune a timeout in a later release.** Pick one now. Changing it is
  indistinguishable, to the user, from changing the command — and it breaks
  every handler at once.
- **Emit whatever the harness would clamp to.** Codex silently clamps
  `SessionEnd` and `Interrupt` to 3s and warns about it on every single run.
  Emit `3` for those two, so the warning never appears **and** the stored hash
  matches the definition the user actually sees.

### The two models are opposites, and a contributor must know which they are in

| | symlinked (opencode, Copilot, pi) | pinned (Codex) |
|---|---|---|
| a roost update reaches the adapter | automatically | only inside the shim |
| changing the registered definition | there is none to change | breaks trust for every handler |
| what must stay stable forever | nothing | the whole registration object |
| how a break announces itself | `roost doctor` names a dangling or foreign link | **it does not** — see T6 |

Writing a pinned adapter with the symlinked model's habits — tuning a timeout,
adding a flag to the command in a later release — silently disables every hook
on every machine that has already granted trust.

### One security property, stated plainly

The first row of the table is a feature for roost and a fact users deserve:
trusting a Codex hook trusts a **path**, not the code at that path. Anyone who
can write `roost-codex-hook` changes what runs, with no re-review. That is
Codex's model rather than something roost introduces, but roost's install docs
must not imply the trust prompt vouches for the script's contents.

## 5. The traps a new adapter must be tested against

These are not hypotheticals. Each one shipped, or nearly shipped, in an adapter
that looked correct — or, for T5 and T6, was caught by a live scout in a harness
roost has not adapted yet, which is the cheaper place to catch it. A new adapter
should carry a fixture for every one that applies to its harness.

T4, T5 and T6 are three **different** shapes of one failure: the harness's own
documentation describes a signal that does not reach you. They are separated
because the fix is different in each, and reading only T4 would leave the other
two undiagnosed.

### T1 — a subagent's events arrive on the same bus

**Input:** a turn that calls a subagent and then answers.
**Wrong output, measured** (`adapters/opencode/roost.js:40-58`, opencode 1.18.20):

```
56331ms  child   session.created   (info.parentID = the parent session)
56423ms  child   session.status    busy
72396ms  child   session.idle       <- unfiltered, this stamped `done`
72430ms  parent  session.status    busy
77346ms  parent  session.idle       <- the real end of the turn
```

The pane read `done` for 34ms while the parent was still working, and two
`roost state` calls 34ms apart are separate processes that can land out of
order — so the wrong one can be the last writer and the pane stays `done` for
the rest of the turn.

It breaks the **reply** as well as the badge, and that half was missed first:
`CHILD_MUTED` originally covered only the child's *lifecycle*. The child's
`message.updated` then took over `assistantID` and cleared the pending reply, so
the child's text was collected and published, **and** the parent's own later
text parts were rejected for not matching the hijacked id. The wrong answer did
not merely appear — it crowded out the right one.

**The rule:** filter a child's lifecycle *and* its speech
(`adapters/opencode/roost.js:106-112`). Filter by **ignoring** the child, not by
tracking which sessions are still busy — a set of active sessions that fails to
empty leaves the pane on `working` forever, which this adapter already shipped
once.

**The exception that must survive the filter:** a subagent's *permission
dialog*. It carries the child's session id, and a human still has to answer it,
so the pane must show `blocked` (`adapters/opencode/roost.js:96-105`, harness
case `tests/opencode-plugin-harness.mjs:288`).

### T2 — a message re-announced after its content (`#14`)

**Input:** any normal opencode turn.
**Wrong output:** `roost read` returned a screen scrape on **every** turn — not
an edge case, every agent.

opencode re-announces the same assistant `message.updated` **twice, after** its
text parts land and immediately before `session.idle`. The handler cleared the
pending reply on every announcement, so the collected reply was wiped a moment
before the only line that would have published it.

**The rule:** clear on an id **change**, not on the event
(`adapters/opencode/roost.js:249-267`). The id is what distinguishes "the same
message, told again" from "a new message" — and the clear is still correct in
the second case, because a different assistant message is a different answer.

**The wider rule, from `docs/known-gaps.md`:** a fixture derived from a
recording replays the **whole recorded turn**, trailing events included. The two
events that broke this were the two the fixture left out, because at
fixture-writing time they looked like noise after the interesting part.

### T3 — an idle that follows an error (`#13`)

**Input:** a turn against an unreachable provider.
**Wrong output, measured** on 1.18.20:

```
 3495ms  session.status  {"type":"retry","attempt":1,...}  ... four more ...
67103ms  session.error   {"name":"APIError",...}
67103ms  session.idle     <- unfiltered, this stamped `done`
```

The pane badged `error`, fired the desktop notification, then overwrote it with
`done` a minute later. **A wrong `done` is the worst wrong badge there is:
every other one makes you look, and this one makes you stop looking.**

**The rule:** swallow the `session.idle` that follows this turn's own
`session.error` (`adapters/opencode/roost.js:349-355`). Key it on the
harness's own failure declaration, **not** on the badge already reading
`error` — those are different claims. Two retries that then *succeed* are a turn
that finished, and its idle must still report `done`.

### T4 — a declared event that never fires

**Input:** an adapter written from the harness's type definitions.
**Wrong output:** an adapter wired to a dead event, shipping broken.

Two live instances in one harness:

- `session.next.text.ended` is declared in opencode 1.18.20's own OpenAPI schema
  with a required `text` field, and the literal string is present in the shipped
  binary (3 occurrences). **It never fires on a normal turn.**
- opencode declares a `permission.ask` **hook**; registering it produces nothing
  when a dialog appears. The `permission.asked` **event** is what fires
  (`adapters/opencode/roost.js:16-19`).

**The rule, and it is `AGENTS.md` §9:** a grep hit is not proof a thing is live.
Drive a real turn, log every event, and wire the adapter to what you observed.
If the harness is not installed, say the answer is documentation-only and
unverified rather than dressing it up.

**Before concluding an event is dead, check T5 and T6.** A signal that does not
arrive may be genuinely absent (this trap), switched off until you register
something (T5), or waiting on a human's consent (T6). The observation is
identical in all three; the fix is not.

### T5 — a gated event: real, documented, and off until you register a handler

**Input:** an adapter written from the harness's schema *and* its own SDK docs.
**Wrong output:** the badge never shows `blocked`; the fleet reads `working`
while a human stares at a permission dialog.

GitHub Copilot CLI's `permission.requested` is declared in the shipped
`schemas/session-events.schema.json` **and** documented in the shipped SDK docs
under "Top 10 Most Useful Event Types", described as *"Agent needs permission
(shell, file write, etc.)"*. Both sources say to subscribe with `session.on`.

Measured (VERIFIED, `reports/scout-copilot.md`): with a permission dialog open on
screen and a probe subscribed to every event, 12 events arrived and **none of
them was `permission.requested`**. Only `permission.completed` ever fired, and
only *after* the human answered — the badge would light up at the exact moment
the human stopped being blocked.

The event is real. It is **gated on registering an `onPermissionRequest`
handler**; registering one turns it on for `session.on` as well.

**The objection, and the escape.** Registering a permission handler sounds like
becoming the permission *decider*, which roost must never be. The SDK defines an
explicit pass-through — `{ kind: "no-result" }` — that observes without
answering. Verified end to end: the handler fired, the badge could flip, the
normal TUI dialog still opened, the human still chose, and the command ran on
their approval.

```
05:00:41.780  ON_PERMISSION_REQUEST  shell   <-- handler fires, badge -> blocked
05:00:41.780  EVENT permission.requested     <-- and now the event fires too
              ... dialog on screen, human thinking for 35s ...
05:01:16.041  EVENT permission.completed     <-- badge -> working
```

**The rule:** when a documented event does not fire, do not conclude it is dead
(that is T4) until you have checked whether something *enables* it. And when the
enabler is a handler that could change the agent's behaviour, look for the
harness's observe-only return value before deciding the state is unreachable.

### T6 — a consent-gated adapter that fails completely silently

**Input:** an adapter installed correctly, whose registration a human has not
yet trusted.
**Wrong output:** every hook is skipped, the turn succeeds normally, and
**nothing anywhere says so**.

Codex requires a human to trust its hooks through a TUI prompt. Until then they
do not run. That is reasonable. What is not obvious is how quiet it is: this is
the complete, unedited stderr of a `codex exec` turn with eight untrusted hooks
wired (VERIFIED, `reports/scout-codex.md` §2):

```
Reading additional input from stdin...
OpenAI Codex v0.150.1
--------
workdir: <scratch>/work
model: granite4.2:3b
...
warning: clamping SessionEnd hook timeout to 3s in <scratch>/cxhome/hooks.json
warning: clamping Interrupt hook timeout to 3s in <scratch>/cxhome/hooks.json
warning: Model metadata for `granite4.2:3b` not found. ...
codex
alpha
```

It warns about timeouts. It warns about model metadata. It says **nothing** about
eight hooks being skipped, and `HOOKS FIRED: 0`.

Codex's own docs claim it prints a startup warning telling you to open `/hooks`.
That is **true of the TUI and false of `codex exec`** — a real doc-versus-
behaviour gap, and `exec` is where automation lives.

The same silence is what makes the registration breakage in §4 undetectable:
change a registered timeout in a later release and every machine that had
already granted trust goes quiet, one successful-looking turn at a time.

**The rule:** `roost doctor` must **check** consent, never infer it from the
files being in place. "The hooks are installed" and "the hooks will run" are
different claims (`AGENTS.md` §9), and here nothing else will ever tell the user
they differ. The check has a fix to print — run `codex`, then `/hooks` — so it
is a `warn`, in the same shape as the existing stale-hook and dangling-symlink
checks at `scripts/roost-doctor:160-174`.

### T7 — `busy` is not evidence of progress

**Input:** a turn against a dead provider, with a retry counter that resets on
`busy`.
**Wrong output:** the pane sat on `working` forever; `error` was unreachable.

The real stream interleaves `busy` with every retry — busy, retry, busy,
retry — because opencode re-announces busy before each attempt
(`adapters/opencode/roost.js:26-37`). So the counter must **not** reset on it.
It resets only at genuine turn boundaries (`session.idle`, `session.error`) and
on permission events.

The same interleave produces a second failure if `busy` unconditionally reports
`working`: the badge flaps working/error for the whole retry loop and
re-notifies on every cycle. Hence the threshold gate at
`adapters/opencode/roost.js:294-319`.

### T8 — a latch that can stick

Every fix above is a latch, and each one carries the mirror risk: a badge stuck
forever is **worse** than the bug it fixed. `adapters/opencode/roost.js:186-195`
answers this by naming the exact clearing condition and proving no event from
the same turn can reach it — plus a second, belt-and-braces clear on the
permission branches.

**The rule:** for every latch, write down the exact event that clears it and why
no event from the same turn can. Assert **both** directions offline: that the
latch holds, and that the next healthy turn walks `working -> done` as it always
did.

### T9 — a pane that names itself after the harness's version

**Input:** an unnamed Claude pane.
**Wrong output:** the border and switcher read `2.1.226` — Claude's own version
string, via `#{pane_current_command}`. It changes every release and means
nothing.

**The rule:** an adapter sets `ROOST_AGENT_NAME` in the environment it invokes
`roost` with (`adapters/opencode/roost.js:137-144`), so the pane falls back to
the harness's name rather than to `@roost-name-default`'s Claude-flavoured
`"claude"`. A human-chosen `@roost-name` still wins over both
(`scripts/roost-agent-state:163-190`). The harness locks it:
`tests/opencode-plugin-harness.mjs:112`.

### T10 — a blast radius enumerated from memory

From `docs/known-gaps.md`: the `error` state's blast radius was enumerated from
recall and missed two consumers. One shifted every glyph by one position for
anyone running the documented first-run path, and the init test asserted the
option *name* was present, never its value, so it passed throughout.

**The rule:** derive the blast radius by `grep` over the state vocabulary and
the glyph accessor, not from memory. `grep -rn roost_glyphset` finds all five
positional consumers in one second.

## 6. What "done" means for a new adapter

An adapter is finished when all of the following are true. This list is the
acceptance criteria; it is short on purpose, and none of it is optional.

### Offline harness cases

A file in `tests/` that fires synthetic events at the adapter and asserts the
`roost` calls that come out — `tests/opencode-plugin-harness.mjs` is the worked
example. It runs in milliseconds, offline, with **no model call**, using a
recording shim on `PATH` in place of `roost`.

Four properties it must have:

- **A fresh adapter instance per case**, so one case's debounce state cannot
  leak into the next and make a later assertion pass for the wrong reason
  (`tests/opencode-plugin-harness.mjs:67-75`).
- **Fixtures replay a whole recorded turn**, in order, trailing events
  included, with the recorded log line numbers in a comment so the next reader
  can check the fixture against the capture rather than against the code. This
  is the `#14` lesson and it is the single most important line in this section.
- **Real recorded ids**, kept verbatim (`tests/opencode-plugin-harness.mjs:92-107`
  keeps the captured parent and child session ids), so the shapes are the ones
  the harness actually emits rather than ones invented for the test.
- **It prints `  PASS:` / `  FAIL:` and always exits 0**, so `tests/run.sh`
  counts it like a bash test and a non-zero exit still means a crash.

Cases must cover, at minimum: every state transition the adapter can reach; the
debounce; each trap in §5 that applies; and the reply-before-`done` ordering as
an assertion on the **verb order**, not just on the values.

### A regression fixture is run against the **unfixed** code first

`docs/known-gaps.md` states this as a rule and `#14` is the worked example:
five fixtures, **5 failed** before the one-line change, 0 after, with the
failure output in the pull request.

A test written after the fix, that has never been seen red, is an assertion that
the code does what it does. The measured cost of skipping this was `#12`:

```
tests/opencode-plugin-harness.mjs against the BROKEN adapter -> 44 passed, 0 failed
tests/opencode-plugin-harness.mjs against the FIXED  adapter -> 44 passed, 0 failed
```

Identical. 529 assertions green across the repo, feature dead, and it sat on
`main` through another release before anyone noticed.

### A live smoke test

`tests/live/opencode-smoke.sh` is the shape. It drives the **real** harness
against a local model and asserts the badges that actually appeared. Its rules:

- **Outside `tests/`'s flat `test-*.sh` glob**, so `tests/run.sh` cannot pick it
  up. It is run by hand before merging an adapter change and after a harness
  upgrade.
- **Its own tmux socket** from `mktemp -d`, never the live `-L roost` server.
  The socket path **must end in `/roost`**, because `roost state` is a no-op on
  any other socket — the same property that makes it safe in a global config.
- **Isolated `XDG_CONFIG_HOME` / `XDG_DATA_HOME` / `XDG_CACHE_HOME`**, so no
  stored credential is even reachable and no account or quota is needed.
- **Installs the adapter the way a user installs it.** For a symlinked harness
  that means a real symlink, which also proves the harness still follows one
  when discovering plugins. For a pinned harness (§4) it means writing the
  frozen registration and granting consent, so the test exercises the path that
  can silently fail rather than a shortcut around it.
- **Budget for the rig.** The scaffolding is not uniform: opencode needed none
  beyond isolated XDG dirs, while Codex needs a proxy that strips tools ollama
  cannot parse, `< /dev/null` on `codex exec`, and the TUI plus a larger model
  before `blocked` can be exercised at all.
- **Skips, never fails**, when the harness or model is missing. A case the local
  model refused to set up (it answered instead of calling the tool) is a `SKIP`
  too, or the suite cries wolf about code that was never exercised.
- **A readiness timeout is a `die`, not a badge failure.** Sending input at a
  TUI that was never listening reads as a plugin regression; that has happened,
  and cost a manual reproduction to rule out.
- **A second spy plugin logs the raw event stream.** The badge assertions say
  *what* the pane showed; the log is the only thing that says *why*, and a
  re-run costs minutes of model time. Keep the logs on failure, delete them on
  success.

The default model is chosen for **size**, then checked for fitness —
`granite4.2:3b` at 2.2 GB, because this is the one test a contributor has to
pull a model to run at all (`tests/live/opencode-smoke.sh:18-32`).

### The rest of the checklist

- `roost doctor` gains an install check for the adapter: linked, dangling, or
  pointing at a different checkout, each with the exact fix command
  (`scripts/roost-doctor:160-174`). Informational, not a failure — most users
  will not have that harness.
- **If the harness gates on consent, doctor checks the consent too**, not just
  the files (T6). Nothing else will tell the user, and a `codex exec` run with
  every hook skipped looks exactly like a healthy one.
- **If the harness pins its registration, the registration is frozen at v1**
  (§4), and whatever roost emits is reviewed as a permanent interface before it
  ships — because the second release cannot change it.
- `site/content/docs/state-badges.md` gains the install stanza, and names the
  tier honestly if the adapter cannot reach `blocked` or the reply channel.
  `site/AGENTS.md` governs that edit.
- `bash tests/run.sh` **and** `python3 tests/test-contrast.py` pass. A non-zero
  exit from `run.sh` is a crash even when the PASS/FAIL counts look fine — a
  file that errors early contributes fewer PASS lines and no FAIL lines
  (`AGENTS.md` §8).
- A live two-pane check by eye: `roost read` returns the agent's real answer
  while `roost screen` returns its input box. This is the step that found `#14`
  after 529 green assertions did not, and it is the last one for a reason.

## Blast radius of this document

None. It adds one file under `docs/airig/specs/` and changes no code, no test,
no site page.

## Non-goals

- **It does not decide which harness gets an adapter next.**
  `AGENTS_PLANNED` at `site/pages/index.ts:64` is untouched — and now known to
  be accurate, since all three scouts came back with "build it". Which one is
  built first, and when, is still not this document's call.
- **It does not commit roost to any of the three.** The costings the scouts
  produced (~150-250 lines for Copilot, ~120-160 for pi, a shim plus a doctor
  check for Codex) are recorded so the work can be sized, not because it is
  scheduled.
- **It does not settle pi's `blocked` question.** Whether roost should ship a
  permission gate so pi panes can block is a product decision for the human;
  the table in §3 states the position without taking it.
- No new roost command, and no change to the `roost state` / `roost reply`
  contract.
- No change to `@agent_state` or `@agent_since`, in name or in scope — they are
  deliberately unbranded so two servers can share one hook mechanism
  (`AGENTS.md` §6).
- Not a site page. This is maintainer-facing; `AGENTS.md` §11 puts user-facing
  detail in `site/content/docs/` and this is neither install instructions nor
  usage.
