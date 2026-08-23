# `roost read` returns TUI chrome, not the reply, for agent panes

**FIXED.** Each adapter now records the turn's last assistant message onto its
own pane as `@roost-reply`, and `roost read` returns that instead of scraping
the screen. `roost screen` is the raw capture under an honest name. See "How it
was fixed" at the bottom.

Found 2026-08-21 during a live agent-to-agent test between a Claude Code pane
and an opencode pane. Recorded at the time rather than fixed, because the
failure is silent and sits in the middle of the workflow the skill is written
around.

## What happens

`roost read TGT [N]` is documented as "print an agent's last N non-blank lines".
It is implemented as:

```sh
t capture-pane -p -t "$(target "$raw")" | grep -v '^[[:space:]]*$' | tail -n "$lines"
```

For a **shell** pane that is exactly right — output accumulates at the bottom,
so the last N non-blank lines are the last N lines of output.

For a **full-screen TUI** — Claude Code, opencode, anything using the alternate
screen — the bottom of the pane is not output. It is furniture. `roost read %7 5`
against a live Claude Code pane returns:

```
❯
────────────────────────────────────────────────
  ~/w/beatzball/roost   main   Opus 5 (1M context)   ctx 80%
  current  ● ○ ○ ○ ○ ○ ○ ○ ○ ○   11%   1h 44m
  weekly   ● ● ● ○ ○ ○ ○ ○ ○ ○   31%   13h 14m
```

Zero lines of conversation: an input box, a rule, and three status-bar rows.

## Why it matters

This is the collect-the-reply step in `skills/roost/SKILL.md`:

```sh
roost wait-done "$helper" 120
roost read "$helper" 40
```

So the documented coordination loop works for a `bash` helper and degrades for
an *agent* helper — which is the only case the skill exists for.

At `N=40` some conversation does appear, but interleaved with box-drawing
characters, spinner frames, and truncated wrapped lines. The caller has to know
to ask for far more lines than the reply is long, and then filter furniture it
has no reliable way to identify.

## How it surfaced

An opencode agent was asked, with the user's knowledge, to run `roost read %7 5`
and report the last non-blank line. It ran the command, looked at what came
back, and refused:

> There is no clear "last non-blank line" — just formatting characters. I can't
> pick one without guessing.

That is the correct response, and worth noting: the tool handed a capable agent
a result that looked like data and was not, and only the agent's unwillingness
to fabricate stopped a wrong answer propagating. A less careful caller returns
`⏸ manual mode on · ← 1 agent` as the helper's reply.

## Why the obvious fixes do not work

- **Raise the default `N`.** Moves the boundary without removing it, and makes
  the shell-pane case noisier for no gain.
- **Filter box-drawing characters.** Different TUIs draw differently, agents
  legitimately emit tables and diagrams, and a reply containing a code fence or
  a table would be mangled by the same filter.
- **`capture-pane -S -`** to include scrollback. An alternate-screen application
  has no scrollback in the normal buffer; this returns what was on screen
  *before* the TUI started.

The shape of the problem is that `capture-pane` reads a **rendering**, and a
reply is **content**. Nothing in the rendering marks where one ends and the
other begins.

## Directions worth costing

- **Ask the agent to write its reply somewhere addressable** — a file, a named
  pipe — and have `read` prefer that when present, falling back to
  `capture-pane`. Turns a scrape into a protocol, at the cost of the helper
  having to cooperate.
- **Have the adapters do it.** The Claude hook and the opencode plugin already
  run on every turn and already know the pane. Either could record the last
  assistant message alongside the state it already stamps.
- **Scope `read` honestly.** Document it as "what is on that pane's screen",
  which is what it does, and give agent-to-agent replies a different verb. The
  present name promises something `capture-pane` cannot deliver.

The second is probably cheapest: the machinery already exists and already fires
at the right moment.

## Related

- `docs/airig/issues/2026-08-20-send-into-permission-dialog.md` — the other half
  of the same loop. Together: `send` can deliver into the wrong UI state, and
  `read` can return the wrong part of the screen. Both are consequences of
  driving a TUI as if it were a pipe.

## How it was fixed

