# A real reply channel for `roost read`

Status: **approved and implemented** — all three open questions resolved as
recommended (`roost screen`, head truncation, `roost reply` shipped)
Date: 2026-08-23
Size: **Build** (adds a subcommand, changes `roost hooks` output, changes what
an existing command returns)
Base: `3551a1e` — `main` at "Ignore the whole .claude/ directory"

Fixes `docs/airig/issues/2026-08-21-read-returns-tui-chrome.md`.

## Why

`roost read TGT N` is `capture-pane | grep -v blank | tail -n N`. For a shell
pane that is exactly right. For a full-screen TUI the bottom of the pane is
furniture — an input box and status bars — so `read` returns chrome instead of
the reply, which breaks the one step the whole coordination skill is written
around. The issue doc has the full failure, including a live opencode agent
correctly refusing to name a "last non-blank line" in the result.

The shape of the problem: `capture-pane` reads a **rendering**, and a reply is
**content**. Nothing in the rendering marks where one ends and the other begins.

So stop scraping and record the content at the moment the agent produces it.
Both adapters — `scripts/roost-agent-state` (Claude Code hook) and
`adapters/opencode/roost.js` — already fire at the end of every turn and already
know the pane. That is the cheap route the issue doc named, and the verification
below confirms both can actually reach the text.

## What was verified, and how

Everything in this section was executed on this machine on 2026-08-23. Nothing
here is quoted from memory or from a type definition alone — §9 of `AGENTS.md`.

### Claude Code: the `Stop` hook carries the reply directly

Method: an isolated `claude -p` run with `--settings` pointing at a throwaway
settings file whose `Stop`, `PostToolUse` and `SessionEnd` hooks each dumped
their stdin payload to a file. Nothing under `~/.claude/` was touched. Prompt:
run a bash command, then reply with three known lines.

| hook | `last_assistant_message` |
|---|---|
| `PostToolUse` | **absent** |
| `Stop` | `'LINE-ONE\nLINE-TWO\nLINE-THREE'` |
| `SessionEnd` | **absent** |

Full `Stop` key set: `session_id`, `transcript_path`, `cwd`, `prompt_id`,
`permission_mode`, `hook_event_name`, `stop_hook_active`,
**`last_assistant_message`**, `background_tasks`, `session_crons`.

Two things follow. The reply is handed over as a plain string, so the transcript
JSONL never has to be parsed. And `Stop` is the **only** one of the three that
carries it, so `Stop` is the event this design hangs on — the same event that
already reports `done`.

Multi-line content survived byte-for-byte, and the value is the final assistant
message only: the text emitted before the tool call is not included.

### opencode: `message.part.updated`, **not** `session.next.text.ended`

Method: opencode 1.18.20, an isolated `XDG_CONFIG_HOME`/`XDG_DATA_HOME` holding
a single spy plugin that appended every `event.type` (plus any text field) to a
log; `opencode serve` on a scratch port; a session created and prompted over the
HTTP API with a free model, asking for two known lines.

The real stream, trimmed to the parts that matter:

```
message.updated role=user
message.part.updated PARTTEXT="Reply with exactly two lines: PLUM-ONE …" partType=text
session.status status="busy"
message.updated role=assistant
… message.part.delta ×N …
message.part.updated PARTTEXT="The user is asking me to reply with …" partType=reasoning
message.part.updated PARTTEXT="" partType=text
… message.part.delta ×N …
message.part.updated PARTTEXT="PLUM-ONE\nPLUM-TWO" partType=text
message.updated role=assistant
session.status status="idle"
session.idle
```

Findings, each of which changes the design:

- **`session.next.text.ended` never fired.** It is declared in this build's
  OpenAPI schema with a required `text` field, and the literal string is present
  in the shipped binary (3 occurrences), so reading the schema alone would have
  produced a design built on an event that this version does not emit on a
  normal turn. This is precisely the "a grep hit is not proof a thing is live"
  case in `AGENTS.md` §9, and it is why the live run was worth the cost.
- **`message.part.updated` carries the whole text, cumulatively.** The same part
  id is re-sent as it grows (`""` → the full text); `message.part.delta` carries
  the increments separately. So the last `message.part.updated` for a text part
  holds the complete text and nothing needs to be reassembled from deltas.
- **`message.updated` for the assistant carries metadata only.** Confirmed
  against the schema: `AssistantMessage` has `id`, `role`, `time`, `cost`,
  `tokens`, … and **no** parts array and no text. It cannot supply the reply.
