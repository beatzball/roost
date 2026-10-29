# Known gaps and follow-ups

Risks carried by what has shipped, and why each was left rather than fixed.
Not a wish list — the spec's "Out of scope" sections cover future work. This
file covers things that are already live and could surprise you.

The section headings carry the severity, so read them first. **Behaviour
changes** are things to know about, not defects. **Live risks** are the ones
that can actually bite. Each entry says plainly which it is — an entry that
reads like an alarm when it is merely a note is a bug in this file.

Keep it short. When an entry is fixed, delete it.

## Live risks

### `roost save` and `roost restore` (placement only): what the shape rests on (#51, #191)

Live risk, small. Part 1 of persistent sessions ships `save` and a `restore`
that places panes and resumes nothing. Each rule below rests on a probe in
`docs/airig/probes/persist-1-*.md` (tmux 3.2a, 3.4 and 3.6, once each); a tmux
that changes one of these breaks the rule quietly.

- **A zoomed window** is saved with `#{window_layout}` as read — the unzoomed
  layout on all three builds — and `zoomed 1`. Nothing is ever unzoomed to
  save it. `#{window_visible_layout}` is the one-pane view and is not used.
- **A session group** (`new-session -t`) is saved as its first member (lowest
  session id) in full and each other member as a block with a `group` line,
  keyed on `#{session_group}`. `#{window_linked}` is NOT a signal for a group:
  it reads 0 for a group's windows on 3.2a and 3.4 and 1 on 3.6. A window
  linked by `link-window` outside a group still comes back as two windows.
- **Odd values, the writer's rule for each.** tmux 3.4 prints every `$` in a
  value as `\$` and every control byte in an option or path as `\NNN`; the
  writer learns both once per save by setting and reading back one pane
  option, then undoes the first and treats the second as a control byte (so
  a name holding the four characters `\033` is dropped on 3.4 — the safe
  side). A newline in a value cuts tmux's line listing; a cut line is read
  again pane by pane. A name holding a control byte is not saved (one stderr
  line); a directory holding one is saved as `$HOME` (one stderr line). A
  session or window name with a control byte is stored by tmux itself as
  escape text up to tmux 3.6; from 3.7 tmux refuses such a window name
  (`invalid window name`), so none can be saved.
- **Names tmux rewrites.** tmux stores a backslash in a session or window
  name as `\\`, and a `$` in one as `\$` on 3.2a and 3.4. Restore undoes that
  for a session name before `new-session -s`, and passes a window name to
  `new-window -n` as saved (which stores it as given up to tmux 3.6); from
  3.7 tmux escapes a window name too, and restore reads each named window
  back and renames it with the escaping undone when it differs. All measured
  to come back the same over two save-and-restore cycles (3.8 included). Up to tmux 3.7 a dotted
  session name cannot exist (tmux stores `.` and `:` as `_`), and restore
  matches a saved dotted name to the `_` one and never makes it twice; from
  3.7a tmux keeps both, so there `v3.69-x` and `v3_69-x` are two sessions,
  and restore asks the server's version which rule holds (a test session
  would run a person's hooks).
- **Exact targets.** `=NAME:INDEX` falls back to a window NAMED like the
  index when that index does not exist, on all three builds, and `display -p`
  on a missing target exits 0 with empty output. Restore therefore targets
  everything after `new-session` by the id tmux printed.
- **A headless Claude in a pane's shell** (`claude -p` run by the pane's own
  agent) fired the pane's SessionStart hook and took over its key (Claude
  Code 2.1.312). The hook now skips the identity when
  `CLAUDE_CODE_ENTRYPOINT=sdk-cli` or `CLAUDE_CODE_SESSION_ATTENDED=0`, the
  child's measured values (R4). A Claude that stops setting them reopens it.
- **Presence alone for pi and opencode.** A pane's key is saved as live only
  when its command agrees with its harness. pi reads `node` (not
  distinctive) and opencode was not measured (its 2.x service could not be
  stopped on the dev machine), so for those two a key is trusted on presence
  alone: an exited pi under a Node dev server would be saved as live.
- **The owner rule needs `ps`.** A restore records its pid and start time
  (`ps -o lstart=`) in `restoring/owner`; with no `ps` every recorded owner
  reads as gone, so two restores could run at once. Every machine roost runs
  on has it; a minimal container image needs `procps`.
- **History has no ring yet.** Every changed save adds a file to `history/`
  until Part 4 adds `ROOST_SHAPE_KEEP`; nothing saves automatically yet, so it
  grows only with each `roost save`.

### When a Claude turn is over: steps 1 to 5 built, with the holes they leave (#95, #97, #105, #110)

**Steps 1 to 3 of the design are built** (`docs/airig/specs/2026-09-29-turn-
over-design.md`, 2026-10-24): a Claude pane is held ⏳ working while its own
background work runs and released by Claude's own final `Stop`; an
interrupted turn is `interrupted`, `wait-done` exits 5 for it, and a Claude
Esc is recovered from the transcript; `wait-done --json` exists. **Steps 4 and 5 (#105, who may report a pane's
state) are built too** (2026-10-25): see "The report filter (#105)" and "`wait-done`
sees an agent that died inside a shell", below. #95, #97 and #105 are
one question: when is a turn over, and who may say so? The measurements below
are the ones the design was made from (2.1.283) and the ones step 1 was
checked against (2.1.310); the list of what is still live follows them.

**How it was measured** (Claude Code 2.1.283, tmux 3.6, macOS, 2026-09-26): one
throwaway `-S` server whose socket path ended in `/roost`, so roost's own hooks
acted on it; a local stand-in for the Messages API that scripted each reply (a
plain answer, a background `Bash`, an `Agent` call, a slow stream); one logger
on 31 of Claude's 33 hook events (all but `WorktreeCreate` and
`WorktreeRemove`, which act on the answer) beside this checkout's
`roost hooks claude`; `--setting-sources local`, `--model haiku`. The logger
kept every payload and each hook's process ancestry. Raw logs were kept with
the design work, not committed. `~/.claude/settings.json` was hashed before
and after, and did not change. **"Once" below means one run**: it shows the
shape can happen, not that it always does.

- **M1. `Stop` lists the background work still running.** Every `Stop` carried
  `background_tasks` and `session_crons`, both `[]` on a plain turn. With work
  still running, one item per task: `{"id", "type": "shell", "status":
  "running", "description", "command"}` or `{"id", "type": "subagent",
  "status": "running", "description", "agent_type"}`. No pid, pane or terminal.
  `prompt_id` is the same on a turn's `UserPromptSubmit` and its `Stop`. Only
  `running` was seen as a `status`. **Not known:** which older Claude versions
  send the key. The #55 captures on 2.1.272 were not committed.
- **M2. A background shell: the pane read ✅ done for about 30 s while it ran**
  (once). `Stop` at 0.749 s with `[shell, running]` badged done. When the job
  ended, Claude **started a turn by itself**: at 30.698 s a `UserPromptSubmit`
  whose prompt is a `<task-notification>` record, which badged `working` 58 ms
  later, then a `Stop` with `[]` at 30.756 s. roost counted that as a turn of
  its own: `@roost-reply-turn` reached 3 with two prompts sent.
- **M3. A background agent: ✅ done for 30.56 s** (once, a clean run; an
  earlier attempt on another pane was not clean and is not counted). `Stop` at
  0.273 s with `[subagent, running]` badged done. The pane went back to ⏳ at
  30.908 s only because the subagent's own `PostToolUse` fired on the main pane
  (the shape in "A SUBAGENT's tool result…", below), and `--tool-hook` ignores
  `agent_id` only while the pane is `blocked`. That is an accident, not a
  design. Reasoned, not measured: a subagent that makes no tool call after the
  main `Stop` would not do it.
- **M4. `SubagentStop` is not a sign that background work ended.** After
  every `Stop` logged, 5–15 ms later, a `SubagentStop` fired with a fresh
  `agent_id` and `agent_type: ""`, after plain turns too. Its API request
  carried `[SUGGESTION MODE: …]`: it is Claude's prompt-suggestion fork, not
  the user's work. In the M3 run one more `SubagentStop` with `agent_type: ""`
  fired 30.2 s in with no `Stop` before it; not examined. Only a `Stop` whose
  `background_tasks` is empty says the work is done.
- **M5. Esc while the model streams: no hook at all for 170 s** (once). No
  `Stop`, no `StopFailure`, no `Notification`; the badge stayed `working`. So
  the Esc bullet in the #55 entry below, measured on 2.1.272, still holds. The
  transcript ends with the partial answer, then a user record
  `[Request interrupted by user]`, and **no** `system turn_duration` after it.
  **Treating `idle_prompt` as "turn over" does not work here.** After a normal
  `Stop` an `idle_prompt` Notification arrived 60.1 s later (once); after the
  Esc, none came within 170 s. Not measured beyond 170 s.
- **M6. Esc while a foreground tool runs: no hook for 20 s** (once). A 30 s
  `sleep` in `Bash`, auto-allowed, no dialog, Esc after 4 s. No
  `PostToolUseFailure`, no `Stop`. The transcript ends with a `tool_result`
  "The user doesn't want to proceed with this tool use. …", then
  `[Request interrupted by user for tool use]`, and again **no**
  `turn_duration`. `scripts/lib/roost-unblock.sh` requires `turn_duration`
  after the marker, so it would not match this shape even if it were run on
  the pane.
- **M7. A declined dialog still recovers, and `wait-done` calls it success**
  (once). Esc at a `Write` dialog: `PermissionRequest` 0.235 s after the
  prompt, the `permission_prompt` Notification 5.955 s after that, then the
  three #38 records **with** `turn_duration`. `roost wait-done %3 3` cleared
  the 🛑 and **exited 0**, with the badge unset — the "`wait-done` exits 0 on
  an interrupted turn" bullet in the #38 entry below, seen live.
- **M8. Every Claude hook call ran inside the pane's process tree.** 45 of 45
  logged calls, on the two panes of the clean runs, main-loop and subagent
  events alike, had the pane's `#{pane_pid}` in their parent chain: the hook's
  parent was `claude`, and `claude`'s parent was the pane's process. Only
  Claude was measured in this run, and only on tmux 3.6. The other harnesses'
  hook parents come from the #64 design
  (`docs/airig/specs/2026-09-15-agent-identity-design.md`, §3.1), not from
  this run.
- **M9. Walking that ancestry is cheap.** 100 calls each, with 1,294 processes
  running on this machine: `ps -A -o pid=,ppid=` took 26 ms a call and
  `ps -o ppid= -p PID` 2.4 ms a level. Claude's hook is 2 levels below the
  pane's process, so a walk is about 5 ms. That last figure is arithmetic,
  not a timed walk.

