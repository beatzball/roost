# The roost adapter contract

Status: **reference** — describes what already ships, so a new adapter can be
written without reverse-engineering the two that exist
Date: 2026-08-29
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
shipped adapters, their tests, and the two bug-fix commits against them** —
not from a view about what a good plugin API looks like. Where a rule exists
because something broke, the breakage is named.

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

An adapter is also a **no-op outside roost**. `scripts/roost-agent-state:43-51`
exits 0 unless `$TMUX` names a socket path ending in `/roost`. That is what
makes it safe to wire into a *global* harness config — running the harness
anywhere else does nothing. A new adapter inherits this for free by going
through `roost state`, and must not add a check of its own that fails louder.

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

Claude Code reports `error` from **no hook at all** — there is no Claude hook
in `roost hooks` that maps to it. That is honest and worth stating plainly: a
tier is not all-or-nothing per state, and an adapter may ship with `error`
unreachable.

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

## 4. The traps a new adapter must be tested against

These are not hypotheticals. Each one shipped, or nearly shipped, in an adapter
that looked correct. A new adapter should carry a fixture for every one that
applies to its harness.

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

### T5 — `busy` is not evidence of progress

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

### T6 — a latch that can stick

Every fix above is a latch, and each one carries the mirror risk: a badge stuck
forever is **worse** than the bug it fixed. `adapters/opencode/roost.js:186-195`
answers this by naming the exact clearing condition and proving no event from
the same turn can reach it — plus a second, belt-and-braces clear on the
permission branches.

**The rule:** for every latch, write down the exact event that clears it and why
no event from the same turn can. Assert **both** directions offline: that the
latch holds, and that the next healthy turn walks `working -> done` as it always
did.

### T7 — a pane that names itself after the harness's version

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

### T8 — a blast radius enumerated from memory

From `docs/known-gaps.md`: the `error` state's blast radius was enumerated from
recall and missed two consumers. One shifted every glyph by one position for
anyone running the documented first-run path, and the init test asserted the
option *name* was present, never its value, so it passed throughout.

**The rule:** derive the blast radius by `grep` over the state vocabulary and
the glyph accessor, not from memory. `grep -rn roost_glyphset` finds all five
positional consumers in one second.

## 5. What "done" means for a new adapter

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
debounce; each trap in §4 that applies; and the reply-before-`done` ordering as
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
- **Installs the adapter as a symlink**, matching how a user installs it — which
  also proves the harness still follows symlinks when discovering plugins.
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
  `AGENTS_PLANNED` at `site/pages/index.ts:64` is untouched; three scouts are
  investigating Codex, GitHub Copilot CLI and pi, and their findings decide
  that.
- No new roost command, and no change to the `roost state` / `roost reply`
  contract.
- No change to `@agent_state` or `@agent_since`, in name or in scope — they are
  deliberately unbranded so two servers can share one hook mechanism
  (`AGENTS.md` §6).
- Not a site page. This is maintainer-facing; `AGENTS.md` §11 puts user-facing
  detail in `site/content/docs/` and this is neither install instructions nor
  usage.
