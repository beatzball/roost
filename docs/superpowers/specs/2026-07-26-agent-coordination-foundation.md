# amux agent coordination — Foundation

**Status:** design
**Date:** 2026-07-26

## Problem

amux can run many agents as windows, but there's no supported way for an agent
(or a human) to reliably *drive* another agent from inside amux, and nothing that
teaches an LLM how to do it. The switcher doesn't even show the address you'd
send to. amux already has the hardest part — **semantic agent states
(`@agent_state`) and a blocking `wait-done`** — because of the Claude hooks. This
spec builds the "Foundation": make messaging reliable and discoverable, add the
two missing primitives, and ship a portable skill so an LLM knows how to use it.

## Scope

**In scope (Foundation):**
1. Make `amux send` reliable into a Claude Code TUI.
2. `amux whoami` — an agent's own address.
3. `amux spawn` — create a helper agent window **without attaching**.
4. Switcher shows the `session:index` send-target.
5. A portable `skills/amux/SKILL.md` teaching the coordination loop.

**Explicitly deferred (revisit after Foundation):**
- Synchronous `amux ask TARGET "..."` (= send + wait-done + read). Pure
  composition on Foundation; no Foundation decision blocks it.
- Sender attribution (`[from session:index]` prefixing) — additive flag on
  `send`, designed as a hook point here, not built.
- Event/subscribe push, pane-level addressing, an MCP server.

## Key decision: the canonical target string

One address format used identically by `amux send`, `amux whoami`, `amux spawn`,
and the switcher: **`session:index`** (e.g. `charm:2`). It's unambiguous, is
exactly what tmux and `amux send` already resolve, and is robust against
duplicate/auto-renamed window names. The switcher and `whoami` also *show* the
friendly window name for humans, but the copy-paste target is always
`session:index`. (`amux send` continues to also accept a bare window name for
convenience, resolving against the default session as today.)

## Design

### 1. Reliable `amux send` (`bin/amux`)

Today: `t send-keys -t "$(target "$raw")" "$*" Enter` — a single call. Reliably
injecting into a full-screen TUI (like the Claude Code prompt box) requires the
**text and the Enter to be separate calls with a small delay** — a single
combined `send-keys "$*" Enter` can drop the submit or race it, leaving the text
sitting unsent in the input box. Separately, a typo'd target currently exits 0
and silently delivers nothing (the worst failure mode).

New behavior:
1. Resolve the target (existing `target()`).
2. **Validate** it resolves to a live window:
   `t display-message -p -t "$tgt" '#{window_id}'` — empty/error → print
   `amux send: no such target '<raw>'` to stderr, exit 2.
3. Deliver in two steps:
   - `t send-keys -t "$tgt" -l -- "$text"` (`-l` = literal, so a message
     containing `Enter`/`C-c`/etc. is typed as text, not interpreted as keys)
   - `sleep "$delay"`
   - `t send-keys -t "$tgt" Enter`
4. `delay` comes from `@amux-send-enter-delay` (default `0.3`). Read once:
   `t show-options -gqv @amux-send-enter-delay`, fall back to `0.3`.

Future hook (not built): an optional `--from LABEL` (or auto `amux whoami`)
prefix so the receiver knows the sender. The two-step delivery and the `-l`
literal text are what make attribution safe to add later.

### 2. `amux whoami` (`bin/amux`)

Prints the caller's own canonical target so an agent knows its own address.
Implementation: `tmux display-message -p '#{session_name}:#{window_index}'` run
from inside the pane. Output is exactly the `session:index` string on stdout
(one line, nothing else) so it's clean to capture in a shell substitution
(`me="$(amux whoami)"`).

Guard: only meaningful inside amux. If `$AMUX_HOME` is unset (not inside amux),
print `amux whoami: not inside an amux session` to stderr, exit 1.

### 3. `amux spawn NAME [CMD...]` (`bin/amux`)

