# Probe 1.7 — the placeholder's 5-second wake and `remain-on-exit failed`

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.7.
Date: 2026-10-27. macOS 26.3, `/bin/sh` (which runs `/bin/bash` in sh mode
here: `/private/var/select/sh -> /bin/bash`), tmux 3.6. Run count: once.

## Method

A throwaway `-S` server in a temp directory, temp `HOME`, `-f /dev/null`, no
client attached. The pane ran this script with `/bin/sh`:

```sh
stty raw -echo min 0 time 50
n=0; start=$(date +%s)
while :; do
  b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  n=$((n+1)); now=$(date +%s)
  if [ -z "$b" ]; then printf 'wake %d t=%d nobyte\r\n' "$n" "$((now-start))"
  else printf 'wake %d t=%d byte=%s\r\n' "$n" "$((now-start))" "$b"; fi
done
```

The screen was read with `capture-pane -p` at 0, 6, 11 and 16 s after the
session started; then `send-keys x`, and the screen read 1 s later; then the
shell's CPU time (`ps -o time=`), to rule out a busy loop.

`remain-on-exit failed`: a window running `sleep 60`, the option set with
`set -p`, then `kill -9` of the pane's pid; a window running `sh -c "exit 1"`,
and one running `sh -c "exit 0"`, the option set right after `new-window`.
The two `exit` cases again with no race: a window running `sleep 600`, the
option set, then `respawn-pane -k` with the exiting command. Each read 1 s
later: is the pane listed, `pane_dead`, `pane_dead_status`,
`pane_dead_signal`.

## Result

| step | read |
|---|---|
| screen at 0 s | empty (no wake yet) |
| screen at 6 s | `wake 1 t=5 nobyte` |
| screen at 11 s | `wake 1 t=5`, `wake 2 t=10 nobyte` |
| screen at 16 s | ... `wake 3 t=15 nobyte` |
| `send-keys x` at 16 s, read 1 s later | `wake 4 t=16 byte=78` (`x`) |
| CPU time of the loop after ~18 s | `0:00.01` |
| `kill -9` of `sleep 60` under `remain-on-exit failed` | pane present, `pane_dead=1`, `pane_dead_status=` (empty), `pane_dead_signal=kill` |
| `exit 1` (both ways) | pane present, `pane_dead=1`, `pane_dead_status=1` |
| `exit 0` (both ways) | pane **gone** |

## Outcome

- **Wake:** `dd` returns about every 5 s with no byte, and at once on a key,
  with no busy loop. Task 1.11 uses exactly `stty raw -echo min 0 time 50` +
  `dd bs=1 count=1`.
- **`kill -9`:** leaves the pane dead under `remain-on-exit failed`
  (`pane_dead_signal=kill`). Part 4's crashed-placeholder test (Task 4.10)
  uses `kill -9`.
- **`exit 1`:** leaves a dead pane (`pane_dead_status=1`), so every
  `remain-on-exit failed` net in §4.1 step 7 and §4.7 holds. `exit 0` removes
  the pane, as `failed` means.

Not covered here: Ubuntu `dash` (Task 5.2 is that probe).