- **`session.idle` carries only `sessionID`.** It is the turn boundary, not the
  content — so the text must be held in the plugin between the part event and
  the idle event.
- **Reasoning is delivered through the same event** with
  `part.type === "reasoning"`. Not filtering on `part.type === "text"` would
  publish the model's thinking as its reply.
- **The user's own prompt also arrives as `message.part.updated` /
  `partType=text`.** So the part must be tied to an assistant message.
  `message.updated` with `info.role === "assistant"` fires **before** its text
  parts (visible above), so the assistant message id is known in time.

A plugin's `event` hook does receive these bus events — confirmed separately by
the spy plugin logging `session.created` from a bare `opencode serve`.

### tmux: a pane option survives hostile text, and caps at 16 KiB

Method: a throwaway `-S` socket (`mktemp -d`), per `AGENTS.md` §2 and §8.

Stored a value containing newlines, a tab, `#{pane_id}`, `#[fg=red]`, and a
literal `%`. Read back through **both** `show-options -p -v` and
`display-message -p '#{@roost-reply}'`: byte-identical to what went in, under
`od -c`. tmux does **not** re-expand a substituted option value, so an agent
reply containing tmux format syntax — entirely plausible in this repo — is safe.

`show-options -p -t %N -qv` on an **unset** pane option exits 0 with empty
output. That is the same shape that already bit `wait-done` (see the comment at
`bin/roost:456`), so emptiness, not exit status, is the test.

Size limit, found by binary search:

| value length | result |
|---|---|
| 16332 bytes | accepted |
| 16333 bytes | `command too long` |

The cap is on the whole tmux command line (≈16384 bytes), not the value, so the
usable budget shrinks by the length of `set-option -p -t %N @roost-reply `.
**This is a hard, measured constraint and it shapes the design.** Method
recorded so it can be re-measured: tmux 3.6, Darwin arm64, isolated `-S` socket.

Pane ids are **not** reused: killing `%1` and splitting again yielded `%2`.
Within one server run an id is unique, and a server restart destroys every pane
option along with the panes, so a pane option cannot outlive what it describes.

### The runtime-dependency constraint

`scripts/roost-doctor:31` records an existing decision in a comment:

> python3 is not required at runtime — roost init prints the hooks for you to
> merge by hand; only the test suite uses python3.

`grep -rn '\bjq\b\|python3' bin/ scripts/ install.sh adapters/ tmux/` returns
that comment and nothing else. So no shipped code path may **require** a JSON
reader. This is the single hardest constraint on the Claude half, and §"The JSON
problem" below is about nothing else.

## Design

### Where the reply is stored: a pane option, `@roost-reply`

`tmux set-option -p -t %N @roost-reply "<text>"`, alongside the `@agent_state`
and `@agent_since` the hook already stamps.

Why the pane option rather than a file keyed by pane id:

| | pane option | file keyed by pane id |
|---|---|---|
| Lifetime | exactly the pane's | outlives it; needs pruning |
| Server restart | gone with the server | **stale file, new server, same `%N` → the wrong reply, silently** |
| Cleanup owner | nobody — tmux frees it | a pruner nobody runs |
| Permissions | inside the tmux socket, already `0700` | a new secrets-bearing path in `/tmp` to get right |
| Size | **capped at ~16 KiB, measured** | unbounded |
| New moving parts | none | a directory, a naming scheme, a pruner |

The file route trades a bounded, visible limitation for an unbounded, silent
one. A stale reply returned as fresh after a server restart is the exact
failure shape this project treats as worst: wrong, plausible-looking, and quiet.
The pane option's lifetime is the *right* lifetime for free.

Naming: `@roost-reply`, with the `@roost-` prefix. It is **not** `@agent_reply`.
`AGENTS.md` §6 reserves the unbranded `@agent_` prefix for the two options both
servers' hooks share; this is a roost feature, so it takes the roost prefix.

Nobody cleans it up. That is the point.

### Staleness: never clear it, report it instead

A reply recorded at the end of turn N is still sitting on the pane during turn
N+1. Two ways to stop that being read as fresh:

1. **Clear `@roost-reply` when the pane transitions to `working`.** Simple, but
   it destroys a reply the coordinator was merely slow to collect.
2. **Keep it, and have `read` say when it is not current.** `@agent_state`
   already answers this: if the pane is `working` or `blocked`, any recorded
   reply is by definition from a previous turn. `read` prints it and adds a
   stderr line saying so.

