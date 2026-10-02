# An adapter for opencode 2 — design for #150

Status: **proposed 2026-10-02, revised twice the same day after two rounds of
review. Not approved, nothing built.** The one decision that was the human's to
make, Q1, is answered (§8). A jury of three reviewed the first version and the
second, and asked for changes both times; §9 says what they found and what
changed. This third version has not been reviewed. The rest still waits for
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

So an open dialog can be found by a plugin that did not see it open.

The same for a **subagent's** dialog (A1, measured after the second review
round). With a child's dialog open, a terminal started afterwards on the
**parent** chat found:

| call | result |
|---|---|
| `family(parent)` | `[parent, child]` |
| `permission.list(parent)` after sync | `[]` |
| `permission.list(child)` after sync | one pending request, `sessionID` = the child |
| `root(child)` | the parent |
| `permission.sync` | 7 ms for the child, under 1 ms for the parent |

So "is a dialog open for the chat in front?" has an answer that needs no
memory and no attribution of events: **any pending request in any member of
`family(front)`.**

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

### 3.2 The model: one entry per session, and `blocked` is asked for, not tracked

A map from session id to `{ phase, text, due }`, keyed by the id **the event
itself carries**. There is no map of children to parents and no resolving of
ids.

- `phase` — `working`, `done`, `error`, or `idle`. Never `blocked`.
- `text` — what the turn in progress has said so far.
- `due` — a reply owed to the pane for the turn that just ended and not yet
  written: `{ publish: TEXT }` or `{ clear: true }`, or nothing.

| event | for the entry of the session id it carries |
|---|---|
| `session.execution.started` | `working`; `text = none`; **`due = none`** |
| `session.text.ended` | `text = data.text` — the last one wins, as on 1.x |
| `session.retry.scheduled` | `error` if `attempt >= 3`, else `working` |
| `session.execution.succeeded`, with text | `done`; if this session is in front **now**, `due = publish(text)` |
| `session.execution.succeeded`, no text | `done`; if in front now, `due = clear` |
| `session.execution.failed` | `error`; if in front now, `due = clear` |
| `session.execution.interrupted` | `done`; if in front now, `due = clear` |
| `permission.asked`, `permission.replied`, **for any session** | nothing in the model; mark the front's dialog state **stale** (§3.3) |

"In front now" is a fresh `router.current()` read when the event is handled,
not what the last `reconcile()` saw.

**Why a child needs no special handling.** A subagent's events carry the
child's id (§2.4), so they land in the child's own entry and never touch the
parent's. The child's `succeeded` cannot end the pane's turn and the child's
text cannot become the pane's reply, because the pane only ever reads the entry
of the session in front. The first two versions of this design mapped children
to their roots, and both review rounds found a way for that mapping to be
wrong — a `session.created` that was never heard, a `root()` that is not yet
right (§9). Not mapping at all removes the question.

**Why `blocked` is asked for.** Tracking it from `permission.asked` and
`permission.replied` needs each event attributed to the right chat, and needs a
count when two requests are open at once. Asking needs neither: the pane is
`blocked` exactly when some member of `family(front)` has a pending request
(§2.5). The events are still used — as the signal to ask again.

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

**A `due` never outlives its moment.** It is dropped when its session stops
being the front one, and when that session starts another turn. Both review
rounds reached the same bug from different sides: a reply that was owed, not
yet written, and then written much later — after a tab switch and back — as
if it were the newest answer (§9).

The map is capped at 200 entries, and only entries in `done`, `error` or
`idle` are evicted. A session with no entry is **unknown**, which §3.3 handles
the same way whether it was evicted, never seen, or lost to a reload.

### 3.3 What `reconcile()` writes, and when it asks

`front` is the session id `router.current()` names, or none on the home
screen. `written` is what this instance last wrote: `{ front, state }`. It
starts empty, so the first pass writes everything.

Each pass, in this order:

1. **The front changed** (`front != written.front`). The pane is now about a
   different chat, so the stored reply is not this chat's: drop the `due` of
   the session that left, **clear the stored reply** — an empty
   `roost reply -` (§2.8) — forget `written.state`, and mark the dialog state
   stale.
