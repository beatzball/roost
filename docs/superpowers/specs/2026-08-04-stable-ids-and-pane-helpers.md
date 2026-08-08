# amux stable-id addressing + pane helpers

**Status:** design
**Date:** 2026-08-04
**Builds on / revises:** the agent-coordination Foundation (`send`/`read`/`spawn`/`whoami`/`wait-done`, which shipped with friendly `session:index` targets).

## Problem

Two linked gaps:

1. **Friendly targets drift.** amux runs `renumber-windows on`, so closing a
   window shifts every higher `session:index`; pane indices renumber the same way
   on pane-close. A captured target (`main:2`, `main:2.1`) can silently point at
   the wrong window/pane later. Rare in "spawn-and-use-now" flows, but fatal for a
   **standing multi-pane workspace** an agent references over time.
2. **No helper-in-the-current-window.** `spawn` gives a helper in a *new window*;
   there's no way to drop a helper *beside* your work (a shell, logs, a sub-agent
   you pipe to), and no way to compose a layout (e.g. one agent full-left, a stack
   of helpers on the right).

## Approach

- **Canonical targets become tmux's stable ids** — a pane is `%N`, a window is
  `@N`. They're globally unique, never reused, and survive every renumber. Since
  every agent/helper lives in a **pane**, amux unifies on **pane ids (`%N`)** as
  the thing commands emit; friendly forms stay accepted as *input* for humans.
- **`amux split`** creates a helper pane in the current window, with **direction
  and source-pane control** so agents can build arbitrary layouts.

## Scope

**In scope:**
1. `target()` also accepts stable ids (`@N`, `%N`) — additive; friendly forms
   (`session:index`, `session:window.pane`, bare name) still work as input.
2. `amux spawn` / `amux whoami` **emit `%N`** (the new window's pane / the caller's
   pane) instead of `session:index`.
3. `amux split [-h|-v] [-t FROM] [CMD...]` — a background helper pane; emits `%N`.
4. `amux status` leads each row with the stable `%N` target (keeps the friendly
   `session:index name/cmd [state]` for humans).
5. The agent switcher shows the `%N` target (the real send-target) alongside the
   name.
6. SKILL + README updated for stable-id targets, `split` (helpers/layouts), and
   the `spawn`-vs-`split` boundary.

**Explicitly deferred (separate specs):**
- **Per-pane agent state.** `@agent_state` is window-scoped, so `wait-done` on a
  pane reflects its *window*. Making split panes first-class tracked agents
  (per-pane state, aggregate tab badge, panes in switcher/status/restamp) is a
  large UI change of its own.
- fzf **pane navigation** (switcher jumping into individual panes); agent-raised
  approval/attention modals.

## Key decisions

- **Emit ids, accept both.** Commands that produce a target (`spawn`, `split`,
  `whoami`) print `%N` so captured targets never drift. Commands that consume a
  target (`send`, `read`, `wait-done`, `split -t`) accept `%N`/`@N` **and** the
  friendly forms, so a human can still type `amux send api "…"`. This is
  backward-compatible input; only the *emitted* format changes.