**Take (2).** It cannot mislead — the caller is told — and it does not throw
away data. It also needs no new write on the hot path.

`@agent_since` is not reused for the reply's own age: it is stamped on every
state change, so it dates the state, not the reply. If an age is wanted later,
that is a separate `@roost-reply-at`, and adding one is a decision, not a
tidiness reflex — cf. the "do not add a third unset for `@agent_since`" note in
the rename spec.

### Ordering: the reply is written **before** the state flips to `done`

This is load-bearing and easy to get backwards. The documented idiom is:

```sh
roost wait-done "$helper" 120
roost read "$helper" 40
```

`wait-done` returns the instant `@agent_state` stops being `working`/`blocked`.
If `done` were stamped first, `read` could fire into the gap before
`@roost-reply` was written and fall back to the screen — reintroducing the bug
intermittently, which is worse than reintroducing it consistently.

So, in both adapters: **write the reply, then the state.**

In `scripts/roost-agent-state` this also has to sit **above** the unchanged-state
early bail at line 72 (`[ "$state" = "$prev" ] && exit 0`). A `Stop` arriving
when the pane already reads `done` — a turn with no `UserPromptSubmit`, a
re-entrant stop — would otherwise bail out before recording anything. Guarding
the reply write on `state = done` keeps `PostToolUse` (which fires on every tool
call and which Claude blocks on) at its current one-read-then-bail cost.

### The JSON problem, and how it degrades

The `Stop` payload is JSON on stdin. `last_assistant_message` is a JSON string:
it will contain `\n`, and it can contain `\"`, `\\`, and `\uXXXX`. Unescaping
that in pure bash is a meaningful amount of shell whose failure mode is a
**subtly corrupted reply** — wrong, plausible, silent. That is not a trade worth
making to avoid a process spawn that happens once per turn.

Nor may a JSON reader be *required*, per the constraint above.

So: **prefer `python3`, then `jq`, and if neither is present record nothing.**
`read` then falls back to the screen and says so, which is exactly the
already-designed no-reply path — no new failure mode, and the feature is an
enhancement rather than a dependency. Cost is one process spawn on `Stop` only,
never on `PostToolUse`; by the rename spec's own measurements a spawn is ~0.57
of a tmux round trip, and the hook already makes several.

`roost doctor` gains an optional check: neither reader found → warn that
`roost read` will fall back to the pane's screen, and name why.

### Reading stdin must not be able to hang

`roost state` is a documented public command that humans and third-party
adapters call by hand. If it grew an unconditional stdin read it would block
forever on a terminal. Two guards, both required:

- The stdin read happens **only** on the hook path, behind an explicit flag —
  `roost-agent-state done --stop-hook` — never on the plain `roost state done`
  path.
- The public verb takes its text as **argv**, not stdin (below), so no public
  entry point ever reads stdin at all.

### Truncation is visible, never silent

Measured ceiling is ~16332 bytes for the whole command. Cap the stored reply at
**12288 bytes** (12 KiB), leaving generous headroom for the command prefix and
any future field, and append a marker line:

```
[roost: reply truncated — 12288 of 41902 bytes]
```

Keep the **head**, not the tail: a reply cut from the front reads as if it began
mid-sentence, and the reader cannot tell that from a genuinely odd answer. A
marked tail-truncation is honest but less useful; a marked head-truncation is
honest and still readable. The marker is the point either way — a silently
shortened reply is the same class of bug as a scraped one.

If replies routinely exceed 12 KiB in practice, the file-backed store is the
escape hatch, and it should be adopted deliberately with the pruning and
permissions questions answered — not reached for the first time a reply is long.

### `roost hooks` output changes

The `Stop` entry becomes:

```
"$ROOST_HOME/scripts/roost-agent-state" done --stop-hook
```

`UserPromptSubmit`, `Notification` and `PostToolUse` are untouched. Users who
copied the old block keep working — they simply never record a reply, and
`read` tells them so on every fallback. `roost doctor` gains a check for a
`Stop` hook still wired without `--stop-hook`, naming the exact fix, in the same
shape as the existing stale-`amux-agent-state` check.

### The opencode adapter

Add to `adapters/opencode/roost.js`, keeping the existing state machine intact:

- On `message.updated` with `info.role === "assistant"`, remember `info.id`.
- On `message.part.updated` where `part.type === "text"` **and**
  `part.messageID` is that remembered id **and** `part.synthetic` is not true,
  hold `part.text` as the pending reply, replacing whatever was held. Cumulative
  re-sends make the last one the complete text; ignoring `reasoning` parts keeps
  the model's thinking out of the reply.
