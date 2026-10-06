# An adapter for opencode 2 — Plan

Design:     `docs/airig/specs/2026-10-02-opencode-2-adapter-design.md` (approved 2026-10-06, v4)
Repository: `$HOME/w/beatzball/roost/.claude/worktrees/opencode2-adapter`
Branch:     `worktree-opencode2-adapter`
Base:       `8cbafa1` (`main`, PR #153 merged)
Oracle:     automated (one deferred human-run batch at the end: the live smoke test)
Unattended: no

> **Repository path:** the worktree, never the primary checkout. Resolve it as
> `$(git -C "$HOME/w/beatzball/roost" worktree list | grep opencode2-adapter | awk '{print $1}')`
> and `cd` there. Before every commit: `git rev-parse --abbrev-ref HEAD` must
> print `worktree-opencode2-adapter`. Commit with a pathspec
> (`git commit -m ... -- <files>`), never a bare `git commit`: the index is
> shared and another agent's staged work rides along otherwise.

The branch already holds, before Task 1: the design (approved), and
`tests/fixtures/opencode2/` — the recorded opencode 2.0.20 event logs with a
README that says what each holds and how the payloads were clipped. **Read
that README before Task 3.** Nothing else is built.

## Global constraints

- **Test command:** `bash tests/run.sh` from the repository root. It runs every
  `tests/test-*.sh` and sums PASS/FAIL lines. A **non-zero exit** means a test
  file died mid-run, which the counts do not show; treat it as a failure. Also
  a CI step: `python3 tests/test-contrast.py`.
- **A test file always exits 0** and prints `  PASS: …` / `  FAIL: …` lines;
  `tests/run.sh` counts them. A node harness does the same and is wrapped by a
  `tests/test-*.sh` that skips when `node` is absent — copy
  `tests/test-opencode-plugin.sh` exactly.
- **Never run an opencode binary.** Not 1.x, not 2.x, not in a test, not by
  hand. 1.x and 2.x cannot share a data directory, and the machine this runs
  on has a real 1.x with real data. Every test that needs "an opencode on
  PATH" uses a stub script that prints a version line
  (`#!/bin/sh\necho "opencode v2.0.20"` or `echo "1.18.30"`), never a symlink
  to a real binary. The one script that does run a real 2.x is
  `tests/live/opencode2-smoke.sh` (Task 9), which is run by hand, by the
  human, and skips unless told which binary to use.
- **Never a bare `tmux` command, never `tmux kill-server` without `-S`
  naming a throwaway socket**: a live `-L roost` server holds real agents.
  Tests build their own servers under `mktemp -d /tmp/amx.XXXX` (short, for
  the socket path limit) — copy `tests/test-reply-channel.sh`'s header.
- **Tests never touch a real home.** Redirect `HOME`, `XDG_CONFIG_HOME`,
  `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `CLAUDE_SETTINGS`,
  `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, `CODEX_HOME`. `tests/test-install.sh`
  and `tests/test-doctor.sh` canary every one of these; copy their shape.
- **Node is 24 in CI** (`.github/workflows/ci.yml`). `node:test`'s
  `mock.timers` is available. ES modules only.
- **Before the final task, run the changed test files in
  `ubuntu:24.04`** (tmux 3.4, `dash` as `sh`, non-root, no `claude`, no
  `opencode`):
  `docker run --rm -v "$PWD":/src:ro ubuntu:24.04 bash -c 'apt-get update -qq >/dev/null && apt-get install -y -qq tmux fzf git python3 perl nodejs >/dev/null; useradd -m t; mkdir /work && tar -C /src --exclude=node_modules --exclude=.git --exclude=.claude --exclude=.airig -cf - . | tar -C /work -xf -; chown -R t /work; su t -c "cd /work && bash tests/test-X.sh"'`
  (Ubuntu's `nodejs` package may be older than 24; if `mock.timers` is
  missing there, the node harness must print one `SKIP` line and exit 0, the
  way it does without node at all.)
- **Comments are the product** (AGENTS.md §5). The 1.x adapter's `run()`
  helper comes over with every comment it carries. When you copy a line, its
  comment moves with it. Never shorten a comment to save space.
- **Public repository** (AGENTS.md §1): no real names, no `/Users/<name>`
  paths, no provenance trailers in commit messages. `.airig/leakcheck.sh
  <file>...` in this worktree checks a file against the same lists the git
  hooks use; run it on every new file and on `git diff` output before a
  commit.
- **What this plan does not touch:** `adapters/opencode/roost.js` (the 1.x
  adapter), `scripts/roost-wiring`, `scripts/lib/roost-opencode.sh`, the
  `#151` / `#152` ideas, `OPENCODE_CLI_CONFIG_CONTENT`, `OPENCODE_CONFIG_DIR`.

### The adapter in one paragraph (the design, §3)

`adapters/opencode/v2/tui.js` default-exports `{ id: "roost", setup(context) }`.
Events update a model only: one entry per session id, `{ phase, text, due }`.
One serial `reconcile()` is the only thing that runs `roost`: it reads the
front chat from `context.ui.router.current()`, asks opencode whether a dialog
is open (`context.data.session.family(front)`, then for each member
`permission.sync(id)` + `permission.list(id)`), and writes the pane —
`roost reply -` (text, or empty to clear) before `roost state <state>`. Every
event and a 1-second `setInterval` end by calling `reconcile()`. `blocked` is
never tracked, always asked. A reply is published once, when a turn of the
front chat ends; a front change clears the stored reply with an empty
`roost reply -`. `setup` writes the pane in full. The cleanup `setup` returns
stops the listener and timer and sets `disposed`; it kills nothing.

---

### Task 1 — Pin the one roost behaviour the adapter leans on

**Files:** `tests/test-reply-record.sh`
**Depends on:** nothing

The adapter clears a pane's stored reply with an empty `roost reply -`. That
works today (design §2.8: an empty reply records no turn and `roost read`
treats it as no reply) and nothing tests it. If it ever changes, the adapter
silently serves another chat's answer. Pin it.

**Do:**
1. Read `tests/test-reply-record.sh` top to bottom: how it enables the
   on-disk record (`tests/lib.sh` switches it off; this file sets its own
   directory), how it starts its throwaway server, and `as_pane`/`stored`
   helpers in the shape of `tests/test-reply-channel.sh`.
2. Add case 13, "an empty reply clears the pane and records no turn":
   - in the pane, `roost reply "ANSWER ONE"`, then `roost reply "ANSWER TWO"`;
     assert two turn files exist in the pane's record directory (this is the
     control: a non-empty reply adds a turn);
   - `printf '' | roost reply -` as the pane; assert exit 0, the turn-file
     count is still two, `@roost-reply` on the pane is empty, and `roost read
     <pane>` falls back to the screen with `no recorded reply` on stderr;
   - `roost read --turn 2 <pane>` still returns `ANSWER TWO` — the record is
     intact, only the pane's current reply is gone.
