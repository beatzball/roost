# Agent identity for `wait-done` (#64) — design

Status: **approved 2026-09-15, and built on the #64 branch** after #66 merged.
The human chose to count a hook-recorded identity as a fact, and to record the
pane terminal's foreground job.

## 1. The problem

After #54, `roost wait-done` exits 2 when an agent's pane closes or goes dead
while it reads `working` or `blocked`. It still misses an agent that was typed
at a shell prompt and then died: the pane stays alive, `pane_dead` stays 0, no
hook rewrites the badge, and `wait-done` waits out its timeout and exits 1.

The issue asks for a recorded fact, not an inference from names or screen text,
and it asks one question first: **does an identity recorded by the agent's own
hook count as a fact, or is checking it a guess?**

## 2. The decision

**It counts as a fact, in this form:** the foreground job on the pane's
terminal at the moment a hook stamps `working` or `blocked`.

It is read from the terminal, not from the hook's parent processes, so it is
the same fact for all five harnesses and every way a hook can be delivered.
It was the agent's job at every hook call measured below, in all five
harnesses. `wait-done` then calls a pane died only when two more kernel facts
hold at check time:

1. no process of that job is left, **and**
2. the pane's shell holds the terminal again.

A "job" here is a process group: the group an interactive shell creates for a
command typed at its prompt, and hands the terminal to while it runs.

## 3. Measurements

Machine: macOS 25.3 (arm64), tmux 3.6, every run on a throwaway `-S` socket.
Agents were typed into `/bin/sh -i` unless stated. `~/.claude/settings.json`
and `~/.codex/config.toml` were hashed before and after every live run, and no
run changed either file. Probes: a hook script that logs `$$`, `$PPID` and its
ancestry with `pid, ppid, pgid, tpgid, tty, lstart`, and an in-process plugin
for opencode, pi and copilot that logs `process.pid` and `process.ppid` and
runs the same hook script as a child. The probe was checked on a known call
before any live run.

### 3.1 Per harness: the foreground job at hook time

| harness, version | how measured | hook/plugin sees | foreground job (`tpgid`) at hook time |
|---|---|---|---|
| Claude Code 2.1.272 | a `--settings` file; a settings-file source; a non-exec PATH wrapper | hook `$PPID` = `claude` | `claude`'s job (under the wrapper: the wrapper's job, which holds `claude`) |
| codex-cli 0.154.0 | isolated `CODEX_HOME` + `HOME`, ollama `granite4.2:8b` via the test proxy, hooks trusted in the TUI | hook `$PPID` = `codex` on SessionStart, UserPromptSubmit, Stop | `codex`'s job |
| opencode 1.18.30 | isolated XDG homes, plugin dir | `process.pid` = `opencode` | `opencode`'s job |
| pi 0.81.1 | isolated `PI_CODING_AGENT_DIR` | `process.pid` = `pi` (`node`) | `pi`'s job |
| copilot 1.0.83 | isolated `COPILOT_HOME`, BYOK ollama | `process.pid` = a forked extension host; `process.ppid` = `copilot` | `copilot`'s job |

Other facts from the same runs:

- Claude runs a hook in its **own process group with no terminal** (`tty ??`).
  Codex runs a hook in its own process group but on the pane's terminal. The
  plugins' children share the agent's process group. So the hook's own process
  group is not the identity; the terminal's foreground job is.
- Claude starts `caffeinate` inside its own process group. **Corrected while
  building:** the design runs killed an *idle* Claude, when no `caffeinate` was
  running. Killed in the middle of a reply, Claude 2.1.272 and 2.1.273 left
  `caffeinate -i -t 300` alive in the job for up to 305 s — see section 8. The
  human chose to keep the strict rule anyway.
- After `SIGKILL` of the agent, in all five: the job had no process left, the
  terminal's foreground job returned to the pane's shell (`tpgid` =
  `pane_pid`), `pane_dead` stayed 0 and `pane_current_command` became `bash`.