- **Unify on pane ids.** `spawn` makes a window but returns that window's sole
  pane `%N` (not `@N`), so every emitted target is the same kind of thing and
  `send %N` always reaches the exact pane. `@N` is still accepted as input
  (targets the window's active pane).
- **Layout via `-h|-v` + `-t FROM`.** Verified: `split -h` off the agent makes a
  right column; `split -v -t <right-pane>` stacks below it. Two flags let an agent
  compose any layout; no higher-level "layout" command needed (YAGNI).
- **`wait-done` boundary stays.** `wait-done %N` resolves `%N`'s **window** state
  — reliable for a `spawn`ed single-pane window-agent, but shared for split
  helpers in a multi-pane window. The SKILL steers: `spawn` (window) for co-agents
  you `wait-done` on; `split` (pane) for helpers you `send`/`read`/eyeball.

## Design

### `target()` — accept stable ids (`bin/amux`)
```sh
target() { case "$1" in @*|%*|*:*) printf '%s' "$1" ;; *) printf '%s:%s' "$DEFAULT_SESSION" "$1" ;; esac; }
```
`@N`/`%N` (and any colon form) pass through; a bare word still resolves against
the default session. `send`/`read`/`wait-done` route through `target()`, so all
three gain stable-id support with this one change.

### `amux spawn` / `amux whoami` — emit `%N` (`bin/amux`)
- `spawn`: `new-window -d -P -F '#{pane_id}' …` → prints the new window's pane
  `%N` (was `#{session_name}:#{window_index}`).
- `whoami`: `display-message -p -t "$TMUX_PANE" '#{pane_id}'` → the caller's pane
  `%N`. Guard unchanged (`$TMUX_PANE` unset → exit 1).

### `amux split [-h|-v] [-t FROM] [CMD...]` (`bin/amux`)
- Parse leading flags: `-h`/`-v` → split direction (default: tmux's default);
  `-t FROM` → the pane to split (default `$TMUX_PANE`); `--` ends flags; the rest
  is the optional command.
- Guard: no `FROM` (i.e. `$TMUX_PANE` unset and no `-t`) → `amux split: not inside
  an amux session`, exit 1.
- `t split-window $dir -d -P -F '#{pane_id}' -t "$FROM" -c "$PWD" "$@"` — `-d`
  (no focus steal), prints the new pane `%N`.

### `amux status` / switcher — show the stable target
- `status`: lead each window row with the active pane's `%N`:
  `#{pane_id}  #{session_name}:#I  #{window_name}/#{pane_current_command}  [#{@agent_state}]`.
  Agents parse `%N` as the target; humans still see `session:index` + name + state.
- switcher (`scripts/amux-switch`): the visible target column becomes `%N` (the
  real send-target) next to the window name. Navigation still uses the hidden
  `window_id` — unchanged.

### SKILL + README
- Targets are stable ids (`%N`) captured from `spawn`/`split`/`whoami`; they don't
  drift. Friendly `session:index`/names still work when a human types them.
- `amux split [-h|-v] [-t FROM] [cmd]` → a helper pane in your window; example: the
  full-left-agent + stacked-right layout via `split -h` then `split -v -t <right>`.
- Boundary: `spawn` (window) for a co-agent you `wait-done` on; `split` (pane) for
  helpers you `send`/`read`.

## Edge cases

| Case | Behavior |
|---|---|
| `send`/`read`/`wait-done` given `%N` or `@N` | routed as-is (via `target()`) |
| `send api "…"` (bare friendly name) | still resolves against the default session (back-compat) |
| `amux split` outside amux (no `$TMUX_PANE`, no `-t`) | stderr `not inside an amux session`, exit 1 |
| `amux split -t %N …` from outside amux | allowed — splits the named pane |
| `amux split` unknown flag | stderr, exit 2 |
| `wait-done %N` on a split helper | reflects the window's shared state (documented; use `spawn` for tracked co-agents) |
| a pane/window closes | `%N`/`@N` of *others* are unaffected (ids never renumber); only the closed one's id is gone |

## Testing

`tests/test-panes.sh` (new) + updates to `tests/test-coordination.sh`, isolated
server via `AMUX_SOCKET`:

- **coordination updates:** `whoami` now emits `%N` (matches the caller pane's
  `pane_id`); `spawn` emits `%N` that resolves to a live pane; `send`/`read`/
  `wait-done` accept `%N` (send a marker via `%N`, read it back); friendly
  `session:index` input still works.
- **split:** creates a pane in the caller's window (window pane-count +1); prints
  a `%N` that resolves; `-d` leaves the active pane unchanged (no focus steal);
  CMD form runs; `env -u TMUX_PANE amux split` → exit 1.
- **layout:** `split -h` then `split -v -t <right>` yields the agent full-height on
  the left with a stacked right column (assert via `pane_left`/`pane_top`/
  `pane_height` geometry, as verified during design).
- **wait-done boundary:** two panes in one window share `@agent_state` (documents
  the limitation, not a bug).

Full suite green on bash 5 + bash 3.2; CI both OSes.

## Global constraints (carried)

tmux 3.1 floor (pane options/ids well within it); bash 3.2 safe (`\xHH`, no
`printf '\uXXXX'`); guarded tmux calls / never break a running agent; `bin/amux`
under `set -euo pipefail`; `AMUX_SOCKET` test seam; tests never touch the real
`-L amux` server; no reference to any external competitor project in committed
files.