- On `session.idle`, **await** publishing the reply, then report `done`.
- On `session.error` / turn start, drop the pending reply so it cannot attach to
  the wrong turn.

A turn whose assistant message has several text parts separated by tool calls
keeps the **last** one. That matches what Claude Code's `last_assistant_message`
returned for exactly that shape (verified above: the pre-tool text was not
included), so the two harnesses agree on what "the reply" means.

The adapter publishes via a new public verb rather than by calling `tmux`
itself: it currently owns no tmux knowledge and should keep owning none.

### A new verb: `roost reply TEXT`

```
roost reply TEXT...    record TEXT as this pane's reply, for `roost read`
```

Stamps `@roost-reply` on the caller's own pane, from `$TMUX_PANE`, and is a
silent no-op outside a roost server — the same contract as `roost state`, and
for the same reason: it must be safe to leave in an adapter that sometimes runs
elsewhere. Text comes from **argv**, so nothing can block on stdin.

This also completes the story `skills/roost/SKILL.md` already tells under
"Reporting your own state": an agent whose harness has no adapter can badge
itself with `roost state`, and can now post its reply with `roost reply`.

### `read` keeps its name; `screen` is added beside it

`AGENTS.md` §7 and the issue doc both argue the present name over-promises. It
does — but the fix is to make it deliver, not to retire it. Two facts decide
this:

- The documented coordination idiom ends with `roost read TARGET` — "collect the
  result". Renaming that step to something else leaves every existing caller,
  and every third party holding an older `SKILL.md`, on the broken path
  silently. Making `read` return the reply fixes them all without their doing
  anything.
- The raw screen is **also** genuinely wanted, and is documented today:
  `SKILL.md`'s exit-1 guidance says to "`roost read` it to see what's stuck".
  That use needs the rendering, chrome included.

So:

| verb | returns |
|---|---|
| `roost read TGT [N]` | the recorded reply if there is one; otherwise the screen, **with a stderr notice** |
| `roost screen TGT [N]` | always the pane's screen — today's `read`, honestly named, no notice |

`roost screen` is what `SKILL.md`'s stuck-pane guidance should point at.

**`N` applies to the screen only.** A recorded reply is returned whole.
Applying `tail -n N` to it would chop the beginning off a long reply — and
`SKILL.md` passes `40` today, which would silently truncate anything longer.
The help text has to say this outright, because "read TGT 5 returned 200 lines"
is otherwise a surprise.

### The no-reply notice

Goes to **stderr**, so stdout stays clean:

```
roost read: no recorded reply for '%7' — showing the pane's screen instead.
roost read: (that pane has no roost adapter, or its turn has not finished)
```

Not silent, per the task brief: a silent fallback re-creates the current bug
quietly. Not on stdout, because `tests/test-coordination.sh:242` and
`tests/test-panes.sh:31` both pipe `roost read` into `grep -q`, and the
documented `for w in …; do roost read "$w"; done` shell idiom would be polluted.

Shell panes will emit this notice every time. That is correct — a shell pane
genuinely has no reply channel — and the message says why rather than just
reporting an absence.

A stale reply gets its own notice and still prints the reply:

```
roost read: '%7' is working — this reply is from its previous turn.
```

## Oracle — how we know it worked

Automated, in `tests/`, isolated `-S` sockets throughout (`tests/lib.sh`).

| Check | Type | Asserts |
|---|---|---|
| `roost reply` then `roost read` round-trips a multi-line value | Automated | The reply channel works end to end |
| A reply containing `#{pane_id}`, `#[fg=red]`, a tab and `%` survives | Automated | No tmux format re-expansion (regression-locks the finding above) |
| `roost read` on a pane with no `@roost-reply` falls back **and** writes to stderr | Automated | The fallback is loud, and stdout is clean |
| `roost read`'s stdout is unchanged for a shell pane | Automated | `test-coordination.sh` / `test-panes.sh` still pass unmodified |
| A >12 KiB reply is stored truncated **with** the marker | Automated | Truncation is visible, and the tmux limit is never hit |
| `roost read` on a `working` pane holding an old reply emits the stale notice | Automated | Staleness cannot be read as freshness |
| `roost screen` returns what `read` returns today | Automated | The old behaviour is still reachable |
| `roost reply` outside a roost server is a silent no-op, exit 0 | Automated | Same contract as `roost state` |
| `roost state done` (no flag) does not block on a terminal | Automated | The stdin hazard is closed |
| opencode harness: text/reasoning/user parts, and reply-before-`done` ordering | Automated | `tests/opencode-plugin-harness.mjs`, offline, no model call |
| `roost doctor` warns on a `Stop` hook wired without `--stop-hook` | Automated | The self-closing signal exists |
| A live Claude pane and a live opencode pane each return their real reply | **Human-eye** | The thing the issue is actually about |

