# `roost read` returns TUI chrome, not the reply, for agent panes

Found 2026-08-21 during a live agent-to-agent test between a Claude Code pane
and an opencode pane. **Not fixed.** Recorded because the failure is silent and
sits in the middle of the workflow the skill is written around.

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
