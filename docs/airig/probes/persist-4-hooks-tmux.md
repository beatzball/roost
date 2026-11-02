# Probe 4.3 — hook names and moves on tmux 3.2a and 3.4

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 4.3.
Spec: §2.7 (revision 4's hook-name and move probes, measured on 3.6 only),
§3.4's table.

## Outcome

**Every name exists on 3.2a and 3.4, and every move fires as on 3.6, with
one difference that touches no kill.** Task 4.6 installs §3.4's table as
written. The table's rows, in order:

- Every name §3.4 uses — `after-new-session`, `session-closed`,
  `after-rename-session`, `after-new-window`, `window-linked`,
  `window-unlinked`, `after-rename-window`, `after-split-window`,
  `pane-exited`, `pane-died`, `after-kill-pane`, `after-select-layout`,
  `after-resize-pane` — plus `client-attached`, sets with exit 0 on 3.2a,
  3.4, 3.6 and 3.8. The made-up control fails on all four with `invalid
  option`. The ten names §2.7 found missing on 3.6 are missing on 3.2a and
  3.4 too; on 3.8 one of them, `after-swap-window`, now exists (not used:
  it is missing on the floor).
- **The one move difference:** `swap-pane` fires **no** hook on 3.2a;
  on 3.4, 3.6 and 3.8 it fires only `window-layout-changed`. Neither is a
  hook this design uses, so `swap-pane` is "saved with the next event" on
  every build, as §3.4 already says; it is in Task 4.6's "what no hook
  covers" list. It changes no kill difference (no removal hook fires).
- **Where a hook is listed** (not a difference in behaviour, a fact Task
  4.6's check needs): `set-hook -g` of a pane or window hook stores it with
  the window options, so `show-hooks -g` does not list it and `show-hooks
  -gw` does. `pane-exited`, `pane-died`, `window-renamed` and
  `window-layout-changed` are `-gw` on every build; `window-linked` and
  `window-unlinked` are `-gw` on **3.2a** and `-g` on 3.4, 3.6 and 3.8.
  So "every `[98]` name it sets is listed" reads both `show-hooks -g` and
  `show-hooks -gw`.

## Method

The same two scripts on four builds, each once:

| build | where |
|---|---|
| tmux 3.2a | `ubuntu:22.04` container, apt's tmux |
| tmux 3.4 | `ubuntu:24.04` container, apt's tmux |
| tmux 3.6 | this Mac, the installed tmux |
| tmux 3.8 | this Mac, the unpacked 3.8 bottle first on `PATH` (persist-1-tmux38.md) |

Each run: a throwaway `-S` socket under `mktemp -d /tmp/amx.XXXX`, `HOME`,
`XDG_CONFIG_HOME` and `TMUX_TMPDIR` in that directory, `TMUX` unset,
`-f /dev/null`, a 200x50 session.

1. **Names.** For each of the 18 names §2.7 found on 3.6, the ten it found
   missing, and a made-up `after-made-up-control`: `set-hook -g NAME[98]
   'run-shell -b true'`, its exit code and error, then whether
   `show-hooks -g` and `show-hooks -gw` list `NAME[98]`.
2. **Moves.** A `[97]` hook on each of the 18 names runs `run-shell "echo
   NAME >> LOG"`. Each move: wait 0.6 s (so the hooks of the setup before
   it have written), empty the log, run the move, wait 0.6 s, print the log.

## Raw output: names (3.2a; 3.4, 3.6 and 3.8 differ only where said above)

```
after-new-session rc=0 listed_g=1 listed_gw=0
after-new-window rc=0 listed_g=1 listed_gw=0
after-split-window rc=0 listed_g=1 listed_gw=0
after-kill-pane rc=0 listed_g=1 listed_gw=0
after-rename-window rc=0 listed_g=1 listed_gw=0
after-rename-session rc=0 listed_g=1 listed_gw=0
after-select-layout rc=0 listed_g=1 listed_gw=0
after-resize-pane rc=0 listed_g=1 listed_gw=0
pane-exited rc=0 listed_g=0 listed_gw=1
pane-died rc=0 listed_g=0 listed_gw=1
window-linked rc=0 listed_g=0 listed_gw=1
window-unlinked rc=0 listed_g=0 listed_gw=1
window-renamed rc=0 listed_g=0 listed_gw=1
session-closed rc=0 listed_g=1 listed_gw=0
session-renamed rc=0 listed_g=1 listed_gw=0
window-layout-changed rc=0 listed_g=0 listed_gw=1
client-attached rc=0 listed_g=1 listed_gw=0
client-detached rc=0 listed_g=1 listed_gw=0
after-respawn-pane rc=1 ... err=invalid option: after-respawn-pane[98]
after-move-pane rc=1 ... err=invalid option: after-move-pane[98]
after-join-pane rc=1 ... err=invalid option: after-join-pane[98]
after-break-pane rc=1 ... err=invalid option: after-break-pane[98]
after-swap-pane rc=1 ... err=invalid option: after-swap-pane[98]
after-move-window rc=1 ... err=invalid option: after-move-window[98]
after-swap-window rc=1 ... err=invalid option: after-swap-window[98]
after-link-window rc=1 ... err=invalid option: after-link-window[98]
after-kill-window rc=1 ... err=invalid option: after-kill-window[98]
after-kill-session rc=1 ... err=invalid option: after-kill-session[98]
after-made-up-control rc=1 ... err=invalid option: after-made-up-control[98]
```

On 3.4, 3.6 and 3.8, `window-linked` and `window-unlinked` read
`listed_g=1 listed_gw=0`. On 3.8, `after-swap-window rc=0 listed_g=1`.

## Raw output: moves (3.4)

```
-- break-pane (not last)
window-layout-changed window-renamed window-linked
-- break-pane (last pane of a window)
window-linked window-unlinked
-- move-window
window-linked window-unlinked
-- link-window
window-linked
-- join-pane (keeps its window)
window-layout-changed window-layout-changed window-layout-changed
-- join-pane (last pane of its window)
window-layout-changed window-unlinked window-unlinked window-layout-changed
-- move-pane (last pane)
window-layout-changed window-unlinked window-layout-changed
-- swap-pane
window-layout-changed
-- swap-window

-- respawn-pane -k

-- kill-pane
after-kill-pane window-layout-changed
-- kill-window
window-unlinked
-- kill-session (not last)
session-closed window-unlinked
```

3.2a: the same, except `swap-pane` prints an empty line. 3.6: the same as
3.4 (its `break-pane (not last)` adds a second `window-renamed`, from the
automatic name). 3.8: the same as 3.6, `kill-pane` listing
`window-layout-changed` before `after-kill-pane`. The order inside one line
is the order the hooks' commands ran and is not used by the design.

## What this means for Task 4.6

- Install §3.4's names; nothing more is needed on 3.2a.
- The "listed" check reads `show-hooks -g` and `show-hooks -gw` together.
- "What no hook covers" stays: `swap-pane`, `swap-window`, a `join-pane`
  or `move-pane` that keeps its source window, `respawn-pane -k`.
