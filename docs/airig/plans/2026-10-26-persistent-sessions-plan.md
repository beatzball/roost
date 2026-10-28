# Persistent sessions (#191: #51, #57, #192, the restore offer) — Plan

Design:     docs/airig/specs/2026-10-24-persistent-sessions-design.md (revision 10, final jury approved; §6 build order, §8 tests, §9 Q1–Q4 decided A and the opt-in ruling of 2026-10-25)
Plan base:  f5e343d (origin/main, 2026-10-26)
Parts:      1 → 2 → 3 → 4 → 5 → 6 → 7, one PR each, in this order
Oracle:     automated (stub harnesses on throwaway named servers) + instrumented (probes, live smokes) + human-eye (the reboot, §8.2)

Seven parts, one per §6 step. Each part opens with its own header block
(worktree, branch, base) and ships as its own PR. A part starts only after the
part before it has merged, and branches from origin/main at that moment.

**What depends on what.**

| part | §6 step | needs merged first | why |
|---|---|---|---|
| 1 | save, the format, placement | nothing | — |
| 2 | `revive` | 1 | the agreement check and the owner rule live in Part 1's shape library |
| 3 | restore resumes | 1, 2 | the engine is placement (1) plus `revive`'s checks and claims (2) |
| 4 | save on change | 3 | the saver applies pending arrows (T13, T13a, T13b, T19) to Part 3's files, and the overlay reads them |
| 5 | `persist`, login, first attach | 3, 4 | `--at-login` stops at Part 3's pending record; the reading rule and `closed/` are Part 4's |
| 6 | printed store listings | 2, 3 | the §5.6 line is printed by `revive` (2) and the restore report (3) |
| 7 | the restore offer | 5 (and so all before) | `r` leans on the first-attach hook, `l` on `persist on` |

Nothing in this plan re-opens a decision of the spec. Where a probe answers
something the spec did not allow for, the part stops (see **Probes** below).

## Open ruling for the coordinator (R1) — read before Part 4