- A stand-in agent killed with `SIGTERM` in `/bin/sh -i` and in `zsh -il`: the
  same.

### 3.2 Checking later: cost and speed

500 calls each. Linux numbers come from a Debian container on Docker's
linuxkit 6.11 kernel, not a Linux host.

| operation | macOS | Linux (container) |
|---|---|---|
| `kill -0 PID` (bash builtin, no fork) | 27 µs | 10 µs |
| `ps -o lstart= -p PID` (fork; `ps -o tpgid=` is the same shape) | 1786 µs | 727 µs |
| bare fork + exec of `true` | 1590 µs | 233 µs |
| `tmux display-message` | 3970 µs | not measured |

- **How fast a death is visible:** `SIGKILL` to `kill -0` failing took 5.2,
  5.0 and 5.8 ms, because an interactive shell reaps its job at once. A
  `wait-done` poll is 250 ms, so detection takes one poll.
- **Pid reuse:** on macOS pids wrap after 99999. The next free pid moved by
  13,624 in 60 s on this machine while live agents and these tests ran, so a
  full wrap took about 7 minutes. The wrap was also seen directly: a run at
  00:31 got pids near 72,600, and a run at 00:40 got pids 127 and 130. The
  Linux container's `pid_max` was also 99999; a Linux host's default was not
  measured. For the job record, reuse matters in one direction only: a reused
  id can make a dead job look alive (a timeout), never make a live job look
  dead.
- `kill -0` reports a process owned by another user (`EPERM`) as failure: on
  the host `kill -0 1` returned 1 while `ps -p 1` returned 0. An agent's job
  belongs to the same user as the hook, so this does not arise for a record
  the sink wrote; section 5 still confirms with the terminal before calling a
  death.

### 3.3 Live agents that must never read as died

| case | measured | result |
|---|---|---|
| agent typed at a prompt, killed | Claude, codex, opencode, pi, copilot | died ✓ |
| `bash -c 'agent'` (one command) | bash `exec`s it: the child's `$PPID` was the outer shell | same as plain |
| `bash -c 'agent; …'`, or a wrapper that waits and exits | the wrapper leads the job | died once the wrapper exits ✓ |
| agent that re-`exec`s itself | pid and job unchanged | alive ✓ |
| agent that restarts as a child and exits (stand-in for an upgrade restart) | old process gone; the child kept the job | alive ✓ |
| #58 PATH wrapper that adds `--settings`, no `exec` | the job is the wrapper's and holds `claude` | alive ✓ |
| hook fired twice | section 3.6 | same record twice |
| **wrapper that outlives its agent** | Claude under a wrapper that runs `sleep 600` after it, Claude killed | **not detected**: section 8 |

Codex's own upgrade does not restart in place: it prints "Update ran
successfully! Please restart Codex."
(docs/airig/issues/2026-08-29-codex-upgrades-its-own-host.md). A restart by a
human is a new job that stamps again.

### 3.4 Where no record is made, and where one goes stale

A missing record always gives today's behaviour: a timeout, exit 1.

| situation | measured fact | result |
|---|---|---|
| agent **is** the pane's command (`roost spawn`) | `tpgid` = `pane_pid` while it lives | no record; #54 already covers its death |
| agent started with `&` | `tpgid` = `pane_pid` | no record |
| shell without job control (`sh -c` script as the pane) | the job's id is `pane_pid` | no record |
| container in the pane | inside, the shell was pid 1, ppid 0; the host `pane_pid` is not visible | no record |
| pane moved (`move-pane`, `break-pane`) | pane id, `pane_pid` and pane options all kept | record still valid |
| `respawn-pane -k` | pane option **kept**, `pane_pid` changes | the record stores `pane_pid`, so it is ignored |
| `roost ssh HOST` | it is `exec ssh -t HOST roost …`: agents, hooks and `wait-done` all run on the remote | works there |
| `ssh` typed into a local pane | a remote hook has no local `$TMUX` | no badge at all, unchanged |
| `opencode attach` to a detached server | not measured | records the pane's foreground job, the attach client |
| pane command is a login wrapper, not the shell | not measured; inferred | the shell's job is not `pane_pid`, so never died → timeout |
| older install, or a hook that never reaches the new sink | — | no record |

