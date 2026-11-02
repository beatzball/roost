# Probe 4.4 — the kill difference on tmux 3.2a and 3.4

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 4.4.
Spec: §2.7 ("A kill is seen inside tmux, at hook time", revision 3,
measured on 3.6 only), §3.6a.

## Outcome

**The same BEFORE/AFTER sets as on 3.6, on 3.2a, 3.4, 3.6 and 3.8.** A kill
is in its own difference, a death never is, a move gives none, and a
`SIGTERM` to the server runs no hook. Task 4.6 as written.

Two facts the builder must keep:

- **Compare as sets, never as strings.** After a `join-pane` the AFTER list
  holds the same ids in another order on every build (`BEFORE=%0 %2 %11 …
  AFTER=%0 %15 %16 %2 %11 …` on 3.2a and 3.4). A string compare would read
  that as a kill.
- The order in which the `-b` jobs write their lines differs between builds
  (3.2a wrote `window-unlinked` before `pane-exited` for a pane dying in its
  own session); the sets each line carries do not. What decides the result
  is that the `pane-exited` hook's synchronous refresh of `@ids` ran before
  the next hook expanded its BEFORE, on every build.

## Method

The same script on the four builds of Task 4.3 (3.2a and 3.4 in
`ubuntu:22.04` and `ubuntu:24.04` containers; 3.6 and 3.8 on this Mac),
each once, on a throwaway `-S` socket with `HOME`, `XDG_CONFIG_HOME`,
`TMUX_TMPDIR` in a `mktemp -d /tmp/amx.XXXX` directory and `-f /dev/null`.

- Every structural hook (`after-new-session`, `after-new-window`,
  `after-split-window`, `after-rename-window`, `after-rename-session`,
  `window-linked`, `after-select-layout`, `after-resize-pane`, `pane-died`)
  at `[98]`: `set -gF @ids "#{S:#{W:#{P:#{pane_id} }}}"`.
- Each removal hook (`after-kill-pane`, `window-unlinked`,
  `session-closed`, `pane-exited`) at `[98]`: `run-shell -b "echo NAME
  pane=#{hook_pane} BEFORE=#{@ids} AFTER=#{S:#{W:#{P:#{pane_id} }}} >> LOG"
  ; set -gF @ids "#{S:…}"` — the old value and the new loop expanded when
  the hook runs, then the refresh.
- A death "within 20 ms" of a kill: the dying pane runs `while [ ! -e GO ];
  do sleep 0.005; done`; the case runs `touch GO; sleep 0.02; kill-pane
  -t VICTIM`.

## Raw output (3.4; 3.2a, 3.6 and 3.8 carry the same sets)

```
-- kill-pane  (ids before: %0 %2 %1 )
   after-kill-pane pane= BEFORE=%0 %2 %1 AFTER=%0 %2
-- kill-session (not the last)  (ids before: %0 %2 %3 %4 )
   session-closed pane= BEFORE=%0 %2 %3 %4 AFTER=%0 %2
   window-unlinked pane= BEFORE=%0 %2 AFTER=%0 %2
-- a pane dying in its own window  (ids before: %0 %2 %5 )
   pane-exited pane=%5 BEFORE=%0 %2 %5 AFTER=%0 %2
   window-unlinked pane= BEFORE=%0 %2 AFTER=%0 %2
-- a pane dying in its own session  (ids before: %0 %2 %6 )
   pane-exited pane=%6 BEFORE=%0 %2 %6 AFTER=%0 %2
   window-unlinked pane= BEFORE=%0 %2 AFTER=%0 %2
   session-closed pane= BEFORE=%0 %2 AFTER=%0 %2
-- a death then a kill-pane within 20 ms (same window)  (ids before: %0 %2 %7 %8 )
   pane-exited pane=%8 BEFORE=%0 %2 %7 %8 AFTER=%0 %2 %7
   after-kill-pane pane= BEFORE=%0 %2 %7 AFTER=%0 %2
   window-unlinked pane= BEFORE=%0 %2 AFTER=%0 %2
-- a death (own window) then a kill-pane within 20 ms  (ids before: %0 %2 %9 %10 )
   pane-exited pane=%10 BEFORE=%0 %2 %9 %10 AFTER=%0 %2 %9
   window-unlinked pane= BEFORE=%0 %2 %9 AFTER=%0 %2 %9
   after-kill-pane pane= BEFORE=%0 %2 %9 AFTER=%0 %2
   window-unlinked pane= BEFORE=%0 %2 AFTER=%0 %2
-- break-pane (not the last pane)  (ids before: %0 %2 %11 %12 )
-- break-pane (a window's last pane)  (ids before: %0 %2 %11 %12 %13 )
   window-unlinked pane= BEFORE=%0 %2 %11 %12 %13 AFTER=%0 %2 %11 %12 %13
-- move-window  (ids before: %0 %2 %11 %12 %13 %14 %15 )
   window-unlinked pane= BEFORE=%0 %2 %11 %12 %13 %15 %14 AFTER=%0 %2 %11 %12 %13 %15 %14
-- join-pane (keeps its window)  (ids before: %0 %2 %11 %12 %13 %15 %16 %14 )
-- join-pane (last pane of its window)  (ids before: %0 %2 %11 %12 %13 %15 %16 %14 )
   window-unlinked pane= BEFORE=%0 %2 %11 %12 %13 %15 %16 %14 AFTER=%0 %15 %16 %2 %11 %12 %13 %14
-- kill -TERM of the server  (ids before: %0 %15 %16 %2 %11 %12 %13 %14 )
```

The last line is empty below it on every build: no hook ran.

## The sets, read

| case | difference (BEFORE minus AFTER), every build |
|---|---|
| `kill-pane` | the killed pane |
| `kill-session`, not the last | that session's panes at `session-closed`; empty at the `window-unlinked` after it |
| a pane dying in its own window | empty at `window-unlinked` (`pane-exited` names the pane by `hook_pane`) |
| a pane dying in its own session | empty at `window-unlinked` and `session-closed` |
| a death, then a `kill-pane` within 20 ms | only the killed pane |
| `break-pane`, `move-window`, `join-pane` | empty, or no removal hook at all |
| `kill -TERM` of the server | no hook ran |

Small differences between builds, none in a set: the pane ids of the
`kill-pane` case are in another order on 3.2a and 3.4 (where `split -d`
placed the new pane), and the order of the `-b` lines inside one case.