The second direction, as predicted — the adapters already fire at the end of
every turn and already know the pane. Design and costings:
`docs/airig/specs/2026-08-23-read-reply-channel-design.md`.

Each adapter stamps the turn's last assistant message on the pane as
`@roost-reply`, a pane option, and `roost read` prefers it over `capture-pane`.
A pane option was chosen over a file keyed by pane id because its lifetime is
already exactly right: it dies with the pane, so nothing has to prune it, and a
server restart cannot leave a stale reply behind for a recycled `%N` — which
would be a wrong answer served silently, strictly worse than the chrome this
started as.

**Where the text comes from was verified, not assumed, and one of the two
answers was not the obvious one.**

- Claude Code hands it over directly: the `Stop` payload carries a
  `last_assistant_message` field. `PostToolUse` and `SessionEnd` do not, so the
  transcript never has to be parsed. The hook takes `--stop-hook` to read that
  payload; `roost hooks` prints it, and `roost doctor` warns when a settings
  file predates the flag.
- opencode delivers it on `message.part.updated`, filtered to
  `part.type === "text"` and matched to the assistant message id from
  `message.updated`. It does **not** arrive on `session.next.text.ended` —
  opencode 1.18.20 declares that event in its own OpenAPI schema with a
  required `text` field, and the string is in the shipped binary, but it never
  fired on a live turn. Building on the type definitions would have produced a
  feature wired to an event that does not happen. Reasoning parts and the
  user's own prompt arrive on the same event, so both have to be filtered out.

Two orderings are load-bearing, and both are the opposite of the obvious one:

- The reply is stamped **before** `@agent_state`. `wait-done` returns the
  instant the state stops being `working`, and the documented idiom is
  `wait-done` then `read`, so stamping state first opens a gap in which the
  reader falls back to the screen — the original bug, intermittently, which is
  harder to diagnose than the original bug consistently.
- In `roost-agent-state` the reply write sits **above** the unchanged-state
  early bail, or a `Stop` on a pane that already reads `done` records nothing
  and the previous turn's reply is served again.

`read` keeps its name rather than ceding it to a new verb. AGENTS.md section 7
is right that the name over-promised, but the fix for a name that promises too
much is to deliver, not to rename: the documented loop ends with `roost read`,
so making it return the reply fixes every existing caller — including anyone
holding an older `SKILL.md` — without their changing anything. `roost screen`
takes over the raw capture, which is genuinely wanted for a stuck pane and for
any pane that is not an agent.

When there is no recorded reply, `read` falls back to `capture-pane` and says
so **on stderr**. It never returns nothing: an empty result would be a worse
failure than chrome, because the caller cannot tell it from an agent that said
nothing. And the notice is never silent, because a silent fallback would
recreate this bug quietly. stderr rather than stdout because
`tests/test-coordination.sh` and `tests/test-panes.sh` pipe `read` into
`grep -q`, and the site documents a bare `for w in …; do roost read "$w"; done`
loop.

A reply recorded at the end of one turn is not cleared at the start of the next
— that would throw away a reply the caller was merely slow to collect. Instead
`read` reports it as stale when `@agent_state` says the pane is `working` or
`blocked`, and prints it anyway.

`roost reply TEXT` is the public write end, for a harness with no adapter. It
takes argv, never stdin, so no public command can block waiting for input, and
it refuses to write unless the caller's `$TMUX` names this server — a
`$TMUX_PANE` from another server is a perfectly valid pane id here, and an
unguarded write would land on a real, unrelated pane with nothing reporting an
error.

Replies are capped at 12288 bytes with a visible truncation marker. tmux
rejects an over-long *command*, not an over-long value: measured by binary
search on tmux 3.6 (Darwin arm64, isolated `-S` socket), a value of 16332 bytes
is accepted and 16333 is rejected. The cut lands on the last newline inside the
budget, which is a single ASCII byte and therefore provably not inside a
multi-byte character.

Tests in `tests/test-reply-channel.sh` cover the round trip, tmux format syntax
inside a reply, the stale notice, pane-scope isolation, the loud fallback with
clean stdout, both truncation paths, the cross-server guard, and the Stop hook
including its early-bail case. `tests/opencode-plugin-harness.mjs` covers the
part filtering and the reply-before-`done` ordering offline.