### 3.5 Cost on hook calls

A scratch copy of `scripts/roost-agent-state` against a throwaway server.

- **Hot path (unchanged state, PostToolUse): not touched.** The record is
  written only after the unchanged-state bail, so that path runs no new code.
  Today it measured 9.4 to 10.9 ms per call.
- **Busy transition:** alternating working/done measured 23.0 and 21.9 ms per
  transition today, and 30.3 and 27.0 ms with the record. **+5 to +7 ms per
  transition.**

### 3.6 Hooks that fire twice (#58 migration hazard)

- The **same command string** in two sources (a settings file and
  `--settings`): Claude 2.1.272 ran each hook **once**.
- **Different** command strings for the same event (one in a settings file,
  one through `--settings`): every event fired **twice**, in the same second —
  SessionStart, UserPromptSubmit and Stop. All six calls saw the same
  foreground job, because the value is the terminal's state at that instant.

The record is a pane option, so a second write of the same value changes
nothing.

## 4. The design

`scripts/roost-agent-state` only. No adapter changes, no `hooks.json` or
settings changes.

On a transition into `working` or `blocked` (after the unchanged-state bail):

1. Read `#{pane_pid}` with one `tmux display-message`. It is a new call on
   the busy-transition path only (about 4 ms of the measured +5 to +7 ms); the
   hot-path read above the bail is deliberately left as it was.
2. Run `ps -o tpgid= -p PANE_PID`: the pane terminal's foreground job.
3. If it is non-empty and differs from `PANE_PID`, set the pane option
   `@roost-agent-job` to `"PGID:PANE_PID"` (no space, so `wait-done` can read it as one field). Otherwise unset it: the agent is
   not a job of the pane's shell, and nothing is recorded.

Nothing is recorded either when the foreground job is the sink's own process.
`roost state working` typed at a prompt `exec`s into the sink, which then leads
its own job and exits at once; a record of it would report "died" a moment
later about a pane with no agent. (Added while building, and pinned by
tests/test-wait-done-shell.sh. No measured harness runs the sink as a job
leader.)

Every tmux and `ps` call keeps the sink's `|| true` discipline: a failure
records nothing, and never breaks the agent.

A stale record from an earlier agent in the same pane cannot cause a false
"died": while a newer job holds the terminal, rule 2 of section 2 fails. The
newer agent writes its own record on its next busy transition.

### Not chosen: the agent's pid

Recording the agent's own pid (with its start time, against reuse) was the
other candidate. It would catch a wrapper that outlives its agent. It was not
chosen because the process that calls a hook is not always the agent — for
copilot it is a forked extension host, and for codex's shipped adapter the
sink is two levels below codex — so all five adapters would each have to name
their agent, and one wrong name is a false "died". It also gave a false "died"
on the measured restart-by-child stand-in, where the job record stays correct.

## 5. How `wait-done` uses it

For each pane the snapshot reads `working` or `blocked`, after the existing
error check (an errored pane keeps exit 1) and the #54 checks:

1. No `@roost-agent-job`, or its `PANE_PID` differs from the pane's current
   `#{pane_pid}` → nothing new; today's behaviour.
2. `kill -0 -- -PGID` succeeds → a process of that job lives → not died.
3. It fails → one `ps -o tpgid= -p PANE_PID`. Equal to `PANE_PID` → **exit 2**,
   with a message that names the reason, for example:
   `roost: '%N' died: the job that held its terminal when it read working has
   exited, and the pane's shell has the terminal back`.
   Anything else → another job holds the terminal → not died, keep waiting.

