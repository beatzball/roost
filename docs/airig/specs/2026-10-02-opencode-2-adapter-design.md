# An adapter for opencode 2 — design for #150

Status: **proposed 2026-10-02, revised the same day after review. Not approved,
nothing built.** The one decision that was the human's to make, Q1, is answered
(§8). A jury of three reviewed the first version and all three asked for
changes; §9 says what they found and what changed. The rest still waits for
agreement.

Base: `main` at `8cbafa1`, which is PR #153 merged. This builds on it: #153
added `scripts/lib/roost-opencode.sh`, bounded the version check, and stopped
`roost wiring` setting `OPENCODE_CONFIG_DIR` for opencode 2 (#154).

Measured on opencode **2.0.20**, macOS arm64, 2026-10-01 and 2026-10-02, with
`HOME`, the four `XDG_*_HOME` directories and `TMPDIR` redirected, the TUI in
panes of a throwaway `tmux -S` server, and a spy plugin. The raw sequences are
in #150 and its comments and are not repeated here; this document quotes the
result. Anything not executed is labelled *not measured*. opencode 2 shipped
two releases during these two days. Every event name below is a 2.0.20 fact,
not a promise.

Size: **Build.** A new adapter, a new install path, and a new test harness that
`roost install`, `roost doctor` and CI will depend on.

---

## 0. The short answer

opencode 2 needs its own adapter, and it is a different kind of plugin from the
1.x one — not a port.

- 1.x: one plugin, loaded by the opencode process in the pane. It finds its
  pane from `$TMUX_PANE`.
- 2.x: a "server" plugin runs in a **shared background server**, one per user,
  and sees whichever pane started that server. It cannot badge a pane. A
  **terminal-side** plugin runs in the TUI process, which is the pane's
  process, and sees the right `$TMUX_PANE` in every pane (measured, two panes).

So the adapter is a terminal-side plugin. It hears every chat's events, keeps
each chat's state, and makes the pane say what is true of the chat **its own
terminal is showing**. That last part is new: a 2.x terminal holds several
chats as tabs, and roost has one badge per pane.

What is built: `adapters/opencode/v2/tui.js`, a link to it from
`roost install`, a doctor check, an offline test in `tests/run.sh` that drives
the real plugin entry point, and a live smoke test that drives a real
opencode 2.

What is not: one window per chat (#151), and send/read through opencode's
server (#152).

---

## 1. What was settled before this document

Decided by the human on 2026-10-01 (the peck round on #150):

| # | decision |
|---|---|
| D1 | A pane is one agent. Its badge follows **the chat on screen**. A hidden tab that is working or waiting shows nothing; that is a known gap, not a bug. |
| D2 | roost does not change how opencode is started. No `--standalone`, no disabling the service. |
| D3 | Same features as 1.x: the five badges and the reply channel. Nothing more. |
| D4 | opencode 1.x stays supported, from the same `roost install`. |
| D5 | The oracle is automated: a test drives real opencode 2 and asserts the badges with no person looking. |

Assumed then, unchallenged since: a chat open in two panes badges both;
subagent chats are muted except their permission dialogs; roost never edits the
user's own opencode files.

---

## 2. What the measurements say

### 2.1 Where a plugin runs

| plugin kind | file | process | `TMUX_PANE` it sees |
|---|---|---|---|
| server | `<config>/opencode/plugins/x.js` | `opencode serve --service`, ppid 1 | the pane of whoever started the service |
| terminal-side | `<config>/opencode/plugins/<name>/tui.js` | the TUI, child of the pane's shell | its own pane |

A plain default export `{ id, setup(context) }` loads. No import of the plugin
package is needed, so the adapter stays one dependency-free file, as on 1.x.

### 2.2 Every terminal hears every chat

`context.data.listen(fn)` delivers the server's events as `{ name, details }`,
payload at `details.data`, session at `details.data.sessionID`. A turn typed in
pane `%1` was delivered whole to the plugin in pane `%0`.

`context.ui.router.current()` is per terminal: `{ type: "home" }`, or
`{ type: "session", sessionID }`. It is the only thing that tells two terminals
apart. `context.ui.tabs.list()` is shared across terminals and is not.

`context.data.session.status(id)` is synchronous and returned `"idle"` or
`"running"`. It has no value for blocked, done or failed.

**Switching the front tab emits no event** (`alt+up` / `alt+down`, two chats,
one terminal: the screen changed, the plugin heard nothing).

### 2.3 How a turn runs and ends

```
session.execution.started
  session.reasoning.started / .ended   the model's thinking — its own events
  session.text.ended            data.text = one whole text part
  permission.asked / permission.replied
  session.retry.scheduled       data.attempt (2 = first retry), data.error
then exactly one of:
session.execution.succeeded
session.execution.failed        data.error
session.execution.interrupted   data.reason = "user" (Esc Esc) | "shutdown" (a dialog answered Reject)
```

Reasoning arrives as `session.reasoning.*`, separately from `session.text.*`,
in the one turn where the model reasoned. So `text.ended` is the model's
prose, which is what the contract requires the reply to be.

Nothing success-shaped follows a failure: on a dead provider the stream was
ten `retry.scheduled`, `step.failed`, `execution.failed`, and then nothing. The
1.x adapter's `died` flag and retry counter have no job here.

### 2.4 Subagents

The tool is `subagent`. The child is its own session; its `session.created`
carries `parentID`. Its lifecycle, its text and its permission events all carry
the **child's** id. Its dialog is drawn in the parent's terminal. Its
`execution.succeeded` arrives before the parent's.

`context.data.session.root(<child>)` returned the child's own id for the first
four seconds of the child's life, and the parent after that. In the one run,
the child's `permission.asked` came five seconds in, after `root()` had become
right.

### 2.5 What a plugin with no memory can find out

A second terminal was started on a chat **after** that chat's
`permission.asked`, so its plugin never heard the event. In it:

- `context.data.session.permission.list(id)` returned nothing until
  `await context.data.session.permission.sync(id)` had run, and then returned
  the pending request — its id, session, action and resources.
- `status(id)` was `"running"`.

So an open dialog can be recovered by a plugin that did not see it open.
Measured for a dialog of the chat itself. *Not measured* for a dialog that
belongs to a child of the chat (A1, §5).

### 2.6 A reload

Editing the plugin file while two terminals ran it: in each, the old
instance's cleanup function ran, a new instance was set up in the same
process, and the old instance's interval stopped ticking. So a reload is clean
— and the new instance starts with no memory at all. A roost update that
changes the adapter file is a reload in every open opencode terminal, possibly
in the middle of a turn. (*Not measured*: whether a change to the **target** of
a symlinked plugin directory triggers the reload. The file edited was the one
in the config directory.)

### 2.7 Install shapes

| shape | on 2.0.20 | on 1.18.30 |
|---|---|---|
| `<config>/opencode/plugins/roost` → symlink to a directory holding `tui.js` | loads | ignored: no error, nothing logged |
| `<config>/opencode/plugin/roost.js` (the 1.x adapter) | `1 plugin failed` in the TUI footer | loads |
| `OPENCODE_CLI_CONFIG_CONTENT='{"plugins":["/abs/dir"]}'`, nothing in any config dir | loads; the user's `opencode.json` is still read | *not measured* |
| `OPENCODE_CONFIG_DIR` | loads, **and replaces the user's whole configuration** (#154) | merges |

### 2.8 What roost does with a reply (read in the code, not assumed)

- `roost reply TEXT` with non-empty text **appends a numbered turn** to the
  pane's kept record and then sets `@roost-reply` (`bin/roost`, the `reply)`
  branch). `roost send` predicts that number, and `wait-done --turn N` and
  `read --turn N` use it.
- `roost reply -` with **empty** input records no turn and sets `@roost-reply`
  to an empty value, which `roost read` treats as no reply: it falls back to
  the screen and says so. Nothing in `tests/` pins this today.
- A plain `roost state done` does not touch the stored reply. Only the
  `--stop-hook` paths clear it.
- `roost read` warns that a reply may be stale only when the badge is
  `working`, `blocked` or `error`. On `done` and `idle` it serves what is
  stored, silently.

### 2.9 Not measured

- `--standalone`, and a remote `--server`, with a terminal-side plugin.
- Whether `OPENCODE_CLI_CONFIG_CONTENT` drops the `plugins` list in the user's
  own `cli.json`. opencode's documentation says arrays in it replace.
- Compaction; a prompt queued behind a running turn; a turn started from
  another client (web, desktop) in a chat this terminal is showing.
- A terminal whose route is a **child** session (the user stepped into a
  subagent's chat).
- A retry that then succeeds. The only retry sequence recorded is the dead
  provider (A2, §5).
- Any event that says a chat was deleted.
- Linux. opencode 2 on tmux 3.4.
- What a 1-second interval costs in the TUI.

---

## 3. The design

### 3.1 One file; the pane is reconciled, not driven

`adapters/opencode/v2/tui.js`, default export `{ id: "roost", setup }`. The
directory is `v2/` because opencode discovers a terminal-side plugin as a
directory with a `tui.*` file in it.

The 1.x adapter turns each event straight into a `roost` call. That shape does
not survive two things 2.x adds: a front chat that changes with no event, and
a timer running beside the event listener. Two callbacks that each `await` a
child process can finish in either order, and the last writer wins.

So this adapter separates **what is known** from **what has been written**:

- Events only update a model (§3.2). They write nothing.
- One function, `reconcile()`, makes the pane match the model for the chat in
  front. It is the **only** code that runs `roost`. It runs serially: a second
  call while one is in flight sets a flag and returns, and the running one
  loops until the pane matches. After every `await` it re-reads the front and
  the model, so a write that became wrong while it was in flight is followed
  by the right one before the loop ends.
- Events and the timer both end by calling `reconcile()`.

`run()` — `execFile("roost", …)` with the reply on stdin, never throwing — is
the 1.x helper, comments and all, including `ROOST_AGENT_NAME=opencode`.
A missing API (`context.data.listen` absent on some later 2.x) leaves the pane
unbadged rather than broken.

### 3.2 The model: one entry per chat

A map from **root** session id to `{ state, text, due }`.

- `state` — `working`, `blocked`, `done`, `error`, or `idle`.
- `text` — what the turn in progress has said so far.
- `due` — a reply that is owed to the pane and not yet written: either
  `{ publish: TEXT }` or `{ clear: true }`, or nothing.

`children` maps a child id to its root, learned from `parentID` on
`session.created`. A `permission.*` event for an id that is neither a known
root nor a known child is resolved with `context.data.session.root(id)` before
it is filed (§2.4: by the time a child asks, `root()` was right).

| event | for the root it belongs to |
|---|---|
| `session.execution.started` (root's own) | `working`; `text = none` |
| `session.text.ended` (root's own) | `text = data.text` — the last one wins, as on 1.x |
| `permission.asked` (root's or a child's) | `blocked` |
| `permission.replied` (root's or a child's) | `working` |
| `session.retry.scheduled` (root's own) | `error` if `attempt >= 3`, else `working` |
| `session.execution.succeeded` (root's own), with text | `done`; if this chat is in front, `due = publish(text)` |
| `session.execution.succeeded` (root's own), no text | `done`; if in front, `due = clear` |
| `session.execution.failed` (root's own) | `error`; if in front, `due = clear` |
| `session.execution.interrupted` (root's own) | `done`; if in front, `due = clear` |
| a child's lifecycle, text, retries | ignored |

`attempt >= 3` is the 1.x rule — error at the second retry — read off
opencode's own counter. The known gap about a retrying-but-alive provider
wearing `error` mid-turn (`docs/known-gaps.md`) carries over unchanged.

`interrupted` → `done` is the 1.x judgement for Esc: the person who ended the
turn is sitting there. It also covers Reject, which opencode 2 reports the
same way.

**A turn that ends with no answer clears the stored reply.** Esc, Reject, a
failure, a success with no prose: the pane's stored reply is the previous
turn's, and on `done` `roost read` would serve it with no warning (§2.8). The
1.x opencode adapter has this hole today; that is recorded in
`docs/known-gaps.md` by this work and fixed for 1.x separately.

**A turn that finishes while its chat is hidden owes the pane nothing.** Its
text is not kept. See §3.3 for why, and §6 for what that costs.

The map is capped at 200 roots. Only entries in `done`, `error` or `idle` are
evicted; a `working` or `blocked` chat is never dropped. An evicted or
never-seen chat is **unknown**, which §3.3 handles the same way as a chat met
for the first time.

### 3.3 What `reconcile()` writes

`front` is the root of the session `router.current()` names, or none on the
home screen. `written` is what this adapter last wrote: `{ front, state }`.

Each pass, in this order:

1. **The front changed** (`front != written.front`). The pane is now about a
   different chat, so the stored reply is not this chat's:
   **clear it** — an empty `roost reply -` (§2.8) — and forget
   `written.state`. Then, if the new front is unknown, **recover** it (below).
2. **A reply is due** for the front chat: `publish` → `roost reply -` with the
   text; `clear` → the empty one. Then drop `due`.
3. **The state differs** from `written.state` → `roost state <state>`.

Reply before state, always: `wait-done` returns the moment the badge stops
being busy, and the documented idiom is wait-done then read.

**A reply is published exactly once, when a turn of the front chat ends.** It
is never re-published. The first version of this design re-published a
remembered reply on a tab switch, and all three reviewers found the same thing
wrong with it (§9): every non-empty `roost reply` is a new numbered turn, so
flipping between two tabs filled the record with duplicates, pushed real turns
out of it, and made `wait-done --turn N` and `read --turn N` return another
chat's old answer. So after a front change `roost read` has no recorded reply
for the pane and says so, until the chat in front finishes a turn. That is
weaker than restoring it and it is true.

**Recovering an unknown chat** — one this instance has no entry for: a chat
never seen, an evicted one, and every chat after a reload (§2.6):

1. `await permission.sync(id)`, then `permission.list(id)`: a pending request
   → `blocked`.
2. else `status(id) == "running"` → `working`.
3. else → `idle`.

Step 1 exists because of what its absence does: `roost send` refuses only a
`blocked` target, so a pane that reads `working` over an open dialog gets the
next prompt typed into the dialog.

**At `setup`, the pane is never downgraded.** A new instance — a fresh
terminal, or a reload mid-session — recovers the front chat, and writes only if
the answer is `blocked` or `working`. If it is `idle` it writes nothing and
clears nothing: after a reload the pane already holds the right `done` and the
right reply from the instance that was just replaced, and this one cannot know
that. `written` starts as "whatever is there".

**`idle` is reported on a front change, and the contract says adapters do not
report it.** That sentence in `2026-08-29-adapter-contract.md` is already not
true — the codex adapter reports `idle --stop-hook` on Interrupt — and the
contract is corrected to say when an adapter may: to take back a badge that is
no longer about the pane's chat.

A badge written on a front change is a **restatement**, not a transition, and
`error` and `blocked` ping the desktop. Read in `scripts/roost-agent-state`:
the ping is sent only when the pane's window is **not** the active one. A
person switching tabs is typing in that window, so a restated `error` does not
ping.

### 3.4 Noticing the front changed

No event says so (§2.2). `reconcile()` is called:

1. at the end of every event the plugin hears;
2. by a 1-second `setInterval` — its only job. It is cleared in the cleanup
   `setup` returns, which a reload was measured to run (§2.6).

One second because a badge that lags a tab switch by a second is invisible. The
cost is one cheap call a second per open opencode terminal when nothing has
changed; *not measured* (R3).

### 3.5 Install, doctor, wiring, validate

**`roost install`**, when the opencode on `PATH` is 2.x
(`roost_opencode_v2`, from #153):

- links `<config>/opencode/plugins/roost` → `adapters/opencode/v2`;
- removes `<config>/opencode/plugin/roost.js` **if it is roost's own link** —
  it is what makes opencode 2 print `1 plugin failed`. Anything else at that
  path is left, as today.

When it is 1.x: exactly what it does today. The 2.x directory is not linked,
though 1.x would ignore it, so that a 1.x machine's config directory holds
nothing it does not use.

`scripts/lib/roost-adapters.sh` gains the 2.x path and target, so install and
doctor read one definition, as they do for every other adapter.

**`roost doctor`**, on 2.x: the "not supported yet" line from #153 is replaced
by the same four states every adapter has — linked, not installed, dangling,
not this install. The other 2.x lines from #153 stay.

**`roost wiring`** — the route that needs no `roost install` — does **nothing**
for opencode 2. Decided, Q1.

**`roost validate`** is a third reader of the adapter table and drives the
`opencode` on `PATH`. What it does when that is 2.x has not been traced. It is
read before step 4 of §5, and at the least it must not report a 2.x drive it
did not do as a pass.

### 3.6 What a user of both versions gets

One machine cannot run both against one data directory (1.18.30 fails with
`Database is not empty and has no session table` after 2.0.20 has used it), so
"both installed" in practice means one on `PATH`. `roost install` wires that
one. Switching majors means running `roost install` again; doctor says so,
because the link it expects for the version it finds is missing.

---

## 4. Tests — the oracle

The first version tested a pure core and left `setup`, the timer and the
process calls to a by-hand live run. Two wrong adapters passed all of it: one
with no timer at all, and one whose writes crossed (§9). So the offline test
now drives the **real entry point**.

**Offline, in `tests/run.sh` and CI.** `tests/opencode2-plugin-harness.mjs`,
Node only, no opencode:

- imports `tui.js` and calls `setup(context)` with a **fake context**:
  `data.listen`, `ui.router.current`, `data.session.status`,
  `data.session.permission.sync/list` and `data.session.root`, each scripted
  by the case;
- puts a **recording `roost` shim** on `PATH`, as the 1.x harness does and as
  the contract requires, so what is asserted is the real `execFile` path: the
  argv, the stdin, and the order the processes actually ran in. One variant of
  the shim sleeps on `reply`, to force the overlap §3.1 exists for;
- drives time with Node's mock timers, so "a second passed and nothing else
  happened" is a step a case can take.

The sequences are the ones recorded for #150, copied in whole with their
source noted. A case that has no recorded sequence is not written until one
exists (the contract: fixtures replay a recorded turn).

| case | asserts — as calls to the shim, in order |
|---|---|
| a turn with no tool | `state working`, `reply TEXT`, `state done` |
| a tool behind a dialog, allowed | `working`, `blocked`, `working`, reply, `done` |
| a subagent with its own dialog | the child's `succeeded` writes nothing; the child's text is never a reply; its dialog writes `blocked` (trap T1) |
| a subagent's dialog whose `session.created` was never heard | `blocked`, through `root()` |
| answered turn, then a turn ended by Esc Esc | second turn: `working`, **empty reply**, `done` — the first answer is not left behind |
| answered turn, then a turn ended by Reject | `working`, `blocked`, `working`, **empty reply**, `done` |
| answered turn, then a turn that succeeds with no prose | **empty reply**, `done` |
| a dead provider | `working`, `error` once at attempt 3, nothing through attempts 4–11, **empty reply**, still `error` after `failed` |
| two chats interleaved, front is A | only A's states and A's reply are written |
| front A → B → A → B, all four finished, **no events**, timer only | each switch: empty reply, then the state. **No non-empty reply is ever written** — the turn record cannot grow |
| front → a chat with an open dialog this instance never heard | empty reply, `blocked` |
| front → home | empty reply, `idle` |
| `setup` on a chat that is idle | **nothing written** |
| `setup` on a chat that is running / has a pending permission | `working` / `blocked`, and no reply call |
| the slow-`reply` shim: A succeeds, the front moves to B (running) while A's publish is in flight | the last `state` written is B's `working`, and the last reply written is the empty one |
| 201 chats, the oldest one `blocked` | it is not evicted; front → it writes `blocked` |
| no `roost` on `PATH`; an event with no session id; an unknown type; a null payload | nothing thrown |

Each event case is run once more with a second, unrelated chat's events
shuffled in. And the file is run once with the `setInterval` line removed by
the test itself: the timer-only case **must fail**, or the test is not testing
the timer.

**Against the real `roost`.** One case in `tests/test-reply-channel.sh`'s
shape, on a throwaway server: the A → B → A → B sequence through the real
`bin/roost`, asserting the number of turn files on disk does not change and
`roost read` reports no recorded reply. This is the assertion the first design
would have failed.

**Live, by hand and before any release that touches the adapter.**
`tests/live/opencode2-smoke.sh`, in the shape of `opencode-smoke.sh`:

- takes the binary as `ROOST_OPENCODE2_BIN` and **skips** unless it is set and
  is 2.x — it never runs whatever `opencode` is on `PATH`, because on a 1.x
  machine that is the wrong binary and on any machine the default data
  directory is the user's real one;
- redirects `HOME`, the four XDG directories and `TMPDIR`; checks
  `opencode debug paths` before starting anything; starts 2.x by absolute path
  in every pane; runs `opencode service stop` in an EXIT trap;
- writes `{ "action": "shell", "resource": "*", "effect": "ask" }` into the
  redirected config. Without a rule 2.0.20 runs a shell command with no
  dialog, and the `blocked` case would never be set up;
- drives a free `opencode/*` cloud model, as `roost validate --opencode-cloud`
  does, so it needs no account;
- asserts pane options, not screens: `done` and the reply after a plain turn;
  `blocked` while a dialog is open; `done` and no stored reply after Esc Esc;
  `error` against a provider on a closed port; two panes — pane A's badge does
  not move when pane B runs a turn; and **one terminal, two finished chats,
  `alt+down` and nothing else** — the badge and the stored reply change within
  three seconds. That last one is the only live check of the timer.

**Install and doctor**: stub-driven cases beside the existing ones in
`tests/test-install.sh` and `tests/test-doctor.sh`, with the 1.x stub as the
control for every 2.x assertion.

---

## 5. Order of work

Two things are measured before anything is built, because the design leans on
them and nobody has seen them:

- **A1** — a pending permission that belongs to a **child** session, seen by an
  instance that started after it was asked. If `permission.list` cannot show
  it, recovery (§3.3) has a hole for subagent dialogs and it is recorded as a
  gap.
- **A2** — a retry that then succeeds, recorded, for the fixture. Until it is,
  that case is not in the offline suite.

Then:

1. In roost itself: a test that pins "an empty `roost reply -` records no turn
   and reads as no reply". The adapter's clear depends on it and nothing holds
   it today. No new command.
2. `tui.js` and the offline harness, together. No opencode needed; this is all
   of the logic and all of the CI coverage.
3. The live smoke test against 2.0.x.
4. `roost install`, `roost-adapters.sh`, doctor, `roost validate`, and their
   tests.
5. Docs: State Badges gets a 2.x section; Setup and Troubleshooting lose the
   "not supported yet" lines; the adapter contract gets its corrected `idle`
   paragraph and a row in "Where each harness stands"; `known-gaps.md` gets
   the gaps in §6 and the 1.x stale-reply hole.

One PR.

---

## 6. Gaps this ships with

- **A hidden tab** that is working, blocked or failed shows nothing until it is
  brought to the front (D1).
- **After a tab switch `roost read` has no reply for the pane** until the chat
  now in front finishes a turn. It says so and shows the screen.
- **A turn that finishes while its chat is hidden records no reply at all.** A
  coordinator that sent the prompt with `roost send` and waits with
  `wait-done --turn N` waits until its timeout if a person tabbed away in that
  pane mid-turn.
- **After a reload or an eviction a finished chat reads `idle`, not `done`**,
  once it is switched away from and back to. `status()` cannot say more.
- **A front change is seen up to a second late**, or at the next event. For
  that second the badge and `roost read` describe the chat that was in front.
- **No badge without `roost install`** on opencode 2 (Q1). 1.x keeps its
  no-setup wiring.
- **A retrying-but-alive provider** reads `error` mid-turn, as on 1.x.
- Everything in §2.9.

---

## 7. Risks

- **R1 — the clear rests on behaviour nothing tests.** An empty `roost reply -`
  is how the adapter takes a reply back. It works today (§2.8) and step 1 pins
  it. If pinning it shows a case where it does not, stop: the adapter is wrong
  without a clear.
- **R2 — the API moves.** Two releases in two days. The live smoke test is the
  only thing that notices, and it is run by hand. `roost doctor` could warn on
  an opencode 2 newer than the last one the smoke test passed on; not in this
  design, worth deciding after the first break.
- **R3 — the timer.** One call a second, unmeasured. If it shows up anywhere,
  the fallback is events only, and a front change is then seen at the next
  event rather than within a second.
- **R4 — the first event of a new chat.** Typing the first prompt on the home
  screen, the route was already the new session when `session.created`
  arrived — in one sample. If the route can lag, `reconcile()` writes `idle`
  for the home screen and corrects itself within a second.
- **R5 — #141** (session id, directory and harness on the pane) is being built
  in parallel. This adapter knows the session id of the front chat and should
  stamp it the way that issue settles; it does not invent its own option.
- **R6 — recovery costs a network call.** `permission.sync` is awaited on every
  front change to an unknown chat. Its latency was not measured; while it is
  in flight the pane still shows the previous chat's badge.

---

## 8. Decisions

**For the human — one, and it is answered:**

**Q1. Should roost's no-install wiring reach opencode 2? — Decided 2026-10-02:
A, no.** opencode 2 badges only after `roost install`.

The question as it was put:

- **A. No.** opencode 2 badges only after `roost install`, like codex, pi and
  copilot. Nothing in a pane's environment is changed for opencode 2.
- **B. Yes**, by setting `OPENCODE_CLI_CONFIG_CONTENT` on the server to name
  the adapter directory. Measured to load the plugin and to leave
  `opencode.json` alone. By opencode's documentation it **replaces** the
  `plugins` list in the user's own `cli.json`, and it wins over that file for
  as long as it is set.

*Recommend A.* #154 was this same idea — a variable in every pane to save the
user one command — and it cost them their configuration. B is smaller, but it
is the same shape, on an API that is a few weeks old.

**Made by the author, open to challenge:**

- A terminal-side plugin, not `--standalone` (D2 rules the other out).
- State per root chat; the pane is reconciled to the front chat (D1).
- `interrupted` → `done` for both Esc and Reject.
- A reply is published once, when a turn of the front chat ends, and never
  re-published. A front change clears the stored reply. The alternative — a
  new way in roost to restore a reply without recording a turn — is more than
  D3 allows and is not proposed.
- A turn that ends with no answer clears the stored reply.
- A 1-second timer for front changes.
- `setup` never downgrades a pane.
- `idle` is reported on a front change, and the contract is corrected.
- `roost install` links exactly one opencode adapter: the one for the version
  on `PATH`.
- The live test never runs the `opencode` on `PATH`.

---

## 9. What the review changed

A jury of three read the first version on 2026-10-02 — two models in one
harness and a third in another, each on the whole document with the
measurements and the code beside it, none seeing another's report. All three
returned CHANGES_NEEDED. Each claim below was checked against the code before
it changed anything.

| finding | raised by | what changed |
|---|---|---|
| Re-publishing a reply on a tab switch appends a numbered turn each time: duplicates in the record, real turns evicted, `--turn N` answered by another chat | 3 of 3 | No re-publish. A front change clears (§3.3). A test against the real `roost` counts turn files (§4). |
| A front-chat turn that ends by Esc, Reject or no prose leaves the previous answer stored, served silently on `done` | 3 of 3 | Those endings clear the reply (§3.2). The 1.x adapter's same hole is recorded. |
| A chat the plugin has no memory of — after a reload, a late start, an eviction — can only read `working` or `idle`, so an open dialog reads `working` and `roost send` types into it | 2 of 3, and the third for subagents | Measured: `permission.sync` + `permission.list` recovers it (§2.5). Recovery added (§3.3); `working` and `blocked` chats are never evicted; `setup` never downgrades; an unheard child is resolved through `root()`. |
| Every listed test passes with no timer, and with writes that cross: the shell was untested | 2 of 3 | One serial `reconcile()` is the only writer (§3.1). The harness drives `setup` with a fake context, a real `roost` shim and mock timers, and must fail when the timer is removed (§4). A live event-free tab switch is added. |
| "Nothing un-records a reply" was wrong: an empty `roost reply -` does | 2 of 3 | Step 1 is a test, not a new command (§2.8, §5). |
| "No adapter reports `idle`" was wrong: codex does | 1 of 3 | The contract paragraph is corrected, not bent (§3.3). |
| `session.deleted`, cleanup on reload and reasoning were relied on and not measured | 1 of 3 | Reload measured (§2.6). Reasoning was already in the logs and is now stated (§2.3). `session.deleted` is no longer used. |
| The retry-then-succeeds fixture would be invented | 1 of 3 | Not written until recorded (A2). |
| `roost validate` also reads the adapter table | 1 of 3 | Named (§3.5). |
| The live test needs the "ask" rule or `blocked` is never set up | 1 of 3 | Added (§4). |

None of the three ran an opencode binary; they were told not to. Every
opencode 2 fact in this document rests on the author's measurements alone.
