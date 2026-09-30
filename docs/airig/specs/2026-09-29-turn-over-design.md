# When is a turn over, and who may say so — design for #95, #97, #105

Status: **approved 2026-09-29. Step 0 built (PR #139, `6db2398`); steps 1–5 not
started.** All nine questions are decided by the human and listed, dated, in
§8 — Q1 and Q2 on 2026-09-27, Q3–Q9 and the limits on 2026-09-28/29. §9 records
the two places they bend the "could not tell is never done" rule, and §10 what
the design's author expects to break in step 1. Read §10 before building.

Step 0 is the only part on `main`: the M1–M9 measurements and the two accepted
exceptions are in `docs/known-gaps.md`, and the "a long-lived server goes in its
own pane" line is in `skills/roost/SKILL.md`. Nothing else here is built.

Base: `main` at `88e9165`. New measurements: Claude Code **2.1.283**, tmux 3.6,
macOS, 2026-09-26, one throwaway `-S` server (details in §2). Anything not
executed is labelled *inferred* or *not measured*, and single runs say so;
§2's "Not measured" list is a list on purpose. A1–A3 are the three checks step 1
must run before it starts — they decide whether the ownership rule in §3.1 can
be built from Claude's own payload at all.

---

## 0. The short answer

The belief is **mostly right, with one real split.**

- #95, #97 and the "dead agent" half of #105 are one question: **when is a
  turn over?** They need one definition and one place that records the
  answer, or they will give three different answers.
- The "any process can stamp any pane" half of #105 is a second question:
  **who may write the badge?** It meets the first at one point only: a
  "turn is over" report counts only if the right process sent it.
- #105's text says ancestry is "the mechanism behind #77, #78 and #102 at
  once". **That is not true for #77 or #102.** A nested agent (#77) runs
  *inside* the pane's process tree, so it passes any ancestry test. #102 is
  about silence, not about the sender. Ancestry helps #78, but as a way to
  *find* a pane, not to refuse a report.

The measurement changed the picture for #97. On 2.1.283, Claude's `Stop`
payload **lists the background work that is still running**, and Claude
**starts a turn of its own** when that work ends. #97 is therefore not a
guess any more. It is a small, measurable fix.

The measurement also **refuted one idea** in the #95 comment: after an Esc
mid-stream, no `idle_prompt` Notification arrived within 170 s.

---

## 1. What was already known (not re-derived here)

From `docs/known-gaps.md`, and still true on `88e9165`:

- Esc while Claude streams fires **no hook** (2.1.272, "A Claude Code turn that
  fails on an API error"). The badge stays `working`.
- A declined dialog is recovered from Claude's transcript by
  `scripts/lib/roost-unblock.sh`, which **only unsets** (#38).
- `wait-done` exits **0** on an interrupted turn on every harness: codex's
  Interrupt leaves `idle`, Claude recovery leaves the badge unset, copilot maps
  `session.idle {aborted: true}` to `done` (known-gaps, #38 section).
- #64 already records the pane terminal's foreground job
  (`@roost-agent-job`), and `wait-done` exits 2 when that job is gone and the
  shell has the terminal back. Its two misses (Claude's `caffeinate` helper for
  up to ~300 s, a wrapper that outlives its agent) are recorded there.
- A Claude subagent's `PostToolUse` fires on the **main** pane
  (known-gaps, "A SUBAGENT's tool result…").

---

## 2. New measurements (Claude Code 2.1.283)

**Rig.** A throwaway `-S` socket under `/tmp/amx.*` ending in `/roost`, so
roost's own hooks acted on it. A local fake Messages API
(`ANTHROPIC_BASE_URL`) that scripts each reply: a plain answer, a background
`Bash`, an `Agent` call, a slow stream. One logger on **31 of Claude's 33 hook
events** (all but `WorktreeCreate`/`WorktreeRemove`, which act on the answer),
plus this checkout's `roost hooks claude`. The logger writes the full payload
and the hook's process ancestry. `--setting-sources local`, `--model haiku` on
the command line, no slash commands. `~/.claude/settings.json` was hashed
before and after: **unchanged**. (`~/.claude.json` changed. That is the
folder-trust entry the smoke tests also write, and every live Claude session
writes that file too.)

Raw logs, fake API, logger and start scripts:
`/tmp/claude-501/replies/turn-over-evidence/` (`events.jsonl` has every payload).
Request bodies were **not** kept there, because they hold system prompts.

### M1. The `Stop` payload carries background work (measured)

A plain turn's `Stop`, in full:

```json
{"session_id": "…", "transcript_path": "…/<session>.jsonl", "cwd": "…",
 "scratchpad_dir": "…", "prompt_id": "2560a3f4-…", "permission_mode": "default",
 "hook_event_name": "Stop", "stop_hook_active": false,
 "last_assistant_message": "PONG", "background_tasks": [], "session_crons": []}
```

With work still running, one item per task:

```json
"background_tasks": [{"id": "bsjdgrhtz", "type": "shell", "status": "running",
                      "description": "bg sleep", "command": "sleep 30; echo bgout"}]
"background_tasks": [{"id": "a63e6659b88af8367", "type": "subagent", "status": "running",
                      "description": "bg agent", "agent_type": "general-purpose"}]
```

`prompt_id` is the same on a turn's `UserPromptSubmit` and its `Stop`.

**Not known:** whether older Claude versions send `background_tasks`. The #55
captures (2.1.272) were not committed. Only `running` was seen as a `status`.

### M2. Background shell outlives the turn (measured, once)

| t (s) | event | roost badge |
|---|---|---|
| 0.000 | `UserPromptSubmit` "BGBASH…" | working |
| 0.749 | `Stop`, `background_tasks: [shell, running]` | **done** |
| 0.755 | `SubagentStop`, `agent_type: ""` (see M4) | done |
| 30.698 | `UserPromptSubmit`, prompt = `<task-notification>…<status>completed</status>…` | working (58 ms) |
| 30.756 | `Stop`, `background_tasks: []` | done |

So the pane read ✅ **done for ~30 s while the job ran.** When the job ended,
Claude started a turn **by itself**, and roost recorded it as a new turn:
`@roost-reply-turn` went to 3 with only two prompts sent. The transcript shows
`queue-operation enqueue`, `dequeue`, then the `<task-notification>` user
record.

### M3. Background agent outlives the turn (measured, once, clean run)

| t (s) | event | roost badge |
|---|---|---|
| 0.000 | `UserPromptSubmit` "BGAGENT go" | working |
| 0.146 | `SubagentStart` (general-purpose) | working |
| 0.273 | `Stop`, `background_tasks: [subagent, running]` | **done** (seen at 0.428) |
| 30.908 | subagent's `PostToolUse` (with `agent_id`) on the main pane | **working** (seen at 30.988) |
| 31.008 | `SubagentStop` for the real agent | working |
| 31.058 | `UserPromptSubmit` `<task-notification>` | working |
| 31.113 | `Stop`, `background_tasks: []` | done |

The pane read ✅ **done for 30.56 s** while the agent worked. It went back to
⏳ only because the subagent's tool call happened to fire `PostToolUse` on the
main pane, and `--tool-hook` ignores `agent_id` only while the pane is
`blocked`. That is an accident, not a design. A subagent that makes no tool
call after the main `Stop` never gets that.

### M4. `SubagentStop` is not a signal that background work ended (measured)

After **every** `Stop`, 5–15 ms later, a `SubagentStop` fires with a fresh
`agent_id` and `agent_type: ""`. Its API request carried
`[SUGGESTION MODE: …]`: it is Claude's prompt-suggestion fork, not the user's
work. It fired after plain turns too. So "a `SubagentStop` arrived" means
nothing by itself. Only `background_tasks` in the final `Stop` says the work
is done.

### M5. Esc while the model streams (measured, once)

No hook of any kind for **170 s** after the Esc: no `Stop`, no `StopFailure`,
no `Notification`. The badge stayed `working`. The transcript tail:

```
assistant  [text "word word word …"]            (the partial answer)
user       [text "[Request interrupted by user]"]
```

There is **no** `system turn_duration` record after it.

For comparison, after a normal `Stop`, an `idle_prompt` Notification arrived
60.1 s later (once). So the #95 comment's idea, "treat `idle_prompt` as turn
over", did **not** hold for an interrupted turn on this version. Not measured
beyond 170 s.

### M6. Esc while a tool runs (measured, once)

A foreground `Bash` (a 30 s sleep, auto-allowed, no dialog). Esc after 4 s.
No hook in the next 20 s: no `PostToolUseFailure`, no `Stop`. Transcript tail:

```
user  [tool_result "The user doesn't want to proceed with this tool use. …"]
user  [text "[Request interrupted by user for tool use]"]
```

Again **no** `turn_duration`. `roost-unblock.sh` requires `turn_duration`
after the marker (its rule 3), so this shape would not match today's reader
even if it were asked.

### M7. Declined dialog still recovers (measured, once)

Esc at a `Write` dialog: `PermissionRequest` 0.235 s after the prompt, the
`permission_prompt` Notification 5.955 s after `PermissionRequest`, then the #38 three records **with**
`turn_duration`. `roost wait-done %3 3` cleared the 🛑 and **exited 0**, with
the badge now unset. That is the "interrupted looks like success" half of #95,
seen live.

### M8. Hook ancestry reaches the pane (measured)

**45 of 45** logged Claude hook calls, across two panes, main-loop and
subagent events alike, had the pane's `#{pane_pid}` in their parent chain. The
hook's parent was `claude`, and `claude`'s parent was the pane's process. Only
Claude was measured today. The #64 spec (§3.1) already measured the parent of
each harness's hook: codex's hook `$PPID` is `codex`, copilot's extension host
is a child of `copilot`, and the opencode and pi plugins run in the agent itself.

### M9. The cost of walking ancestry (measured, this machine)

100 calls each, 1,294 processes running: `ps -A -o pid=,ppid=` **26 ms**;
`ps -o ppid= -p PID` **2.4 ms** per level. Claude's hook is 2 levels below the
pane process, so that is about 5 ms per walk.

### Not measured

- Background work on **codex, opencode, pi, copilot.** codex has
  `SubagentStart`/`SubagentStop` events. Whether any `Stop` there carries
  background state is unknown.
- A human prompt sent **while** background work runs, and where the
  `<task-notification>` turn goes then.
- A background task that never ends (a dev server, the `Monitor` tool), and a
  non-empty `session_crons`.
- `claude -p` with background work.
- tmux 3.4 / 3.5a `pane_pid` (CI's Ubuntu runs 3.4). A container. `opencode
  attach` to a detached `opencode serve`.

---

## 3. The single definition

> **A turn is over when the agent has stopped acting on the prompt, and
> nothing it started for that prompt is still running.**
>
> roost may believe that from exactly three sources:
>
> 1. **The agent's own report**, from inside the pane: Claude's `Stop` with no
>    running `background_tasks`, `StopFailure`, codex `Interrupt`, copilot and
>    opencode `session.idle`.
> 2. **The agent's own record of the turn**, read by roost: Claude's transcript
>    interrupt markers. roost may only **unset** from this source.
> 3. **A kernel or tmux fact that the agent is gone**: pane closed, pane dead,
>    or the #64 job gone.
>
> Anything else is **"could not tell"**. The badge then stays as it is, or is
> unset. It is never set to `done`.

Every ending also carries an **outcome**, because "over" is not "succeeded":

| outcome | from | badge after | the only one that is exit 0 |
|---|---|---|---|
| `finished` | source 1 (`Stop`, no running work) | ✅ done | **yes** |
| `error` | source 1 (`StopFailure`, codex #39 inference) | 💥 error | no |
| `interrupted` | source 1 (codex `Interrupt`, copilot `aborted`) or 2 (Claude transcript) | unset / 💤 idle | no |
| `died` | source 3 | unset | no |

**How the four cases fit:**

- **Normal end:** source 1, `finished`.
- **Interrupted:** source 1 where the harness says so, or source 2 for
  Claude, `interrupted`.
- **Background work outlives the main turn:** **not over while that work
  lives in this pane** (the ownership rule, §3.1). The `Stop` with running
  work is a report of "main reply ready", not "turn over". The turn ends at the
  later `Stop` whose list is empty (M2, M3). Work handed to another pane never
  holds this one.
- **Agent gone:** source 3, `died`.

**Can one definition cover all four? Yes, as a definition. Not as one
signal.** That is the real finding. The evidence differs by case, and so
does who reads it: the agent pushes source 1, and roost pulls sources 2 and 3
when someone asks. That is why the outcome has to be **recorded in one place**
(§6). If each command works it out in its own way, we get three inconsistent
answers again.

**A second real finding: coordinators ask two different questions**, and
today roost merges them at `Stop`:

- "Is the answer ready?" This is true at the first `Stop` (M2, M3).
- "Has the agent stopped touching things?" This is only true at the last `Stop`.

The definition answers the second one. That is the safe direction: a false
"still working" costs time, and a false "done" makes you stop looking. The
first question stays answerable, but only as a **separate, named fact**
("main reply ready, N tasks running"), never as `done`.

### 3.1 The ownership rule (decided by the human, 2026-09-27)

> **Background work holds this pane at `working` only while it lives in this
> pane. Work handed to another pane is that pane's to report. No pane waits on
> another pane's work.**

#### Can it be built from what was measured?

**The payload cannot say where the work lives.** A `background_tasks` item
carries `id`, `type`, `status`, `description`, and `command` or `agent_type`
(M1). It has **no pid, no pane and no terminal.** Nothing in it tells "in this
pane" from "in another pane".

**For the cases measured, it does not need to.** Everything the list held was
work Claude runs itself:

- `type: "subagent"` runs inside the `claude` process. M8 found every subagent
  hook in the pane's process tree. That is this pane.
- `type: "shell"` is a command Claude started with `run_in_background`.
  **Not measured:** its parent process. It is expected to be a child of
  `claude`, and so in this pane, but that is not checked (**A1** below).

Work handed to another pane never reaches the list. `roost spawn`, `roost
split` and `roost send` are ordinary tool calls that return at once. The new
pane is a child of the tmux server, not of this pane. So the other pane's work
never appears here. That follows from how tmux starts panes; the list was not
logged for a spawn (**A3**).

**So, as stated, the rule ships for Claude as "hold while the list has a
running `shell` or `subagent` item".** That is the same code as the step-1
design. The rule changes what it *means*, and it adds one restriction: an item
of a type **not** known to live in the pane must not be assumed to live in it.

**Two gaps could break that, and neither is measured:**

- **A1. Is a background shell really in the pane's process tree?** One run of
  this rig with the logger's `ps` walk on the task's pid settles it. If it is
  reparented (for example to pid 1), the list and the rule disagree, and step 1
  needs a pid test instead of the list.
- **A2. Claude's agent teams.** The binary has `TeammateIdle`, `TaskCreated`
  and `TaskCompleted` events. Teammates can run in **other tmux panes**. If a
  teammate appears in `background_tasks` with a type that does not say "other
  pane", the payload **cannot** apply the rule. That is exactly the case the
  human named. Until it is measured, an unknown `type` holds `working`. That
  is the safe direction, and it can break the rule for teams: this pane would
  wait on another pane's work. Recorded in known-gaps, not guessed away.
- **A3.** Nobody has logged the list after a `roost spawn` or `roost split`.
  One run confirms it stays empty.

#### Is it the same idea as #105?

**Yes, it is one principle: a pane answers only for its own process tree.**
#105 applies it to **who may write** the badge. The ownership rule applies it
to **what may hold** the badge.

**One test, two sources of evidence.** The test is "is process P inside pane
X's tree?" (§4.2). #105 can run it today, because the reporter's pid is its
own. #97 cannot run it on Claude's list, because the list has no pids. So:

- Build **one function**, `pid in pane` (bounded ancestry walk, §4.2, M9), in
  step 4.
- Step 1 uses Claude's list as its evidence, and states that it relies on A1
  and A2.
- If A1 fails, or a future list carries pids, step 1 switches to the same
  function. Then one mechanism serves both, and step 4 moves before step 1.

#### What happens to `wait-done --main`?

It was offered as part of Q1 option A. It was the way out for a pane whose
never-ending server would keep it ⏳ for ever.

**Under the ownership rule it no longer earns a place in this design.** A
never-ending server belongs in its own pane. A server kept in this pane holds
this pane `working`, and the rule says that is the truth. The other thing
`--main` gave, "the answer is ready while work continues", stays visible with
no new flag: `read --json` `final: false` and `background: N`, and
`status --json` `background`. If a coordinator needs to *wait* for that
moment, #43 ("wait for a named state") is the place for it. **Dropped: the
human's decision Q9, 2026-09-28.**

#### What the rule costs

- **A dev server in its own pane has no badge.** Badges come from agent hooks.
  A plain `npm run dev` pane renders like a shell, and `wait-done` on it
  returns 0 at once. "That pane has its own badge" is true for an **agent**
  pane only. For a server, the truth lives on its screen (`roost screen`), as
  the human said: the agent checks it when it needs to. The rule is still
  right, but the server's state is not reported anywhere by roost.
- **Work that leaves the tree belongs to no pane.** `nohup cmd &`, `setsid`,
  or `cmd & disown` from a foreground `Bash` call: the tool call returns, the
  process is reparented, it is not in the list, and it is not in any pane.
  This pane reads ✅ while that process may still change files. roost cannot
  see it, and this design does not try to. It is a hole, recorded as one.

#### Cases the rule leaves unclear

1. **This pane waits, by choice, on another pane.** A background shell that
   runs `roost wait-done %9` lives in **this** pane, so it holds this pane
   `working` until %9 ends. The rule allows it, because the process is here.
   But it is a pane waiting on another pane's work, which the rule's last
   sentence forbids. **Settled by the human, Q8, 2026-09-28: it lives here,
   so it holds `working`.** It is also the only answer that can be built,
   because the list cannot tell this shell apart from any other.
2. **Work started here that is reparented elsewhere** (above): it belongs to
   no pane.
3. **A pane that spawns another pane and then exits.** The new pane is a child
   of the tmux server and keeps running. The first pane's badge follows its
   own agent (`finished`, or `died` from #64). Nothing holds either pane on
   the other. No gap, provided the new pane runs an agent. If it runs a plain
   command, see "no badge" above.
4. **`session_crons`** (a wake-up scheduled in this pane). It is owned here but
   not running now. It does not hold `working`. The pane reads ✅ and later
   starts a turn by itself, like the `<task-notification>` turn in M2. Not
   measured.
5. **Agent-team teammates (A2)** and **remote or cloud tasks**, if Claude ever
   lists them: owned elsewhere, and the list may not say so.
6. **A pane moved** (`move-pane`, `break-pane`) keeps its process and its tree,
   so nothing changes. **`respawn-pane -k`** ends the old tree, so the old
   work is gone with it.


---

## 4. Who may report state (#105)

### 4.1 The rule: two channels, with different powers

`@agent_state` has exactly two writers today (`grep` of `bin`, `scripts`,
`adapters`, `tmux`): the sink `scripts/roost-agent-state` (by `$TMUX_PANE`)
and the #38 recovery `scripts/lib/roost-unblock.sh` (cross-pane, unset only).
The design keeps that split and makes it the rule:

| channel | who | may write | test it must pass |
|---|---|---|---|
| **report** | a process in the pane: a hook, an adapter, `roost state` typed in the pane | any state | the reporter is **inside the pane's process tree** |
| **recovery** | roost itself (`send`/`read`/`wait-done`/`status`), or a human with #96 | **unset only**, plus an outcome record | evidence from source 2 or 3, tied to `@agent_since` |

A recovery can never set `done`, `working` or `blocked`. That rule is what lets
roost act on another pane without guessing.

### 4.2 Ancestry, assessed

**What it fixes:** a process **outside** the pane's tree that carries the
pane's `$TMUX_PANE`. Examples: a GUI app launched from the pane that detached
itself, a shell that copied the variable, a daemon.

**What it does not fix:**

- **#77, nested agents.** A `codex exec` or `claude -p` started by the pane's
  agent is a descendant, so it passes. #77 still needs its env switch.
- **#102, silence.** Nothing is reported, so there is nothing to refuse.

**What it breaks, or changes:**

| case | today | with an ancestry check | verdict |
|---|---|---|---|
| Claude, codex, copilot, pi, opencode in the pane | badges | passes (M8; #64 §3.1) | fine |
| `roost state` typed in the pane | badges | passes: it is a child of the pane's shell | fine |
| roost's own recovery (`roost-unblock.sh`) and #96's hand clear | cross-pane unset | not a report, so it is not checked | fine, **but only if the check lives in the sink and not in a shared tmux wrapper** |
| **hook that runs detached** (`setsid` + double fork, `nohup … &` and the parent exits) | badges | reparented to pid 1, so **refused** | No in-tree adapter does this: all use an awaited `execFile`, and `roost-notify` never writes state. A third-party extension might |
| **agent reparented after its shell exits** | the pane closes, or is dead with `remain-on-exit` | reports refused | Correct. #54 already calls it `died` |
| **`respawn-pane -k`** | pane options survive, `pane_pid` changes | the old agent's late reports are refused | Correct. This is the #64 record rule |
| **`pane_pid` is not the shell** (`roost spawn NAME CMD` through `sh -c`, the #58 `roost-pane-shell`, which `exec`s) | badges | passes: tmux forks the pane's first process, and the agent is below it, `exec` or not. Measured on 3.6 with a non-`exec` `zsh -c` (M8) | fine on 3.6. **3.4 and 3.5a not measured** |
| **container in the pane** (#64 §3.4: the host `pane_pid` is not visible inside) | badges | could not be checked, so **accepted and marked unverified** (Q4, decided) | no regression, and no protection there either. §9 |
| **`opencode attach`** to a detached `opencode serve` | the plugin runs in the server and stamps the pane the server started in, which is the wrong pane | refused | an improvement. Not measured |
| **cost** | — | ~5 ms per walk for Claude (M9). Deeper for codex | only after the unchanged-state bail, so the `PostToolUse` hot path pays nothing. An unchanged write from a stranger changes nothing anyway |

### 4.3 What happens to a refused report

**A refusal is not neutral.** It depends on what the pane reads now:

- The pane reads **busy** (`working`/`blocked`). A refused `done` keeps it
  busy. That is the safe direction. Keep the badge.
- The pane reads **`done`/`idle`**. A refused `working` or `blocked` would
  leave an old ✅ standing while *something* claims work is happening. That
  is the dangerous direction. **Unset the badge** ("could not tell").

In both cases, record `@roost-refused` = `"<epoch> <state> <pid>"` and say it
in `state --json` (`"recorded": false`, new field `"refused": "not in this
pane's process tree"`). `roost doctor` names panes with a refusal. A stranger
can therefore **unset** a `done` badge, but never set one. That is a
"look again" cost, which the rules allow.

### 4.4 "The pane whose agent died"

This is #105's second half. It is mostly built already: #64's `job_gone` in
`bin/roost`. The design moves that check from inside `wait-done` into one
function that `read` and `send` also call, as `roost_unblock_pane` is shared
today. **`status` does not call it** (Q6, decided: a read command stays a read
command). On a `died` result, that function **unsets** the badge and
records outcome `died` (recovery channel). `wait-done` keeps exit **2**. The two
known misses (`caffeinate` for up to ~300 s, a long-lived wrapper) stay as
they are. They are timeouts, never a false `died`.

A process walk from `status` is **not** added. It stays on the #64 facts, as
the `wait-done` comment requires ("never a process-tree walk … both guess").
The ancestry walk is used only to **admit a report**, never to declare a death.

---

## 5. What a caller sees

### 5.1 What must NOT change

- **Exit 0** from `wait-done` still means "finished". Existing scripts test for 0.
- **`send`'s exit codes 0–4**, including #92's **4** ("submitted, no turn
  began"), keep their meanings exactly.
- **`wait-done` 1** (error, timeout, usage, `--turn` refusals) and **2** (died,
  gone) keep their meanings.
- **stdout without `--json`**, byte for byte. New facts go to **stderr notices**
  and **new JSON fields**. New fields and new enum values do not bump
  `schema` (driving-a-fleet.md, "What counts as a change to `schema`").
- The five state words, and the names `@agent_state` / `@agent_since`. **No
  new badge state.**

### 5.2 What changes, and why each is the safe direction

| situation | today | proposed |
|---|---|---|
| Claude turn ends with background work running **in this pane** | ✅ done, `wait-done` → **0** | stays ⏳ **working** until the final `Stop`. `wait-done` keeps waiting. A short timeout now gives **1** instead of a false 0 |
| Claude turn ends after handing work to **another pane** (`roost spawn`/`split`/`send`) | ✅ done | ✅ done — unchanged. The other pane answers for that work |
| interrupted turn (any harness) | `wait-done` → **0** | `wait-done` → **5** (`interrupted`), stderr `roost: '<tgt>' was interrupted, not done` |
| Claude Esc mid-stream / mid-tool | ⏳ working until timeout | recovered from the transcript on the next `send`/`read`/`wait-done` (never `status`, Q6): unset, outcome `interrupted`, `wait-done` → 5 |
| copilot `session.idle {aborted: true}` | ✅ done | 💤 idle plus outcome `interrupted` |
| dead agent seen by `send`/`read` | the badge keeps reading `working` | unset, outcome `died` (`wait-done` is already 2). `status` shows what is stored and changes nothing (Q6) |

**Why a new exit code, and why 5.** An interrupted turn exiting 0 is the same
kind of bug #54 fixed when a gone pane exited 0: success reported for something
that did not succeed. Moving it to non-zero only stops callers that were
wrongly continuing. **1** is already overloaded (error, timeout, usage), and a
"retry on timeout" loop would retry an interrupted turn. **3 and 4** belong to
`send`, and #43 plans to fuse `send` and `wait-done` into one command, so their
tables must not overlap. **5** is free in both.

### 5.3 New JSON fields (additive, `schema` stays 1)

- **`wait-done --json`** (reserved in `2026-09-15-json-output-design.md`):
  `outcome` gains `interrupted`. The reserved values `done | error | timeout |
  died | gone` stay. Per pane: `state`, `error_reason`, and the new
  `background` (integer, or `null` when unknown).
- **`status --json`**, per pane: `outcome` (the last ended turn's outcome, or
  `null`), `background` (count of running tasks, or `null` when roost cannot
  see it — Q5, §9), `verified` (`false` when the last report could not be
  checked — Q4, §9; `null` before any report), `refused` (the
  last refused report's epoch, or `null`).
- **`read --json`**: `final` (bool; `false` for a main reply while
  background work runs) and `background`. Today's `stale` keeps its meaning,
  "from an earlier turn". A main reply of *this* turn is `stale: false,
  final: false`, and plain `read` prints one stderr line saying so.
- **`send --json`**: unchanged. Note that a pane held `working` by background
  work goes down `send`'s "already mid-turn" path, so it gets `started: false,
  turn: null`. That is honest, but a coordinator loses the turn number there.

### 5.4 Turn numbers: a hole this design must close

`send` predicts the turn as "last recorded + 1" (`bin/roost`, the `turn_num`
branch). Two measured behaviours break that prediction:

1. **Claude records turns nobody sent.** The `<task-notification>` turn (M2)
   recorded turn 3 after two prompts. A `send` in flight could be told "turn 3"
   and then read the notification's reply.
2. **An interrupted Claude turn records nothing** (M5, M6), so the *next*
   prompt's reply becomes turn N. Then `wait-done --turn N` returns on the
   wrong prompt. The mechanism is read from the code. Only its parts were
   measured.

The fix belongs with #95 and #97, not later:

- On an `interrupted` outcome, write an **empty turn record** with outcome
  `interrupted`, so numbering stays aligned. Then `wait-done --turn N` exits 5.
- A `<task-notification>` turn is folded into the turn whose background work
  it reports (Q3, decided 2026-09-28). Its reply becomes that turn's final
  reply, and no new turn number is used. Claude's `prompt_id` and the
  `<task-notification>` prompt make this checkable for Claude. Other
  harnesses: not measured, and not built (Q7).

---

## 6. Where the answer lives

One record per pane, written in the **same tmux command** as the badge, as the
repo already does for `@roost-reply` and the #91 `if-shell`:

- `@roost-ended` = `"<@agent_since> <outcome>"`. It is ignored unless its
  first word equals `@agent_since`, the `@roost-transcript` rule. So a record
  from an old turn can never describe a newer one.
- `@roost-background` = `"<@agent_since> <count>"`, set by a `Stop` with
  running work and cleared by the final one.
- `@roost-transcript` is recorded at **`UserPromptSubmit`** too, not only at
  dialogs, so the interrupt reader has a transcript for a `working` pane.
  `UserPromptSubmit` runs once per turn, not on the hot path.

The interrupt reader extends `roost-unblock.sh` with the two new tails (M5, M6)
under its existing fail-closed rules. It matches only when the marker is the
**newest** conversation record and is **no older than `@agent_since`**. It
unsets and records `interrupted`. An unknown record type stays "could not
tell". A new prompt after the Esc stamps `working` newer than the marker, so
nothing clears.

---

## 7. Build order, and what each step is worth alone

**#105 does not have to land before #95 or #97.** Both read evidence from
Claude's own payload or file, and the #95 recovery only unsets. A foreign
report can at worst stamp `working` after an interrupt, which blocks the
recovery. That fails toward "still working", the safe direction.

0. **Docs only.** Record M1–M9 in `docs/known-gaps.md`. Correct the #95
   comment (`idle_prompt` did not come after an interrupt, M5). Correct #105's
   claim about #77 and #102. *Worth:* stops the next design from starting on
   a wrong premise. Also record the two accepted exceptions (§9) and state
   that background handling is Claude-only (Q7). Cost: an hour.
1. **#97: hold `working` while `background_tasks` has a running item of a
   type that lives in this pane** (Claude; §3.1). **First, two measurements**
   that decide whether the list really is "this pane": the ancestry of a
   background shell (A1), and whether agent-team teammates appear in the list
   (A2). Record the main reply as `final: false`. `done` comes at the
   empty-list `Stop`. A `Stop` without the field behaves as today (§8 Q5).
   Add a live smoke test beside `claude-stop-failure-smoke.sh`, reusing this
   rig. The skill gains one line: a long-lived server goes in its own pane
   (`roost split`/`spawn`), not in `run_in_background`. *Worth:* removes a
   **measured 30 s false ✅** per background task. It is the most dangerous of
   the three bugs, because it is a false `done`. Size: M (it was S–M; the two
   measurements are the difference).
2. **#95: the `interrupted` outcome.** The transcript reader for a `working`
   pane (M5, M6 shapes), `@roost-ended`, `wait-done` exit 5, the empty turn
   record, copilot `aborted` → `interrupted`, codex `Interrupt` → `interrupted`.
   *Worth:* no more "working for ever" after an Esc, and no more "success" for
   a stopped turn. Size: M.
3. **`wait-done --json`**, now that `outcome` has every value. *Worth:*
   coordinators stop parsing stderr. Size: S.
4. **#105 part 1: the report filter** in the sink, with the §4.3 refusal rule.
   A reporter that cannot be checked is accepted and marked unverified (Q4).
   *Worth:* ends stray stamps from outside the pane. Size: M.
5. **#105 part 2: share `job_gone`** with `read` and `send` (not `status`, Q6).
   *Worth:* the badge stops lying after a death, not only `wait-done`. Size: S.

#77 (env switch), #78 (find the pane by ancestry) and #102 (age hint) stay
separate. They can reuse step 4's walk function.

**What the ownership rule changed in this order:** step 1 gains the two
measurements and the skill line, and no longer carries `wait-done --main`.
The order itself does not change. Step 1 still does not need step 4: the
Claude list is the evidence for step 1, and the pid test is the evidence for
step 4 (§3.1, "Is it the same idea as #105?"). If A1 fails, step 1 needs
step 4's function and must move after it.

---

## 8. Decisions

**Every question is now decided by the human.** Nothing below is a
recommendation. Where a decision differs from what I proposed, it says so.

**Made by the human on 2026-09-27:**

- **Q1 — the ownership rule.** Background work holds the badge at `working`
  only while it lives in **this** pane. Work the agent handed to **another**
  pane does not hold it. That pane has its own badge. No pane waits on another
  pane's work. The human's words: *"A makes sense as long as it remains in the
  same shell of the agent, but if the agent spawns a dev server into another
  pane, that agent should claim done if the turn is over because the process
  is owned elsewhere."* It replaced both options I offered (A: hold for every
  task, plus `wait-done --main`; B: hold for subagents only). §3.1 works it
  through.
- **Q2 — exit 5.** `wait-done` exits 5 for an interrupted turn.

**Made by the human on 2026-09-28:**

- **Q3 — fold.** The `<task-notification>` turn folds into the prompt whose
  background work it reports. "Turn N = the Nth prompt you sent" stays true.
- **Q4 — accept and mark.** A reporter whose ancestry cannot be checked is
  accepted and marked unverified, not refused. Refusing would turn "could not
  check" into a silent badge loss, which is worse than today. **An exception
  to the rule — see §9.**
- **Q5 — confirmed.** A `Stop` with no `background_tasks` field keeps today's
  `done`. Breaking every older Claude install to be strictly correct is the
  wrong trade. It goes into `docs/known-gaps.md` as an accepted exception.
  **An exception to the rule — see §9.**
- **Q6 — no.** `status` does not write. Unsetting stays with `send`, `read`
  and `wait-done`, which already do it.
- **Q7 — Claude only.** The other four harnesses are not measured. Do not
  guess about them, and say so in the docs.
- **Q8 — it lives here, so it holds `working`.** A background shell in this
  pane that waits on another pane holds this pane. It is also the only answer
  that can be built from Claude's list.
- **Q9 — drop `wait-done --main`.** Not needed under the ownership rule.

**Made by the human on 2026-09-29:**

- **Q5 limits — accepted.** Part of the Q5 decision:
  1. The exception applies **only when the `background_tasks` key is
     absent.** A key that is present but malformed counts as "could not tell",
     so the pane stays `working`.
  2. The JSON reports `background: null`, never `0`, so a caller can tell
     "none running" from "could not see".
- **Q4 limits — accepted.** Part of the Q4 decision:
  1. A report whose ancestry walk **runs** and reaches pid 1 without passing
     this pane is **refused**. "Unverified" means only that the walk could not
     run (the pane's `pane_pid` is not visible, or `ps` fails).
  2. Unverified reports are **visible**: `verified: false` in `status --json`
     and `state --json`, and `roost doctor` names the pane.
- **The rule, reworded — adopted.** *"Could not tell is never reported as
  done, EXCEPT where the only other choice removes something that works today,
  and every such place is listed in `docs/known-gaps.md`."* The precedent is
  already live: the codex adapter with no JSON reader badges ✅ (known-gaps, "A
  codex pane's 💥 error is inferred…"). Q4 and Q5 are the second and third
  entries on that list. §9 describes each.

**Still not measured, and not decisions:** A1, A2, A3 in §3.1 (the ancestry
of a background shell, agent-team teammates, the list after a spawn). Step 1
starts with them.

---

## 9. Where "could not tell" is let through: two accepted exceptions

The repo's rule is that **"could not tell" must never be reported as
"done"**. Two decisions bend it, on purpose, for compatibility. **The rule is
not absolute after this design.** Anyone who reads it as absolute will be
surprised in exactly these two places.

### 9.1 Q5: an older Claude reads ✅ while its background work runs

**Where:** the Claude `Stop` hook, when the payload has **no**
`background_tasks` key.

**What it costs:** on such a Claude, the measured false ✅ of M2 and M3 stays:
about 30 s per background task in those runs, and as long as the task runs in
general. `wait-done` returns 0, and a coordinator moves on while files may
still change. It is **no worse than today**. It is the whole of today's #97 bug,
kept on those installs.

**Two more inputs reach the same branch, and the decision should be read as
covering them, or not, explicitly:**

- **No JSON reader** (no `python3` and no `jq`, or the macOS `python3` stub).
  The payload cannot be read at all, so the key cannot be seen. That is
  today's `done`, the same as the codex precedent in known-gaps ("A machine
  where no JSON reader works gets the old behaviour").
- **A future Claude that renames or drops the key.** It would look exactly
  like an old one, and the false ✅ would come back **silently**. Only a live
  smoke test after each upgrade catches it. That is the same guard, and the
  same weakness, as `claude-stop-failure-smoke.sh`.

**How to keep it narrow**, as design within the decision:

- The exception is for the key being **absent** only. A key that is present
  but malformed (not a list, or items with no `status`) is a new shape, not an
  old Claude. It is "could not tell", so the pane is **held** `working`.
- The badge says ✅, but the JSON does not claim more than roost knows:
  `background: null` (unknown), never `0`, in `status --json` and
  `read --json`. A coordinator that checks the field can tell "no background
  work" from "could not see".

### 9.2 Q4: an unverified report stands

**Where:** the report filter (step 4), when the reporter's ancestry cannot be
walked to a verdict. That is when the pane's `pane_pid` is not visible from
the reporter (a container's pid namespace), or when `ps` fails.

**What it costs:** in those cases the filter protects nothing. A stray process
there can stamp any state, `done` included, as today. It is **no worse than
today**: today no report is checked at all. The real risk is **false
confidence**: once step 4 ships, readers will assume every badge was checked.

**How to keep it narrow:**

- "Cannot check" means **the walk could not run**. A walk that runs and ends
  at pid 1 without meeting the pane is a verdict (refuse), not an
  "unverified". Otherwise any detached process gets in as "unverified".
- Unverified is **visible**: `@roost-verified` is recorded beside the badge
  and tied to `@agent_since`, and `status --json` and `state --json` carry
  `verified: false`. `roost doctor` names panes whose last report was
  unverified.

### 9.3 The assessment behind the decisions (written before 2026-09-29)

The limits in §9.1 and §9.2, and the reworded rule below, were accepted by the
human on 2026-09-29 and are recorded in §8. This section keeps the reasoning.

**Neither decision is wrong.** Both are reasonable trades, for the same
reason: in each case the other choice is *worse than today*, and the
exception is *exactly today*. The rule is bent only where holding it would
remove something that works now.

They are **not equal**, though:

- **Q5 has a real, measured cost.** It keeps a false ✅, the dangerous
  direction, on older Claudes, and it can come back silently on a newer one.
  I accept it, but only with the two limits in §9.1: absent key only, and
  `background: null` in the JSON. **Without those two limits, I would call it
  wrong**, because a malformed payload would then read ✅ as well, and a
  coordinator would have no way to tell.
- **Q4 costs almost nothing.** It is today's behaviour in a corner that is
  small (containers, a failing `ps`). Its only real danger is the false
  confidence above. The `verified: false` mark answers that, and so does the
  rule that "walk ended at pid 1" is a refusal, not an "unverified".

The repo already bends the rule once, in the same shape: the codex adapter
with no JSON reader badges ✅ (known-gaps). With these two beside it, the rule's
real wording becomes the one the human adopted (§8): **"could not tell is never reported
as done, except where the only alternative removes behaviour that works
today; each such place is listed in known-gaps."**

---

## 10. What I expect to go wrong in step 1 (the designer's read, not a decision)

Written after the design closed, for whoever builds it. These are predictions
from the code and the measurements, most likely first.

1. **The unchanged-state bail will eat the new record.** A `Stop` with work
   still running writes `working` onto a pane that already reads `working`.
   `scripts/roost-agent-state` bails on an unchanged state **before** most
   writes. It already lost `@roost-error-reason` this way (known-gaps, "A
   second failure … keeps the first reason"). `@roost-background` must be
   written above the bail, or in the same tmux command as the badge, or the
   hold will "work" in tests that start from ✅ and fail on a live pane.
2. **Folding (Q3) is the hard part, and I would build it differently from how
   §5.4 reads.** Rewriting turn N's file when the notification turn ends goes
   against `scripts/lib/roost-record.sh`, which only appends, and its `.pane`
   sidecar check. That check trusts a turn file edited in place (known-gaps,
   #42). **Build it as a deferral instead.** At the `Stop` that still has work
   running, set `@roost-reply` (the main reply, `final: false`) and write
   **nothing** to disk. At the `Stop` that releases the pane, append **one**
   turn file. Then records stay append-only, "turn N = the Nth prompt" holds
   with no renumbering, and `wait-done --turn N` waits for the release with no
   new code. The cost: the main reply is not kept on disk once the final reply
   replaces it.
3. **The release depends on an event roost does not control.** The pane is
   held until Claude starts a `<task-notification>` turn by itself. That
   happened in M2 and M3. **Not measured:** a task killed with `TaskStop` or
   from the task panel, Claude exiting with work running, and a human typing
   in the prompt when the work ends. If any of these fires no final `Stop`,
   the pane reads ⏳ for ever. That is the safe direction, but it is the #95
   shape again. Measure these beside A1–A3 before building.
4. **Detecting the notification turn by its prompt text may misfire.** In one
   request body the fake API received, a `<task-notification>` block sat in
   the **same** user message as a human's prompt. If a human prompt and a
   notification arrive together, `UserPromptSubmit` may carry the human's
   text, and a check for the `<task-notification>` prefix misses it. It also
   means the sink must read the `UserPromptSubmit` payload, which it does not
   do today (a new flag). Not measured.
5. **`read` will call the main reply stale.** Plain `read` and `read --json`
   treat any reply on a `working` pane as "from its previous turn". A held pane
   needs `@roost-background` checked there too, or the stderr notice and
   `stale: true` will be wrong on exactly the pane this step is for.
6. **`Monitor` will surprise people.** It is a tool this harness uses often.
   If it appears in `background_tasks` (not measured), the ownership rule
   correctly holds the pane for as long as the monitor runs. That is right,
   but coordinators with short timeouts will see many more exit 1s. Say it in
   the skill before users find it.
7. **Unknown `type` values will appear.** Only `shell` and `subagent` were
   seen. Any other value holds `working` (§3.1). Log each unknown type
   somewhere a human sees it, such as `roost doctor`, or the first team or
   monitor user will report a stuck pane and nobody will know why.

Nothing here changes a decision. Items 2 and 4 change **how** Q3 is built,
not what it does.
