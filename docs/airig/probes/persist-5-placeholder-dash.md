# Probe 5.2 — the placeholder under `dash` (#192)

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 5.2.
Date: 2026-11-03. `ubuntu:24.04` container from a `git archive` export of the
branch (base b972c09 plus probe 5.1's file), `LANG=C.UTF-8`; `/bin/sh` →
`/usr/bin/dash` (dash 0.5.12-6ubuntu5), tmux 3.4, coreutils `stty`/`dd`.
Run count: the wake and the exits twice (the second run added the key
timing and a fresh socket for the exits), `tests/test-shape-place.sh` once.

## Method

1. Task 1.7's wake script (persist-1-placeholder.md), run by `/bin/sh`
   (dash) in a pane of a throwaway `-S` server with a temp `HOME`, `-f
   /dev/null`, no client. Screen read at 0, 6, 11 and 16 s; then
   `send-keys x`, polled every 50 ms for the `byte=` line; then the loop's
   CPU time.
2. The real `scripts/roost-placeholder FILE --placing` started as a pane's
   command, so its own `#!/bin/sh` line picks the shell: read the pane's
   process and `/proc/PID/exe`.
3. `remain-on-exit failed` on a window, then `respawn-pane -k` with
   `/bin/sh -c 'exit 1'` and with `'exit 0'`.
4. `bash tests/test-shape-place.sh` (every placing-mode case of the suite).

## Result

| step | read |
|---|---|
| screen at 0 s, 6 s | empty (the first wake lands just after 6 s here: the shell started late in a cold container) |
| screen at 11 s | `wake 1 t=5 nobyte` |
| screen at 16 s | `wake 1 t=5 nobyte`, `wake 2 t=11 nobyte` |
| `send-keys x` | `wake 3 t=15 byte=78` appeared **0.01 s** after the key |
| CPU time of the loop | `00:00:00` (no busy loop) |
| the placeholder's process | `/bin/sh /w/scripts/roost-placeholder …/pending --placing`, `/proc/PID/exe` = `/usr/bin/dash` |
| `exit 1` under `remain-on-exit failed` | pane kept, `dead=1 status=1` |
| `exit 0` | pane gone |
| `tests/test-shape-place.sh` | rc 0, **202 passed, 0 failed** (canary clean) |

The first run's exit cases reused the wake server's socket right after
`kill-server` and read `server exited unexpectedly`; that was the probe's own
socket reuse, not dash. The second run used a fresh socket and read the rows
above.

## Outcome

**Passes → nothing.** Under dash, `stty raw -echo min 0 time 50` + `dd bs=1
count=1` wakes about every 5 s with no byte and returns at once on a key,
without a busy loop; the placeholder runs as dash through its own `#!/bin/sh`;
`remain-on-exit failed` keeps an `exit 1` pane dead and drops an `exit 0`
one, as on macOS.