The code contradicts §3.6a, §5.9 and test 8(e): **`roost close` refuses the
last pane of a session, even with `--force`** (`bin/roost`, the `close` arm,
step 2: "refuse the last pane of a session, even with --force … `roost kill`
is the command for that"). So "`roost close` the only pane of the only
session" cannot be run, and the "closed on purpose" path for a last session
does not exist through `close`. Two ways to read the spec:

- **A (recommended):** the deliberate end of a session or fleet is `roost kill
  NAME` and `roost stop` (both roost's own code, `kill|down|stop` arm), so
  each writes `closed/<boot>/close.<N>` for every pane it is about to remove,
  before the tmux command, exactly as §3.6a has `close` do. Test 8(e) becomes
  "`roost kill` the only session" and "`roost stop`". This also fixes a gap the
  spec does not name: `roost stop` is `kill-server`, runs no hook, and today's
  plan would bring the whole fleet back at the next login.
  **A's cost, plainly:** after `roost stop` (or `roost kill` of every
  session), the next login restore and a plain `roost restore` bring nothing
  back and print "nothing to restore: every saved pane was closed on
  purpose". `roost restore --from STAMP-GEN` does **not** bring it back
  either: every save since this server started is of the same boot as the
  `close.<N>` files the stop wrote (an older save in `history/` is filtered
  by its own boot's record instead), and §3.6 step 4 filters a `--from
  STAMP-GEN` save by its own boot with no time comparison. The fleet is still
  on disk, and the way back is `--from FILE`, which skips step 4 by design:
  restore a file **by path** — `shape` itself, or a `history/` file —
  for example `roost restore --from
  ~/.local/state/roost/shapes/roost/history/20261026T101500Z-412` (the name
  `roost restore --list` shows for the save before the stop). No save-time
  exemption is added. Task 4.8's message and Task 4.12's page say this.
- **B:** `close` gains a mode that takes a session's last pane. That changes a
  shipped refusal and its documented reason.

Task 4.8 and Task 5.6's test 8 (e) case are written for **A**. If the
coordinator rules B, Task 4.8's step 2 becomes "`close` takes a session's
last pane" (with its own red case) and test 8 (e) uses `roost close`. Until
ruled, Part 4 runs every task but 4.8, and Part 5 runs every case but 8 (e).

## Coordinator rulings R2–R5: additions beyond the spec

Field reports from other tools' save, restore and autostart work were read
after the spec was approved. The coordinator accepted four additions. Each
extends the spec section named, does not change any rule the spec states, and
has its own red test. Every other lesson from those reports is either already
covered by a task below, added as a test case or probe inside the spec's
rules, or left out.

- **R2 — the second-server guard** (extends §4.4, §4.6 and `ensure_session`,
  §1). One autostart tool, a reconnecting client and an over-eager start path
  each started a second server under the same name while the first still ran
  with its socket file gone (a temp cleaner, a crash of the socket's
  directory), and the live fleet became unreachable. Rule: before roost starts
  a server under a name — `ensure_session`, restore's **Server** step,
  `--at-login` — it reads the `boot` of the newest save for that server
  (`START-PID`); when that pid is alive, its command is `tmux` and its start
  time is the boot's, roost starts nothing, prints `roost: the tmux server
  (pid N) is still running but its socket is gone; kill -USR1 N recreates it`,
  and exits 1 (`--at-login` logs it and exits 0). Part 5 gate: Task 5.4.
- **R3 — the silent saver** (extends §3.5 and §4.5). Every timer-based saver
  read shipped with a health line that said "saved" while nothing was
  written, found by users months later. Rule: the saver writes `save.err`
  (0600) in the shape directory with the stamp, the failing step and its exit
  code whenever a round fails to list or to publish, and removes it on the
  next published save; `doctor` prints it as a `warn`. When `save.err` itself
  cannot be written (the directory is read-only), the saver stays silent and
  writes nothing else: the second signal covers it. `doctor` also warns,
  **whatever `persist` says** but only while saving is on (`roost_shape_saving`
  prints a directory), when a running server has no save whose `boot` is its
  own (§4.5 limits that line to `persist` on). Same PR as the hooks: Tasks
  4.5 and 4.11.
- **R4 — a nested same-harness agent writing over the pane's key** (extends
  §3.2's agreement check, whose `nested` case sees only another harness). One
  tool lost a pane's conversation when the pane's own Claude ran a headless
  `claude -p` through its shell tool: the child's session start re-identified
  the pane with a throwaway id. Rule, gated on Task 1.5's probe: the Claude
  identity path ignores a report whose environment marks a non-interactive
  child (the variables the probe finds). Task 1.15.
- **R5 — a terminal quit that kills the server** (extends §4.4 and §8.2 item
  1). A tmux maintainer recorded that on a newer macOS, quitting the terminal
  app killed a tmux server started from it, with every process in it. A
  server roost's launchd job starts is not the terminal's child; one
  `ensure_session` starts from a terminal is. Part 5 probe with its "if
  confirmed, do Y" table: Task 5.3; the build, only if confirmed: Task 5.10.

## Coordinator ruling R6: a read rule from probe 1.3

- **R6 — tmux 3.4 prints `$` as `\$`** (extends spec §3.2; found by Task
  1.3's probe, docs/airig/probes/persist-1-control-bytes.md, and re-run by
  the coordinator on `ubuntu:24.04`). On tmux 3.4 every value tmux prints
  holding `$` comes out with one backslash before each `$`, whatever the
  read (`show-options -v`, `display -p`, `list-panes -F`, with or without
  `#{q:}`); a backslash already there is not doubled. 3.2a and 3.6 print `$`
  bare. Rule: before a save lists, the writer learns once per run whether
  this server does it — set one pane option to a known value holding `$`,
  read it back, unset it — and if it does, removes exactly one backslash
  before every `$` in every value it reads. Red tests, run on the CI tmux
  (3.4) as well as this Mac: a round trip of `a$b`, `a\$b`, `$HOME`-shaped
  text (`a$HOME` and `a${HOME}b`, never expanded) and a no-`$` control `ab`,
  each as a directory (`cwd`, `session_cwd`) and as a `name`. The writer half
  is in Task 1.9, the round trip through the reader in Task 1.10.

## Coordinator ruling R7 (human decision): a session group is one block per later member

- **R7 — a group-aware block** (extends spec §3.2; decided by the human on
  2026-10-28 after Task 1.2's probe, docs/airig/probes/persist-1-session-group.md,
  showed a group listed once per member with the same window and pane ids).
  Groups are keyed on `#{session_group}`, never `#{window_linked}` (it reads
  0 on tmux 3.2a and 3.4 and 1 on 3.6 for the same group). The **first
  member** — the lowest session id, so the choice is stable — is saved in
  full. Each **later member** is a `session` block holding only its own
  keys (`id`, `active` when set, `active_window INDEX` — its own current
  window, since it has no window blocks to carry an `active 1`) and one
  `group <first member's name>` line, and **no** window or pane blocks.
  Restore makes the first member as usual, then each later member with
  `new-session -d -t =<first> -s <name>`. **Refusal** (the checker, the
  spec's existing rule "an address with no parent is a named refusal of
  the whole file"): a `group` line naming a session that has no full
  `session` block in the file, naming itself, naming another later member,
  or a later member that also has window or pane blocks → exit 16, nothing
  done. **`--only`** of a later member alone: it joins its first member when
  that session already exists on the server; otherwise it is the same
  "no parent" refusal, exit 16, nothing done. `--only` of the first member
  brings its later members with it. The addressing, `--only`, `--dry-run`
  and `--list` output name a later member once, as joining its group
  (`session view (joins main's group)`). Red tests: round trip of a two- and
  a three-member group; no pane id appears twice in the save; restore makes
  one copy of each pane; a window made in one member after restore is
  visible in the other; `--only` of a later member alone (joins a live first
  member; refused without one); a bad `group` line refused; on tmux 3.2a,
  3.4 and this Mac. The writer half in Task 1.9, the checker and round trip
  in 1.10, the restore half in 1.12, the output in 1.14.

## Coordinator ruling R8: the other probe 1.3 facts, probe 1.4, the test server name

1. **A newline cuts a listing line.** A listing line that does not start
   with its id field (`%N`, `@N`, `$N`) is a fault of that round, not data.
   The writer then reads that object's free-text values one at a time with
   `display -p -t <id>`, and a value holding a newline gets the control-byte
   rule (drop `name`; `cwd` → home; one stderr line). Task 1.9 cases: a
   newline in `@roost-name` and in a directory.
2. **ESC/SOH read as `\NNN` text on tmux 3.4.** R6's shape: once per run,
   set a known value holding ESC, read it back; if this server prints a
   backslash and three octal digits, any `\NNN` (octal) sequence in a read
   free-text value is treated as a control byte under the existing rule. A
   literal `\033` a person typed is then dropped too: the safe side, said
   in the docs. Task 1.9's odd-value test expects the same result on every
   build.
3. **Backslash and `$` in session and window names drift on restore.**
   Test first: save and restore sessions and windows named `a\b` and `a$b`
   on tmux 3.2a, 3.4 and this Mac; the name after restore equals the one
   before, and does not grow over two cycles. Measure tmux's rewrite; if
   restore can undo it exactly on every build, do that before `new-session
   -s` / `new-window -n`; if not exact on some build, the writer drops such
   a name on that build (default name, one stderr line). Tasks 1.12
   (sessions) and 1.13 (windows).
4. **Probe 1.4 applies in Tasks 1.12 and 1.13:** every target after the
   session comes from the id the creating command prints (`-P -F`); a
   dotted session name is stored by tmux with `_`, so restore reads the
   created name back.
5. **The shape test server is `-L roost`** under a guarded temp
   `TMUX_TMPDIR` (Task 1.8's finding: roost's hooks and `identify` act only
   on a socket path ending in `/roost`), driven and killed by its full
   socket path.

## Probes

Each part's first tasks are its probes: those §6 names, and in Part 1 also the
five format probes the coordinator moved to the very start (Tasks 1.1–1.5),
because the format cannot change once Part 1 ships it. A probe task:

- runs on throwaway sockets only (`-S` under `mktemp -d /tmp/amx.XXXX`, or
  `-L` with the `TMUX_TMPDIR` guard of AGENTS.md §2), with every home
  redirected (the list in Global constraints);
- writes its result, with the method, versions, run count ("once") and raw
  output excerpts, to the result file the task names under
  `docs/airig/probes/` (new directory; scrubbed: no names, no home paths,
  fake ids of the same shape), and commits it;
- then applies its "if the probe says X, do Y" table. **A result outside the
  table, or one that breaks a rule the spec states, stops the part**: append
  `STATUS: BLOCKED probe <task>: <one line>` to the part's report and stop.
  Never re-design to fit a result.

Probe scripts stay out of the repository (the spec's rule); only the result
file is committed.

## Global constraints (every task in every part)

- **Location.** Work only in the part's worktree; `git -C <worktree>` for every
  git command. Before the first commit: `git -C <worktree> rev-parse
  --show-toplevel` prints the worktree and `git -C <worktree> branch
  --show-current` prints the part's branch, or stop. Never `git stash`. One
  commit per task, subject given in the task. No push, PR, merge or tag.
- **Shell.** `bin/roost`, `scripts/roost-agent-state` and every
  `scripts/lib/*.sh` run under bash 3.2 (macOS `/bin/bash`) and bash 5 with
  `set -euo pipefail` where the caller has it: no `declare -A`, no
  `${var,,}`, no `mapfile`, no `|&`; `cmd && last` at a function tail needs
  `|| true`. `scripts/roost-placeholder` is POSIX `sh` and must run under
  macOS `/bin/sh` and Ubuntu `dash`. `bash -n` every touched bash file under
  `/bin/bash`.
- **tmux output.** CI is tmux 3.4: never split tmux output on a tab (it prints
  `_` under a C locale, docs/known-gaps.md). Use a space or `|`, and quote
  free text with `#{q:…}` or read it on its own line.
- **Tests.** `XDG_STATE_HOME=$(mktemp -d) bash tests/<file>.sh` to iterate.
  Every new test is written first and **seen failing** (keep the FAIL lines for
  the report) before the code. Tests drive `tmux -S "$ROOST_TEST_SOCK"` or a
  `-L` name after `roost_test_tmux_named_guard` (tests/lib.sh; AGENTS.md §2),
  never a bare `tmux`, and never `tmux kill-server` without `-S`/`-L` naming a
  test socket. Every new test file redirects `HOME`, `XDG_CONFIG_HOME`,
  `XDG_STATE_HOME`, `TMUX_TMPDIR`, `ROOST_RECORD_DIR`, `ROOST_SHAPE_DIR`,
  `CLAUDE_SETTINGS`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`,
  `PI_CODING_AGENT_DIR`, clears `ZDOTDIR`, and exports the canary of
  `tests/test-install.sh` (copy its `CANARY` / `canary_leaks` shape) and fails
  if anything lands there. A file that takes over 12 s gets a `shard_weight`
  line in `tests/run.sh`.
- **No test saves a shape by accident.** `tests/lib.sh` exports
  `ROOST_SHAPE_DIR=""` unconditionally (Task 1.8), as it already does for
  `ROOST_RECORD_DIR`, so an existing test that spawns or splits writes no
  shape once Part 4 saves on every change; a test that wants shapes sets its
  own temp root after sourcing it (`tests/lib-shape.sh` does). Every
  `tests/live/*.sh` rig that runs `bin/roost` passes `ROOST_SHAPE_DIR` at a temp
  path (or `env -u ROOST_SHAPE_DIR` beside its redirected `XDG_STATE_HOME`).
- **The shared test library** `tests/lib-shape.sh` (new in Task 1.8) holds the
  named-server setup, the canary, the stub harnesses and the
  `$HOME/shells.log` rc files; later parts add to it, never copy it.
- **Comments are the product** (AGENTS.md §5): new code carries its why; a moved
  line keeps its comment.
- **Never named.** No names, e-mails or home paths in anything committed
  (`grep -rn "/Users/[a-z]" <touched files>` prints nothing); no provenance
  trailer in a commit message; no competing product named anywhere.
- **Never touched.** `VERSION`; `@agent_state`, `@agent_since` (AGENTS.md §6);
  the real `~/.claude`, `~/.claude.json`, `~/.config/roost`, `~/.codex`,
  `~/.copilot`, `~/Library/LaunchAgents`, `~/.config/systemd`. No `roost
  install`, `upgrade`, `doctor`, `validate` or `persist` against the real home.
  No real `launchctl`/`systemctl` call from any test or task, with two
  exceptions: the Part 5 VM probe (Task 5.1), on the VM; and Task 5.3's macOS
  probe (R5), which loads one throwaway job labelled
  `dev.roosting.roost.probe` from a plist **in its own temp directory** (never
  `~/Library/LaunchAgents`) and boots it out before it ends.
- **Exit codes** (§4): new verbs use 0, 1, 2 with their shared meanings and
  12 (skipped as existing), 13 (not resumed / refused, reason printed), 14
  (harness not on `PATH`), 15 (directory gone), 16 (shape refused), 17 (no
  launchd or systemd). Existing verbs' codes do not move.
- **Changelog** (each part's docs task): one entry under `## [Unreleased]` in
  `CHANGELOG.md`, house style (bold first sentence naming the issue, then what
  a user sees), then `cd site && node scripts/sync-changelog.mjs && node
  scripts/build-llms-txt.mjs --check`. Read `site/AGENTS.md` before touching
  `site/`.
- **Suite and container** (each part's verify task): `XDG_STATE_HOME=$(mktemp
  -d) bash tests/run.sh` (exit code and totals; a non-zero exit means a file
  died — read the per-file lines), `python3 tests/test-contrast.py`, then once
  in Ubuntu on a `git archive` export, never a mount, run as `bash <script
  file>` (a script file, not inline):
  ```
  X=$(mktemp -d) && git -C <worktree> archive HEAD | tar -x -C "$X"
  docker run --rm -v "$X":/w -w /w -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 ubuntu:24.04 bash -c \
    'apt-get update -qq && apt-get install -y -qq tmux git jq python3 bash locales procps >/dev/null && bash tests/run.sh' 2>&1 | tail -30
  ```
  Record totals and every FAIL line; re-run once; say whether a FAIL repeats.

### Names this plan fixes (so tasks agree)

New files and what each holds. A task that adds a function adds it to the file
named here.

| file | part | holds |
|---|---|---|
| `scripts/lib/roost-shape.sh` | 1 | `roost_shape_saving` (§3.4a), `roost_shape_key`, `roost_shape_dir`, the owner rule (`roost_shape_owner_take`, `_live`, `_drop`), `roost_shape_agree` (§3.2's agreement check), the writer, the checker and the parser; Part 4 turns the publisher into the saver |
| `scripts/lib/roost-restore.sh` | 1 | placement, the `--dry-run` tree, `--list`, which save (`--from`, and Part 4's reading rule) |
| `scripts/roost-placeholder` | 1 | the placeholder program (§4.7), POSIX `sh`; placing mode in Part 1, the pending modes in Part 3 |
| `scripts/lib/roost-resume.sh` | 2 | the resume table (§2.8), the directory rule (§5.1), the store checks and exact-id lookup (§5.1a), `claims/` (§4.1 step 5a), `revive`'s core; Part 6 adds the listings |
| `scripts/lib/roost-pending.sh` | 3 | `pending/<boot>/` files, the §4.7 renames and the `origin` rule, the resume engine (§4.6) |
| `scripts/lib/roost-persist.sh` | 5 | `service.env`, the plist and unit text, `on`/`off`/`status`, `--at-login` |
| `scripts/lib/roost-offer.sh` | 7 | the offer's checks, lock, pin, prompt |
| `tests/lib-shape.sh` | 1 | test helpers (above) |

New `bin/roost` arms: `save` and `restore` (Part 1), `revive` (Part 2),
`persist` (Part 5). Each arm parses its flags and sources its library; the
work is in the library.

Hidden flags `save --auto` takes from the hooks (Part 4; the spec does not name
them, this plan does): `--boot KEY` (the hook's `#{start_time}-#{pid}`),
`--pane %N` (`#{hook_pane}`), `--ids-before "…"` and `--ids-after "…"` (the
`@roost-ids` value and the fresh `#{S:#{W:#{P:#{pane_id} }}}` loop).

### Test seams (each read only when set; each added by the task that first needs it)

| seam | meaning | added in |
|---|---|---|
| `ROOST_TEST_NOW=EPOCH` | the clock for every stamp `save` and `close` write, and the offer's "ago" | 1.9 (`save`), 4.7 (`close`), 7.4 |
| `ROOST_TEST_RESTORE_HOLD=FILE` | restore waits right after `new-session`, holding `restoring/`, until FILE exists | 1.12 |
| `ROOST_TEST_PLACE_HOLD=FILE` | restore waits after a window's panes exist and its layout is applied, before the per-pane step | 1.13 |
| `ROOST_TEST_PLACE_HOLD_AFTER_USED=FILE` | restore waits after winning `F → F.used` (T2), before that pane's respawn | 1.12 |
| `ROOST_TEST_REVIVE_HOLD=FILE` | `revive` waits after its rename to `%N.launching`, its `origin` line and its claim, before step 7 | 3.8 |
| `ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN=FILE` | `revive` waits right after that rename, before its `origin` line | 3.8 |
| `ROOST_TEST_LOOP_HOLD=FILE` | a hand restore waits after placement, before its resume loop (this plan's seam, not the spec's: it lets Task 3.3 read the placed state before Task 3.5's loop exists) | 3.3 |
| `ROOST_TEST_RESUME_HOLD=FILE` | the engine waits after its rename to `.launching` and its claim, before the respawn | 3.5 |
| `ROOST_TEST_RESUME_HOLD_AFTER_FAILED=FILE` | the engine waits right after T7 | 3.5 |
| `ROOST_TEST_SAVE_HOLD=FILE` | the saver holds `lock/` until FILE exists | 4.5 |
| `ROOST_TEST_SAVE_HOLD_AFTER_DRAIN=FILE` | the saver waits after `mv want want.<pid>` | 4.5 |
| `ROOST_TEST_SAVE_HOLD_AFTER_LIST=FILE` | the saver waits after listing, before publishing | 4.5 |
| `ROOST_TEST_PUBLISH_FAIL=1` | the saver's publish step fails as a refused `mv` would, in a writable directory (this plan's seam, for R3's `save.err` case) | 4.5 |
| `ROOST_SHUTDOWN_AT=EPOCH` | a stub shutdown record; set and empty = no readable record | 4.9b |
| `ROOST_PERSIST_WRITE_ONLY=1` | `persist on` writes the unit and does not load it | 5.5 |
| `ROOST_TEST_OFFER_TIMEOUT=SECONDS` | the offer's 60 s no-answer bound | 7.4 |

---

# Part 1 — `roost save`, the shape, and placement (§6 step 1, #51)

Design:     §3.1–§3.3, §3.4a, §3.6 (`--from`, `--list` only), §4.2, §4.3 (placement only), §4.7 (placing rows and T1–T4, T2b), §2.7, §2.10
Repository: the `persist-1` worktree of this checkout (`.claude/worktrees/persist-1`)
Branch:     worktree-persist-1
Base:       origin/main when the part starts (record the sha in the report)
Oracle:     automated (`tests/test-shape.sh`, `tests/test-shape-place.sh`) + instrumented (seven probes)
Unattended: yes (Task 1.5 needs the live Claude rig of `tests/live/claude-background-smoke.sh`)

**The tmux versions.** Tasks 1.1–1.4 run on three tmux builds: 3.2a
(`ubuntu:22.04`), 3.4 (`ubuntu:24.04`) and this Mac's (`tmux -V`). Each
container runs `apt-get install -y -qq tmux procps` and a probe script copied
in from a temp directory, never a mount of the worktree; the Mac run uses a
throwaway `-S` server with a temp `HOME`. Every probe writes one result file
with a column per version.

In this part `restore` **places only**: no agent is launched, a keyed pane
becomes a shell in its directory, and the shape's keys are kept for Part 3.
There is no `@roost-was`, no pending record, no auto save (Part 4), and the
history grows without the ring (Part 4 adds `ROOST_SHAPE_KEEP`). `restore`
with no `--from` reads `shape`.

**After this part merges, a user can:** run `roost save` and read their fleet
as a plain file; copy it, edit it, and `roost restore --from COPY` it on any
server, getting the same sessions, windows, panes, names, directories and
layouts back as shells; preview with `--dry-run` and list saves with `--list`.

### Task 1.1 — Format probe: a zoomed window's `#{window_layout}`

**Files:** `docs/airig/probes/persist-1-zoom-layout.md` (new)
**Depends on:** nothing

**Do:** On each of the three tmux builds: a 200x50 detached session, one
window split into three panes (one `-h`, one `-v`); read `#{window_layout}`
and `#{window_visible_layout}`; `resize-pane -Z` on one pane; read both again
and `#{window_zoomed_flag}`; unzoom; read again. Never unzoom to save — one
tool that did so corrupted zoomed windows and made them flicker; this probe
only reads.

**If the probe says:**
- `#{window_layout}` while zoomed equals the unzoomed string on all three:
  Task 1.9 saves `#{window_layout}` as read and `zoomed 1` from the flag (§2.7,
  §3.2), and Task 1.13's test unzooms after restore and compares the string.
- on some version it is the one-pane view while zoomed, and
  `#{window_visible_layout}` is the one that changes: Task 1.9 still saves
  `#{window_layout}`; record it.
- on some version `#{window_layout}` is the one-pane view while zoomed:
  **stop** — §2.7's "the zoomed state is not in the string" would not hold,
  and the only way round is the unzoom the field shows to be harmful.

**Check:** `test -s docs/airig/probes/persist-1-zoom-layout.md`, with three version columns and one outcome named.
**Commit:** `probe: a zoomed window's layout string on tmux 3.2, 3.4 and this Mac (#51)`

### Task 1.2 — Format probe: how a session group lists

**Files:** `docs/airig/probes/persist-1-session-group.md` (new)
**Depends on:** nothing

**Do:** On each build: a session `main` with two windows (the second split),
then `new-session -d -t main -s view` (a grouped session). Read `list-sessions
-F '#{session_name} #{session_group} #{session_grouped}'`, `list-windows -a
-F '#{session_name} #{window_index} #{window_id} #{window_linked}'` and
`list-panes -a -F '#{session_name} #{window_index}.#{pane_index} #{pane_id}'`.
One tool restored a grouped session as two independent sessions, doubling
every program in it; this probe tells what roost's listing would hold.

**If the probe says:**
- each member is listed under its own name with the same window and pane ids
  (the linked-window shape): Task 1.9 writes both as §3.2 writes a linked
  window, so the second copy comes back as its own windows and its agents
  meet §5.1a's duplicate refusal (safe, doubled shells). Record it; the
  coordinator has the recommendation (a group-aware block) as a spec question;
  the plan stays on the spec.
- one address (`SESSION:INDEX` or `SESSION:INDEX.PANE`) is listed twice:
  **stop** — the saver would write a file §3.2 refuses whole.
- anything else: **stop**.

**Check:** `test -s docs/airig/probes/persist-1-session-group.md`, three version columns.
**Commit:** `probe: what a grouped session looks like in the listings (#51)`

**Stop point after Task 1.2.** Append `STATUS: BLOCKED grouped-session
decision (probe 1.2 done)` to the part's report and stop. The coordinator
takes the grouped-session question to the human (save a later group member
as a group-aware block, or keep the spec's linked-window treatment) before
Task 1.9 starts, because 1.9 freezes the format. Tasks 1.3–1.8 may run while
the human decides; Task 1.9 waits for the answer, and a "yes" arrives as a
spec revision, not as a plan edit by the builder.

### Task 1.3 — Format probe: control bytes in names and directories

**Files:** `docs/airig/probes/persist-1-control-bytes.md` (new)
**Depends on:** nothing

**Do:** On each build, try to give each of these a tab, a newline, an ESC and
a `\001`: a session name (`new-session -s`, `rename-session`), a window name
(`rename-window`), a pane option (`set -p @roost-name`), and a directory a
pane's shell `cd`s into (`mkdir "$(printf 'a\tb')"` etc.). Record which tmux
accepts, which it rewrites (and to what), and what `#{q:session_name}`,
`#{q:window_name}`, `#{q:@roost-name}` and `#{q:pane_current_path}` print.
Then the ordinary names: a space, `$`, `'`, `"`, `#`, a trailing space and a
UTF-8 glyph, the same reads. One tool wrote a `cwd` holding `$` that its own
reader then refused; another refused its whole saved layout for one bad value.

**If the probe says** (every row decides one writer rule in Task 1.9; §3.2
already says the file holds no control byte, so the only question is what the
writer does with one instead of writing a file restore refuses):
- tmux refuses or rewrites control bytes in a session name: nothing to do for
  sessions.
- tmux accepts one in a session name: the writer leaves that session's blocks
  out, with one stderr line naming it (by `#{q:}`), and counts it in `save`'s
  summary as `K skipped`.
- one in a window name or `@roost-name`: the writer drops that `name` key,
  one stderr line (the key is optional).
- one in `pane_current_path`: the writer writes that pane's `cwd` as the
  home directory's absolute path (`$HOME` expanded by the writer, never the
  four characters), one stderr line naming the pane; restore then gives a shell at home, and a
  resume's directory still comes from §5.1, not from `cwd`.
- any ordinary name above does not round-trip through `#{q:}` and an
  unescape: **stop** (the writer cannot read its own values back).

**Check:** `test -s docs/airig/probes/persist-1-control-bytes.md`, three version columns, one rule chosen per row.
**Commit:** `probe: control bytes and odd characters in session, window and pane names (#51)`

### Task 1.4 — Format probe: dotted and numeric names, and the exact-match target

**Files:** `docs/airig/probes/persist-1-targets.md` (new)
**Depends on:** nothing

**Do:** On each build: sessions named `v3.69-x` and `1`, each with windows at
index 1 and 5 and a window named `2`. Try `has-session -t v3.69-x` and `-t
=v3.69-x`; `new-window -d -t '=v3.69-x:7'`; `split-window -d -t
'=v3.69-x:5.0'`; `select-layout -t '=v3.69-x:5' tiled`; `display -p -t '=1:'
'#{session_name}'`; `display -p -t '=1:2'` (index 2 versus the window named
`2`). One tool tested a dotted session's existence with a bare target, failed
to find it, made it again, and renamed the first window over.

**If the probe says:**
- every `=NAME:`, `=NAME:INDEX` and `=NAME:INDEX.PANE` form resolves exactly
  on all three: Tasks 1.12 and 1.13 build every target from a saved name in
  that form (as `bin/roost` already does with `=$sess:`), and test the dotted
  and numeric sessions.
- some form fails on some version: those tasks build the session target as
  `=NAME:` and take every later target from the id the creating command prints
  (`new-window -P -F '#{window_id}'`, `split-window -P -F '#{pane_id}'`);
  record which.
- `has-session -t =NAME` fails for a session that exists: existence is read
  from `list-sessions -F '#{q:session_name}'` with an exact compare; record it.

**Check:** `test -s docs/airig/probes/persist-1-targets.md`, three version columns.
**Commit:** `probe: exact-match targets for dotted and numeric names (#51)`

### Task 1.5 — Probe: a nested Claude in the pane's own shell writes over its key

**Files:** `docs/airig/probes/persist-1-nested-claude.md` (new)
**Depends on:** nothing

**Do:** With `tests/live/claude-background-smoke.sh`'s rig (fake Messages API,
redirected homes, the settings and `.claude.json` guard), roost's hooks
installed on the throwaway server, and a logger hook on `SessionStart` that
writes the **names** of every `CLAUDE*` variable and the values of
`CLAUDE_CODE_ENTRYPOINT` and `CLAUDE_CODE_SESSION_ATTENDED` (no other value):
one interactive pane; script a `Bash` tool call `claude -p hi --output-format
json`, then one with `--resume <that id>`. Read `@roost-session` before and
after each. Also do it for a background session if the version offers one
(`claude --bg`), else record "not offered". Once.

**If the probe says:**
- `@roost-session` never moved: nothing to build; Task 1.15 is skipped and
  says so in the report.
- it moved, and the child's `SessionStart` environment carries a value the
  interactive session's does not (for example `CLAUDE_CODE_ENTRYPOINT` other
  than `cli`, or `CLAUDE_CODE_SESSION_ATTENDED=0`): Task 1.15 builds R4 on
  exactly those names and values.
- it moved and nothing in the environment tells the two apart: **stop** (a
  rule would need more than an environment check, which R4 does not grant).

**Check:** `test -s docs/airig/probes/persist-1-nested-claude.md` with the guard lines unchanged and one outcome named.
**Commit:** `probe: does a headless Claude in the pane's shell re-identify the pane (#51)`

### Task 1.6 — Probe: what `#{pane_current_command}` reads for pi, copilot and opencode

**Files:** `docs/airig/probes/persist-1-command-names.md` (new)
**Depends on:** nothing

**Do:**
1. For pi and copilot, start each with the rig of its smoke test
   (`tests/live/pi-smoke.sh`, `tests/live/copilot-smoke.sh`: redirected homes,
   local model, roost extension) in a pane of a throwaway `-S` server. Read
   `#{pane_current_command}` at its prompt, mid-turn, and in a tool call that
   runs `sleep 5`, 3 reads each.
2. opencode 2.x cannot run beside the user's own background service (§2.5).
   Do not stop it. Record opencode as **not measured**, with that reason.
3. Write the result file: per harness, every value read, the version, the run
   count.

**If the probe says:**
- a stable name that is not a shell and not another harness's (for example
  `pi`, `copilot`, `node`): add it to `roost_shape_agree`'s table in Task 1.9
  as that harness's command, and say in the file whether it is distinctive
  (`node` is not: two harnesses could read it — then the nested half stays
  "presence alone" for both, as the spec allows).
- a shell name (`sh`, `bash`, `zsh`, `fish`, `dash`) while the harness runs:
  **stop** — §3.2's rule would mark every live pane of that harness `exited`.
- not measured (it would not run): presence alone for that harness, as §3.2
  says until measured; say so in the file and in Task 1.16's known-gaps entry.

**Check:** `test -s docs/airig/probes/persist-1-command-names.md && grep -c 'not measured\|measured' docs/airig/probes/persist-1-command-names.md` prints ≥ 3; `grep -rn '/Users/[a-z]' docs/airig/probes/` prints nothing.
**Commit:** `probe: what pane_current_command reads for pi, copilot and opencode (#191)`

### Task 1.7 — Probe: the placeholder's 5-second wake and `remain-on-exit failed`

**Files:** `docs/airig/probes/persist-1-placeholder.md` (new)
**Depends on:** nothing

**Do:**
1. On macOS `/bin/sh`, a throwaway `-S` server with a temp `HOME`: a 20-line
   `sh` script that runs `stty raw -echo min 0 time 50`, then `dd bs=1
   count=1 2>/dev/null` in a loop, printing a counter and `date +%s` each time
   `dd` returns with no byte. Attach nothing. Read the screen at 0, 6, 11 and
   16 s.
2. Send one key with `send-keys`: the loop sees the byte within 1 s.
3. `set -p remain-on-exit failed` on a pane running `sleep 60`; `kill -9` the
   sleep: read `pane_dead` and `pane_dead_status`/`pane_dead_signal`. Repeat
   with a script that `exit 1`s and one that `exit 0`s.
4. Write the result file.

**If the probe says:**
- `dd` returns about every 5 s with no byte, and at once on a key: Task 1.11
  uses exactly `stty raw -echo min 0 time 50` + `dd bs=1 count=1`.
- `dd` blocks until a byte (no wake): **stop** — §4.7 step 1's reprint of a
  failed reason without a respawn depends on the wake.
- `dd` returns at once with no byte (a busy loop): **stop**, same reason.
- `kill -9` leaves the pane dead under `remain-on-exit failed`: Part 4's
  crashed-placeholder test (Task 4.10) uses `kill -9`.
- `kill -9` removes the pane: Task 4.10 uses a placeholder that `exit 1`s
  instead (§8.1 test 11 allows exactly this), and the file says so.
- `exit 1` does not leave a dead pane: **stop** — every `remain-on-exit failed`
  net in §4.1 step 7 and §4.7 rests on it.

**Check:** `test -s docs/airig/probes/persist-1-placeholder.md`; it states one row of the table above for the wake and one for each exit kind.
**Commit:** `probe: the placeholder's 5 s wake and remain-on-exit failed on macOS (#191)`

### Task 1.8 — Test library, and the one switch for saving

**Files:** `tests/lib.sh`, `tests/lib-shape.sh` (new), `scripts/lib/roost-shape.sh` (new), `tests/test-shape.sh` (new), `tests/test-shape-isolation.sh` (new), `tests/live/*.sh` (one line each, the rigs that run `bin/roost`), `tests/run.sh` (only a `shard_weight` line if needed)
**Depends on:** nothing

**Do:**
1. `tests/lib-shape.sh`: sourced after `tests/lib.sh`. `shape_test_setup`:
   `TMUX_TMPDIR=$(mktemp -d /tmp/amx.XXXX)` exported, then
   `roost_test_tmux_named_guard`; every home in Global constraints at a temp
   dir; the canary; `ROOST_SHAPE_DIR=$TMP/shapes`; a redirected `HOME` whose
   `.bash_profile` and `.bashrc` each append `"$TMUX_PANE $$"` to
   `$HOME/shells.log`; `ROOST_SOCKET=roost` (a `-L` name under the guarded
   temp `TMUX_TMPDIR`; ruling R8 item 5: roost's hooks and `identify` act only
   on a socket path ending in `/roost`). `shape_test_teardown` kills only that
   server, by its full socket path. Helpers `shells_for %N` (lines in
   `shells.log` for a pane) and `canary_check`. The stub harnesses (§8.1's
   opening). **The foreground name must be the harness's**, because
   `roost_shape_agree` classifies by `#{pane_current_command}` and a stub that
   ends in `exec sleep 600` reads `sleep` (measured: that is `other`). Measured
   for this plan on 2026-10-26, once each: a real executable **file named**
   `claude` reads `claude`, and one named `codex` reads `codex`, on this Mac
   (tmux 3.6, macOS 26.3) and in `ubuntu:24.04` (tmux 3.4, `/bin/sh` = dash);
   a shell wrapper that `exec`s that file reads the same. On macOS a copy of
   a system binary (`cp /bin/sleep`) is killed at exec (status 137, also after
   an ad-hoc `codesign`), so the file is compiled there. So
   `stub_build_bin DIR`: on Darwin, `cc -o DIR/claude` a three-line C program
   (`int main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 600); return 0; }`,
   `<stdlib.h>`, `<unistd.h>`), elsewhere `cp "$(command -v sleep)" DIR/claude`;
   then `cp DIR/claude DIR/codex`. No `cc` on a Mac → the file fails with
   `STATUS`-style message `needs cc for the harness stub`, never a silent
   skip. Then, in a second temp directory put first on `PATH`: `claude` (a
   `sh` wrapper) appends `<epoch> <cwd> <argv>` to `$STUB_LOG`, runs `roost
   identify --session <the --resume id> --cwd "$PWD" --harness claude` only
   when `STUB_IDENTIFY=1` (or with `STUB_IDENTIFY_AS=<id>` for a different
   id), then `exec "$STUB_BIN/claude" 600`; `codex` the same with `codex
   resume <id>` and `--harness codex` (Task 3.11's codex note needs two such
   panes); `claude-exit1` exits 1 at once; `claude-exit0` exits 0 at once
   without identifying (each installed as `claude` by the test that needs it).
   `shape_test_setup` starts one pane with the wrapper and asserts
   `#{pane_current_command}` reads `claude` (and one with `codex` reads
   `codex`) before any case, failing the file otherwise. The `other` fixture
   stays a plain `sleep 60` in the foreground, which reads `sleep`. A helper
   `stub_store_add ID CWD` writes `$CLAUDE_CONFIG_DIR/projects/<folder by the
   measured rule: / and . → ->/<ID>.jsonl` holding a `"cwd":"<CWD>"` line.
2. Red first, `tests/test-shape.sh`, library level: `roost_shape_saving` with
   `ROOST_SHAPE_DIR=` (empty) and `ROOST_SHAPE_DIR=rel/dir` prints nothing;
   unset → the default path under the redirected `XDG_STATE_HOME`; absolute →
   that path. Key: a `-L NAME` server is keyed `NAME`; a `-S PATH` server
   `path-<cksum of PATH>`; `/a/b-c` and `/a-b/c` give two keys.
   `roost_shape_dir` makes the directory 0700 (the §8.1 guard; the file half is
   Task 1.9's).
3. `scripts/lib/roost-shape.sh`: `roost_shape_saving` (prints the directory or
   nothing: unset → `${XDG_STATE_HOME:-$HOME/.local/state}/roost/shapes`;
   empty or relative → nothing; reads nothing else, §3.4a), `roost_shape_key
   FLAG SOCKET`, `roost_shape_dir` (saving dir + key, made 0700, `umask 077`
   for the files). Comment the §3.4a rule: the one function every writer asks.
4. **Isolation** (this is the first part that can write a shape, so it lands
   here, before any automatic save exists). Red first,
   `tests/test-shape-isolation.sh`: `env -i HOME="$HOME" PATH="$PATH" bash -c
   '. tests/lib.sh; printf "[%s]" "${ROOST_SHAPE_DIR-unset}"'` prints `[]`;
   with `ROOST_SHAPE_DIR=<a canary dir>` exported, `bash tests/test-panes.sh`
   and `bash tests/test-view.sh` leave the canary dir empty (re-run by Task
   4.7 once spawns save). Then in `tests/lib.sh`, right after the
   `ROOST_RECORD_DIR` export and with a comment in its style: `export
   ROOST_SHAPE_DIR=""`. `tests/lib-shape.sh` sets its own temp root after
   sourcing it. Audit every `tests/live/*.sh` and every `tests/test-*.sh` that
   does not source `tests/lib.sh` (today: the four extension-harness tests):
   each that can run `bin/roost` gets `ROOST_SHAPE_DIR` at its temp root or
   `-u ROOST_SHAPE_DIR` where it already writes `-u ROOST_RECORD_DIR`; list
   the files changed and the ones left (with why) in the report.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape.sh` and `bash tests/test-shape-isolation.sh` → all PASS, exit 0, canary empty; `grep -L 'ROOST_SHAPE_DIR' tests/live/*.sh` prints only the rigs the report names as not running `bin/roost`.
**Commit:** `shape: the one switch for saving, the directory key, the test library (#51)`

### Task 1.9 — `roost save`: the writer

**Files:** `scripts/lib/roost-shape.sh`, `scripts/lib/roost-close.sh` (`roost_close_harness`'s `case`, Task 1.6's names), `bin/roost` (the `save` arm; `@roost-launch` in `spawn`, `split`, `view`), `tests/test-shape.sh`
**Depends on:** 1.1, 1.2, 1.3, 1.6, 1.8

**Do:**
1. Red first, in `tests/test-shape.sh`: build 2 sessions, 3 windows, a zoomed
   window, a window at index 5 under `base-index 1`, a pane name with two
   leading and three trailing spaces; `roost identify` two panes (one with
   `--transcript`). `roost save` prints the path and `S sessions, W windows, P
   panes, A with a conversation, K stale` on stderr; the file starts `roost-shape
   1`, has every header key of §3.2 (`server`, `socket`, `boot`, `saved` UTC,
   `gen`, `trigger save`, `roost`, `tmux`, `host`), every block's required keys,
   `zoomed 1` on the zoomed window, `session_cwd` only where `@roost-cwd` is
   set, the name byte for byte. **Stale, by the saver itself (§8.1 test 4's
   save half, "Exited and nested" — C N4):** a pane whose stub exited back to
   `sh` with identity set is written `stale_reason exited`; a pane running the
   stub `claude` with `@roost-harness codex` is `stale_reason nested`; a pane
   running `sleep 60` with identity set is `stale_reason other` (test 6's
   `other` save half); none of the three has a plain `harness` line. A pane
   started by `roost spawn x 'FOO_TOKEN=abc sh'` has `launch FOO_TOKEN=… sh`.
   **Body compare (§8.1 test 1):** a first `roost save` leaves `shape`, `gen`
   1 and an empty `history/` (a first save has nothing to archive, §3.5 step
   2); a change and a second save → one `history/` file and `gen` 2; then
   `roost save` again with no change → still one `history/` file and `gen`
   2. `roost save --to FILE`
   writes there and leaves `shape` alone. **§8.1 test 10, the `save` half
   (10a):** `ROOST_SHAPE_DIR=` and `ROOST_SHAPE_DIR=rel/dir` → `roost save`
   writes nothing, exits 0, one stderr line saying saving is off; a read-only
   shape directory → exit 1 naming it. `shape` and every `history/` file are
   0600. **A failed listing never publishes:** `roost save` against a server
   that is not running → exit 1, `shape`, `gen` and `history/` unchanged.
   **Odd values (Task 1.3's rows):** each control-byte case Task 1.3 found
   tmux to accept is saved by the row's rule (session left out and counted,
   `name` dropped, `cwd` written as the home directory's absolute path), each
   with its stderr line, and no control byte anywhere in the file (`LC_ALL=C
   grep -c '[[:cntrl:]]'` on it, tabs included, prints 0). That the file also
   passes the reader is Task 1.10's case, since the reader lands there.
   **R6, the writer half:** panes whose shells `cd` into `a$b`, `a\$b`,
   `a$HOME`, `a${HOME}b` and `ab`, each with `@roost-cwd` set to the same
   directory and `@roost-name` set to the same last part → the file's `cwd`,
   `session_cwd` and `name` hold each value byte for byte (no `$` expanded,
   no backslash added or lost); after the save no pane carries the
   writer's test option. The suite runs this on tmux 3.4 in CI and on the
   Mac, so both branches of the rule are exercised.
2. `bin/roost` `spawn` and `split`: set `@roost-launch` on the new pane to the
   command as handed (before `roost-pane-shell` wraps it), beside the
   `@roost-name` stamp (`spawn` and `split` each have one `set-option -p …
   @roost-name`). `view` stamps nothing itself today — it re-enters `split`
   or `spawn` and gets the new id back as `$new` — so after that call it
   overwrites `@roost-launch` on `$new` with `roost view <its own arguments>`
   (best effort, `|| true`, the way the name write is), which is the hint
   §4.3's report quotes. Redaction happens at save, not here.
3. `roost_shape_agree HARNESS COMMAND` → `ok`, `exited`, `nested`, `other`.
   It reuses the agreement table §3.2 names, `roost_close_harness ""
   COMMAND ""` (scripts/lib/roost-close.sh), for "which harness does this
   command name" (Claude's version string, the five names), and adds only:
   shell names (`sh`, `bash`, `zsh`, `fish`, `dash`) → `exited`; Task 1.6's
   measured names, added to `roost_close_harness`'s own `case` so the two
   never drift — **only a distinctive name** (Task 1.6's exception: a generic
   name such as `node`, which two harnesses could read, is not added, and
   those harnesses stay on presence alone); a harness that names a different one → `nested`; the same →
   `ok`; no harness from the command, and HARNESS is pi/copilot/opencode with
   no measured name → `ok` on presence (§3.2); anything else → `other`.
4. The writer: first R6's test (set one pane option to a known value holding
   `$`, read it back, unset it; when it reads `\$`, remove exactly one
   backslash before every `$` in every value read below, before any other
   rule); then one `list-sessions`, one `list-windows -a`, one `list-panes -a`
   with space-separated `#{q:}` fields (no tab); the consistency check of §3.5
   step 2 (every pane's window and session in the other listings, else list
   again, at most 3 times); `printf` the blocks; redact `launch`; a value
   holding a control character is handled by Task 1.3's row for its key,
   never written. A listing command that fails (the server gone, a client and
   server of different tmux versions) ends the round with nothing published.
5. Publish (Part 1 form): `mktemp` in the shape dir; body compare against
   `shape` (everything after the header's blank line); same → remove the temp,
   exit 0; else hard-link `shape` to `history/<stamp>-<gen>`, `mv` the temp
   over `shape`, write `gen` + 1. `--trigger NAME` sets the header. The
   `save` arm: `--to FILE`, `--trigger NAME`, `--auto` (accepted, silent,
   same path until Part 4); exit 1 when nothing could be written.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape.sh` → all PASS, exit 0; `bash tests/test-panes.sh` and `bash tests/test-view.sh` still exit 0.
**Commit:** `roost save: write the server's shape, with stale keys and the launch hint (#51)`

### Task 1.10 — The checker and parser, and every refusal

**Files:** `scripts/lib/roost-shape.sh`, `tests/test-shape.sh`, `tests/fixtures/shape-v1.txt` (new)
**Depends on:** 1.9

**Do:**
1. Red first (§8.1 test 5, the parse half): each of `roost-shape 2`, no
   readable first line, a repeated key in one block, a value with a tab, a
   value with another control character, a repeated address, a `window` with
   no `layout`, a `pane` with no `cwd`, a header with no `boot`, a pane whose
   window block is missing, a renamed session whose panes were not renamed →
   `roost_shape_check` returns non-zero and `ROOST_SHAPE_FAULT` reads `line N:
   <fault>` with the right N. A block whose first word is unknown is skipped
   with one stderr line naming its line, and the file passes. Unknown keys are
   ignored. A name with leading and trailing spaces parses byte for byte.
   **The writer's files pass the reader** (moved here from Task 1.9, whose
   writer lands first): every file Task 1.9's cases write, the odd-value ones
   included, passes `roost_shape_check`. **R6, the round trip:** the file
   Task 1.9's R6 case writes passes `roost_shape_check`, and
   `roost_shape_parse` + `roost_shape_get` give back `a$b`, `a\$b`, `a$HOME`,
   `a${HOME}b` and `ab` byte for byte for `cwd`, `session_cwd` and `name`
   (on tmux 3.4 in CI and on the Mac).
   A zero-byte file and a file cut off inside its header are named refusals
   (exit 16 at restore), never "nothing to restore". **The kept shape:**
   `tests/fixtures/shape-v1.txt` is a shape this task's own test writes with
   `roost save` (two sessions, a zoomed window, a keyed pane, a stale pane, a
   `launch` line), scrubbed to `/tmp/roost-fixture/...` paths and fake ids;
   every run checks and parses it and asserts its block counts and five
   values. The file is never edited: a later key gets a second fixture beside
   it, so every later roost is proven to read what this one wrote (the header
   comment of the test says so; one tool lost every saved session at each
   upgrade because nothing pinned the old format).
2. `roost_shape_check FILE`: one pass, `IFS= read -r line`, key `${line%%
   *}`, value `${line#* }`, blank line ends a block; the rules of §3.2 in
   that order. `roost_shape_parse FILE DIR`: after a passing check, one file
   per block in DIR named `NNNN.<kind>` holding the block's lines verbatim,
   and `roost_shape_get BLOCKFILE KEY` (prints the value, returns 1 when
   absent — a reader tests presence). No `eval`, no `source` of shape text.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape.sh` → all PASS, exit 0.
**Commit:** `shape: check the whole file before anything, and refuse by line (#51)`

### Task 1.11 — `scripts/roost-placeholder`, placing mode

**Files:** `scripts/roost-placeholder` (new, executable), `tests/test-shape-place.sh` (new)
**Depends on:** 1.7, 1.8

**Do:**
1. Red first, `tests/test-shape-place.sh` (named server from `lib-shape.sh`):
   a pane started by **path as argv**, `respawn-pane -k
   "$ROOST_HOME/scripts/roost-placeholder" "$F" --placing`, with `F` an
   existing file: within 2 s the screen shows `roost restore is placing this
   session - press any key for a shell`, `shells.log` has no line for it. One
   key: `F` is gone and `F.taken` exists, `shells.log` gains one line for the
   pane, `pane_pid` unchanged (exec). With `mv F F.used` done first by the
   test, a key: the screen shows `roost restore is placing this pane`, no
   `shells.log` line, `F.used` still there. `send-keys -l 'echo keep-me'` then
   `C-a`: the shell's line is empty. `remain-on-exit` on the pane is unset
   after a winning key. With `default-command 'exec /bin/sh'` set, a key
   hands over to `/bin/sh` (`ps -o args= -p #{pane_pid}`).
2. The program (POSIX `sh`): args `FILE --placing` (Part 3 adds `FILE
   HARNESS`). Print the line for the file's current name; loop `stty raw -echo
   min 0 time 50; dd bs=1 count=1` (Task 1.7's form); on a wake with no byte
   re-read the name and reprint on change; on a byte: drain (`stty -icanon min
   0 time 0`, one more `dd`), restore the terminal, `mv FILE FILE.taken`. Won:
   `tmux set -pu remain-on-exit`, then `exec` `#{default-shell} -c
   "#{default-command}"` read now with `tmux display -p`, or
   `#{default-shell} -l` when empty. Lost: reprint and keep waiting; **never**
   start a shell after a lost rename (§4.7 step 2). Comment each rule with its
   § and the measured reason (§2.10).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS; `sh -n scripts/roost-placeholder` exits 0.
**Commit:** `roost-placeholder: a pane roost can prove untouched, placing mode (#51)`

### Task 1.12 — Restore's server, sessions and the replaceable bootstrap

**Files:** `scripts/lib/roost-restore.sh` (new), `scripts/lib/roost-shape.sh` (owner rule), `bin/roost` (the `restore` arm), `tests/test-shape-place.sh`
**Depends on:** 1.4, 1.10, 1.11

Every shape in this task's cases has one window of one pane per session, so
a session is complete once its first pane is placed; windows and splits are
Task 1.13. The per-pane step (claim the file, respawn) lands **here**,
because the bootstrap cases need it, and Task 1.13 reuses it for every pane.

**Do:**
1. Red first (§8.1 test 2, cases base, a, b, c, d, e, f, g, h): restore into a
   server where one saved session exists → skipped and named, exit 12, the
   others placed, nothing added to the live one. Stopped server → its own
   bootstrap is placed into, exit 0, first pane's `cwd` the saved first pane's,
   `restoring/bootstrap.used` left. (a)–(e) skipped, exit 12, `pane_pid`
   unchanged, (d)'s screen still `echo keep-me`. (f) `ROOST_TEST_RESTORE_HOLD`
   + a real client attached from a pane of a second throwaway server (`env -u
   TMUX tmux -S <inner> attach`, the `tests/test-notify-osc.sh` way) + one key
   → `bootstrap.taken`, skipped, exit 12. (g) the same held bootstrap, client
   at 80x20 against a 200x50 save, no key → exit 0. (h)
   `ROOST_TEST_PLACE_HOLD_AFTER_USED` after `bootstrap → bootstrap.used`, one
   key: while held no `shells.log` line, screen `roost restore is placing this
   pane`; released: exit 0, a line only from restore's own respawn. Plus the
   owner rule: `restoring/` with a live pid makes a second restore refuse
   (exit 1, naming the pid); a dead pid, or a live pid with another start time
   (`ps -o lstart=`), is taken over (and T2b settles the dead run's bootstrap
   into a shell, its session then skipped, exit 12). **Dotted and numeric
   names** (Task 1.4): a saved session `v3.69-x` that exists is skipped and
   named, not made again; one that does not exist is placed (its one pane in
   its saved directory); the same for a session named `1`. **The restored server survives a resize
   storm:** with a real client attached at 80x20 to the 200x50 restored server,
   20 resizes of the outer pane in one second leave the inner server running
   (`tmux -S <inner> ls` exits 0) — the shape another tool's users crashed
   tmux with on a server made by `new-session -x -y`.
2. `roost_shape_owner_take DIR` (`mkdir`, then `pid` and `lstart` lines),
   `roost_shape_owner_live DIR`, `roost_shape_owner_drop DIR`; never by age.
3. `roost-restore.sh` placement, server and sessions part (§4.3): write
   `restoring/` first; stopped server → write `restoring/bootstrap`, then `-f
   CONF new-session -d -s <first session> -c <its first cwd> -x W -y H
   "$ROOST_HOME/scripts/roost-placeholder" restoring/bootstrap --placing`
   (argv, W and H the largest root cell of that session's saved layouts), then
   the same globals `ensure_session` sets and `roost wiring apply`; the
   replaceable test is exactly §4.3's (this run made it, won `mv bootstrap
   bootstrap.used`, still one pane). Other sessions: `restoring/place.<n>`
   written, then `new-session -d -s NAME -x W -y H <placeholder> place.<n>
   --placing`. Existing session → skip and name. `restoring/` dropped last.
   Every target built from a saved name takes Task 1.4's form (`=NAME:` and
   on), and existence is tested the way Task 1.4 found exact.
4. The per-pane step, `roost_restore_place_pane PANE FILE CWD`, in this
   order: (i) `mv FILE FILE.used`; lost → leave the pane; (ii) won →
   `ROOST_TEST_PLACE_HOLD_AFTER_USED` wait, **right after the rename and
   before any check**, so a test can change the pane in the gap; (iii) read
   the pane's start command and `pane_dead` **now**; not the placing line
   (a person respawned it) → `mv FILE.used FILE.taken`, **no respawn**, leave
   it (T2); (iv) still the placing line → `respawn-pane -k -c CWD
   "<default-command value>"` as one string (read once after `wiring apply`;
   empty → `#{default-shell}` and `-l` as argv). The bootstrap's first pane
   takes exactly these steps with `restoring/bootstrap`; Task 1.13 runs the
   same function on every other pane. Run it on each session's first pane.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS, exit 0.
**Commit:** `roost restore: sessions, the bootstrap that a key or a live session keeps (#51)`

### Task 1.13 — Windows, splits, layout, and the per-pane step

**Files:** `scripts/lib/roost-restore.sh`, `tests/test-shape-place.sh`
**Depends on:** 1.1, 1.3, 1.4, 1.12

**Do:**
1. Red first (§8.1 test 1 base, wide, wired; test 2 (i) unkeyed half, (j)):
   save 2 sessions / 3 windows / 6 panes with names, dirs and a split layout,
   one window of six stacked panes at `-x 200 -y 50`, index 5 under
   `base-index 1`, one zoomed; kill the server by its socket; restore;
   `status --json` before/after equal on `session`, `window_name`,
   `window_index`, `pane_index`, `name`, `cwd` (the first pane's too); layout
   strings equal with checksum and pane ids stripped; zoomed is zoomed, and
   after `resize-pane -Z` unzooms it its layout string equals the saved one
   (ids and checksum stripped), so a wrong layout under a right zoom flag is
   red (Task 1.1); first window 200x50. The test's conf also sets
   `pane-base-index 1` (pane indices come back as saved). **Odd names round
   trip:** a session `v3.69-x` and a session `1`, a window name and a `cwd`
   each holding a space, `$`, `'`, `"`, `#`, a trailing space and a UTF-8
   glyph: `window_name` and `pane_current_path` equal after restore. **Wide:** six side-by-side panes at `-x 200 -y 10` → six panes,
   layout equal. **Wired:** every shell pane, the first included, has
   `roost-pane-shell` in `#{pane_start_command}` and `ROOST_TMUX` in its
   environment (the stub `sh` writes it to a file). (i) unkeyed: a shape of two
   sessions, the second with a two-pane window; `ROOST_TEST_PLACE_HOLD` after
   that window; a key into a pane then `sleep 60` Enter; release →
   `place.<n>.taken`, `pane_pid` and the sleep alive, every other pane placed,
   exit 0. (j) `ROOST_TEST_PLACE_HOLD_AFTER_USED` after winning an unkeyed
   pane's `place.<n> → .used`; `respawn-pane -k -t %N 'sleep 60'`; release →
   `place.<n>.taken`, sleep alive, exit 0. **Hand edits (test 5's restore
   half):** a copy with a deleted pane block does not restore it; a renamed
   session (addresses renamed) is created under the new name; a linked window
   saved under two sessions comes back as two windows. **The K-pane
   fallback:** a hand-edited copy whose window's root cell is `20x6` with six
   saved panes, two of them keyed: restore places the panes that fit, the
   window keeps tmux's default layout, exit 13, and stderr names every block
   not placed with its key and `roost revive` guidance (§4.3) — a pane roost
   could not place never vanishes in silence, which is how another tool
   orphaned conversations when its splits failed.
2. Per window: `restoring/place.<n>` then `new-window -d -t SESSION:INDEX -n
   NAME -c CWD <placeholder> place.<n> --placing`; split until the saved count,
   each time on the pane whose larger side is largest, `-h` when width ≥
   height else `-v`, each pane created as a placing placeholder after its own
   `place.<n>`; a refused split → keep K panes, default layout, a stderr line
   naming the blocks not placed (their keys listed), exit 13. `select-layout`
   the saved string (failure: one stderr line); `resize-pane -Z` for `zoomed
   1`; Task 1.12's `roost_restore_place_pane` on every pane in index order.
   Names re-stamped; saved active window and pane selected. Keyed panes are
   shells in this part.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS, exit 0.
**Commit:** `roost restore: windows by the largest side, the saved layout, the per-pane rename (#51)`

### Task 1.14 — `--dry-run`, `--list`, `--from`, `--only`, directories

**Files:** `scripts/lib/roost-restore.sh`, `bin/roost` (the `restore` arm), `tests/test-shape-place.sh`
**Depends on:** 1.13

**Do:**
1. Red first: `--dry-run` prints §4.3's tree (first line naming the save and
   why; `session`, two-space `window`, four-space `pane` lines with index,
   name, directory, harness, action and reason) and exits with the code the
   real run would give; it starts no server (`tmux -L <name> ls` fails after);
   no colour when stdout is a pipe. `--list` prints `shape` and every
   `history/` save with stamp, `gen`, `trigger` and counts, marking the one
   restore would pick. `--from STAMP-GEN` finds `shape` first, then
   `history/`; `--from FILE` restores a copy; **other host** (§8.1 test 11,
   that case): `--from` a file whose `host` differs prints one line and
   restores. `--only SESSION`, `--only SESSION:WINDOW`, `--only %OLD`
   restrict placement. No shape → exit 2. A malformed shape → exit 16 and a
   listing before and after is identical (test 5's "create nothing").
   **Directories (§8.1 test 3, the placement half — 3a):** a pane whose `cwd`
   was removed is a shell in the home directory with one stderr line.
   **`renumber-windows`**, in a test server of its own whose conf sets
   `renumber-windows on` (kept apart from Task 1.13's index-5 fixture, where a
   renumber on any window close would move the window the assertion reads):
   the `--dry-run` tree carries §4.3's note that the user's conf renumbers.
2. Implement; `--from` reads `host` and the caller's server, never the file's
   `socket`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` and `bash tests/test-shape.sh` → all PASS, exit 0.
**Commit:** `roost restore: --dry-run tree, --list, --from, --only, a gone directory (#51)`

### Task 1.15 — R4: a non-interactive Claude child does not re-identify the pane

**Files:** `scripts/roost-session-context`, `tests/test-session-context.sh`
**Depends on:** 1.5 (skip this task, and say so in the report, when Task 1.5 found that `@roost-session` never moved)

**Do:**
1. Red first, in `tests/test-session-context.sh`: run the hook as `roost
   hooks claude` wires it, with a `SessionStart` payload naming session B on a
   pane already identified as session A, and the environment Task 1.5 found
   for the headless child (exactly its variable names and values): `@roost-
   session` still reads A, the pane record still names A, and the hook still
   prints its context and exits 0. The same payload with the interactive
   values Task 1.5 found: `@roost-session` reads B (a `/clear` or a resume must
   still re-identify). Unset variables: B (an older Claude that sets neither
   keeps today's behaviour).
2. In `scripts/roost-session-context`, before it calls
   `roost_identity_from_payload`: when the environment matches Task 1.5's
   non-interactive markers, skip the identity stamp (and nothing else). The
   comment names R4, the rule (§3.2's agreement check sees only another
   harness), and the measurement it rests on.

**Check:** `bash tests/test-session-context.sh` and `bash tests/test-identity.sh` exit 0.
**Commit:** `identity: a headless Claude run from the pane's own shell does not take over its key (#51)`

### Task 1.16 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md` (new; sidebar per `site/AGENTS.md`), `bin/roost` (help header lines for `save` and `restore`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 1.1–1.15

**Do:**
1. The page: what `save` writes and where (§3.1), the format and how to edit a
   copy (§3.2), `restore` placement, `--dry-run`/`--list`/`--from`/`--only`,
   the bootstrap rule and its cost (run `roost restore` from a plain
   terminal), a linked window comes back as two, a `cd` is not seen until the
   next save, scrollback is not saved on purpose, conversations belong to the
   harness, a shape on another machine resumes nothing. Say plainly that
   agents are not resumed yet.
2. Help lines; `ROOST_SHAPE_DIR`, and that `rm -rf ~/.local/state/roost/shapes`
   forgets every shape and nothing else.
3. known-gaps: Tasks 1.1–1.6's results (the zoom string, a session group
   comes back doubled with its agents refused as duplicates, the writer's
   rule for each odd value, the exact-match targets, the nested-Claude result
   and R4), the presence-alone risk (§10); history has no ring yet. The page
   says what the writer does with a name or directory holding a control
   byte.
4. Changelog (Added: `roost save`, `roost restore` placement).

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; `git diff --stat` shows `site/content/docs/changelog.md` changed with `CHANGELOG.md`.
**Commit:** `docs: roost save and roost restore (placement) (#51)`

### Task 1.17 — Verify

**Files:** none (report only)
**Depends on:** 1.16

**Do:**
1. `bash -n` every touched bash file under `/bin/bash` and bash 5; `sh -n
   scripts/roost-placeholder`.
2. Mutants (§8.1's list for this part), each run against the two new files,
   red count recorded, then restored: drop `select-layout`; drop `-x`/`-y`;
   merge into an existing named session; split the largest pane by area in the
   default direction; a bare `respawn-pane`; place a shell instead of a placing
   placeholder; start the placeholder through `default-command`'s value; start
   a shell after a lost rename; end bootstrap eligibility at an attach;
   classify stale keys only in a fixture (feed `restore` a hand-made file
   instead of `save`'s); write a control byte as read (the writer's own
   reader then refuses the file); target a saved session by its bare name
   (the dotted session is made twice); save the visible layout of a zoomed
   window; publish after a failed listing; drop the K-pane stderr names;
   skip R4's check (when Task 1.15 ran).
3. Suite, contrast, container (Global constraints); and `tests/test-shape.sh`
   and `tests/test-shape-place.sh` once more in `ubuntu:22.04` (tmux 3.2a),
   the same `git archive` recipe with that image.

**Check:** suite exit 0, no FAIL; container exit 0; every mutant turns at least one test red.
**Commit:** none

**Deferred (Part 1):** §8.2 item 7 — a person opens `shape` cold and says what
the fleet was; copies it, edits one `cwd`; `--dry-run --from COPY` says what
they meant.

---

# Part 2 — `roost revive` (§6 step 2, #57)

Design:     §4.1, §2.8, §5.1, §5.1a, §5.6 (the one-line note only; listings are Part 6), §1 (record gains `transcript`)
Repository: the `persist-2` worktree of this checkout (`.claude/worktrees/persist-2`)
Branch:     worktree-persist-2
Base:       origin/main when the part starts (Part 1 merged)
Oracle:     automated (`tests/test-revive.sh`) + instrumented (two probes, two live smokes)
Unattended: yes

No pending record exists yet, so `revive` meets only panes with **no file**
(§4.7's last row) and gone panes. Part 3 teaches it the pending states.
`claims/<boot>/` ships here.

**After this part merges, a user can:** `roost revive %N` a pane whose agent
crashed or was `/exit`ed and get the same conversation back in the same `%N`;
revive a closed pane on the same boot into a new window; and get a plain
reason (exit 13/14/15) instead of a dead pane when the conversation is gone.

### Task 2.1 — Probe: does `claude --resume` keep model and permission mode?

**Files:** `docs/airig/probes/persist-2-resume-flags.md` (new)
**Depends on:** nothing

**Do:** With `tests/live/claude-background-smoke.sh`'s rig (fake Messages API,
redirected homes, settings hash guard), start `claude --model haiku
--permission-mode plan`, one prompt, `/exit`, `claude --resume ID` with no
flags; read the model in the next request the fake API receives and the mode
shown on screen. Once; record the guard lines. Two more reads in the same run,
each recorded only (they inform questions for the coordinator, and nothing in
this plan is built on them): whether the `SessionStart` hook's environment
carries `CLAUDE_CONFIG_DIR` when the pane's Claude was started with one
(another tool resumed without it and found "No conversation found" for 7 of
8 sessions); and whether this Claude keeps a live-session registry file per
process (its path, what it holds, whether `/exit` and a `kill -9` each remove
it) — the only way roost could see the same conversation open outside roost.

**If the probe says:**
- both kept: nothing to build; the file says so; `launch` stays a hint.
- either dropped: nothing to build in this plan (§10: an allowlist per adapter
  is a follow-up); the file says which, and Task 2.10 adds a known-gaps entry
  and a site line ("a resumed Claude starts with its default model / mode").
- the run could not complete (the rig failed): **stop**.
- the two extra reads: any answer is recorded; none changes a task.

**Check:** `test -s docs/airig/probes/persist-2-resume-flags.md`, with the guard lines saying the real settings were unchanged.
**Commit:** `probe: what claude --resume keeps of the launch flags (#57)`

### Task 2.2 — Probe: does a re-filed transcript keep its first `cwd`?

**Files:** `docs/airig/probes/persist-2-refiled-cwd.md` (new)
**Depends on:** nothing

**Do:** Same rig. Start in trusted directory A, one prompt, `/exit`;
`claude --resume ID` from trusted directory B (it re-files, §2.1), one prompt,
`/exit`. Read the first `"cwd":"…"` of the file now under B's project folder
(`grep -m1 -o '"cwd":"[^"]*"' | head -n 1`) and whether A's file still exists.
**The worktree case** (one tool's users found a conversation unfindable once
Claude had moved it into a worktree): start in a repository root R, script an
`EnterWorktree` tool call so the session moves into `R/.claude/worktrees/w1`,
one more prompt, `/exit`. Record the transcript's folder, its first `cwd`, and
from which of R and the worktree `claude --resume ID` finds the conversation.

**If the probe says:**
- the first `cwd` is still A: §5.1's rule resumes in A, as written.
- the first `cwd` is B: the rule resumes where the conversation was last filed,
  which §5.1 accepts; no code change; say so in known-gaps (Task 2.10).
- no `cwd` line at all in the re-filed file: **stop** (the rule would refuse
  every re-filed conversation).
- worktree case, the resume works from the first `cwd` (R, or the worktree if
  that is what the first line names): §5.1 holds; Task 3.5 gains this fixture
  (a transcript filed under the worktree's folder whose first `cwd` is R)
  and asserts the stub runs in the first `cwd`.
- worktree case, the resume works **only** from a directory other than the
  first `cwd`: **stop** — §5.1's rule would resume such panes where Claude
  cannot find them, and the directory rule is the spec's to change, before
  Part 3 writes `cwd` into the pending record.
- `EnterWorktree` is not offered by the rig's Claude: record "not measured".

**Check:** `test -s docs/airig/probes/persist-2-refiled-cwd.md`.
**Commit:** `probe: the first cwd of a re-filed Claude transcript (#57)`

### Task 2.3 — The pane record keeps `transcript`

**Files:** `scripts/lib/roost-identity.sh` (`roost_identity__record`, `roost_identity_stamp`), `tests/test-identity.sh`
**Depends on:** nothing

**Do:**
1. Red first in `tests/test-identity.sh`: `roost identify --session S --cwd D
   --harness claude --transcript /abs/x.jsonl` writes `transcript` in the
   pane's record beside `session_id`, `cwd`, `harness`; without
   `--transcript`, no `transcript` file (absent, not empty); a relative
   transcript is refused as today.
2. `roost_identity__record` takes a seventh argument and writes it with
   `roost_record__put` only when non-empty; `roost_identity_stamp` passes its
   TRANSCRIPT through. Comment: additive under the record's schema rule (§1).

**Check:** `bash tests/test-identity.sh` and `bash tests/test-identity-adapters.sh` exit 0.
**Commit:** `identity: the pane record keeps the transcript path, for a gone pane's revive (#57)`

### Task 2.4 — The resume table, the directory rule and the store checks

**Files:** `scripts/lib/roost-resume.sh` (new), `tests/test-revive.sh` (new)
**Depends on:** 2.2

**Do:**
1. Red first, library-level cases in `tests/test-revive.sh` (sources the lib
   directly; stub stores under the redirected harness homes):
   `roost_resume_command HARNESS ID TRANSCRIPT` prints the argv of §2.8 one
   word per line (`claude --resume ID`; `codex resume ID`; `copilot
   --resume=ID`; `pi --session PATH` when a session file is known, else `pi
   --session ID`; opencode → returns 3, "print, do not run"); an id that fails
   its adapter's shape (a UUID for four; codex's rollout uuid) is refused.
   `roost_resume_dir`: Claude → the transcript's first `"cwd":"…"`, refused on
   a `\`, the first of two on one line; pi → `session_cwd` else `cwd`; codex,
   copilot, opencode → `session_cwd` else `cwd`. `roost_resume_store_check`:
   Claude → the recorded file exists, else exactly one
   `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<id>.jsonl`; codex → a
   `$CODEX_HOME/sessions/**/rollout-*-<id>.jsonl` (find, no `**` glob);
   copilot → `$COPILOT_HOME/session-state/<id>/`; pi → recorded file, else
   exactly one `$PI_CODING_AGENT_DIR/sessions/*/*_<id>.jsonl`; zero or two →
   miss. `roost_resume_exact_id` returns that one file. Folders in the stub
   store are named by the measured rule (`/` and `.` → `-`), every path dotted
   (`…/repo/.claude/worktrees/w1`).
2. Implement. Nothing evaluates a shape or record value; the command is an
   argv.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-revive.sh` → all PASS, exit 0.
**Commit:** `resume: the per-harness command, the directory rule and the store check (#57)`

### Task 2.5 — Claims

**Files:** `scripts/lib/roost-resume.sh`, `tests/test-revive.sh`
**Depends on:** 2.4

**Do:**
1. Red first: `roost_resume_claim DIR HARNESS ID PANE` makes
   `claims/<boot>/<harness>-<id>/` with `pid`, `lstart`, `pane` (`pane` empty
   until the launcher knows it). When `mkdir` fails, the existing claim is
   judged in **two stages**, §4.1 step 5a's rule:
   - **it names a pane** — the same pane as this claim → taken over (an
     in-place revive of a pane whose earlier launch never identified); another
     pane that **exists** on this server → refused, naming it, **whatever the
     claimer's liveness** (the claimer is usually a short-lived `revive` that
     has already exited while its pane sits in a dialog); a pane that is gone →
     stale, taken over.
   - **it names no pane yet** — the claimer's liveness decides: a live owner
     (pid running with its recorded start time) → refused; a dead owner, or
     the pid reused → taken over.
   Red cases for each: another existing pane **and a dead claimer** →
   refused; no pane and a dead claimer → taken over; no pane and a live
   claimer → refused; a gone pane with a live claimer → taken over.
   `roost_resume_release` removes only a claim whose `pid`/`lstart` are this
   run's; a refused claim is left byte for byte.
2. Implement. `roost_shape_owner_live` is used only in the no-pane stage;
   the pane stage asks tmux (`display -p -t %N '#{pane_id}'`).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-revive.sh` → all PASS.
**Commit:** `resume: one claim per conversation, released only by its taker (#57)`

### Task 2.6 — `roost revive` on a live pane, in place

**Files:** `bin/roost` (the `revive` arm, help line), `scripts/lib/roost-resume.sh`, `tests/test-revive.sh`
**Depends on:** 2.5

**Do:**
1. Red first (§8.1 test 6, the live-pane cases): a live idle stub pane →
   exit 0, the same `%N`, `@agent_state` and the identity four cleared before
   the respawn, the stub's argv `--resume <id>` in the chosen directory (its
   own key is not a duplicate); a `working` pane → exit 1, untouched; no key →
   exit 13 with `has no recorded conversation`; harness off `PATH` → exit 14;
   directory gone → exit 15; store miss → exit 13 and the same `pane_pid`;
   an id another live pane carries → exit 13 naming it; `claude-exit1` stub →
   `pane_dead` 1, window pane count unchanged. **Exited:** stub exited, shell
   back, identity set → exit 0, same `%N`; with `sleep 60` running → exit 1,
   sleep alive; `--force` then launches. **Nested** → 13; **other** (`sleep 60`
   foreground, identity set) → 13. **Release only one's own:** with a live
   claim for `%Q`, a refused revive of a second pane carrying K leaves the
   claim byte for byte. `--json` prints `{"pane","was","harness",
   "session_id","command","cwd"}`.
2. Implement §4.1 steps 1–8 for a live pane with no pending file: agreement →
   key → `PATH` → directory → store → claim → shell checks (`pgrep -P
   #{pane_pid}`) and the `working`/`blocked` rule → clear options (keep
   `@roost-name`) → `set -p remain-on-exit failed` → `respawn-pane -k -c DIR`
   with the argv, through `roost-pane-shell` when wired → print `%N`, one
   stderr line with the command. opencode: print the command, exit 13
   ("opencode resume is not checked; run: …"). No save call (Part 4 adds it).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-revive.sh` → all PASS; `bash tests/test-close.sh` exits 0.
**Commit:** `roost revive: bring a pane's conversation back in place, same %N (#57)`

### Task 2.7 — `revive` of a gone pane, and `--new-window`

**Files:** `bin/roost`, `scripts/lib/roost-resume.sh`, `tests/test-revive.sh`
**Depends on:** 2.3, 2.6

**Do:**
1. Red first (§8.1 test 6, the gone-pane cases): a gone `%N` with a record →
   a new window in the record's session (else the caller's), `@roost-was
   %OLD` on it, the stub launched; **gone, no transcript in the record**: one
   `<id>.jsonl` in a dotted-path folder → resumes in the transcript's `cwd`;
   two such files → 13, nothing launched; a record with `transcript` → used,
   the store not searched (the stub store emptied to prove it). **Two revives
   of one gone record** (stub never identifies): first → exit 0, a new window,
   `claims/<boot>/claude-<id>` naming it; second → 13 naming the first pane,
   one launch in the stub log; kill the first new pane; a third → launches
   (the claim names a gone pane, so it is stale and taken over — this proves
   the takeover only; that the kill **releases** the claim at once is Task
   4.10's case, since the hooks land in Part 4). `--new-window` of a live
   pane with its own key → 13 naming the pane itself, no new window.
2. Implement step 1's record path (`record_for` in `bin/roost`), the exact-id
   lookup, and step 7's `new-window -d` branch.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-revive.sh` → all PASS.
**Commit:** `roost revive: a gone pane comes back in a new window from its record (#57)`

### Task 2.8 — Live smoke: `revive` against the real Claude Code

**Files:** `tests/live/revive-smoke.sh` (new)
**Depends on:** 2.7

**Do:** Beside `tests/live/claude-background-smoke.sh`, reusing its fake API
and guard: one prompt, `/exit`, `roost revive %N` → the pane re-identifies the
**same** id (§2.1) and the old prompt is on screen; delete the transcript, then
`revive` → exit 13 and the pane untouched (same `pane_pid`).

**Check:** `bash tests/live/revive-smoke.sh` → every line PASS, guard lines unchanged (one run, recorded as one).
**Commit:** `live smoke: revive resumes the same Claude conversation, refuses a deleted one (#57)`

### Task 2.9 — Live smokes: one resume case for codex, copilot and pi

**Files:** `tests/live/codex-smoke.sh`, `tests/live/copilot-smoke.sh`, `tests/live/pi-smoke.sh`
**Depends on:** 2.7

**Do:** In each, after its existing turn: `/quit` or `/exit`, `roost revive
%N`, assert the old prompt on screen and the same id re-identified (codex:
assert the resume command ran; identity may be empty under the shared
app-server, §2.2). The codex smoke kills its own app-servers by their
environment's `CODEX_HOME`, as the probe did.

**Check:** `bash tests/live/codex-smoke.sh`, `bash tests/live/copilot-smoke.sh` and `bash tests/live/pi-smoke.sh` → every line PASS (one run each; a harness not installed is reported SKIP, not PASS).
**Commit:** `live smokes: a revive case for codex, copilot and pi (#57)`

### Task 2.10 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `site/content/docs/driving-a-fleet.md` (exit-code table), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 2.1–2.9

**Do:** The page's `revive` section: what it brings back, exit 13/14/15, the
dialogs a resume can open per harness (§2.8), "launched, not resumed",
opencode printed. known-gaps: Tasks 2.1 and 2.2 results; opencode not checked.
Changelog (Added: `roost revive`).

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: roost revive (#57)`

### Task 2.11 — Verify

**Files:** none
**Depends on:** 2.10

**Do:** `bash -n`; mutants against `tests/test-revive.sh`: skip the store
check; count the target as a duplicate; treat `exited` as `nested`; refuse a
gone pane with no recorded transcript; look for a claim without taking one;
release a claim the run did not take; require the transcript's `cwd` to equal
`session_cwd` or `cwd`. Suite, contrast, container.

**Check:** suite exit 0; container exit 0; every mutant red.
**Commit:** none

**Deferred (Part 2):** none.

---

# Part 3 — Restore resumes (§6 step 3)

Design:     §4.3 (Resumes, Report), §4.6 (all but the login service), §4.7 (all rows and T5–T19 except the hook-driven T13, T13a, T13b and T19 on a kill), §5.4, §5.5, §5.7, §2.9
Repository: the `persist-3` worktree of this checkout (`.claude/worktrees/persist-3`)
Branch:     worktree-persist-3
Base:       origin/main when the part starts (Parts 1–2 merged)
Oracle:     automated (`tests/test-shape-resume.sh`, `tests/test-shape-address.sh`) + instrumented (the §2.9 measurement)
Unattended: yes

**Worker-only cases.** The `client-attached` hook is Part 5. Every §8.1 case
in this part that says "attach a real client so the worker runs" is run here by
calling `roost restore --resume` directly and is **labelled in the test as not
covering the hook** (§8.1 test 11 allows this). The hook's own cases are
Part 5's.

**Probe.** §6 step 3 names one measurement, which needs the engine; it is Task
3.12, not first.

**After this part merges, a user can:** after a reboot, run `roost restore` and
get the fleet back with every agent resumed 2 s apart in its own directory;
press a key in a waiting pane to keep it as a shell; `roost restore --resume
--retry` once a cause is fixed; address an old pane as `was:%930`; see `(was
%930)` in `roost status`.

### Task 3.1 — The pending files, the renames, and the `origin` rule

**Files:** `scripts/lib/roost-pending.sh` (new), `tests/test-shape-resume.sh` (new)
**Depends on:** nothing

**Do:**
1. Red first (library level): `roost_pending_write DIR BOOT %N` writes a
   0600 file with `was`, `harness`, `session_id`, `transcript`, `cwd`,
   `session_cwd`, `session`, `window`, `order`; `roost_pending_take FROM TO
   ORIGIN` renames and then appends `origin ORIGIN` only when the rename won;
   `roost_pending_leave_launching FILE NEWNAME [REASON]` first rewrites the
   file without any `origin` line (a temp file beside it, renamed over), then
   renames; a `%N`, `%N.failed` or `%N.taken` produced by it has no `origin`
   line (revision 10, C B1). `roost_pending_state FILE` maps a name and first
   line to §4.7's row names (`waiting`, `launching`, `failed-waiting`,
   `failed-dead`, `failed-exited`, `failed-interrupted`, `failed-changed`,
   `failed-replaced`, `taken`).
2. Implement; comment each function with the arrows it serves.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` → all PASS.
**Commit:** `pending: the resume record between placement and launch, and its renames (#191)`

### Task 3.2 — The placeholder's pending modes

**Files:** `scripts/roost-placeholder`, `tests/test-shape-place.sh`
**Depends on:** 3.1

**Do:**
1. Red first: args `FILE HARNESS`: `waiting to resume claude - press any key
   for a shell`; renamed by the test to `.launching` → within 6 s `resuming
   claude now`, and a key then starts no shell; renamed to `.failed` with
   first line `store miss` → within 6 s `claude was not resumed: store miss -
   press any key for a shell; roost restore --resume --retry tries again`, no
   respawn, no `shells.log` line; a key there → `.taken`, the reason, then a
   shell. A key on `FILE` → `.taken`, `this pane is yours; claude was not
   resumed (roost revive %N to resume it)`. An `origin` line planted in the
   file it wins is removed from its `.taken` file before the shell starts.
2. Implement T6, T15 and the reprint for each state.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS; `sh -n scripts/roost-placeholder`.
**Commit:** `roost-placeholder: waiting, launching and failed lines, and T6/T15 (#191)`

### Task 3.3 — Placement writes the pending record

**Files:** `scripts/lib/roost-restore.sh`, `bin/roost` (`--no-resume`, `--recent`), `tests/test-shape-resume.sh`
**Depends on:** 3.1, 3.2

**Do:**
1. Red first, every case under `ROOST_TEST_LOOP_HOLD=FILE` (new here: a hand
   restore waits after placement, before its resume loop; until Task 3.5 there
   is no loop and restore simply ends there): `restore --no-resume` → no
   pending file, keyed panes shells; `restore` → every resumable keyed pane
   runs the placeholder by path (`#{pane_start_command}` names
   `roost-placeholder` and its file), each file written before its
   placeholder, `order` matching shape order; stale, gone-directory and
   no-key panes → shells, no file; `--recent 0` with an old transcript mtime →
   that pane a shell (`shells.log`) with no file under `pending/<boot>/`.
   **§8.1 test 2 (i), the keyed half:** a keyed pane taken during placement →
   no placeholder, its file `%N.taken`, one stderr line naming `roost revive
   %N`, no launch.
2. Implement T3 with the pending write first; `--recent` and `--no-resume`
   decided here (§4.3, revision 10); the `ROOST_TEST_LOOP_HOLD` wait at the end
   of placement.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` and `bash tests/test-shape-place.sh` → all PASS.
**Commit:** `restore: placement writes the pending record and waiting placeholders (#191)`

### Task 3.4 — The pane side: `send` refuses, `close` cancels

**Files:** `bin/roost` (`send`, `answer`, `close` arms), `scripts/lib/roost-pending.sh`, `tests/test-shape-resume.sh`
**Depends on:** 3.3

**Do:**
**The policy**, the `roost send` column of §4.7's table, one function for
`send` and `answer` alike. "Refused" is the blocked-target refusal (same exit
code, a message naming the state). `--force` bypasses **only this new
refusal**, as §7 says; each verb then keeps every check it has today —
`answer` still refuses a dead pane, a pane that is not `blocked` and one with
no dialog record (bin/roost's `answer` arm, steps 1 and 4–5), and `send`
keeps its own dead-pane and readiness checks.

| state (file, then pane) | `send` / `answer` |
|---|---|
| **placing** — `restoring/bootstrap` or `restoring/place.<n>`, the pane runs that placing line | refused |
| **placing, claimed** — that file as `.used` | refused |
| **placing, taken** — that file as `.taken` | as for any pane |
| **waiting** — `pending/<boot>/%N` | refused |
| **launching** — `%N.launching`, placeholder line | refused |
| **launched** — `%N.launching`, the resume command (perhaps a dialog) | refused unless `--force` |
| **failed, waiting / dead / interrupted** — `%N.failed` with that first line | refused |
| **failed, changed** — `%N.failed pane changed` | as for any pane |
| **failed, replaced** — `%N.failed replaced` | as for any pane |
| **taken** — `%N.taken` | as for any pane |
| no file | as for any pane |

1. Red first, at two levels. **The policy, per row:** `roost_send_policy
   STATE 0` and `STATE 1` for every row above → refuse/allow exactly as the
   table says (a function-level case; no delivery asserted). **The verbs:**
   `send` to each refused row (planted) → the ownership refusal and the file
   unchanged (the unforced waiting case: the file is still `%N`); `send
   --force` to the waiting row → the ownership refusal is bypassed and the
   text is typed into the placeholder, which takes it as a key (T6): after a
   bounded wait (50 × 0.1 s) the file is `%N.taken` and `$HOME/shells.log`
   has a line for the pane. Nothing is asserted about the text itself — the
   placeholder drains the rest of the input on purpose (§4.7 step 2); `answer` to each refused row → the ownership refusal before
   any dialog lookup; `answer --force` to the waiting row → today's "is not
   blocked … nothing to answer" (exit 6), and to a failed, dead pane →
   today's dead-pane refusal (exit 2), proving `--force` bypassed only the
   new check. **Forced delivery into a real dialog:** a **launched** pane —
   its file `%N.launching`, the pane running the dialog script of
   `tests/test-answer.sh` (which stamps 🛑 through the real sink and leaves a
   real dialog record) — both calls carry the same valid `--expect`
   fingerprint read from `status --json` (an approval without one is refused
   before any target check): `answer --expect FP --approve` without `--force`
   → the ownership refusal and no key logged; `answer --force --expect FP
   --approve` → the key is delivered and logged, as in `tests/test-answer.sh`.
   The placing rows are planted under `ROOST_TEST_PLACE_HOLD` and
   `ROOST_TEST_PLACE_HOLD_AFTER_USED` (Part 1's seams); **§8.1 test 11 (f)**
   is the waiting row, the file still `%N` afterwards. A shell taken during a
   placement that has since finished (placing line, no `restoring/` file in
   any name) → `send` delivers as to any pane. **§8.1 test 11, close
   on a waiting pane:** `roost close %N` on a waiting placeholder → pane gone,
   no `shells.log` line, file removed, exit 0. `close` on `.failed` and on a
   dead failed pane likewise uses `kill-pane`.
2. `roost_pane_owner_state %N` in `scripts/lib/roost-pending.sh`: reads
   `#{pane_start_command}` and `#{pane_dead}` once; a placing line names its
   `restoring/` file, whose current name gives the placing rows; a placing
   line whose `restoring/` file is gone in every name (`F`, `F.used`,
   `F.taken` — restore has finished and removed `restoring/`, and the start
   command survived the `exec` that gave a person the shell, §2.10) is the
   **no file** row; else the pane's file under `pending/<boot>/` gives the
   rest. It prints the row
   name. `roost_send_policy STATE FORCE` returns refuse or allow from the
   table. `send` and `answer` call both where they test `blocked`; `close`
   calls the state first and, for the placeholder states, removes the file,
   releases any claim, and `kill-pane`s (T19, F N1).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh`; `bash tests/test-close.sh`, `tests/test-send-turn.sh`, `tests/test-answer.sh` exit 0.
**Commit:** `send refuses a waiting pane; close cancels its resume with kill-pane (#191)`

### Task 3.5 — The resume engine (`restore --resume`, and a hand restore)

**Files:** `scripts/lib/roost-pending.sh`, `scripts/lib/roost-restore.sh`, `bin/roost` (`--resume`, `--pace`), `tests/test-shape-resume.sh`
**Depends on:** 3.3

**Do:**
1. Red first (§8.1 test 4 resume, directory rule, siblings, duplicate, stale,
   store miss, mid-turn; test 3 the exit-13 half — 3b; test 11 (a) (b) (c)
   (e), worker-only): the stub runs `--resume <id>` in the chosen directory,
   two agents ≥ 2 s apart; shells placed before any agent; `--no-resume` → 0
   runs; `--recent 0` with an old transcript → 0 runs; **`--recent` holds at
   the next attach** (worker-only): after that restore, `restore --resume`,
   two `--pace` intervals → the stub log still empty, the pane still that
   shell; `--only SESSION` → one session; directory rule cases (shell cwd,
   identity cwd, neither but existing, removed → not run, `\` refused, two on
   one line → first) with dotted paths; when Task 2.2's worktree case held,
   a transcript filed under the worktree's folder whose first `cwd` is the
   repository root runs the stub in the root; exited/nested not launched and named;
   siblings each get their own `--resume`; duplicate → the first launched, the
   second `%N.failed duplicate of %M` showing it, exit 13; store miss → exit
   13, `%N.failed store miss`, still the placeholder; a gone `cwd` with a key
   → exit 13 (3b); a pane saved `state working` named in the report. (a)
   `echo keep-me` + `C-a` into a placeholder with `--pace 6` → `%N.taken`,
   empty line, same `pane_pid`, two launches. (b) `sleep 60` Enter → same,
   sleep never ran. (c) `respawn-pane -k -t %N 'sh'` before its turn →
   `%N.failed pane changed`, `sh` untouched. (e) with
   `ROOST_TEST_RESUME_HOLD`, a key after `.launching` → `resuming claude
   now`, no shell, the resume replaces it.
2. Implement §4.6's loop: hold `resuming/` (owner rule); walk plain `%N`
   files by `order`, shells first; per pane: T5 + `origin waiting`; §4.1
   steps 3–5 read-only → T7 on failure (pane untouched); claim → T7
   `duplicate of %M`; check the pane by its from-state row → T9; T10
   (`remain-on-exit failed`, `respawn-pane -k`); `--pace` between launches.
   A hand `restore` runs this loop in the foreground after placement.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` → all PASS.
**Commit:** `restore: resume every waiting agent, paced, through one engine (#191)`

### Task 3.6 — `--retry`, the worker's takeover and T8b

**Files:** `scripts/lib/roost-pending.sh`, `bin/roost` (`--retry`), `tests/test-shape-resume.sh`
**Depends on:** 3.5, 3.7 (its cases need a launched file removed when the stub identifies, T11)

**Do:**
1. Red first (worker-only): **Retry recovers (A)** store miss repaired →
   `--retry` launches once more, `pane_dead` 0, file gone after identify;
   **(C)** the same pane taken and running `sleep 60` → `--retry` launches
   nothing; **(D)** `%N.failed pane changed` → nothing, sleep alive. **A key
   after a failure is marked:** `ROOST_TEST_RESUME_HOLD_AFTER_FAILED` → reason
   on screen within 6 s, same `pane_pid`, no `shells.log` line; one key →
   `.taken`, a shell; `sleep 60`; release → sleep alive. **A `.failed` file is
   retried only with `--retry`** (that `--list` names it is Task 3.11's
   case, where the pending listing lands). **Interrupted** (test
   11): kill the loop after the first launch → one file gone, two claimable,
   the next `restore --resume` takes the dead worker's `resuming/` and
   launches exactly those two. **Interrupted after the claim:** kill the
   worker under `ROOST_TEST_RESUME_HOLD` → the next run renames `.launching`
   back and launches it once. **Duplicate across workers:** two panes, one
   key, the stub never identifying; kill after the first launch; run again →
   the second `%N.failed duplicate of %M`, the claim names the first; kill the
   first pane; `--retry` launches the second.
2. Implement T14 (first line decides), T8b by `origin` (only the holder of
   `resuming/`), and the takeover.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` → all PASS.
**Commit:** `restore --resume --retry: recover what was fixed, never a person's pane (#191)`

### Task 3.7 — Identity lands: T11, T12, T18

**Files:** `scripts/lib/roost-identity.sh` (the stamp's callers' path), `bin/roost` (`identify` arm), `scripts/lib/roost-pending.sh`, `tests/test-shape-resume.sh`
**Depends on:** 3.5

**Do:**
1. Red first: a stub that runs `roost identify` with the same id → the
   `.launching` file and the claim removed (T11); with a different id →
   `%N.failed replaced`, claim released (T12); **§8.1 test 11, taken then an
   agent started:** a stub run by hand in a taken pane identifies → `%N.taken`
   removed (T18). An identify that changes nothing does not touch pending (the
   one-read bail stays).
2. Behind `ROOST_IDENTITY_WROTE=1` only, in the `identify` arm and in
   `roost_identity_from_payload`, call `roost_pending_identified SOCK %N ID`.
   No save call yet (Part 4).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh`; `bash tests/test-identity.sh`, `tests/test-session-context.sh`, `tests/test-codex-hook.sh` exit 0.
**Commit:** `identify releases a pending resume: same id, different id, a taken pane (#191)`

### Task 3.8 — `revive` meets the pending states

**Files:** `scripts/lib/roost-resume.sh`, `bin/roost` (`revive`), `tests/test-revive.sh`
**Depends on:** 3.6

**Do:**
1. Red first (§8.1 test 6, revision 3/4/5/10 cases, worker-only where they
   attach): **revive against a waiting pane** → `%P.launching`, exit 0, a
   worker run after launches nothing for `%P`; **overlapping the worker**:
   `revive %Q` then `restore --resume` → `%P.failed duplicate of %Q`, one
   launch; **a taken pane in use** → exit 1, sleep alive, `%P.taken` again,
   no claim; **idle** → exit 0, same `%P`; **`--force`** → launched; before
   each, assert `#{pane_start_command}` still equals the placeholder line;
   **a revive of a taken shell, interrupted** (`ROOST_TEST_REVIVE_HOLD`, `kill
   -9`, then a worker run) → `%P.taken`, claim gone, sleep and `pane_pid`
   alive, nothing launched; **no origin line** (planted) → `%P.failed
   interrupted`, `--retry` launches nothing; **an inherited origin** (store
   miss → no `origin` line; T15 → none; `ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN`,
   `kill -9`, worker run) → `%P.failed interrupted`, nothing launched;
   **`--new-window` from a pending file** → 13 `revive it in place`, file
   still `%P`.
2. Implement §4.1 step 5a's pane claim by state (T5, T14, T16, T17, T8c),
   T8, the `origin` append after a win, step 7's check column per state.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-revive.sh` and `bash tests/test-shape-resume.sh` → all PASS.
**Commit:** `revive: claim a pending pane by its state, with the shell checks for a taken one (#57)`

### Task 3.9 — `@roost-was`, the alias map and `was:%N`

**Files:** `scripts/lib/roost-restore.sh`, `bin/roost` (a new `resolve_was` used by `send`, `read`, `wait-done`, `screen`, `answer`, `close`, `revive`, `forget`; `status` human line), `scripts/lib/roost-jsonout.sh` (`roost_jsonout_status`), `tests/test-shape-address.sh` (new), `tests/test-json-output.sh`
**Depends on:** 3.5

**Do:**
1. Red first (§8.1 test 7 whole; test 11 "two sockets"; the §8.1 guard on
   `status --json`): after a restore `send was:%OLD "x"` reaches the new pane
   with `roost send: was:%OLD is %NEW` on stderr; `read was:%OLD` reads the
   old boot's record; a bare `%OLD` naming a live pane delivers there with the
   courtesy note; a bare `%N` naming nothing → exit 2, no redirect; `was:%N`
   not in the map → exit 2; two restores with the same old id → `was:%N` exit
   2 naming both `was:%N@BOOT`, and each form delivers; a map file from
   another boot is ignored; `close was:%OLD` closes the new pane. A shape from
   server A restored into server B → B's map has A's ids, nothing placed in A.
   `status --json` gains `was` (null when none), byte-identical otherwise
   (update the gold documents in `tests/test-json-output.sh`); `status` human
   lines end `(was %930)` on a restored pane.
2. Placement sets `@roost-was %OLD` and appends `%OLD OLDBOOT %NEW` to
   `aliases/<new boot>`. `resolve_was RAW` (new, in `bin/roost` beside
   `target()`): a `was:` prefix → this boot's map only → a `%N`, or exit 2;
   a bare `%N` → itself, plus the note when it is also an old id. Call it
   first in each named verb.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-address.sh`, `bash tests/test-json-output.sh`, `bash tests/test-send-turn.sh` → exit 0.
**Commit:** `was:%N: an old pane id resolves through this boot's restore map, never by guess (#191)`

### Task 3.10 — Claude learns its old id

**Files:** `scripts/roost-session-context`, `tests/test-session-context.sh`
**Depends on:** 3.9

**Do:** Red first: with `@roost-was %930` set, the injected context adds `it
was %930 before a restore`; without it, the text is byte-identical. Then
implement: the script makes no tmux read of its own today (it asks `roost
whoami` for the pane id and calls `roost_identity_from_payload`), so add one
`tmux show-options -pqv -t "$pane" @roost-was` through the same socket
`whoami` resolved, `|| true`, after the pane id is known.

**Check:** `bash tests/test-session-context.sh` exits 0.
**Commit:** `session context: tell a resumed Claude the id it had before the restore (#191)`

### Task 3.11 — The report

**Files:** `scripts/lib/roost-restore.sh`, `tests/test-shape-resume.sh`
**Depends on:** 3.5

**Do:**
1. Red first: the report line of §4.3 (`restored S sessions, W windows, P
   panes; launched A agents; skipped K (existing); R not resumed …; M were
   working or blocked at the save — re-prompt by hand: %a %b`); one line per
   pane not resumed with its `launch` hint; the §5.6 one-liner for a stale or
   missing key; **the codex note** with two codex stub panes (`N codex panes
   resumed; until #145 their badges all land on the first (…)`); exit 0 / 12 /
   13, 12 winning; `--json` `{"restored":[…],"skipped":[…],"from":…}`;
   `--list` shows the pending record and `.launching`/`.failed`/`.taken`
   files; **§8.1 test 11:** a `.failed` file (store miss) is listed by
   `--list`.
2. Implement.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` → all PASS.
**Commit:** `restore: the report says what was launched, what was not and why (#191)`

### Task 3.12 — Measure: a resumed fleet against placement only (§2.9)

**Files:** `docs/airig/probes/persist-3-fleet-rss.md` (new)
**Depends on:** 3.11

**Do:** On a throwaway named server with every home redirected, place a
30-pane shape with `--no-resume` and read `ps -axo rss=,comm=` summed for the
server's tree; then the same shape with the resume (stub `claude` that holds
a fixed allocation, `python3 -c` sleeping) and read again at the end of the
pacing. Report the **ratio** with the method, once; if a real Claude rig is
available (Task 2.8's), add one resumed real Claude's RSS before its first
prompt.

**If the measurement says:** any ratio — record it; no code changes (§2.9 is
a hypothesis the number tests, not a gate). The file says whether it supports
"cold starts, not resident set".

**Check:** `test -s docs/airig/probes/persist-3-fleet-rss.md` with a ratio and its method.
**Commit:** `measure: a resumed stub fleet against placement only (#191)`

### Task 3.13 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `site/content/docs/driving-a-fleet.md` (`was:%N`, `status --json` `was`), `bin/roost` (help: `was:%N`, `--resume`, `--retry`, `--pace`, `--recent`, `--no-resume`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 3.1–3.12

**Do:** The page: resumes by default, pacing, the waiting line and what a key
does, `--retry`, `was:%N` and why a bare `%N` after a restore may be another
pane, the codex note, "launched" not "resumed". known-gaps: the §2.9 ratio;
a dialog on resume is left for a person. Changelog.

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: restore resumes agents; was:%N (#191)`

### Task 3.14 — Verify

**Files:** none
**Depends on:** 3.13

**Do:** `bash -n`, `sh -n`; mutants: no pacing; resume in `session_cwd`
without the transcript check; launch a `stale_*` key; skip the store check;
redirect a bare `%N` through the map; read the alias map without checking the
boot; a per-run duplicate set instead of `claims/`; claim with `cp` instead of
`mv`; skip the worker's rename and trust a pre-check; keep `origin` through T7
or T15; decide `--recent` only in the loop; skip the shell checks for a taken
pane; resume in the home directory when `cwd` is gone (test 3); respawn a
failed pane into a shell that prints its reason (test 11, a key after a
failure is marked); a retry check that only a placeholder can pass, or no
check at all for a failed file (test 11 retry A, D). Suite, contrast,
container.

**Check:** suite exit 0; container exit 0; every mutant red.
**Commit:** none

**Deferred (Part 3):** §8.2 item 6 — two real codex panes after a restore: the
badges land where the codex note says they do.

---

# Part 4 — Save on change (§6 step 4)

Design:     §3.4, §3.5, §3.6, §3.6a, §4.5 (the saving warnings), §4.7 T13/T13a/T13b/T19 on a kill, §2.7
Repository: the `persist-4` worktree of this checkout (`.claude/worktrees/persist-4`)
Branch:     worktree-persist-4
Base:       origin/main when the part starts (Parts 1–3 merged)
Oracle:     automated (`tests/test-shape-save.sh`, `tests/test-shape-closed.sh`) + instrumented (four probes, three cost measurements)
Unattended: no — Tasks 4.1 and 4.2 need a Linux VM; Task 4.8 waits for ruling R1

**After this part merges, a user can:** forget `roost save` — every structural
change is saved within a moment, a crash loses at most the last change, and a
shutdown restores the fleet as it was, not what was closed on purpose.

### Task 4.1 — Probe: the Linux shutdown record

**Files:** `docs/airig/probes/persist-4-linux-shutdown.md` (new)
**Depends on:** nothing

**Do:** On a Linux VM (Ubuntu 24.04; the coordinator supplies it — **none
available: stop, BLOCKED needs a Linux VM**), reboot twice, then read `last -x
shutdown`, `last -x reboot`, `journalctl --list-boots` and
`/proc/sys/kernel/random/boot_id`. Note the time resolution and zone of each.

**If the probe says:**
- `last -x shutdown` prints a shutdown time with minute or better resolution:
  Task 4.9b reads it on Linux (the window: that minute and the one before).
- no wtmp, but `journalctl --list-boots` gives the previous boot's last entry
  time: Task 4.9b reads that.
- neither readable: Linux takes rule 3 (§3.6), as the spec allows.

**Check:** `test -s docs/airig/probes/persist-4-linux-shutdown.md` with one outcome named.
**Commit:** `probe: the shutdown record on Linux (#192)`

### Task 4.2 — Probe: does tmux run `session-closed` during a shutdown?

**Files:** `docs/airig/probes/persist-4-shutdown-hooks.md` (new)
**Depends on:** nothing

**Do:** On the same VM, a throwaway `-L` server with three sessions whose
`session-closed[97]`, `pane-exited[97]` and `window-unlinked[97]` hooks append
to a file on a persistent disk; `systemctl poweroff`; read the file after boot.

**If the probe says:** hooks ran (a shrinking chain) or none ran — either is
allowed; the 100-entry ring and §3.6's rule stand; record which. The file is
unreadable or empty because the disk write was lost: say so; not a stop.

**Check:** `test -s docs/airig/probes/persist-4-shutdown-hooks.md`.
**Commit:** `probe: tmux hooks during a Linux shutdown (#192)`

### Task 4.3 — Probe: hook names and moves on tmux 3.2 and 3.4

**Files:** `docs/airig/probes/persist-4-hooks-tmux.md` (new)
**Depends on:** nothing

**Do:** In `ubuntu:22.04` (tmux 3.2a) and `ubuntu:24.04` (tmux 3.4), from a
`git archive` export, rerun §2.7's revision 4 probes: `set-hook -g NAME[98]
'run-shell -b true'` for every name of §3.4's table and `client-attached`,
`pane-died`, with a made-up name as the control; and the move probe (a `[97]`
hook per name appending its name) for `break-pane`, `move-window`,
`link-window`, `join-pane`, `swap-pane`, `swap-window`, `respawn-pane -k`,
`kill-pane`.

**If the probe says:**
- every name exists and every move fires as on 3.6: Task 4.6 installs the
  table as written.
- a name is missing on 3.4 (CI): **stop** — the conf would refuse on CI.
- a name is missing on 3.2 only: **stop** — roost's floor is 3.2; the
  coordinator decides between raising the floor and a version guard.
- a move fires differently: **stop** if it changes a kill difference
  (§3.6a); otherwise record it and add the case to Task 4.6's "what no hook
  covers" list.

**Check:** `test -s docs/airig/probes/persist-4-hooks-tmux.md` with both versions.
**Commit:** `probe: tmux 3.2 and 3.4 hook names and moves (#191)`

### Task 4.4 — Probe: the kill difference on tmux 3.2 and 3.4

**Files:** `docs/airig/probes/persist-4-kill-diff.md` (new)
**Depends on:** nothing

**Do:** In the same two containers, §2.7's revision 3 probe: every structural
hook refreshes `set -gF @ids "#{S:#{W:#{P:#{pane_id} }}}"`; each removal hook
first `run-shell -b` with the old value and the new loop. Cases: `kill-pane`;
`kill-session` (not the last); a pane dying in its own window and its own
session; a death then a `kill-pane` within 20 ms; `break-pane`, `move-window`,
`join-pane`; `kill -TERM` of the server.

**If the probe says:** the same BEFORE/AFTER sets as on 3.6 → Task 4.6 as
written. A death appears in a kill's difference, or a kill does not → **stop**
(§3.6a rests on it).

**Check:** `test -s docs/airig/probes/persist-4-kill-diff.md` with both versions.
**Commit:** `probe: the kill difference on tmux 3.2 and 3.4 (#191)`

### Task 4.5 — The saver: one per server, a want per cause, a ring of 100

**Files:** `scripts/lib/roost-shape.sh`, `tests/test-shape-save.sh` (new), `tests/run.sh` (`shard_weight`)
**Depends on:** 4.3, 4.4

The shutdown-hook probe (Task 4.2) is not a prerequisite here: its answer is
used by the reading rule's steps 1–3 and the part's verify task, which wait
for it.

**Do:**
1. Red first (§8.1 test 8, the saver's own half; the test calls `roost save
   --auto` directly): `restoring/` with a live pid → `save --auto` writes
   nothing, leaves its want. `lock/` with a dead pid → taken over; alive with
   another start time → taken over. **Owner held past 10 s** — held 15 s, a
   second `save --auto` takes no lock and writes nothing, its want is there;
   release → published. `history/` holds at most `ROOST_SHAPE_KEEP` (set to 3).
   **§8.1 test 10, the auto half (10b):** `ROOST_SHAPE_DIR=` and a relative one
   → `save --auto` exits 0 within 5 s, writes nothing; a read-only shape dir →
   `save --auto` silent, exit 0; a `restore --dry-run` loop while 20 saves land
   never sees a refusal. (The hooks' own "exit 0 within 5 s" is asserted in
   Task 4.6 with the conf loaded.) **A listing that fails mid-round:** hold
   the saver with `ROOST_TEST_SAVE_HOLD_AFTER_DRAIN`, kill the server by its
   socket, release → `shape`, `gen` and `history/` unchanged, `save --auto`
   silent with exit 0. **R3, `save.err`, in a writable directory:** that
   failed round, and a round whose publish fails by
   `ROOST_TEST_PUBLISH_FAIL=1`, each leave `save.err` (0600) naming the
   stamp, the failing step and its exit code; the next published save removes
   it. **A read-only shape directory** (a separate case): `save --auto`
   writes nothing, exits 0, prints nothing, and no `save.err` is required (it
   cannot be created there); Task 4.11's doctor line is what shows it. **The directory removed
   under a held saver:** `rm -rf` the shape directory while
   `ROOST_TEST_SAVE_HOLD_AFTER_LIST` holds the saver; release → the saver
   publishes nothing into it and exits 0 (its lock went with the directory);
   the next save makes a fresh directory whose `gen` starts at 1. (One tool
   found a deleted session brought back by a late write from its own saver;
   this pins the opposite.)
2. Turn Part 1's publisher into §3.5: steps 1–4, the three seams, `gen` and
   `history/<stamp>-<gen>`, the ring prune after each publish. `--auto` never
   prints and never fails loudly. R3: write `save.err` on a failed list or
   publish and remove it on the next publish. Before publishing, check that
   `gen` and the lock this round made still exist; if not, publish nothing.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-save.sh` → all PASS.
**Commit:** `save --auto: one saver per server, every cause kept, a ring of 100 (#51)`

### Task 4.6 — The hooks, `@roost-ids` and the kill files

**Files:** `tmux/roost.conf`, `scripts/lib/roost-shape.sh` (`closed/` writes), `bin/roost` (the `save` arm's hidden flags), `tests/test-shape-closed.sh` (new)
**Depends on:** 4.3, 4.4, 4.5

**Do:**
1. Red first: **§8.1 test 8 hooks** — load `tmux/roost.conf` into a throwaway
   server on the suite's tmux with stderr captured: empty, and every `[98]`
   name it sets is listed by `show-hooks -g`. **Kills by every route (8i):**
   `kill-pane` → a `kill.*` file naming exactly that pane; `kill-window` of a
   two-pane window and `kill-session` (not the last) → files naming exactly
   their panes, the save after labelled `window-unlinked` / `session-closed`;
   `break-pane`, `join-pane`, `move-window` → none; `kill -TERM` of the server
   → none. **Overlap rewritten (8b2):** with the saver held, `kill-pane` B and
   let stub C (alone in its own window and session) exit → the kill and close
   files name B only, a `died.<C>` note exists. **Death in the gap:**
   `ROOST_TEST_SAVE_HOLD_AFTER_DRAIN`, C exits, then `kill-pane` B → still
   only B. **A boot change (8h):** `--at-login`-free version — a `shape` from
   boot B1; kill the server; start B2 with `restore` held by
   `ROOST_TEST_RESTORE_HOLD`, split a pane and kill it, release → `closed/<B2>/`
   names exactly that pane, nothing under `closed/<B1>/`. **What no hook
   covers:** `swap-pane`, `swap-window`, a `join-pane` that keeps its window →
   no new `shape` until the next event; `respawn-pane -k` by hand → none.
   `window-layout-changed` alone → none. **Coalescing on cue** —
   `ROOST_TEST_SAVE_HOLD` holds the saver; ten `rename-window`s to ten names,
   each firing its hook; release → exactly one more history file, its body the
   tenth name, its `trigger` listing every distinct trigger fired; held again,
   ten `roost save --auto --trigger save` with no change → no new history
   file, `gen` unchanged. With `ROOST_SHAPE_DIR=` every hook still exits 0
   within 5 s (10b's hook half).
2. `tmux/roost.conf`: one line per hook of §3.4's three structural rows plus
   `after-select-layout`, `after-resize-pane`, `pane-died`, each `[98]`,
   `run-shell -b "… save --auto --trigger NAME --boot … [--pane #{hook_pane}]
   [--ids-before '#{@roost-ids}' --ids-after '#{S:…}'] >/dev/null 2>&1 || :"`
   then `set -gF @roost-ids "#{S:#{W:#{P:#{pane_id} }}}"`. The four hooks that
   already hold the `events --reconcile` line in `[98]` keep it and gain the
   save in the same slot's command list (a slot holds a list; one line per
   hook). Only names Task 4.3 measured. The comment above the block says why
   each is there and why `window-layout-changed` is not.
3. `save --auto` step 1 (§3.5): before the lock, `kill.<stamp>-<pid>` from the
   before/after difference (empty after-list → nothing), `died.<N>` from
   `pane-exited --pane`, both under `closed/<the hook's boot>/`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-closed.sh` → all PASS; `bash tests/test-events.sh` and `bash tests/test-died-shared.sh` exit 0.
**Commit:** `save on change: tmux hooks, the pane list in the server, and the kill record (#51)`

### Task 4.7 — Direct save calls in roost's own verbs

**Files:** `bin/roost` (`spawn`, `split`, `view`, `identify`, `revive`, `close`, the restore final save), `scripts/lib/roost-identity.sh`, `scripts/lib/roost-pending.sh` (the launch's save), `tests/test-shape-save.sh`
**Depends on:** 4.5, 4.6 (the hook-driven verbs in its list — `rename-window`, `kill-pane`, the moves, `select-layout` — save through 4.6's hooks)

**Do:**
1. Red first (§8.1 test 8, per verb): `spawn`, `split`, `rename-window`,
   `kill-pane`, `move-pane` of a window's last pane, `break-pane`,
   `move-window`, `link-window`, `select-layout`, `identify` and `revive` each
   produce a new `shape` (body or `gen`); `trigger` is the hook's name, `close`
   after `roost close`, `save` after the verb, `respawn` after `revive`;
   **50 `roost state working` on a working pane produce none**; restore's final
   save has `trigger restore` and is the only one during a restore. **Ten
   `roost spawn`s in parallel** → a `shape` holding all ten panes, at most ten
   history files, every history name unique, `gen` monotonic.
2. Add `roost save --auto --trigger NAME` after the name is stamped in
   `spawn`/`split`/`view`; behind `ROOST_IDENTITY_WROTE=1` in `identify` and
   `roost_identity_from_payload`; after the respawn in `revive` and in the
   engine's T10; `close` after the pane is gone with `--trigger close`;
   restore after `restoring/` is dropped. `ROOST_TEST_NOW` read by `close`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-save.sh`; `bash tests/test-agent-state.sh`, `tests/test-reply-record.sh`, `tests/test-close.sh` exit 0; `bash tests/test-shape-isolation.sh` (Task 1.8's canary run, now that `spawn` and `split` save) exits 0 with the canary dir empty.
**Commit:** `save on change: roost's own verbs save after they change the fleet (#51)`

### Task 4.8 — `roost close` records its intent (and ruling R1)

**Files:** `bin/roost` (`close`, and per R1-A `kill|down|stop`), `tests/test-shape-closed.sh`
**Depends on:** 4.6, 4.7, 4.9a (its restores filter by `closed/`, the reading rule's step 4), ruling R1

**Do:**
1. Red first: **(8b) the planted race** — A and B run the stub; `roost close
   A` with `ROOST_TEST_SAVE_HOLD` keeping `close`'s save until the
   `pane-exited` save for A is published; assert the newest `shape` is that
   save without A and `close`'s save wrote nothing; then `roost restore
   --from <STAMP-GEN of the newest save that still holds A>` → A not back
   (`closed/<boot>/close.<A>`; step 4 applies to `--from STAMP-GEN`, so this
   needs no shutdown record — the walk back to that save by the reading rule
   is Task 4.9b's chain case). **Same second** under `ROOST_TEST_NOW`. **(g)
   a save in flight** — `ROOST_TEST_SAVE_HOLD_AFTER_LIST` while A is listed;
   `roost close A`; release; B dies; `restore --from <STAMP-GEN of the save
   published after the close, which holds A>` → A not back.
   **The ends of a fleet** (R1-A; this plan's own case — §8.1 test 8 (e)
   itself runs through `--at-login` in Task 5.6): `roost kill NAME` of a
   session and `roost stop` each leave one `closed/<boot>/close.<N>` per pane
   they removed, written before the tmux command, and a plain `restore` then
   prints `nothing to restore: every saved pane was closed on purpose` and a
   second line naming the way back, `to bring back a fleet you stopped:
   roost restore --from <a file from roost restore --list>` (the full path of
   the newest `history/` file, or of `shape`, printed), exit 0; `restore
   --from <that STAMP-GEN>` prints the same two lines (step 4 filters it);
   `restore --from <that file's path>` places the whole fleet.
   A failed close (the harness does not leave) removes its `close.<N>`. (The
   belt — a kill file and a death note keep a pane, a `close.` file and a
   death note do not — is Task 4.9a's case, which owns step 4.)
2. `close`: write `closed/<boot>/close.<N>` before the exit command; remove it
   on exit 1 or 2 with the pane still there. R1-A: `kill NAME` and `stop` write
   one `close.<N>` per pane they will remove, before the tmux command.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-closed.sh` → all PASS; `bash tests/test-close.sh` exits 0.
**Commit:** `close records its intent, so a closed pane stays closed after a reboot (#51)`

### Task 4.9a — The `closed/` filter by pane id (reading rule step 4)

**Files:** `scripts/lib/roost-restore.sh`, `tests/test-shape-closed.sh`
**Depends on:** 4.6

Ungated: step 4 reads only `closed/<boot>/` and the picked save's own `boot`,
no OS record. Without shutdown evidence restore picks `shape` (Part 1), so
every case here names its save with `--from`.

**Do:**
1. Red first: step 4 removes from the picked save every pane a `closed/` file
   of **that save's boot** names — for a plain `restore` (`shape`) and for
   `--from STAMP-GEN`, not for `--from FILE`; files of another boot are never
   read. A pane named by a kill file and a death note is kept; by a `close.`
   file and a death note, removed. A window that lost panes to step 4 → tmux's
   default layout and one stderr line; an emptied window or session → not
   created; nothing left → `nothing to restore: every saved pane was closed
   on purpose`, exit 0. **8 (i), the restore half:** after a `kill -TERM` of
   the server (no hook, no kill file), a plain `restore` brings the whole
   fleet back.
2. Implement step 4 as `roost_restore_drop_closed PARSEDIR BOOT`, called on
   whichever save was picked (Task 4.9b adds the picking).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-closed.sh` → all PASS.
**Commit:** `restore drops every pane its boot's closed record names (#51)`

### Task 4.9b — Shutdown evidence: which save a restore picks (steps 1–3)

**Files:** `scripts/lib/roost-restore.sh`, `tests/test-shape-closed.sh`
**Depends on:** 4.2, 4.8 (its chain case runs Task 4.8's planted `roost close` race, which needs `close`'s intent file), 4.9a (and 4.1's result when there is one)

**Do:**
1. Red first (§8.1 test 8 a, c, d, f): with `ROOST_SHUTDOWN_AT`, (a) a chain of
   `pane-exited` saves inside the window → the save before it is picked and
   `--list` names it (this is also the reading-rule form of 8 (b): with the
   planted race of Task 4.8 inside the window, a plain `restore` walks back
   to the save holding A and A still does not come back); (c)
   `ROOST_SHUTDOWN_AT=` empty → the newest save and the stderr line,
   `closed/` still applied; (d) 60 death saves → still recoverable; (f) a stub
   `last` printing `shutdown time … Dec 31 23:59` and a stub boot second on 1
   January → the window is in the year before. **8 (b2), the restore half:**
   restore inside the window brings back C, its window and its session, and
   not B.
2. Implement §3.6 rules 1–3 in epoch seconds, then Task 4.9a's step 4 on the
   pick; macOS `last reboot` + `sysctl kern.boottime`; Linux per Task 4.1's
   outcome. If Task 4.1 is blocked for want of a VM, Linux takes rule 3 (the
   spec's "until it lands") and the report says so; this task does not wait
   for 4.1.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-closed.sh` → all PASS.
**Commit:** `restore picks the save before a shutdown's teardown (#51)`

### Task 4.10 — The saver applies the hook-driven arrows

**Files:** `scripts/lib/roost-shape.sh` (saver step 2), `scripts/lib/roost-pending.sh`, `tests/test-shape-resume.sh`
**Depends on:** 4.6, 4.7 (its "dialog keys survive" case saves through `spawn`), 1.7's result

**Do:**
1. Red first (§8.1 test 11, worker-only where it says attach): **Released** —
   `claude-exit1` → `%N.failed died`, claim gone, `--retry` reaches it; **retry
   (B)** — good stub first on `PATH`, `--retry` → one more launch, `pane_dead`
   0, same `%N`; **a kill releases a revive's claim at once** (§8.1 test 6,
   the release half of "two revives of one gone record"): a gone-pane `revive`
   whose stub never identifies leaves a new pane holding
   `claims/<boot>/claude-<id>` and **no** pending file; `kill-pane` it → wait,
   bounded (50 × 0.1 s, the suite's usual loop: the release comes from the
   `-b` hook's saver), until the claim directory is gone, and assert it went
   before any further `revive` runs; the same when the pane **dies** (the stub
   exits 1 under `remain-on-exit failed`) — the claim is released by
   `pane-died`;
   **the only pane of the only session** — the `claude-exit1`
   case again with the restored fleet being one pane in one session, under
   `remain-on-exit failed` and `pane-died[98]`: the server is still running
   and lists one dead pane, the file `%N.failed died` (a tmux build once
   exited the server in exactly this shape; run here on the Mac's tmux and
   in both containers by Task 4.13); **a crashed placeholder** (Task 1.7's form) → dead pane,
   `%N.failed died`, `--retry` launches; **a resume that exits 0** →
   `%N.failed exited`, no claim, `--list` names it, `revive %N` → new window,
   file gone; **a dead pane retried while still broken** → count unchanged,
   first line `died`, `store miss` later; fixed → launched; **a placeholder
   that crashes while failed** → `%N.failed died`, then recovers; **the first
   line decides** (T16 for `died`, T14 for `store miss`); **`kill-pane` on a
   placed pane** before the worker → file removed, the worker launches two;
   **a taken pane `exit`ed** → same through `pane-exited`; **dialog keys
   survive**, the structural half: a stub that never identifies, then a
   `spawn` → `shape` carries its key with `resume pending`; a `.failed` one with
   `resume failed …`. Also the §8.1 guard: the record tests pass with shapes
   on (`bash tests/test-reply-record.sh`).
2. In saver step 2: `pane-died.<%N>` → T13/T13a; `pane-exited.<%N>` on
   `.launching` → T13b, on any other file → T19; a pane in a kill difference →
   T19; and, **with or without a pending file**, a claim under
   `claims/<boot>/` whose `pane` line names a pane in the kill difference, or
   one that died or exited, is released (§4.1 step 5a: a launch keeps its
   claim until identity lands or the pane dies); the overlay (all four file kinds) when writing a pane with no
   `@roost-session`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` and `bash tests/test-reply-record.sh` → exit 0.
**Commit:** `the saver moves a died, exited or killed pane's resume to its row (#191)`

### Task 4.11 — Cost measurements and the doctor's saving lines

**Files:** `scripts/roost-doctor`, `tests/test-doctor.sh`, `tests/test-shape-save.sh`, `docs/airig/probes/persist-4-cost.md` (new)
**Depends on:** 4.5, 4.7

**Do:**
1. Measure (§3.4a cost), once each, ratio with the method: `roost save --auto`
   time at 47 panes; time and files written for ten spawns in one second; 50
   `roost state working` on a working pane write no shape (already a test;
   record its time). Red first in `tests/test-shape-save.sh`: **no process per
   pane** — a recording stub `ps` first on `PATH`; `save --auto` on a
   server of 4 panes and one of 40 calls it the same number of times (the
   owner rule's own read, at most 2); other tools' per-pane `ps` saves
   pinned whole machines after a sleep.
2. Red first in `tests/test-doctor.sh`: `persist: saving on; login restore
   off (…)`; `ROOST_SHAPE_DIR=` → `persist: saving off (ROOST_SHAPE_DIR is
   empty); login restore off`; `warn` for a `lock/` or `restoring/` with one
   live owner over 60 s (planted, pid named); `warn` N panes run a harness with
   no recorded conversation and M carry a disagreeing identity. **R3:** a
   planted `save.err` → a `warn` line quoting its step and exit code; a
   running server with **no** save whose `boot` is its own → `warn: no save
   since this server started (…)`, with `persist` off as well as on, only
   while `roost_shape_saving` prints a directory (with `ROOST_SHAPE_DIR=` no
   such line: saving is off by choice); a read-only shape directory → that
   line, with no `save.err` line required; a server whose newest save is its
   own → no such line.
3. Implement those doctor lines (the login-restore half is Part 5). The
   "no save since this server started" line is unconditional (R3 extends
   §4.5, which tied it to `persist` on).

**Check:** `bash tests/test-doctor.sh` exits 0; the cost file has three numbers with methods.
**Commit:** `doctor: what saving does on this server; the cost of a save, measured (#51)`

### Task 4.12 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `bin/roost` (help: `ROOST_SHAPE_KEEP`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 4.1–4.11

**Do:** The page: saving is automatic, what triggers it, what is saved late
(swaps, a join that keeps its window, a drag resize, a `cd`), the ring, which
save a restore picks, closed stays closed, `roost close`/`kill`/`stop` (per
R1) as the way to end a fleet for good — and, under R1-A, how to undo it:
a fleet ended with `roost stop` or `roost kill` comes back only with
`roost restore --from <path of a saved file>`, with the worked example of
R1's paragraph (`--list`, then `--from` the `history/` file by path), and a
sentence that `--from STAMP-GEN` honours the close and restores nothing; and R3: `doctor` says when no save
has landed since the server started and quotes `save.err`. known-gaps: Tasks 4.1–4.4 and 4.11
results; the user-hook global-queue risk. Changelog.

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: saving on change, and what a restore picks (#51)`

### Task 4.13 — Verify

**Files:** none
**Depends on:** 4.2, 4.12

**Do:** `bash -n`; mutants: save on `after-set-option`; drop the lock; a single
`want` flag; break a lock by age; step back over a `close` save; drop the
`closed/` line; write `closed/` for a death; compare `closed/` with `saved` or
by `gen`; record a missing window or session as killed; compare `shape` with a
new listing to find kills; hook `after-kill-window`; let a kill file outvote a
death note, or a death note outvote a `close.` file; no `pane-died[98]`; read
a placeholder's exit as a cancel; read only `%N` pending files in the overlay;
read live options instead of the pending record in the gap (test 11);
`mv -f` without `mktemp`. Suite, contrast, container on `ubuntu:24.04` **and**
`ubuntu:22.04` (tmux 3.2a) for `tests/test-shape-*.sh`. R3 mutants: no
`save.err` on a failed listing; the "no save since" line gated on `persist`.

**Check:** suite exit 0; both containers exit 0; every mutant red.
**Commit:** none

**Deferred (Part 4):** none (§8.2 item 3 rides Part 5's reboot).

---

# Part 5 — `roost persist`, the login restore, the first attach (§6 step 5, #192)

Design:     §4.4, §4.5 (login half), §4.6 (trigger, `ensure_session`, cleanup), §8.2 items 1–5
Repository: the `persist-5` worktree of this checkout (`.claude/worktrees/persist-5`)
Branch:     worktree-persist-5
Base:       origin/main when the part starts (Parts 1–4 merged)
Oracle:     automated (`tests/test-persist.sh`, `tests/test-shape-attach.sh`, `tests/test-second-server.sh`) + instrumented (three probes) + human-eye (§8.2 items 1–5)
Unattended: no — Task 5.1 needs a Linux VM; Task 5.3 needs a person to quit the terminal app

**The gate.** Tasks 5.3 (R5's probe) and 5.4 (R2's guard) land before any
task that starts a server at login or from a terminal: both failures leave a
second server, or no server, where a live fleet was.

**After this part merges, a user can:** run `roost persist on` once, reboot,
log in, and find the fleet placed; type `roost` and watch the agents come back
2 s apart, with any dialog in front of them; `roost persist off` without
stopping a single agent.

### Task 5.1 — Probe: the systemd unit on a Linux VM

**Files:** `docs/airig/probes/persist-5-systemd.md` (new)
**Depends on:** nothing

**Do:** On a Linux VM (none: stop, BLOCKED needs a Linux VM), a hand-written
unit of §4.4's shape (`Type=oneshot`, `RemainAfterExit=yes`,
`KillMode=process`, `ExecStart` a script that starts a `tmux -L probe` server
with three `sleep` panes and exits 0). Read: after `systemctl --user start`,
the server alive after the script exits; after `systemctl --user disable` (no
`--now`), still alive; after logout and login without linger, with linger,
and with `KillUserProcesses=yes` set in a drop-in, what survived.

**If the probe says:**
- the server survives exit and `disable`: build §4.4 as written.
- the server dies at the oneshot's exit or at `disable`: **stop** (§4.4's
  core claim).
- logout results: any — record them for the page and §8.2 item 2.

**Check:** `test -s docs/airig/probes/persist-5-systemd.md` with each case.
**Commit:** `probe: a oneshot user unit keeps its tmux server across exit, disable and logout (#192)`

### Task 5.2 — Probe: the placeholder under `dash`

**Files:** `docs/airig/probes/persist-5-placeholder-dash.md` (new)
**Depends on:** nothing

**Do:** In `ubuntu:24.04` from a `git archive` export, run
`tests/test-shape-place.sh` and Task 1.7's wake probe with `/bin/sh` = `dash`.

**If the probe says:** passes → nothing. `stty`/`dd` behave differently (no
wake, or no byte) → **stop**.

**Check:** `test -s docs/airig/probes/persist-5-placeholder-dash.md`.
**Commit:** `probe: the placeholder under dash (#192)`

### Task 5.3 — Probe (R5): does quitting the terminal app kill a server started from it?

**Files:** `docs/airig/probes/persist-5-terminal-quit.md` (new)
**Depends on:** nothing

**Do:** On the newest macOS available (record `sw_vers`), with a temp `HOME`
and a throwaway `-L` name under a temp `TMUX_TMPDIR`: open the system
terminal app, start `tmux -L probe new-session -d 'sleep 600'` in it, note the
server pid, quit the app (Cmd-Q), wait 5 s, read `ps -p PID`. Repeat with the
two candidate remedies: (i) the server started by a throwaway LaunchAgent
plist (label `dev.roosting.roost.probe`, loaded with `launchctl bootstrap
gui/$(id -u)` and removed with `bootout` after) whose job runs the same `tmux
new-session -d`; (ii) the server started from the terminal under `nohup` and
a new session (`setsid` where present). Once each. Never the live server.

**If the probe says:**
- the server survives the quit: R5 is not confirmed on this macOS; record the
  version; Task 5.10 is skipped and says so; §8.2 item 1's terminal-quit check
  (deferred list) is what will see it on a newer macOS.
- the server dies, and candidate (i) survives: Task 5.10 builds Y — with
  `persist` on, on macOS, the server is started through roost's own launchd
  job instead of as the terminal's child; with `persist` off, `doctor` warns
  and the page says so.
- the server dies, and only candidate (ii) survives: Task 5.10 builds Y with
  (ii) as the start path on macOS, whatever `persist` says.
- the server dies and neither candidate survives: **stop**.

**Check:** `test -s docs/airig/probes/persist-5-terminal-quit.md` with `sw_vers`, the pids and one outcome named; `launchctl print gui/$(id -u)/dev.roosting.roost.probe` fails afterwards (the probe job is gone).
**Commit:** `probe: a terminal quit and the tmux server it started, on macOS (#192)`

### Task 5.4 — R2: never start a second server under a live one's name

**Files:** `bin/roost` (`ensure_session`, new `server_lost_socket`), `scripts/lib/roost-restore.sh` (the **Server** step), `tests/test-second-server.sh` (new)
**Depends on:** nothing (Parts 1–4 merged)

**Do:**
1. Red first, `tests/test-second-server.sh` (named server, `lib-shape.sh`):
   start the inner server with `roost spawn a sh` (a save lands with its
   `boot`); `rm` its socket file; then `roost spawn b sh` → exit 1, stderr
   `roost: the tmux server (pid N) is still running but its socket is gone;
   kill -USR1 N recreates it` with the real pid, and the only tmux server
   process for that socket directory is still pid N (`ps -axo pid=,args=`);
   `roost restore` → the same exit and line, nothing placed. `kill -USR1 N` →
   the socket is back and `roost spawn b sh` works. Controls: a newest save
   whose `boot` names a dead pid, and one whose pid is alive but is not tmux
   (the test's own `sleep`), and one whose pid is a tmux with another start
   time → each starts a server as today.
2. `server_lost_socket`: called only when `server_running` is false and a
   server is about to be started; reads the newest save's `boot START-PID`
   (from `roost_shape_dir`'s `shape`, none → false); true when `kill -0 PID`
   succeeds, `ps -o comm= -p PID` ends in `tmux`, and now minus `ps -o etime=
   -p PID` (parsed `[[dd-]hh:]mm:ss`) is within 2 s of START. `ensure_session`
   and restore's **Server** step then print the line and exit 1. Task 5.6
   calls it from `--at-login` (log the line, exit 0). The comment names R2,
   the field lesson, and why the start time is checked (a reused pid after a
   reboot must not block).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-second-server.sh` → all PASS; `bash tests/test-panes.sh` exits 0.
**Commit:** `never start a second server while the first still runs with its socket gone (#192)`

### Task 5.5 — `roost persist on|off|status`

**Files:** `scripts/lib/roost-persist.sh` (new), `bin/roost` (the `persist` arm, help), `tests/test-persist.sh` (new), `tests/lib-shape.sh` (the `launchctl`/`systemctl` recording stubs)
**Depends on:** 5.1, 5.3, 5.4

**Do:**
1. Red first (§8.1 test 9): `ROOST_PERSIST_WRITE_ONLY=1` under
   `XDG_STATE_HOME=/custom`-style temp, `CODEX_HOME=/x`, `MY_API_KEY=1` →
   plist (macOS) or unit (Linux) naming this checkout and the server;
   `service.env` names the custom root and `/x`, not `MY_API_KEY`; the unit has
   `Type=oneshot`, `RemainAfterExit=yes`, `KillMode=process`, no `ExecStop`;
   one save with `trigger persist-on`; `on` for B then `off` for A leaves B's
   files and A's `shape`/`history/`/`pending/`. Second run, no seam, stubs
   first on `PATH` that record argv and fail on `stop`: `on` loads through the
   stub; `off` called `disable`/`bootout`, never `stop` or `--now`; a name with
   a space or `/` → exit 1; `status` reads it all back. (On with the server
   stopped needs `--at-login`: Task 5.6.) **The publish wait:** a
   planted live `lock/` → `on` waits (no load call while the owner lives),
   then saves and loads. A failing save removes `persist` and `service.env`.
   No launchd or systemd → exit 17. **`service.env` is written by `on` and
   only by `on`:** edit a line in it, then run `status` → the file is byte for
   byte the edited one (another tool rewrote its unit on every start, lost
   users' edits and raised a system notification each time). The same check
   for `--at-login` is Task 5.6's and for `doctor` Task 5.9's, where those
   land.
2. Implement §4.4 `on`/`off`/`status`; `on`'s save is not `--auto` (waits by
   the owner rule); `server_running` decided once.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-persist.sh` → all PASS.
**Commit:** `roost persist on|off|status: one login unit per server, never stopped (#192)`

### Task 5.6 — `--at-login`: place, stop, leave the pending record

**Files:** `scripts/lib/roost-persist.sh`, `scripts/lib/roost-restore.sh`, `tests/test-shape-attach.sh` (new)
**Depends on:** 5.5

**Do:**
1. Red first: **§8.1 test 1 "started at all"** — wired by the real
   `roost wiring apply`; `restore --at-login` with no client → every keyed
   pane's `#{pane_start_command}` begins with the placeholder's absolute path
   and holds no `'`; one second later every `pane_dead` 0 and every
   placeholder shows its waiting line; with the conf's `default-command 'exec
   /bin/sh'`, unkeyed panes run it and a key hands over to `/bin/sh`. **§8.1
   test 11, the placement half:** three keyed panes → three placeholders, one
   shell, three pending files, nothing launched; a `spawn` then → `shape`
   carries the keys with `resume pending`; kill the server, `--at-login` again
   → three files again with `order`. **Dialog keys survive, the reboot half:**
   after Task 4.10's structural save, kill the server and `--at-login` → the
   pending and the `.failed` files are back. **§8.1 test 8 (e) the last
   session** (per R1; under A the close is `roost kill NAME` of the only
   session, under B `roost close` of its only pane): with `persist` on, end
   the only session; the server ends; with `ROOST_SHUTDOWN_AT=` empty,
   `restore --at-login` places nothing, prints the "closed on purpose" line,
   exits 0; the same with `ROOST_TEST_NOW` putting the last save and the close
   in one second; the same fleet torn down by stub exits only (no close),
   inside the window, is restored whole. **§8.1 test 9, on with the server
   stopped:** a planted `main` + `work`, server down, Task 5.5's stubs that
   start `restore --at-login <inner>` on the load call → `on` exits 0, the load
   logged, `shape` still the planted save until the job's `--trigger restore`
   save (no `persist-on` save in between), the job places both. `--at-login`
   writes `restoring/` first, waits up to 60 s for
   the socket directory, writes `login/<os-boot>` and `login.log` (0600,
   halved past 1 MB), removes other boots' `pending/` and `claims/` after its
   own files, and always exits 0. **`closed/` is not swept with them** (§3.6a,
   §4.6): `closed/<boot>/` is removed only when **no** save in `shape` or
   `history/`, not `declined`, and not a live offer's `offer/save` names that
   boot. **Ring case (red):** a B1 save kept in `history/`,
   `closed/<B1>/close.N` for a pane in it; `--at-login` on boot B2 →
   `closed/<B1>/close.N` still exists, and `roost restore --from <that B1
   STAMP-GEN>` does not place `%N`. **Eventual cleanup (red):** with
   `ROOST_SHAPE_KEEP=2`, enough B2 saves that no B1 save is left in the ring,
   and no `declined` → the next `--at-login` removes `closed/<B1>/`. (The
   `declined` and pin cases are Part 7's, Tasks 7.2 and 7.5.) **`service.env`
   untouched by `--at-login`:** an edited `service.env` is byte for byte the
   same after an `--at-login` run. **Idempotent at login:**
   `--at-login` three times in a row against a running server whose fleet is
   placed → session, window and pane counts unchanged after the first, three
   `login.log` lines, exit 0 each time, no second bootstrap session (another
   tool's boot unit added a session per restart). **Nothing to place starts
   nothing:** in the 8 (e) case above, no inner server exists afterwards
   (`tmux -L <inner> ls` fails). **R2 at login:** with Task 5.4's lost-socket
   server planted, `--at-login` logs R2's line, starts nothing, exits 0.
2. Implement. `--at-login` decides "nothing to place" after §3.6 step 4 and
   before the **Server** step, and calls `server_lost_socket` (Task 5.4)
   first. The `closed/` sweep reads the boots named by every save left
   (`shape`, `history/*`, `declined`, `offer/save` when `offer/` has a live
   owner) and removes only the other boots' directories.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-attach.sh` → all PASS.
**Commit:** `persist --at-login: place the fleet at login and keep every key for the first attach (#192)`

### Task 5.7 — The first attach: `client-attached[98]`

**Files:** `tmux/roost.conf`, `bin/roost` (`restore --resume --auto`), `tests/test-shape-attach.sh`
**Depends on:** 5.6

**Do:**
1. Red first (§8.1 test 11, the hook cases): **a real attach** from a pane of
   a second throwaway server with no direct `restore --resume` → three stubs
   2 s apart in `order`, exactly three launches, each file `.launching` then
   gone on identify; **the same with `client-attached[98]` deleted** from the
   test's conf → zero launches; **two clients** in the same second → each stub
   once; **worker held past 10 s** (`--pace 6`, second attach at 12 s) →
   nothing extra, `resuming/` still names the first; **(d) must still launch** —
   rc files with banners, client at 80x20 against a 200x50 save → all three
   launch, none `.taken`/`.failed`; the same with a `.bashrc` and `.zshrc` that
   **block** (`read -r x` at the end) → all three still launch (neither the
   placeholder nor the resume runs a shell rc; other tools typed their resume
   into a shell whose rc file never returned); a detach starts nothing. `restore --resume
   --auto` waits for a live `restoring/` owner before it walks.
2. `tmux/roost.conf`: `set-hook -g client-attached[98] 'run-shell -b
   "…/bin/roost restore --resume --auto … >/dev/null 2>&1 || :"'` (a Task 4.3
   measured name), with its why.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-attach.sh` → all PASS.
**Commit:** `the first attach resumes the agents, paced, and a detach never does (#192)`

### Task 5.8 — `ensure_session` waits for, or runs, the login restore

**Files:** `bin/roost` (`ensure_session`), `tests/test-shape-attach.sh`
**Depends on:** 5.6

**Do:**
1. Red first (§8.1 test 11's last cases): `persist` on, no server, a `shape`,
   no `login/<os-boot>` → `roost spawn x sh` (through `ensure_session`) runs the
   placement itself; with the marker → it does not. A live `restoring/` owner
   → `ensure_session` waits, printing `waiting for the login restore (pid N)`
   every 10 s, then goes on; a dead owner → no wait.
2. Implement; `persist` off → unchanged (Part 7 adds the offer).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-attach.sh`; `bash tests/test-panes.sh` exits 0.
**Commit:** `ensure_session waits for the login restore, or runs it when the service did not (#192)`

### Task 5.9 — `roost upgrade` follows, and `doctor` says the login half

**Files:** `scripts/roost-upgrade`, `scripts/roost-doctor`, `tests/test-upgrade.sh`, `tests/test-doctor.sh`
**Depends on:** 5.5

**Do:** Red first: with `persist` on (write-only seam), an upgrade that moves
the checkout rewrites the unit to the new path and says so; doctor's line
`persist: saving on; login restore on for 'NAME' (launchd, unit names this
checkout; roots match; last save …; last login restore: …; N pending)`; `warn`
when the unit names another checkout, `service.env` names a root the caller
lacks, its `PATH` lacks a harness the shape names, or this boot's pending
record has unlaunched or failed panes; and `resuming/` over 60 s. (The "no
save since this server started" line is Task 4.11's, unconditional by R3.)
And: an edited `service.env` is byte for byte the same after `roost doctor`
(Task 5.5's rule, the doctor leg). Then implement.

**Check:** `bash tests/test-upgrade.sh` and `bash tests/test-doctor.sh` exit 0.
**Commit:** `upgrade rewrites the login unit; doctor reports the login restore (#192)`

### Task 5.10 — R5: start the server where a terminal quit cannot reach it (only if Task 5.3 confirmed the kill)

**Files:** `bin/roost` (`ensure_session`'s server start), `scripts/lib/roost-persist.sh` (the start job), `scripts/roost-doctor`, `tests/test-persist.sh`, `tests/test-doctor.sh`
**Depends on:** 5.3, 5.5, 5.8 (skip this task, and say so in the report, when Task 5.3 found the server survives)

**Do:**
1. Red first, with the recording `launchctl` stub of Task 5.5 and `uname`
   reading `Darwin`: with Task 5.3's candidate (i) chosen and `persist` on,
   `roost` with the server stopped and the login marker present (so no
   restore) starts the server through the start job — the stub log holds the
   job's load or kickstart call, and the server that answers is the one that
   job started (its parent is not the test's shell: `ps -o ppid= -p <server
   pid>`) — then attaches as today; with `persist` off, today's start, and
   `doctor` prints `warn: a server started from a terminal ends when the
   terminal app quits on this macOS (roost persist on starts it through
   launchd)`. With candidate (ii) chosen instead: every macOS start goes
   through it (the server's session id differs from the test shell's:
   `ps -o sess=`). On a non-Darwin `uname`, nothing changes.
2. Implement the chosen candidate: for (i), a second plist written by
   `persist on` beside the login unit, label
   `dev.roosting.roost.<server>.start`, whose job only starts the server the
   way `ensure_session` does and places nothing; `ensure_session` loads or
   kicks it and waits up to 10 s for `server_running`. `persist off` removes
   it with the login unit. For (ii), the start wrapped as the probe proved.
   The comment names R5 and the probe's file.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-persist.sh` and `bash tests/test-doctor.sh` exit 0.
**Commit:** `macOS: start the server where quitting the terminal app cannot end it (#192)`

### Task 5.11 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `site/content/docs/getting-started.md` (a pointer only), `bin/roost` (help: `persist`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 5.1–5.10

**Do:** The persist section: `on`/`off`/`status`, what runs at login and at
first attach, linger on Linux, `off` never stops an agent, the Keychain note,
what `service.env` holds and never holds, that `service.env` is rewritten
only by `persist on`, R2's line and `kill -USR1`, and Task 5.3's result (and
Task 5.10's start path when built). known-gaps: Tasks 5.1–5.3.
Changelog (Added: `roost persist`).

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: roost persist and the login restore (#192)`

### Task 5.12 — Verify

**Files:** none
**Depends on:** 5.11

**Do:** `bash -n`; mutants: load the unit in a test; `--now` on `off`;
delete `client-attached[98]`; break `resuming/` by age; place a shell instead
of a placeholder at login; start the placeholder through `default-command`'s
value; drop R2's check (a second server starts); R2 without the start-time
compare (a planted non-tmux or reused pid blocks); rewrite `service.env`
outside `on`. Suite, contrast, container.

**Check:** suite exit 0; container exit 0; every mutant red.
**Commit:** none

**Deferred (Part 5) — one pass, on a spare machine or VM, never the live server:**
1. §8.2 item 1 — a real macOS reboot with `persist on`: placement at login,
   waiting lines, agents 2 s apart after `roost`, a key keeps a shell, each
   Claude at its prompt with its conversation, `login.log` names the save and
   why, `restore --list` shows the pending record empty; count dialogs by
   harness; repeat with `roost` typed before the service ran. Then quit the
   terminal app (Cmd-Q), open it again, and `roost`: the fleet is still there
   (R5; on a macOS where Task 5.3 did not see the kill, this is the check that
   will).
2. §8.2 item 2 — the same on a Linux VM; without linger the unit starts at
   login; `persist off` with forty stub agents ends none; a logout/login with
   the distribution's `KillUserProcesses`: say what survived.
3. §8.2 item 3 — after item 1, `restore --list`: did saves land in the final
   seconds, with which triggers; does `last reboot` carry the minute; did the
   rule pick right.
4. §8.2 item 4 — Claude's credentials at first attach: what the Keychain
   shows.
5. §8.2 item 5 — `roost upgrade` with `persist on`: the unit follows.

---

# Part 6 — The printed store listings (§6 step 6, Q4 = A)

Design:     §5.6, §2.8 ("source if roost has no key"), §9 Q4
Repository: the `persist-6` worktree of this checkout (`.claude/worktrees/persist-6`)
Branch:     worktree-persist-6
Base:       origin/main when the part starts (Parts 1–5 merged)
Oracle:     automated (`tests/test-shape-listing.sh`) + instrumented (two probes)
Unattended: yes

**After this part merges, a user can:** see, for a Claude or codex pane roost
has no key for, every conversation of that directory as ready-to-type
`claude --resume <id>` / `codex resume <id>` lines, newest first — printed,
never run.

### Task 6.1 — Probe: Claude's folder rule for `_`, a space and a non-ASCII byte

**Files:** `docs/airig/probes/persist-6-claude-folders.md` (new)
**Depends on:** nothing

**Do:** Task 2.1's rig; start Claude once in each of `a_b`, `a b`, `aé`
(trusted); list the throwaway `projects/` folder names.

**If the probe says:** a definite rewrite per character → Task 6.3's narrowing
uses it. Unclear or lossy → Task 6.3 scans every folder for those paths (the
narrowing only shortens; §5.6 allows it).

**Check:** `test -s docs/airig/probes/persist-6-claude-folders.md`.
**Commit:** `probe: Claude's project folder name for _, space and non-ASCII (#191)`

### Task 6.2 — Probe: pi's folder rule for a path with a `.`

**Files:** `docs/airig/probes/persist-6-pi-folders.md` (new)
**Depends on:** nothing

**Do:** `tests/live/pi-smoke.sh`'s rig in `…/.claude/worktrees/w1`; read the
session folder's name.

**If the probe says:** any rule → recorded (only narrowing would use it; pi
has no listing in §5.6, so nothing else changes). It would not run → not
measured, recorded.

**Check:** `test -s docs/airig/probes/persist-6-pi-folders.md`.
**Commit:** `probe: pi's session folder for a dotted path (#191)`

### Task 6.3 — The Claude listing

**Files:** `scripts/lib/roost-resume.sh`, `tests/test-shape-listing.sh` (new)
**Depends on:** 6.1

**Do:**
1. Red first: a stub store with five transcripts in two folders (dotted
   paths), three whose first `cwd` is the pane's directory byte for byte →
   three `claude --resume <id>` lines, newest mtime first; one with a `\` in
   its `cwd` → not listed; an `exited` pane's own stale id first; a folder the
   rule misses only shortens the list.
2. `roost_resume_listing claude DIR [STALE_ID]`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-listing.sh` → all PASS.
**Commit:** `listing: print every Claude conversation of a pane's directory, never run (#191)`

### Task 6.4 — The codex listing, and both wired in

**Files:** `scripts/lib/roost-resume.sh`, `scripts/lib/roost-restore.sh`, `bin/roost` (`revive`'s no-key branch), `tests/test-shape-listing.sh`
**Depends on:** 6.3

**Do:**
1. Red first: rollouts under `$CODEX_HOME/sessions/YYYY/MM/DD/` whose
   `session_meta.cwd` (first line; `grep -o`, no parser) is the pane's
   directory → `codex resume <id>` lines newest first. `revive` of a no-key
   Claude pane prints the listing after its exit-13 line; the restore report
   and `--dry-run` print it under a pane with a stale or missing key; nothing
   is ever launched from it (the stub log empty).
2. Implement.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-listing.sh` and `bash tests/test-revive.sh` → exit 0.
**Commit:** `listing: codex rollouts too; revive and restore print them (#191)`

### Task 6.5 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 6.1–6.4

**Do:** The page: what the listing is, why it is never run. known-gaps: the
two probes. Changelog.

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: the printed resume lines for a pane with no key (#191)`

### Task 6.6 — Verify

**Files:** none
**Depends on:** 6.5

**Do:** `bash -n`; mutants: derive Claude's folder from "`/` as `-`" and
decide by it; run the newest listed id. Suite, contrast, container.

**Check:** suite exit 0; container exit 0; every mutant red.
**Commit:** none

**Deferred (Part 6):** none.

---

# Part 7 — The restore offer (§6 step 7)

Design:     §4.8, §3.6 (`--from` lookup order, `--list` marks), §4.4/§4.6 (the decline guard), §4.5 (the decline line)
Repository: the `persist-7` worktree of this checkout (`.claude/worktrees/persist-7`)
Branch:     worktree-persist-7
Base:       origin/main when the part starts (Parts 1–6 merged)
Oracle:     automated (`tests/test-shape-offer.sh`) + instrumented (the marker probe) + human-eye (§8.2 item 8)
Unattended: yes

**After this part merges, a user can:** after a crash with `persist` off,
type `roost` and be asked — `r` restore, `p` preview, `n` start fresh and do
not ask again, `l` restore at login from now on — instead of finding an empty
session.

### Task 7.1 — Probe: agent markers per harness

**Files:** `docs/airig/probes/persist-7-markers.md` (new)
**Depends on:** nothing

**Do:** For codex, Copilot, pi and opencode (opencode 2: not runnable beside
the user's service — record not measured), with each smoke test's rig: from
the harness's tool command, with a pty where offered, run `env | sort` and
`[ -t 0 ]; [ -t 1 ]`; the same from a shell nested inside that tool shell; and
`env | sort` in a plain login shell and in a new terminal outside the harness.
Confirm `CODEX_THREAD_ID` on this codex version. Names only, never values.

**If the probe says:** a variable set in the tool shell (and the nested
shell) and absent from both plain shells → add it to the marker list in Task
7.3 and the table on the page. None found → that harness stays held off by
checks 2b and 2d only (allowed). A candidate also set in a plain terminal →
not added.

**Check:** `test -s docs/airig/probes/persist-7-markers.md`, no values printed.
**Commit:** `probe: what each harness's tool shell sets, for the offer's markers (#191)`

### Task 7.2 — `--from` finds a pinned or declined save; the automatic decline guard

**Files:** `scripts/lib/roost-restore.sh`, `scripts/lib/roost-persist.sh`, `bin/roost` (`ensure_session`), `tests/test-shape-offer.sh` (new)
**Depends on:** nothing

**Do:**
1. Red first: `--from STAMP-GEN` looks at `shape`, `history/`, `offer/save`,
   then `declined`; `--list` marks `declined`, listing it last when the ring
   has dropped it. **§8.1 test 12 (h2):** a `declined` save made the one §3.6
   picks, `persist` marker planted directly, no `login/` marker →
   `restore --at-login <inner>` places nothing, `login.log` names the decline;
   the same state, `roost spawn x sh` → the ordinary fresh `spawn x sh` shape
   (compared with a control run on a third server), no `work`, no planted key,
   no `@roost-was`, `login.log` names the decline.
2. Implement.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-offer.sh` → all PASS.
**Commit:** `restore --from finds a declined save; no automatic path places one (#191)`

### Task 7.3 — When the offer is asked, its lock, and the pin

**Files:** `scripts/lib/roost-offer.sh` (new), `bin/roost` (`attach_session`, `roost new`, leading `--no-offer`), `tests/test-shape-offer.sh`
**Depends on:** 7.1, 7.2

**Do:**
1. Red first (§8.1 test 12, `roost` in a pane of a second throwaway server as
   `env -u …` the full list of §8.1 test 12, so stdin/stdout are a pty):
   **(a)** the summary names `2 sessions`, `4 panes`, `1 of 2 agents would
   resume` and an age from `ROOST_TEST_NOW`; no inner server while it waits;
   `offer/` names the pid; `offer/save` has the planted save's inode and
   `offer/stamp` its `STAMP-GEN`; a second pane's `restore --dry-run --from
   STAMP-GEN` finds it; `roost new x` asks too. **(b)** `roost < /dev/null`
   and `roost | cat` → no summary; `CLAUDECODE=1`, `CODEX_THREAD_ID=x`,
   `ROOST_NO_OFFER=1`, `--no-offer` → within 5 s the inner server with one
   session, no summary, no `declined`, no `offer/`. **(c)** `declined` linked
   to the planted save → no summary; a new save of the same fleet → asked.
   **(d)** `persist` marker, no `login/` marker → no prompt, the self-restore
   places. **(e)** closed on purpose, one unkeyed shell, `ROOST_SHAPE_DIR=`,
   `roost spawn x sh`, another host (with the `not offered here` line) → no
   prompt. **(j), the lock half:** two panes in one second → one summary, the
   other `waiting for the restore offer in another terminal`; `kill -9` the
   first → the second takes `offer/` over and asks. (The `n` half of (j)
   needs Task 7.4's keys and is there.)
2. Implement checks 1–7 in order, `offer/` under the owner rule, the pin with
   one re-read and one retry (F N2), the marker list (Task 7.1's additions),
   the `trap` release.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-offer.sh` → all PASS.
**Commit:** `the restore offer: asked only of a person, after a crash, about one pinned save (#191)`

### Task 7.4 — The prompt: `p`, `n`, Enter, no answer, Ctrl-C

**Files:** `scripts/lib/roost-offer.sh`, `tests/test-shape-offer.sh`
**Depends on:** 7.3

**Do:**
1. Red first: **(b) no answer** — `ROOST_TEST_OFFER_TIMEOUT=2`, no key → the
   no-answer line, one fresh `main`, no `declined`, `offer/` gone; re-plant →
   asked again. **(f)** `p` → the exact text of a separate `restore --dry-run
   --from STAMP-GEN` run, `directory gone` on that pane, then summary and keys;
   no inner server; with `ROOST_SHUTDOWN_AT=` empty no `restoring the newest
   save` line; **the bound ends at the first key** — timeout 2, `p`, 5 s
   silence → no no-answer line, then `n` declines. **(h)** `n` → `declined`
   is a hard link to the pin; the screen names `roost restore --from
   STAMP-GEN` and the rename hint; one fresh `main`; `ROOST_SHAPE_KEEP=2` and
   five saves → `--list` lists it last as `declined`; the hint's two commands
   as printed restore `main` and `work`, the fresh one is `main-fresh`. **(i)**
   Enter → fresh `main`, `not declined`, no `declined`, asked again after a
   re-plant; Ctrl-C → exit 130, no server, no `declined`, asked again.
   **(j), the `n` half:** two panes in one second; `n` in the one that
   asks → the other then attaches to the running server with no prompt, and
   `capture-pane` of it never shows a summary line.
2. Implement the prompt (`read -rsn1 -t 60` first, then no timeout), each
   line printed before the attach.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-offer.sh` → all PASS.
**Commit:** `the restore offer's keys: preview, decline, start fresh, time out (#191)`

### Task 7.5 — `r` and `l`

**Files:** `scripts/lib/roost-offer.sh`, `tests/test-shape-offer.sh`
**Depends on:** 7.4

**Do:**
1. Red first: **(g)** own fixture, `r` under `ROOST_TEST_PLACE_HOLD`: after
   `l` the keys line reads `on`; while held `restoring/` exists and neither the
   unit nor `persist` does; released → both exist, `restoring/` gone, both
   sessions placed, the two agents launched only after the attach, 2 s apart,
   once each; the failing stub → `persist on failed` on screen, still
   attached; the shared fixture's `r` writes one pending file only; **which
   session** — `work` + `ops` with `active 1` on `ops` → attached to `ops`, the
   line names it, no `main`; **`l` then silence** → still waiting, `on`, no
   no-answer line, no server, no service. **(h3)** no write-only seam, the
   recording stubs that start `--at-login` on load, a planted live `lock/`:
   `l` then `n` → while the owner lives no load call, no unit, `shape` still
   the planted save; kill it → the load is logged, `login.log` shows the job
   skipped every session, no pending file, one fresh `main`; `l` then Enter →
   the same, no `declined`; Linux argv has no `--now`. **(k)** a script starts
   the server mid-prompt; wait (≤ 10 s) until `shape` names the live boot; `r`
   → saved `main` skipped (exit 12), `work` restored from the pin, attached.
   **(k2)** `closed/<boot>/close.3`, `ROOST_SHAPE_KEEP=3`, six saves and an
   `--at-login` cleanup while waiting; `p` → pin unchanged, `main` skipped,
   `work` without `%3`, equal to a second pane's same-moment dry run; `n` →
   `declined` has the pin's inode, `closed/<boot>/` kept, `restore --from`
   restores `work` without `%3`. **(k3)** `r` on a pin with a closed pane →
   `work` has one pane, no `@roost-was %3`, `%2`'s pending file, after the
   attach `%2` and `%1` launched once, 2 s apart.
2. Implement `r` (§4.3 from the pin via the `--from STAMP-GEN` lookup, up to
   placement, report to the terminal, no `login/` marker, attach to `main` or
   the pin's active session) and `l` (`persist on` after the choice's server
   is built and `declined` written, before the attach; never fatal); release
   `offer/` last, just before the `exec`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-offer.sh` → all PASS; `bash tests/test-persist.sh` exits 0.
**Commit:** `the restore offer: r restores the pinned fleet, l turns on the login restore (#191)`

### Task 7.6 — Doctor's decline, help, docs and changelog

**Files:** `scripts/roost-doctor`, `tests/test-doctor.sh`, `bin/roost` (help: the offer and `--no-offer` under `roost`), `site/content/docs/getting-started.md`, `site/content/docs/persistent-sessions.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 7.5

**Do:** Red first: doctor's persist line ends `; declined at the restore
offer: STAMP-GEN (roost restore --from STAMP-GEN)` when `declined` exists.
Then: getting-started's "If roost was not shut down cleanly" paragraph under
"First run"; the page's persist section per §4.8's **Docs** (which one runs
when; a script without a terminal never sees it; markers, `ROOST_NO_OFFER`,
`--no-offer`; any other caller times out in 60 s and declines nothing — never
"an agent never sees it"; Enter vs `n`; `declined`, newest only; `--from`; the
rename hint). Changelog.

**Check:** `bash tests/test-doctor.sh` exits 0; `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: the restore offer; doctor names a decline (#191)`

### Task 7.7 — Verify

**Files:** none
**Depends on:** 7.6

**Do:** `bash -n`; mutants: ask without testing stdin or stdout; start the
server before the prompt; skip the `declined` check, or match by `boot` alone;
offer with `persist` set; offer before §3.6 step 4; a preview in its own
format; `r` that launches agents itself; `persist on` before placement; a fatal
`persist on` failure; Enter as `r`; record a decline on Ctrl-C; `restoring/`
instead of `offer/`; `--from` that reads only `history/`, or skips `shape`, or
misses `offer/save`; `r`/`p`/`n` reading `shape` instead of the pin; restore
the pin as `--from FILE`; ignore `ROOST_NO_OFFER`/`--no-offer`/
`CODEX_THREAD_ID`; no timeout, or one that declines, or one that restarts at
every key; release `offer/` before the server runs; attach to a fresh `main`
after `r`; drop the automatic decline guard; `persist on`'s save as `--auto`;
`--now` on Linux. Suite, contrast, container.

**Check:** suite exit 0; container exit 0; every mutant red.
**Commit:** none

**Deferred (Part 7):** §8.2 item 8 — on a throwaway `-L` server with its
state redirected, `kill -9` the server, open a new terminal, `ROOST_SOCKET=NAME
roost`; read the summary cold; `p`, then `r`, agents 2 s apart after the
attach; again with `n`, and the printed line brings the fleet back.

---

## Deferred checks — all parts, one pass each

| part | item |
|---|---|
| 1 | §8.2 item 7, reading the file |
| 3 | §8.2 item 6, the codex note with two real codex panes |
| 5 | §8.2 items 1–5, the reboots, the shutdown chain, credentials, upgrade |
| 7 | §8.2 item 8, the offer after a real crash |

A deferred check that fails is a new task in a new part, not a rewind.

## Coverage: every §8.1 item → the one task that lands it

| §8.1 item | task |
|---|---|
| 1 base (placement, first cwd, layout ids stripped, zoom, 200x50) | 1.13 |
| 1 body compare (save twice, one file) | 1.9 |
| 1 wide layout | 1.13 |
| 1 wired | 1.13 |
| 1 started at all, and a user's own `default-command` | 5.6 |
| 2 base (existing skipped; stopped server's bootstrap used) | 1.12 |
| 2 (a) (b) (c) (d) (e) (f) (g) (h) | 1.12 |
| 2 (i) unkeyed half | 1.13 |
| 2 (i) keyed half | 3.3 |
| 2 (j) | 1.13 |
| 3a a gone `cwd` → shell at `$HOME`, stderr line | 1.14 |
| 3b exit 13 when it had a key | 3.5 |
| 4 resume, pacing, `--no-resume`, `--recent` launch count, `--only` | 3.5 |
| 4 `--recent` holds at the next attach (worker-only) | 3.5 |
| 4 directory rule (all cases) | 3.5 |
| 4 exited and nested — the saver classifies | 1.9 |
| 4 exited and nested — restore launches neither | 3.5 |
| 4 siblings, duplicate, stale, store miss, mid-turn line | 3.5 |
| 5 parse refusals, unknown block, whitespace | 1.10 |
| 5 deleted block, renamed session, linked window | 1.13 |
| 5 a session group (R7): one block per later member, round trip, `--only`, a bad `group` line | 1.9 (writer), 1.10 (checker), 1.12 (restore), 1.14 (output) |
| 5 "create nothing" on a refusal | 1.14 |
| 6 live pane, own key, exited, nested, other (revive), release only one's own | 2.6 |
| 6 `other` — saved with `stale_reason other` | 1.9 |
| 6 gone pane, no transcript in the record, two revives (refusal and stale takeover), `--new-window` own key | 2.7 |
| 6 two revives — the kill releases the claim at once | 4.10 |
| 6 against a waiting pane, overlapping the worker, taken pane in use / idle / `--force`, interrupted revive, no origin line, inherited origin, `--new-window` from a pending file | 3.8 |
| 7 addressing (all) | 3.9 |
| 8 per-verb new `shape`, 50 `state working` none, triggers | 4.7 |
| 8 `window-layout-changed` none; what no hook covers; hooks load | 4.6 |
| 8 owner rule (live `restoring/`, dead pid, reused pid), owner held past 10 s, ring | 4.5 |
| 8 coalescing on cue | 4.6 |
| 8 ten `spawn`s in parallel | 4.7 |
| 8 (a) (c) (d) (f) reading rule | 4.9b |
| 8 (b) planted race, same second, (g) in flight | 4.8 |
| 8 the belt (kill file + death note kept; `close.` file + death note removed) | 4.9a |
| 8 (e) the last session (per R1) | 5.6 |
| 8 (b2) overlap rewritten, death in the gap, (h) boot change, (i) kills by every route — the `closed/` files | 4.6 |
| 8 (b2) — the restore half (C back and not B, inside the window) | 4.9b |
| 8 (i) — the restore half (the whole fleet back after `kill -TERM`) | 4.9a |
| 8 step 4 for `--from STAMP-GEN` not `--from FILE`; emptied window/session | 4.9a |
| 9 persist (all but the next row) | 5.5 |
| 9 `on` with the server stopped | 5.6 |
| 10a `save` with empty/relative/read-only dir | 1.9 |
| 10b `save --auto` degrade; reader loop | 4.5 |
| 10b every hook exits 0 within 5 s with saving off | 4.6 |
| 11 `--at-login` placement, structural save in the gap, second reboot | 5.6 |
| 11 a real attach; hook deleted; two clients; worker held; (d) must still launch | 5.7 |
| 11 interrupted loop; interrupted after the claim; duplicate across workers | 3.6 |
| 11 a pane taken (a) (b) (c) (e) | 3.5 |
| 11 (f) `send` refuses a waiting pane | 3.4 |
| 11 released (exit1 → died), different id → replaced | 4.10 (died), 3.7 (replaced) |
| 11 a key after a failure is marked; duplicate shows its reason | 3.6 |
| 11 retry recovers (A) (C) (D) | 3.6 |
| 11 retry recovers (B) | 4.10 |
| 11 a crashed placeholder | 4.10 |
| 11 a resume that exits 0; a dead pane retried while broken; a placeholder that crashes while failed; the first line decides | 4.10 |
| 11 `close` on a waiting pane | 3.4 |
| 11 taken, then an agent started in it | 3.7 |
| 11 dialog keys survive — structural save half | 4.10 |
| 11 dialog keys survive — `--at-login` half | 5.6 |
| 11 `kill-pane` before attach; taken then `exit`ed | 4.10 |
| 11 a `.failed` file listed by `--list` | 3.11 |
| 11 a `.failed` file retried only with `--retry` | 3.6 |
| 11 `ensure_session` with persist on, with and without the marker | 5.8 |
| 11 other host | 1.14 |
| 11 two sockets | 3.9 |
| 12 (a) (b) markers and switches (c) (d) (e), (j) the lock half | 7.3 |
| 12 (b) no answer, (f) (h) (i), Ctrl-C, (j) the `n` half | 7.4 |
| 12 (g) (h3) (k) (k2) (k3) | 7.5 |
| 12 (h2) | 7.2 |
| guard: `status --json` byte-identical but `was` | 3.9 |
| guard: record tests pass with shapes on | 4.10 |
| guard: canary empty | every test file (Global constraints) |
| guard: 0700 directory | 1.8 |
| guard: 0600 files | 1.9 |
| mutations | each part's verify task (1.17, 2.11, 3.14, 4.13, 5.12, 6.6, 7.7) |
| live: `revive-smoke.sh` | 2.8 |
| live: codex, copilot, pi resume cases | 2.9 |

## Coverage: plan additions beyond §8.1 → the task that lands each

Field lessons from other tools, written as test cases inside the spec's rules,
and the coordinator's rulings R2–R8. Each is red before its code.

| addition | task |
|---|---|
| format probes: zoom string, session group, control bytes, exact targets, nested Claude | 1.1, 1.2, 1.3, 1.4, 1.5 |
| stop point for the grouped-session decision | after 1.2 |
| the harness stubs read `claude` / `codex` as their foreground command (asserted in setup) | 1.8 |
| no test saves a shape by accident: `tests/lib.sh` override, inherited-canary run, live-rig audit | 1.8 (re-run in 4.7) |
| `renumber-windows` note in a server of its own | 1.14 |
| the claim's two-stage rule (an existing pane refuses whatever the claimer's liveness) | 2.5 |
| the send / answer policy, one case per §4.7 row, `--force` | 3.4 |
| `closed/` kept while any save, `declined` or pin names its boot; swept after | 5.6 |
| `save` against a stopped server publishes nothing | 1.9 |
| no control byte written (control bytes by Task 1.3's rules) | 1.9 |
| the writer's files pass the reader | 1.10 |
| zero-byte and cut-off shapes are named refusals | 1.10 |
| the kept shape fixture, read on every run, never edited | 1.10 |
| dotted and numeric session names skipped or placed exactly | 1.12 |
| the restored server survives a resize storm from a real client | 1.12 |
| unzoom after restore and compare the layout; `pane-base-index 1` | 1.13 |
| odd names and directories round-trip (space, `$`, quotes, `#`, trailing space, UTF-8) | 1.13 |
| the K-pane fallback names every unplaced block with its key | 1.13 |
| R4: a headless Claude child does not re-identify the pane | 1.15 |
| R6: `$` read back as `\$` on tmux 3.4 — the read test and the round trip | 1.9, 1.10 |
| R7: a session group saved as one full member and later-member blocks; restored with `new-session -t` | 1.9, 1.10, 1.12, 1.14 |
| R8.1: a newline cuts a listing line — re-read by id, the control-byte rule | 1.9 |
| R8.2: ESC/SOH read as `\NNN` on tmux 3.4 — the read test, same result on every build | 1.9 |
| R8.3: backslash and `$` in session and window names do not drift over two cycles | 1.12, 1.13 |
| launch-flag, harness-home and live-registry reads (recorded only) | 2.1 |
| the worktree-relocated transcript (probe, and its fixture) | 2.2, 3.5 |
| a listing that fails mid-round publishes nothing | 4.5 |
| R3: `save.err` written on a failed round (injected publish failure, writable directory), removed on the next publish | 4.5 |
| R3: a read-only shape directory fails silently, no `save.err` required; `doctor`'s no-save line shows it | 4.5, 4.11 |
| the shape directory removed under a held saver is not recreated by it | 4.5 |
| the only pane of the only session dies under `pane-died[98]`: the server lives | 4.10 |
| no process per pane in a save | 4.11 |
| R3: `doctor` quotes `save.err`; "no save since this server started" whatever `persist` says | 4.11 |
| R5 probe: a terminal quit and the server it started | 5.3 |
| R2: no second server under a live one's name; `kill -USR1` line | 5.4 (and its `--at-login` case in 5.6) |
| `service.env` rewritten only by `persist on` — `status` leg / `--at-login` leg / `doctor` leg | 5.5 / 5.6 / 5.9 |
| `--at-login` three times is idempotent; nothing to place starts no server | 5.6 |
| a blocking shell rc does not stop a resume | 5.7 |
| R5 build, only if confirmed | 5.10 |
| quit the terminal after the reboot restore (deferred, §8.2 item 1) | Part 5's deferred list |

Split items: where one §8.1 item spans two parts (test 1, 2 (i), 3, 4, 6, 10,
11), it is cut into the halves named above, each half in exactly one task. The
split follows §6's step for the mechanism each half asserts.