**Not measured:** background work on codex, opencode, pi and copilot (codex
has `SubagentStart` and `SubagentStop`; whether any of their turn-end events
carries background state is unknown). A human prompt sent **while**
background work runs, and where the `<task-notification>` turn goes then. A
background task that never ends (a dev server, the `Monitor` tool), and a
non-empty `session_crons`. `claude -p` with background work. `pane_pid` on
tmux 3.4 and 3.5a (CI's Ubuntu runs 3.4). A container. `opencode attach` to a
detached `opencode serve`. Whether a `run_in_background` shell is a child of
`claude` at all, and whether Claude's agent-team teammates, which can run in
other panes, appear in `background_tasks`.

**Step 1 measurements (Claude Code 2.1.310, tmux 3.6, macOS 26.3, 2026-10-24).**
Taken before step 1 was built, with the rig the design's §2 describes rebuilt
on 2.1.310: two throwaway `-S` servers whose socket path ended in `/roost`,
`HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp directories, a local
fake Messages API scripting each reply from a marker in the prompt, a logger on
25 hook events that also recorded each hook's pid chain and the pane's
`pane_pid`, `--model haiku --permission-mode default --setting-sources local
--settings <file>` with `permissions.allow` for the commands the rig runs.
Run 1 was eleven prompts in one pane, run 2 five prompts in another;
`~/.claude/settings.json` was hashed before and after each run and did not
change; `~/.claude.json` changed (tip and queue counters, which this machine's
own live Claude session writes) and gained no project key. "Once" means one
run. The raw logs, the fake API, the logger and the scripts that drove them
were kept with the lane's work, not committed; the payloads and transcript
tails the tests need are in `tests/fixtures/claude-stop-bg-*.json`,
`claude-ups-task-notification.json` and `claude-transcript-interrupt-*.jsonl`,
scrubbed of ids and paths.

- **A1 holds: a `run_in_background` shell is in the pane's process tree.** A
  `sleep 30` started with `run_in_background: true` had the chain `sleep <-
  zsh <- claude <- zsh (the pane's own process) <- tmux`, 1 of 1; a
  background subagent's foreground `sleep 20`, the same, 1 of 1; the two
  shells of a `Monitor`, the same, 2 of 2. Every one of the 72 logged hook
  calls across both runs had the pane's `pane_pid` in its chain. So step 1
  is built from Claude's list, as the design planned.
- **A2, agent teams: not measured.** No team tool was offered to the fake
  (the list Claude sent: Agent, AskUserQuestion, Bash, DeferredToolPlaceholder,
  Edit, ListAgents, Read, ReportFindings, ScheduleWakeup, Skill, ToolSearch,
  Workflow, Write; `Monitor` and `TaskStop` are reachable through
  `ToolSearch`). The rule stands: an unknown `type` holds `working`, and
  `roost doctor` names the pane and the type.
- **A3 holds: the list stays empty after `roost spawn` and `roost split`.**
  A turn whose `Bash` ran `roost spawn rig-a 'sleep 600'` ended with
  `background_tasks: []`; so did one that ran `roost split 'sleep 600'`. Once
  each. The new panes were the tmux server's children.
- **M2 again, twice (30 s and 15 s).** `Stop` with one running `shell` 266 ms
  after the prompt; ✅ done 144 ms after that `Stop`; done for 29.9 s / 14.9 s;
  then a `UserPromptSubmit` whose `prompt` is the `<task-notification>` text
  (`<task-id>`, `<tool-use-id>`, `<output-file>`, `<status>completed</status>`,
  `<summary>`) and a `Stop` with `[]` 258 ms / 104 ms later. The notification
  turn carries a **new `prompt_id`** (4 of 4 notification turns), so nothing
  but its prompt text ties it to the task; the deferral built in step 1 does
  not need the link. `@roost-reply-turn` went up by one for every
  notification turn, as M2 found.
- **M3 again, once (20 s).** `Agent` with `run_in_background: true`:
  `PostToolUse` (`status: async_launched`) and `SubagentStart` in the same
  millisecond, `Stop` with one running `subagent` 106 ms later, ✅ done 144 ms
  after that. The subagent's `PostToolUse` on the main pane at +20.1 s
  stamped ⏳ again (M3's accident), then `SubagentStop` (its
  `background_tasks` still listing the agent as running, as M10 says), the
  notification `UserPromptSubmit`, and `Stop` with `[]`.
- **A `Monitor` is a `shell` in the list, not a new type** (once, two
  monitors). The tool returns `{"taskId","timeoutMs","persistent":false}` and
  the `Stop` lists it as `type: "shell", status: "running"` with its command.
  Each monitor's end brought its own notification turn, and the `Stop`
  between them still listed the one left. Under the ownership rule a pane is
  held for the whole life of a `Monitor`; the skill says so.
- **`session_crons` is not a hold** (once). `ScheduleWakeup {delaySeconds:
  60}` put `[{"id","schedule":"2 23 * * *","recurring":false,"prompt"}]` in
  `session_crons` with `background_tasks: []`, on that `Stop` and the two
  after it. The wake-up turn did not start within 2 min 15 s; not measured
  beyond that.
- **Does the releasing `Stop` come? (§10 item 3)** Killed with `TaskStop`
  (once): the turn that called it ended with a `Stop` whose list is `[]`,
  and no notification turn followed in 25 s. Killed from the task panel:
  **not measured**. Claude exits with work running (once): `/exit` opened a
  Claude dialog ("Background work is running … 1. Exit and stop tasks"; no
  hook fired for it); after confirming, `SessionEnd` and **no `Stop`**, and
  the task was killed. A human prompt typed while the work runs (once): that
  turn's `Stop` **also** listed the running task, and the notification turn
  released with `[]`; a prompt typed exactly as the work ends was not driven,
  so not measured.
- **M5 again, once.** Esc 6 s into a slow stream: no hook of any kind in
  80 s. Transcript tail: an `assistant` text record with `isAbortedMidStream:
  true`, then a `user` record whose `message.content` is `[{"type":"text",
  "text":"[Request interrupted by user]"}]` with `interruptedMessageId`. No
  `turn_duration`.
- **M6 again, once.** Esc 4 s into a foreground `perl -e 'sleep 30'`: no hook
  in 20 s. Tail: a `user` `tool_result` with `toolDenialKind: "user-rejected"`
  and content starting "The user doesn't want to proceed with this tool
  use.", then `user` text `[Request interrupted by user for tool use]`. No
  `turn_duration`: the #38 decline's first two records without its third. A
  prompt typed afterwards fired `UserPromptSubmit` and `Stop` as usual. (A
  foreground `sleep 30` is refused by Claude 2.1.310 itself — "Blocked:
  standalone sleep" — hence perl.)
- **Transcript record types new since 2.1.270**, all metadata: `api-request`,
  `api-request-blob`, `api-request-shape`, `file-history-snapshot`,
  `queue-operation`, and `system` with subtype `stop_hook_summary`, which
  carries hook command paths. None landed after an interrupt marker in the
  two tails above; a reader that meets one there says "could not tell", as
  the decline reader does.

**What is still live after steps 1 to 3, most serious first.** Severity is
stated; "not measured" means not measured.

- **A Claude that exits with work running is released by `SessionEnd`, and
  only by it** (fixed in #188; measured on 2.1.310, one run per case, with
  the fake Messages API rig). Every exit tried fires `SessionEnd` and no
  `Stop`:

  | how Claude exited | `reason` |
  |---|---|
  | `/exit`, then "Exit and stop tasks" | `prompt_input_exit` |
  | `/exit`, then "Move to background and exit" (the work keeps running under pid 1, outside the pane) | `prompt_input_exit` |
  | Ctrl-C twice (opens the same dialog; no hook until it is answered) | `prompt_input_exit` |
  | `kill -TERM` | `other` |
  | `kill -HUP` (a closed terminal) | `other` |
  | `respawn-pane -k` (fired about 4 s after the respawn, into the same pane) | `other` |

  The payload carries `cwd, hook_event_name, prompt_id, reason, session_id,
  transcript_path` and no `background_tasks`. `--session-end-hook` releases a
  pane held for its stamp, and only when the payload's `session_id` is the
  hold's owner, `@roost-background-session`, which the Stop that held the
  pane wrote (and a prompt that reaches an already-held pane rewrites, so the
  old Claude's SessionEnd after a respawn cannot release the new one's turn):
  the badge is unset, `@roost-ended` reads `died`, `wait-done` exits 2, and
  the held main reply is kept as the turn (outcome `died`) and on the pane.
  The turn file is written only after the release is seen to land, so a
  SessionEnd that loses a race files nothing. With the first version of the
  fix (which matched `@roost-transcript`), all six cases above released the
  pane in the live rig; with the owner rule, `/exit` then "Exit and stop
  tasks" was run again, one run: released, `died`, `wait-done` exit 2. The
  respawn race itself was tested with fixture payloads only. What is left:
  - **`clear` and `resume` are recorded as `interrupted`** (`clear` measured
    once on 2.1.310; `resume` and `logout` not measured). Claude Code's hooks
    reference lists five reasons: `clear`, `resume`, `logout`,
    `prompt_input_exit`, `other`. After `/clear` or an interactive `/resume`
    the Claude is still in the pane at its prompt, so roost records the held
    turn as `interrupted` (`wait-done` exits 5), not `died`; `logout` and any
    reason roost does not know are `died`. Measured for `/clear` on a held
    pane: no dialog; `SessionEnd` reason `clear` with the old session id,
    then `SessionStart` source `clear` with a new id; the pane was released
    as interrupted. **The background shell kept running** in the new
    session, so from `/clear` until it ended the pane showed no badge while
    work ran in it (medium, measured once). When it ended, the new session
    got the notification as a `UserPromptSubmit` and a `Stop`: turn 1 is the
    main reply (interrupted), turn 2 the notification's answer (done).
  - **`claude --resume <the same id>` in the same pane after a respawn**
    keeps the session id, so the old process's late SessionEnd matches the
    new process's hold (reasoned, not measured). It needs the new process to
    prompt, run background work and Stop held inside the ~4 s before the old
    SessionEnd lands; the stamp check is what stands in the way.
  - **A gap between the release and the turn file** (provoked on every run
    by section 9 of `tests/test-session-end.sh`, which pauses the release at
    three points in the gap; the interrupt recovery has the same gap, and
    that one is reasoned, not measured). `wait-done --turn N`
    waits for the file as well as the badge, so it polls through the gap;
    but the `outcome` sidecar is written just after the turn file, and a
    `wait-done --turn N` that reads in the microseconds between the two
    would call the turn done. A hook cancelled inside the gap leaves the
    badge released, `@roost-ended` saying why, and no turn file, so
    `wait-done --turn N` times out. The entry carries `"timeout": 10`,
    since Claude's SessionEnd default is 1.5 s. A new prompt inside the gap
    cannot take turn N: the release reserves N in its own tmux command
    (`@roost-turn-reserved`), and every other writer starts above it (flock
    round 2 found that wrong). A `roost send` inside the gap prints no turn
    number at all: the release clears the badge, and `send` numbers only a
    pane that reads done or idle, as for any pane with no badge. `send` also
    counts a live reservation when it does number a pane; that only matters
    for a done or idle pane whose reservation is still set, so it is a
    zero-cost guard (one more field in a read `send` already makes), not
    something the gap needs. A hook cancelled inside the gap leaves
    the reservation and a `.reserving.*` file in the record's `replies/`;
    each later turn end on that pane then pays one tmux read for it, and
    numbering skips N, which is the number that turn would have had. A
    second SessionEnd release on the same pane inside the same 70 ms
    overwrites the first one's token, and the first turn is then not filed
    (reasoned: it needs a new prompt, a held Stop and a second exit inside
    the gap).
  - **A wiring from before #188 has no `SessionEnd` entry**, and such a pane
    stays ⏳ until #54 or #64 sees the agent go, as before. `roost doctor`
    names both the user's settings file and a server's wiring file.
  - **No owner, no release.** A hold with no `@roost-background-session` --
    written by a roost before this fix, by a Stop whose payload had no
    usable `session_id`, or after a prompt with none reached the held pane
    -- cannot be matched to the session that ended, so it stays held: the
    safe direction.
  - **A Claude that exits mid-turn with no hold still reads ⏳** until #54
    or #64 sees it go (not changed here). The same event and session check
    could release it; that is the next step, not this fix.
  - **`kill -KILL` runs no hook** (reasoned, not measured): the pane stays ⏳
    until #54 or #64, as before.
  - **The subagent count is not cleared** when Claude exits with a
    background agent running (not measured): `status --json` can report
    `subagents` above 0 for a pane whose agent has gone.
- **Work that leaves the pane's process tree belongs to no pane** (serious,
  by design, reasoned not measured). `nohup cmd &`, `setsid`, `cmd &
  disown` from a foreground `Bash`: the tool call returns, the process is
  reparented, it is not in Claude's list, and the pane reads ✅ while it may
  still change files. roost cannot see it and this design does not try to.
- **An older Claude, or a future one that renames the key, reads ✅ while its
  work runs** (serious, accepted: the Q5 exception below). A `Stop` with no
  `background_tasks` key keeps `done`. A machine with neither python3 nor jq
  is the same case. `tests/live/claude-background-smoke.sh` is the guard
  after a Claude upgrade, and only if someone runs it.
- **Killed from the task panel: not measured.** `TaskStop` from the model
  releases the pane at that turn's own `Stop` (once); whether a human
  killing the task from Claude's task list produces a releasing `Stop` was
  not driven. If it does not, the pane reads ⏳ until the next prompt. The
  safe direction, and the #95 shape again.
- **A `Monitor` holds the pane for its whole life** (correct, and a cost,
  measured once). It is a `shell` in the list, in the pane's tree, and ends
  only on its own exit or timeout, so a coordinator's `wait-done` exits 1
  until then. `skills/roost/SKILL.md` says to put one in its own pane.
- **An unknown kind of background work holds, and agent teams are not
  measured** (medium). Only `shell` and `subagent` were seen; any other
  `type` holds `working` on the rule that work roost cannot place is not
  assumed to live elsewhere, and `roost doctor` names the pane and the kind.
  If Claude's agent-team teammates, which can run in other panes, ever
  appear in the list, this pane waits on another pane's work: the one case
  the ownership rule forbids, left this way until measured (A2).
- **A prompt sent into a held pane is folded into the held turn** (medium,
  measured once). The human turn's `Stop` lists the running work too, so the
  pane stays held, and the release appends ONE turn file: the final reply.
  That prompt gets no turn file of its own, and `send` to a held pane prints
  no turn number (it takes the "already mid-turn" path), so a coordinator
  never had one to lose. The main reply is not kept on disk either, once the
  final reply replaces it — the cost of building Q3 as a deferral. When the
  release has NO reply of its own (a turn that ended on a tool call), or the
  held turn is ended by an Esc or a declined dialog, the held main reply IS
  the turn's file (flock round 1); it is taken back off the pane, so a main
  reply longer than the 12 KB pane cap is recorded cut, with its truncation
  marker (low: the release with no reply of its own is itself rare).
- **After a recovery saves a held turn's answer, plain `read` shows the
  screen; `read --turn N` has the answer** (low, by design). Recovery may only
  unset, so the badge and `@roost-reply` go and the main reply lives in turn
  N's file. A coordinator that gets exit 5 from `wait-done` and then runs a
  plain `read` gets the screen with its notice; `read --turn N` (or
  `wait-done --json`'s `turn`) is the way to the answer. With recording off
  there is no file, so the answer is put back on the pane instead, and plain
  `read` serves it.
- **A Claude settings file or wiring from before #95 recovers no Esc** (low,
  by design). The transcript path is recorded at the start of a turn only
  under `--prompt-hook` on the UserPromptSubmit entry, so a plain `roost
  state working` never reads its stdin. An older `settings.json` badges
  exactly as before and an Esc mid-turn leaves ⏳ until the next prompt, as
  before #95; `roost doctor` names the missing flag and `roost install`
  replaces the entry. A roost server started before the upgrade keeps its old
  wiring file until it is restarted.
- **After a Claude interrupt the pane has no badge, so the next `send`
  prints no turn number** (low). Recovery may only unset, so the pane is
  neither done nor idle, and `send`'s turn watch runs only from those two.
  The same is true after a declined dialog today. The interrupted turn does
  have a number — an empty file with an `outcome` sidecar — so the NEXT
  turn's number is right.
- **A human prompt typed exactly as the work ends: not measured.** Typed
  while the work runs is measured (above); the coincidence was not driven.
  The deferral does not depend on which turn the notification lands in: any
  `Stop` whose list is empty releases.
- **The other four harnesses are not measured and not built (Q7).** codex
  has `SubagentStart` and `SubagentStop`; whether any of their turn-end
  events carries background state is unknown. Their badges behave as before:
  a background job there can outlive a ✅.
- **`wait-done` exit 5 is new, and a script that tested only for 0 and
  non-zero sees a non-zero it did not before** (low, intended). Exits 0, 1
  and 2 keep their meanings; plain stdout is unchanged.
- **The transcript format is not a contract** (the #38 shape, now for
  `working` too). A renamed marker fails closed: the pane stays ⏳ until the
  next prompt, as before #95. `tests/live/claude-decline-smoke.sh` covers the
  decline shape; the two interrupt shapes have fixtures from 2.1.310 and no
  live guard of their own yet.

**Process ancestry (#105) is not a fix for #77 or #102.** M8 shows a report
from Claude's own hooks passes an ancestry test. Reasoned from that, not
measured: a nested agent that the pane's agent starts (#77) is a descendant
too, so it passes as well; and #102 is about a pane that reports nothing, so a
test on the sender has nothing to refuse. Ancestry can help #78, as a way to
*find* a pane rather than to refuse a report.

### Two places "could not tell" is reported as done on purpose

The rule behind every false-`done` entry in this file is that "could not
tell" is never reported as done. **That rule is not absolute.** The human
decided on 2026-09-28 to bend it in two places, for #97 and #105, because in
each the strict answer would remove something that works today. The first is
built (step 1, 2026-10-24); the second too (step 4, 2026-10-25). Each is recorded here so
nobody reads the rule as absolute and is surprised.

- **A Claude too old to report background work keeps reading ✅ done.** A
  Claude `Stop` with **no** `background_tasks` key keeps today's `done`
  (built, step 1). Holding `working` there instead would break every older
  Claude install. **Cost:** on such a Claude the false ✅ of M2 and M3 stays —
  about 30 s per task in those runs, and as long as the task runs in general —
  and `wait-done` exits 0 while files may still change. That is no worse than
  today: it is today's #97 bug, kept on those installs. Two more inputs reach
  the same branch: a machine with no working JSON reader, which cannot see the
  key at all, and a future Claude that renames or drops the key, where the
  false ✅ comes back **silently** and only a live smoke test after the upgrade
  would catch it (`tests/live/claude-background-smoke.sh`). The two limits
  the human accepted on 2026-09-29 are built: the exception covers an
  **absent** key only (a key that is present but malformed holds `working`,
  with a count of `?`), and the JSON reports `background: null`, never `0`,
  so a coordinator can tell "no background work" from "could not see".
- **A report whose sender cannot be verified is accepted and marked
  unverified** (built, step 4). A report whose ancestry walk cannot run — a
  container whose pid namespace hides the host `pane_pid`, or a `ps` that
  fails — is accepted, not refused. Refusing would turn "could not check" into
  a silent badge loss. **Cost:** in those cases the filter protects nothing,
  and any process there can stamp any state, `done` included, exactly as
  before the filter, when nothing was checked. The real risk is false
  confidence: readers will assume every badge was checked. The two limits the
  human accepted on 2026-09-29 are built: "cannot check" means the walk could
  not **run** — a walk that reaches pid 1 without meeting the pane is a
  refusal, not "unverified" — and "unverified" is visible, as
  `verified: false` in `status --json` and `state --json`, and as a
  `roost doctor` line naming the pane. The test suite's own switch
  (`ROOST_TEST_SKIP_ANCESTRY=1`, exported by `tests/lib.sh`) takes this same
  path, so it is never a silent pass either. It is a **deliberate bypass in
  the shipped sink**, not only a test hook: any process that sets it is
  accepted as unverified, wherever it runs (found by review, fix round 1).
  Kept so because the filter's threat is a stray process, not an attacker --
  a process that can set an environment variable can also set `TMUX_PANE`
  and run inside the pane -- and because every such report is still marked
  `verified: false` and named by `doctor`. Narrowing it to the suite's
  `/tmp/amx.*` sockets was considered and not done: a test socket path is
  not a fixed shape across the suite.

An older exception of the same shape is already live: a codex adapter on a
machine with no working JSON reader badges a dead turn ✅ done (see the codex
entry below). The rule as it really stands: **"could not tell" is never
reported as done, except where the only alternative removes behaviour that
works today, and every such place is listed in this file.** Add any new one
here.

### The report filter (#105): what it does not cover

**Built** (step 4 of `docs/airig/specs/2026-09-29-turn-over-design.md`,
2026-10-25). `scripts/roost-agent-state` walks its own parent up with
`ps -o ppid=` (`scripts/lib/roost-ancestry.sh`, `roost_pid_in_pane`) and
accepts a report only when the pane's `#{pane_pid}` is met on the way. A walk
that reaches pid 1 without it is **refused** (§4.3: a busy badge stays; a
`done` or `idle` badge is unset by a refused `working` or `blocked`; the
refusal is `@roost-refused "<epoch> <state> <pid>"`). A walk that cannot run
is accepted and marked (the second entry of "Two places 'could not tell' is
reported as done on purpose", above). `tests/test-report-filter.sh` pins
each case against a real pane.

**What it costs** (measured 2026-10-25, macOS, tmux 3.6, about 1,440
processes running). The old sink (`HEAD` before the filter) and the new one
were each called from inside a pane of a throwaway `-S` server, one process
below the pane's shell — a Claude hook's shape (hook → claude → pane, M8) —
in three alternating rounds of 200 calls per measure:

| measure | old sink | new sink | difference |
|---|---|---|---|
| unchanged state (`working --tool-hook` on a working pane: the PostToolUse hot path) | 13.6–14.3 ms | 13.3–14.2 ms | none measurable: no `ps`, no extra tmux round trip (`#{pane_pid}` rides in the bail's one read) |
| the same, after fix round 1's stale-job check (5 alternating rounds of 200, a live job record; e01453e's sink vs the new one) | 13.07–13.51 ms | 12.87–14.47 ms | none measurable: the job record rides in the same read, and the check is a builtin `kill -0` |
| a badge change (`working --tool-hook` from done, then `done`) | 48.9–49.8 ms | 52.2–53.7 ms | about +3.5 ms, one `ps -o ppid=` level (M9 measured 2.4 ms a level) |

A ratio, not a number to quote: about +7% on a transition, 0 on the hot
path. A harness whose hook is deeper pays one `ps` per extra level; a report
from the pane's own shell (`roost state` typed at the prompt) pays none,
because the walk starts at the sink's `$PPID`. The flags that write above the
bail (Stop, the dialog hooks, the prompt hook) add one tmux read of
`#{pane_pid}` besides, once per turn or dialog.

**What it leaves:**

- **A nested agent passes.** A `codex exec` or `claude -p` the pane's own
  agent started is a descendant of the pane, so the filter accepts its
  reports (§4.2; #77 still needs its env switch).
- **A stranger's report of the state the pane already has is not checked.**
  It bails before the walk, which is what keeps PostToolUse free, and it
  changes nothing; but it is not recorded as refused either, so `doctor`
  cannot name it. Only a report that would change something is checked.
- **The `verified` mark describes the stamp, not every report since.** It is
  written with the badge, so a later unchanged-state report (unchecked, above)
  leaves the stamp's mark standing.
- **An `error` badge is not unset by a refused `working` or `blocked`.** The
  design names done and idle; an unbadged pane is one `wait-done` exits 0 for,
  and turning a 💥 into that would be a false "finished". So a stranger's
  `working` leaves 💥 standing — "could not tell" either way, and the safe one.
- **A refusal writes no event line.** A refused `working` that unsets a ✅ is
  a badge change the event log (#98) does not record.
- **A refused `working` that unsets a ✅ leaves `@roost-reply` standing**
  (found by review, fix round 1; per §4.3, which says only "unset the
  badge"). `read` then serves the finished turn's reply on an unbadged pane
  as current, with nothing on stderr. The reply is the last real turn's, so
  it is not false, but nothing says the badge went for a refusal.
- **`@roost-refused` is never cleared.** It keeps the LAST refusal, so
  `status --json`'s `refused` and the `doctor` line name it until the pane
  closes or another refusal replaces it. It says when, so an old one can be
  told from a new one.
- **`--subagent-hook` is not filtered.** It keeps a count, never the badge.
- **Inside a container the filter protects nothing**, as accepted (Q4): the
  walk ends at the container's own pid 1 and the host's pane pid is not
  visible, so every report there is "unverified". Not measured: a container
  pid that happens to EQUAL the host's pane pid would read as met or as a
  verdict. Neither is likely; neither is checked.
- **A process that exits mid-walk makes the walk "unverified"**, not refused:
  its `ps` fails. A reporter would have to lose that race on purpose.
- **tmux 3.5a `pane_pid` is not measured** for this step. 3.4 is:
  `tests/test-report-filter.sh` passed in the Ubuntu 24.04 image (tmux 3.4,
  dash as `sh`), whose in-pane cases start the pane through `sh -c` and
  walk from it, and 3.6 on macOS.

### A Claude Code turn that fails on an API error: fixed by #55, with holes left

**Fixed by #55.** Before it, a Claude turn that ended on a rate limit, an
overload or any other API error left the pane ⏳ `working` forever. Claude fires
`StopFailure` for that turn instead of `Stop`, and roost did not wire it. So
`wait-done` burned its whole timeout on an idle agent, and the human saw no 💥.

**What was measured** (Claude Code 2.1.272, one logger on all 33 hook events, a
throwaway `-S` server, `--setting-sources local`; every failure triggered on
demand, never a real rate limit):

| case | events after `UserPromptSubmit` | `error` field |
|---|---|---|
| healthy haiku turn | `Stop` | — |
| `--model` naming a model that does not exist (real API) | `StopFailure` | `model_not_found` |
| local fake API answering 429, `CLAUDE_CODE_MAX_RETRIES=0` | `StopFailure` | `rate_limit` |
| the same 429, default retries | 10 retries over ~3 min, then `StopFailure` | `rate_limit` |
| fake API 500 | `StopFailure` | `server_error` |
| fake API 529 | `StopFailure` | `server_error` |
| base URL nobody listens on | `StopFailure` | `server_error` |
| Esc while the model streams | nothing | — |

`StopFailure` fired once, ~60 ms after the failure, and never together with
`Stop`. The only later event was an `idle_prompt` Notification ~60 s on, which
the `permission_prompt` matcher already ignores. The payload carries the usual
fields plus `error` and `last_assistant_message`, which is Claude's error
banner, not a reply. Claude's schema also has an optional `error_details`; it
was absent in all seven captures, and roost does not read it. Raw logs were
kept with the #55 work, not committed.

**What is wired.** A Claude hook of its own, `StopFailure` with no matcher, runs
`roost-agent-state error --stop-failure-hook`. It badges 💥 error, clears the
previous turn's reply, and records `@roost-error-reason` as *Claude ended the
turn on an API error (<kind>)* — the same path codex uses (#53), so
`wait-done` and `read` print it. `<kind>` is the payload's `error` if it is
lowercase letters and underscores, else `unknown`. A payload with an
`agent_id` changes nothing. `tests/test-claude-stop-failure.sh` holds both
directions: a failed turn is not `working` or `done`, and a healthy turn, and
the healthy turn after a failed one, still reach `done`.

**What is still not covered, most serious first.**

- **Esc while the model is still answering leaves ⏳ `working`, and #55 does
  not change that.** The same measurement shows it fires no hook at all — not
  `Stop`, not `StopFailure` — so nothing moves the badge, and `wait-done`
  waits out its timeout on an idle pane. It was true before #55. Unlike a
  declined dialog, no transcript record is read to recover it. Re-measured on
  2.1.283: still no hook for 170 s — see "When a Claude turn is over" above.
- **Existing installs need `roost install` again.** A `settings.json` wired
  before #55 has no `StopFailure` entry, so a failed turn still reads
  `working` there. `roost doctor` warns about exactly this, and the installer
  adds the one missing entry without touching the others.
- **The subagent rule is read from Claude's source, not measured.** The
  2.1.272 source adds `agent_id` to a hook payload only for a subagent's loop,
  and a subagent's API error returns to the main turn as a failed tool call.
  If a later Claude sends `agent_id` for the main loop too, a failed main
  turn would stay `working` again. If a subagent's `StopFailure` ever arrives
  WITHOUT `agent_id`, the main pane would read 💥 mid-turn until its next
  tool call sets `working`.
- **Three more failure routes are read from the source, not measured.**
  2.1.272 also fires `StopFailure` for a prompt that is too long, an image
  error, and a tool call the model could not form twice in a row. Each ends
  the turn with no answer, so 💥 is right, but no capture was taken.
- **With no python3 and no jq** the badge is still 💥, but the kind reads
  `unknown` and a subagent's failure cannot be told apart, so it badges the
  main pane too.
- **A second failure on a pane that already reads `error` keeps the first
  reason.** The unchanged-state bail in `scripts/roost-agent-state` returns
  before the reason is written. In practice a new prompt sets `working` in
  between, so this needs a hand-typed `roost state error` or a failure with no
  `UserPromptSubmit` before it.
- **Claude's own retries look like work.** On a 429 with default settings,
  Claude retried for ~3 minutes before giving up, and the pane read
  `working` for all of it. That is true — the turn is still running — but a
  `wait-done` with a short timeout will time out, not report the error.
- **`tests/live/claude-stop-failure-smoke.sh` is the only guard against a
  Claude upgrade** renaming the event or its `error` field. The suite's
  payloads are old captures. Run it by hand after an upgrade.

### A pane reads 🛑 blocked for the whole run of a tool that was approved

**A live risk, and today's behaviour on Claude Code and codex.** Measured for
the `roost answer` design (#142,
`docs/airig/specs/2026-09-30-roost-answer-design.md`, M6) on a throwaway `-S`
server with a local stand-in for each API: Claude Code 2.1.283, codex-cli
0.157.1, tmux 3.6, 2026-09-30. Each case below was run **once**.

- **Claude Code.** A `sleep 25` was approved with `1`. The dialog left the
  screen 12 ms later. The pane then read `blocked`, with the same
  `@roost-blocked-on`, for **25.09 s**, until the tool's `PostToolUse`. No hook
  fires between `PermissionRequest` and `PostToolUse`, and the transcript gains
  no record in that time. So the badge says "a dialog is open" when none is.
- **What that costs.** `roost send` refuses the pane with "a permission dialog
  is open", which is the wrong reason. `next-blocked` and a notification point
  a human at a pane that needs nothing. And a key sent to "answer" the dialog
  lands in the prompt box: a `1` sent to an idle Claude or codex prompt is
  typed there and stays (once each).
- **codex** shows the same until its turn ends, and then something worse: see
  the next entry.

**Why it is left.** Neither harness has an event for "the human said yes".
The first event after an approval is the tool's result. `roost answer` (#142)
works around it, and does not fix it: it checks the visible screen for the
dialog before it sends a key, refuses a second answer to the same dialog, and
records the answer in `@roost-answered`, which `status --json` shows as
`dialog.answered`. A human who presses the key at the pane still gets this
badge, with no `answered`.

**What would close it:** an approval event from the harness, or for codex a
`PostToolUse` when `exec_command` yields.

### A codex pane can read 🛑 blocked after its turn is over

**A live risk. Seen once, on codex-cli 0.157.1**, in the same run as the entry
above. A `sleep 25` was approved with `y`. `exec_command` gave control back to
the model after about 10 s, while the command still ran. So `Stop` fired at
+10.2 s with **no** `PostToolUse` before it, and the `Stop` guard in
`scripts/roost-agent-state` held that one `Stop` back, because the pane read
`blocked`. **The pane still read `blocked` 20 s later, with the turn over**,
and stayed so until the next prompt.

**What that costs.** `roost wait-done` waits out its timeout on a finished
turn, `roost send` refuses with exit 3, and `roost read` calls the turn's own
reply stale. It is the "exactly one `Stop` and no clearing event" hole in the
declined-dialog entry below, seen live for the first time.

**Why it is left.** It was found while measuring a design, and the fix is in
the codex adapter, which that design does not touch. **What would close it:**
a clearing event when `exec_command` yields, or a `Stop` guard that does not
hold a `Stop` back once the dialog is known to be answered.

### A second codex pane can badge the first (#145)

**A live risk, high if it holds up. Seen once, on codex-cli 0.157.1.** Two
codex panes on one `CODEX_HOME`: all six hook calls of the second pane ran
with the first pane's `TMUX_PANE`, so the first pane read `blocked` for a
dialog on the second pane's screen, and the second pane had no badge. #145 has
the measurement and owns the fix. It is listed here because a wrong pane's
badge is the kind that makes `send` and `wait-done` act on the wrong pane. It
is also why `roost answer` has no codex keys yet: every codex dialog is
refused with exit 8 until #145 is understood.

### `roost answer` (#142): what it refuses, and what it cannot prove

**A live risk, by design narrow.** `roost answer` sends one key into the
dialog a pane is blocked on. The design and its measurements are
`docs/airig/specs/2026-09-30-roost-answer-design.md`; the build is steps 1, 2,
3 and 5 of its §10. Every case below sends nothing unless it says so.

**The caller check cannot prove a person. Medium.** It refuses (exit 9) a call
whose `$TMUX` names this server and whose `$TMUX_PANE` is a pane an agent has
reported from: it has `@agent_state` or an identity (`@roost-session`). That
stops an agent that reads the skill, sees a blocked peer and tries the obvious
command. It does not stop:

- one `env -u TMUX -u TMUX_PANE roost answer …`. The environment is the only
  signal used today; the parent-chain test of the design's §7.2 waits for
  #105's walk (step 6 of §10). Scrubbing the environment AND detaching
  (`nohup … &`) gets past both, and nothing can close that
- an agent in a harness with no adapter: its pane has no badge and no
  identity, so it looks like a person's shell pane (the human's decision Q1)
- an agent passing `--force`. The skill says never to, unless its human told
  it to answer that dialog

And it surprises one person (the design's §12.9): someone who ran an agent in
a pane, quit it, and now types in that pane gets exit 9, because the pane
still has its badge. `--force` is the honest answer there.

**What is refused in this cut, each with the exit code a caller sees:**

| case | exit |
|---|---|
| a bad call: no action, two actions, `--option` with no number, `--expect` that is not 12 lowercase hex | 1 |
| `--approve` or `--option` with no `--expect` | 1 |
| no such target, a dead pane, a window with more than one blocked pane | 2 |
| a pane that is not blocked, one in copy mode, one whose screen does not show the dialog, a dialog already answered | 6 |
| `--expect` that is not the pane's dialog, or a dialog that changed before the send; a blocked pane with no dialog record and `--expect` given | 7 |
| `--text`; a dialog of kind `other` (a Claude `WebFetch`, an MCP tool, `NotebookEdit`, plan approval, a multi-select, two or more questions, an option with a preview, a subagent's dialog, a payload no reader could parse); every codex dialog (#145); every opencode, copilot and pi dialog; `--approve` on a question; `--option` on a permission prompt; an option number the agent did not give; a deny with no `--expect` on a pane with no dialog record | 8 |
| a caller in an agent's pane, without `--force` | 9 |

Claude's `Edit` dialog was measured for this cut (2.1.309, once each: `1`
approves with no Enter, Escape declines) and is answered. `WebFetch` and an
MCP tool were not measured — one needs the network, the other a server — and
stay refused.

**What can still go wrong after a key is sent.** Each was predicted by the
design (§12) and none was seen; the first two cannot be reproduced on demand.

- **The approve that lands on the next dialog. Low.** A new dialog is drawn a
  little before its hook writes the new fingerprint (11 to 16 ms, plus the
  hook's own run). If a person answers the old dialog at the pane in that
  instant, `answer`'s key goes to the new one under the old fingerprint, and
  the marker cannot tell the two apart. It needs two answers inside about
  60 ms.
- **A stray digit in the prompt box. Low.** A person declines at the pane a
  few milliseconds before `answer` sends `1`. Claude fires no hook for a
  decline, so every check passes, and the `1` is typed into the prompt. The
  transcript then shows the decline, so `answer` exits 10 and says so; the
  stand-in test covers that. The digit stays in the prompt box, and the next
  `send` pastes after it. roost does not send a key to clean it up.
- **The `screen` proof is the builder's reading, not a measurement.** After a
  key, the dialog leaves the screen before anything else changes, so a screen
  with no dialog on it counts as proof only once it has held for half a
  second, and a stronger proof or a decline seen in that time wins. No run
  measured how long the stronger proofs can lag. An approved slow tool is
  reported `confirmed: screen` half a second late; that is the cost.
- **"Same hook twice" keeps the fingerprint, by reasoning.** Two hook calls
  for one dialog keep one token when the pane already reads blocked with the
  same tool and input. A subagent's dialog with the same tool and input,
  opened while the main dialog is up, was not measured; it is kind `other`, so
  its record differs and it gets a new token, and it is refused anyway.
- **The marker text is Claude's, not a contract.** The day a dialog is
  reworded, every `answer` on it is exit 6, "no dialog is on its screen".
  That is safe, and it will look like a roost bug. `tests/live/answer-smoke.sh`
  says which it is; run it after every Claude Code upgrade.
- **A wrapped dialog line.** The screen is read with wrapped lines joined
  (`capture-pane -J`), and the stand-in test checks a pane 10 columns wide,
  where both marker lines wrap. A real Claude dialog in a narrow pane was not
  driven.

### On tmux 3.4 a C-locale client reads a tab as `_`

**A live risk, unmeasured outside one case. Medium on a C-locale machine.**
Measured on Ubuntu 24.04, tmux 3.4-1ubuntu0.2: a tmux client whose locale is
`C` prints a tab in a `display-message` or `list-*` format as `_`, so
`#{session_name}<TAB>#{pane_id}` came back as `0_%0`. Under `C.UTF-8` it
printed the tab, and tmux 3.6 on macOS prints it in both, so CI (`C.UTF-8`)
and the Mac never see it. Several readers split a tmux reply on tabs and were
not changed: the event log (`scripts/lib/roost-events.sh`), `status --json`
and the other `--json` readers (`scripts/lib/roost-jsonout.sh`, which already
refuses a row whose tab count is wrong and falls back to one field per call),
the hook (`scripts/roost-agent-state`) and `scripts/roost-ext`. On such a
machine each of them reads one field where it expected several, and what that
costs was not measured per reader. `roost answer` (#142) splits on `|`
instead, which tmux 3.4 printed unchanged in both locales, and
`tests/test-answer.sh` runs it against a server and a client in the C locale.
**What would close it:** the same separator in the other readers, each with
a C-locale case on tmux 3.4.

### Claude's "No" is not always option 3

**A note, not a defect in roost.** For anyone who scripts keys to a Claude
permission dialog. Measured on 2.1.283, once each: a `Bash` dialog has three
options, `1. Yes`, `2. Yes, and always allow …`, `3. No`. A `Bash` command
that uses `&` has two, `1. Yes`, `2. No`. So `2` is "No" on one dialog and a
standing permission on the other. Escape declines on both. `1` approves on
both, and with the cursor moved to another row (once). The "third dialog
answer" bullet in the entry below describes the three-option shape only.

### A declined permission dialog: fixed for Claude Code and codex, with holes left

**Fixed by #38, for two harnesses, from harness records rather than the
screen.** Before it, answering **No** at a permission dialog, or pressing Esc,
ended the turn with `@agent_state` stamped `blocked` and nothing to unstamp it:
`roost send` refused the pane with exit 3 forever, `roost wait-done` burned its
whole timeout, and `roost read` called a current reply stale.

**What was measured** (one logger on every hook event, throwaway `-S` servers,
raw logs kept with the #38 work):

| harness | No | Esc | Yes |
|---|---|---|---|
| Claude Code 2.1.270, all 32 events | **no event at all** | **no event at all** | PostToolUse, then Stop |
| codex-cli 0.154.0, all 12 events | Interrupt (+42 ms), no Stop | Interrupt (+84 ms), no Stop | PostToolUse (+132 ms), no Interrupt |
| Copilot CLI 1.0.83 | **not measured** (see below) | `permission.completed {kind: cancelled}`, `abort`, `session.idle {aborted: true}` | `permission.completed {kind: approved}` |

On Claude Code, `PostToolUseFailure`, `PermissionDenied` and `StopFailure` were
all wired and all silent. codex's Esc while the model is still streaming, with
no dialog, also fires Interrupt and no Stop.

**What is wired.**

- **codex** registers a fifth hook, `Interrupt`, which badges `idle` and clears
  the previous turn's reply. It is an event, so it sets state.
- **Claude Code** has no event for the ANSWER. It does write the decline into
  its own transcript — `tool_result` "The user doesn't want to proceed with this
  tool use…" with `toolDenialKind: "user-rejected"`, then
  `[Request interrupted by user for tool use]`, then `system turn_duration` —
  so the dialog hooks record `transcript_path` beside their stamp
  (`--permission-request-hook`, `--notification-hook`), and `send`, `read` and
  `wait-done` call `scripts/lib/roost-unblock.sh` before believing `blocked`.
  It clears only when those three records are the newest conversation records
  in the transcript and none is older than the stamp; it only ever UNSETS, and
  records `@roost-unblocked`. An old decline under a newer prompt — the screen-based
  first attempt's fatal case — stays blocked, and is a test.
- **copilot** needed nothing for Esc: 1.0.83 fires `permission.completed` with
  `cancelled`, which the adapter already clears on.
- **`roost doctor`** names any pane that has read `blocked` for 10 minutes
  with no dialog text on its screen, as "may be stuck". Read-only.

**What is still not covered, most serious first.**

- **Claude's transcript format is not a contract.** If an upgrade renames a
  record, recovery stops silently and panes stay blocked, as before #38. It
  fails closed, never open. `tests/live/claude-decline-smoke.sh` is the guard
  and fails loudly on a shape change — but only if someone runs it after an
  upgrade.
- **Existing installs need one step each.** codex: the `Interrupt` handler is
  new, so codex asks at "Hooks need review" again and nothing works until
  someone answers "Trust all and continue" once more (`roost doctor` names
  exactly this). The same handler's timeout has since moved from 10 to 3 —
  codex's own cap, which it was clamping the 10 down to while warning with the
  hooks.json path on every start — so a machine installed before that change
  needs `roost install`. Whether a trust answer has to follow depends on the
  version: 0.154.0 does not hash a timeout, so the rewrite lands under the
  existing trust entry and codex asks nothing; 0.151.0 did, and there it asks
  once. Nothing the hook does changes either way, and `roost doctor` reads the
  timeout out of `hooks.json` and says so when it is still the old one. Claude: a `settings.json` wired before #38 has no
  `--notification-hook`, records no transcript, and never recovers until
  `roost install` is re-run; one wired before #91 has no `PermissionRequest`
  entry at all and keeps the whole 6 s window, and no `PostToolUseFailure`
  entry, so a tool that fails after a Yes leaves the pane 🛑 for the rest of
  the turn. `roost doctor` names each of those three by the flag or the event
  name it looks for, and each of those checks now has a test that fails when
  the check is removed (flock round 2 found two that did not). `roost doctor` names each
  missing entry by the flag it looks for, and `roost install` adds the entry
  and leaves everything else alone.
- **copilot `No` is not measured.** On 1.0.83, `3` moved the cursor and neither
  Enter nor `C-m` sent through `tmux send-keys` closed the dialog, three tries.
  Esc recovers; whether No does is unknown.
- **`wait-done` used to exit 0 on an interrupted turn, on every harness;
  since #95 it exits 5.** A codex Interrupt and a copilot aborted turn now
  record `@roost-ended "<stamp> interrupted"` beside their `idle`, a Claude
  decline or Esc is recorded the same way when roost recovers it, and
  `wait-done` reads that record where it would have exited 0 (found by
  review, flock round 1; seen live on Claude 2.1.283, M7 above). What is
  still true: a Claude decline recovered from a `blocked` pane leaves no
  badge, so the next `send` prints no turn number; and a copilot `No` is
  still not measured (next bullet).
- **Claude with no python3 and no jq** cannot read a transcript, so it never
  recovers there. Same fail-closed shape.
- **A Claude too old for `PermissionRequest` still has the whole 6 s window,
  and roost cannot tell.** Fixed for current Claude by #91: a seventh hook,
  `PermissionRequest` with no matcher, badges 🛑 as the dialog opens.
  Re-measured on 2.1.278 with a logger on all 18 hook events, an isolated HOME
  and a local stand-in for the Messages API: `PermissionRequest` lands 11–16 ms
  after the dialog is drawn (four samples, polling `capture-pane` at ~5–9 ms a
  frame), and the `permission_prompt` Notification lands a flat **6.00 s after
  it** — 6.002, 6.001, 5.996, 6.003 and 5.997 s for a Bash, an Edit, a Write, a
  WebFetch and an MCP tool. A dialog answered inside those six seconds fires no
  Notification at all, which is why a fast answer was never badged. The
  Notification entry stays wired as the fallback, so a Claude without the event
  keeps exactly the old behaviour — and roost does not detect the version, so
  on such a Claude the 6 s window is still open and nothing says so.
- **Nothing but its own test keeps the hook silent.** `PermissionRequest` is an
  event Claude ACTS on: a hook that prints a `decision` of `allow` answers the
  dialog on the human's behalf. roost prints nothing, which was measured to
  leave the dialog for the human (as does `{}`), and
  `tests/test-claude-permission-request.sh` asserts the hook's stdout is empty
  — on the active-window path and on the one that starts a `roost-notify`
  child, the only process that inherits the hook's stdout. That pair of
  assertions is the only thing between a future edit and roost approving a
  tool call nobody saw.
- **A long-running roost server keeps the old hooks after an upgrade.**
  `scripts/roost-wiring` generates a second Claude settings file, and it does
  so when the SERVER starts — so a `-L roost` server that has been up since
  before #91 hands every pane the old entries even after `roost install` has
  run, and the user's own `settings.json` check says nothing because that file
  is fine. Found by review (flock round 1). `roost doctor` now names that file
  too, and `roost wiring on` regenerates it; nothing detects it automatically.
- **A subagent's dialog over a declined main dialog: measured, and the window
  is now about 250 ms rather than about 6 s.** Found by review (flock round 1),
  and reproduced on 2.1.278 in the #91 rig. What happens: a background agent's
  dialog is drawn on the MAIN pane, `PermissionRequest` fires for it with
  `agent_id` and `agent_type` added, and its `transcript_path` still names the
  main session file. So the stamp moves to the new dialog, and
  `roost-unblock.sh`'s rule 4 — every record no older than `@agent_since` —
  then refuses to read the older decline as current, which is what closes the
  wrong clear. What is LEFT is the gap between the main decline and the
  subagent's `PermissionRequest`: 259 ms from the prompt in the rig. A `roost
  send` inside that gap still clears correctly, because no dialog is open yet,
  and can then land in the dialog that opens next. That is a race, not a stuck
  badge, and it is the same shape on any harness.
- **A Claude subagent's dialog ends the main turn, and the main turn's `Stop`
  races the dialog.** Measured on 2.1.278, twice, and the two runs DISAGREED:
  first `PermissionRequest` (with `agent_id`) at 1790058350.889319 and the main
  turn's `Stop` (with NO `agent_id`, so nothing in the payload tells them
  apart) 7 ms later; then, on the same case, `Stop` at 1790062049.316559 and
  `PermissionRequest` at 1790062049.316824 — `Stop` first, by 0.265 ms. So
  nothing may depend on which arrives first, and the first version of this
  guard did: it read `@agent_state` and acted on that read dozens of lines
  later, which gave ✅ done under an open dialog in 28 of 40 runs when the two
  hooks started together (flock round 1, measured). `scripts/roost-agent-state`
  now holds the `Stop` back with a single `if-shell`, so tmux tests and writes
  in one command. What is LEFT: the rule is still that a pane reading `blocked`
  keeps its badge through a `Stop`, so anything that badges a pane `blocked`
  and never clears it costs that pane one `Stop` — see the bullet below.
- **The `Stop` guard swallows exactly one `Stop` per dialog, and that bound is
  the only thing keeping a pane from sticking at 🛑 for ever.** The first
  version had no bound, and two reviewers found panes stuck with `send`
  refusing, `wait-done` burning its timeout and `read` calling the reply stale
  (flock round 1). One of the two inputs reproduces live and is now wired:
  a tool that FAILS after a Yes fires `PostToolUseFailure` and no `PostToolUse`
  (measured on 2.1.278 — `PermissionRequest` at 1790061919.001582, Yes,
  `PostToolUseFailure` at 1790061923.942409, `Stop` 114 ms later), so
  `PostToolUseFailure` is now an entry of its own and clears the badge. The
  bound is the belt to that: `@roost-stop-swallowed` is unset when a dialog is
  stamped and set when a `Stop` is held back, so a second `Stop` always moves
  the pane. A turn that fires exactly one `Stop` and no clearing event still
  loses that `Stop` — the pane then reads 🛑 until the next prompt, which is
  the pre-#38 shape and fails closed.
- **A declined SUBAGENT dialog was reasoned to strand a pane; measured, it does
  not.** The review's input: the subagent's `PermissionRequest` stamps
  `@roost-transcript` with the MAIN session file, the decline records go
  somewhere `roost-unblock.sh` cannot match, and the main turn's real `Stop` is
  swallowed. Measured on 2.1.278, pressing `3` at a subagent dialog:
  `PostToolBatch` +52 ms, `SubagentStop` +102 ms, **`UserPromptSubmit` +158 ms**
  and `Stop` +227 ms. Claude re-enters the main loop with a prompt of its own,
  and roost already wires `UserPromptSubmit` to `working`, so the pane leaves
  `blocked` before the real `Stop` arrives. The reviewers were right about the
  shape and the version does not have it; the bounded guard above covers it if
  that `UserPromptSubmit` ever stops arriving.
- **The path that LEAVES `blocked` is the one writer left that is not atomic.**
  Everything that stamps a dialog is now one tmux command — the transition and
  the repeat, from one function — and the `Stop` is an `if-shell`. The clear
  (`working`, `error`, `idle`) still reads `@agent_state` once near the top and
  unsets `@roost-blocked-on` and `@roost-stop-swallowed` in separate calls
  further down, so a dialog stamped in between would have its record cleared
  under it. Round 2 of the flock bounded the window at single-digit
  milliseconds and could NOT reproduce it at any gap, because the hook that
  would have to win the race is systematically the slower of the two. Left
  alone deliberately: the badge itself is written last and correctly, and
  making it atomic costs the `PostToolUse` hot path a second round trip on
  every tool call of every live agent.
- **A SUBAGENT's tool result no longer clears another agent's dialog, but the
  case behind it is not measured live.** Found by review (flock round 2) and
  reproduced at hook level: a background agent finishing a tool fires
  `PostToolUse` on the MAIN pane, and `working` cleared the 🛑 a DIFFERENT
  agent's dialog had stamped there — badge gone, description gone, `send`
  exit 0 into the open dialog. `--tool-hook` now reads `agent_id` and ignores
  a subagent's tool event while the pane is blocked. What is NOT measured is
  the live shape it needs: **two** background agents at once, one holding a
  dialog while the other finishes a tool. The rig drives one subagent at a
  time. Queued dialogs — a second dialog arriving while the first is still
  open — are unmeasured for the same reason.
- **A sibling tool's `PostToolUse` cannot clear a live dialog on 2.1.278.**
  Found by review (flock round 1): an auto-allowed `Read` in the same assistant
  message as a `Bash` that needs permission would badge `working` over the
  dialog's 🛑. Measured both orders on the account-free rig. Read first:
  `PostToolUse` for the Read at 1790061947.304801, then `PermissionRequest` at
  1790061947.407430 — the badge is set last and survives. Bash first: only
  `PreToolUse` and `PermissionRequest`, and the Read's `PostToolUse` does not
  arrive until after the dialog is answered. Claude runs a batch up to the
  first tool that needs permission and then stops, so there is no sibling event
  while a dialog is open. Not defended against in code; it would come back if
  that changed.
- **`acceptEdits` is clean; `bypassPermissions` is not measured.** The event
  fires only when a dialog would actually be drawn, so it cannot badge a pane
  🛑 with nothing on screen: measured on 2.1.278 with
  `--permission-mode acceptEdits`, an Edit ran with `PreToolUse` and
  `PostToolUse` and **no** `PermissionRequest`, and no dialog. The same check
  for `bypassPermissions` was not completed — its one-time "Yes, I accept"
  screen did not take a `send-keys Down` in the rig — and it is the mode whose
  whole point is that no dialog is shown, so the expected answer is the same.
- **The third dialog answer is the one #38 already measured.** On 2.1.278 the
  options are `1. Yes`, `2. Yes, and …`, `3. No` — there is no "No, and tell
  Claude what to do differently". `3` fires NO hook at all, on a Bash dialog
  and on an Edit dialog, and no `Stop` either, so the badge is cleared by
  `roost-unblock.sh` from the transcript exactly as an Esc is.
- **A codex subagent's Interrupt is not measured.** If codex fires
  `Interrupt` for a child while the parent turn continues, the parent pane
  would read 💤 idle mid-turn. Measured and ruled out: Esc at an idle codex
  prompt, fresh or right after a finished turn, fires no `Interrupt` (0.154.0,
  three presses), so a stray Esc does not drop a ✅ done pane or its reply.
- **Anything the transcript reader does not know stays blocked.** A background
  task finishing after the decline appends a `queue-operation` record, and so
  does a message queued mid-turn; either makes the tail unrecognisable. That is
  the intended answer to "cannot tell", and a new prompt clears it anyway.

### codex 0.157.1 runs every hook in one shared process: a second codex pane's badges land on the first (#141)

**Severity: high, and older than #141.** It affects every codex badge, not only
identity, on any machine running two codex agents at once on this version.

**What was measured** (codex-cli 0.157.1, tmux 3.6, macOS, 2026-09-30): one
throwaway `-S` server, its own `CODEX_HOME`, `HOME` and XDG dirs, a local model
through `tests/live/codex-tool-proxy.py`, and a logger on SessionStart,
UserPromptSubmit and Stop that wrote each payload's `session_id` and `cwd`, the
hook's `$TMUX_PANE`, and its process ancestry. Two codex TUIs in two windows —
panes `%1` and `%2`, the second started in a subdirectory — each sent one
prompt. The second TUI's three events carried ITS session id and ITS
subdirectory, and all three ran with `TMUX_PANE=%1`. Every hook's parent was
one `codex app-server --listen unix:// --managed-daemon` process, a child of the
FIRST TUI. So codex's hooks inherit the environment of whichever codex started
that app-server, and `roost state` badges that pane, whatever pane the turn
belongs to. One run; the mechanism (one parent process for both TUIs' hooks) is
what makes it more than a one-off.

**Two things seen around it**, recorded because the next person to measure will
trip on them: the app-server outlives `tmux kill-server` and needed `SIGKILL`
after a `SIGTERM`; and in one run it downloaded a NEWER app-server (0.159.2)
into the throwaway `CODEX_HOME/packages/` despite
`check_for_update_on_startup = false`. The real `~/.codex` on the measuring
machine had a 0.159.2 app-server running too, with parent pid 1 — detached, so
its `$TMUX_PANE` is whatever pane first started it, or none.

**What #141 did about it:** only the identity. `adapters/codex/roost-codex-hook`
skips identity when its parent's command line names `app-server`. So a codex
pane on this version should read four `null`s in `status --json` instead of
another agent's session — **inferred, not seen**: the guard is tested against a
stand-in parent script named `app-server`, and no live codex has run the final
hook. The badge is sent exactly as before. The upshot is that codex identity is
delivered for no version measured so far.

**What would close it:** a way for a hook to learn its own TUI's pane. Nothing in
the payload names the TUI or its terminal. Candidates to measure: whether the
TUI passes anything per-session to the app-server that a hook can see; whether
codex can be run without the shared app-server; or keying the pane from the
session id — the pane whose codex process owns that session's rollout file.

### A codex pane's 💥 error is inferred, and some dead turns still read ✅ done

Codex has exactly twelve hook events — `PreToolUse`, `PermissionRequest`,
`PostToolUse`, `PreCompact`, `PostCompact`, `SessionStart`, `SessionEnd`,
`UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt` —
enumerated out of the shipped binary and confirmed against live runs on 0.150.1
and 0.151.0. **None of them reports an error.** A turn that never reaches the
model still ends, and codex still fires `Stop`.

Until #39 that `Stop` badged ✅ done, and `roost wait-done` reported success on
a corpse. **A wrong `done` is the worst wrong badge there is: every other one
makes you look, and this one makes you stop looking.**

**What shipped (#39).** The adapter now reads the `Stop` payload itself and
splits it on `last_assistant_message`, a field codex genuinely sends:

| `Stop` payload | badge |
|---|---|
| parses, field is a non-empty string | ✅ done, plus the reply |
| parses, field is `""`, `null` or absent | 💥 error, previous reply cleared |
| does not parse, or no `python3` and no `jq` | ✅ done, as before |

The pane also carries `@roost-error-reason`, a fixed sentence saying the turn
ended with no reply. `roost wait-done` prints it under its usual
`is in error state, not done` line and exits 1. `tests/test-codex-hook.sh`
section 10 holds both directions: a dead turn is not `done`, a healthy turn and
the healthy turn after a dead one still are.

**This is an inference, not a report**, and it is named as one here and in the
Codex section of `site/content/docs/state-badges.md`. A codex 💥 means "the
turn ended with nothing to say", not "codex said it failed". What is still not
covered, most serious first:

- **Not re-measured live for this change.** The one fact the inference rests
  on — a dead turn's `Stop` carries an empty `last_assistant_message` — is the
  observation this entry recorded before #39, on 0.150.1/0.151.0. Its raw bytes
  were not kept, which is why all three spellings of "empty" are treated alike.
  The fixtures in section 10 are the real healthy capture with that one field
  edited, not captures of a dead turn. Re-capture on the current codex
  (isolated `CODEX_HOME`) before trusting the badge further than that.
- **A dead turn that had already said something still reads ✅ done.** If the
  stream dies after the model has produced text, that partial text is the
  `last_assistant_message`, and nothing in the payload says the turn was cut
  short.
- **A turn that ends with no reply for a reason other than dying would read 💥
  error**, with a desktop notification if its window is off screen. Two such
  routes are measured on *Claude Code's* `Stop`, whose payload codex matches
  field for field (`scripts/roost-agent-state`, the reply-clearing comment):
  the field present but empty on a turn that ended on a tool call, and the
  field absent on an interrupted turn. Neither is measured on codex. Both
  codex interrupts ARE now measured (#38, 0.154.0): Esc at a permission dialog
  and Esc while the model is still streaming each fire `Interrupt` and NO
  `Stop`, so neither reaches this inference; `Interrupt` badges `idle`. It is
  the cheaper wrong badge — it makes you look.
- **A machine where no JSON reader works gets the old behaviour**, a dead turn
  badged ✅ done. That is no `python3` and no `jq`, and also a `python3` that is
  on `PATH` but cannot run — the macOS `/usr/bin/python3` stub without the
  Command Line Tools — because the adapter, like `roost-agent-state`, does not
  fall back to `jq` once it has found a `python3`. Nothing is known about any
  turn there, and badging every one of them error would notify on every turn.
- **The reason is not always shown.** Two small holes, both on stderr only; the
  badge and every exit code are right in both. `roost read` checks for a reason
  on the pane its target resolves to, and a WINDOW target resolves to that
  window's active pane: when the dead codex pane is not the active one, `read`
  prints its old guess (*"no roost adapter, or its turn has not finished"*).
  `wait-done` does not have this hole, because it names the errored pane itself.
  And a pane that already reads `error` with no reason — a hand-typed
  `roost state error` — gets none from a following dead codex `Stop`: the
  unchanged-state bail in `scripts/roost-agent-state` returns before the reason
  is written, so `wait-done` prints only its one-line refusal.
- **No test runs the `jq` reader.** Every machine the suite has run on has
  `python3`, so the adapter's `jq` branch has been checked by hand only: against
  a string, `""`, `null`, an absent field, an array, a number, non-JSON and empty
  input, it agrees with the `python3` branch on every one.

The rejected alternative stays rejected: an unmatched `PreToolUse` (a live turn
whose tool call failed showed five `PreToolUse` against four `PostToolUse`)
mislabels a healthy turn, which the adapter contract's §1 rules out.

### A codex adapter can be installed, correct, and silently switched off

`adapters/codex/roost-codex-hook` only runs once a human has answered *"Trust
all and continue"* at codex's `Hooks need review` prompt. Until then all four
hooks are skipped, and **codex says nothing about it**. This is the complete,
unedited stderr of a `codex exec` turn with untrusted hooks wired:

```
warning: clamping SessionEnd hook timeout to 3s in <scratch>/cxhome/hooks.json
warning: clamping Interrupt hook timeout to 3s in <scratch>/cxhome/hooks.json
warning: Model metadata for `granite4.2:3b` not found. ...
codex
alpha
```

Warnings about timeouts. A warning about model metadata. Nothing about four
hooks being skipped. (The `Interrupt` line is gone now — roost asks for the 3
codex was clamping it to. The `SessionEnd` line came from the twelve-event
probe file that capture used, not from roost's five. Both are kept above
because they are what the cap was measured from.) Codex's own docs promise a startup warning pointing at
`/hooks` — true of the TUI, false of `codex exec`, which is where automation
lives.

**What that costs, precisely.** The same as the copilot entry below: an
unbadged pane is not `blocked`, so `roost send`'s exit-3 refusal never fires,
and a `send` aimed at a codex pane sitting at a permission dialog pastes into
that dialog and presses Enter on whatever is highlighted.

**Why it shipped anyway.** The gate is codex's and cannot be answered from this
side; `--dangerously-bypass-hook-trust` exists and roost does not use it or
suggest it. This is one of the only two steps `roost install` cannot do (see
the behaviour-change note below): the installer writes `hooks.json` and then
prints this step on every run, including the runs that wrote nothing.
`roost doctor` does the rest of what can be done — it reads the trust entries
out of `$CODEX_HOME/config.toml` and counts them, so "installed" and "will run"
are reported as the different claims they are.

**The residual risk doctor cannot see.** A trust entry stores a *hash* of the
normalised handler. roost does not know codex's normalisation, so four present
entries are not proof that four hooks will fire: a `hooks.json` hand-edited
after trust was granted keeps its entries and loses its hooks. roost's own
answer is upstream of doctor — `roost hooks codex` emits handler objects that
are frozen, so a roost upgrade is almost never the cause.

"Almost never" because it has happened once: the `Interrupt` timeout moved from
10 to 3. On a codex that hashes timeouts that upgrade is the one that can leave
a machine with five trust entries and four working hooks. It is not left
undetected — doctor reads the timeout out of `hooks.json` and warns while it is
still the old number, which catches every machine that has not run
`roost install` yet, and the installer then prints the trust step, as it does on
every run. The change was accepted because the behaviour on both sides of it is
the same 3 seconds: codex was clamping the 10 down all along.

**What codex hashes moved between versions, so measure it rather than quote
this.** `roost hooks codex`'s handler bytes were frozen on the strength of
0.150.1 and 0.151.0, where changing a single timeout from 10 to 11 took
handlers down. Re-measured on **0.154.0** through the `hooks/list` app-server
method, one scratch `$CODEX_HOME`, one field changed at a time, with a `Stop`
handler left untouched as a negative control:

| handler | change | `currentHash` |
|---|---|---|
| `Interrupt` | `timeout: 10` | `06e8ee7caa7ca69f664e4a…` |
| `Interrupt` | `timeout: 3` — one digit | `06e8ee7caa7ca69f664e4a…` (unmoved) |
| `Interrupt` | one argument appended to the command | `0db7877522cf5461c283b3…` (moved) |
| `Stop` | none | `5e9fc7fe549e9f615c9353…` throughout |

The third row is the positive control: the probe can still see a real change,
so the second row's stability is a fact about codex and not about the probe. So
on 0.154.0 a timeout is **not** hashed and a command **is**. That does not make
timeouts editable: roost cannot choose which codex a user runs, and a value that
is free on one version and silently fatal on another is not one to edit twice.

### A copilot pane can be badge-less, and nothing says so

`adapters/copilot/extension.mjs` only runs once **two** gates are past, and
neither one announces itself when it is not:

1. Copilot's extension system is behind a feature flag that is off by default.
   Without `copilot --experimental` or `{"enabledFeatureFlags":
   {"EXTENSIONS": true}}` in `~/.copilot/settings.json`, copilot does not read
   the first line of the adapter. **`roost install` writes that flag**, so a
   machine wired by it is past this one; a machine wired by hand may not be.
2. In interactive mode copilot asks the human, **once per directory**, to
   approve the extension — *"wants to: handle permission requests"*. Denying it
   prevents the extension loading. There is no global pre-approval, so every new
   worktree asks again. This is one of the only two steps `roost install` cannot
   do (see the behaviour-change note below).

In both cases the turn runs normally and copilot prints nothing about having
skipped anything. The pane simply stays unstamped, which roost renders exactly
like a shell.

**What that costs, precisely.** It is not only a missing badge. `roost send`
refuses a `blocked` target with exit 3 so that one agent cannot paste into
another's permission dialog — and an unbadged pane is not blocked, so the
refusal never fires. A copilot pane whose extension never loaded, sitting at a
permission prompt, will take a `roost send` straight into that dialog and press
Enter on whatever is highlighted.

**Why it shipped anyway.** Both gates are copilot's, not roost's. The flag is a
switch in the user's own config, so `roost install` now sets it — that half is
no longer manual. The consent is a TUI answer that persists nothing unless the
human picks "always allow in this directory", and no tool can answer it from
here. `roost doctor` does what can be done — it reads `settings.json` for the
flag and prints the exact fix, and it states the consent gate rather than
inferring an answer to it (`AGENTS.md` §9, and the same discipline the adapter
contract's T6 sets out). The install stanza in
`site/content/docs/state-badges.md` names both before a user trusts the badge.

### pi's `blocked` rides on an undocumented internal, and would fail silently

`adapters/pi/roost.ts` reaches `blocked` by wrapping the four blocking dialog
methods on `ctx.ui`. That works — and reaches *other* extensions' dialogs, which
is the whole point, since pi raises none of its own — only because `ctx.ui` is a
getter returning **one shared object** for every loaded extension
(`dist/core/extensions/runner.js:458`, pi 0.81.1). Verified live end to end: a
separate gate extension called `ctx.ui.confirm`, and the adapter badged the pane
`blocked` with the dialog on screen.

**That sharing is not a documented contract.** If pi ever gives each extension
its own `ctx.ui` — a reasonable isolation change — the wrap keeps working for
dialogs roost itself raises (none) and stops seeing everyone else's. There is no
crash and no error. The badge simply never appears again.

**What that costs, precisely.** Only users who have installed a permission gate
of their own are exposed, because a stock pi has no dialogs at all. For them the
failure is the "silently stuck" one the adapter contract's §3 names: the pane
reads `working` while a human stares at a prompt, `roost next-blocked` does not
find it, and `roost send` pastes into the dialog and presses Enter on whatever is
highlighted.

**Why it shipped anyway.** The alternative is not to offer `blocked` for pi at
all, and the mechanism was verified working against the shipped build rather
than inferred. `tests/live/pi-smoke.sh` asserts `blocked` against a real dialog
raised by a real second extension, so a pi upgrade that breaks it turns a silent
gap into a red test — that test is the mitigation, and it has to be run after
every pi upgrade for the mitigation to be real. The durable fix is upstream: a
`dialog_open` / `dialog_close` event would make this a supported integration
point rather than a reach into an internal.

### A `pi -p` or `--mode json` pane is never badged, on purpose

`adapters/pi/roost.ts` reports nothing unless `ctx.hasUI` is true — interactive
and RPC mode only. A pane where a human types `pi -p "…"` themselves stays
unstamped, which roost renders exactly like a shell.

**Why.** pi's sub-agent pattern (its shipped `examples/extensions/subagent/`)
runs each sub-agent as a **separate `pi --mode json -p --no-session` process**,
and a child inherits the parent's `$TMUX_PANE` and loads the same global
extensions. Measured live on 0.81.1 from inside a roost pane: the child logged
`TMUX_PANE=%114`, `mode=json`, `hasUI=false`. Ungated, every sub-agent badges
its **parent's** pane — `working` when it starts and `done` when it finishes,
while the parent is still working — and publishes its own answer as the pane's
reply. That is the adapter contract's T1 with two OS processes instead of one,
so no in-process filter can see across it.

**What the trade costs.** A `pi -p` pane reads as "not an agent": `roost
wait-done` against it returns immediately because it is never `working`, and
`roost read` falls back to scraping the screen with its stderr notice. A
coordinating agent that treats `pi -p` as a fleet member gets chrome where it
expected an answer.

**Why it shipped this way.** A wrong `done` from a sub-agent is worse than a
missing badge from a one-shot command, and there is no third signal available:
the child is indistinguishable from a hand-typed `pi -p` except by the one
property that says a human is attached. Tier 0 covers the gap —
`roost state working && pi -p "…" && roost state done` — and
`site/content/docs/state-badges.md` prints that line in the pi section.

### An opencode pane on a retrying-but-alive provider wears `error` mid-turn

`adapters/opencode/roost.js` badges `error` at the second `retry` of a turn and
then holds it. `RETRY_THRESHOLD` is 2 (`adapters/opencode/roost.js:38`), the
count is raised in the `retry` branch (`:323-325`), and the `busy` branch is
gated on `retries < RETRY_THRESHOLD` (`:319`) — so once the threshold trips,
nothing reports `working` again until the turn ends. The gate is deliberate and
the comment above it is right: opencode re-announces `busy` before every retry,
so an ungated `busy` would flap the badge working/error around the whole retry
loop and re-notify on each cycle (`:293-305`). `session.idle` resets the counter
and stamps `done`.

The threshold was tuned against a **dead** provider, where the retries never
stop and `error` is correct and useful. A **rate-limited but alive** provider is
indistinguishable from a dead one until the turn ends — so on a free tier, where
retries are routine, a pane wears `error` through most of a turn that is
working fine.

**Input:** an opencode pane on a free cloud model (OpenCode Zen,
`nemotron-3-ultra-free`), one ordinary turn.
**Wrong output:** the pane badges 💥 `error` for minutes while the spinner
animates, the context grows and tool calls land — and `roost wait-done` against
it exits 1 with `is in error state, not done` (`bin/roost:719-722`), reporting a
healthy turn as a corpse to whatever is coordinating it. One desktop
notification fires with it (`scripts/roost-agent-state:201-220`); `set` bails on
an unchanged state (`adapters/opencode/roost.js:208-212`), so it is one ping per
turn, not one per retry.

Measured from opencode's own log (`~/.local/share/opencode/log/opencode.log`),
five entries across roughly two minutes of one turn:

```
23:47:14 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:48:12 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:48:23 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:48:26 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
23:49:22 ERROR stream error  providerID=opencode modelID=nemotron-3-ultra-free
```

opencode retried each one and carried on. The turn was healthy throughout.

**This is a third shape of wrong badge, not either of the two already here.**
It is not the stranded `blocked` at the top of this section: that one needs a
human keystroke, never self-heals, and outlives the turn. It is not a stale
badge either — `@agent_since` advances and the adapter is still reporting. The
badge is *accurate about the turn as a whole* and wrong about the present
moment, which is the only thing a glanceable badge is for.

**Why it is a live risk and not a note.** It costs no keystroke to create — a
free tier produces it on ordinary turns — and the consumer that acts on `error`
acts on it wrongly: `wait-done` stops the moment it sees the badge, so a
coordinating agent abandons a turn that would have finished on its own.

**Why it is not worse than that.** It self-heals at the end of every turn:
`session.idle` resets the counter and stamps `done`, so nothing is left stranded
and no pane is unreachable the way a stuck `blocked` one is. It fails loud
rather than silent — the opposite direction from the codex wrong-`done` entry
above — and it costs one notification, not one per retry.

**The fix is deliberately not in this PR.** #27 is the installer; this is an
adapter change carrying its own risk, in the one code path that has already
produced a real bug here (see *opencode counts retries too* below). Two
directions, neither decided:

- Let a genuine sign of forward progress after the retries — a tool call,
  output tokens — return the badge to `working`. It preserves the dead-provider
  behaviour and kills the false red. It has to be a one-way latch within the
  turn rather than a plain reset of the counter, or it reintroduces exactly the
  flapping `:293-305` exists to prevent.
- Leave the logic alone and add a distinct state meaning "struggling but
  alive", reserving `error` for actually dead. That is a new entry in the state
  vocabulary — glyphs, `wait-done`, notifications, the adapter contract — so it
  is by far the larger of the two.

### A space in the checkout path silently un-wires every claude hook

**Input:** install roost into a path containing a space, e.g.
`/opt/My Tools/roost`.
**Wrong output:** the hook command is written into `settings.json` unquoted, so
the shell that runs it splits on the space and tries to execute `/opt/My`. The
hook never fires and the pane never badges. The merge itself returns rc 0 and
reports *"merged"* — nothing is printed anywhere. The same unquoted
interpolation is where a path containing a `"` would break the JSON document.

### The two JSON engines disagree about `{"hooks": null}`

**Input:** a `settings.json` whose `hooks` key is explicitly `null`.
**Wrong output:** which engine is installed decides what happens. `python3`
exits 1 with a raw Python type error as its message; `jq` exits 0 and writes
the file successfully. A user hitting this gets a different outcome on two
machines with the same roost, and the python message names an internal type
rather than the file.

### The other-checkout refusal is checked at plan time, not at write time

`scripts/roost-install` refuses to edit a config wired to a different checkout,
but only while building its plan. The symlink write loop re-checks
`roost_adapter_state` immediately before each `ln -s`; the JSON write loop
calls `roost_json_merge` with no such re-check. A config that becomes
another checkout's between the plan and the write is edited anyway. Small
window, small fix, listed so it is not rediscovered.

### A hardlinked settings.json is silently disconnected

**Input:** a `~/.claude/settings.json` that is a hard link (link count 2), as
some dotfile setups produce.
**Wrong output:** the merge writes a temp file and `mv`s it over the target,
which replaces the inode. The link count drops to 1 and the other name now
points at the old content. Nothing warns. The atomic write is deliberate and
correct for the crash case, so this is a real trade rather than an oversight —
but an unwarned one.

### A mis-quoted default in the patch argument

One default in the merge path is a 14-byte string where an object was meant.
It is inert today because every live caller passes the argument explicitly, so
the default is never taken. Recorded because "inert today" is a property of
the callers, not of the code.

### Nothing confines an extension once it runs

**A live risk, and a deliberate one.** `roost ext` installs code from a git
repository and runs it when you type its command. Roost pins the commit and
asks first; it does not sandbox what runs. An extension can do anything the
user can — read any file, use any key, reach the network.

Real containment means a `sandbox-exec` profile on macOS and something else
entirely on Linux: large, platform-specific, and out of scope for a tmux tool.
Naming it as absent is the honest position, and every piece of user-facing
wording has to survive that. Nothing roost prints may read as a verdict on an
extension's code, and the word "safe" must never appear in it.

### `needs` is a declaration, not a boundary, and cannot be made one

**A live risk about what the field means, not a defect in it.** A manifest
declaring `"needs": ["fleet"]` is given `ROOST_SOCKET`, `ROOST_SOCKET_FLAG` and
roost's scripts on `PATH`; one that declares nothing is given none of them. That
withholding is real and it prevents nothing.

An extension is nearly always run from inside a roost pane, and such a pane
already carries the fleet before the dispatcher runs: `$TMUX` holds the socket
path verbatim, and `bin/roost` puts `$ROOST_HOME/scripts` on the session `PATH`
for every pane it starts. The default socket is the guessable name `roost`
besides. Scrubbing `$TMUX` and rewriting `PATH` would close the first two and
not the third: no arrangement of environment variables stops a program running
`tmux -L roost list-panes`.

So `needs` buys visibility at consent time (and again at `update`, when it
grows) and removes the convenient path. It does not buy prevention. The consent
block says so in as many words — *"An extension that did NOT ask can still reach
them if it tries"* — and the docs page says it again, because the value of the
field rests on users knowing its limit.

### `roost ext verify` does not cover the clone's `.git`

**A live risk, and the cost of a correct exclusion.** An installed extension
keeps a full `.git`, whose ref state changes on every fetch; without the
exclusion every ordinary git operation inside an extension would make `verify`
report a change that is not one. Measured: `git checkout -b` and `git gc` inside
an installed clone leave `verify` reporting `ok`, which is what we want.

What it costs: a payload written to `.git/hooks/post-checkout` or
`.git/payload.sh` inside an installed extension is invisible to `verify`, which
reports `ok`. That is honest — `ok` means "matches what was recorded", and
install recorded with the same exclusion — but it is a region of the tree
integrity does not cover. Nothing roost does today executes from there: the
dispatcher execs only `bin/roost-<cmd>`, every git call sets `GIT_DIR` to a
throwaway object database, and the wrapper forces `core.hooksPath=/dev/null`.
The docs page states the limit rather than implying `ok` covers everything.

### `install` and `verify` run whatever clean filter the user's gitconfig names

**A live risk, small, and it is the user's own code.** `roost_ext_tree_hash`
hashes an extension's tree with `git add`, and `git add` runs any clean filter
configured in the user's own `~/.gitconfig`. No blanket switch exists to turn
filters off, so both `install` and `verify` execute it. Measured: a filter
configured in the user's gitconfig ran three times during one install.

It is named because the consent block promises *"Nothing runs during install"*,
and that sentence is about the extension's code. Anyone tightening that promise
should know this is the one thing it does not cover. The docs page carries the
same qualification.

### The control-character refusal does not cover Unicode bidi formatting

**A live risk, narrow.** Manifest text shown at consent is refused if it
contains any C0 control character or DEL, which closes the ESC repaint that
made the consent block display a commit other than the one installed. It does
**not** refuse Unicode bidi formatting characters (`U+202A`–`U+202E`,
`U+2066`–`U+2069`).

Two free-text fields carry the exposure, and they are not equally visible.
`roost` (capped at 64) is **printed inside the consent block**, on the
`roost  >=A.B.C <D.E.F  (you have X)  ok` row; `description` (capped at 200) is
not in that block at all — `roost ext install` prints `repo`, `ref`, `commit`,
`contract`, `roost` and `claims` (`scripts/roost-ext:2091`–`:2104`) — and
surfaces only in `roost ext info`'s manifest dump. So this gap does reach the
consent prompt. Do not read it as leaving that prompt untouched.

What it cannot do is forge the commit row, and the reason is **per-line**: the
bidi algorithm resolves each line on its own, so no formatting character in the
`roost` row or in a `description` can reorder any other line, including the
`commit` row above it. The exposure is one line reordering itself.

Left open rather than closed because refusing the class would refuse legitimate
right-to-left text, and a tool that cannot describe itself in Arabic or Hebrew
is a worse outcome than a line that can reorder itself. Named as absent rather
than implied closed.

### The two JSON engines disagree about a leading-zero `contract`

**A live risk, narrow.** `contract` is the one hard gate in an extension's
manifest: a version this roost does not speak refuses the install. Which JSON
engine is on the machine decides whether a leading-zero contract passes it.

**Input:** a manifest whose `contract` is written `001` (also `01`, `0001`).
**Wrong output:** on a machine with `jq` and no `python3`, that reads as
contract `1`, matches `ROOST_CONTRACT`, and the extension installs. On a
machine with `python3`, the same manifest is refused before the gate is
reached, with *"could not be read as JSON"*. Same roost, same repository, two
outcomes.

A leading zero is not valid JSON — python3 is right and jq is lenient. The
divergence cannot be closed in the engines: by the time either expression sees
a number, jq has consumed the literal and `001` is indistinguishable from `1`
in its value model. Closing it would mean roost carrying its own JSON parser,
or refusing every number, and neither is worth it for a manifest nobody writes
by hand twice.

Not an escalation — a contract of `001` is a contract of 1, and an extension
that installs this way gets exactly the authority its `needs` declared and the
consent block showed. What it costs is the promise that two users comparing
notes get the same answer. Every other number form was made to agree (see
`roost_ext__manifest_py`'s `json.load`); this one is named as absent rather
than implied closed, and `tests/test-ext.sh` asserts the **divergence**, so it
turns red if either engine ever changes.

### `roost install` reads back its own TAB row with the fields shifted

**A live risk that is benign today — and pre-existing, not from the extension
branch. It is recorded here rather than fixed there.**

`scripts/roost-install` emits a seven-field TAB row at `:781` (and `:784`) whose
sixth field, `json_dead`, is **empty on every ordinary install**. It reads that
row back at `:995` with:

```sh
while IFS="$TAB" read -r h real cfg kept replaced dead label; do
```

Tab is IFS whitespace, so `read` squeezes the two consecutive tabs and every
field after the gap shifts left by one: `dead` receives the label text and
`label` receives nothing. Measured on the exact producer and consumer strings:

```
row:  h<TAB>real<TAB>cfg<TAB>1<TAB>0<TAB><TAB>roost's four Claude hooks
read: dead=[roost's four Claude hooks]  label=[]
cut:  -f6=[]  -f7=[roost's four Claude hooks]
```

Why it is benign **today**: `label` is never read in that loop, and `dead` is
passed on only as `${dead:+"$dead"}` to `roost_json_merge`, where a deaddir of
`roost's four Claude hooks` matches no hook command and changes nothing. It
stops being benign the moment `label` is used, a label string starts resembling
a hook command, or the deaddir match loosens.

`scripts/roost-switch` produces TAB rows the same way but consumes them with
`cut -f` (`:85`–`:87`), which does not squeeze, so it is unaffected. The same
class of bug was found and fixed inside the extension branch, which is how this
one was noticed. The fix here is to read with `IFS=` unset over `read -d` — or
to stop emitting an empty interior field — and it belongs in a branch that owns
`roost-install`.

### `wait-done` sees a dead agent only through tmux facts, and three cases slip past

**Fixed by #54 for the common case.** `roost wait-done` reads two tmux facts on
every poll, beside `@agent_state`: whether the pane still exists (from
`list-panes`), and `#{pane_dead}`. An agent pane that closes, or whose process
exits, while its badge reads `working` or `blocked` now exits **2** with a
`died` message naming the pane. A target already gone when the wait starts
also exits 2, with `is gone`. A window target gives the same answer.

**What was measured** (tmux 3.6, throwaway `-S` servers, a stand-in agent and
Claude Code 2.1.272 killed mid-turn; SIGTERM and SIGKILL behaved the same):

| how the agent died | pane after | `pane_dead` | badge | before #54 |
|---|---|---|---|---|
| launched as the pane's command (`roost spawn NAME CMD`), killed | gone | — | — | **exit 0 at once** |
| `kill-pane` / `kill-window` | gone | — | — | **exit 0 at once** |
| `remain-on-exit on`, killed or exited | stays | 1 | `working` | whole timeout, exit 1 |
| launched from a shell prompt in the pane, killed | stays, at the prompt | **0** | `working` | whole timeout, exit 1 |

The first two were worse than a hang: `display-message -p -t %GONE` exits 0
with every format empty, so a vanished pane read as "no badge", which read as
done. `list-panes` exits non-zero on a missing target, which is why it is the
one used now.

**What is still not covered, most serious first.**

- **An agent killed inside a shell was not detected.** Fixed by #64 wherever
  the agent's hook recorded its job — see the next section for what that
  covers and the two cases it still misses. The pane stays alive at a prompt,
  `pane_dead` stays 0, and nothing rewrites the badge — Claude fires no hook on
  SIGTERM either. The only tmux fact that changes is `#{pane_current_command}`
  (Claude's reads `2.1.272`, then `bash`), which is a process NAME: comparing it
  to a shell would call a working agent dead whenever its own process is a
  shell, a wrapper script or `bash -c`. That comparison is still not made.
- **A one-shot agent that finishes and closes inside one poll reads as died.**
  `claude -p` in a `roost spawn` window closed its pane 531 ms, 1297 ms and
  1348 ms after its badge read done (three runs). `wait-done` exits 0 for a pane
  it saw `done` before it closed, and polls every quarter second rather than
  every second so it lands in that gap. A gap under 250 ms would still be
  reported as died. Not seen in a measurement, but not ruled out. In a window
  with a `blocked` sibling the gap can be wider than a tick: once a second the
  loop hands that sibling to the #38 unblock helper, which reads a transcript
  tail, and a pane that turns done AND closes during that call was never seen
  done. A pane seen done before the call is safe — the history is rebuilt from
  that read, and a test pins it — so only the finish-and-close inside the
  helper's own run time is misreported.
- **`is gone` cannot tell "finished, then closed" from "died".** A pane that
  closed before the wait started leaves no badge to read. The message says so.
- **A window target cannot see an agent pane that closed before the wait
  started, if another pane keeps the window open.** The window exists, the
  closed pane is not listed, and there is no record it was ever there, so the
  window reads as having no busy agent and exits 0. A `%N` target on that same
  pane exits 2.

### `wait-done` sees an agent that died inside a shell only through a recorded job

**Fixed by #64.** When a hook stamps `working` or `blocked`,
`scripts/roost-agent-state` records the job that holds the pane's terminal —
its process group — in `@roost-agent-job`, as `PGID:PANE_PID`. `wait-done`
exits **2** on a busy pane when that job has no process left **and** the pane's
shell holds the terminal again, with a `died` message that says so. A window
target gives the same answer. The design and every measurement behind it are in
`docs/airig/specs/2026-09-15-agent-identity-design.md`: at every hook call
measured, on Claude, codex, opencode, pi and copilot, the terminal's foreground
job was the agent's job. `tests/test-wait-done-shell.sh` pins the cases below.

**Two cases it misses, both on purpose, both a timeout and never a false
`died`.** `wait-done` counts a job as gone only when no process of it is left.
That strict rule was chosen over a quicker one (below).

**1. A Claude killed in the middle of a reply is caught only when its
`caffeinate` helper exits — up to about five minutes later.** While a reply is
running, Claude starts `caffeinate -i -t 300` inside its own process group, and
that helper outlives Claude. Measured (tmux 3.6, Claude typed into
`/bin/sh -i`, killed with SIGKILL mid-reply):

| Claude | shell had the terminal back | no process of the job left | `wait-done` |
|---|---|---|---|
| 2.1.272 | yes | `caffeinate -i -t 300` still in the job 76 s later, reparented to pid 1 | `wait-done %0 60` timed out, exit 1 |
| 2.1.273 | 0.08 s after the kill | 305.23 s after the kill | — (timing run, no waiter) |

So a `wait-done` whose timeout is shorter than that still exits 1, exactly as
before #64; a longer one exits 2 once the helper exits. A Claude killed
*between* replies has no helper running and is caught at once. codex, opencode,
pi and copilot were measured with only their own process in the job mid-reply,
and were caught within 0.10 s (codex: `wait-done` exit 2 in 0.56 s).

The quicker rule — "the job's first process is gone and the shell holds the
terminal" — would catch this Claude case in one poll. It was not taken because
it calls an agent that restarts itself as a child and exits "died" while the
agent still runs (measured with a stand-in; no real harness was seen doing it).

**2. A wrapper that outlives its agent.** If the agent
runs under a script that keeps running after the agent dies — it starts
`claude` without `exec`, then sleeps or waits for something else — the wrapper
is still a live process of the job, and the shell never gets the terminal
back. Measured with Claude under a wrapper that runs `sleep 600` after it:
Claude killed, the job still held two processes. `wait-done` waits its timeout
and exits 1, as before #64. It never reports a false `died`. A wrapper that
exits when its agent exits is caught.

**No record, so exactly the #54 behaviour (a timeout, exit 1):**

- the agent is the pane's own command (`roost spawn`) — #54 already sees that
  pane close;
- the agent was started in the background with `&`, or by a shell without job
  control;
- `roost state working` typed at a prompt: the stamp's own process leads the
  job and exits at once, so it names no agent. A stamp made through a `roost`
  shim that does not `exec` would lead the job instead, and *would* be recorded
  and then reported died — not measured, and not a path any adapter uses;
- a hook running inside a container, which cannot see the host's pane process;
- a pane stamped by an install older than #64.

**Not measured, inferred:** a pane whose command is a login wrapper rather than
the shell. The shell's job is then not the pane's process, so rule 2 never
holds and the pane times out. `opencode attach` records the attach client's
job, which is the thing in the pane.

A record left by an earlier agent cannot report a later one dead: while any
other job holds the terminal the pane is not died, and `respawn-pane -k`, which
keeps pane options, changes the pane process the record names, so the record
is ignored.

**`send` and `read` clear it too, since #105 step 5** (2026-10-25). The check
moved into one function, `roost_died_pane` in `scripts/lib/roost-unblock.sh`,
which `wait-done`, `send` and `read` all call; on a death it **unsets** the
badge, the job record, the dialog records and the hold, and writes
`@roost-ended "<stamp> died"` (the design's recovery channel: unset only).
`wait-done` still exits 2, and a later `wait-done` on the cleared pane exits 2
from the record, saying the agent "exited inside its shell before its turn
finished". `status` does **not** call it (the human's Q6): it shows what is
stored, so a dead agent's pane reads `working` there until one of the three
looks at it. `tests/test-died-shared.sh` pins each of these. What it leaves:

- **The dead turn is filed with its own word, `died_in_shell`** (fix round 1;
  the first cut filed nothing, and a second `wait-done --turn N` then timed
  out, found by review and reproduced). The turn file is empty, or the held
  main reply, as the interrupt recovery files it, so the next prompt is
  numbered after it (§5.4). `wait-done --turn N` exits 2 (`died`) and
  `read --turn N` says the agent "exited inside its shell before the turn
  finished" -- never #188's background-work sentence.
- **The dead turn's number is reserved in the clear** (fix round 2; found by
  review, reproduced with forced schedules). The file lands after the clear,
  and a replacement agent that reported and finished inside that gap took
  turn N, so the death became N+1; one that reported before the clear was
  read back made the clear look refused, and the death was never filed. The
  clear now uses #188's mechanism: the number goes into the clear's own tmux
  command as `@roost-turn-reserved`, a clear that landed is told by its
  token and files its turn even when a newer turn superseded it, and the
  newer turn's pointer is left alone. `tests/test-died-shared.sh` forces both
  schedules. What is left is #188's own gap: a hook killed between the clear
  and the file costs the number, never the outcome.
- **A replacement that starts before anyone looks** (fix round 2; found by
  review). With no `send`, `read` or `wait-done` on the dead pane, the
  replacement's first report came through the sink's stale-job check below,
  restamped, and filed nothing, so its first reply took the dead prompt's
  number. The sink now files the dead turn as `died_in_shell`, with the held
  main reply when the pane was held for the old stamp, before it restamps,
  under a number reserved the same way. The claim also unsets the old
  turn's hold record and owner, so the dead Claude's late SessionEnd (#188)
  finds nothing to release. Measured on the parent commit: with B's stamp in
  the same second as A's, that late SessionEnd DID release B's live turn,
  because the stamp, the hold and the owner all still matched
  (`tests/test-session-end.sh` section 11, records off). Cost, counted with
  logging wrappers on one restamping report: 13 tmux calls with records on
  and 8 with records off, against 5 before; 2 `ps` either way. Only that
  report pays it, once per replacement. It rests on job_gone's premise, that
  the recorded job IS the agent's: a harness that handed the terminal to a
  child job at a busy stamp and kept running after that child ended would
  have its live turn filed as died. No harness has been measured doing
  that. This filing raised what a wrong stale verdict costs: before it, a
  live agent whose recorded job looked dead (that harness shape, or a
  `kill -0` refused with EPERM on a group holding another user's process)
  only got a harmless restamp; now its live turn is filed `died_in_shell`
  and its hold released, so `wait-done --turn N` exits 2 on a turn still
  running and the real reply lands at N+1. That is what makes a future
  harness measurement matter. Fix round 3 (found by review, reproduced
  both): the check now runs for any busy report over any busy state, so an
  agent that died BLOCKED and a replacement whose first report is `working`
  is filed too, where before only the same state onto itself was; and a
  claim a concurrent clear refused no longer releases the clear's
  reservation of the same number. The claim's job-record unset is needed
  and tested: a clear that passed job_gone before the replacement was
  typed, and whose command lands after the claim but before the transition
  path re-records the job, matched on all three fields without it, unset
  the live replacement's badge and filed a second death
  (`tests/test-died-shared.sh`, "job unset"). Still open: the sink's claim
  writes no `died` line to the event log (only the clear does, through
  roost_events_unblocked, which needs an empty badge), so after a
  replacement that started before anyone looked, `roost events` shows two
  `working` lines and never the death. The turn record has it.
- **A replacement agent at the same prompt wins against the clear** (fix
  round 1; found by review, reproduced). A new agent typed at the prompt
  after the first one died, reporting `working` onto a pane that still read
  working, was a repeat to the sink and wrote nothing, so the clear's
  compare still matched and the live agent's badge was cleared. The sink now
  treats a busy report over a job record with no process left as a
  transition: it re-records the job and restamps. That costs the hot path
  one builtin `kill -0` (measured: none, "The report filter", above), and
  the one restamping report a `ps` and two tmux calls.
- **A `send` to the cleared pane types into the shell.** There is no agent
  behind the pane any more, so the text reaches the shell at its prompt and
  runs there, as it did before the badge was cleared (then too, a `working`
  pane let the send through). `send` does not refuse such a pane; whether it
  should is not decided.
- **A held pane keeps its main reply** on the pane, and only the hold record
  goes: the reply is the dead turn's own answer, and `read` prints it and says
  the agent died. It is also the filed turn's text (above).
- **A death already recorded is reported at once by a later `wait-done`.**
  The clear takes the badge and the job record, so a later wait cannot use
  job_gone; it reads the `died` record instead, once a second, for an
  unbadged pane, and exits 2 without waiting for a busy sibling in the same
  window. That applies to SessionEnd's `died` (#188) too, which before waited
  for the rest of the window. Not with `--turn N`: the record describes the
  pane's newest turn, not turn N, whose sidecar answers instead. The read is
  one `display-message` per UNBADGED pane per second while a sibling in the
  window is busy (found by review): nothing for a single pane, but a window
  of many idle panes and one busy one pays it for each idle pane.
- **`send --when-idle` offers the pane too** (fix round 1; found by review,
  reproduced). Its hold polled only the badge, so a dead agent held the send
  for the whole bound and it exited 6 saying the pane "still reads working".
  The hold now offers the pane to `roost_died_pane` and then
  `roost_interrupted_pane` (#95's Esc, the same shape) once a second, as
  `wait-done` does. Cost, counted with a logging `tmux` wrapper on a live
  working stand-in and a 4 s bound: 28 tmux calls, 6 a second while held --
  the poll, two in `roost_died_pane` (its snapshot, then the pane-scope
  state) and three in `roost_interrupted_pane` -- plus 4 once per send; no
  `ps`. Dropping the snapshot's `#{@agent_state}` field would save no call:
  the pane-scope read is the one that counts (a format resolves window and
  global values too), and the snapshot is still needed for the rest.
- **The event log has a line for the replacement** (fix round 2; found by
  review). A stale-job report is now logged as a new turn starting from no
  state, so the log no longer reads the dead agent's `working` and the
  replacement's `done` as one turn.
- **The event log names the clear** ("the agent exited inside its shell"),
  through the same `@roost-unblocked` token the two transcript recoveries use.

### opencode 2: the adapter ships with gaps, and the wiring fix has three holes (#150, #154)

**A live risk. High for the one case below it does not reach; otherwise low.**

Two separate things, and the second was the dangerous one.

**No badge (#150) — fixed by the adapter.** `adapters/opencode/roost.js` is an
opencode 1.x plugin, and opencode 2 refuses it at load. opencode 2 now has its
own adapter, `adapters/opencode/v2/tui.js`, which `roost install` links at
`~/.config/opencode/plugins/roost`. Its design is
`docs/airig/specs/2026-10-02-opencode-2-adapter-design.md`; §6 there is where
these gaps come from. **Low each, except the third, which is medium for a
script:** the badge and `roost read` follow the chat on screen, and that is
where most of them come from.

- **A hidden tab** that is working, blocked or failed shows nothing until it
  is brought to the front.
- **After a tab switch `roost read` has no reply for the pane** until the chat
  now in front finishes a turn. It says so and shows the screen.
- **A turn that finishes while its chat is hidden records no reply at all.** A
  coordinator that sent the prompt with `roost send` and waits with
  `wait-done --turn N` waits until its timeout if a person tabbed away in that
  pane mid-turn.
- **After a reload, a finished chat reads `idle` with no stored reply**, until
  its next turn. Measured: editing the plugin file reloads it in every open
  terminal, and the reload runs `setup` again. Not measured: whether a roost
  update does that. roost installs a symlinked plugin DIRECTORY, so an update
  changes the link's target, and a change to the target is the case that was
  not tried (design §2.6). If an open opencode's badge stops changing after an
  update, restart it. The adapter's `setup` writes the pane in full because it
  cannot know whose badge is on it. The same for an evicted chat brought back
  to the front. opencode's `status()` cannot tell `done` from `idle`.
- **A dialog answered or opened while a `permission.sync` is failing** is seen
  one pass late.
- **A reload inside one `roost` call.** A write the old instance had already
  handed to `tmux` can land after the new instance's first tick, if `tmux`
  takes more than a second to act on it. The pane then shows the old
  instance's state until the next event. Not designed around.
- **Killing nothing on reload** means the old instance's last call finishes
  normally — up to its 5-second timeout if `roost` is wedged.
- **A front change is seen up to a second late**, or at the next event. For
  that second the badge and `roost read` describe the chat that was in front.
- **No badge without `roost install`** on opencode 2. `roost wiring` does not
  reach it (the next part of this section says why). 1.x keeps its no-setup
  wiring.
- **A missed end-of-turn event pins `working`.** Low; not observed. The
  adapter takes a chat's phase from its own record whenever it has one, and
  asks opencode's `status()` only for a chat it never heard. If the event
  that ends a turn (`succeeded`, `failed`, `interrupted`) for the chat in
  front never arrives — a dropped connection, or compaction, which was not
  measured (design §2.9) — the record keeps `working`, so the badge stays
  `working` and `wait-done` waits until its timeout, or until the chat's next
  event.
- **Two turn ends inside one pass can replace the owed reply.** Low; not
  observed. When the front chat's turn N ends, the adapter keeps the reply it
  owes in `due`, and the next pass writes it. If a queued prompt's turn N+1
  also ends before that pass returns, `due` is overwritten, not queued
  (`adapters/opencode/v2/tui.js:273`). A pass can wait up to 2 s for each
  family member in `ask()`, or 5 s in a `roost` child. Reply N is then never
  written, and the pane's turn numbers shift by one, so `roost wait-done
  --turn N` waits on the wrong turn. It needs two turn ends inside one pass.
  The fix is a one-element queue, left for a follow-up.
- **The `opencode` first on PATH chooses the install.** Low. `roost install`
  asks that one binary its version. On a machine with 2.x first on PATH that
  still runs 1.x by absolute path, the install removes roost's 1.x link at
  `plugin/roost.js`. A 1.x in a roost pane still badges through roost's
  wiring; a 1.x anywhere else that relied on the link does not. The run
  prints the `ln -s` that puts the link back.
- **A retrying-but-alive provider** reads `error` mid-turn, as on 1.x — the
  entry "An opencode pane on a retrying-but-alive provider wears `error`
  mid-turn" above, carried over unchanged.
- **Inferred, not measured: a user's own `OPENCODE_CONFIG_DIR` may hide the
  link.** `roost install` links under `${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/roost`
  and does not read `OPENCODE_CONFIG_DIR`. opencode 2 reads a directory named
  there *instead of* `~/.config/opencode` (measured, below). If it also looks
  for plugins only in that directory, a 2.x user who sets the variable
  themselves gets `opencode 2 plugin linked` from `roost doctor`, and "opencode
  badges come only from roost install", and a pane that never badges. On 1.x
  the same shape is harmless, because 1.x merges both directories. Whether 2.x
  discovers plugins from the directory that replaced its own was not measured.
- **Not measured** (the design's §2.9): `--standalone`, and a remote
  `--server`, with a terminal-side plugin; whether `OPENCODE_CLI_CONFIG_CONTENT`
  drops the `plugins` list in the user's own `cli.json`; compaction, a prompt
  queued behind a running turn, and a turn started from another client in a
  chat this terminal is showing; a terminal whose route is a subagent's chat; a
  retry that then succeeds; any event that says a chat was deleted; Linux, and
  opencode 2 on tmux 3.4; what a 1-second interval costs in the TUI.

**The 1.x adapter serves a stale reply after a turn with no answer.** Found by
the review of the opencode 2 design, and **not fixed** here. When a turn ends
by Esc, by Reject at a dialog (inferred from the 2.x recording; not recorded on
1.x), or with no prose at all, `adapters/opencode/roost.js` publishes nothing,
so the pane's stored reply is still the previous turn's.
The badge reads ✅ `done`, and `roost read` serves that older answer as this
turn's with no notice. The opencode 2 adapter clears the stored reply for each
of those endings. **Medium for a coordinator** that reads a reply after
`wait-done`: it acts on an answer to a question it did not just ask.

**The user's configuration was replaced (#154).** `roost wiring` set
`OPENCODE_CONFIG_DIR` in every pane. opencode 1.x reads that directory as well
as the user's own; 2.x reads it **instead**. Measured on 2.0.20 against 1.18.30
with the same files: under the variable, 2.x reported the wiring folder as its
config directory and ran a turn on the built-in default model, where 1.x ran it
on the model the user's file named. So an opencode 2 in a roost pane silently
lost the user's model, providers and **permission rules** — and with no rules
at all, 2.0.20 ran a shell command without asking.

`roost wiring apply` now asks the opencode on `PATH` for its version, does not
set the variable when that is 2.x, and removes one it set earlier. Checked end
to end against the real 2.0.20 binary: a new pane of a freshly wired server has
no `OPENCODE_CONFIG_DIR` and `opencode debug paths config` names the user's
directory, where the previous wiring gave the wiring folder.

What that does **not** reach:

- **A shell that is already open.** It was handed the variable when it started
  and keeps it. Nothing roost runs on the server can take it back. An opencode
  2 started there still ignores the user's configuration. `roost doctor`, run
  in that shell, says so and names `unset OPENCODE_CONFIG_DIR`. This is the
  high case: it is every pane of a server that was running before the upgrade
  to this roost, until each is closed or told.
- **An opencode that becomes 2.x after the server started.** The version is
  read once per `apply`, which runs when a server starts and on
  `roost wiring on`. Install or upgrade to opencode 2 on a machine with a
  long-lived roost server and new panes keep getting the variable until one of
  those happens. That includes a machine with **no** opencode at server start:
  absent takes the 1.x path, as it always did, so the variable is set.
- **A pane whose `PATH` finds a different opencode than the one `apply` saw.**
  The check uses the `PATH` of whoever ran `apply`: the process that started
  the server, or the shell `roost wiring on` was typed in — which is the very
  command doctor sends an opencode 2 user to. Two opencodes on one machine, one
  per major, is exactly the setup a careful upgrader has.

All three fail in the same direction — the variable is set where it should not
be — and `roost doctor` in the affected shell reports all three, because it
reads its own environment and its own `PATH`. None is detected by anything that
runs unasked.

**An opencode that will not say which it is gets no wiring.** The version check
is bounded: `opencode --version` is killed after five seconds (six at worst),
because it runs while a roost server is starting and an unbounded one was a
roost that could hang at start. Measured in a fresh directory, three runs each,
it took 0.29–0.52 s on 1.18.30 and 0.30–1.10 s on 2.0.20. An opencode that is
on `PATH` but prints no version, or is killed at the bound, is treated by
`roost wiring` as *not safe*: the variable is not set, and one roost set
earlier is removed. For a real 1.x that is a lost badge until `roost install`
is run, which doctor names. It is the cheaper mistake — the other one is this
section's bug — and it is a behaviour change: before, an opencode that printed
no version was wired. `roost doctor` still guesses 1.x for such a one, since a
wrong guess there costs a line of advice. Not measured: how often a loaded
machine pushes a real `--version` past five seconds.

**Not measured:** whether opencode 2's shared background server, started from a
roost pane that has the variable, carries the replaced configuration to
opencode windows outside roost. It follows from the server owning configuration
and inheriting its starter's environment; it was not run. Linux was not
measured for any of this.

The 1.x plugin link `roost install` makes is still made on a 2.x machine.
opencode 2 shows `1 plugin failed` for it; doctor names the `rm`.

### Roost's own wiring reaches claude and opencode only (#58)

**A live risk, low.** Phase 1 of #58 wires claude (a PATH shim, reached through
tmux `default-command`) and opencode (`OPENCODE_CONFIG_DIR`) in roost panes.
The design is `docs/airig/specs/2026-09-15-roost-owned-settings-design.md`;
its "Measured" section has the evidence for everything below.

What stays on `roost install`, and why:

- **codex.** `-c` can supply hooks, but codex ignores trust passed through `-c`,
  so trust still has to be written into `~/.codex/config.toml` by codex's own
  prompt. In a login zsh on the measured machine, Homebrew's codex also comes
  before a shim on PATH.
- **pi and copilot.** No variable adds an extension without also moving auth
  and sessions (`PI_CODING_AGENT_DIR`, `COPILOT_HOME`); `-e` and
  `--plugin-dir` are flags only. A shim loses to nvm (pi) and Homebrew
  (copilot) in zsh on the measured machine.

Holes in what did ship:

- **The shim is bypassed** by an alias to claude's full path, by a
  `default-command` in the user's own `roost.conf` (roost keeps it rather than
  replace it), and by startup files that put claude's directory ahead of
  roost's. The pane then badges only through `roost install`. `roost doctor` run
  in the pane names the path that won — except for an alias, which doctor
  cannot see: it runs in its own process, where the user's aliases do not
  exist. The PATH positions were measured on one machine's zsh and bash startup
  files; **fish was not measured**.
- **A pane with neither `ROOST_TMUX` nor `tmux` on PATH.** The shim then cannot
  read `@roost-wiring-enabled`, and `roost wiring off` does not reach a claude
  started there. It fails toward "on". Doctor warns. Every pane of a server this
  roost started has `ROOST_TMUX`, and most panes have tmux on PATH anyway.
- **One wiring directory per checkout, and they are not cleaned up.** Each
  server uses `~/.config/roost/wiring/<checkout id>/`, so a second server from
  another checkout cannot overwrite the file a running server's panes use (found
  in review). A checkout that is moved or deleted leaves its directory behind
  until `roost wiring remove`; the files are small. `roost wiring on` run from
  a DIFFERENT checkout re-points a running server at that checkout's
  directory: new panes get its hooks, panes already open keep the old ones. If
  the global install names the first checkout, doctor's "runs twice" row is
  the only thing that says so.
- **Two routes for two checkouts run every Claude hook twice.** Identical
  commands run once (measured with real user settings); a global install
  pointing at a different checkout is not identical. Doctor warns.
- **The opencode load guard is keyed on opencode's plugin input.** Measured:
  opencode loads the plugin twice when it is in both the user's plugin
  directory and roost's; the guard keeps the second load from registering
  hooks. The guard assumes both loads get the same `client` object or input
  object. Measured live on opencode 1.18.30 with a recording `roost` on PATH:
  roost's copy alone made 2 `roost state` calls in one turn, the guarded plugin
  in both directories made 2, and an unguarded copy in both made 4. A future
  opencode that builds a fresh input per plugin would bring the double report
  back, and nothing would say so. The guard also only protects copies that
  carry it: if the user's global plugin link names a checkout from before #58,
  and opencode loads that unguarded copy, roost's copy registers as well and
  every event reports twice. Doctor has no row for this.
- **A user's own `--settings` replaces roost's for that run.** The shim puts
  its `--settings` before the user's arguments. Measured on Claude Code
  2.1.272 with two `--settings` flags, each file carrying a stamp hook: only
  the LAST file's hook ran. So `claude --settings mine.json` inside roost runs
  with the user's file and without roost's hooks — no badge for that run, and
  never a double. Putting roost's last instead would silently drop the user's
  file, which is worse. `claude --settings <file> mcp list` works (exit 0, the
  same output as without it), so the position before a subcommand is fine.
- **`roost wiring off -t SESSION` affects new panes only.** A pane that already
  exists keeps the environment its shell started with; use
  `export ROOST_NO_SHIM=1` there. For opencode, measured by a reviewer on tmux
  3.6: after `set-environment -t o -r OPENCODE_CONFIG_DIR` with a global value
  set, a new pane in session `o` has no `OPENCODE_CONFIG_DIR` and a new pane in
  another session keeps the global one.
- **A `ROOST_NO_SHIM` in the shell that STARTS the server opts out the whole
  server.** tmux copies the starting client's environment into the server's
  global one, so every pane of that server runs claude without roost's
  settings until `roost wiring on`, which clears it. On a server that is
  already running, a caller's `ROOST_NO_SHIM` does not reach a new
  `roost spawn` pane. Doctor shows `· ROOST_NO_SHIM is set here` in such a pane.
- **A `claude` symlinked to the shim in an unmarked directory loops.** The
  shim's PATH walk skips only directories holding `.roost-shim`, so a user who
  links `shims/claude` into, say, `~/.local/bin` makes the shim find itself and
  exec itself forever, adding `--settings` each round. Roost never creates such
  a link. A guard comparing each candidate with the shim itself (`-ef "$0"`)
  would close it; not done in #58 because it was found in the last review
  round.
- **`roost wiring off` from a shell with a different `XDG_CONFIG_HOME` leaves
  `OPENCODE_CONFIG_DIR` set.** The check for "roost's own" value is computed
  from the caller's XDG/HOME, not from the `ROOST_WIRING_DIR` the server
  exported, so new opencode panes stay wired while the command says they start
  unwired. Doctor's opencode note has the same dependence. Found in the last
  review round; not fixed in #58.
- **The login shell is started with `-l`, not an argv0 of `-<shell>`.** tmux
  starts an unwired pane's shell with a leading dash in argv0; POSIX sh cannot
  set argv0, so `roost-pane-shell` passes `-l`, which sh, bash, zsh and fish
  accept. A shell without `-l` would not start as a login shell. Not measured
  with such a shell.
- **Outside roost, a `claude` found only through an empty or `.` PATH entry is
  not run by the shim.** The PATH walk skips those entries before the roost
  check, so a shim directory inherited onto PATH outside roost says "no claude
  found" where the shell would have run a `./claude`. Exit 127 either way; the
  argv is never changed.
- **A `claude` an agent starts inside its own pane is wired too**, exactly as
  the global install already wires it, and badges the same pane. #64 decides
  how a child agent in one pane is treated.

### Kept replies (#42): what the pane record does not cover

**Shipped:** each turn's reply is kept whole in
`${XDG_STATE_HOME:-~/.local/state}/roost/panes/<boot>/<pane>/replies/`, beside
the capped `@roost-reply`. `read` prints a reply past 12 KB whole, `read --turn
N` reads an earlier turn, a closed `%N` still reads its last reply, and `roost
forget` deletes them. Design: docs/airig/specs/2026-09-16-pane-record-design.md.
The pane option stays the truth: a file is printed only when it agrees with
`@roost-reply`.

What it does not cover. Each is low severity, and none reports a wrong reply as
right — the failure is always today's output.

- **A reply passed to `roost reply` as one ARGUMENT is still capped by the
  operating system.** Linux refuses a single argument of 131,072 bytes or more
  (`MAX_ARG_STRLEN`, which is separate from the far larger `ARG_MAX` total);
  macOS has no per-argument cap and gives out at the total instead. Measured:
  ubuntu:24.04, kernel 6.11.11 aarch64, `getconf ARG_MAX` 2,097,152 — 131,071
  bytes execs and 131,072 does not; Darwin 25.3.0 arm64, `getconf ARG_MAX`
  1,048,576 — 1,041,390 bytes accepted and 1,041,391 refused, the difference
  being the caller's own environment, so that second figure moves with it. The
  command fails before roost runs, so nothing is recorded and `read` falls back
  to the screen with its notice.

  `roost reply -` reads the reply from stdin and has no such limit. The
  opencode, pi and copilot adapters publish that way (#86) — which is what the
  cap used to break, since the largest Claude reply seen on the design machine
  was 24,675 bytes but a reply built from a file is not rare — and both `roost
  help` and the roost skill say to use stdin for anything past a few KB. What
  is left is a human or a script that passes a long reply as an argument
  anyway, and gets the kernel's message instead of roost's.
- **Trailing newlines and NUL bytes are still dropped**, before either store,
  because the reply passes through `$(...)` and a bash variable. A kept reply is
  whole in content, not bit-exact at the end.
- **Without a record, a reply still prints the way tmux rewrote it.** tmux 3.4
  stores `$` before a letter or `{` as `\$` (`$HOME` → `\$HOME`) and control
  bytes as `\ooo`; tmux 3.5a the control bytes. A tmux client that is not UTF-8
  (no UTF-8 locale, no `-u`, no `$TMUX` — a `roost read` from a plain shell)
  prints newline, tab, non-ASCII and control bytes as `_`. With a record, `read`
  serves the file while the pane still holds what the writer's read-back saw
  (the `.pane` sidecar), so those replies print as written; with none — records
  off, or a write that failed — they print as before. Found by CI on PR #84.
- **A turn file edited in place is trusted while the pane is unchanged.** The
  link between pane and file is the `.pane` sidecar, not the file's content,
  because the content cannot be compared exactly on tmux 3.4. Only a changed
  byte count under a truncation marker is caught.
- **A closed pane is readable by `%N` only, and only on the server boot that
  wrote it.** A window name for a closed window, or a pane from before a server
  restart, is not looked up: the `name` field that would allow it is reserved,
  not built.
- **A filesystem without hard links** (some network and FAT volumes) records
  nothing: the writer gives up at the first failed link, and the pane option
  works as before.
- **A hook that fires twice for one Stop** (two different command strings for
  one event, the #58 migration case) keeps the turn twice.
- **Removals are reported only where they are asked for.** `read --turn` names a
  pruned turn and the kept range, and `forget` lists what it removed. A closed
  pane's record swept after 30 days leaves `read %N` with today's gone-pane
  failure and no word about the sweep; a hint for it was dropped because it
  could not tell a swept record from one that never existed. No `roost doctor`
  line reports the directory's size yet.
- **A live server whose socket file was deleted reads as gone.** tmux answers
  "No such file or directory" for a socket that is not there, and the liveness
  check calls that gone, because tmux unlinks its socket when it exits. A /tmp cleaner that removes the socket of a
  server still running makes that server unreachable anyway, but `forget
  --gone` and the sweep would then remove its panes' records.
- **A shared home over NFS mixes hosts' records.** The boot key has no host in
  it. Host B asking about host A's record asks B's own server at the same socket
  path, gets another boot key, and calls A's live records gone. Not measured.
- **A record that cannot be checked is kept until a human removes it.** No
  socket recorded, a socket directory the caller may not look into (a locked
  parent, a sandbox), or a server that never answers within 2 seconds: `forget --gone` names such records and keeps them, and the
  sweep keeps them silently. `roost forget TGT` or `--all` removes them.
- **A record whose `schema` file was lost is removed by nothing.** Every delete
  path requires the schema file, so a directory of the right shape that roost
  did not write is left alone — and so is a damaged record. Delete its
  directory by hand.
- **The suite's leak check sees new pane directories only.** `tests/run.sh`
  looks for record directories created during the run whose socket is gone. A
  turn a test appended to a record that already existed, or a record whose test
  server was left running, would not be caught.
- **The sweep runs only when a new pane record is created.** A machine that
  never starts another agent never sweeps; `roost forget --gone` does it by hand.
- **`read --json` gained `"turn":null`** on every document without a kept turn.
  Additive under the #41 rule; a consumer comparing whole documents byte for
  byte would see it.
- **Pruning against a stale listing** could in theory give a turn a number
  already freed, out of order. It needs `ROOST_RECORD_KEEP` writes on one pane
  between one writer's listing and its link. Not reachable with one agent per
  pane; not tested.

### The agent's identity (#141): what it does not cover

**Severity: low, except the first two items, which are medium.** Most items
leave a field `null`, stale or less precise. The first two DO put a wrong
identity on a pane — a session that is not the pane's agent's, or a harness
that is no longer running — which is the failure the design set out to refuse.
The codex entry above is a third case, and there the refusal was built.

- **A nested headless agent replaces the pane's identity (medium).** An agent
  that starts another one from its own shell — a `claude -p ...` run by its
  Bash tool — passes on `TMUX` and `TMUX_PANE`, so that child's SessionStart
  is stamped on the parent's pane: its session id, its directory, its
  transcript. Nothing puts the parent's back, because the parent's own
  SessionStart does not fire again; `status --json` and the pane record name
  the child until the parent's next `/clear`. Reproduced by feeding the two
  payloads through `scripts/roost-session-context` in that order; that a real
  `claude -p` fires SessionStart with the inherited pane is from Claude Code's
  documented hook behaviour, not from a live run. Only `agent_id` (a
  subagent inside the same process) is filtered. #77 — one environment switch
  that silences a nested agent's hooks on every harness — is what would close
  it; checking that the hook's harness is the pane's own process is the other
  route.
- **The identity outlives the agent (medium).** Nothing clears the four
  options when the agent exits: Claude's SessionEnd hook (#188) acts only on
  a pane held by background work and clears none of them, and the other
  adapters send nothing at exit. A pane that went back to its
  shell keeps reporting the last agent's `harness`, `session_id` and
  `transcript`, and a codex started there next on 0.157.1 — which writes no
  identity (the entry above) — reads as the Claude that ran before it for its
  whole life. Found in review by reading the options after the last event; no
  real harness was exited. Closing it needs an exit signal per harness, or a
  check at read time that the pane still runs the recorded harness.
- **A pane identified before its first turn and never answering leaves a
  record with no `replies/`** (`schema`, `socket`, `session_id`, `cwd`,
  `harness`). The 30-day sweep finds its candidates by dating `replies/`, so
  such a record is never swept by age; only `roost forget` removes it. The
  sweep itself does run when identity makes a directory (fixed in review).
  Closing it: date the pane directory too, or make `replies/` at identify.

- **`cwd` is where the session started, not where the agent is now.** Measured
  on Claude Code 2.1.283: after a Bash `cd sub`, every later payload's `cwd`
  reads `sub`, but SessionStart does not fire again, and /clear's SessionStart
  reads the launch directory. The launch directory is also where the transcript
  is filed and where `claude --resume` must run, which is why it was chosen.
  Tracking the current one would need a stdin read on UserPromptSubmit — a new
  flag in the generated settings file and in `tests/fixtures/hooks-claude.txt`.
- **A codex pane is identified at its first prompt**, not at launch: roost
  registers no SessionStart for codex, and codex 0.157.1 fires its SessionStart
  only with the first prompt anyway.
- **opencode, copilot and pi were not measured live.** Their adapters read the
  session id and directory from each harness's documented API (opencode's
  `session.*` events and plugin `directory`, copilot's `session.sessionId`, pi's
  `ctx.sessionManager` and `ctx.cwd`), and `tests/test-identity-adapters.sh`
  drives them offline. What a new conversation inside one copilot does to the id
  is unknown, and copilot is identified once, at join.
- **opencode 2: measured on 2.0.29, two cases still not.** In a real roost
  pane, the chat in front was identified (`session_id`, `cwd` and `harness` in
  `roost status --json`), and a tab switch identified the new chat. Not
  measured: a chat that is deleted while it is in front, and two terminals on
  one opencode server. `tests/opencode2-plugin-harness.mjs` has no case for
  either.
- **opencode 2: the `cwd` is where the TUI was started**, not the chat's own
  directory. The adapter passes `process.cwd()` of the terminal-side plugin,
  which runs in the TUI process; a chat opened on another project from that
  TUI is reported with the TUI's directory.
- **opencode 2: a hidden tab's chat is not the pane's identity.** The pane is
  identified as the chat in FRONT, re-identified when the front changes, and
  left as it was on the home screen. A chat that keeps working in a hidden tab
  is never the pane's `session_id`. After a switch the pane still names the
  chat that was in front until the change is seen: usually within the
  adapter's one-second tick; longer while an earlier pass is still waiting on
  opencode (up to 2 s on a sync) or on roost (up to 5 s on a call).
- **opencode 2: a failed identify is not tried again.** The adapter calls
  `roost identify` once per change of the chat in front. If that one call
  fails or times out, the pane keeps the previous chat's identity until the
  front changes again. This is on purpose: a value roost refuses would
  otherwise be sent again every second.
- **Only a changed identity rewrites the pane record.** A record removed by
  `roost forget` while the pane lives is written again only when the session,
  directory, harness or transcript next changes.
- **No python3 and no jq: no identity for Claude Code or codex.** The same
  degradation every payload reader in the hooks has; badges are untouched.
- **A path that is not UTF-8** is stored rewritten as `\ooo` by tmux 3.4 and
  3.5a (scripts/lib/roost-jsonout.sh's header), so it never compares equal and
  every event rewrites it. Harmless, but not the one-read cost the rule promises.
- **The record directory is created by a copy** of `roost_record_append`'s
  lines in `scripts/lib/roost-identity.sh`, because that function also writes a
  turn. A shared `roost_record_ensure` in `scripts/lib/roost-record.sh` would
  close it; that file was outside #141's lane.

### The event log (#98): what it does not cover

`roost events` is new, so nothing that worked before is at risk. These are the
places a reader of the log can still be wrong. Severity is stated on each.

- **A server that stops writes no `closed` lines. Low.** `kill-server`, or a
  server that dies, runs no tmux hook, so nothing is left to ask which panes
  went. Closing the LAST session is the same case, because the server exits
  with it: measured with a `run-shell -b` logger on all four close hooks, tmux
  3.6 ran no hook job at all, whether the session was killed or its only
  pane's program exited; tmux 3.4 ran `session-closed` for a kill and nothing
  for an exit. A reader learns it from `--follow` ending, which it does when
  its server stops. Closing it: a `closed` line for each open pane of the old
  boot, written the next time anything reads or writes the log and finds that
  boot gone (roost_record_liveness already answers the question).
- **A pane whose lines have rotated out gets no `closed` line. Low.** The
  close check takes its candidates from the lines still kept, so an agent
  pane that stays `done` while the rest of the fleet writes more than
  ROOST_EVENTS_KEEP lines (5000 by default, so 6250 at most) is no longer
  known to it, and closes silently. A reader that built its pane list from
  `status --json` and the log keeps that pane for ever unless it checks
  `status --json` again. Closing it: keep each open pane's newest line through
  rotation (copy it into the new segment when one is made), or have the check
  take the pane list from a per-boot file of panes that ever wrote a line.
- **The close check reads the server's environment, not the agent's. Note.**
  `roost events --reconcile` runs from tmux's `run-shell`, which has the
  environment the server started with. A `ROOST_EVENTS` or `ROOST_RECORD_DIR`
  exported only in the shell an agent runs in, after the server started, puts
  the agent's lines in one log and the close check's search in another, and
  no `closed` line is written. Closing it: record the log's directory in a
  server option the first time a line is written, and have the check read it.
- **A second codex dialog in a row writes no `blocked_on` line when codex's
  hook runs in its shared app-server. Low.** Since #142 the codex adapter
  passes its PermissionRequest payload, so a codex dialog has a description
  like Claude's. But when the hook's parent is codex's shared app-server
  (#145), the adapter sends a flagless `blocked` instead, because there the
  pane it names may not be the pane showing the dialog. That stamp carries no
  description, so nothing says the dialog changed. Closing it: #145.
- **A line can land in a segment a reader has already left. Low.** A writer
  lists the segments, then appends to the newest. If another writer rotates in
  between — microseconds — the line goes into the segment just closed. It is
  not lost: it is in the log, and `roost events` without `--since` prints it.
  But a reader whose cursor is already in the next segment does not go back.
  `--follow` narrows this: it moves to a new segment only after it has existed
  for a whole poll, and reads the old one again first. Not seen in the
  200-writer test in `tests/test-events.sh`, which races four rotations.
  Closing it: a cursor that names the segment count as well, so a reader can
  re-read a closed segment's tail once.
- **A writer stalled across two rotations can recreate a pruned segment.
  Very low.** `>>` creates the file it cannot find, with the process umask, and
  that segment then sorts oldest. Needs a writer frozen between listing and
  appending while ROOST_EVENTS_KEEP/2 other lines are written. Closing it:
  check the segment still exists after the append and remove it if it is
  older than the oldest kept one.
- **`reason` holds the command a dialog asks about. Note.** It is the same
  `@roost-blocked-on` text #91 records (see the note for #93 in
  `scripts/roost-agent-state`), so `export TOKEN=...` typed by a model lands in
  the log. The file is 0600 in a 0700 directory, beside kept replies that hold
  far more. `roost forget --all` clears it; `forget TGT` and `forget --gone` do
  not, because cutting one pane's lines out would move every cursor after
  them. Closing it, if it matters: rewrite that pane's `reason` fields to `""`
  in place, which keeps every byte offset only if the text is padded, so it is
  not cheap.
- **The suite does not switch the log off by name. Low.** `tests/lib.sh` sets
  `ROOST_RECORD_DIR=""`, which turns the log off too, but a developer who
  exports `ROOST_EVENTS=/some/dir` would have every hook-driving test write
  there. Closing it: `export ROOST_EVENTS=""` in `tests/lib.sh`, beside the
  `ROOST_RECORD_DIR` line.
- **The line is written by an EXIT trap. Note.** `scripts/roost-agent-state`
  has no other; one added later would replace it silently and the log would
  stop. `scripts/lib/roost-events.sh` says so where the trap is set. Closing
  it: a test that fails when the hook sets a second EXIT trap.
- **It costs a state change 7.5 to 9.4 ms. Note.** Measured on macOS 26.3,
  tmux 3.6, bash 3.2.57: 80 working/done transitions through the real hook,
  38.1 / 39.0 ms each with the log off and 45.6 / 48.4 ms with it on, over two
  rounds. The forks are one tmux read, `date` and `wc -l`. The PostToolUse hot
  path does not reach the new lines: 13.0 to 13.4 ms per call either way, over
  three rounds in alternating order.
- **A stopped server's lines cannot be read. Low.** `roost events` prints only
  the lines of the server it is talking to, by boot key, and exits 2 when none
  is running. The lines stay in the file until they rotate out. Closing it: a
  `--server BOOT` option.
- **The one-line usage `roost` prints for an unknown command does not list
  `events`. Low.** `roost help` does. Closing it: add `events` to that line in
  the `*)` fallback of `bin/roost`.
- **Two lock directories left behind stop closes being logged. Low.** The
  close check takes over an old lock under a second, short-lived one. If a run
  is killed in the few system calls between making that second directory and
  removing it, while it was taking over a lock another killed run had left,
  both stay: every later run waits five seconds and gives up, and no `closed`
  line is written until both directories are removed. Found in review, by
  setting the two directories up by hand; not seen to happen. It needs two
  runs killed, the second inside a very small window. Closing it: treat the
  second lock like the first, and take it over when it is old.

### `roost close` (#143): what it cannot see yet

`close` types a harness's exit command into a pane, waits for the agent to
leave, then kills that one pane. Four things it cannot do, and one it may get
wrong. None of them closes the wrong pane or answers a dialog: the worst case
of each is a refusal or a timeout (exit 1, the pane left open), or, for the
last one, a keypress into the wrong screen.

- **An exit dialog is caught only if the harness badges it `blocked`.** The
  stop-and-say-so rule reads `@agent_state`. The tests prove it with a
  stand-in that stamps `blocked`. No real harness was driven into an exit
  dialog: Claude Code 2.1.285 and codex 0.157.1 both quit at once even
  mid-turn (measured; scripts/lib/roost-close.sh has the numbers). A harness
  whose exit dialog fires no hook leaves `close` waiting out its bound, then
  exiting 1 with the pane open. Severity: low — slow, not wrong. What would
  close it: drive Claude with a background shell running and see whether
  `/exit` asks, and whether a hook fires.
- **Three rows of the table are not fully measured.** copilot's `/exit` is
  read from `copilot help commands` (1.0.83), not run: it needs a signed-in
  account. opencode (1.18.30 and 2.0.29, the 2.x terminal in a real roost
  pane) and pi (0.81.1) were measured at rest only; what they do mid-turn is
  not known. On opencode 2 the exit command ends the whole terminal, every
  chat tab in it; the chats live on its server and are not lost. `close` refuses a working pane, so
  this matters only under `--force`, which types nothing anyway. Severity:
  low. What would close it: run each with a model configured.
- **The harness is guessed until `@roost-harness` exists.** #141 adds the
  option and `close` already prefers it. Until then it is the process name
  (Claude Code's is its own version, such as `2.1.285`; codex and opencode use
  their own names) and then the pane name the adapters give an unnamed pane.
  pi and copilot run as `node`, so a pi or copilot pane that a human renamed
  is refused as "cannot tell" unless `--force`. Severity: low — a refusal
  that names its way out. What closes it: #141.
- **A turn that starts between the check and the keypress.** `close` reads the
  badge, then types. Another agent's `roost send` landing in that gap would
  get `/exit` typed into a working agent, which (measured above) quits at
  once and loses the turn. The gap is the ~0.3 s of the two-step type.
  Severity: low, and the same race `send` has with a human typing.
- **A startup screen can take the Enter.** Measured by accident while
  building this: codex 0.157.1 showed an update prompt at start, and an
  Enter meant for its input box chose "update now" and began a real package
  upgrade (killed before it finished; nothing changed). `close` only types
  into a pane with a badge, and a badge normally means the harness is past
  its start screens, but nothing proves that. Severity: low, and real. What
  would close it: the harness's own session-start signal (#141) as the gate
  instead of any badge.
- **A job stopped with ctrl-z is killed with its pane, unasked.** An
  interactive shell that holds the terminal, a leftover `done` badge, no
  recorded job, and an agent suspended in the background: `close` sees only a
  shell, types nothing, and closes the pane, which ends the stopped job too.
  "Only a shell holds it" is true of the terminal, not of the pane. Found in
  review, on a throwaway server with a stopped `sleep`. Severity: low — a
  stopped agent cannot read an exit command anyway, and the case needs three
  unusual things at once. What would close it: count the shell's child
  processes before deciding nothing is there.

### Who sent a prompt (#56): what the `sent_by` sidecar does not cover

`roost send` keeps who sent each prompt beside the turn it started, as
`replies/NNNNNN.sent_by` in the pane's record: the `--from LABEL`, else
`pane:%N` for a send from a pane on this server, else `human`. The label is
written when the turn BEGINS, because that is when `send` knows the turn's
number; the reply that becomes the turn file arrives when the turn ends.
Three things follow, none of which changes what is pasted or whether a send
succeeds.

- **The first prompt into a fresh Claude pane keeps no label.** `send` only
  watches for a turn, and so only numbers one, on a pane that wears a badge
  (its own rule: no badge means not an agent). Claude's SessionStart hook
  injects context and stamps nothing, so a pane straight from `roost spawn
  claude` has no badge until its first prompt, and that prompt — a
  coordinator's brief, usually — is not numbered and gets no sidecar. Every
  later prompt does. Harnesses that start on a badge (opencode 2 at adapter
  load, codex after an interrupt) keep the first one too, and
  tests/test-send-turn.sh section 13a pins that path. Severity: low — one
  known turn per Claude pane, always the first. What would close it: a
  SessionStart stamp of `idle` from the Claude adapter (#141's session-start
  signal is the natural place), after which `send` watches from the start.
- **A turn that lives through an opencode retry loses its label.** A turn
  that ends with no reply — an API error, an interrupt — is never recorded,
  so the number `send` predicted goes to the next turn. Its label does not go
  with it: scripts/roost-agent-state drops the pending sidecar when a NEW
  turn starts (a stamp of `working` from done, idle, error or no badge),
  before the badge moves, so a prompt typed by hand after a failed send reads
  `sent_by: null` and never the coordinator's name. The one case that pays
  for that rule: opencode's adapters stamp `error` on the third retry of a
  turn that is still running, and `working` again when the retry goes on,
  and from the hook that is a new turn. The label of a turn that survived a
  retry is dropped — `null`, not a wrong name. Severity: low — one missing
  label, only on opencode, only after a retry that then succeeded, and the
  record never says anything false. What would close it: the opencode
  adapters telling the hook a resume from a retry apart from a new turn,
  which they cannot today without a turn id in the stamp.
- **The label is a claim, not a proof.** `--from` takes any word; a sender
  can say it is someone else. The default `pane:%N` is checked against the
  server (the sending pane must exist here, and `$TMUX` must name this
  server's pid), but a caller that passes `--from pane:%3` from %5 is
  recorded as %3. Severity: low — the record is for a human's audit, and a
  pane that lies in it is a pane the human already runs. What would close it:
  nothing cheap; the envelope half of #56 can at least make the pasted text
  carry the checked default beside the claimed one.

### One send per pane (#175): what the send lock does not cover

`roost send` holds a lock on its target pane from before the first key to
after the turn watch: a directory beside the server's socket, with the
holder's pid in it (scripts/lib/roost-panelock.sh). A second send to the same
pane waits — `@roost-send-lock-timeout`, default 60 s — and then exits 1 with
nothing typed. A holder that was killed is taken over. Three things it does
not promise.

- **A live holder can be made to exit 1 for nothing.** No live lock is ever
  deleted: a stale lock or guard is moved aside by mv, its pid read back,
  and removed only on a match, else moved straight back. In the two
  syscalls between the move away and the move back, the live holder's
  `roost_panelock_check` (run before each paste, C-u and Enter) reads no
  pid file and the holder exits 1 with "the send lock was taken from this
  send", having submitted nothing. A third process can also mkdir the name
  in that gap, in which case the moved copy is removed and the holder stops
  at its next check the same way. Severity: low — it needs a taker killed
  between its mkdir and its rmdir (microseconds), and then a waiter whose
  read and mv straddle another's mkdir; the result is one spurious exit 1,
  which the documented retry covers. What would close it: a compare-and-swap
  on a directory, which the file system does not offer.
- **Between a check and its key there is one tmux call.** The check reads
  the pid file; the key is sent next — before the paste, before each C-u,
  between a C-u and its re-paste, and before Enter. A sender whose lock is
  taken in that gap, and whose box another sender then pastes into before
  the key lands, would press Enter on both texts. The gap is one tmux call
  with no sleep, and the other sender has to mkdir, write a pid, load a
  buffer and paste inside it. Severity: low, and the only path left to two
  texts in one box.
- **A holder SIGKILLed between its load-buffer and its paste-buffer leaves
  its message in tmux's buffer list.** Nothing runs on SIGKILL, the next
  send names a different buffer, and a takeover clears only the lock on the
  file system. The text sits in `prefix + =` until the server is restarted
  or someone deletes it. Severity: low — a SIGKILL inside a two-call window,
  and the message was the sender's own prompt.
- **`roost answer` takes the lock too, since #181**, just before its key and
  through its confirm wait, and exits 11 with nothing sent when it cannot
  hold it. What it does not do is clear a `send`'s abandoned draft: it types
  one key into a dialog, not text into an input box, and a draft left by a
  send that stopped is that send's to clear (it does, while it holds the
  lock).
- **A holder stopped for a minute between its mkdir and its pid write writes
  its pid into the taker's lock.** A lock with no pid file is "gone" once it
  is a minute old; a SIGSTOP in that microsecond window, held for a minute,
  lets a waiter take the lock, and the stopped holder then writes its own
  pid into the taker's directory. It is the TAKER whose next check then
  reads a foreign pid and stops; the stopped one carries on as the sole
  holder. Severity: low — still one writer, and the one that stops says so.
- **"Is it a roost" is `ps -o args=`.** A killed sender's pid reused by a
  process whose args happen to carry "roost" (a `roost status`, a shell in a
  directory named roost) holds the lock until that process exits; sends to
  that pane wait the bound and exit 1 until then. A `ps` that answers
  nothing is "cannot tell" and keeps the lock. Severity: low — bounded, and
  loud either way.

### `send --when-idle`: what it does not cover (#56)

`roost send --when-idle` polls the target's `@agent_state` about once a
second, before it takes the send lock, until the pane reads anything but
`working`; then it takes the lock, reads the state again under it, and drops
the lock and goes back to waiting if another sender got in first. Past
`@roost-send-idle-timeout` (default 300 s, at most 3600) it exits 6 with
nothing typed. Five things it does not promise.

- **A turn shorter than a second can be missed.** The poll is one second. A
  pane that goes working, done, working again between two polls is read as
  working throughout, and the send keeps waiting for the next gap. It never
  pastes into a pane that READ working; it can only wait longer than it had
  to. Severity: low — a later poll catches the next gap, and the bound is
  the worst case. Not measured against a real harness.
- **The read under the lock is the last look.** Between it and the paste
  there are a few tmux calls and no sleep. Another roost send cannot get in
  there (it needs the lock); a harness that stamps `working` on its own in
  that gap (a background task finishing into a new turn, a human typing in
  the pane) can, and the text then lands mid-turn as a plain send's would.
  The rest of the window is the send lock's, listed above. Severity: low.
- **Nothing waits on `blocked`.** A blocked target is refused at exit 3 with
  or without the flag, on purpose: a dialog is for a human to answer. A
  caller that wants "wait until it can take a prompt" must still retry exit
  3 itself. Severity: a note, not a defect.
- **The bound is the wait for `working`, not the whole command.** The lock
  wait after it has its own bound (`@roost-send-lock-timeout`, 60 s, exit 1),
  and the paste and turn watch take their usual time. So a held send can run
  past `@roost-send-idle-timeout` by up to a lock bound and a send. Two held
  senders at one pane: the second can wait on the lock while the first
  watches for its turn (up to `@roost-send-turn-timeout`, 10 s), well inside
  the lock's 60 s. Severity: low.
- **`waited` is in the `--json` document only with the flag.** Every other
  field of every document is always present; this one is absent without
  `--when-idle`, because the plain send must print exactly what it printed
  before. A program that reads `waited` must treat absent as "not held".
  Severity: a note.

### `send` takes a new paste placeholder as delivery (#176): what that does not cover

A long or multi-line paste is drawn by Claude Code, pi and opencode 2 as a
placeholder, not as the text, so `send` cannot find the message on the
screen. Since #176 it counts the placeholders of three known shapes —
`[Pasted text #N …]`, `[paste #N …]`, `[Pasted ~N …]` — before the paste and
after, and one more than before is proof the paste landed. A message that
itself holds one of those shapes never uses that proof: once a pane echoes,
the message is on the screen, and a cut tail that quotes a placeholder would
otherwise pass. Such a send is checked by its head only. Six things it does
not promise.

- **A shape it does not know falls back to the slow path.** A harness that
  changes its wording, or a new harness, gets the old behaviour: re-paste for
  the whole `@roost-send-ready-timeout` (15 s), print "accepted the keys but
  does not show them", and submit anyway. Loud and slow, not lossy. Severity:
  low. The pi and opencode 2 shapes come from #176 (pi 1.4.0, opencode
  2.1.3); this fix was tested against a fixture that draws them, not
  re-measured against the real harnesses.
- **A placeholder proves a paste arrived, not that all of it did.** The text
  behind it cannot be read from the screen. This is what Claude's placeholder
  always meant here; it now covers pi and opencode 2 too. Severity: a note.
- **An old placeholder that scrolls off as the new one appears hides it.**
  The count stands still and the send takes the slow path above. Severity:
  low — wrong only in the loud direction.
- **A placeholder from something else counts.** A human pasting into the
  same pane in the same second, or the harness drawing one for its own
  reasons, reads as this send's. Another roost send cannot: it waits on the
  send lock. Severity: low, not measured.
- **The pane's own output can print a placeholder shape.** An agent working
  on this code, a `git diff` in a shell pane or a `cat` of the changelog can
  print `[Pasted text #1]` or `[paste #1 +12 lines]` as text. If that output
  appears during the check window of a paste that did NOT land, the count
  rises and the send is taken as delivered: Enter is pressed on whatever is in
  the box, which may be nothing or a cut tail, with no warning. It needs a
  paste that failed and such output in the same seconds. Severity: low, not
  measured. What would close it: count only inside the input box, which
  roost cannot locate on the screen for every harness.
- **A message that quotes a placeholder shape gets the slow path.** On a pane
  that collapses the paste, such a send waits out `@roost-send-ready-timeout`
  (15 s), re-pastes and prints the "does not show them" warning, as every
  long send did before #176. This is chosen: the other way can submit a cut
  message silently. Severity: a note; loud and slow, not lossy.

### The subagent count is never reset (Phase 0 lane D)

`@roost-subagents` and `@roost-subagent-ids` go up on `SubagentStart`, down
on `SubagentStop`, and nothing else touches them. Not `SessionStart`:
scripts/roost-session-context sets no pane option at all. Not a pane respawn:
`respawn-pane -k` keeps every pane option. Not an agent exit: no hook fires
for a helper still out when its Claude quits, and whether `SubagentStop`
fires on session exit, a `/tasks` kill or an Esc'd turn is not measured (M10
of docs/airig/specs/2026-09-29-turn-over-design.md). So a Claude that ends
with a helper out leaves the count on the pane, and the next Claude in that
pane counts up from it: `roost status --json` then reports a helper that no
longer exists. Found in review on a throwaway socket: one `SubagentStart`,
then `respawn-pane -k` of the pane, and the count still read 1 with the old
id listed. Severity: low. The count never touches the badge, so nothing
waits on it; it is wrong only in `status --json`, and only after a helper
was left out. What would close it: clear both options on `SessionStart`, in
scripts/roost-session-context, which already runs there. Which of its five
sources should clear is that follow-up's first question: `startup` and
`clear` plainly should, and `compact` fires mid-session with helpers
possibly still out. Not done in lane D, whose spec did not ask for it.

### Past 32 subagents at once the count is a limit, not a promise (Phase 0 lane D)

The id list on the pane (`@roost-subagent-ids`) is capped at 32 ids and the
count (`@roost-subagents`) is not, so from the 33rd subagent RUNNING AT ONCE
some running agents are unlisted. From there the hook cannot tell an
unlisted running agent from an id it has never seen, and three things
follow. None of them happens at 32 or fewer, and tests/test-agent-state.sh
("past the cap") pins each so a fix must change the test on purpose.

- **A stop for an id that was never started changes the count.** While the
  count is above the list's length every stop counts one down, because the
  rule "a stop for an unknown id changes nothing" needs the list to say what
  is known. 33 starts and one stop for an id never started reads 32.
- **A repeated start of an unlisted id counts again.** A second
  `SubagentStart` for the 33rd agent, which is not listed, reads as a new
  agent: 34 for 33 running, and stopping all 33 leaves a ghost 1.
- **Concurrent starts can list a few more than 32.** The cap is read in the
  shell before the write, and the count is changed inside tmux; many starts
  at once can each see fewer than 32 and all append. Found in review: three
  trials of 40 concurrent distinct starts counted 40 every time and listed
  33, 32 and 35 ids.

The trigger is 33 or more subagents running at once in one Claude, a shape
no rig run has produced. The lane spec asked for two things that conflict
past the cap: an unknown stop that changes nothing, and a list that cannot
grow without bound; this cut keeps the bound and the count for honest
payloads, and gives up the unknown-stop rule only above it. Severity: low.
The count never touches a badge, so nothing waits on it; it is wrong only in
`status --json`, and only on a pane past the cap. What would close it: a
list whose cap is enforced inside the same tmux command as the count (so the
third case ends), and a count that is only ever the list's length (so the
first two end, at the price that the 33rd agent is not counted at all). That
is a different trade, not a fix to this one, and it is a follow-up.

### The deferred codex ping (#195): what it does not cover

A codex `blocked` pings after `@roost-notify-delay` seconds, from a child the
hook starts and leaves running (`roost_defer_blocked_ping` in
`scripts/roost-agent-state`). Tested on a throwaway server with fixture
payloads (`tests/test-codex-notify-delay.sh`), not under a live codex.

- **Not measured live: whether codex lets the child outlive the hook.** The
  child closes all three streams and runs in its own process group (`set -m`),
  so a caller that waits on the pipe or kills the hook's group leaves it
  alone. Codex 0.164.0's own source says that is how it behaves: its hook
  runner (`codex-rs/hooks/src/engine/command_runner.rs`, lines 302–307 and
  352–360 at tag `rust-v0.164.0`) turns process-tree cleanup off when a hook
  succeeds and, on a timeout, kills the hook's process GROUP, not its
  session; an upstream test (`completed_hook_preserves_background_descendant`
  in `command_runner_tests.rs`) checks that a detached descendant survives
  the hook. A probe on a throwaway server found the child in its own group,
  reparented to pid 1, holding only `/dev/null` on its three streams, with the
  hook back in 0.11 s. What is left is a sandbox that reaps every descendant,
  or a later codex that changes the runner; either would make the dialog ping
  NEVER rather than late. Severity: low — source and probe agree, but it is
  still not measured under a live codex. What would close it: one live codex
  run with an off-screen pane and a dialog left open past the delay.
- **A real dialog pings later.** Up to the delay, 5 s by default. That is the
  trade the setting makes; `0` restores the instant ping.
- **Two dialogs in one second are two dialogs.** Round 1 keyed the wait on
  `@agent_since`, which is whole seconds, and a review reproduced the cost: a
  dialog answered and a second opened in the same second shared the stamp,
  and the first one's child pinged for the second while it had been open for
  1.5 s of a 2 s delay. The wait is now keyed on `@roost-block-entry`, which
  changes every time the pane leaves blocked and comes back, inside any
  second. A ping always means one unbroken stretch of 🛑 as long as the delay.
  A dialog that opens while the pane already reads 🛑 (the rest of a parallel
  batch, or a second dialog over the first) is the same stretch: it does not
  restart the wait, and the batch gets one ping, on the first entry's
  deadline. Tests 1, 9, 10 and 11 in `tests/test-codex-notify-delay.sh`.
- **A dialog that opened while its window was ON screen schedules no ping.**
  The hook checks the window once, when the pane goes 🛑, and starts no child
  if the human is looking at it. If they then switch away and leave the dialog
  open, no ping comes. A dialog that opened off screen gets no ping either if
  the human switches to its window during the delay and away again: the
  child checks the window once, when it wakes, and stands down for good if
  the human was looking then. That is also what happened before #195, when
  the ping was instant or nothing. A later dialog in the same stretch that
  arrives while the window is off screen does start a child, so a batch can
  still ping (test 12). Severity: low — the human saw the dialog when it opened. What would
  close it: a pane-focus hook that re-arms the wait when the window leaves the
  screen, which roost does not have.
- **Auto-review that DENIES, then asks the human, is still a ping.** It
  arrives as a later dialog with a later stamp, which is the right outcome,
  but it waits the delay too.

## Behaviour changes

### `send` now writes a stderr line whenever it names no turn (#177)

Every `roost send` that submits the text and prints no `%N TURN` now adds one
line on stderr that starts `roost send: no turn number:` and says why. Stdout,
`--json` and the exit codes did not change. Two things to know, neither a
defect:

- **A send to a plain shell or a log tail gets the line every time**, as "has
  no badge yet". roost cannot tell a pane that is not an agent from an agent
  whose first turn has not started — both have no badge — so it says the
  second, which is the case that confused workers. A script that sends into a
  helper shell and treats any stderr as failure now sees a line where it saw
  none. Two tests in the suite asserted empty stderr on such a send
  (tests/test-coordination.sh, tests/test-send-paste.sh); they now take out
  that one line and still fail on any other. Severity: low. What would close
  it: a way to tell "never an agent" from "not yet", for example the Claude
  SessionStart `idle` stamp the `sent_by` entry above asks for.
- **The badge named is the one read before the paste.** A pane that was
  `working` when `send` looked and has finished by the time it returns is
  still reported as mid-turn, which is what decided that it was not watched.
  Severity: none; it is the honest reason for that send.

### Replies are kept on disk, and `read` prints long ones whole (#42)

Every recorded reply is now also written to a file under
`${XDG_STATE_HOME:-~/.local/state}/roost/panes/`, private to the user (`0700`
on the root roost creates and on every directory under it, `0600` files). The newest 100 turns per pane are kept
(`ROOST_RECORD_KEEP`), and a closed pane's turns are deleted 30 days after its
last reply (`ROOST_RECORD_DAYS`), when the next new pane record is made. So what
an agent said now outlives its pane, on disk, until then. `roost forget --all`
deletes every kept reply; `ROOST_RECORD_DIR=""` in the environment agents start
from keeps none.

`roost read` on a reply longer than 12 KB prints the whole reply instead of the
head and a truncation marker. On tmux 3.4, and from a shell without a UTF-8
locale, a reply with a record also prints as the agent wrote it instead of as
tmux rewrote it (`\$HOME`, `_`). Everything else it prints is unchanged —
measured byte for byte against the previous `read` on 23 invocations without
`--json`, on tmux 3.6 — except `read --json`'s added `"turn"` field.


### Claude and opencode in a roost pane are wired without `roost install` (#58)

**A note, not a defect.** A roost server wires the claude and opencode started
in its panes, whoever starts them, from files under `~/.config/roost/wiring/`.
Nothing is written to the user's own config. Every back-out route is on the
site's Setup page (`site/content/docs/setup.md`): `ROOST_NO_SHIM=1`, `roost wiring off [-t SESSION]`,
`@roost-wiring-enabled off`, and `roost wiring remove`.

Two visible differences in a pane: `default-command` is set to
`scripts/roost-pane-shell` (the pane still starts the user's login shell), and
`roost spawn`/`roost split` run their command through that script. Test
servers whose socket is not named `roost` are never wired.

### A moved or re-cloned checkout still needs codex wired by hand

**A note, not a defect — the claude half of this is fixed.** roost now asks
whether the checkout a hook names still EXISTS, which separates two cases that
used to look identical. A hook pointing at a checkout that is gone is roost's
own and broken, so it is replaced — the same treatment a dangling symlink has
always had. A hook pointing at a checkout that is still there belongs to
somebody who meant it, and is left alone.

`roost doctor` no longer reports the broken case as healthy. Its claude branch
compares the wired command against this checkout's own path, which its codex
branch had always done.

**Codex is still refused, on purpose.** Codex stores a hash of each hook
handler in `config.toml` and silently skips any handler whose hash no longer
matches — nothing on stdout, on stderr, or in the TUI. Rewriting one to point
at the new checkout would un-badge a machine that had already granted trust,
which is worse than leaving it. What changed is only the words: roost says the
checkout no longer exists rather than blaming "a different checkout", which
sent people looking for a checkout that was not there.

**What you do:** run `roost hooks codex` and copy the object into
`$CODEX_HOME/hooks.json` yourself, then answer codex's trust prompt.

### Wiring is part of installing now, and two prompts are all that is left

**A note, not a defect.** Pointing roost at your agents used to be a separate
manual step per harness. `curl … | sh` now does it in the same step as the
`PATH` line, and `roost install` (`roost update` is `roost upgrade`'s alias now)
is the re-run for later: a harness installed since, a moved or re-cloned
checkout, a release that adds an adapter. `roost install` does not fetch new roost code.

**The only two steps `roost install` cannot do are prompts**, and it prints
both on every run, including runs that wrote nothing:

- codex — *"Trust all and continue"* at its `Hooks need review` prompt.
- copilot — the per-directory *"wants to: handle permission requests"*.

Neither can be answered from this side, and neither leaves anything on disk to
detect, so both are stated rather than inferred. They are listed because they
are permanent, not because they are outstanding work. What each costs on a
machine where nobody has answered it is a different question, and it is a live
risk that stays above: *"A codex adapter can be installed, correct, and
silently switched off"* and *"A copilot pane can be badge-less, and nothing
says so"*.

### `bin/roost` now addresses the roost server you are inside

With `ROOST_SOCKET` unset, every `roost` subcommand used to address the shared
`-L roost` server no matter which server the caller's own pane was on. It now
resolves in three steps — `ROOST_SOCKET`, then the server it is running inside,
then `-L roost` — the same order `roost-status`, `roost-switch` and
`roost-notify` already used, via `scripts/lib/roost-socket.sh`.

**This is the fix for a live risk, not a new one.** It is what makes `roost
reply` land on a non-default server, where the badge already did.

Only a socket path ending in `/roost` counts as "inside roost", so `roost
spawn` typed from a user's everyday tmux still means the roost server. Nothing
changes for the default single-server install: `-L roost` resolves to a path
ending in `/roost`, so both steps name the same server.

### `roost wait-done` exits non-zero on an errored target

`wait-done` no longer treats "stopped being busy" as success. An errored pane
makes it print `roost: '<target>' is in error state, not done` and exit 1.

**Nothing shipped broken, and no existing usage can break.** Before this
branch the state vocabulary was `blocked working done idle` and anything else
normalised to `idle`, so a pane could not be in `error` at all — the condition
this exit code fires on was unreachable. `wait-done` would have called an
errored agent finished only in the window between the commit that added `error`
and the commit that taught `wait-done` about it, both on this branch. There are
no programmatic callers outside this repo's own tests, and the README's
`for w in ...; do roost wait-done "$w"; done` loop is not `set -e` guarded.

**If you script against it:** a non-zero exit now means *error or timeout*,
distinguished by the message. `skills/roost/SKILL.md` says so, because agents
read that file to coordinate, and one that assumed "non-zero means timeout"
would retry a corpse. A `set -e` script will now stop on a dead agent rather
than continuing — the intended improvement, but a change in flow.

Failing loudly is the safe direction. The unsafe direction is a wrong success,
and `wait-done` can only refuse one if nothing upstream of it reports a failed
turn as `done` in the first place — which is why `adapters/opencode/roost.js`
swallows the `session.idle` that follows a `session.error`.

### `roost wait-done` exits 2 on a target that is gone or died (#54)

A target that does not exist, or an agent pane that closed or whose process
exited mid-turn, used to exit **0** — a dead agent reported as finished — or,
with `remain-on-exit`, wait out its whole timeout. It now exits **2**, the code
`roost send` already uses for "the target is unusable". 0 and 1 keep every
other meaning. `site/content/docs/driving-a-fleet.md` carries the exit table and
`skills/roost/SKILL.md` the idiom.

**The one flow that changes:** a script that waited on a target it had already
closed, and read the 0 as success, now stops. That 0 was the bug. The live
risk above, *"`wait-done` sees a dead agent only through tmux facts"*, lists
what is still not caught.

### `roost doctor` names the roost version, and only the release (#47)

doctor's first line is `roost version: X`, asked of the same checkout's
`bin/roost version`, so the two cannot disagree. A missing or unreadable
`VERSION` prints `roost version: unknown (could not read <path>/VERSION)`. No
answer at all — `bin/roost` missing, or dying before it dispatches — prints
`roost version: unknown (<path>/bin/roost gave no version)`. It is a line of context, not a check: doctor's exit code is the
same either way, and `tests/test-doctor.sh` pins that for a passing and a
failing run.

**Not covered:** it names the release in `VERSION`, not the commit. A checkout
on a branch, or on `main` between releases, reports the last release number
while running code that release never had. A bug report from such a checkout
still needs `git rev-parse HEAD` asked for by hand.

### `roost wait-done` refuses a timeout that is not a whole number (#66)

`abc`, `1.5` and a number too big for bash's integers used to loop forever,
printing a bash error with the checkout's path four times a second. `-5` and an
empty string waited with no limit, silently. They are now refused at once with
exit 1 and a usage line that names the value.

**The flows that change:** an **empty** timeout — a script passing `"$T"` with
`T` unset — used to mean "no limit" and is now a usage error. A leading zero is
decimal: `010` used to wait eight seconds and now waits ten, and `08` used to be
a bash error. A value over 15 digits is refused; `timeout * 4` has to fit a
64-bit integer.

**Not covered:** words after the timeout are still ignored, as they always
were. `roost wait-done api 30 extra` waits 30 seconds and says nothing.

### opencode counts retries too, and we still count our own

`adapters/opencode/roost.js` hand-rolls a consecutive-`retry` counter.
opencode's `SessionStatus` carries `{type: "retry", attempt, message, next}`,
and `attempt` is upstream's own count. Measured on 1.18.20, two dead-provider
turns in one TUI session (`tests/live/opencode-smoke.sh` case 2 prints this):

```
    turn ended: attempts [1, 2, 3, 4, 5]
    turn ended: attempts [1, 2, 3, 4, 5]
```

So `attempt` is per session, increments once per retry, and restarts at 1 in
the next turn — the same rule our counter follows.

**Left as it is, and the entry it replaces overstated the prize.** Reading
`status.attempt` would not delete the counter: the `busy` branch is gated on
the count so the badge cannot flap during a retry loop, and `busy` events carry
no `attempt`, so a local number and its turn-boundary resets have to stay
either way. The change is one line (`retries += 1` becomes `retries = attempt`)
in exchange for a dependency on upstream's numbering, in the one code path that
has already produced a real bug here.

## Small deferred items

- **`roost identify` is not in the one-line usage string (#141).** It is in
  `roost help`, but the pinned usage line at the bottom of `bin/roost` (printed
  for an unknown command) was left alone, because every lane that adds a
  command wants the same line and it is settled once, at merge.

- **The unknown-subcommand usage line does not list `close` (#143).** `roost
  bogus` prints a one-line usage string naming every core command. `close` is
  not in it yet: tests/test-ext.sh pins that line byte for byte, so the two
  change together. `roost help` does list `close`.
  Severity: cosmetic. What closes it: add `close [--force] TGT [T]` to the
  line at the bottom of bin/roost and to its copy in tests/test-ext.sh,
  together.

- **The `prefix a` switcher's cursor keeps its position across a reload, not
  its row.** The list reloads every two seconds. If a pane opens or closes
  above the cursor in the moment before `Enter`, the jump lands on a
  neighbouring pane. Low severity: it needs that timing, the preview shows the
  row `Enter` will take, and a wrong jump costs one more `prefix a`. Left on
  purpose — fzf can follow a row by id (`--track --id-nth`), and on fzf 0.74.4
  that dropped `Enter` in 3 of 30 scripted tries, twice, against 0 of 30
  without it and 0 of 30 with no reload at all. Method: a throwaway `-S`
  server, the popup in a detached session, `Down` then `Enter` sent at a random
  0–1 s offset, success = the popup exited and the target pane was selected.
  Worth re-measuring on a later fzf; `scripts/roost-switch` holds the comment.

- **`--json` (#41): what shipped and what did not.** Shipped: `status`, `read`,
  `screen`, `whoami`, and `state STATE --json`, schema 1, specified in
  `docs/airig/specs/2026-09-15-json-output-design.md`. Not covered:
  - **`wait-done --json`.** Left out while #47/#66 and #65 change its argument
    parsing and exit codes. The design says what its document will be.
  - **A blank screen: the two modes disagree on the exit status.** `screen
    --json` and `read --json` exit 0 with `"text":""`, as the design chose.
    Plain `roost screen` and `roost read` exit 1 there, because `screen_dump`'s
    `grep -v` selects nothing under `pipefail`. That exit 1 is a bug of its own,
    to be filed separately; until it is fixed, the modes differ in this one case.
  - **gawk was never run.** The encoder was fuzzed with BSD awk, mawk and BusyBox
    awk. It sets `LC_ALL=C` for awk, which is what gawk needs to walk bytes, but
    CI runs mawk and BSD awk, which walk bytes in any locale — so a change that
    dropped that `LC_ALL=C` would stay green in CI and break on a gawk machine.
  - **On tmux 3.4 and 3.5a a reply is rewritten before anyone reads it.**
    Measured: those versions store a control byte, DEL, or a byte of invalid
    UTF-8 as escape text (`\001`, `\r`, `\377`) when `roost reply` or a hook
    records it, and do not escape a backslash, so it cannot be decoded exactly.
    `read --json` keeps the text as stored and says `"lossy": true` when it holds
    such a sequence on such a server (a literal `\033` in a shell snippet is
    flagged too: the flag means "may differ", not "did"). Plain `roost read` has
    printed the same escape text on those versions since the reply channel
    shipped; it is tmux's storage, not roost's output, and this change does not
    alter it. Pane names, window names and `error_reason` carry no `lossy` flag,
    so on those versions they are reported as tmux stores them.
  - **A writer that is not in a UTF-8 locale loses tab, newline and non-ASCII.**
    tmux 3.4, 3.5a and 3.7c store them as `_` when the client that writes the
    option runs in a non-UTF-8 locale (3.6 keeps them). `_` is an ordinary
    character, so neither mode can detect it. A hook environment without
    `LANG`/`LC_ALL` would hit this.
  - **A trailing newline in an option value is lost**, in `--json` and in the
    plain commands alike, because `$(...)` strips it.
  - **Invalid UTF-8 is replaced, not preserved.** JSON strings cannot carry raw
    bytes. `"lossy": true` says it happened; a lossless extra field (base64)
    could be added later without a schema bump.

- **No signature verification of an extension.** Pinning to a full commit SHA,
  and recording the tree hash `roost ext verify` re-checks, is the substitute:
  it proves what runs is what was agreed to, and says nothing about who wrote
  it. Deliberate for build 1.
- **No pattern screening at consent** (`curl | sh`, writes to `~/.ssh`,
  `~/.aws`, `crontab`). Deliberately absent. If it is ever added it must be
  *information only* — never a refusal, never a verdict, and never the word
  "safe". It would catch careless, not malicious, and a screen users believe is
  worse than no screen at all.
- **Extension events are contract 2, with no consumer yet.** Contract 1 is
  commands only. Roost's state hook already fires on every tool call, so events
  are reachable; shipping an event API with no consumer would have frozen its
  shape on the day it landed. The contract integer is what makes adding them
  later non-breaking.
- **`roost doctor` does not check extensions.** It reports nothing about
  `ext.lock`, a clone that is missing, or a lockfile that disagrees with
  `ext.index`. `roost ext list` warns on the disagreement and `roost ext verify`
  answers the integrity question, but neither is on the path a user takes when
  something is wrong and they reach for `doctor`.
- **The `roost` range parser handles three forms only** — `>=A.B.C <D.E.F`, `*`,
  and absent. Anything else warns "unparsable range, skipping check" and
  continues. Deliberately tiny: the field is advisory, so a fancier range must
  never be able to harden into a refusal. Whoever widens it inherits that rule.
- **`roost_test_tmux_named_guard` protects only the three test files that call
  it**, and cannot detect its own absence in a fourth. It refuses unless
  `TMUX_TMPDIR` is set, exists, and sits under a temp root — which is what keeps
  a `tmux -L <name>` in a test away from the live agents' socket directory — but
  a new test file that uses `-L` and forgets the call gets no warning from
  anything. Closing it mechanically is a CI grep for `tmux -L` under `tests/`
  with no nearby guard call; it has not been written.
- A `roost.conf` produced by the legacy migration **before** it learned to
  backfill `@roost-glyph-error` still predates the error state, and migration
  cannot re-fire on it (it only runs while `roost.conf` is absent — an
  existing one always wins, because a running amux server may still be reading
  the old file). Nothing writes that value on their behalf. `roost doctor` now
  names the missing line, the glyph being inherited, and the exact fix
  (`roost settings`, re-pick the set), which is as far as a read-only check
  goes.
- `tests/pi-extension-harness.mjs` imports the adapter's `.ts` directly, which
  needs node >= 22.18 (or >= 23.6) for unflagged type stripping. On an older
  node the whole file prints one `SKIP` line and exits 0 — the honest degrade,
  but a whole harness quietly not running is exactly the shape this file's own
  "green is evidence about the tests" lesson warns about. `.github/workflows/ci.yml`
  pins node so CI cannot land there; a contributor on an older node can still
  skip it without noticing. Shipping the adapter as `.js` was the alternative and
  was rejected: pi's discovery glob only looks for `*.ts` and `*/index.ts`, so a
  `.js` adapter is a file pi never loads.
- `tests/live/codex-smoke.sh` runs a harness that can modify the machine it is
  tested on. A codex TUI being driven inside an isolated tmux socket ran
  `brew upgrade --cask codex` and replaced the host's binary mid-test — the tmux
  socket, `CODEX_HOME` and the XDG homes were all isolated and all held; a
  system package manager is not something a scratch directory contains. The test
  sets `check_for_update_on_startup = false`, which is codex's own switch rather
  than a boundary roost enforces. Full write-up, and what it means for the next
  harness, in `docs/airig/issues/2026-08-29-codex-upgrades-its-own-host.md`.
- `roost validate` now reports adapter links from the installer's own record
  (`roost install --records`) rather than from the disk, which fixed two
  divergences between "is it linked" and "did this run link it". One shape is
  left, and it is wording in the report rather than anything the run does to
  the machine: a candidate the installer reached no verdict on — a write that
  failed, or an installer that could not start — lands in the same bucket as a
  path roost refused to touch, and §1 renders that bucket as *"Something that
  is not this checkout's adapter already sits at each path below"*, sending the
  tester to look for a conflicting file that is not there. Measured by making
  the write fail (`chmod 555` on the adapter's parent directory): the record
  line comes back `failed<TAB>opencode<TAB><path>`, and validate files anything
  that is not `wrote` or `unchanged` under `BLOCKED_LINKS`. Two things keep it
  small — the run prints `could NOT link <path>` on stdout as it happens, and
  §5 re-reads the disk, so for the same harness it says *"the adapter is not
  linked — run: mkdir -p … && ln -s …"*. The two sections disagree and the one
  carrying the fix is the correct one. Left because the honest fix is a fourth
  bucket in `report_install` ("this run could not link it"), a report change
  with its own test file, and because reaching it at all needs a directory
  roost can read but not write.
- **`roost upgrade` has no bound on its pull.** A fetch that hangs on a dead
  network hangs the command, and the user sees git's own output. `install.sh`
  has the same property. Severity: low; Ctrl-C ends it, and the gate has
  already run, so nothing is half-done. What closes it: a timeout around the
  pull in `scripts/roost-upgrade` and in `install.sh`, together.

- **`roost upgrade` reads `main` literally, not `origin/HEAD`.** A checkout
  whose default branch has another name is refused as "not main". Severity:
  low; roost publishes from one remote whose default is `main`, and the
  refusal names the rule and the curl line. What closes it: read the default
  branch from `origin/HEAD` in `gate_branch`, which adds a lookup that can
  itself fail.

- **A shell opened before an upgrade keeps `OPENCODE_CONFIG_DIR`.** `upgrade`
  re-applies wiring on the running server, which fixes every new pane, but no
  command can change the environment of a shell that already exists, so an
  opencode 2 pane opened before the upgrade still runs with roost's empty
  configuration. Severity: low; only `roost doctor` says so, per pane, and
  `unset OPENCODE_CONFIG_DIR` or a new pane clears it. What closes it:
  nothing roost can do from outside the shell.

- **A Claude hook written as `bash <other-copy>/scripts/roost-agent-state`
  reads as gone, not live.** A leading interpreter word defeats the match, so
  the hook is treated as a copy that no longer exists and install rewrites it
  even from a worktree, where a live copy's hook would be refused. Predates
  the relink work. Severity: low; it needs a hand-written hook, and the
  rewrite is the one install already makes for a gone copy. What closes it:
  strip a leading interpreter word before the existence test.

- **A gone copy's hook and a live third copy's hook in one settings file give
  the refusal the codex reason.** When the first roost command found is the
  gone copy's, install reports the "Will NOT edit" reason that explains why a
  codex handler is never rewritten (it would re-hash it and silently
  un-badge the machine), whichever harness the file belongs to. From a plain
  checkout the whole file is then refused and left untouched, so no takeover
  happens. Severity: low; a conservative refusal that writes nothing, with
  the wrong reason text. What closes it: pick the reason from every command
  the file holds, not the first, and let a claude file with a live third copy
  go through the relink path.

- **The hook probes derive the script names from the patch; the merge engines
  take them from the given script list.** Today both name the same two
  scripts. A third hook script would have to be added in both places, or the
  probe and the merge would disagree about which hooks are roost's. Severity:
  latent; nothing is wrong until a script is added. What closes it: one list
  that both read.

- **The install test that makes a link's parent directory read-only SKIPs as
  root.** `chmod 555` does not stop root from writing, and the Ubuntu
  container runs the suite as root, so the failed-relink branch is proven only
  on a developer machine. Severity: low; a Mac run covers it before a pull
  request. What closes it: still open. Running that one case as a non-root
  user in the container might work; it has not been tried, and making the
  parent immutable needs capabilities the container may not grant.

- **A copilot extension reached through a hand-made folder link gets
  install's generic note.** When `extensions/roost` is a symlink to
  `<other>/adapters/copilot`, the path roost wants is a regular file — the
  other copy's tracked `extension.mjs` — so `roost install`'s manual note says
  "it is not a symlink — look at it first, move it aside yourself". `roost
  doctor` has a line of its own for the same input that names the folder and
  says roost links the file, not the folder. Severity: wording only; nothing
  is deleted, because install never prints or runs `rm` for something that is
  not a symlink. What closes it: install tests `-L "$(dirname "$path")"` the
  way doctor does, and prints the folder-link note.
- The executable bit on `tests/test-*.sh` is split with nothing distinguishing
  the two groups: 11 files at mode 644 and 16 at 755, re-measured with
  `git ls-files -s tests/test-*.sh | grep -c '^100644'` (and `100755`) at
  `9738321`. It was 9 and 15 at the commit that fixed `test-doctor.sh` and
  `test-next-blocked.sh`, so the split is still growing. Cosmetic —
  `tests/run.sh` invokes `bash "$t"`, so no test has ever needed the bit.
  Left alone rather than swept, because a `chmod` across nine files that other
  branches are editing collides for no benefit.

## Process lessons

### A sweep done from a review's list is not a sweep

PR #29 changed one phrase across the repo after #31 replaced typing with
pasting. Three review rounds running, a reviewer returned with more sites:
five, then about fifteen — two of them in the very file whose section had just
been rewritten — then five more, plus two the author found alongside them. Each
round the listed sites were fixed and the job called done.

Only `fc6c30c` ran a `grep` over the whole tree instead of working from the
report, and that is the commit that actually closed it.

**And the mirror of it, in the very next commit.** Sweeping a phrase without
reading each site produced the opposite error: `394f314` changed four comments
in `tests/live/*-smoke.sh` to say "delivered" when those scripts use raw
`tmux send-keys`, not `roost send`. "Typed" was correct there, and
load-bearing — the race those comments explain exists *because* keystrokes
reach a TUI that has not rendered. Reverted in `fbb805f`.

Neither half is reading the code: taking a list on trust, or taking a phrase on
trust. A sweep finds the candidates; only the surrounding code says which are
real.

**Commits, not round numbers.** This entry named ordinals twice and had them
wrong both times — which is the failure it is about. A SHA cannot drift.

### A mutation that fails to apply reports the fix as unnecessary

Six mutations across PR #29 earned their keep. A seventh lied: its anchor
string did not match, so nothing was mutated, the suite stayed green, and the
result read exactly like "this fix was not needed". Every mutation since
asserts its own anchor before running.

Two of the six found what the tests could not. One showed a flag-consuming
loop was dead code, because removing it turned nothing red. One showed an
assertion passing for the wrong reason — it checked only that the exit code was
non-zero, and the command failed for an unrelated cause. Three assertions in
that file were checking status where they meant to check the message.

**A test that cannot fail and a fix that is not needed look identical from
here.** Only a mutation proven to have been applied tells them apart.

### Blast radius enumerated from memory misses consumers

The `error` state's blast radius was enumerated from recall and missed two
consumers. One of them, `scripts/roost-init` (then `amux-init`), shifted every
glyph by one position for anyone running the documented first-run path — and
the init test asserted the option *name* was present, never its value, so it
passed throughout. The other, `scripts/roost-next-blocked` (then
`amux-next-blocked`), left the notification that `error` fires with no jump
target.

For the next harness increment: derive the blast radius from `grep` over the
state vocabulary and the glyph accessor, not from memory. `grep -rn
roost_glyphset` finds all five positional consumers in one second.

### A fixture that stops where the feature does proves nothing (#12, #14)

`#12` shipped the opencode reply channel, and it published nothing on **any**
turn — not an edge case, every agent, straight back to `roost read` scraping the
screen. It sat on `main` through `#13` before anyone noticed.

The suite did not merely miss it. It could not see it:

```
tests/opencode-plugin-harness.mjs against the BROKEN adapter -> 44 passed, 0 failed
tests/opencode-plugin-harness.mjs against the FIXED  adapter -> 44 passed, 0 failed
```

Identical. 529 assertions green across the repo, feature dead.

The fixtures were built from a real recorded opencode turn, which is the right
instinct — and they were trimmed to the events the feature reads: the assistant
`message.updated`, its text parts, then `session.idle`. The live stream does not
stop there. opencode **re-announces** the assistant message twice *after* the
text parts, and the handler cleared the collected reply on every announcement,
so it was wiped a moment before the line that would have published it. The two
events that broke it were the two the fixture left out, because at fixture-writing
time they looked like noise after the interesting part.

Only the live two-pane check found it, and only after the merge.

**Two rules, both cheap:**

- A fixture derived from a recording replays the **whole recorded turn**, in
  order, trailing events included. Trimming a recording to the events you
  believe matter encodes the belief you are trying to test. Keep the recorded
  log line numbers in a comment so the next reader can check the fixture against
  the capture rather than against the code.
- A regression test is **run against the unfixed code first**, and its failure
  output goes in the pull request. A test written after the fix, that has never
  been seen red, is an assertion that the code does what it does. `#14` does
  this: five fixtures, 5 failed before the one-line change, 0 after.

The wider point is the one the entry above already makes in a different key:
green is evidence about the tests, not about the feature. When a mechanism has
never been exercised end to end outside its own harness, say so plainly at
review time rather than reading the count as coverage.