3. Run the file; every new line passes.

**Check:** `bash tests/test-reply-record.sh` → every line `PASS`, exit 0, and
the new case's five assertions are among them. Then, to prove the case can
fail: temporarily change `printf ''` to `printf 'x'` in your working copy, run
again, see the turn-count and `no recorded reply` assertions FAIL, revert.
**Commit:** `tests: an empty roost reply - records no turn and reads as no reply (#150)`

---

### Task 2 — The adapter table learns `opencode2`

**Files:** `scripts/lib/roost-adapters.sh`, `tests/test-adapter-install.sh`
**Depends on:** nothing

`roost install` and `roost doctor` read one table of "where an adapter goes
and what it points at". opencode 2's adapter is a **directory** symlink at a
different path. Add it as a harness key of its own, plus one function that
says which of the two opencode keys applies on this machine.

**Do:**
1. In `scripts/lib/roost-adapters.sh`:
   - `roost_adapter_home`: `opencode2)` → the same directory as `opencode`.
   - `roost_adapter_path`: `opencode2)` → `<home>/plugins/roost`.
   - `roost_adapter_target`: `opencode2)` → `<root>/adapters/opencode/v2`.
   - `roost_adapter_state`: accept `opencode2` beside the three symlink
     harnesses. `-ef` is true for a directory symlink and its target, so the
     four states need no change; say so in a comment.
   - Add `roost_adapter_key HARNESS`: prints `opencode2` when `$1` is
     `opencode` and `roost_opencode_v2` (from `scripts/lib/roost-opencode.sh`,
     which this file must source relative to its own `BASH_SOURCE`) returns 0;
     otherwise prints `$1` unchanged. Comment: every caller that acts on the
     opencode on PATH asks this, so install, doctor and validate cannot
     disagree about which adapter a machine gets.
   - Update the header comment's claim about which callers the table serves.
