# Per-pane agent state

**Date:** 2026-08-08
**Status:** approved

## Problem

`amux split` puts a helper agent in a pane of the current window, but agent state
is recorded on the **window**: `amux-agent-state` calls `set-option -w -t
"$TMUX_PANE"`. Two agents in one window therefore fight over a single badge —
the last hook to fire wins, and the tab lies about both of them.

Everything downstream inherits the same window granularity: the switcher lists
windows, the status-bar rollup counts windows, `wait-done` reads a window
option, and `prefix + b` jumps to a window. A helper pane is unreachable and
unobservable.

This design makes the **pane** the unit of agency throughout.

## Verified mechanics

Four spikes on tmux 3.6 against isolated `-S` sockets established the following.
They are recorded here because several are non-obvious and one is a trap.

1. `set-option -p` stores per-pane options that do **not** leak to sibling panes.
2. `show-options -wqv` on a pane-scoped option exits 0 with **empty** output. This
   is a live bug waiting to happen: `wait-done` reads `-wqv` today, so after the
   move a `|| echo idle` fallback never fires (the command didn't fail) and the
   empty string matches neither `done` nor `idle` — the wait loop hangs until its
   timeout instead of returning early.
3. `#{P:...}` loops over the panes of the window being rendered, and per-pane
   option lookups inside the loop resolve per pane. A window tab can therefore
   compute its badge live, with no extra writes and no staleness when a pane
   dies.
4. **A literal comma inside `#{P:...}` is a separator, not text.** tmux parses
   the two-argument form (active format, inactive format), so `#{P:#{@agent_state},}`
   silently yields something other than what it reads like. Loop bodies must use
   a space separator.
5. Option lookup for a pane falls back **pane → window → global**. A leftover
   window-scoped `@agent_state` is therefore inherited by every unstamped pane in
   that window, which would make plain shells masquerade as agents. This drives
   the migration requirement in §8.
6. `#{E:@opt}` expands an option's value as a format, so a long expression can
   live in one named option instead of being inlined four times.
7. `pane-border-status top` consumes one row even when a window has a single
   pane (measured: pane height 11 of a 12-row window).
8. `list-panes -a` does **not** return panes in a stable display order (observed
   `%0 %2 %1`). Any consumer that groups or orders must sort explicitly.
9. `#{t/f/...}` cannot carry a `%H:%M` argument — the format's own `:` ends the
   modifier. `#{t/p:@agent_since}` renders `12:52` and is the usable form.

## Design

### 1. State model

`@agent_state` and `@agent_since` become **pane options**:

```sh
tmux set-option -p -t "$TMUX_PANE" @agent_state "$state"
tmux set-option -p -t "$TMUX_PANE" @agent_since "$(date +%s)"
```

`@agent_glyph` is **removed**. Glyphs are derived from `@amux-glyph-<state>` at
render time. This deletes `scripts/amux-restamp` and its call from `bind r`: a
theme or glyph change becomes live everywhere immediately, because nothing is
stamped that could go stale. That staleness was the original defect that started
this line of work.

The global default `set -g @agent_state "idle"` is **removed**. This is
load-bearing, not tidying: with no fallback value, an unstamped pane reads empty,
which makes *"is this pane an agent?"* a decidable predicate —

> **A pane is an agent if and only if its pane-scoped `@agent_state` is non-empty.**

A pane running `less`, `tail`, or a bare shell is not an agent and never counts
as one.

`amux-agent-state` runs on every `PostToolUse`, so its cost matters. It currently
reads three values (previous state, previous glyph, configured glyph for the new
state) to decide whether to bail early. With glyphs gone it reads one value and
compares it to the requested state. The hot path gets cheaper, not more
expensive. Everything else about the script is unchanged: it stays a no-op
outside an amux-socket pane, every tmux call keeps `|| true` so a dead server
degrades instead of breaking Claude, and it still notifies on a transition into
`blocked`.

### 2. Window tab badge

The badge emits one glyph per **distinct** state present in the window, ordered
by urgency (blocked → working → done → idle), deduplicated. It lives in one
option and is referenced as `#{E:@amux-tab-badge}` from both
`window-status-format` and `window-status-current-format`, so the two can never
drift and a user can override the badge in exactly one place.

Structure (single-quoted in the conf; note the space separators required by
finding 4):

```
#{?#{==:#{P:#{@agent_state}},},          <- no pane is stamped at all
   #{@amux-glyph-idle},                  <- ... show the idle glyph
   <blocked?><working?><done?><idle?>}   <- ... else one glyph per state present
```

where each `<x?>` is `#{?#{m:*x*,#{P:#{@agent_state} }},#{@amux-glyph-x},}`.

Substring matching is safe because no state name is a substring of another.

Verified behavior:

| window contents | badge |
| --- | --- |
| plain shell + blocked agent | `🛑` |
| no agents at all | `💤` |
| working agent + done agent | `⏳✅` |
| three working agents | `⏳` |

Row 1 is the case that matters day to day: splitting a window must not smear a
spurious `💤` onto its tab. Row 2 keeps a freshly opened tab looking exactly as
it does today.

### 3. Pane borders

`pane-border-status top` is enabled globally — every window, split or not. This
costs one row of height everywhere and buys consistency plus no hook machinery
to keep a per-window setting in sync with the pane count.

`pane-border-format` shows, for an agent pane:

```
 🛑 %12 claude · blocked 12:52
```

and for a non-agent pane just `%14 zsh`. Both the glyph and the trailing
`· state since` clause are guarded on `#{?@agent_state,...,}`, and the timestamp
is additionally guarded on `#{?@agent_since,...,}` so a half-stamped pane cannot
render garbage. The state→glyph mapping is a nested `#{?#{==:...}}` chain over
the four states.

**Do not nest `#{E:}` inside another `#{E:}`.** The glyph chain is inlined into
the border format rather than referenced through a second option; nesting relies
on expansion depth that is not guaranteed. Implementation must confirm the
rendered output rather than assuming.

`pane-active-border-style` uses `@amux-color-active-bg` so the focused pane is
marked with the same colour the active tab already uses.

### 4. Switcher — grouped by window

`scripts/amux-switch` reads panes instead of windows, sorting explicitly by
session name, window index, then pane index (finding 8).

Fields: `session_id`, `session_name`, `window_id`, `window_index`,
`window_name`, `window_panes`, `pane_id`, `pane_index`, `pane_current_command`,
`b:pane_current_path`, `@agent_state`, `@agent_since`. The three ids are hidden
key columns (`--with-nth` hides them); the rest is displayed.

Layout:

- A window with **one** pane collapses to a single flat row, exactly as today.
  Otherwise the common case doubles in length for no added information.
- A window with **two or more** panes emits a header row (window name + path)
  followed by one indented row per pane.
- Every pane row carries `window·command` in its label. Headers disappear the
  moment the user types into fzf, so each row must remain self-describing on its
  own.
- Non-agent panes render the idle glyph with no state word and no elapsed time.

```
🛑 blocked    3m  %12   api·claude        (~/w/api)      <- single-pane window
   web                                    (~/w/web)      <- header
   ⏳ working    1m  %7    web·claude
   💤            --  %14   web·zsh                       <- not an agent
```

Selecting a pane row navigates all three levels: `switch-client -t <session_id>`,
`select-window -t <window_id>`, `select-pane -t <pane_id>`. Selecting a header
row jumps to that window's active pane.

Glyphs are resolved from `@amux-glyph-<state>` read once at startup, keeping the
switcher and the status bar derived from the same source.

### 5. Status-bar rollup

`scripts/amux-status` counts **agent panes** via `list-panes -a`, skipping panes
with an empty state entirely.

Behavior change worth stating plainly: a server with three tabs and no agents
yet shows nothing where it previously showed `💤 3`. The rollup becomes a count
of agents rather than a count of tabs. Since it also no longer reads a stamped
glyph, it resolves each state's glyph from `@amux-glyph-<state>` directly.

### 6. CLI semantics

- `amux wait-done %N` — that pane's state, read with `display-message -p -t %N
  '#{@agent_state}'`. **Not** `show-options -wqv` (finding 2).
- `amux wait-done @N` / `sess:idx` / bare name — aggregate: every agent pane in
  the window must be `done` or `idle`. A window with no agent panes returns
  immediately.
  The two cases must branch on the target's form, because `list-panes -t %N`
  lists that pane's whole **window**, not the single pane.
- `amux status` — lists panes: `%N`, `sess:win.pane`, window name, command, and
  state (`-` when the pane is not an agent).
- `prefix + b` — moves to a new `scripts/amux-next-blocked`, which finds the
  first blocked pane server-wide and issues `select-window` + `select-pane`. The
  logic no longer fits legibly in an inline binding, and as a script it is
  testable.
- `amux whoami`, `amux send`, `amux read`, `amux spawn`, `amux split` — unchanged.
  They already speak `%N`.
- Blocked-notification suppression stays window-level: if the window is on
  screen the pane is visible, so no ping is sent.

### 7. Skill

`skills/amux/SKILL.md` gains the pane-level model: a pane opened by `amux split`
is a real agent, addressable by its `%N` for `send`, `read`, and `wait-done`, and
visible in the switcher and the tab badge. The existing spawn-vs-split guidance
stays.

### 8. Migration of a running server

The live server must upgrade in place via `prefix + r`, without a restart.
Two leftovers would otherwise corrupt the new model:

1. **Window-scoped `@agent_state` on existing windows.** By finding 5, pane
   lookups fall back to the window, so every unstamped pane in such a window —
   including plain shells — would report the window's old state and be counted
   as an agent.
2. **The global `@agent_state "idle"`.** Deleting the line from `amux.conf` does
   not unset an option already set on a running server; re-sourcing only adds and
   overwrites.

Therefore:

- `amux.conf` explicitly unsets the globals: `set -gu @agent_state`,
  `set -gu @agent_glyph`.
- A new `scripts/amux-migrate-state`, run from `bind r`, unsets `@agent_state`,
  `@agent_glyph`, and `@agent_since` at **window** scope across every window on
  the server. It is idempotent and a no-op after the first run.

No state is persisted anywhere, so a fresh server needs no migration at all.

### 9. tmux version floor

The design uses `#{P:}` loops, `#{E:}`, and `#{t/p:}`. The documented floor rises
from **3.1 to 3.2**; `scripts/amux-doctor` and the README are updated to match.
tmux 3.2 dates from 2021. Pane options themselves are not the constraint —
`set-option -p` landed in 3.0, and `#{E:}` in 2.9.

The implementation must confirm the exact minimum for `#{P:}` and `#{t/p:}` from
tmux's `CHANGES`/man page rather than trusting this paragraph, and adjust the
floor if either is later than 3.2.

## Testing

New:

- `tests/test-pane-state.sh` — the badge matrix from §2 (shell + agent, no
  agents, mixed states, duplicate states); pane isolation (stamping one pane
  leaves its sibling empty); the comma trap (a loop body with a literal comma
  must not be introduced); migration (a window-scoped leftover does not leak into
  an unstamped pane after `amux-migrate-state`).
- `tests/test-next-blocked.sh` — `amux-next-blocked` selects the right window
  *and* the right pane, and is a no-op when nothing is blocked.

Updated:

- `tests/test-agent-state.sh` — pane scope; a sibling-leak assertion; the
  cheaper single-read early exit still bails when the state is unchanged.
- `tests/test-coordination.sh` — `wait-done %N` is pane-precise; `wait-done @N`
  aggregates; a window with no agents returns immediately; the regression guard
  that `wait-done` never reads a window-scoped option.
- `tests/test-switcher.sh` — single-pane collapse, multi-pane header + indented
  rows, `window·command` present on every pane row, explicit sort order,
  non-agent panes rendered without a state.
- `tests/test-window-glyph.sh` — the badge's idle fallback replaces the old
  `@agent_glyph` fallback.
- `tests/test-settings.sh` — a glyph/theme change is live with no restamp step.

Retired:

- `tests/test-restamp.sh` — the script it covers is deleted.

All tests keep using isolated `-S` sockets via the existing `AMUX_*_SOCK` seams;
none may touch the live `-L amux` server. The suite must stay green on both
bash 5 and bash 3.2.

## Out of scope

- Per-pane titles or naming (`amux split -n`).
- Layout presets beyond what `amux split` already offers.
- Any change to `spawn`, `send`, `read`, or the remote (`ssh`) path.