The human-eye check is one pass at the end, on the live `-L roost` server, and
is the only step that touches it. `python3 tests/test-contrast.py` runs as well;
a non-zero exit from `tests/run.sh` is a crash even if the counts look fine
(`AGENTS.md` §8).

## Blast radius

Derived by grep, not memory (`AGENTS.md` §9):
`grep -rn "roost read" .` and `grep -n 'read' README.md`.

| File | Line(s) | What changes |
|---|---|---|
| `bin/roost` | 21 | help header: `read`'s description; new `reply` and `screen` lines |
| `bin/roost` | 445–448 | the `read)` branch — prefer `@roost-reply`, fall back, notice |
| `bin/roost` | 538 | the `usage:` synopsis |
| `scripts/roost-agent-state` | 66–79 | record the reply above the early bail, before the state write |
| `scripts/roost-doctor` | 31, ~57 | JSON-reader check; `Stop`-hook-without-flag check |
| `adapters/opencode/roost.js` | 82–130 | hold the last assistant text part; publish before `done` |
| `skills/roost/SKILL.md` | 67, 103, 162 | `read` now returns the reply |
| `skills/roost/SKILL.md` | 93 | exit-1 guidance should point at `roost screen` |
| `skills/roost/SKILL.md` | 114, ~145 | helper-pane example; `roost reply` beside `roost state` |
| `site/content/docs/driving-a-fleet.md` | 3, 14, 37 | frontmatter description, the `read api 20` example, the bullet |
| `tests/test-coordination.sh` | 228 | the subcommand list gains `reply` and `screen` |
| `tests/test-coordination.sh` | 242–244 | unchanged, and must stay passing — the fallback proof |
| `tests/test-panes.sh` | 28–31 | unchanged, same role |
| `tests/opencode-plugin-harness.mjs` | 52–99 | new event fixtures and cases |
| `docs/airig/issues/2026-08-21-read-returns-tui-chrome.md` | — | marked FIXED, in the shape used for the send-permission-dialog issue |
| `README.md` | 132 | the one-line `bin/roost` inventory names the subcommands |

`README.md` contains no `roost read` invocation — only that inventory line.
Per `AGENTS.md` §11, user-facing detail belongs in `site/content/docs/` and the
README stays contributor-facing, so the reply channel is documented on the site
and the README is not given a second copy.

### Noticed in passing, not fixed here

`site/content/docs/driving-a-fleet.md:39` says "a pane's state is shared with
its window, so `wait-done` on it is not per-pane". `bin/roost:461` and
`skills/roost/SKILL.md:54` both say the opposite, and per-pane state is the
whole point of the `-p` stamp in `scripts/roost-agent-state:78`. The site line
is wrong. It is adjacent to the lines this work edits but it is a different bug,
so it is recorded here rather than swept into this change.

## Risks

| Risk | Mitigation |
|---|---|
| The reply is never written, so `read` returns **nothing** — worse than chrome | `read` never returns nothing: absence falls back to the screen and says so on stderr. This is why the fallback is kept rather than replaced |
| A stale reply is returned as if fresh | The stale notice, keyed on `@agent_state` being `working`/`blocked` |
| `read` races `wait-done` and misses a reply written a moment later | The reply is written **before** the state flips to `done`, in both adapters |
| A user's old `Stop` hook records nothing, forever, unnoticed | The stderr notice fires on every fallback; `roost doctor` names the exact fix |
| No `python3`/`jq` on the machine | Degrades to the fallback path, which is already designed and already loud. No hard dependency added — the `roost-doctor:31` constraint holds |
| A reply longer than the tmux command limit | Capped at 12 KiB with a visible marker; the ceiling was measured, not assumed |
| A reply containing tmux format syntax corrupts the read | Verified byte-identical through both read paths, and locked by a test |
| Reading stdin makes `roost state` hang on a terminal | Stdin is read only behind `--stop-hook`; the public `roost reply` takes argv |
| The opencode adapter publishes the model's *reasoning* as the reply | Filter on `part.type === "text"`; the reasoning part was observed on the same event in the live run |
| The opencode adapter publishes the *user's* prompt as the reply | Match `part.messageID` against the assistant message id from `message.updated` |
| A dead tmux server breaks the agent being badged | Every new tmux call carries `|| true`, matching every existing call in the hook |
| `roost screen` becomes a second name nobody uses | It is what `SKILL.md`'s stuck-pane guidance is repointed at, so it has a documented caller from day one |

