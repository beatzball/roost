# Fleet board groundwork (Phase 0) — Plan

Design:     `searoost/docs/airig/plans/2026-09-29-searoost-plan.md` §4.1 and §6
            (the sibling repository, `github.com/beatzball/searoost`), plus the
            roost issues each lane names. Decided 2026-09-30 (D1, D2) and
            committed to on 2026-10-08.
Repository: one worktree per lane, under the primary checkout:
            `<roost>/.claude/worktrees/<lane>` — see "How this plan is run"
Branch:     `worktree-<lane>`, one per lane, named in each lane's header
Base:       `main` at the moment the lane's worktree is made; the coordinator
            writes the short sha into the lane's report file before dispatch
Oracle:     automated, with one design checkpoint (lane C) and a short
            deferred human-eye list at the end
Unattended: no — the human merges every pull request and decides lane C's
            three open questions

> `<roost>` is the primary checkout. Resolve it, never type it:
> `git -C "$(pwd)" rev-parse --show-toplevel` from inside any worktree prints
> the worktree, and `git worktree list | head -1` prints the primary. Never
> commit from the primary checkout.

## 1. What this plan is for

A board over every agent in a roost: one page, one card per pane, a column
for what each agent needs from you, a reply box on every card, and it works
from a phone. That board is [searoost](https://github.com/beatzball/searoost).
Its plan (§6) puts the board itself in Phase 1 and later, and says the board
cannot start until roost has six small primitives it lacks today. Those six
are **Phase 0**, and this document is the plan for them.

Each primitive is worth shipping on its own, with or without a board. A
coordinator in a pane gains `roost events` instead of polling, a human on
another machine gains `roost answer`, every hand-off gains `roost close`.
Nothing here depends on the board existing.

| lane | primitive | issue | size | blocks |
|---|---|---|---|---|
| A | session identity on the pane, in `status --json` and the record | #141 | M | every board card |
| B | `roost events`: one JSON line per state change, tail-able | #98 | M | the live feed |
| C | `roost answer`: the human's verb for a dialog | #142 (#93 for the "on what") | M + design | approve from anywhere |
| D | subagent hooks: count and ids on the pane, Claude only | (R5 in the design) | S | the "working" column's detail |
| E | `roost send --from LABEL` and a per-turn `sent_by` sidecar | #56, first half | S | the audit log |
| F | `roost close TGT`: end one agent its own way, then close its pane | #143 | S | the close flow |
| G | cut 0.7.0 | — | XS | — |

Not in Phase 0, on purpose, with where each goes: §8.

## 2. How this plan is run

The coordinator loop the roost releases have used (0.6.0, pull requests
#113–#116): **one pane per lane, one worktree per pane, report files, the
human merges.**

1. **Make the lane's worktree** from the primary checkout, inside the repo:

   ```sh
   git -C <roost> worktree add .claude/worktrees/<lane> -b worktree-<lane> main
   git -C <roost>/.claude/worktrees/<lane> rev-parse --short HEAD   # the Base sha
   ```

   The worktree lives under `.claude/worktrees/`, never beside the repository.
2. **Write the lane's report file first**, at
   `<roost>/.claude/reports/<lane>.md` (ignored by git), with the Base sha and
   the lane's task list. The builder appends to it; the coordinator reads it.
   No `roost read` for reports — a report is a file.
3. **Spawn one builder pane per lane** with `roost spawn <lane> <harness>`,
   `cd` into the worktree in the pane's first prompt, and hand it **only its
   lane**: the header of this plan, §3, and its own lane section. A builder
   reads one lane, not the whole file.
4. **Builders commit and stop.** No push, no pull request, no merge, no tag.
   One commit per task, the subject line given in the task.
5. **The coordinator verifies each claim** in the report against the branch
   before acting on it: run the lane's Check commands again, under `bash`,
   with a planted control where the check is "nothing changed". A builder's
   "all green" is a claim.
6. **Reviews run as a flock** (`airig:flock`) on the lane's diff, then the
   coordinator rebases the lane on `main`, pushes, and opens the pull request
   with the lane's issue in the body (`Closes #N`). At most two fix loops per
   lane; a third means the task was wrong, not the builder.
7. **The human reviews and squash-merges.** Then `airig:postmerge` for the
   lane. The next wave starts from the new `main`.

**Waves.** Lanes A, B, D, E and F touch different verbs and can run at once.
Lane C's design checkpoint (C0) also starts at once. Lane C's build (C1–C5)
starts only after the human has decided C0 **and** lane E is on `main`,
because C's "who answered" record uses E's sidecar. Lane G runs last.

```
wave 1:  A  B  D  E  F  C0(design, human decides)
wave 2:  C1–C5
wave 3:  G
```

**Expect merge conflicts** between lanes A and D (both edit
`scripts/roost-agent-state` and `scripts/lib/roost-jsonout.sh`), and on
`CHANGELOG.md` and `site/content/docs/driving-a-fleet.md` between every lane.
Resolve them by hand at rebase time. Never resolve by parsing conflict
markers with a script.

## 3. Global constraints — every lane, every task

- **Test command:** `bash tests/run.sh` from the worktree root, then
  `python3 tests/test-contrast.py`. A **non-zero exit** from `run.sh` means a
  test file died mid-run; the PASS/FAIL totals under-report that. Read the
  per-file lines. If the suite fails, **re-run once**: not reproducible,
  record it in the report and go on; reproducible, it is real.
- **Run one test file directly** to iterate: `bash tests/test-<name>.sh`. Note
  #136: a file with failing assertions can still exit 0 when run alone, so
  read its output, do not trust its exit code.
- **Ubuntu before the pull request.** CI runs tmux 3.4 with `dash` as `sh`
  and no agent binaries. Before a lane is handed back, run the suite once in
  a container from the worktree root:

  ```sh
  docker run --rm -v "$PWD":/w -w /w ubuntu:24.04 bash -c \
    'apt-get update -qq && apt-get install -y -qq tmux fzf git python3 >/dev/null && bash tests/run.sh'
  ```

  A test that only passes on the Mac is not done.
- **Two opencode adapters.** `adapters/opencode/roost.js` is for opencode
  1.x and `adapters/opencode/v2/tui.js` for opencode 2 (#150, #156). A
  change to what opencode reports lands in both, or the task says why not.
  The 2.x plugin knows only the chat in front of its terminal, has no
  transcript, and must not run `roost` outside its one serial `reconcile()`;
  read `docs/airig/specs/2026-10-02-opencode-2-adapter-design.md` §3 first.
  A second opencode 2 cannot be driven against a throwaway home while the
  user's own runs: 2.x keeps one background service per user.
- **bash 3.2 safe.** No `declare -A`, no `${var,,}`, no `printf '\uXXXX'`,
  no `read -N`. `bin/roost` runs on the macOS `/bin/bash`.
- **Tests use isolated sockets.** Every test drives `tmux -S "$ROOST_TEST_SOCK"`
  from `tests/lib.sh`. **Never** a bare `tmux`; never `tmux kill-server`
  without `-S` or `-L` naming a test socket. The live `-L roost` server holds
  the author's real agents. A test that needs `-L` follows AGENTS.md §2
  (`TMUX_TMPDIR` under `mktemp -d` and `roost_test_tmux_named_guard`).
- **Tests never touch a real home.** `HOME`, `XDG_CONFIG_HOME`,
  `XDG_STATE_HOME`, `ROOST_RECORD_DIR`, `CLAUDE_SETTINGS`, `CODEX_HOME`,
  `COPILOT_HOME`, `PI_CODING_AGENT_DIR` all point at temp dirs. Copy the shape
  of `run_install` in `tests/test-install.sh`, canary directory included.
- **The hot path stays cheap.** Nothing new runs on `PostToolUse` unless the
  task says so. One tmux command per hook call where possible, and an early
  exit when nothing changed. `docs/airig/specs/2026-09-16-pane-record-design.md`
  §M5 gives the measured cost of a hook write; stay inside it.
- **Comments are the product** (AGENTS.md §5). Move a comment with its line.
  Never shorten or drop one. New code carries the *why* in the same density.
- **Names that never change** (AGENTS.md §6): `@agent_state`,
  `@agent_since`. New pane options take the `@roost-` prefix.
- **Validate before it becomes an option or a path.** One line, no control
  characters, a length cap, absolute where a path is expected: the checks
  `--permission-request-hook` already applies to `transcript_path` in
  `scripts/roost-agent-state`. Reuse that code, do not re-derive it.
- **`--json` documents follow the json-output design**
  (`docs/airig/specs/2026-09-15-json-output-design.md`): additive fields,
  `schema` stays `1`, `null` for unknown, exit codes identical with and
  without the flag, encoding through `scripts/lib/roost-jsonout.sh`.
- **The record is additive** (pane-record design, "Reserved names"): new
  files in the pane directory, never a changed meaning for an existing one,
  `schema` stays `1`. Sidecars are `replies/NNNNNN.<field>`; a reader of
  turn files matches digits only, so a sidecar is invisible to it.
- **roost never answers a dialog on its own.** No hook, adapter, or verb other
  than `roost answer`, run by a person, ever sends a key into a dialog.
- **No home paths, names or e-mail addresses in anything committed.** Before
  each commit: `grep -rn "/Users/[a-z]" <files you touched>` returns nothing.
- **No provenance trailer in a commit message.** No session link, no agent
  attribution, no "generated with". The `commit-msg` hook refuses them; if it
  does, rewrite the message.
- **Changelog, not version.** Each lane adds its entry under `## [Unreleased]`
  in `CHANGELOG.md`, in the house style (bold first sentence, the issue
  number, what a user sees). Only lane G touches `VERSION`.
- **Docs ship in the lane.** A verb that is not on `roosting.dev` does not
  exist: `site/content/docs/driving-a-fleet.md` for coordinator verbs, the
  `--json` section of the same page for new fields, `skills/roost/SKILL.md`
  for what an agent may and may not run.
- **Builders do not publish.** Commit and stop. No push, pull request, merge,
  tag, release, or repository change. Say so in the report if one is needed.

## 4. Lane A — session identity on the pane (#141)

**Worktree:** `<roost>/.claude/worktrees/identity` · **Branch:** `worktree-identity`

Stamp four facts on every agent pane from its first event, show them in
`status --json`, and keep them in the pane record so a closed pane can still
be identified.

```
@roost-session      the harness's own session id
@roost-cwd          the agent's working directory, absolute
@roost-harness      claude | codex | opencode | copilot | pi
@roost-transcript   the transcript path, absolute (exists today, written only when blocked)
```

### Task A1 — measure what each harness gives, and write it down

**Files:** `docs/airig/specs/2026-10-08-pane-identity-design.md` (new)
**Depends on:** nothing

**Do:**
1. For Claude Code: on a throwaway `-S` server whose socket path ends in
   `/roost` (so roost's own hooks act on it), with the fake Messages API rig
   from `tests/live/claude-stop-failure-smoke.sh` and the event logger
   `tests/live/event-log.js`, log the `SessionStart` and the first
   `UserPromptSubmit` payload. Record: which of `session_id`,
   `transcript_path`, `cwd` each carries; what `/clear` does to `session_id`;
   what `claude --resume` does; whether `cwd` is the launch directory or the
   current one. Note the Claude version (`claude --version`).
2. For codex: the same with `tests/live/codex-smoke.sh`'s rig, logging the
   `UserPromptSubmit` payload; note whether a `SessionStart` event exists
   and what it carries (`adapters/codex/roost-codex-hook` line 93 lists the
   events codex offers). Note `codex --version`.
3. For opencode, copilot and pi: read the adapter's session-start event
   object in `tests/opencode-plugin-harness.mjs`,
   `tests/copilot-extension-harness.mjs` and `tests/pi-extension-harness.mjs`
   fixtures, and the live smoke in `tests/live/` where one exists. Record
   which fields exist. Where a field is not available, write **not
   available** and the version checked. Do not guess.
4. Write the spec: one table, five harnesses by four fields, a version per
   row, and a "Decisions" section that says, per harness, which event stamps
   identity and which fields it can fill.

**Check:** the file exists; the table has five rows and four columns; every
cell is a value, "not available", or "not measured" with a reason; every row
names a version. `grep -c 'not measured' docs/airig/specs/2026-10-08-pane-identity-design.md`
is at most 2, and each is explained.
**Commit:** `docs: measure what each harness reports about its own session, for #141`

### Task A2 — the identity library, test first

**Files:** `scripts/lib/roost-identity.sh` (new), `tests/test-identity.sh` (new)
**Depends on:** A1

**Do:**
1. Write `tests/test-identity.sh` first, using `roost_test_server` from
   `tests/lib.sh` and `ROOST_RECORD_DIR` at a temp dir. It must assert, by
   behaviour:
   - after one stamp, the four pane options hold the given values;
   - a value with a newline, a tab, or a control character is refused and
     the option stays unset;
   - a relative `cwd` or `transcript` is refused;
   - a value over 512 bytes is refused;
   - a second stamp with identical values runs **one** tmux read and **no**
     tmux write (assert through a `with_path_shim` tmux wrapper that counts
     `set-option` calls, the shape `tests/test-agent-state.sh` uses);
   - a changed session id replaces the old one;
   - the record directory for the pane gains files `session_id`, `cwd`,
     `harness`, `transcript` with the same values, mode `0600`;
   - a stamp **never** sets or changes `@agent_state`.
   Run it; it fails because the library does not exist.
2. Write `scripts/lib/roost-identity.sh` with one function,
   `roost_identity_stamp PANE SESSION CWD HARNESS TRANSCRIPT`. Empty
   arguments mean "leave that field alone". Validate with the same checks
   `scripts/roost-agent-state` applies to `transcript_path` (reuse the
   function, do not copy it; move it into the library if it is inline and
   source the library from the state script). Read the four current values
   in one `display-message -p` call; exit early when nothing changed; write
   all changed options in one `set-option` command line; then write the
   record files through `roost_record_put_pane` in
   `scripts/lib/roost-record.sh`.
3. Run the test until green. Run the full suite.

**Check:** `bash tests/test-identity.sh` → every assertion `PASS`, none
`FAIL`, and `bash tests/run.sh` exits 0 with no new failures.
**Commit:** `identity: one library stamps session, cwd, harness and transcript on a pane (#141)`

### Task A3 — `roost identify`, the public command for adapters

**Files:** `bin/roost` (dispatch beside `state)`; the help text),
`tests/test-state-cmd.sh`
**Depends on:** A2

**Do:**
1. Add `roost identify --session ID --cwd DIR --harness NAME [--transcript PATH] [--json]`.
   It resolves its own pane the way `roost state` does (from `$TMUX_PANE`,
   only on a roost socket, silent no-op elsewhere) and calls
   `roost_identity_stamp`. `--json` echoes after the write, the shape
   `roost state --json` uses: `{"schema":1,"command":"identify","pane":"%N","landed":true,...}`
   with the four values as stored.
2. Exit codes: `0` landed or silent no-op outside roost; `1` a value was
   refused (stderr names the field); `2` usage.
3. Tests in `tests/test-state-cmd.sh`: landed, refused, no-op outside a roost
   pane, `--json` round trip.

**Check:** `bash tests/test-state-cmd.sh` → all `PASS`; `roost help` shows
the verb in one line beside `roost state`.
**Commit:** `roost identify: an adapter's one call to record who it is (#141)`

### Task A4 — Claude Code stamps identity at SessionStart and on each prompt

**Files:** `scripts/roost-session-context`, `scripts/roost-agent-state`,
`tests/test-session-context.sh`, `tests/test-agent-state.sh`
**Depends on:** A2, A1's Claude row

**Do:**
1. `scripts/roost-session-context` runs on `SessionStart` and today reads
   nothing from stdin. When stdin is not a tty (`[ ! -t 0 ]`), read the
   payload with the same one-reader shape `--permission-request-hook` uses
   in `roost-agent-state`, take `session_id`, `transcript_path`, `cwd`, and
   call `roost_identity_stamp` with harness `claude`. The context JSON it
   prints is unchanged, byte for byte.
2. In `scripts/roost-agent-state`, on `working` **without** `--tool-hook`
   (that is `UserPromptSubmit`, once per turn — never the `PostToolUse` hot
   path), read the same three fields and stamp. A `/clear` gives a new
   session id mid-process; this is where it is caught.
3. Tests: a fixture payload for each hook with the three fields; assert the
   options after `SessionStart` alone; assert a changed `session_id` on the
   next `UserPromptSubmit` replaces it; assert a `PostToolUse` call with a
   different `session_id` in its payload changes **nothing** (the hot-path
   guard, as a mutation target); assert the context JSON printed is
   byte-identical to before (keep the existing golden).

**Check:** `bash tests/test-session-context.sh && bash tests/test-agent-state.sh`
→ all `PASS`.
**Commit:** `claude: stamp session, cwd and transcript at SessionStart and on every prompt (#141)`

### Task A5 — codex stamps identity from its hook payload

**Files:** `adapters/codex/roost-codex-hook`, `tests/test-codex-hook.sh`
**Depends on:** A3, A1's codex row

**Do:**
1. On the `UserPromptSubmit` event the hook already handles, read
   `session_id`, `cwd` and `transcript_path` (the names A1 measured) and run
   `roost identify --harness codex ...`. Use `UserPromptSubmit`, which is
   already in `roost_hooks_codex`; **do not add a `SessionStart` entry** to
   the codex hook set. The set is hashed by codex (`scripts/lib/roost-hooks.sh`,
   header) and a changed set silently un-wires older installs. If A1 shows a
   field is only on `SessionStart`, record that as a gap in the spec and
   stamp what `UserPromptSubmit` has.
2. Tests: feed the fixture payload, assert the options and record files.

**Check:** `bash tests/test-codex-hook.sh` → all `PASS`.
**Commit:** `codex: stamp session, cwd and transcript from the prompt hook (#141)`

### Task A6 — opencode, copilot and pi call `roost identify`

**Files:** `adapters/opencode/roost.js` (opencode 1.x),
`adapters/opencode/v2/tui.js` (opencode 2, the terminal-side plugin from
#150), `adapters/copilot/extension.mjs`, `adapters/pi/roost.ts`,
`tests/test-opencode-plugin.sh`, `tests/test-opencode2-plugin.sh`,
`tests/test-copilot-extension.sh`, `tests/test-pi-extension.sh` and their
`*-harness.mjs` / `.ts` files
**Depends on:** A3, A1's rows

**Do:**
1. In each adapter, at its session-start event (opencode `session.created`
   for a session with no `parentID`; copilot's session start; pi
   `session_start`), spawn `roost identify` once with what the event has:
   the session id, `process.cwd()` for the directory, the harness name, the
   transcript path where A1 found one. The call is a silent no-op when the
   process is not in a roost pane, the same rule `roost state` applies.
2. One spawn per session start, not per event; a child session (opencode's
   `parentID`) never calls it.
   **opencode 2 is different:** its plugin runs in the terminal, one
   terminal shows one chat at a time and can switch tabs, and nothing on
   disk is a transcript. Identify the chat in front, from inside the one
   serial `reconcile()` the adapter has (its design forbids a `roost` call
   anywhere else), re-identify when the front chat changes, pass
   `process.cwd()` as the directory and no transcript. The home screen
   identifies nothing. Test it in `tests/opencode2-plugin-harness.mjs` with
   the `tabs.jsonl` fixture.
3. Extend each offline harness test: the fixture stream includes a session
   start and the test asserts exactly one `identify` call with the expected
   arguments, and zero for a child session.

**Check:** `bash tests/test-opencode-plugin.sh && bash tests/test-opencode2-plugin.sh && bash tests/test-copilot-extension.sh && bash tests/test-pi-extension.sh`
→ all `PASS` (the pi harness needs Node 22.18+; it prints `SKIP` on older,
which is not a pass — check `node --version`).
**Commit:** `adapters: opencode, copilot and pi record their session on the pane (#141)`

### Task A7 — `status --json` shows the four fields; docs; changelog

**Files:** `scripts/lib/roost-jsonout.sh` (`roost_jsonout_status`),
`tests/test-json-output.sh`, `site/content/docs/driving-a-fleet.md`
(the `--json` section), `CHANGELOG.md`
**Depends on:** A2

**Do:**
1. Add `session`, `cwd`, `harness`, `transcript` to each pane object, read in
   the same `list-panes` format string as the other fields (one tmux call,
   no per-pane round trip). `null` when the option is unset. `schema` stays
   `1`.
2. Tests: a stamped pane shows the values; an unstamped pane shows four
   `null`s; the human `roost status` output is byte-identical to before
   (golden).
3. Docs: the four fields in the `--json` field table with one line each.
   Changelog entry under `[Unreleased]` / `### Added`.

**Check:** `bash tests/test-json-output.sh` → all `PASS`; `bash tests/run.sh`
exits 0; the Ubuntu container run from §3 exits 0.
**Commit:** `status --json: session, cwd, harness and transcript on every pane (#141)`

## 5. Lane B — `roost events` (#98)

**Worktree:** `<roost>/.claude/worktrees/events` · **Branch:** `worktree-events`

One file, one line per state change, and a reader that can tail it and
resume from a cursor. No daemon, no socket.

```
{"schema":1,"seq":412,"ts":1791401187,"pane":"%12","window":"@4","from":"working","to":"blocked","turn":7,"reason":""}
```

The file is `$(roost_record_root)/events.log` (beside `panes/`; the same
`ROOST_RECORD_DIR` / `XDG_STATE_HOME` rules, so a test points it at a temp
dir, and setting `ROOST_RECORD_DIR` to empty turns events off with the
replies). `reason` is `@roost-error-reason` on `error`, else empty.

### Task B1 — the writer, in the one place state changes, test first

**Files:** `scripts/lib/roost-events.sh` (new), `scripts/roost-agent-state`,
`tests/test-events.sh` (new)
**Depends on:** nothing

**Do:**
1. Write `tests/test-events.sh` first: with `ROOST_RECORD_DIR` at a temp dir,
   drive `roost state working`, `roost state blocked`, `roost state done`
   from a test pane and assert three lines, `seq` 1, 2, 3, `from`/`to`
   correct, `turn` equal to `@roost-reply-turn` or `null`; a repeated
   `roost state done` appends **nothing** (the unchanged-state early bail is
   before the writer); with `ROOST_RECORD_DIR=""` nothing is written and
   nothing is printed on stderr; a `pane` value is JSON-escaped through
   `roost_jsonout_encode`; the file is `0600`. Run it; it fails.
2. `scripts/lib/roost-events.sh`: `roost_events_append PANE WINDOW FROM TO TURN REASON`.
   Read the last line's `seq` with `tail -n 1` (the file is small by
   construction, see B2's rotation), add one, append with a single `printf >>`
   (one write under 4 KB is atomic on both platforms). Create the file
   `0600` with `umask 077` the first time.
3. Call it from `scripts/roost-agent-state` **after** the unchanged-state
   bail, so the hot path (`PostToolUse` with no change) never reaches it. The
   `from` value is the state read in the same `display-message` the script
   already does; do not add a tmux call.
4. Measure the added cost of one changed-state hook call with the method in
   the pane-record design §M5 and write the number into the library header.

**Check:** `bash tests/test-events.sh` → all `PASS`; `bash tests/test-agent-state.sh`
still all `PASS`.
**Commit:** `events: every state change appends one JSON line to events.log (#98)`

### Task B2 — rotation, bounded by size

**Files:** `scripts/lib/roost-events.sh`, `tests/test-events.sh`
**Depends on:** B1

**Do:**
1. Before appending, if `events.log` is over 1 MiB (`wc -c`, no `stat`
   flags: they differ between BSD and GNU), `mv events.log events.log.1`
   (replacing any older `.1`) and start fresh. `seq` continues from the moved
   file's last line, so a cursor stays valid across a rotation.
2. Tests: seed a file just under the limit, append once, assert `.1` exists
   and `seq` continued; a second rotation drops the oldest.

**Check:** `bash tests/test-events.sh` → all `PASS`.
**Commit:** `events: rotate at 1 MiB and keep one older file, seq continues (#98)`

### Task B3 — the reader: `roost events [--since SEQ] [--follow] [--pane %N] [--json]`

**Files:** `bin/roost` (dispatch and help), `tests/test-events.sh`
**Depends on:** B2

**Do:**
1. Without `--follow`: print `events.log.1` then `events.log`, filtered by
   `seq > SEQ` when `--since` is given, by `pane` when `--pane` is given.
   Filtering is one `awk` over both files; the line is printed as stored.
   `--json` changes nothing (the output is already JSON lines) and is
   accepted so callers can be uniform.
2. With `--follow`: print as above, then `tail -n 0 -F events.log` (both
   `tail`s support `-F`, and `-F` survives B2's rename), still filtered.
   `--follow` stops when its stdout closes.
3. A missing file is an empty result, exit 0. A `--since` that is not a
   non-negative integer exits 2 with a usage line. Outside any roost server
   context (no record root) exit 1 with one line on stderr.
4. Tests: `--since` skips exactly the older lines across a rotation; `--pane`
   filters; `--follow` run in the background with a 5 s `timeout` wrapper of
   the kind `tests/test-wait-done-timeout.sh` uses, then a new `roost state`
   from the pane; the background reader prints the new line within 2 s and
   is killed by the test; no `--follow` process survives the test (assert
   with `pgrep -f` on the temp path).

**Check:** `bash tests/test-events.sh` → all `PASS`; `bash tests/run.sh` exits 0.
**Commit:** `roost events: print and follow the state log from a cursor (#98)`

### Task B4 — forget clears it, doctor names it, docs, changelog

**Files:** `bin/roost` (`forget --all`), `scripts/roost-doctor`,
`site/content/docs/driving-a-fleet.md`, `skills/roost/SKILL.md`,
`CHANGELOG.md`, `tests/test-doctor.sh`, `tests/test-events.sh`
**Depends on:** B3

**Do:**
1. `roost forget --all` removes `events.log` and `events.log.1`. `forget TGT`
   and `--gone` leave the log alone (one pane's lines are not one pane's
   file; say so in the help text).
2. `roost doctor` prints the events path and its size in the same block as
   the kept-replies directory (#89 asks for that block; add the one line).
3. Docs: a "Watch the fleet: `roost events`" section after the `wait-done`
   material in driving-a-fleet.md, with the line format, the cursor rule,
   and the off switch. One paragraph in SKILL.md: a coordinator that waits
   for several panes follows events rather than polling `status`.
4. Changelog entry under `### Added`.

**Check:** `bash tests/test-doctor.sh && bash tests/test-events.sh` → all
`PASS`; the Ubuntu container run from §3 exits 0.
**Commit:** `events: forget clears the log, doctor names it, docs (#98)`

## 6. Lane C — `roost answer` (#142, with #93's "on what")

**Worktree:** `<roost>/.claude/worktrees/answer` · **Branch:** `worktree-answer`

The human's verb for a dialog. It runs when a person runs it, from any
shell, any machine over `roost ssh`, or a board acting for that person. It
refuses an agent, refuses a pane that is not blocked, refuses a dialog that
is not the one the caller saw, refuses a key it has not measured, sends one
key sequence, and confirms it landed. It never retries.

### Task C0 — the design checkpoint: three contracts the human decides

**Files:** `docs/airig/specs/2026-10-08-answer-design.md` (new)
**Depends on:** nothing. **Runs in its own design pane** (`airig:design`),
and the human decides before C1 starts.

**Do:** write the design with the measurements below and the three
questions, each with the proposal here as option A and one alternative as
option B. The builder of C1–C5 reads the decided file, not this task.

1. **Measure the key maps** on a throwaway `-S` server with the fake Messages
   API rig (`tests/live/claude-decline-smoke.sh` opens a real permission
   dialog; extend it to script an `AskUserQuestion` with three options), and
   codex with `tests/live/codex-smoke.sh`. For each dialog shape record:
   which key approves, which denies, whether a digit both picks and confirms
   or only moves the cursor, and the minimum gap between keys (the sibling
   project measured keys under ~400 ms apart being dropped). Record the
   harness version.
   Shapes for the first cut: Claude permission prompt (approve, deny); Claude
   `AskUserQuestion` single-select (`--option N`); codex command approval
   (approve, deny). Everything else is **refused and named** in this cut.
2. **Q1 — exit codes.** They must not collide with `send`'s `1` (never left
   the input line), `2` (no such target), `3` (blocked, refused), `4` (no
   turn began). Proposal A: `0` landed; `2` no such target (same meaning as
   `send`); `3` target is not `blocked`; `5` `--expect` mismatch; `6` caller
   is an agent and no `--force`; `7` no measured map for this harness or
   shape; `8` key sent but the pane did not leave `blocked` within the bound.
   Option B: `1` for every refusal with the reason only on stderr.
3. **Q2 — the fingerprint, and where it lives.** Proposal A: `status --json`
   gains, per pane, `blocked_on` (the `@roost-blocked-on` text, or `null`)
   and `blocked_fingerprint`: the POSIX `cksum` of `@roost-blocked-on`, a
   tab, and `@agent_since`, printed as `<crc>-<since>`; `null` when not
   blocked. `--expect` takes that string. Option B: `--expect` takes the
   `blocked_on` text itself and `answer` compares it whole.
4. **Q3 — how "the caller is a human" is decided.** Proposal A: refuse when
   `$TMUX_PANE` names a live pane on **this** roost server, unless `--force`;
   when #105's ancestry walk lands, also refuse a caller whose ancestry
   reaches a pane on this server with a scrubbed environment; document
   plainly that an agent that unsets `$TMUX_PANE` passes today, and that the
   refusal is a guard against accident, not against intent. Option B: no
   check, documentation only.
5. The bound for "it landed" is 5 s, and what counts as landed is: the pane
   leaves `blocked`, **or** `blocked_fingerprint` changes (the next dialog of
   the same turn opened).

**Check (human-eye, blocks C1):** the human has written `Decided: A|B` under
each of Q1–Q3 in the spec, and the key-map table has a version on every row.
**Commit:** `docs: the roost answer design, measured key maps and three decisions (#142)`

### Task C1 — `blocked_on` and `blocked_fingerprint` in `status --json`

**Files:** `scripts/lib/roost-jsonout.sh`, `scripts/lib/roost-answer.sh`
(new: the fingerprint function only, for now), `tests/test-json-output.sh`
**Depends on:** C0 decided; lane A on `main` (its `list-panes` format line
is the one to extend)

**Do:**
1. `roost_answer_fingerprint BLOCKED_ON SINCE` in the new library, per Q2's
   decision. Pure function, no tmux.
2. Add both fields to the pane object in `roost_jsonout_status`, read in the
   existing `list-panes` format string. `null` when `@agent_state` is not
   `blocked`.
3. Tests: a pane stamped `blocked` with a planted `@roost-blocked-on` shows
   the text and a stable fingerprint; the same text with a different `since`
   gives a different fingerprint; a `done` pane shows two `null`s; the human
   `roost status` output is unchanged (golden).

**Check:** `bash tests/test-json-output.sh` → all `PASS`.
**Commit:** `status --json: what a blocked pane is blocked on, and a fingerprint of it (#93, #142)`

### Task C2 — the key map, one table, under test

**Files:** `scripts/lib/roost-answer.sh`, `tests/test-answer.sh` (new)
**Depends on:** C0 decided

**Do:**
1. Write `tests/test-answer.sh` with a pure-function section first:
   `roost_answer_keys HARNESS SHAPE VERB ARG` prints the `send-keys`
   arguments for every measured row of C0's table and exits `7` for any
   other combination. One assertion per table row, one for an unmeasured
   harness, one for an unmeasured shape, one for `--option 0` and
   `--option 10` (refused: options are 1–9 in this cut).
2. Implement the function as a `case` over `harness/shape/verb`, each row
   carrying a comment with the version and date it was measured. The shape
   comes from `@roost-blocked-on`'s prefix (`<tool_name>:` is a permission
   prompt; `AskUserQuestion:` is a question) — say in the comment that this
   is the only signal roost has and what it cannot distinguish.

**Check:** `bash tests/test-answer.sh` → all `PASS`.
**Commit:** `answer: one measured key map per harness and dialog shape (#142)`

### Task C3 — the verb

**Files:** `bin/roost` (dispatch and help), `scripts/lib/roost-answer.sh`,
`tests/test-answer.sh`
**Depends on:** C1, C2; lane E on `main`

**Do:**
1. `roost answer [--json] [--force] [--expect FP] TGT (--approve|--deny|--option N|--text TEXT)`.
   `--text` is accepted by the parser and refused with exit `7` in this cut
   (no measured shape takes free text yet), so the flag's name is reserved.
2. Guards, in this order, each before any key is sent: resolve TGT (exit `2`
   if gone); read `@agent_state`, `@roost-blocked-on`, `@agent_since`,
   `@roost-harness` in **one** `display-message`; not `blocked` → `3`;
   `--expect` given and the fingerprint differs → `5`; `$TMUX_PANE` names a
   live pane on this server and no `--force` → `6`; `roost_answer_keys`
   fails → `7`.
3. Send the keys with one `tmux send-keys -t TGT` against the roost server.
   Then poll every 100 ms, up to 5 s, in one `display-message` per tick,
   until the state leaves `blocked` or the fingerprint changes → `0`. Else
   `8`, and stderr says the key was sent once and will not be resent.
4. Record who answered: write the sidecar `replies/NNNNNN.answered_by` for
   the pane's current turn, with the same label rules and the same writer
   function lane E added for `sent_by` (`roost_record_put_turn_field`).
   The label is `--from LABEL` if given, else `human`.
5. `--json`: `{"schema":1,"command":"answer","pane":"%N","verb":"approve","landed":true,"fingerprint":"…","exit":0}`;
   on a refusal, stdout empty and the exit code as above (json-output design,
   "runtime failure").
6. Tests, with no real harness: a "dialog" is a pane running a script that
   stamps `roost state blocked` with a planted `@roost-blocked-on` and
   `@roost-harness claude`, then `read -n1`s one key and stamps `working`.
   Assert: `--approve` sends `1`, the pane leaves `blocked`, exit `0`,
   sidecar written; each refusal exits its code **and** the script never
   receives a key (assert the script's key log is empty); `--expect` with a
   stale fingerprint exits `5`; a caller with `TMUX_PANE` set to a live pane
   exits `6`, and `--force` passes; a pane whose script never clears
   `blocked` yields `8` after about 5 s and exactly one key in its log.
   Mutation that must turn a test red: remove the `--expect` comparison.

**Check:** `bash tests/test-answer.sh` → all `PASS`; `bash tests/run.sh` exits 0.
**Commit:** `roost answer: the human's verb for a dialog, refuses before it sends (#142)`

### Task C4 — live drive against a real Claude and a real codex

**Files:** `tests/live/answer-smoke.sh` (new)
**Depends on:** C3

**Do:**
1. Reuse the rig of `tests/live/claude-decline-smoke.sh`: a throwaway `-S`
   socket whose path ends in `/roost`, a redirected `HOME`, a fake Messages
   API that scripts a `Bash` call (opens a permission dialog) and then an
   `AskUserQuestion` with three options. From **outside** any roost pane
   (`env -u TMUX_PANE`), run `roost answer --approve` on the first and
   `roost answer --option 2` on the second, each with `--expect` taken from
   `status --json` just before. Assert exit `0` both times, and that the
   transcript's next record shows the tool ran and option 2 was chosen.
2. The same for codex command approval with `tests/live/codex-smoke.sh`'s
   rig: `--approve` then `--deny`.
3. The script prints `SKIP` and exits 0 when `claude` or `codex` is not on
   `PATH`, the way the other live smokes do, so CI is not affected.

**Check:** `bash tests/live/answer-smoke.sh` on the author's machine →
`PASS` lines for all four answers and exit 0. Not run in CI.
**Commit:** `answer: a live smoke proves approve and option 2 land on Claude and codex (#142)`

### Task C5 — docs, skill, changelog, known gap

**Files:** `site/content/docs/driving-a-fleet.md`, `skills/roost/SKILL.md`,
`docs/known-gaps.md`, `CHANGELOG.md`
**Depends on:** C3

**Do:**
1. driving-a-fleet.md: an "Answer a dialog from anywhere: `roost answer`"
   section with the verbs, the `--expect` loop (`status --json` → act →
   `answer --expect`), the exit code table, and the rule in bold: roost never
   answers on its own.
2. SKILL.md: one paragraph under the `blocked` material: an agent does not
   run `roost answer`; it is refused by design, and `--force` is for a human
   who is sure.
3. known-gaps.md, under "Live risks": what Q3's human check cannot prove, and
   which dialog shapes are refused in this cut, each with the exit code a
   caller sees.
4. Changelog entry under `### Added`.

**Check:** `grep -n 'roost answer' site/content/docs/driving-a-fleet.md skills/roost/SKILL.md docs/known-gaps.md`
hits all three files; `bash scripts/verify-site.sh` passes if the site
builds locally (skip with a note in the report if Node is not set up).
**Commit:** `docs: roost answer, what it refuses and what it cannot prove (#142)`

## 7. Lane D — subagent hooks, a count on the pane (Claude only)

**Worktree:** `<roost>/.claude/worktrees/subagents` · **Branch:** `worktree-subagents`

Record how many subagents a Claude pane has running, and their ids. **This
lane never changes a badge.** Whether background work holds `working` is
the turn-over design's question (#97, step 1 there), not this lane's. Q7 of
that design applies: Claude only, say so.

### Task D1 — measure `SubagentStart` and `SubagentStop`

**Files:** `docs/airig/specs/2026-09-29-turn-over-design.md` (a new
subsection "M10. Subagent hooks", measurements only, no decision changed)
**Depends on:** nothing

**Do:**
1. With the logger rig the design's §2 describes (31 hook events logged on a
   throwaway `-S` server), script one `Agent` call and log both events.
   Record each payload's fields (`agent_id`, `agent_type`, any transcript
   path), whether `SubagentStart` fires for the empty-`agent_type` helper
   fork that M4 saw on every `Stop`, and the order relative to `Stop`. Note
   the Claude version.

**Check:** the subsection exists, names the version, and answers the three
questions above with "measured" or "not seen in N runs".
**Commit:** `docs: measure Claude's SubagentStart and SubagentStop payloads`

### Task D2 — the two hooks, a count and ids on the pane, test first

**Files:** `scripts/lib/roost-hooks.sh` (`roost_hooks_claude`),
`scripts/roost-agent-state` (new flag `--subagent-hook start|stop`),
`tests/test-agent-state.sh`, `tests/test-hook-source.sh`,
`tests/test-install.sh`, `tests/test-wiring.sh`
**Depends on:** D1

**Do:**
1. Tests first: feed a `SubagentStart` payload, assert `@roost-subagents` is
   `1` and `@roost-subagent-ids` holds the id; a second start → `2`; a stop
   → `1`; a stop for an id never started changes nothing; a payload with
   `agent_type` empty changes nothing; **`@agent_state` is never written** by
   either (mutation target); the id list is capped at 32 ids and the count
   keeps counting past it.
2. Add `SubagentStart` and `SubagentStop` entries to `roost_hooks_claude`,
   each running `roost-agent-state --subagent-hook start|stop`. The flag
   reads stdin the way `--stop-hook` does, touches only the two
   `@roost-subagent*` options in one `set-option` command, and exits before
   any state logic. Update every test that holds the hook set as a golden
   (`test-hook-source.sh`, `test-install.sh`, `test-wiring.sh`) and the
   comment block in `roost_hooks_claude` that explains each entry.
3. `roost install` and roost-owned wiring (#58) ship the new set by
   construction; add one assertion in `test-wiring.sh` that the generated
   settings carry both entries.

**Check:** `bash tests/test-agent-state.sh && bash tests/test-hook-source.sh && bash tests/test-install.sh && bash tests/test-wiring.sh`
→ all `PASS`.
**Commit:** `claude: count running subagents on the pane from SubagentStart and SubagentStop`

### Task D3 — `subagents` in `status --json`, docs, changelog

**Files:** `scripts/lib/roost-jsonout.sh`, `tests/test-json-output.sh`,
`site/content/docs/driving-a-fleet.md`, `site/content/docs/state-badges.md`,
`CHANGELOG.md`
**Depends on:** D2

**Do:**
1. `subagents`: integer, or `null` when the option is unset (never seen a
   subagent event). Read in the existing `list-panes` format string.
2. Docs: the field in the `--json` table; one paragraph in state-badges.md
   saying a count is not a badge, and that only Claude reports it.
3. Changelog under `### Added`.

**Check:** `bash tests/test-json-output.sh` → all `PASS`; the Ubuntu
container run from §3 exits 0.
**Commit:** `status --json: how many subagents a Claude pane is running`

## 8. Lane E — `roost send --from LABEL` and `sent_by` (#56, attribution half)

**Worktree:** `<roost>/.claude/worktrees/send-from` · **Branch:** `worktree-send-from`

Who sent each prompt, kept beside the turn. The text pasted into the pane
is **unchanged**: no envelope is added in this cut (the envelope and
`--when-idle` from #56 stay open). `send` without the flag is byte-identical
to today.

### Task E1 — the sidecar writer and the label, test first

**Files:** `scripts/lib/roost-record.sh` (`roost_record_put_turn_field`),
`bin/roost` (`send`), `tests/test-send-turn.sh`, `tests/test-reply-record.sh`
**Depends on:** nothing

**Do:**
1. Tests first, in `test-send-turn.sh`: after a `send` that prints `%N TURN`,
   the file `replies/<TURN zero-padded to 6>.sent_by` exists in the pane's
   record directory with the label; without `--from`, the label is `pane:%M`
   when the caller's `$TMUX_PANE` is a live pane on this server, else
   `human`; a `send` that exits `4` (no turn began) writes nothing; a label
   with a space, a control character, or more than 64 bytes is refused with
   exit `2` before anything is pasted; `roost read --turn N` still reads the
   turn (a sidecar is invisible to the digits-only reader, assert it).
2. `roost_record_put_turn_field PANE TURN FIELD VALUE` in the record
   library: atomic write (`mktemp` in the directory, then `mv`), `0600`,
   `FIELD` matched against `[a-z_]+` and `VALUE` one line.
3. `send --from LABEL`: validate, remember, and after the turn number is
   known (the existing wait for a new turn), write the sidecar. `--json`
   gains `"sent_by":"…"` (or `null` on exit `4`).

**Check:** `bash tests/test-send-turn.sh && bash tests/test-reply-record.sh`
→ all `PASS`.
**Commit:** `send --from: who sent each prompt, kept beside the turn (#56)`

### Task E2 — `read --json` shows it; docs; changelog

**Files:** `scripts/lib/roost-jsonout.sh` (the `read` document), `bin/roost`
(`read`), `tests/test-json-output.sh`, `site/content/docs/driving-a-fleet.md`,
`skills/roost/SKILL.md`, `CHANGELOG.md`
**Depends on:** E1

**Do:**
1. `roost read --json [--turn N]` gains `sent_by` (string or `null`), read
   from the sidecar beside the turn file.
2. Docs: the flag in the `send` material and the field in the `--json`
   table. SKILL.md: coordinators pass `--from "$me"` (their own `%N`), and
   the `[from %N]` prefix convention stays until the envelope ships.
3. Changelog under `### Added`.

**Check:** `bash tests/test-json-output.sh` → all `PASS`; the Ubuntu
container run from §3 exits 0.
**Commit:** `read --json: the sent_by label beside each turn (#56)`

## 9. Lane F — `roost close TGT` (#143)

**Worktree:** `<roost>/.claude/worktrees/close` · **Branch:** `worktree-close`

End one agent the harness's own way, wait, then close only that pane.

### Task F1 — the exit table, measured

**Files:** `scripts/lib/roost-adapters.sh` (the per-harness table already
there), `docs/airig/specs/2026-08-29-adapter-contract.md` (a short "Exit
command" row per harness in the tier table)
**Depends on:** nothing

**Do:**
1. For each harness, on the version installed, find the command that ends it
   cleanly from its own prompt (`/exit`, `/quit`, or none) and whether it
   opens a dialog on exit when work is running. Measure on a throwaway
   server with each `tests/live/*-smoke.sh` rig. Record command, version,
   and "dialog on exit: yes/no/not seen".
2. Put the table in `roost-adapters.sh` as one function,
   `roost_adapter_exit_command HARNESS`, that prints the command or exits 1
   for "none measured", with the version in a comment per row.

**Check:** a unit assertion per harness row in `tests/test-adapter-install.sh`
(or a new `tests/test-close.sh`, see F2) that the function prints the
measured string; `grep -c 'measured on' scripts/lib/roost-adapters.sh` is
at least 5.
**Commit:** `adapters: the measured exit command per harness, for roost close (#143)`

### Task F2 — the verb, test first

**Files:** `bin/roost` (dispatch and help), `tests/test-close.sh` (new)
**Depends on:** F1

**Do:**
1. Tests first. Panes on a test server:
   - a plain shell pane with no badge: `roost close %N` kills it, exit `0`,
     and a sibling pane in the same window survives (assert);
   - a pane running a fake agent script that stamps `done`, reads lines, and
     exits on the line `/exit`: `close` pastes `/exit` through the same
     submit path `send` uses, the script exits, the pane is gone, exit `0`,
     and the pane's record directory still exists with its replies;
   - a `working` pane: refused, exit `1`, pane still there; `--force` kills
     it, exit `0`;
   - a `blocked` pane: refused, exit `1`, no key sent;
   - a fake agent that ignores `/exit` for longer than the timeout: exit `1`,
     stderr says it timed out, pane still there (never a kill without
     `--force`);
   - a fake agent that stamps `blocked` on `/exit` (a "work is running"
     dialog): exit `1`, stderr says it is blocked, nothing answered;
   - a target that does not exist: exit `2`;
   - `--json` documents for `0`, `1`, `2`.
2. `roost close [--force] [--json] TGT [TIMEOUT_SEC]`, default timeout 10.
   Harness from `@roost-harness` (lane A) with a fallback to the
   `pane_current_command` heuristic `status` already uses; no badge means
   step 3 directly. Step 2 polls every 200 ms for the pane to be gone or
   its `pane_current_command` to be a shell. Step 3 is
   `tmux kill-pane -t %N` on the roost server, and only that.
3. Exit codes in `wait-done`'s shape: `0` closed, `1` refused or timed out,
   `2` already gone.

**Check:** `bash tests/test-close.sh` → all `PASS`; `bash tests/run.sh` exits 0.
**Commit:** `roost close: end one agent its own way, then close only its pane (#143)`

### Task F3 — docs, skill, changelog

**Files:** `site/content/docs/driving-a-fleet.md`, `skills/roost/SKILL.md`,
`CHANGELOG.md`
**Depends on:** F2

**Do:**
1. driving-a-fleet.md: "Close an agent: `roost close`" after the `spawn`
   material, with the three steps, the refusal rule, and that the record is
   kept.
2. SKILL.md: a coordinator closes its helpers with `roost close`, never
   `tmux kill-pane`; the "Helpers in your current window" section already
   says when to close, so point it at the verb.
3. Changelog under `### Added`.

**Check:** `grep -n 'roost close' site/content/docs/driving-a-fleet.md skills/roost/SKILL.md`
hits both; the Ubuntu container run from §3 exits 0.
**Commit:** `docs: roost close (#143)`

## 10. Lane G — cut 0.7.0

**Worktree:** `<roost>/.claude/worktrees/cut-0.7.0` · **Branch:** `worktree-cut-0.7.0`
**Depends on:** lanes A–F on `main`.

### Task G1 — version and changelog heading

**Files:** `VERSION`, `CHANGELOG.md`, `site/content/docs/changelog.md`

**Do:**
1. `VERSION` → `0.7.0` with a trailing newline (#67: no newline reads as
   unknown).
2. In `CHANGELOG.md`, turn `## [Unreleased]` into `## [0.7.0] - 2026-MM-DD`
   (the day the pull request opens) and add a fresh empty `## [Unreleased]`
   above it. Sync the site copy of the changelog.

**Check:** `bash scripts/roost-release-gate check .` prints nothing and
exits 0; `bash tests/test-release-gate.sh` → all `PASS`.
**Commit:** `Cut 0.7.0: fleet board groundwork — identity, events, answer, subagents, send --from, close`

## 11. Phase 0 is done when

From the searoost plan's acceptance for this phase, made checkable:

1. `bash tests/run.sh` exits 0 on macOS and in the Ubuntu container, on
   `main`, after lane G.
2. `bash tests/live/answer-smoke.sh` on the author's machine prints `PASS`
   for approve and option 2 on Claude, and approve and deny on codex.
3. On the live `-L roost` server: `roost spawn probe claude`, then
   `roost status --json` **before any prompt is typed** shows that pane
   with non-null `session`, `cwd`, `harness` and `transcript`. Then
   `roost close` on it exits 0 and the record directory remains.
4. `roost events --follow` in one pane prints a line within 2 s of a badge
   change in another.

## 12. Deferred checks — one pass at the end

1. Lane A — `roost status` (human output) on the live server: columns did not
   move and nothing new is printed for an unstamped pane.
2. Lane C — the human runs `roost answer --approve` themselves, from a plain
   shell outside roost, against a real Claude dialog on the live server, and
   watches the dialog close. The live smoke proves the choreography; this
   proves it from the chair.
3. Lane C — the desktop notification for a `blocked` pane still shows the
   same body as before (the fingerprint is JSON-only, never in a
   notification).
4. Lane F — `roost close` on a helper pane in a window with a second pane:
   the second pane keeps its size and focus.

## 13. Not in Phase 0, and where it goes

- **Spawn into a worktree** (#40, R4): Phase 3 of the searoost plan.
- **The turn-over fixes** (#95, #97, #105, R7): their own design is decided
  (`docs/airig/specs/2026-09-29-turn-over-design.md`, steps 1–5 not started).
  They run as a separate loop; lane D here is only a count and does not
  pre-empt step 1 there.
- **`idle` at session start** (#76): same hook point as lane A, kept its own
  change as #141 asks. First candidate after Phase 0.
- **The `send` envelope and `--when-idle`** (#56's other half): after lane E
  ships, if coordinators still ask for it.
- **`wait-done --json`** (#110): step 3 of the turn-over loop.
- **The board itself**: searoost, Phase 1, read-only, as a roost extension.
  It starts after lanes A, B and C are on `main`.