2. In `tests/test-adapter-install.sh`, add `make_versioned_shim VERSIONLINE
   NAME...` beside `make_harness_shim`: the same shim, except that the
   `opencode` stub prints `VERSIONLINE`. Then a section "the adapter table and
   opencode 2" asserting, by sourcing the lib in a `bash -c` with `PATH` set
   to a shim: `roost_adapter_key opencode` prints `opencode2` under a shim
   printing `opencode v2.0.20`, `opencode` under `1.18.30`, `opencode` under
   the silent stub, and `opencode` with no opencode on PATH;
   `roost_adapter_path opencode2` ends in `/opencode/plugins/roost`;
   `roost_adapter_target opencode2` ends in `/adapters/opencode/v2`;
   `roost_adapter_state opencode2` is `missing` in an empty home, `ok` after
   `ln -s <target> <path>`, `foreign` when a real directory sits at the path.

**Check:** `bash tests/test-adapter-install.sh` → all PASS, exit 0, the new
section's lines included. `bash tests/test-install.sh` and
`bash tests/test-validate-install.sh` still all PASS (they source the lib).
**Commit:** `adapters: the table knows opencode 2's plugin directory, and which opencode key a machine gets (#150)`

---

### Task 3 — The adapter and its harness: events, the model, `reconcile()`

**Files:** `adapters/opencode/v2/tui.js` (new), `tests/opencode2-plugin-harness.mjs` (new), `tests/test-opencode2-plugin.sh` (new)
**Depends on:** nothing (Task 1 is a precondition for correctness, not for building)

Test-first: write the harness and the cases of this task, see them fail with
no adapter, then write the adapter until they pass. The design's §3.1–§3.3 is
the specification; this task is the part of it that does not involve the
timer, a front change, `setup`'s first pass, or a reload — those are Task 4,
in the same two files.

**Do:**
1. Read, in this order: `adapters/opencode/roost.js` (the 1.x adapter; its
   `run()` helper and every comment on it are reused verbatim),
   `tests/opencode-plugin-harness.mjs` (the recording shim and the `calls()` /
   `replies()` / `verbs()` / `envNames()` / `replyVias()` readers — reuse the
   shape and the shim script), `tests/fixtures/opencode2/README.md`, and the
   design §2.2–§2.5 and §3.
2. `tests/test-opencode2-plugin.sh`: a copy of `tests/test-opencode-plugin.sh`
   that execs `tests/opencode2-plugin-harness.mjs`. If `node:test`'s
   `mock.timers` is unavailable (`typeof mock?.timers?.enable !== "function"`),
   the harness prints `  SKIP: node too old for mock timers` and exits 0.