## Open questions — all resolved 2026-08-23

1. ~~**`roost screen` as the name.**~~ **Resolved: `screen`.** `peek` and
   `capture` were the alternatives; `screen` matches the issue doc's own
   phrasing ("what is on that pane's screen").
2. ~~**Head-truncation at 12 KiB.**~~ **Resolved: head, with a marker.**
   Tail-truncation was defensible if replies are expected to end with their
   conclusion; head won on readability.
3. ~~**Whether `roost reply` ships at all.**~~ **Resolved: it ships.** It keeps
   tmux knowledge out of the JS adapter, and it gives adapter-less harnesses
   the same story `roost state` gives them.

## Corrections found during implementation

One thing this document got wrong, recorded rather than quietly edited, because
the shape of the error is the useful part.

**The multi-byte truncation reasoning was incomplete.** The design said to cut
at the last newline within the byte budget and, failing that, to accept a raw
byte cut. That is right, but it omits *why* the newline rule is the one that
works: a newline is the boundary, not merely a convenient one. Every attempt to
find the boundary by walking backwards off UTF-8 continuation bytes is
unsound — a trailing continuation byte belonging to a *complete* character is
indistinguishable, looking only backwards, from one belonging to a character
the cut split in half. The newline rule sidesteps that entirely: `\n` is a
single ASCII byte and can never appear inside a multi-byte sequence, so a cut
there is provably clean without any lookahead.

The implementation follows the design; this note exists so that the next person
tempted by the "just strip the continuation bytes" version knows it was
considered and is wrong.

## Found after the rebase: subagents

This branch was rebased onto a `main` that had gained a subagent filter for the
opencode adapter (`CHILD_MUTED`). Both changes are correct alone; their
interaction was not, and no test covered it because each side tested only its
own half.

`CHILD_MUTED` covered `session.status`, `session.idle` and `session.error` —
the child's *lifecycle*, which is all the badge cares about. It did not cover
`message.updated` or `message.part.updated`, so a child session's *speech* fell
straight through into the reply collector. Two failures, not one:

1. the child's `message.updated` took over `assistantID` and cleared `pending`,
   so the child's text was collected and the parent's `session.idle` published
   it; and
2. the parent's own later text parts were then rejected for not matching the
   hijacked id — the wrong answer did not merely appear, it crowded out the
   right one.

**Input:** an opencode turn that calls the `task` tool and then answers.
**Wrong output:** `roost read` returned `SUBAGENT OUTPUT` instead of the
parent's answer. Reproduced offline in
`tests/opencode-plugin-harness.mjs` before the fix (4 failing cases), and the
fix backed out again afterwards to confirm the cases fail without it.

The fix adds both message events to `CHILD_MUTED` rather than keying
`assistantID`/`pending` by session. A per-session map is a second unbounded
structure that has to be consulted on the parent's idle to mean anything, and
it buys nothing here: muting the child leaves `assistantID` pointing at the
parent's message, so one line fixes both failures.

A turn where **only** the subagent spoke now publishes nothing, and `read`
falls back to the screen with its notice. That is the intended outcome, not an
over-filter: the pane's own agent did not answer, and a subagent's output was
never addressed to the caller. Only a session id carrying a `parentID` is ever
added to `children`, and a pane's own session has none, so the pane's own
speech can never be muted by this.

The general lesson matches the pattern the rename spec keeps recording: two
things sitting in one set are not automatically the same kind of thing.
`CHILD_MUTED` was named and reasoned about as a *lifecycle* filter, so the
reply channel's events were never weighed against it — until the two met.

## Non-goals

- No change to `@agent_state` or `@agent_since`, in name or in scope.
- No file-backed store. Recorded above as the escape hatch if 12 KiB proves too
  small in practice.
- No parsing of Claude Code's transcript JSONL — the `Stop` payload already
  carries the message.
- No sender attribution on replies. `SKILL.md`'s "prefix who you are" convention
  is unaffected and remains the caller's job.
- No fix for the `driving-a-fleet.md:39` per-pane-state error noted above.