2. **The dialog state is stale** → ask: for each id in `family(front)`,
   `permission.sync(id)` then `permission.list(id)`. Any pending request →
   the front is blocked. Each `sync` is raced against a 2-second limit and
   caught; if it fails or times out, the answer is "not known", the pane keeps
   what it shows, and the question stays stale for the next pass.
3. **A reply is due** for the front session: `publish` → `roost reply -` with
   the text; `clear` → the empty one. Then drop `due`.
4. **The state differs** from `written.state` → `roost state <state>`, where
   the state is: `blocked` if step 2 found a pending request; else the front
   entry's `phase`; else, for an unknown session, `working` if
   `status(front) == "running"` and `idle` if not; and `idle` on the home
   screen.

Reply before state, always: `wait-done` returns the moment the badge stops
being busy, and the documented idiom is wait-done then read.

The dialog state goes stale on three things: a front change, any
`permission.*` event for any session, and `setup`. Not on the timer — asking
costs a call per family member, and the timer runs every second.

**A reply is published exactly once, when a turn of the front chat ends.** It
is never re-published. The first version of this design re-published a
remembered reply on a tab switch, and all three reviewers found the same thing
wrong with it (§9): every non-empty `roost reply` is a new numbered turn, so
flipping between two tabs filled the record with duplicates, pushed real turns
out of it, and made `wait-done --turn N` and `read --turn N` return another
chat's old answer. So after a front change `roost read` has no recorded reply
for the pane and says so, until the chat in front finishes a turn. That is
weaker than restoring it and it is true.

**An unknown session needs no separate path.** A chat never seen, an evicted
one, and every chat after a reload (§2.6) all go through the same four steps:
the dialog question is asked of opencode, and the phase falls back to
`status()`. What cannot be recovered is the difference between `done`, `error`
and `idle` for a turn this instance did not see end; it reads `idle`.

Asking for the dialog state matters because of what a wrong answer does:
`roost send` refuses only a `blocked` target, so a pane that reads `working`
over an open dialog gets the next prompt typed into the dialog.

**`setup` writes the pane in full.** The first pass clears the stored reply and
writes the state it finds. The second version of this design tried to be
cleverer — "never downgrade at setup", so that a reload would keep a finished
chat's `done` and its reply — and the second review found three ways for that
to be wrong (§9): a new opencode started in a pane still showing another
chat's `done` and answer; a busy badge left by the previous instance for a turn
that ended during the reload; and a timer tick that downgraded it anyway a
second later. An instance cannot know whose badge is on the pane, so it does
not guess. The cost is in §6: after a reload, a finished chat reads `idle`
with no stored reply until its next turn.

**A reload must not leave the old instance writing.** `reconcile()` is serial
within one instance, and a reload makes a second one in the same process
(§2.6). The cleanup `setup` returns therefore does four things: stops the
listener, clears the timer, sets a `disposed` flag that every step of
`reconcile()` checks after each `await`, and **kills the `roost` child it has
in flight**, if any. The new instance writes the pane in full, as above, and
writes it once more on its first timer tick, so a write the old instance got
out before it was stopped does not stand.

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
  `data.session.family` and `data.session.permission.sync/list`, each scripted
  by the case — including a `sync` that rejects and one that never settles;
- puts a **recording `roost` shim** on `PATH`, as the 1.x harness does and as
  the contract requires, so what is asserted is the real `execFile` path: the
  argv, the stdin, `ROOST_AGENT_NAME=opencode` on every call, and the order
  the processes actually ran in. One variant of the shim sleeps on `reply`, to
  force the overlap §3.1 exists for;
- drives time with Node's mock timers, so "a second passed and nothing else
  happened" is a step a case can take.

The sequences are the ones recorded for #150, copied in whole with their
source noted. A case that has no recorded sequence is not written until one
exists (the contract: fixtures replay a recorded turn).

