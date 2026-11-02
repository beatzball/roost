# Probe 3.12 — a resumed fleet against placement only (§2.9)

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 3.12.
Design: docs/airig/specs/2026-10-24-persistent-sessions-design.md §2.9.
Date: 2026-11-01. macOS 26.3, tmux 3.6, Claude Code 2.1.316, the code of
this branch at Task 3.11. Run count: **once** for each number below.

## Method

**The stub fleet.** A throwaway `-L fleet` server under a temporary
`TMUX_TMPDIR`, with `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
`XDG_DATA_HOME`, `CLAUDE_CONFIG_DIR`, `CLAUDE_SETTINGS`, `CODEX_HOME`,
`COPILOT_HOME`, `PI_CODING_AGENT_DIR` and `ROOST_SHAPE_DIR` all in one temp
directory, `ROOST_RECORD_DIR` empty, `ZDOTDIR` unset. A hand-written shape of
30 sessions, one window of one pane each, every pane keyed `harness claude`
with its own session id, and a stub Claude store holding all 30. The `claude`
first on `PATH` is a stub that execs `python3 -c` holding a fixed 50 MiB
`bytearray` (every page written, so it is resident) and sleeping.

1. **A, placement only:** `roost restore --no-resume` with no server running
   (restore starts it), 3 s, then the RSS of the tmux server's process tree.
2. The server killed by its socket path, the pending files and claims
   removed, then **B, resumed:** `roost restore` (default `--pace 2`), which
   returns after its loop; 3 s, then the same read.

The read: `ps -axo pid=,ppid=,rss=`, every process descending from the
server's `#{pid}` (the server included), RSS summed, in KiB.

**One real Claude.** `tests/live/revive-smoke.sh` (Task 2.8's rig: fake
Messages API, throwaway home, settings hash guard), copied to a scratch
directory with one addition after its `roost revive`: once the resumed
Claude has re-identified with the same id, and before any new prompt, the
RSS of the pane's process tree (`#{pane_pid}` and its descendants), read
twice 5 s apart. The rig's guards passed (10 passed, 0 failed; no change to
the real settings or trusted projects).

## Results (raw)

```
tmux 3.6; 30 panes; stub = python3 holding 50 MiB
A rc=0
A placed-only: 95776 31  (KiB, processes)
B rc=0 in 68 s
roost restore: restored 30 sessions, 30 windows, 30 panes; launched 30 agents; skipped 0 (existing); 0 not resumed (reasons listed above)
B resumed: 1982912 31  (KiB, processes)
```

```
PROBE-RSS-1 237584
PROBE-RSS-2 237920
```

## The numbers

| what | KiB | ratio |
|---|---|---|
| A: 30 panes placed, no agent (server + 30 shells) | 95,776 | 1 |
| B: the same 30 panes, 30 stub agents resumed | 1,982,912 | **20.7 × A** |
| B − A, per stub agent | 62,905 | the 50 MiB held + about 11 MiB of python3 |
| one resumed real Claude, its pane tree, before its first prompt | 237,920 | — |

Scaled, not measured: 30 real Claudes at that size are about 7.1 GB
(30 × 237,920 KiB), about **75 × A**.

## What it says about §2.9's hypothesis

§2.9 guessed that what was "too heavy" at the 2026-10-20 boot was 35 cold
starts at once, which pacing spreads, rather than the resident set, which
pacing does not reduce.

- A freshly resumed real Claude, **before any prompt**, already holds about
  232 MiB — about 83 % of the 278 MB mean §2.9 read for long-running agents.
  So the resident set arrives with the resume itself, not later with use,
  and pacing cannot lower it: B is the same whatever `--pace` is.
- That resident set for a fleet of the incident's size (about 7 GB for 30)
  is a small part of the 128 GB machine §2.9 names. RSS alone does not
  explain "too heavy".

So the numbers are **consistent with** the hypothesis, and do not prove it:
cold-start cost (CPU, disk, the harness's own start work, many at once) was
not measured here, and RSS cannot show it (§2.9's own caveat). One run each;
the per-agent figure for real Claude is one agent.
