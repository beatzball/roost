# Turn-over steps 1 to 3 (#97, #95, #110) — Plan

Design:     docs/airig/specs/2026-09-29-turn-over-design.md (approved 2026-09-29; §8 decisions, §10 predictions)
Repository: the `turn-over-1-3` worktree of this checkout (`.claude/worktrees/turn-over-1-3`)
Branch:     worktree-turn-over-1-3
Base:       357ad31 (origin/main, 2026-10-24)
Oracle:     automated (unit tests on captured payloads and transcripts) + instrumented (one live smoke test against the real Claude Code)
Unattended: yes

Steps 4 and 5 of the design (#105) are out of scope. Other harnesses' background
work is out of scope (Q7). `wait-done --main` is dropped (Q9). Every design
question is decided in §8 of the spec; nothing here re-opens one. Three
decisions the human re-confirmed on 2026-10-24: Q3 is built as the §10 item 2
**deferral**, not the §5.4 rewrite; the A1–A3 measurements run first; if A1
fails, step 1 waits for step 4.

## 0. Measurements (Claude Code 2.1.310, tmux 3.6, macOS 26.3, 2026-10-24)

**Rig.** Two throwaway `-S` servers under `/tmp/amx.*` whose socket path ends in
`/roost`; `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp directories; a
local fake Messages API on `ANTHROPIC_BASE_URL` that scripts each reply from a
marker in the prompt (a background `Bash`, a background `Agent`, `roost spawn`,
`roost split`, `Monitor` through `ToolSearch`, `TaskStop` through `ToolSearch`,
`ScheduleWakeup`, a slow stream, a foreground `perl -e 'sleep 30'`); a logger
on 25 hook events beside this checkout's `roost hooks claude`, which also
records each hook's pid chain to 1 and the pane's `pane_pid`; `claude --model
haiku --permission-mode default --setting-sources local --settings <file>`
with `permissions.allow` for `Bash(sleep:*)`, `Bash(roost:*)`, `Bash(perl:*)`,
`Agent`, `Monitor`, `TaskStop`. A badge watcher polled `@agent_state`,
`@roost-background` and `@roost-reply-turn` every 50 ms. Run 1: 11 prompts in
one pane; run 2: 5 prompts in one pane. `~/.claude/settings.json` hashed before
and after each run: **unchanged**. `~/.claude.json`: changed in both runs
(`tipsHistory`, `promptQueueUseCount` and the like — this machine's own live
Claude session writes those), **no project key added**, no `amx.` key.
"Once" below means one run.

- **A1 — a `run_in_background` shell IS in the pane's process tree.** `sleep 30`
  started with `run_in_background: true`: pid chain `sleep <- zsh <- claude <-
  zsh (the pane's process, #{pane_pid}) <- tmux`. 1 of 1. The subagent's
  foreground `sleep 20`: the same chain, 1 of 1. The two `Monitor` shells: the
  same chain, 2 of 2. All 72 logged hook calls across both runs had the pane's
  `pane_pid` in their chain. **A1 holds; step 1 is built from Claude's list.**
- **A2 — agent-team teammates: not measured.** The rig offered no team tool
  (the tools Claude sent the fake: Agent, AskUserQuestion, Bash,
  DeferredToolPlaceholder, Edit, ListAgents, Read, ReportFindings,
  ScheduleWakeup, Skill, ToolSearch, Workflow, Write; `Monitor` and `TaskStop`
  reachable through `ToolSearch`). The design's rule stands: an unknown `type`
  holds `working` and is recorded.
- **A3 — `background_tasks` stays empty after `roost spawn` and `roost split`.**
  A turn whose `Bash` ran `roost spawn rig-a 'sleep 600'` ended with
  `background_tasks: []`; so did a turn that ran `roost split 'sleep 600'`.
  Once each. The new panes were children of the tmux server (`list-panes`
  showed them with their own `pane_pid`).
- **M2 on 2.1.310 (2 runs, 30 s and 15 s).** `Stop` with `[{"id","type":
  "shell","status":"running","description","command":"sleep 30"}]` 266 ms after
  the prompt; the badge read ✅ done 144 ms after that `Stop`, and stayed done
  for 29.9 s / 14.9 s; then a `UserPromptSubmit` whose `prompt` is
  `<task-notification>\n<task-id>…</task-id>\n<tool-use-id>…</tool-use-id>\n<output-file>…`
  and a `Stop` with `background_tasks: []` 258 ms / 104 ms later.
  `@roost-reply-turn` went up by one for the notification turn, both runs.
- **§10 item 4 — the notification turn is NOT linked by `prompt_id`.** Its
  `UserPromptSubmit` carries a **new** `prompt_id` (3 of 3 notification turns
  in run 1, 1 of 1 in run 2). Only the prompt text (`<task-notification>` with
  the `<task-id>`) ties it to the task. The deferral does not need the link.
- **M3 on 2.1.310 (once, 20 s).** `Agent` with `run_in_background: true`:
  `PostToolUse` (`status: async_launched`) and `SubagentStart` in the same
  millisecond, `Stop` with `[{type: subagent, status: running}]` 106 ms later,
  badge ✅ done 144 ms after that. The subagent's own `PreToolUse`/`PostToolUse`
  (with `agent_id`) fired on the main pane; its `PostToolUse` at +20.1 s stamped
  ⏳ again (the M3 accident), then `SubagentStop` (+93 ms, its
  `background_tasks` still listing the agent as running), the
  `<task-notification>` `UserPromptSubmit` (+96 ms), `Stop` with `[]` (+84 ms).
- **Monitor (§10 item 6, once, two monitors).** A `Monitor` call returns
  `{"taskId","timeoutMs","persistent":false}` and the `Stop` lists it as
  `type: "shell", status: "running", command: "sleep 25; echo MON-DONE"` — the
  same type as a background `Bash`, not a new one. Its shells sit in the pane's
  tree (A1). Each monitor's end brought its own `<task-notification>` turn, and
  the `Stop` between them still listed the one still running. So the
  ownership rule holds a pane for the whole life of a `Monitor` — right, and
  worth a sentence in the skill.
- **`session_crons` (§10 item 6, once).** `ScheduleWakeup {delaySeconds: 60}`
  put `[{"id":"7aed76a8","schedule":"2 23 * * *","recurring":false,"prompt":
  "…"}]` in `session_crons` on that `Stop` and the two after it, with
  `background_tasks: []`. Not a hold (§3.1 case 4). The wake-up turn did
  **not** start within 2 min 15 s of its minute; not measured beyond that.
- **§10 item 3 — does the releasing `Stop` come?**
  - *Killed with `TaskStop`* (once): the turn that called `TaskStop` ended with
    a `Stop` whose `background_tasks` is `[]` — the release — and no
    `<task-notification>` turn followed in 25 s.
  - *Killed from the task panel*: **not measured** (not driven).
  - *Claude exits with work running* (once): `/exit` opened a Claude dialog
    ("Background work is running … 1. Exit and stop tasks"; no hook fired for
    it). After choosing it: `SessionEnd`, and **no `Stop`**. The task's `sleep`
    was killed. **A held pane is therefore never released by a hook when its
    Claude exits**; only #54 (pane closed/dead) or #64 (job gone) can notice.
    Recorded as a gap.
  - *A human prompt typed while the work runs* (once): the human turn's `Stop`
    **also** listed the still-running task (`[{…status: running}]`), so under
    the hold it keeps the pane `working`; the `<task-notification>` turn then
    released it with `[]`. *A prompt typed exactly as the work ends*: not
    driven; not measured.
- **M5 on 2.1.310 (once).** Esc 6 s into a slow stream: **no hook of any kind
  in 80 s**. Transcript tail: `assistant` (text, `isAbortedMidStream: true`),
  then `user` with `message.content == [{"type":"text","text":"[Request
  interrupted by user]"}]` carrying `interruptedMessageId`. **No
  `turn_duration`.** The badge stayed `working`.
- **M6 on 2.1.310 (once).** Esc 4 s into a foreground `perl -e 'sleep 30'`:
  **no hook in 20 s** (no `PostToolUseFailure`, no `Stop`). Tail: `user`
  `tool_result` with `toolDenialKind: "user-rejected"` and content starting
  "The user doesn't want to proceed with this tool use.", then `user` text
  `[Request interrupted by user for tool use]`. **No `turn_duration`** — the
  #38 decline's first two records without its third. The badge stayed
  `working`. A prompt typed afterwards fired `UserPromptSubmit` and `Stop`
  as usual. (A foreground `sleep 30` is refused by Claude 2.1.310 itself —
  "Blocked: standalone sleep" — which is why the rig uses perl.)
- **New transcript record types on 2.1.310**, all metadata: `api-request`,
  `api-request-blob`, `api-request-shape`, `file-history-snapshot`,
  `queue-operation`, and `system` with subtype `stop_hook_summary` (which
  carries hook command paths). None landed after an interrupt marker in the
  two tails above.

What this decides: step 1 goes ahead from Claude's list (A1). Monitor is a
`shell` and needs no new type. The release after `TaskStop` is a plain `Stop`.
Exit-with-work is a hole; so is the task-panel kill until measured.

## 1. The shape of what is built

- **Hold.** A Claude `Stop` (`done --stop-hook`) reads `background_tasks` in
  the same reader call as the reply. Verdict: `absent` (key missing: today's
  `done`, Q5), `none` (a list with no running item), `hold N` (N items whose
  `status` is `running`; `type` `shell`/`subagent` or anything else — an
  unknown type holds too and its name is recorded in `@roost-background-types`
  for `roost doctor`), `bad` (not a list, or an item that is not an object or
  has no string `status`: could not tell, held with count `?`). Held means the
  stamp is `working`, not `done`.
- **Deferral (Q3 as §10 item 2).** A held `Stop` writes `@roost-reply` (the
  main reply, `final: false`), unsets `@roost-reply-turn`, writes
  `@roost-background` as `#{@agent_since} N` in the **same tmux command**,
  above the unchanged-state bail, and writes **nothing to disk**. The
  releasing `Stop` (`none` or `absent`) appends **one** turn file as today and
  unsets `@roost-background` (and `-types`) in the same command as the stamp.
  The main reply is not kept on disk once the final reply replaces it.
- **`read`.** A `working` pane whose `@roost-background` first word equals
  `@agent_since` is not stale: one stderr line "main reply; N tasks still
  running"; `read --json` gains `final` (false there, true otherwise) and
  `background` (N, or null). **`status --json`** gains `background` per pane
  (integer, or null when unset, unreadable, or `?`).
- **Interrupted.** `@roost-transcript` is also written at `UserPromptSubmit`
  (`working`, from the hook, above the bail: a new turn is never a repeat).
  `scripts/lib/roost-unblock.sh` gains `roost_claude_interrupted` (M5 and M6
  tails, both engines, same fail-closed rules: newest conversation record,
  no older than `@agent_since`, unknown type = could not tell) and
  `roost_interrupted_pane`: for a `working` pane with a matching record, one
  tmux command unsets `@agent_state`, `@roost-reply`, `@roost-reply-turn`,
  `@roost-transcript`, writes `@roost-ended "<since> interrupted"` and
  `@roost-unblocked`; then an **empty turn record** with sidecar
  `NNNNNN.outcome = interrupted`. Called from `send`, `read` and `wait-done`
  on a `working` pane; **never** from `status` (Q6).
- **The sink's `--interrupted`.** `roost-agent-state idle --interrupted` (and
  `roost state idle --interrupted`) stamps `idle`, writes `@roost-ended
  "<now> interrupted"` in the same command, clears the reply and writes the
  empty turn record. codex's `Interrupt` calls it; copilot's
  `session.idle {aborted: true}` calls it instead of `done`.
- **`wait-done`.** Exit 5 with `roost: '<tgt>' was interrupted, not done`
  when, at the moment it would exit 0, a pane's `@roost-ended` reads
  `"<@agent_since> interrupted"`, or with `--turn N` when turn N's `.outcome`
  sidecar says `interrupted`. Exits 0, 1, 2 unchanged; plain stdout
  byte-identical. `--json` prints one document on every **outcome** (done,
  error, timeout, died, gone, interrupted) and nothing on a usage refusal.
- A held pane is never called stale; `send` to it takes the existing
  "already mid-turn" path and prints no turn number (another lane adds the
  stderr note there).

## 2. Global constraints

- Work only in the worktree above; `git -C` or `cd` with its absolute path.
  Never `git stash`. One commit per task, message given below.
- `bin/roost` and `scripts/roost-agent-state` run under `set -euo pipefail` on
  bash 3.2 and bash 5: no `declare -A`, no `${var,,}`, no `mapfile`; `cmd &&
  last` at a function tail needs `|| true`. Comments move with code and are
  never shortened (AGENTS.md §5).
- Tests: `XDG_STATE_HOME=$(mktemp -d) bash tests/test-NAME.sh`; every new test
  file is run red against the unfixed code first and the FAIL lines kept for
  the report. Tests never touch the real `~/.claude`, `~/.claude.json`,
  `~/.config/opencode`, `~/.codex`; redirect `HOME` and the XDG dirs.
- No names, emails or home paths in anything committed; fixtures are
  scrubbed (`/tmp/roost-fixture/...`, `00000000-…` ids). No provenance
  trailers. Never name a competing product.
- `bin/roost`'s exit codes 0–4 for `send` are untouched. No new badge state.
  No screen reading or key sniffing to decide an interrupt.
- Site: `cd site && node scripts/sync-changelog.mjs` after a CHANGELOG edit,
  and `node scripts/build-llms-txt.mjs --check` must pass.

## 3. Tasks

### Task 1 — Fixtures from the rig, and the measurements in known-gaps

**Files:** `tests/fixtures/claude-stop-bg-shell.json`,
`tests/fixtures/claude-stop-bg-subagent.json`,
`tests/fixtures/claude-stop-bg-two-shells.json`,
`tests/fixtures/claude-stop-bg-empty.json`,
`tests/fixtures/claude-ups-task-notification.json`,
`tests/fixtures/claude-transcript-interrupt-stream.jsonl`,
`tests/fixtures/claude-transcript-interrupt-tool.jsonl`, `docs/known-gaps.md`
**Depends on:** nothing

**Do:**
1. From the rig's `events.jsonl`, take the `Stop` payload with one running
   `shell`, the one with one running `subagent`, the one with two `shell`
   items (the Monitor run), the empty-list `Stop`, and the `UserPromptSubmit`
   of a `<task-notification>` turn. Replace every uuid with `00000000-…` of
   the same shape, every task/agent id with a fake of the same length and
   alphabet, every path with `/tmp/roost-fixture/...`. Keep every other key.
2. From run 2's transcript, copy whole lines from the interrupted turn's
   `user` prompt record to the end of the file, for the mid-stream Esc and
   the mid-tool Esc. Drop only `attachment`, `api-request`,
   `api-request-blob` and `stop_hook_summary` lines (system prompt, request
   bodies, hook paths). Scrub as in step 1 (`cwd`, `sessionId`, uuids). Note
   the real timestamps; the tests use them as `since`.
3. In `docs/known-gaps.md`, under "When a Claude turn is over", add a
   subsection "Step 1 measurements (2.1.310, 2026-10-24)" with §0 above,
   run counts included. Do not yet rewrite the "What that leaves live" list
   (Task 8).

**Check:** `python3 -c 'import json,sys; [json.load(open(f)) for f in sys.argv[1:]]' tests/fixtures/claude-stop-bg-*.json tests/fixtures/claude-ups-task-notification.json` exits 0; `grep -c . tests/fixtures/claude-transcript-interrupt-*.jsonl` prints the line counts; `grep -l '/Users/\|sk-ant' tests/fixtures/claude-*` prints nothing.
**Commit:** `turn-over: fixtures from the 2.1.310 rig, and the step 1 measurements`

### Task 2 — The hook holds `working` while this pane's background work runs

**Files:** `scripts/roost-agent-state`, `tests/test-turn-over-hold.sh`,
`tests/run.sh` (a `shard_weight` line if the file takes over 12 s)
**Depends on:** Task 1

**Do:**
1. Write `tests/test-turn-over-hold.sh` first (red): a throwaway `-S` socket
   ending in `/roost`, `ROOST_RECORD_DIR` under the test's temp dir, the hook
   run as `roost hooks` wires it (`env TMUX=... TMUX_PANE=... HOOK working`
   with the UPS fixture, then `HOOK done --stop-hook < fixture`). Assert, each
   from a pane that ALREADY reads `working` (the UPS stamp):
   - bg-shell fixture: state stays `working`; `@roost-background` is
     `"<@agent_since> 1"`; `@roost-reply` holds the main reply; no turn file
     was written; `@roost-reply-turn` is unset.
   - then the empty-list fixture: state `done`; exactly ONE new turn file,
     holding the final reply; `@roost-background` unset; `@roost-reply-turn`
     names it.
   - bg-subagent fixture: held. two-shells fixture: held with count 2.
   - a fixture with an unknown `type` (`teammate`): held, and
     `@roost-background-types` is `"<since> teammate"`.
   - a payload with no `background_tasks` key: `done` (Q5), background unset.
   - `background_tasks: {}`, and `[{"id":"x"}]` (no status): held, count `?`.
   - an item with `status: "completed"` alone: not a hold (`done`).
   - from a pane reading `done` (no UPS first): a held Stop stamps `working`
     and `@roost-background`'s first word equals the new `@agent_since`.
   - the jq-only PATH shim from tests/test-claude-stop-failure.sh: the
     bg-shell fixture is held there too.
2. In the Stop branch of `scripts/roost-agent-state`: one reader (python3,
   else jq) prints the verdict line then the reply. Set `held=1` and
   `state=working` for `hold`/`bad`. Write `@roost-background` with `-F
   '#{@agent_since} N'` in the same tmux command as `@roost-reply` (above the
   bail), skip the record append and unset `@roost-reply-turn` when held; on a
   release append the turn file as today and unset `@roost-background` and
   `@roost-background-types` in the same command as the stamp. On a held
   stamp from a non-working pane, write `@roost-background "$now N"` in the
   same command as `@agent_state`/`@agent_since`. Comments say why each write
   sits where it does (§10 item 1).
3. Run the new test green; run `bash tests/test-agent-state.sh`,
   `tests/test-claude-stop-failure.sh`, `tests/test-reply-record.sh`,
   `tests/test-send-turn.sh` to prove nothing moved.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-turn-over-hold.sh` → all PASS, exit 0; the four existing files above still exit 0.
**Commit:** `agent-state: hold working while this pane's background work runs (#97)`

### Task 3 — `read`, `status --json` and `roost doctor` see a held pane

**Files:** `bin/roost`, `scripts/lib/roost-jsonout.sh`, `scripts/roost-doctor`,
`tests/test-turn-over-hold.sh`, `tests/test-json-output.sh`
**Depends on:** Task 2

**Do:**
1. Red first, in `tests/test-turn-over-hold.sh`: on a held pane, `roost read`
   prints the main reply on stdout, exit 0, and ONE stderr line containing
   `main reply` and `1 task still running` (plural `tasks` for 2); it does not
   contain "previous turn". `read --json` has `"stale": false, "final":
   false, "background": 1`; on the released pane `final: true, background:
   null`. `status --json` has `"background": 1` on the held pane and `null`
   on every other pane; with `@roost-background` set to `"<since> ?"` or a
   stale since, `null`. In `tests/test-json-output.sh`, update the gold
   documents for the new `read --json` keys.
2. `bin/roost` `read`: read `@roost-background` and `@agent_since` with the
   state; when state is `working` and the record's first word equals since,
   print the notice instead of the stale one and set `json_stale=0`,
   `json_final=0`, `json_bg=N` (null for `?`). Every other `read --json`
   document (record, gone, screen) gains `final b 1` and `background i ""`.
3. `roost_jsonout_status`: an 18th field `#{@roost-background}` and
   `#{@agent_since}` already there; emit `background` through
   `roost_jsonout_int` only when the first word equals `since`.
4. `scripts/roost-doctor`: beside the "may be stuck" pane walk, a `warn` for
   every pane whose `@roost-background-types` first word equals its
   `@agent_since`, naming the type: roost holds it `working` for background
   work of a kind it has not measured.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-turn-over-hold.sh` and `bash tests/test-json-output.sh` and `bash tests/test-doctor.sh` all exit 0.
**Commit:** `read, status --json, doctor: a held pane is a main reply, not a stale one (#97)`

### Task 4 — The live smoke test and the skill paragraph

**Files:** `tests/live/claude-background-smoke.sh`, `skills/roost/SKILL.md`
**Depends on:** Task 3

**Do:**
1. Write the smoke test beside `tests/live/claude-stop-failure-smoke.sh`,
   reusing `tests/live/answer-smoke.sh`'s fake API and guard (settings hash,
   project keys of `~/.claude.json`), with `HOME`, `XDG_CONFIG_HOME`,
   `XDG_STATE_HOME` redirected and `ANTHROPIC_API_KEY` set to a fake key
   whose approval is seeded in the throwaway `.claude.json`. One pane, one
   prompt that scripts `Bash {command: "sleep 12", run_in_background: true}`,
   then a final text. Assert: the badge reads `working` 2 s after the main
   reply landed (and `read` prints the main reply with the "main reply"
   notice), `wait-done %N 3` exits 1 (timed out), the badge reaches `done`
   within 30 s, `wait-done` then exits 0, `read` prints the final reply, and
   exactly ONE turn file was written for that prompt. Print the pane on
   failure. `permissions.allow` carries `Bash(sleep:*)` in the settings file.
2. `skills/roost/SKILL.md`: replace the "today not even for that" sentence in
   the long-lived-process paragraph with one that says a background job or a
   `Monitor` in your own pane holds your badge at ⏳ working until it ends,
   so a coordinator's short `wait-done` exits 1; a long-lived server or
   monitor belongs in its own pane (`roost split`/`spawn`).

**Check:** `bash tests/live/claude-background-smoke.sh` → every line PASS, the guard lines say unchanged / no new project key (one run; recorded in the report as one run).
**Commit:** `live smoke: a background shell holds the pane working until the final Stop; skill says so`

### Task 5 — The `interrupted` outcome for Claude: reader, recovery, record

**Files:** `scripts/lib/roost-unblock.sh`, `scripts/roost-agent-state`,
`scripts/lib/roost-record.sh`, `scripts/lib/roost-events.sh`, `bin/roost`,
`tests/test-turn-over-interrupt.sh`
**Depends on:** Task 1

**Do:**
1. Red first, `tests/test-turn-over-interrupt.sh`: both engines on the two
   new transcript fixtures (`roost_claude_interrupted_py` / `_jq`): the
   stream tail and the tool tail are interrupts at their real `since`;
   one second later than the marker's timestamp is not; the decline fixtures
   (`no`, `esc`, `yes`, `round3-running`) are NOT interrupts (their newest
   record is `turn_duration` or a running tool); an unknown record appended
   after the marker is not; a non-JSON line is not; a missing file is not.
   Then the pane: stamp `working`, `@agent_since`, `@roost-transcript "<since>
   <path>"` and a previous reply; `roost send %N "x"` exits 0 and the badge is
   UNSET (never a value), `@roost-reply` unset, `@roost-ended` is `"<since>
   interrupted"`, `@roost-unblocked` recorded; one empty turn file with
   `.outcome` `interrupted` exists in the record (recording on). `read` does
   not call it "working — previous turn" and falls back to the screen with
   its notice. `wait-done` on such a pane returns (exit code pinned in Task
   6). `status --json` on a freshly stamped copy changes nothing (the badge
   still reads `working` afterwards). Everything that must stay `working`:
   a record for a different stamp, no record, a decline tail, a tail with a
   newer prompt (`@agent_since` newer than the marker), a relative path. The
   hook: `HOOK working < UPS fixture` writes `@roost-transcript` with the
   stamp and the payload's `transcript_path`; a UPS whose path is relative,
   or carries a tab, writes none; `HOOK working` with no payload (a tty, or
   empty stdin) leaves an existing record alone.
2. `scripts/lib/roost-unblock.sh`: `roost_claude_interrupted FILE SINCE`
   (python3 then jq) matching, from the end, after SKIP: (a) `user` text
   `[Request interrupted by user]` preceded by an `assistant` record, or
   (b) `user` text `[Request interrupted by user for tool use]` preceded by
   the user-rejected `tool_result`; both no older than SINCE.
   `roost_interrupted_pane TARGET`: `working` at pane scope, record first word
   equals since, absolute path, reader says yes; one `if-shell -F` compare-
   and-clear; then the empty turn record through a new
   `roost_record_append_empty DIR SOCKET` (an `append` of "" plus
   `put_turn_field N outcome interrupted`) using bin/roost's `record_for`;
   `roost_events_unblocked` gains FROM and REASON arguments (defaults keep
   the decline's line byte-identical).
3. `scripts/roost-agent-state`: `working` without `--tool-hook`, stdin not a
   tty, payload readable: take `transcript_path` (same checks as the dialog
   path) and write `@roost-transcript "$now <path>"` in the same command as
   the `working` stamp. This runs only on a transition (above the bail it
   would cost PostToolUse; UserPromptSubmit from `working` bails and must:
   a repeat prompt mid-turn is not a new stamp).
4. `bin/roost`: `send`, `read`, `wait-done` call `roost_interrupted_pane` on a
   `working` pane where they call `roost_unblock_pane` on a `blocked` one;
   `status` never does.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-turn-over-interrupt.sh` → all PASS; `bash tests/test-claude-decline.sh`, `tests/test-events.sh`, `tests/test-send-turn.sh` still exit 0.
**Commit:** `interrupted: recover an Esc mid-stream or mid-tool from Claude's transcript (#95)`

### Task 6 — `wait-done` exits 5; codex and copilot report `interrupted`

**Files:** `bin/roost`, `scripts/roost-agent-state`,
`adapters/codex/roost-codex-hook`, `adapters/copilot/extension.mjs`,
`tests/test-turn-over-interrupt.sh`, `tests/test-codex-hook.sh`,
`tests/test-copilot-extension.sh`, `tests/copilot-extension-harness.mjs`
**Depends on:** Task 5

**Do:**
1. Red first: `wait-done %N 5` on the recovered Claude pane exits 5 with
   stderr `roost: '%N' was interrupted, not done` and nothing on stdout;
   `wait-done --turn N %N 5` where turn N's `.outcome` is `interrupted` exits
   5; a pane whose `@roost-ended` first word is NOT its `@agent_since` exits
   0; `roost-agent-state idle --interrupted` from `working` leaves `idle`,
   `@roost-ended "<since> interrupted"` with since equal to the new
   `@agent_since`, reply unset, an empty turn file with the sidecar; `roost
   state idle --interrupted` through bin/roost does the same; plain `roost
   state idle` writes no `@roost-ended`. codex: the `Interrupt` case in
   `tests/test-codex-hook.sh` now also asserts `@roost-ended`. copilot: the
   harness fires `session.idle` with `{aborted: true}` and the test asserts
   the extension reported `idle --interrupted`, not `done`; a plain
   `session.idle` still reports `done`.
2. `bin/roost` `wait-done`: at the point it would `break` for exit 0, read
   `@roost-ended` and `@agent_since` of every pane in `rows`; a match exits 5.
   With `--turn`, `turn_reached` also reads the sidecar; interrupted exits 5.
   `state` arm: `--interrupted` in `$3` is passed to the sink.
3. `scripts/roost-agent-state`: `--interrupted` with `idle`: clear the reply
   (as `idle --stop-hook`), write `@roost-ended "$now interrupted"` in the
   same command as the stamp, append the empty turn record.
4. codex adapter: `Interrupt` calls `idle --interrupted`. copilot:
   `session.idle` with `data.aborted === true` runs `state idle --interrupted`
   through `run`, drops `pending`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-turn-over-interrupt.sh`, `bash tests/test-codex-hook.sh`, `bash tests/test-copilot-extension.sh`, `bash tests/test-wait-done-timeout.sh`, `bash tests/test-wait-done-died.sh`, `bash tests/test-wait-done-shell.sh` all exit 0.
**Commit:** `wait-done exits 5 for an interrupted turn; codex and copilot record it (#95)`

### Task 7 — `wait-done --json`

**Files:** `bin/roost`, `tests/test-wait-done-json.sh`, `tests/run.sh`
**Depends on:** Task 6

**Do:**
1. Red first, `tests/test-wait-done-json.sh` (the json-output test's `jv`
   helper copied): one document on stdout for each outcome — `done` (with
   `reply` holding `source`, `stale`, `error_reason`, `turn`, `text`,
   `lossy`, `sent_by`, `final`, `background` exactly as `read --json` prints
   them), `error` (exit 1, `error_reason`), `timeout` (exit 1), `died` (exit
   2, a `remain-on-exit` pane), `gone` (exit 2), `interrupted` (exit 5,
   `@roost-ended`); `schema` 1, `command` `wait-done`, `target`, `pane`,
   `state`, `outcome`, `error_reason`, `background`, `elapsed` (integer
   seconds), `turn` (the `--turn` number or null), `reply` (null unless
   outcome is done and a reply is recorded on a `%N`). Nothing on stdout for
   a usage refusal, a bad timeout, `--turn` on a window. Plain `wait-done`
   output byte-identical: run each case without `--json` too and compare
   stderr. `--json` goes before the target, once, like `read`.
2. `bin/roost`: a `wd_json` flag; one exit function `wd_exit CODE OUTCOME
   PANE STATE` that prints the document when asked and exits; every exit in
   the loop goes through it; the stderr lines are unchanged.
3. `tests/run.sh`: a `shard_weight` line if the file takes over 12 s.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-wait-done-json.sh` → all PASS; `bash tests/test-json-output.sh` and the three `test-wait-done-*.sh` files exit 0.
**Commit:** `wait-done --json: one document per outcome, reply included (#110)`

### Task 8 — Docs and changelog

**Files:** `docs/known-gaps.md`, `docs/airig/specs/2026-09-29-turn-over-design.md`,
`site/content/docs/driving-a-fleet.md`, `CHANGELOG.md`,
`site/content/docs/changelog.md`
**Depends on:** Tasks 2–7

**Do:**
1. `docs/known-gaps.md`: rewrite the "#95, #97" section's "What that leaves
   live" to what is true now; keep the Q5 and Q4 exceptions; residuals, each
   with severity and "not measured" where so: the reparented-work hole;
   Claude exiting with work running releases nothing (SessionEnd only);
   task-panel kill not measured; a `Monitor` holds for its whole life;
   unknown types hold and `doctor` names them; agent teams not measured;
   other harnesses not measured; the main reply is not kept on disk; a
   prompt typed into a held pane is folded into the held turn and gets no
   turn file of its own; after a Claude interrupt the pane has no badge, so
   the next `send` prints no turn number; `wait-done` exit 5 is new.
   Update the #38 section's "`wait-done` exits 0 on an interrupted turn"
   bullet. Update "Two places could not tell…" to say step 1 is built.
2. Spec `Status:` line: steps 1 to 3 built, 4 and 5 not started. Nothing else.
3. `site/content/docs/driving-a-fleet.md`: exit 5 row in the `wait-done`
   table; `final` and `background` in `read --json`; `background` in
   `status --json`; a `roost wait-done --json` section next to the others;
   remove "`wait-done` does not take `--json` yet".
4. `CHANGELOG.md` `## [Unreleased]`: Changed (a pane stays ⏳ while its own
   background work runs; `wait-done` exits 5 for an interrupted turn; copilot
   aborted turn is idle, not done), Added (`wait-done --json`, `read --json`
   `final`/`background`, `status --json` `background`, `roost doctor` names
   held panes of unknown kind), in the file's narrative style. Then `cd site
   && node scripts/sync-changelog.mjs && node scripts/build-llms-txt.mjs
   --check`.

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0 and `git diff --stat` shows `site/content/docs/changelog.md` changed with CHANGELOG.md; `grep -n 'does not take `--json` yet' site/content/docs/driving-a-fleet.md` prints nothing.
**Commit:** `docs: turn-over steps 1 to 3 — what changed, what is still open`

### Task 9 — Verify

**Files:** none (report only)
**Depends on:** Task 8

**Do:**
1. `bash -n` both `bin/roost` and `scripts/roost-agent-state` under
   `/bin/bash` (3.2) and the bash 5 on PATH.
2. Mutants, each run against the three new test files: remove the hold
   (`held=0` always); remove the `@roost-ended` since guard in `wait-done`;
   make `wait-done` exit 0 instead of 5. Record the red counts, then restore.
3. `XDG_STATE_HOME=$(mktemp -d) bash tests/run.sh` on macOS: exit code and
   totals. The changed test files in `ubuntu:24.04` with the brief's docker
   recipe (a script file, run with `bash file`).
4. The live smoke test once more against the real Claude Code, with the
   guard lines.

**Check:** suite exit 0 and no FAIL lines; container run exit 0 per file; smoke PASS; mutant counts non-zero.
**Commit:** none

## Deferred checks — one pass at the end

1. Task 4 — the live smoke's screen dump on a failure is readable, and the
   guard lines are the last two lines printed.