3. The harness:
   - puts the recording `roost` shim first on `PATH` (the 1.x shim script,
     unchanged: it records verb, argument, `ROOST_AGENT_NAME`, transport);
   - builds a **fake context** per case: `data.listen(fn)` stores `fn` and
     returns a stop function; `ui.router.current()` returns what the case
     set; `data.session.status(id)`, `data.session.family(id)`,
     `data.session.permission.sync(id)` (async) and
     `data.session.permission.list(id)` return what the case scripted, per
     id, and the case can change them between steps; every call is counted;
   - `mock.timers.enable({ apis: ["setInterval"] })` — only `setInterval`;
     `setTimeout` stays real so the 2-second race in step 2 and the harness's
     own waits run on real time;
   - a `settle()` helper that waits until the shim log has not grown for
     300 ms of real time, then returns the rows — every assertion is made on
     a settled log;
   - loads fixtures from `tests/fixtures/opencode2/*.jsonl`: for each row with
     `what: "ev"`, the event is `JSON.parse(ev)` when `ev` does not end in `…`;
     when it does, the event is rebuilt from the row's `type` and `sid` plus
     the fields the README names for that type (`text` from the clipped
     payload's `"text":"…` prefix where present). Say in a comment which
     fixture and which line each case replays;
   - imports `adapters/opencode/v2/tui.js` fresh per case (`?case=N` on the
     import URL defeats the module cache) and calls `setup(context)`.
4. The adapter, `adapters/opencode/v2/tui.js`, per design §3.1–§3.3:
   - a header comment that says what it is, why it is a terminal-side plugin
     and not a server one, and where the measurements are (#150, the fixtures
     README);
   - `run()` and `report`/`publish` from 1.x, comments and all, with
     `ROOST_AGENT_NAME: "opencode"`;
   - the model (§3.2) and `reconcile()` (§3.3, all four steps) with the
     "trusted answer" rule and the 2-second race on `permission.sync`
     (`Promise.race` against a real `setTimeout`, both wrapped in try/catch);
   - `reconcile()` serial: an in-flight flag plus a "run again" flag, loop
     until neither; after every `await` re-read the front and check
     `disposed`;
   - the cap of 200 entries, evicting only `done`/`error`/`idle` entries,
     least recently touched first;
   - never throws: every entry point is wrapped, and a missing
     `context.data.listen` or `context.ui.router` leaves the pane unbadged.
5. Cases, each asserted as the exact ordered list of shim calls
   (`verbs()`), the states (`calls()`), the replies and their transport, and
   `ROOST_AGENT_NAME=opencode` on every row. The front is set once per case
   and never changes in this task:

   | case | fixture | asserts |
   |---|---|---|
   | a turn with no tool | `fresh.jsonl`, the first turn | `state working`, `reply` (stdin) with the fixture's text, `state done`, in that order |
   | a tool behind a dialog, allowed | `fresh.jsonl`, the subagent run's parent events **without** the child's | `working`, `blocked`, `working`, reply, `done`; the fake `permission.list` returns the request between `permission.asked` and `permission.replied` |
   | a subagent with its own dialog | `fresh.jsonl`, the subagent run whole | the child's `execution.succeeded` writes nothing; the child's text is never a reply; the dialog writes `blocked`, because the fake `family(front)` lists the child and `permission.list(child)` holds the request |
   | the same with every event before the child's first `session.text.ended` withheld | the same | `blocked` all the same |
   | two dialogs open in one family; the first is answered | built from the subagent run: a second `permission.asked` for the parent, then one `permission.replied` | still `blocked`; `working` only after the second `replied` |
   | `permission.sync` rejects on the first ask and works on the next | the dialog case | nothing written on the first pass; `blocked` on the second; nothing thrown |
   | `permission.sync` never settles | the dialog case | the pass ends inside 3 s (real time) and a later pass still writes |
   | answered turn, then Esc Esc | `fresh.jsonl`, the first turn then the interrupted one | second turn: `working`, **empty reply**, `done` |
   | answered turn, then Reject | `fresh.jsonl`, the first turn then the rejected one | `working`, `blocked`, `working`, **empty reply**, `done` |
   | answered turn, then a success with no prose | the first turn, then a copy of it with `session.text.ended` removed | **empty reply**, `done` |
   | a dead provider | `dead-provider.jsonl` | `working`, `error` once at attempt 3, nothing through attempts 4–11, **empty reply** at `failed`, still `error` |
   | `error` at attempt 3, then a dialog answered | `dead-provider.jsonl` to attempt 3, then the dialog events | `error`, `blocked`, `working` |
   | two chats interleaved, front is A | `fresh.jsonl`'s first turn as A, `tabs.jsonl`'s second chat as B, rows shuffled | only A's states and A's reply are written |
   | A succeeds; a queued prompt starts A's next turn before the pass that publishes | the first turn with `execution.started` of a second turn appended immediately | the reply **is** published, then `working` |
   | 201 chats, the oldest `done`; then its front | synthetic ids | the 201st does not throw; the evicted one, brought to the front, writes an empty reply then `idle` |
   | no `roost` on PATH; an event with no session id; an unknown type; a null payload | — | nothing thrown, process exits 0 |

   Each event case runs once more with a second, unrelated chat's events
   shuffled in (take them from `tabs.jsonl`'s second chat), asserting the
   same list.

**Check:** `bash tests/test-opencode2-plugin.sh` → every line PASS, exit 0.
Before writing the adapter: the same command with `adapters/opencode/v2/tui.js`
absent prints FAIL lines (the harness must not crash on a missing module; it
fails its cases). `bash tests/run.sh` picks the file up and its totals rise.
**Commit:** `adapters: an opencode 2 adapter — events, the model, and the one writer (#150)`

---

### Task 4 — Front changes, the timer, `setup`, and a reload

**Files:** `adapters/opencode/v2/tui.js`, `tests/opencode2-plugin-harness.mjs`
**Depends on:** Task 3

**Do:**
1. Add to the adapter: the 1-second `setInterval` whose only job is
   `reconcile()`; `setup`'s first pass writing the pane in full; the first
   tick after `setup` forgetting `written.state` only; the `due` dropped when
   its session leaves the front; the cleanup function (stop listener, clear
   timer, set `disposed`, kill nothing). Design §3.3 and §3.4.
2. Cases, using `mock.timers.tick(1000)` for "a second passed with no event":

   | case | asserts |
   |---|---|
   | front A → B → A → B, all four turns finished, **no events**, ticks only | each switch: empty reply, then the state; **no non-empty reply is ever written** |
   | front → a chat with an open dialog this instance never heard | empty reply, `blocked` (the fake `permission.list` has it) |
   | front → home | empty reply, `idle` |
   | `setup` on an idle chat, the shim's log pre-seeded as if another chat's `done` and reply were on the pane | empty reply, `idle`; after one tick `idle` again and **no second reply call** |
   | `setup` on a running chat / one with a pending request | empty reply, then `working` / `blocked` |
   | `setup` mid-turn; the turn succeeds with text before the first tick | empty reply, `working`, reply, `done`; the tick writes `done` again and **does not clear the reply** |
   | the slow-`reply` shim (a shim variant that sleeps 400 ms on `reply`): A succeeds, the front moves to B (running) while A's publish is in flight | the last `state` written is B's `working`; the last reply written is the empty one |
   | A succeeds in front; the front moves to B **before** the pass that would publish (hold the first pass with the slow shim); A runs a hidden turn and is interrupted; front → A | **no non-empty reply is ever written** |
   | a child's `permission.asked` arrives one pass before the fake `family()` lists it | `working` on that pass, `blocked` on the next tick |
   | a dialog open, then the front chat's turn `failed` with no `permission.replied`, and the fake `permission.list` now empty | `error`, not `blocked` |
   | cleanup, then a new `setup`, with the old instance's `roost` child made slow | after cleanup the old instance starts no new call (count the shim rows after the cleanup's timestamp); the new instance's `setup` writes, and its first tick writes the state again |
   | **the mutation**: the harness copies `tui.js` to a temp file with the `setInterval(` line deleted, imports that copy, and runs the first case of this table | that run must FAIL its assertions, and the harness reports **PASS: the timer-only case fails without the timer** |

**Check:** `bash tests/test-opencode2-plugin.sh` → every line PASS, exit 0,
including the mutation line. `bash tests/run.sh` exit 0.
**Commit:** `adapters: the opencode 2 adapter follows the chat in front, and survives a reload (#150)`

---

### Task 5 — The adapter's call pattern against the real `roost`

**Files:** `tests/test-opencode2-record.sh` (new)
**Depends on:** Task 1

The harness proves which `roost` calls the adapter makes. This proves what
those calls do to a real pane and its record: a tab flip must not grow the
turn record, and must leave `roost read` honest.

**Do:**
1. Copy the server, pane and record-directory setup from
   `tests/test-reply-record.sh`.
2. Replay, as the pane, exactly the call sequence Task 4's first case
   recorded for A → B → A → B (take it from the harness's own assertion):
   `roost reply - <A's text>`, `roost state done`, then for each switch
   `printf '' | roost reply -` followed by `roost state <state>`.
3. Assert: the pane's record holds exactly two turn files (A's and B's);
   `roost read <pane>` after the last switch says `no recorded reply` on
   stderr and returns the screen; `roost read --turn 1` and `--turn 2` return
   A's and B's texts; `roost state` reads `idle`/`done` as the sequence ends.
4. A control at the top of the file: replay the **first design's** pattern —
   a non-empty `roost reply -` on each switch — and assert the record holds
   **four** turn files. That is the failure this test exists to catch; the
   file must show it can see it.

**Check:** `bash tests/test-opencode2-record.sh` → all PASS, exit 0.
**Commit:** `tests: a tab flip through the opencode 2 adapter's calls leaves the turn record alone (#150)`

---

### Task 6 — `roost install` on an opencode 2 machine

**Files:** `scripts/roost-install`, `tests/test-adapter-install.sh`
**Depends on:** Task 2

**Do:**
1. Read `scripts/roost-install` around the harness loop (`for h in
   $HARNESSES`), `LINK_STEPS`, the apply loop that consumes `LINK_STEPS`, and
   the summary printing (`Already correct:`, `Detected:`).
2. In the loop, for `opencode` only: `k="$(roost_adapter_key "$h")"` and use
   `$k` in every `roost_adapter_state`/`_path`/`_target` call for that
   iteration; keep `$h` as the name the user sees. Comment why: one binary,
   two adapters, and the version decides.
3. When `$k` is `opencode2`: if `roost_adapter_state opencode` (the 1.x key)
   is `ok` or `dangling`, add an `unlink` step for `roost_adapter_path
   opencode` — it is roost's own 1.x link and it is what makes opencode 2
   print `1 plugin failed`. `foreign` is left alone and named in the summary,
   as today. Add `unlink` to the plan output ("Remove: …"), to the apply loop
   (`rm` the symlink, never a regular file — check `-L` first), and to the
   `--records` outcomes (`record_outcome removed …`).
4. `--only opencode` must cover both keys.
5. Tests, in `tests/test-adapter-install.sh`, with `make_versioned_shim` from
   Task 2 (and `make_json_shim`'s equivalent where a case needs a JSON tool):
   - 2.x, fresh home: the plan names `plugins/roost` and the `v2` target;
     after `--yes` the directory symlink exists and points at
     `adapters/opencode/v2`; **no** `plugin/roost.js` is created;
   - 2.x, our own 1.x link present: the plan says it will be removed; after
     `--yes` it is gone and `plugins/roost` is linked;
   - 2.x, a foreign file at `plugin/roost.js`: left untouched, still named;
   - 1.x (`1.18.30`), and the silent stub: exactly today's behaviour (the
     existing assertions, re-run under the versioned shim as the control);
   - `--only opencode` on 2.x links `plugins/roost`;
   - the `Already correct:` line on a 2.x re-run names opencode.

**Check:** `bash tests/test-adapter-install.sh` → all PASS, exit 0;
`bash tests/test-install.sh` → all PASS (it uses a silent `opencode` stub and
must be unchanged).
**Commit:** `install: on opencode 2, link the 2.x adapter directory and remove roost's own 1.x link (#150)`

---

### Task 7 — `roost doctor` on an opencode 2 machine

**Files:** `scripts/roost-doctor`, `tests/test-doctor.sh`
**Depends on:** Task 2

**Do:**
1. In `scripts/roost-doctor`, the branch `if [ "$oc_v2" = 1 ]; then` in the
   opencode adapter section: **remove** the `does not support opencode 2 yet`
   warning. In its place, the same four states the 1.x branch has, against
   `roost_adapter_path opencode2` / `roost_adapter_target opencode2`:
   `ok "opencode 2 plugin linked"`; not installed → `warn` with the exact
   `mkdir -p … && ln -s <target> <path>` and `, or run: roost install`;
   dangling → the `rm … && ln -s …` form; not this install → `relink it to
   <target>`. Keep the two other 2.x lines of that branch exactly as they are
   (the `OPENCODE_CONFIG_DIR` warning and the leftover 1.x `rm` line).
2. Tests in `tests/test-doctor.sh`, in the existing opencode 2 section (the
   stubs `oc2shim`/`oc1shim` are already there): replace the assertions that
   expect `does not support opencode 2 yet` and `issues/150` with: linked →
   `opencode 2 plugin linked`; nothing linked → `plugins/roost` and
   `adapters/opencode/v2` in the printed command, and `or run: roost install`;
   dangling → `dangling`; a real directory at the path → `not this install`.
   The 1.x control lines stay as they are. Keep every existing assertion
   about the `OPENCODE_CONFIG_DIR` line and the `1 plugin failed` line.

**Check:** `bash tests/test-doctor.sh` → all PASS, exit 0 (153 lines today;
the count changes). The sandbox canary lines still PASS.
**Commit:** `doctor: opencode 2 has an adapter now; check its link like every other (#150)`

---

### Task 8 — `roost validate` does not pretend to drive opencode 2

**Files:** `scripts/roost-validate`, `tests/test-validate-install.sh`
**Depends on:** Task 2

**Do:**
1. Read `scripts/roost-validate`: `h_prepare` (around `H_SKIP`), the adapter
   report loop (`for h in opencode pi copilot` near the middle of the file),
   and every other `roost_adapter_state opencode` / `_path opencode` call.
2. In `h_prepare`, before the cloud tier: if `$h` is `opencode` and
   `roost_opencode_v2`, set
   `H_SKIP='opencode 2 is not driven by roost validate yet — its adapter is checked by tests/live/opencode2-smoke.sh, run by hand (#150)'`
   and return. A skip, never a pass.
3. Everywhere validate reports on the opencode adapter's link, use
   `roost_adapter_key opencode` so a 2.x machine is reported against
   `plugins/roost`.
4. A test in `tests/test-validate-install.sh` (read its shape first: it
   sandboxes the adapter *offer* slice of validate with fake harness
   binaries). With a `2.0.20` stub on PATH, the offer names `plugins/roost`
   and `adapters/opencode/v2`; with `1.18.30` it names `plugin/roost.js` (the
   control). The `H_SKIP` line is in the drive path, which that file does not
   reach; it is checked by hand in deferred check 4, and the commit message
   says so.

**Check:** `bash tests/test-validate-install.sh` → all PASS, exit 0, the two
new lines included.
**Commit:** `validate: skip the opencode 2 drive with a reason, and report its 2.x link (#150)`

---

### Task 9 — The live smoke test for opencode 2

**Files:** `tests/live/opencode2-smoke.sh` (new)
**Depends on:** Task 4

This is the only script in the repository that runs a real opencode 2, and it
is run by hand. **Do not run it in this task**; the human runs it in the
deferred batch. Your check is that it refuses correctly and is sound.

**Do:**
1. Read `tests/live/opencode-smoke.sh` whole: the helpers (`ok`, `no`,
   `skip`, `state`, `wait_state`, `launch`, `report`), the config writer, the
   approve loop, and how it keeps logs. Reuse their shape.
2. Write `tests/live/opencode2-smoke.sh` per design §4 "Live":
   - `ROOST_OPENCODE2_BIN` names the binary; the script **skips** (prints
     `  SKIP: …`, exit 0) unless it is set, executable, and
     `"$ROOST_OPENCODE2_BIN" --version` — run with all five directories
     redirected into the test's own temp directory — prints a 2.x version;
     it never runs the `opencode` on `PATH`;
   - redirects `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`,
     `XDG_STATE_HOME`, `TMPDIR` under one `mktemp -d /tmp/amx.XXXX`; runs
     `debug paths` first and refuses to continue if any printed path is
     outside that directory; starts the binary by absolute path in every
     pane; runs `"$ROOST_OPENCODE2_BIN" service stop` and kills its own
     `tmux -S` server in an EXIT trap, then checks no process of that binary
     is left;
   - writes `opencode.json` with the free cloud model it finds first in
     `"$ROOST_OPENCODE2_BIN" models` under `opencode/`, the shell `ask` rule,
     and links `plugins/roost` to this checkout's `adapters/opencode/v2`;
   - a throwaway roost server (socket path ending in `/roost`) and `PATH`
     with this checkout's `bin` first, as the 1.x script does;
   - cases, asserting pane options: a plain turn → `done` and the reply via
     `roost read`; a shell call → `blocked` while the dialog is up, `done`
     after Allow; a `general` subagent's shell call → `blocked`, then `done`
     with the parent's reply; Esc Esc mid-turn → `done`, `roost read` says no
     reply; a second config with a provider on a closed port → `error`; two
     panes → pane A's badge unchanged while pane B runs a turn; and one
     terminal, two finished chats, `alt+down` only (`send-keys M-Down`) → the
     badge and `@roost-reply` change within three seconds.
3. `bash -n tests/live/opencode2-smoke.sh`, and run it with
   `ROOST_OPENCODE2_BIN` unset: it prints one SKIP line and exits 0.
   Run it with `ROOST_OPENCODE2_BIN` pointing at a stub that prints
   `1.18.30`: SKIP, exit 0, and nothing created outside its temp directory.

**Check:** `bash -n tests/live/opencode2-smoke.sh` → no output;
`bash tests/live/opencode2-smoke.sh` → `  SKIP: …`, exit 0. The real run is
deferred check 1.
**Commit:** `tests: a live smoke test that drives a real opencode 2, run by hand (#150)`

---

### Task 10 — Docs, the contract, the gaps, the changelog

**Files:** `site/content/docs/state-badges.md`, `site/content/docs/setup.md`, `site/content/docs/troubleshooting.md`, `site/content/docs/getting-started.md`, `README.md`, `docs/airig/specs/2026-08-29-adapter-contract.md`, `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md` (generated)
**Depends on:** Tasks 6, 7 (so the install and doctor wording is final)

**Do:**
1. Read `site/AGENTS.md` first. Then:
   - `state-badges.md`, the `## opencode` section: replace the "**This is for
     opencode 1.x. opencode 2 is not supported yet.**" paragraph with two
     sub-sections, "opencode 1.x" (the text that is there) and "opencode 2":
     `roost install` links `~/.config/opencode/plugins/roost`; the by-hand
     `ln -s`; that the badge follows **the chat on screen** and a hidden tab
     shows nothing; that after a tab switch `roost read` has no reply until
     the chat in front finishes a turn; that a roost update (a reload) turns a
     finished chat's badge to idle until its next turn; that a dialog in a
     subagent's chat badges `blocked`; and that `roost wiring` does not reach
     opencode 2 — `roost install` is the route.
   - `setup.md`: the "opencode 2 gets nothing, on purpose" bullet stays (it
     is about wiring); add one sentence pointing at State Badges for the
     `roost install` route.
   - `troubleshooting.md` item 3 and `getting-started.md`'s requirement line
     and `README.md`'s: drop "not supported yet"; opencode 1.x and 2 both
     have adapters.
   - The adapter contract: in "`idle` is a default, not a report", replace
     "Neither shipped adapter ever reports `idle`" with the truth — codex
     reports `idle --stop-hook` on Interrupt, and the opencode 2 adapter
     reports `idle` to take back a badge that is no longer about the pane's
     chat — and say when an adapter may. In "Where each harness stands", add
     a row for opencode 2: tier 2, shipped; `blocked` asked of the server;
     `error` from `retry.scheduled` attempt 3 / `execution.failed`; reply
     from `session.text.ended`; install: a directory symlink into
     `~/.config/opencode/plugins/`. Under §5, note that T1 and T8 are tested
     for it in `tests/opencode2-plugin-harness.mjs`.
   - `docs/known-gaps.md`: in the "opencode 2 is not supported…" section,
     replace the "No badge (#150) … Not fixed" paragraph with "fixed by the
     adapter" and the gaps the design ships with (§6 of the design, each as a
     bullet), plus the 1.x hole the review found: the 1.x opencode adapter
     leaves the previous turn's reply stored after Esc, Reject or a turn with
     no prose, and `roost read` serves it on `done` with no notice. Keep the
     #154 half of the section as it is.
   - `CHANGELOG.md`, `## [Unreleased]`, `### Added`: one entry, "**opencode 2
     is supported**", saying what the user does (`roost install` once), what
     they see (badges and replies as on 1.x; the badge follows the chat on
     screen), and the two things that differ (tab switch and `roost read`; a
     reload). Then `cd site && pnpm sync` and commit what it writes.
2. `.airig/leakcheck.sh` on every file touched.

**Check:** `cd site && pnpm sync:check` → in step; `pnpm build` → exit 0,
24 routes; `node scripts/check-typography.mjs` → pass. `grep -rn "not
supported yet" site/content/docs README.md` → no match.
**Commit:** `docs: opencode 2 is supported — what to install, what the badge follows, and the gaps (#150)`

---

### Task 11 — The whole thing, on both platforms

**Files:** none changed
**Depends on:** Tasks 1–10

**Do:**
1. `bash tests/run.sh` → `N passed, 0 failed`, exit 0. `python3
   tests/test-contrast.py` → pass.
2. In `ubuntu:24.04` (the command in Global constraints), run
   `tests/test-opencode2-plugin.sh`, `tests/test-opencode2-record.sh`,
   `tests/test-reply-record.sh`, `tests/test-adapter-install.sh`,
   `tests/test-doctor.sh`, `tests/test-validate-install.sh`. Each: `FAIL=0`,
   exit 0 — or, for the node harness on an old `nodejs`, the one SKIP line.
3. `git diff 8cbafa1 -- . ':!tests/fixtures' | grep '^+' > /tmp/amx.added;
   .airig/leakcheck.sh /tmp/amx.added` → all zeros.
4. Report the numbers. Do not open a pull request; that is the human's step.

**Check:** the three commands above, with their outputs quoted in the report.
**Commit:** none.

---

## Deferred checks — one pass at the end

1. **Task 9 — the live smoke test, run by the human** with a real opencode 2
   binary: `ROOST_OPENCODE2_BIN=<path to a 2.0.x opencode> bash
   tests/live/opencode2-smoke.sh`. Expect every case PASS and `v2 processes
   left: 0` at the end. The binary is the release zip from
   `https://opencode.ai/files/bin/<version>/opencode-darwin-arm64.zip`,
   unpacked into a temp directory — never the Homebrew formula, which
   replaces 1.x.
2. **Task 7 — `roost doctor` by eye** on this machine with that same binary
   first on `PATH` and the five directories redirected: the opencode lines
   read `opencode 2 plugin linked` after `roost install` into the redirected
   home, and the `OPENCODE_CONFIG_DIR` warning still appears inside a roost
   pane that has it.
3. **Task 10 — the site**, `cd site && pnpm preview`: the opencode section of
   State Badges renders with its two sub-sections, and the changelog page
   shows the new entry.
4. **Task 8 — `roost validate` by eye**, with the 2.x binary first on `PATH`
   and every home redirected into a temp directory: its report's opencode row
   reads `SKIP` with the reason naming `tests/live/opencode2-smoke.sh`, and
   no opencode was driven.