A **non-attaching** helper-agent create — the piece the skill needs so an agent
can spawn peers without hijacking its own terminal (`amux new` `exec`s
`attach`, which an agent can't use).

- Target session: the caller's current session when inside amux
  (`tmux display-message -p '#{session_name}'`), else the default `main`
  (creating/booting it via the existing `ensure_session`).
- `t new-window -P -F '#{session_name}:#{window_index}' -t "=$sess" -n "$NAME"
  -c "$PWD" [CMD...]` — `-P -F` makes new-window print the new window's
  `session:index`, which `spawn` echoes to stdout. Does **not** attach.
- With no CMD, opens a shell window (the human/agent can then `amux send` into
  it, e.g. to start `claude`). With CMD (e.g. `amux spawn helper claude`), runs
  it directly.

`amux new` is unchanged (still attaches — it's the human "open and jump there"
command). `spawn` is the scriptable/agent sibling that returns a target.

### 4. Switcher shows the target (`scripts/amux-switch`)

The switcher already carries `session_id`/`window_id` as hidden keys. Add a
visible `session:index` column (the exact `amux send` target) so a human or
agent reading the popup can see what to send to, alongside the existing
state/elapsed/name/cmd/path. `#{session_name}:#{window_index}` added to the
`-F` and rendered in the awk row.

### 5. Portable `skills/amux/SKILL.md`

A harness-agnostic skill (works for any agent that can run a shell). Location:
`skills/amux/SKILL.md` (matches the `npx skills add <repo> --skill amux`
convention). Structure:

- **Preflight guard:** "Only proceed if `$AMUX_HOME` is set — that means you're
  inside an amux session. If it isn't, stop and tell the user you're not in
  amux; do not run these commands."
- **Know yourself:** `amux whoami` → your `session:index`.
- **See the fleet:** `amux status` (sessions/windows + states). Note the
  interactive switcher is `prefix a` for humans.
- **Spawn a helper:** `amux spawn NAME [cmd]` → prints the new target; e.g.
  `amux spawn reviewer claude`.
- **Message an agent:** `amux send TARGET "text"` — reliable, submits. Until
  attribution is built in, prefix your message with who you are (from
  `amux whoami`), e.g. `amux send reviewer "[from main:1] please review PR #2"`.
- **Wait + read the reply:** `amux wait-done TARGET [timeout]` then
  `amux read TARGET [N]`.
- **The idiom:** discover → (spawn) → send → wait-done → read. One prompt at a
  time, then wait — don't fire a second message before the first completes.
- **Guardrails:** don't message yourself; don't spam; a bad target errors
  loudly (exit 2) — check it. Spawned agents are real and cost tokens.

## Testability seam

`bin/amux` hardcodes `SOCKET="amux"`. Add `SOCKET="${AMUX_SOCKET:-amux}"` so
tests can point `send`/`spawn`/`whoami` at an isolated `-L <name>` test server
(production unchanged). This mirrors the `AMUX_*_SOCK` seams already in the
scripts.

## Edge cases

| Case | Behavior |
|---|---|
| `amux send` to a nonexistent target | stderr error, exit 2 (no silent no-op) |
| message text contains `Enter`/`C-c`/`;` | typed literally (`send-keys -l --`), not interpreted |
| `@amux-send-enter-delay` unset | default `0.3` |
| `amux whoami` outside amux | stderr error, exit 1 |
| `amux spawn` outside amux | targets/boots the default `main` session |
| `amux spawn` with a CMD | runs CMD in the new window; still no attach |
| skill invoked outside amux | preflight guard stops the agent |

## Testing

New `tests/test-coordination.sh` (isolated `-L` test server via `AMUX_SOCKET`):
- **send reliability:** send `printf 'AMUXMARK\n'`-style text to a shell window,
  `wait` briefly, `capture-pane` shows the marker → proves text **and** Enter
  were delivered (the two-step submit works end to end on a shell).
- **send validation:** a bogus target → exit 2 + stderr message; nothing sent.
- **literal text:** a message containing the word `Enter` lands as text, not an
  extra submit.
- **spawn:** `amux spawn helper` prints a `session:index` that
  `tmux list-windows` confirms exists; no client attached; a second window
  appears; `spawn helper true`-style CMD form runs.
- **whoami:** run inside a test pane (drive via `send-keys` + capture, or a
  small harness), output equals that window's `session:index`; outside amux →
  exit 1.
- **switcher target column:** the row-builder emits `session:index` for a window
  (unit-check the awk/format as with the existing switcher tests).

Existing suite stays green on bash 5 + bash 3.2; CI covers both OSes. The
`SKILL.md` is prose (no automated test) but must reference only real,
implemented commands — a lightweight check greps it for each command it names.

## Docs

README: a short "Driving agents from inside amux" note pointing at `amux whoami`
/ `amux spawn` / reliable `amux send`, and the skill (`skills/amux/SKILL.md`,
`npx skills add` line). The existing "Driving a fleet" section gains `spawn`.

## Global constraints (carried from the project)

tmux 3.1 floor; bash 3.2 safe (`\xHH`, no `printf '\uXXXX'`); guarded tmux
calls / never break a running agent; isolated test sockets (never touch the real
`-L amux` server); atomic where writing files.
