# Measurement 4.11 — what a save costs

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 4.11.
Spec: §3.4a ("*estimated* under 50 ms per save on this machine"; "the
measurements step 4 must take").

## The three numbers

| what | result | method |
|---|---|---|
| `roost save --auto` at 47 panes | **about 350 ms** a save that publishes (351, 352, 352, 359, 353 ms); about 310 ms one that finds nothing changed (332, 305, 307 ms) | wall time of the whole `bin/roost save --auto` process, five and three runs |
| ten `roost spawn`s in one second | all ten returned within **774 ms**; **one** save published (gen +1, one history file) | ten spawns started at once in the background, hooks loaded, timed until the last returned, then waited for every saver to finish |
| 50 `roost state working` on a working pane | **1194 ms** for all 50 (about 24 ms each); **no** shape written (gen +0) | 50 calls in a row from the pane's own environment |

The spec's estimate (under 50 ms) was not met. The save is still off every
agent's path — the hooks run it with `run-shell -b`, identify runs it in the
background — but a verb's own save (`spawn`, `split`, `close`) adds about a
third of a second to that verb at this fleet size.

Where the time goes, measured the same way: the build of the file body
(`roost_shape__body`, all 47 panes) takes about **130 ms**; the rest is
`bin/roost` starting, the three tmux listings, the R6/R8 read rules and the
checker run over the new file before it is published.

## Two faults the measurement found, fixed in the same task

1. **A process per keyed pane.** The agreement table asked each keyed pane's
   own process with its own `ps`, inside a `$(...)`: 15 keyed panes cost
   about 23 ms each. Now one `ps` serves every keyed pane
   (`roost_shape__comms`) and the table sets a variable instead of
   printing into a subshell. A test pins it: a save calls `ps` the same
   number of times on 40 panes as on 4, at most twice
   (tests/test-shape-save.sh).
2. **macOS `ps` with more than one pid is slow.** `ps -o pid=,comm= -p
   A,B` with two or more pids took about 290 ms whatever the count; `ps -A`
   about 90 ms; one `-p` pid about 3 ms (this Mac, about 2400 processes).
   Now: one pid is asked with `-p`, more with one `ps -A` cut to the wanted
   pids by `awk`. Without the cut, bash's pattern lookup over the whole
   process list was quadratic, and a save spun for minutes: the reason
   for the cut.

## The machine

A Mac16,5 with 16 cores, macOS, tmux 3.6, load average about 4.3 to 5
while measuring (other work was running), about 2400 processes. A
throwaway `-S` server under `mktemp -d /tmp/amx.XXXX` with every home and
`ROOST_SHAPE_DIR` redirected; 47 panes, every third with a harness and a
session id on a shell (stale keys, so the agreement table runs). Run once
each. Not measured: Linux, an idle machine, a fleet of real agents.