| case | asserts — as calls to the shim, in order |
|---|---|
| a turn with no tool | `state working`, `reply TEXT`, `state done` |
| a tool behind a dialog, allowed | `working`, `blocked`, `working`, reply, `done` |
| a subagent with its own dialog | the child's `succeeded` writes nothing; the child's text is never a reply; its dialog writes `blocked`, found through `family(front)` (trap T1) |
| the same, with every event before the child's first one withheld — a reload mid-subagent — and the child speaking before it asks | `blocked` all the same: nothing depends on having heard `session.created` |
| two dialogs open in one family; the first is answered | still `blocked`; `working` only after the second |
| `permission.sync` rejects, then works on the next pass | no write on the first pass, `blocked` on the second; nothing thrown |
| `permission.sync` never settles | the pass ends after the 2-second limit and later passes still write |
| answered turn, then a turn ended by Esc Esc | second turn: `working`, **empty reply**, `done` — the first answer is not left behind |
| answered turn, then a turn ended by Reject | `working`, `blocked`, `working`, **empty reply**, `done` |
| answered turn, then a turn that succeeds with no prose | **empty reply**, `done` |
| a dead provider | `working`, `error` once at attempt 3, nothing through attempts 4–11, **empty reply**, still `error` after `failed` |
| two chats interleaved, front is A | only A's states and A's reply are written |
| front A → B → A → B, all four finished, **no events**, timer only | each switch: empty reply, then the state. **No non-empty reply is ever written** — the turn record cannot grow |
| front → a chat with an open dialog this instance never heard | empty reply, `blocked` |
| front → home | empty reply, `idle` |
| `setup` on an idle chat, in a pane the shim says already holds another chat's `done` and reply | empty reply, `idle` — and the same again after one tick |
| `setup` on a chat that is running / has a pending permission | empty reply, then `working` / `blocked` |
| the slow-`reply` shim: A succeeds, the front moves to B (running) while A's publish is in flight | the last `state` written is B's `working`, and the last reply written is the empty one |
| A succeeds in front; the front moves to B **before** the pass that would publish; A runs a second turn while hidden and is interrupted; front → A | **no non-empty reply is ever written** — the owed reply died when A left the front |
| cleanup, then a new `setup`, with the old instance's `roost` child made slow | the old child is killed; the last writes are the new instance's |
| 201 chats, the oldest one with an open dialog | front → it writes `blocked`, entry or no entry |
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

One thing is measured before the case that needs it is written:

- **A2** — a retry that then succeeds, recorded, for the fixture. Until it is,
  that case is not in the offline suite.

(A1 — a child's pending permission seen by an instance that started late — was
measured after the second review round and is in §2.5.)

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
- **After a reload, a finished chat reads `idle` with no stored reply**, until
  its next turn. A reload is what a roost update does to every open opencode
  terminal. `setup` writes the pane in full because it cannot know whose badge
  is on it (§3.3). The same for an evicted chat brought back to the front.
  `status()` cannot tell `done` from `idle`.
- **A dialog answered or opened while a `permission.sync` is failing** is seen
  one pass late, or at the next `permission.*` event.
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
- **R6 — the dialog question is a call to opencode.** `permission.sync` is
  awaited once per member of the front chat's family, on a front change and on
  any `permission.*` event. Measured once: 7 ms for a child, under 1 ms for
  its parent (§2.5). It sits inside the one serial writer, so it is raced
  against 2 seconds and caught; a chat with many subagents multiplies it. Not
  measured: its cost against a remote server.
- **R7 — `family()` is the only source of "whose dialog is this".** It was seen
  to list one child. Grandchildren, and a family after a child has finished,
  were not measured. If it omits a member, that member's dialog reads
  `working`. The live smoke test's subagent case is the check.

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
- State per session; the pane is reconciled to the front chat (D1).
- `blocked` is asked of opencode — a pending request anywhere in the front
  chat's family — and not tracked from events.
- `interrupted` → `done` for both Esc and Reject.
- A reply is published once, when a turn of the front chat ends, and never
  re-published. A front change clears the stored reply. The alternative — a
  new way in roost to restore a reply without recording a turn — is more than
  D3 allows and is not proposed.
