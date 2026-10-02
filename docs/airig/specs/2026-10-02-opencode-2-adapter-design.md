# An adapter for opencode 2 — design for #150

Status: **proposed 2026-10-02. Not approved, nothing built.** The one decision
that was the human's to make, Q1, was answered on 2026-10-02 — see §8. The
rest of the design is still waiting for agreement.

Base: `main` at `8cbafa1`, which is PR #153 merged. This builds on it: #153
added `scripts/lib/roost-opencode.sh`, bounded the version check, and stopped
`roost wiring` setting `OPENCODE_CONFIG_DIR` for opencode 2 (#154).

Measured on opencode **2.0.20**, macOS arm64, 2026-10-01 and 2026-10-02, with
`HOME`, the four `XDG_*_HOME` directories and `TMPDIR` redirected, the TUI in
panes of a throwaway `tmux -S` server, and a spy plugin. The raw sequences are
in #150 and its comments and are not repeated here; this document quotes the
result and says which run it came from. Anything not executed is labelled
*not measured*. opencode 2 shipped two releases during these two days. Every
event name below is a 2.0.20 fact, not a promise.

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
each chat's state, and reports the state of the chat **its own terminal is
showing**. That last part is new: a 2.x terminal holds several chats as tabs,
and roost has one badge per pane.

What is built: `adapters/opencode/v2/tui.js`, a link to it from
`roost install`, a doctor check, an offline replay test in `tests/run.sh`, and a
live smoke test that drives a real opencode 2.

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

**Switching the front tab emits no event** (`alt+up` / `alt+down`, two chats,
one terminal: the screen changed, the plugin heard nothing).

### 2.3 How a turn runs and ends

```
session.execution.started
  session.text.ended            data.text = one whole text part
  permission.asked / permission.replied
  session.retry.scheduled       data.attempt (2 = first retry), data.error
then exactly one of:
session.execution.succeeded
session.execution.failed        data.error
session.execution.interrupted   data.reason = "user" (Esc Esc) | "shutdown" (a dialog answered Reject)
```

Nothing success-shaped follows a failure: on a dead provider the stream was
ten `retry.scheduled`, `step.failed`, `execution.failed`, and then nothing. The
1.x adapter's `died` flag and retry counter have no job here.

### 2.4 Subagents

The tool is `subagent`. The child is its own session; its `session.created`
carries `parentID`. Its lifecycle, its text and its permission events all carry
the **child's** id. Its dialog is drawn in the parent's terminal. Its
`execution.succeeded` arrives before the parent's.

`context.data.session.root(<child>)` returned the child's own id for the first
four seconds. It is not used; `parentID` on `session.created` is.

### 2.5 Install shapes

| shape | on 2.0.20 | on 1.18.30 |
|---|---|---|
| `<config>/opencode/plugins/roost` → symlink to a directory holding `tui.js` | loads | ignored: no error, nothing logged |
| `<config>/opencode/plugin/roost.js` (the 1.x adapter) | `1 plugin failed` in the TUI footer | loads |
| `OPENCODE_CLI_CONFIG_CONTENT='{"plugins":["/abs/dir"]}'`, nothing in any config dir | loads; the user's `opencode.json` is still read | *not measured* |
| `OPENCODE_CONFIG_DIR` | loads, **and replaces the user's whole configuration** (#154) | merges |

### 2.6 Not measured

- `--standalone`, and a remote `--server`, with a terminal-side plugin.
- Whether `OPENCODE_CLI_CONFIG_CONTENT` drops the `plugins` list in the user's
  own `cli.json`. opencode's documentation says arrays in it replace.
- Compaction; a prompt queued behind a running turn; a turn started from
  another client (web, desktop) in a chat this terminal is showing.
- A terminal whose route is a **child** session (the user stepped into a
  subagent's chat).
- Linux. opencode 2 on tmux 3.4.
- How long a plugin's `setInterval` may run in the TUI before it costs
  anything a person would notice.

---

## 3. The design

### 3.1 One file, two halves

`adapters/opencode/v2/tui.js`, default export `{ id: "roost", setup }`.

- **The core** is a pure function of events: `createAdapter({ report, publish })`
  returns `{ onEvent(details), onFront(sessionID | null) }`. No timers, no
  process, no opencode. It is what the offline test drives.
- **The shell** is `setup(context)`: it subscribes with `context.data.listen`,
  reads `context.ui.router.current()`, runs the one timer (§3.4), and provides
  `report` and `publish` — `execFile("roost", …)` with the reply on stdin,
  exactly the 1.x `run()` helper, comments and all. It never throws, and a
  missing API (`context.data.listen` absent on some later 2.x) leaves the pane
  unbadged rather than broken.

The directory is `v2/` because opencode discovers a terminal-side plugin as a
directory with a `tui.*` file in it; the name is not a version number roost
chose.

### 3.2 State is kept per chat

A map from **root** session id to `{ state, text, reply }`: `text` is what the
turn in progress has said so far, `reply` is the answer of the last turn that
finished (§3.3 says why it is kept). `children` maps a child id to its root,
learned from `parentID` on `session.created`.

| event | for the root it belongs to |
|---|---|
| `session.execution.started` (root's own) | `working`; clear `text` |
| `session.text.ended` (root's own) | `text = data.text` — the last one wins, as on 1.x |
| `permission.asked` (root's or a child's) | `blocked` |
| `permission.replied` (root's or a child's) | `working` |
| `session.retry.scheduled` (root's own) | `error` if `attempt >= 3`, else `working` |
| `session.execution.succeeded` (root's own) | `reply = text`; `done` |
| `session.execution.failed` (root's own) | `error`; `reply = none` |
| `session.execution.interrupted` (root's own) | `done`; `reply = none` |
| a child's lifecycle, text, retries | ignored |
| `session.deleted` | forget the entry |

`attempt >= 3` is the 1.x rule — error at the second retry — read off
opencode's own counter. The known gap about a retrying-but-alive provider
wearing `error` mid-turn (`docs/known-gaps.md`) carries over unchanged.

`interrupted` → `done` is the 1.x judgement for Esc: the person who ended the
turn is sitting there. It now also covers Reject, which opencode 2 reports the
same way.

The map is capped (the 200 most recently touched roots). An evicted chat reads
as unknown, which §3.3 handles.

### 3.3 What is reported: the front chat, and only when it changes

`front` is the root of the session `router.current()` names, or none on the
home screen.

- An event that changes the **front** chat's state → `roost state <state>`.
- An event for any other chat → remembered, not reported.
- `front` itself changes → report the new front's remembered state. Unknown
  chat → ask `context.data.session.status(id)`: `"running"` → `working`, else
  `idle`. Home screen → `idle`.

**This is the one place the adapter contract bends.** §1 of
`2026-08-29-adapter-contract.md` says `idle` is a default and no adapter
reports it. A pane that showed `working` for chat A and now shows a finished
chat B has to stop saying `working`, and the only way to take a badge back is
to report `idle`. The contract gets a paragraph saying so; nothing else about
it changes.

A badge reported on a front change is a **restatement**, not a transition, and
`error` and `blocked` ping the desktop. Read in `scripts/roost-agent-state`:
the ping is sent only when the pane's window is **not** the active one. A
person switching tabs is typing in that window, so a restated `error` does not
ping. A front change nobody typed — another plugin moving the route — would;
not measured, and not a case this design tries to cover.

**The reply has to follow the badge, and this is the part with a hole in it
(R1).** A plain `roost state done` does not touch the stored reply — only the
`--stop-hook` paths clear it. So after a switch from chat A to a finished chat
B, the pane would read `done` and `roost read` would return **A's** answer, on
a pane that reads finished, with no notice. `scripts/roost-agent-state` has a
long comment about exactly this failure and why wrong-and-silent is the one to
avoid.

So the reply is kept per chat too. `pending` becomes `reply`: the last text of
the chat's last finished turn, kept after it is published (capped per chat, and
dropped with the entry). Then:

- a turn of the front chat succeeds → publish, then `done`, as on 1.x;
- a turn of a hidden chat succeeds → remember the reply, publish nothing;
- the front changes to a chat with a remembered reply → publish it, then the
  state. `roost read` now answers for the chat on screen, which is what D1
  says the pane is;
- the front changes to a chat with **no** remembered reply (never seen, or it
  failed, or was interrupted) → the pane's stored reply has to be **cleared**,
  and there is no adapter-facing way to do that today. `roost reply` records
  text; nothing un-records it. This needs one small addition to roost — an
  explicit clear — and it is step 1 of §5, because without it the adapter
  ships the silent-stale-reply failure.

### 3.4 Noticing the front changed

No event says so (§2.2). Two triggers:

1. every event the plugin hears — free, and usually soon enough;
2. a 1-second `setInterval` that compares `router.current()` with the last
   value and does nothing else. It is cleared in the cleanup `setup` returns.

One second because a badge that lags a tab switch by a second is invisible, and
a tighter loop buys nothing. The cost is one function call a second per open
opencode terminal; *not measured* (R3).

### 3.5 Install, doctor, wiring

**`roost install`**, when the opencode on `PATH` is 2.x
(`roost_opencode_v2`, from PR #153):

- links `<config>/opencode/plugins/roost` → `adapters/opencode/v2`;
- removes `<config>/opencode/plugin/roost.js` **if it is roost's own link** —
  it is what makes opencode 2 print `1 plugin failed`. Anything else at that
  path is left, as today.

When it is 1.x: exactly what it does today. The 2.x directory is not linked,
though 1.x would ignore it, so that a 1.x machine's config directory holds
nothing it does not use.

`scripts/lib/roost-adapters.sh` gains the 2.x path and target, so install and
doctor read one definition, as they do for every other adapter.

**`roost doctor`**, on 2.x: the "not supported yet" line from PR #153 is
replaced by the same four states every adapter has — linked, not installed,
dangling, not this install. The two other 2.x lines from #153 stay.

**`roost wiring`** — the route that needs no `roost install` — does **nothing**
for opencode 2. Decided, Q1.

### 3.6 What a user of both versions gets

One machine cannot run both against one data directory (1.18.30 fails with
`Database is not empty and has no session table` after 2.0.20 has used it), so
"both installed" in practice means one on `PATH`. `roost install` wires that
one. Switching majors means running `roost install` again; doctor says so,
because the link it expects for the version it finds is missing.

---

## 4. Tests — the oracle

**Offline, in `tests/run.sh` and CI.** `tests/opencode2-plugin-harness.mjs`
imports the core, feeds it recorded sequences, and asserts the exact list of
`report` and `publish` calls. Node only; no opencode. The sequences are the
ones measured for #150, copied in with their source noted:

| case | asserts |
|---|---|
| a turn with no tool | `working`, reply, `done` — reply before `done` |
| a tool behind a dialog, allowed | `working`, `blocked`, `working`, reply, `done` |
| a subagent with its own dialog | the child's `succeeded` does not report `done`; the child's text is not the reply; its dialog does report `blocked` (contract traps T1) |
| Esc Esc | `working`, `done`; no reply |
| a dialog rejected | `working`, `blocked`, `working`, `done`; no reply |
| a dead provider | `working`, `error` at attempt 3, no flapping through attempts 4–11, still `error` after `failed` |
| a retry that then succeeds | `working`, `error`, then `done` with the reply |
| two chats interleaved, front is A | only A's states are reported; B's reply is not published while A is in front |
| front switches A → B → home | B's remembered reply, then B's state; then the reply cleared and `idle` |
| front switches to a chat that failed | the reply is **cleared**, then `error` — A's answer is not left behind |
| front switches to a chat never seen | the reply cleared; `working` or `idle` from the status call |
| an event with no session id, an unknown type, a null payload | nothing reported, nothing thrown |

Each is run once more with the events of a second, unrelated chat shuffled in,
so "ignores other chats" is tested against every case and not only its own.

**Live, by hand and before any release that touches the adapter.**
`tests/live/opencode2-smoke.sh`, in the shape of `opencode-smoke.sh`:

- takes the binary as `ROOST_OPENCODE2_BIN` and **skips** unless it is set and
  is 2.x — it never runs whatever `opencode` is on `PATH`, because on a 1.x
  machine that is the wrong binary and on any machine the default data
  directory is the user's real one;
- redirects `HOME`, the four XDG directories and `TMPDIR`; checks
  `opencode debug paths` before starting anything; starts 2.x by absolute path
  in every pane; runs `opencode service stop` in an EXIT trap;
- drives a free `opencode/*` cloud model, as `roost validate --opencode-cloud`
  does, so it needs no account;
- asserts pane options, not screens: `done` and the reply after a plain turn,
  `blocked` while a dialog is open, `done` after Esc Esc, `error` against a
  provider on a closed port, and — two panes — that pane A's badge does not
  move when pane B runs a turn.

**Install and doctor**: stub-driven cases beside the existing ones in
`tests/test-install.sh` and `tests/test-doctor.sh`, with the 1.x stub as the
control for every 2.x assertion.

---

## 5. Order of work

1. R1: a way for an adapter to clear the pane's stored reply, with its test.
   Small, in roost itself, and first — the adapter is wrong without it.
2. The core and the offline harness. No opencode needed; this is most of the
   logic and all of the CI coverage.
3. The shell (`setup`), then the live smoke test against 2.0.x.
4. `roost install`, `roost-adapters.sh`, doctor, and their tests.
5. Docs: State Badges gets a 2.x section; Setup and Troubleshooting lose the
   "not supported yet" lines; the adapter contract gets its `idle` paragraph
   and a row in "Where each harness stands"; `known-gaps.md` gets the gaps in
   §6.

One PR, after #153 has merged.

---

## 6. Gaps this ships with

- **A hidden tab** that is working, blocked or failed shows nothing until it is
  brought to the front (D1).
- **A reply from a chat that finished while hidden** is published only when
  that chat comes to the front, not when it finishes.
- **A front change is seen up to a second late**, or at the next event. For
  that second the badge and `roost read` describe the chat that was in front.
- **No badge without `roost install`** on opencode 2 (Q1). 1.x keeps its
  no-setup wiring.
- **A retrying-but-alive provider** reads `error` mid-turn, as on 1.x.
- Everything in §2.6.

---

## 7. Risks

- **R1 — a stale reply after a front change.** §3.3. The adapter can re-publish
  a reply it remembers, but cannot clear one, and `roost read` would then serve
  another chat's answer silently. Needs a clear in roost itself, built and
  tested first. If that turns out to be larger than a few lines, stop and
  re-size: the alternative is that a front change publishes nothing and
  `roost read` on an opencode 2 pane is documented as "the last turn that
  finished in front", which is weaker and honest.
- **R2 — the API moves.** Two releases in two days. The live smoke test is the
  only thing that notices, and it is run by hand. `roost doctor` could warn on
  an opencode 2 newer than the last one the smoke test passed on; not in this
  design, worth deciding after the first break.
- **R3 — the timer.** One call a second, unmeasured. If it shows up anywhere,
  the fallback is events only, and a front change is then seen at the next
  event rather than within a second.
- **R4 — the first event of a new chat.** Typing the first prompt on the home
  screen, the route was already the new session when `session.created`
  arrived — in one sample. If the route can lag, the first `working` of a chat
  is dropped until the timer catches up, which is at most a second.
- **R5 — #141** (session id, directory and harness on the pane) is being built
  in parallel. This adapter knows the session id of the front chat and should
  stamp it the way that issue settles; it does not invent its own option.

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
- State per root chat, front chat reported (D1).
- `interrupted` → `done` for both Esc and Reject.
- The reply follows the front chat: kept per chat, re-published on a front
  change, cleared when the new front chat has none — which needs a clear added
  to roost (R1).
- A 1-second timer for front changes.
- `idle` is reported on a front change, and the contract is amended to say so.
- `roost install` links exactly one opencode adapter: the one for the version
  on `PATH`.
- The live test never runs the `opencode` on `PATH`.