A window target applies the same per-pane rule, so it gives a pane target's
answer. Exit codes keep their meanings: 0 finished, 1 timeout or error, 2 died
or gone.

Implementation notes for the plan:

- The snapshot rows already end in the one field that may be empty (the
  state). A second possibly-empty field needs a sentinel or a fixed position,
  not `read`'s whitespace split.
- Step 2 runs every poll (27 µs). Step 3 forks only when step 2 fails.

## 6. Coexisting with #58

#58 may deliver roost's wiring three ways: an environment variable
(`OPENCODE_CONFIG_DIR`), a PATH wrapper that adds `--settings` for `claude`, or
today's global install for pi, codex and copilot. Claude may also run a hook
twice during a migration.

- **The record does not depend on how the hook arrived.** It reads the pane's
  terminal, not the hook's parents. Measured under `--settings`, under a
  settings-file source, and under a non-exec PATH wrapper: the same foreground
  job each time. The `OPENCODE_CONFIG_DIR` route was not measured here; the
  plugin still runs inside opencode, and the sink still reads the terminal.
- **Twice-fired hooks** write the same value (section 3.6).
- #58's "pane identity through the environment" is *which pane*; this record is
  *which job*. They do not overlap.
- This design edits no codex `hooks.json` command string and no Claude
  settings entry, so it changes nothing #58 generates.

## 7. Build order

The build starts **only after #66 merges**, rebased on that `main`, because #66
changes `wait-done`'s argument parsing and both touch the same branch of
`bin/roost`. The coordinator sends the go.

1. Red tests on a throwaway socket, with a stand-in agent typed into
   `/bin/sh -i` and stamped through the real sink: killed → exit 2 within one
   second, on a pane target and a window target; a live agent under a wrapper
   that exits with it, under `bash -c`, and under a restart-by-child stand-in →
   never exit 2; a pane with no record → exactly #54's behaviour; a spawn-style
   pane → no record; a respawned pane → record ignored.
2. The sink records on busy transitions (section 4).
3. `wait-done` reads the record (section 5).
4. Mutation-test each guard: drop the `tpgid` check in step 3, drop the
   `PANE_PID` match, drop the record write.
5. Live check with Claude and codex under the live-run rules.
6. `docs/known-gaps.md`: remove the "killed inside a shell" gap, and add the
   case in section 8 and the no-record cases in section 3.4.

## 8. What this misses

### 8.1 A Claude killed in the middle of a reply (found while building)

Mid-reply, Claude runs `caffeinate -i -t 300` in its own job. After Claude is
killed, the shell has the terminal back within 0.08 s, but the job has a live
process until the helper exits: 305.23 s on Claude 2.1.273, and still alive at
76 s on 2.1.272, where `wait-done %0 60` timed out with exit 1. A `wait-done`
with a shorter timeout therefore exits 1, as before #64. Kept on purpose: the
human chose the strict rule over "the job's first process is gone", which would
catch this at once but would call an agent that restarts itself as a child
died. The evidence for revisiting that is recorded for a follow-up issue.

### 8.2 A wrapper that outlives its agent

If the agent runs under a wrapper script that keeps running after the agent
dies — for example a script that starts `claude` without `exec`, then goes on
to `sleep` or wait for something else — the wrapper is still a live process of
the job. `kill -0 -- -PGID` succeeds, and the shell does not get the terminal
back.

**Measured:** Claude under a wrapper that runs `sleep 600` after it; Claude
killed with `SIGKILL`. The job still had two processes (the wrapper and its
`sleep`), and the terminal's foreground job was still the wrapper's.

**Result:** `wait-done` does not see the death. It waits out its timeout and
exits 1, exactly as before this design. It never reports a false "died".

A wrapper that exits when its agent exits — the usual shape, including a #58
PATH wrapper that runs `claude` and then ends — is detected.