- A turn that ends with no answer clears the stored reply.
- A 1-second timer for front changes.
- `setup` writes the pane in full, and a reload therefore costs a finished
  chat its `done` and its stored reply.
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
| A chat the plugin has no memory of — after a reload, a late start, an eviction — can only read `working` or `idle`, so an open dialog reads `working` and `roost send` types into it | 2 of 3, and the third for subagents | Measured: `permission.sync` + `permission.list` recovers it (§2.5). Recovery added (§3.3); `working` and `blocked` chats are never evicted; `setup` never downgrades; an unheard child is resolved through `root()`. (The last two did not survive round 2, below.) |
| Every listed test passes with no timer, and with writes that cross: the shell was untested | 2 of 3 | One serial `reconcile()` is the only writer (§3.1). The harness drives `setup` with a fake context, a real `roost` shim and mock timers, and must fail when the timer is removed (§4). A live event-free tab switch is added. |
| "Nothing un-records a reply" was wrong: an empty `roost reply -` does | 2 of 3 | Step 1 is a test, not a new command (§2.8, §5). |
| "No adapter reports `idle`" was wrong: codex does | 1 of 3 | The contract paragraph is corrected, not bent (§3.3). |
| `session.deleted`, cleanup on reload and reasoning were relied on and not measured | 1 of 3 | Reload measured (§2.6). Reasoning was already in the logs and is now stated (§2.3). `session.deleted` is no longer used. |
| The retry-then-succeeds fixture would be invented | 1 of 3 | Not written until recorded (A2). |
| `roost validate` also reads the adapter table | 1 of 3 | Named (§3.5). |
| The live test needs the "ask" rule or `blocked` is never set up | 1 of 3 | Added (§4). |

### Round 2, on the revision

The same three, the same day. Each confirmed its own round-1 findings resolved
(two "partly", both about subagents), and all three again returned
CHANGES_NEEDED — every new finding was in logic the revision had added.

| finding | raised by | what changed |
|---|---|---|
| A reply that was owed and not yet written survives a tab switch, and is published much later as if it were the newest answer | 3 of 3 | A `due` is dropped when its session leaves the front and when it starts another turn; "in front" is read fresh at the event (§3.2). A test walks the exact sequence (§4). |
| After a reload, a child's events are filed as a chat of their own, so its dialog never reaches the parent; and `root()` is wrong for a child's first four seconds | 2 of 3 | No mapping of children at all. `blocked` is asked of opencode over `family(front)` — measured for a child's dialog, A1 (§2.5, §3.2). |
| "`setup` never downgrades" keeps another chat's `done` and answer on a pane where a new opencode has started; keeps a stale busy badge; and is undone by the first timer tick anyway | 3 of 3, one situation each | Dropped. `setup` writes the pane in full; the cost is recorded (§3.3, §6). |
| A reload leaves the old instance's `roost` child in flight, and its late write beats the new instance's | 1 of 3 | Cleanup stops the listener and timer, sets `disposed`, kills the child in flight; the new instance writes in full, twice (§3.3). |
| `permission.replied` writes `working` while a second dialog is still open | 1 of 3 | Follows from asking: `blocked` holds while any request is pending. |
| `permission.sync` inside the one serial writer could hang or reject and stop every later write | 2 of 3, as "not checked" | Raced against 2 seconds and caught (§3.3). |
| `ROOST_AGENT_NAME` is named and not asserted | 1 of 3 | Asserted on every call (§4). |
| The claim that reasoning arrives separately had no evidence in the files the jury was given | 1 of 3 | The event excerpt is posted on #150. |

A third round has not been run on this version. Two rounds each found real
faults, and each fault was in logic the previous revision had added. This
revision removes logic rather than adding it — no child mapping, no tracked
`blocked`, no setup rule — and every situation a reviewer found is now a case
in §4. Whether that is enough, or a third round comes first, is the human's
call.

None of the three ran an opencode binary in either round; they were told not
to. Every opencode 2 fact in this document rests on the author's measurements
alone.
