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
- **B:** `close` gains a mode that takes a session's last pane. That changes a
  shipped refusal and its documented reason.

Task 4.8 and Task 5.4's test 8 (e) case are written for **A**. If the
coordinator rules B, Task 4.8's step 2 becomes "`close` takes a session's
last pane" (with its own red case) and test 8 (e) uses `roost close`. Until
ruled, Part 4 runs every task but 4.8, and Part 5 runs every case but 8 (e).

## Probes

Each part's first tasks are its probes from §6. A probe task:

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
- **The shared test library** `tests/lib-shape.sh` (new in Task 1.3) holds the
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
  No real `launchctl`/`systemctl` call from any test or task except the Part 5
  VM probe, on the VM.
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
| `ROOST_TEST_NOW=EPOCH` | the clock for every stamp `save` and `close` write, and the offer's "ago" | 1.4 (`save`), 4.7 (`close`), 7.4 |
| `ROOST_TEST_RESTORE_HOLD=FILE` | restore waits right after `new-session`, holding `restoring/`, until FILE exists | 1.7 |
| `ROOST_TEST_PLACE_HOLD=FILE` | restore waits after a window's panes exist and its layout is applied, before the per-pane step | 1.8 |
| `ROOST_TEST_PLACE_HOLD_AFTER_USED=FILE` | restore waits after winning `F → F.used` (T2), before that pane's respawn | 1.8 |
| `ROOST_TEST_REVIVE_HOLD=FILE` | `revive` waits after its rename to `%N.launching`, its `origin` line and its claim, before step 7 | 3.8 |
| `ROOST_TEST_REVIVE_HOLD_BEFORE_ORIGIN=FILE` | `revive` waits right after that rename, before its `origin` line | 3.8 |
| `ROOST_TEST_LOOP_HOLD=FILE` | a hand restore waits after placement, before its resume loop (this plan's seam, not the spec's: it lets Task 3.3 read the placed state before Task 3.5's loop exists) | 3.3 |
| `ROOST_TEST_RESUME_HOLD=FILE` | the engine waits after its rename to `.launching` and its claim, before the respawn | 3.5 |
| `ROOST_TEST_RESUME_HOLD_AFTER_FAILED=FILE` | the engine waits right after T7 | 3.5 |
| `ROOST_TEST_SAVE_HOLD=FILE` | the saver holds `lock/` until FILE exists | 4.5 |
| `ROOST_TEST_SAVE_HOLD_AFTER_DRAIN=FILE` | the saver waits after `mv want want.<pid>` | 4.5 |
| `ROOST_TEST_SAVE_HOLD_AFTER_LIST=FILE` | the saver waits after listing, before publishing | 4.5 |
| `ROOST_SHUTDOWN_AT=EPOCH` | a stub shutdown record; set and empty = no readable record | 4.9 |
| `ROOST_PERSIST_WRITE_ONLY=1` | `persist on` writes the unit and does not load it | 5.3 |
| `ROOST_TEST_OFFER_TIMEOUT=SECONDS` | the offer's 60 s no-answer bound | 7.4 |

---

# Part 1 — `roost save`, the shape, and placement (§6 step 1, #51)

Design:     §3.1–§3.3, §3.4a, §3.6 (`--from`, `--list` only), §4.2, §4.3 (placement only), §4.7 (placing rows and T1–T4, T2b), §2.7, §2.10
Repository: the `persist-1` worktree of this checkout (`.claude/worktrees/persist-1`)
Branch:     worktree-persist-1
Base:       origin/main when the part starts (record the sha in the report)
Oracle:     automated (`tests/test-shape.sh`, `tests/test-shape-place.sh`) + instrumented (two probes)
Unattended: yes

In this part `restore` **places only**: no agent is launched, a keyed pane
becomes a shell in its directory, and the shape's keys are kept for Part 3.
There is no `@roost-was`, no pending record, no auto save (Part 4), and the
history grows without the ring (Part 4 adds `ROOST_SHAPE_KEEP`). `restore`
with no `--from` reads `shape`.

**After this part merges, a user can:** run `roost save` and read their fleet
as a plain file; copy it, edit it, and `roost restore --from COPY` it on any
server, getting the same sessions, windows, panes, names, directories and
layouts back as shells; preview with `--dry-run` and list saves with `--list`.

### Task 1.1 — Probe: what `#{pane_current_command}` reads for pi, copilot and opencode

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
  `pi`, `copilot`, `node`): add it to `roost_shape_agree`'s table in Task 1.4
  as that harness's command, and say in the file whether it is distinctive
  (`node` is not: two harnesses could read it — then the nested half stays
  "presence alone" for both, as the spec allows).
- a shell name (`sh`, `bash`, `zsh`, `fish`, `dash`) while the harness runs:
  **stop** — §3.2's rule would mark every live pane of that harness `exited`.
- not measured (it would not run): presence alone for that harness, as §3.2
  says until measured; say so in the file and in Task 1.10's known-gaps entry.

**Check:** `test -s docs/airig/probes/persist-1-command-names.md && grep -c 'not measured\|measured' docs/airig/probes/persist-1-command-names.md` prints ≥ 3; `grep -rn '/Users/[a-z]' docs/airig/probes/` prints nothing.
**Commit:** `probe: what pane_current_command reads for pi, copilot and opencode (#191)`

### Task 1.2 — Probe: the placeholder's 5-second wake and `remain-on-exit failed`

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
- `dd` returns about every 5 s with no byte, and at once on a key: Task 1.6
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

### Task 1.3 — Test library, and the one switch for saving

**Files:** `tests/lib-shape.sh` (new), `scripts/lib/roost-shape.sh` (new), `tests/test-shape.sh` (new), `tests/run.sh` (only a `shard_weight` line if needed)
**Depends on:** nothing

**Do:**
1. `tests/lib-shape.sh`: sourced after `tests/lib.sh`. `shape_test_setup`:
   `TMUX_TMPDIR=$(mktemp -d /tmp/amx.XXXX)` exported, then
   `roost_test_tmux_named_guard`; every home in Global constraints at a temp
   dir; the canary; `ROOST_SHAPE_DIR=$TMP/shapes`; a redirected `HOME` whose
   `.bash_profile` and `.bashrc` each append `"$TMUX_PANE $$"` to
   `$HOME/shells.log`; `ROOST_SOCKET=shp$$` (a `-L` name). `shape_test_teardown`
   kills only that named server. Helpers `shells_for %N` (lines in
   `shells.log` for a pane) and `canary_check`. The stub harnesses (§8.1's
   opening), in a temp directory put first on `PATH`: `claude` appends `<epoch>
   <cwd> <argv>` to `$STUB_LOG`, runs `roost identify --session <the --resume
   id> --cwd "$PWD" --harness claude` only when `STUB_IDENTIFY=1` (or with
   `STUB_IDENTIFY_AS=<id>` for a different id), then `exec sleep 600`;
   `claude-exit1` exits 1 at once; `claude-exit0` exits 0 at once without
   identifying (each installed as `claude` by the test that needs it). A helper
   `stub_store_add ID CWD` writes `$CLAUDE_CONFIG_DIR/projects/<folder by the
   measured rule: / and . → ->/<ID>.jsonl` holding a `"cwd":"<CWD>"` line.
2. Red first, `tests/test-shape.sh`, library level: `roost_shape_saving` with
   `ROOST_SHAPE_DIR=` (empty) and `ROOST_SHAPE_DIR=rel/dir` prints nothing;
   unset → the default path under the redirected `XDG_STATE_HOME`; absolute →
   that path. Key: a `-L NAME` server is keyed `NAME`; a `-S PATH` server
   `path-<cksum of PATH>`; `/a/b-c` and `/a-b/c` give two keys.
   `roost_shape_dir` makes the directory 0700 (the §8.1 guard; the file half is
   Task 1.4's).
3. `scripts/lib/roost-shape.sh`: `roost_shape_saving` (prints the directory or
   nothing: unset → `${XDG_STATE_HOME:-$HOME/.local/state}/roost/shapes`;
   empty or relative → nothing; reads nothing else, §3.4a), `roost_shape_key
   FLAG SOCKET`, `roost_shape_dir` (saving dir + key, made 0700, `umask 077`
   for the files). Comment the §3.4a rule: the one function every writer asks.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape.sh` → all PASS, exit 0, canary empty.
**Commit:** `shape: the one switch for saving, the directory key, the test library (#51)`

### Task 1.4 — `roost save`: the writer

**Files:** `scripts/lib/roost-shape.sh`, `bin/roost` (the `save` arm; `@roost-launch` in `spawn`, `split`, `view`), `tests/test-shape.sh`
**Depends on:** 1.1, 1.3

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
   `roost save` twice with no change writes `shape` once (§8.1 test 1's body
   compare): one `history/` file, `gen` unchanged. `roost save --to FILE`
   writes there and leaves `shape` alone. **§8.1 test 10, the `save` half
   (10a):** `ROOST_SHAPE_DIR=` and `ROOST_SHAPE_DIR=rel/dir` → `roost save`
   writes nothing, exits 0, one stderr line saying saving is off; a read-only
   shape directory → exit 1 naming it. `shape` and every `history/` file are
   0600.
2. `bin/roost` `spawn`, `split`, `view`: set `@roost-launch` on the new pane
   to the command as handed (before `roost-pane-shell` wraps it), in the same
   `set-option` place as `@roost-name`. Redaction happens at save, not here.
3. `roost_shape_agree HARNESS COMMAND` → `ok`, `exited`, `nested`, `other`:
   shell names → `exited`; another harness's command → `nested`; the
   harness's own (Claude's version string, `codex`, and Task 1.1's answers) →
   `ok`; pi/copilot/opencode with no measured name → `ok` on presence (§3.2).
4. The writer: one `list-sessions`, one `list-windows -a`, one `list-panes -a`
   with space-separated `#{q:}` fields (no tab); the consistency check of §3.5
   step 2 (every pane's window and session in the other listings, else list
   again, at most 3 times); `printf` the blocks; redact `launch`; refuse to
   write a value holding a control character (skip that key, one stderr line).
5. Publish (Part 1 form): `mktemp` in the shape dir; body compare against
   `shape` (everything after the header's blank line); same → remove the temp,
   exit 0; else hard-link `shape` to `history/<stamp>-<gen>`, `mv` the temp
   over `shape`, write `gen` + 1. `--trigger NAME` sets the header. The
   `save` arm: `--to FILE`, `--trigger NAME`, `--auto` (accepted, silent,
   same path until Part 4); exit 1 when nothing could be written.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape.sh` → all PASS, exit 0; `bash tests/test-panes.sh` and `bash tests/test-view.sh` still exit 0.
**Commit:** `roost save: write the server's shape, with stale keys and the launch hint (#51)`

### Task 1.5 — The checker and parser, and every refusal

**Files:** `scripts/lib/roost-shape.sh`, `tests/test-shape.sh`
**Depends on:** 1.4

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
2. `roost_shape_check FILE`: one pass, `IFS= read -r line`, key `${line%%
   *}`, value `${line#* }`, blank line ends a block; the rules of §3.2 in
   that order. `roost_shape_parse FILE DIR`: after a passing check, one file
   per block in DIR named `NNNN.<kind>` holding the block's lines verbatim,
   and `roost_shape_get BLOCKFILE KEY` (prints the value, returns 1 when
   absent — a reader tests presence). No `eval`, no `source` of shape text.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape.sh` → all PASS, exit 0.
**Commit:** `shape: check the whole file before anything, and refuse by line (#51)`

### Task 1.6 — `scripts/roost-placeholder`, placing mode

**Files:** `scripts/roost-placeholder` (new, executable), `tests/test-shape-place.sh` (new)
**Depends on:** 1.2, 1.3

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
   min 0 time 50; dd bs=1 count=1` (Task 1.2's form); on a wake with no byte
   re-read the name and reprint on change; on a byte: drain (`stty -icanon min
   0 time 0`, one more `dd`), restore the terminal, `mv FILE FILE.taken`. Won:
   `tmux set -pu remain-on-exit`, then `exec` `#{default-shell} -c
   "#{default-command}"` read now with `tmux display -p`, or
   `#{default-shell} -l` when empty. Lost: reprint and keep waiting; **never**
   start a shell after a lost rename (§4.7 step 2). Comment each rule with its
   § and the measured reason (§2.10).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS; `sh -n scripts/roost-placeholder` exits 0.
**Commit:** `roost-placeholder: a pane roost can prove untouched, placing mode (#51)`

### Task 1.7 — Restore's server, sessions and the replaceable bootstrap

**Files:** `scripts/lib/roost-restore.sh` (new), `scripts/lib/roost-shape.sh` (owner rule), `bin/roost` (the `restore` arm), `tests/test-shape-place.sh`
**Depends on:** 1.5, 1.6

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
   into a shell, its session then skipped, exit 12).
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

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS, exit 0.
**Commit:** `roost restore: sessions, the bootstrap that a key or a live session keeps (#51)`

### Task 1.8 — Windows, splits, layout, and the per-pane step

**Files:** `scripts/lib/roost-restore.sh`, `tests/test-shape-place.sh`
**Depends on:** 1.7

**Do:**
1. Red first (§8.1 test 1 base, wide, wired; test 2 (i) unkeyed half, (j)):
   save 2 sessions / 3 windows / 6 panes with names, dirs and a split layout,
   one window of six stacked panes at `-x 200 -y 50`, index 5 under
   `base-index 1`, one zoomed; kill the server by its socket; restore;
   `status --json` before/after equal on `session`, `window_name`,
   `window_index`, `pane_index`, `name`, `cwd` (the first pane's too); layout
   strings equal with checksum and pane ids stripped; zoomed is zoomed; first
   window 200x50. **Wide:** six side-by-side panes at `-x 200 -y 10` → six panes,
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
   saved under two sessions comes back as two windows.
2. Per window: `restoring/place.<n>` then `new-window -d -t SESSION:INDEX -n
   NAME -c CWD <placeholder> place.<n> --placing`; split until the saved count,
   each time on the pane whose larger side is largest, `-h` when width ≥
   height else `-v`, each pane created as a placing placeholder after its own
   `place.<n>`; a refused split → keep K panes, default layout, a stderr line
   naming the blocks not placed (their keys listed), exit 13. `select-layout`
   the saved string (failure: one stderr line); `resize-pane -Z` for `zoomed
   1`; the per-pane step in index order: `mv place.<n> place.<n>.used`; lost →
   leave it; won but its start command is not the placing line → `mv
   .used .taken`, leave it (T2); won → `respawn-pane -k -c CWD
   "<default-command value>"` as one string (read once after `wiring apply`;
   empty → `#{default-shell}` and `-l` as argv). Names re-stamped; saved
   active window and pane selected. Keyed panes are shells in this part.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` → all PASS, exit 0.
**Commit:** `roost restore: windows by the largest side, the saved layout, the per-pane rename (#51)`

### Task 1.9 — `--dry-run`, `--list`, `--from`, `--only`, directories

**Files:** `scripts/lib/roost-restore.sh`, `bin/roost` (the `restore` arm), `tests/test-shape-place.sh`
**Depends on:** 1.8

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
   was removed is a shell at `$HOME` with one stderr line.
2. Implement; `--from` reads `host` and the caller's server, never the file's
   `socket`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-place.sh` and `bash tests/test-shape.sh` → all PASS, exit 0.
**Commit:** `roost restore: --dry-run tree, --list, --from, --only, a gone directory (#51)`

### Task 1.10 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md` (new; sidebar per `site/AGENTS.md`), `bin/roost` (help header lines for `save` and `restore`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 1.1–1.9

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
3. known-gaps: Task 1.1's result and the presence-alone risk (§10); history
   has no ring yet.
4. Changelog (Added: `roost save`, `roost restore` placement).

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; `git diff --stat` shows `site/content/docs/changelog.md` changed with `CHANGELOG.md`.
**Commit:** `docs: roost save and roost restore (placement) (#51)`

### Task 1.11 — Verify

**Files:** none (report only)
**Depends on:** 1.10

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
   instead of `save`'s).
3. Suite, contrast, container (Global constraints).

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
shown on screen. Once; record the guard lines.

**If the probe says:**
- both kept: nothing to build; the file says so; `launch` stays a hint.
- either dropped: nothing to build in this plan (§10: an allowlist per adapter
  is a follow-up); the file says which, and Task 2.10 adds a known-gaps entry
  and a site line ("a resumed Claude starts with its default model / mode").
- the run could not complete (the rig failed): **stop**.

**Check:** `test -s docs/airig/probes/persist-2-resume-flags.md`, with the guard lines saying the real settings were unchanged.
**Commit:** `probe: what claude --resume keeps of the launch flags (#57)`

### Task 2.2 — Probe: does a re-filed transcript keep its first `cwd`?

**Files:** `docs/airig/probes/persist-2-refiled-cwd.md` (new)
**Depends on:** nothing

**Do:** Same rig. Start in trusted directory A, one prompt, `/exit`;
`claude --resume ID` from trusted directory B (it re-files, §2.1), one prompt,
`/exit`. Read the first `"cwd":"…"` of the file now under B's project folder
(`grep -m1 -o '"cwd":"[^"]*"' | head -n 1`) and whether A's file still exists.

**If the probe says:**
- the first `cwd` is still A: §5.1's rule resumes in A, as written.
- the first `cwd` is B: the rule resumes where the conversation was last filed,
  which §5.1 accepts; no code change; say so in known-gaps (Task 2.10).
- no `cwd` line at all in the re-filed file: **stop** (the rule would refuse
  every re-filed conversation).

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
   `claims/<boot>/<harness>-<id>/` with `pid`, `lstart`, `pane`; a second
   claim for another live pane with a live owner → refused, naming it; a claim
   naming a gone pane, or no pane and a dead owner → taken over; a claim
   naming the same pane → taken over (in-place); `roost_resume_release` removes
   only a claim whose `pid`/`lstart` are this run's.
2. Implement with `roost_shape_owner_*`.

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
   (the claim names a gone pane, so it is stale). `--new-window` of a live
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

**Check:** each of the three files → every line PASS (one run each; a harness not installed is reported SKIP, not PASS).
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
1. Red first: **§8.1 test 11 (f)** `roost send %N "hi"` to a waiting
   placeholder refuses as for a blocked target, the file still `%N`; the same
   for `.launching` (placeholder line), `.failed`; `--force` sends. **§8.1
   test 11, close on a waiting pane:** `roost close %N` on a waiting
   placeholder → pane gone, no `shells.log` line, file removed, exit 0.
   `close` on `.failed` and on a dead failed pane likewise uses `kill-pane`.
2. `roost_pending_for_pane BOOT %N` (prints the file and state); `send` and
   `answer` call it where they test `blocked`; `close` calls it first and, for
   the placeholder states, removes the file, releases any claim, and
   `kill-pane`s (T19, F N1).

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
   one line → first) with dotted paths; exited/nested not launched and named;
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
**Depends on:** 3.5

**Do:**
1. Red first (worker-only): **Retry recovers (A)** store miss repaired →
   `--retry` launches once more, `pane_dead` 0, file gone after identify;
   **(C)** the same pane taken and running `sleep 60` → `--retry` launches
   nothing; **(D)** `%N.failed pane changed` → nothing, sleep alive. **A key
   after a failure is marked:** `ROOST_TEST_RESUME_HOLD_AFTER_FAILED` → reason
   on screen within 6 s, same `pane_pid`, no `shells.log` line; one key →
   `.taken`, a shell; `sleep 60`; release → sleep alive. **A `.failed` file is
   listed by `--list` and retried only with `--retry`.** **Interrupted** (test
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
implement (read `@roost-was` in the same tmux read the script already makes).

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
   files.
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
pane. Suite, contrast, container.

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
  Task 4.9 reads it on Linux (the window: that minute and the one before).
- no wtmp, but `journalctl --list-boots` gives the previous boot's last entry
  time: Task 4.9 reads that.
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
**Depends on:** nothing

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
   Task 4.6 with the conf loaded.)
2. Turn Part 1's publisher into §3.5: steps 1–4, the three seams, `gen` and
   `history/<stamp>-<gen>`, the ring prune after each publish. `--auto` never
   prints and never fails loudly.

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
**Depends on:** 4.5

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

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-save.sh`; `bash tests/test-agent-state.sh`, `tests/test-reply-record.sh`, `tests/test-close.sh` exit 0.
**Commit:** `save on change: roost's own verbs save after they change the fleet (#51)`

### Task 4.8 — `roost close` records its intent (and ruling R1)

**Files:** `bin/roost` (`close`, and per R1-A `kill|down|stop`), `tests/test-shape-closed.sh`
**Depends on:** 4.6, 4.7, ruling R1

**Do:**
1. Red first: **(8b) the planted race** — A and B run the stub; `roost close
   A` with `ROOST_TEST_SAVE_HOLD` keeping `close`'s save until the
   `pane-exited` save for A is published; assert the newest `shape` is that
   save without A and `close`'s save wrote nothing; restore inside the window
   → A not back (`closed/<boot>/close.<A>`). **Same second** under
   `ROOST_TEST_NOW`. **(g) a save in flight** — `ROOST_TEST_SAVE_HOLD_AFTER_LIST`
   while A is listed; `roost close A`; release; B dies; restore → A not back.
   **The ends of a fleet** (R1-A; this plan's own case — §8.1 test 8 (e)
   itself runs through `--at-login` in Task 5.4): `roost kill NAME` of a
   session and `roost stop` each leave one `closed/<boot>/close.<N>` per pane
   they removed, written before the tmux command, and a plain `restore` then
   prints `nothing to restore: every saved pane was closed on purpose`, exit 0.
   **The belt:** a planted kill file plus a death note → the pane is restored; a
   `close.` file plus a death note → not. A failed close (the harness does not
   leave) removes its `close.<N>`.
2. `close`: write `closed/<boot>/close.<N>` before the exit command; remove it
   on exit 1 or 2 with the pane still there. R1-A: `kill NAME` and `stop` write
   one `close.<N>` per pane they will remove, before the tmux command.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-closed.sh` → all PASS; `bash tests/test-close.sh` exits 0.
**Commit:** `close records its intent, so a closed pane stays closed after a reboot (#51)`

### Task 4.9 — The reading rule

**Files:** `scripts/lib/roost-restore.sh`, `tests/test-shape-closed.sh`
**Depends on:** 4.6 (and 4.1's result when there is one)

**Do:**
1. Red first (§8.1 test 8 a, c, d, f): with `ROOST_SHUTDOWN_AT`, (a) a chain of
   `pane-exited` saves inside the window → the save before it is picked and
   `--list` names it; (c) `ROOST_SHUTDOWN_AT=` empty → the newest save and the
   stderr line, `closed/` still applied; (d) 60 death saves → still
   recoverable; (f) a stub `last` printing `shutdown time … Dec 31 23:59` and a
   stub boot second on 1 January → the window is in the year before. Step 4
   for `--from STAMP-GEN`, not for `--from FILE`. A window that lost panes to
   step 4 → default layout and one stderr line; an emptied window or session →
   not created.
2. Implement §3.6 rules 1–4 in epoch seconds; macOS `last reboot` +
   `sysctl kern.boottime`; Linux per Task 4.1's outcome. If Task 4.1 is
   blocked for want of a VM, Linux takes rule 3 (the spec's "until it lands")
   and the report says so; this task does not wait.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-closed.sh` → all PASS.
**Commit:** `restore picks the save before a shutdown's teardown, and drops what was closed (#51)`

### Task 4.10 — The saver applies the hook-driven arrows

**Files:** `scripts/lib/roost-shape.sh` (saver step 2), `scripts/lib/roost-pending.sh`, `tests/test-shape-resume.sh`
**Depends on:** 4.6, 1.2's result

**Do:**
1. Red first (§8.1 test 11, worker-only where it says attach): **Released** —
   `claude-exit1` → `%N.failed died`, claim gone, `--retry` reaches it; **retry
   (B)** — good stub first on `PATH`, `--retry` → one more launch, `pane_dead`
   0, same `%N`; **a crashed placeholder** (Task 1.2's form) → dead pane,
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
   T19; the overlay (all four file kinds) when writing a pane with no
   `@roost-session`.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-resume.sh` and `bash tests/test-reply-record.sh` → exit 0.
**Commit:** `the saver moves a died, exited or killed pane's resume to its row (#191)`

### Task 4.11 — Cost measurements and the doctor's saving lines

**Files:** `scripts/roost-doctor`, `tests/test-doctor.sh`, `docs/airig/probes/persist-4-cost.md` (new)
**Depends on:** 4.7

**Do:**
1. Measure (§3.4a cost), once each, ratio with the method: `roost save --auto`
   time at 47 panes; time and files written for ten spawns in one second; 50
   `roost state working` on a working pane write no shape (already a test;
   record its time).
2. Red first in `tests/test-doctor.sh`: `persist: saving on; login restore
   off (…)`; `ROOST_SHAPE_DIR=` → `persist: saving off (ROOST_SHAPE_DIR is
   empty); login restore off`; `warn` for a `lock/` or `restoring/` with one
   live owner over 60 s (planted, pid named); `warn` N panes run a harness with
   no recorded conversation and M carry a disagreeing identity.
3. Implement those doctor lines (the login-restore half is Part 5).

**Check:** `bash tests/test-doctor.sh` exits 0; the cost file has three numbers with methods.
**Commit:** `doctor: what saving does on this server; the cost of a save, measured (#51)`

### Task 4.12 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `bin/roost` (help: `ROOST_SHAPE_KEEP`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 4.1–4.11

**Do:** The page: saving is automatic, what triggers it, what is saved late
(swaps, a join that keeps its window, a drag resize, a `cd`), the ring, which
save a restore picks, closed stays closed, `roost close`/`kill`/`stop` (per
R1) as the way to end a fleet for good. known-gaps: Tasks 4.1–4.4 and 4.11
results; the user-hook global-queue risk. Changelog.

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: saving on change, and what a restore picks (#51)`

### Task 4.13 — Verify

**Files:** none
**Depends on:** 4.12

**Do:** `bash -n`; mutants: save on `after-set-option`; drop the lock; a single
`want` flag; break a lock by age; step back over a `close` save; drop the
`closed/` line; write `closed/` for a death; compare `closed/` with `saved` or
by `gen`; record a missing window or session as killed; compare `shape` with a
new listing to find kills; hook `after-kill-window`; let a kill file outvote a
death note, or a death note outvote a `close.` file; no `pane-died[98]`; read
a placeholder's exit as a cancel; read only `%N` pending files in the overlay;
`mv -f` without `mktemp`. Suite, contrast, container on `ubuntu:24.04` **and**
`ubuntu:22.04` (tmux 3.2a) for `tests/test-shape-*.sh`.

**Check:** suite exit 0; both containers exit 0; every mutant red.
**Commit:** none

**Deferred (Part 4):** none (§8.2 item 3 rides Part 5's reboot).

---

# Part 5 — `roost persist`, the login restore, the first attach (§6 step 5, #192)

Design:     §4.4, §4.5 (login half), §4.6 (trigger, `ensure_session`, cleanup), §8.2 items 1–5
Repository: the `persist-5` worktree of this checkout (`.claude/worktrees/persist-5`)
Branch:     worktree-persist-5
Base:       origin/main when the part starts (Parts 1–4 merged)
Oracle:     automated (`tests/test-persist.sh`, `tests/test-shape-attach.sh`) + instrumented (two probes) + human-eye (§8.2 items 1–5)
Unattended: no — Task 5.1 needs a Linux VM

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
`tests/test-shape-place.sh` and Task 1.2's wake probe with `/bin/sh` = `dash`.

**If the probe says:** passes → nothing. `stty`/`dd` behave differently (no
wake, or no byte) → **stop**.

**Check:** `test -s docs/airig/probes/persist-5-placeholder-dash.md`.
**Commit:** `probe: the placeholder under dash (#192)`

### Task 5.3 — `roost persist on|off|status`

**Files:** `scripts/lib/roost-persist.sh` (new), `bin/roost` (the `persist` arm, help), `tests/test-persist.sh` (new), `tests/lib-shape.sh` (the `launchctl`/`systemctl` recording stubs)
**Depends on:** 5.1

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
   stopped needs `--at-login`: Task 5.4.) **The publish wait:** a
   planted live `lock/` → `on` waits (no load call while the owner lives),
   then saves and loads. A failing save removes `persist` and `service.env`.
   No launchd or systemd → exit 17.
2. Implement §4.4 `on`/`off`/`status`; `on`'s save is not `--auto` (waits by
   the owner rule); `server_running` decided once.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-persist.sh` → all PASS.
**Commit:** `roost persist on|off|status: one login unit per server, never stopped (#192)`

### Task 5.4 — `--at-login`: place, stop, leave the pending record

**Files:** `scripts/lib/roost-persist.sh`, `scripts/lib/roost-restore.sh`, `tests/test-shape-attach.sh` (new)
**Depends on:** 5.3

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
   stopped:** a planted `main` + `work`, server down, Task 5.3's stubs that
   start `restore --at-login <inner>` on the load call → `on` exits 0, the load
   logged, `shape` still the planted save until the job's `--trigger restore`
   save (no `persist-on` save in between), the job places both. `--at-login`
   writes `restoring/` first, waits up to 60 s for
   the socket directory, writes `login/<os-boot>` and `login.log` (0600,
   halved past 1 MB), removes other boots' `pending/`, `claims/` and
   `closed/` after its own files, and always exits 0.
2. Implement.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-attach.sh` → all PASS.
**Commit:** `persist --at-login: place the fleet at login and keep every key for the first attach (#192)`

### Task 5.5 — The first attach: `client-attached[98]`

**Files:** `tmux/roost.conf`, `bin/roost` (`restore --resume --auto`), `tests/test-shape-attach.sh`
**Depends on:** 5.4

**Do:**
1. Red first (§8.1 test 11, the hook cases): **a real attach** from a pane of
   a second throwaway server with no direct `restore --resume` → three stubs
   2 s apart in `order`, exactly three launches, each file `.launching` then
   gone on identify; **the same with `client-attached[98]` deleted** from the
   test's conf → zero launches; **two clients** in the same second → each stub
   once; **worker held past 10 s** (`--pace 6`, second attach at 12 s) →
   nothing extra, `resuming/` still names the first; **(d) must still launch** —
   rc files with banners, client at 80x20 against a 200x50 save → all three
   launch, none `.taken`/`.failed`; a detach starts nothing. `restore --resume
   --auto` waits for a live `restoring/` owner before it walks.
2. `tmux/roost.conf`: `set-hook -g client-attached[98] 'run-shell -b
   "…/bin/roost restore --resume --auto … >/dev/null 2>&1 || :"'` (a Task 4.3
   measured name), with its why.

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-attach.sh` → all PASS.
**Commit:** `the first attach resumes the agents, paced, and a detach never does (#192)`

### Task 5.6 — `ensure_session` waits for, or runs, the login restore

**Files:** `bin/roost` (`ensure_session`), `tests/test-shape-attach.sh`
**Depends on:** 5.4

**Do:**
1. Red first (§8.1 test 11's last cases): `persist` on, no server, a `shape`,
   no `login/<os-boot>` → `roost spawn x sh` (through `ensure_session`) runs the
   placement itself; with the marker → it does not. A live `restoring/` owner
   → `ensure_session` waits, printing `waiting for the login restore (pid N)`
   every 10 s, then goes on; a dead owner → no wait.
2. Implement; `persist` off → unchanged (Part 7 adds the offer).

**Check:** `XDG_STATE_HOME=$(mktemp -d) bash tests/test-shape-attach.sh`; `bash tests/test-panes.sh` exits 0.
**Commit:** `ensure_session waits for the login restore, or runs it when the service did not (#192)`

### Task 5.7 — `roost upgrade` follows, and `doctor` says the login half

**Files:** `scripts/roost-upgrade`, `scripts/roost-doctor`, `tests/test-upgrade.sh`, `tests/test-doctor.sh`
**Depends on:** 5.3

**Do:** Red first: with `persist` on (write-only seam), an upgrade that moves
the checkout rewrites the unit to the new path and says so; doctor's line
`persist: saving on; login restore on for 'NAME' (launchd, unit names this
checkout; roots match; last save …; last login restore: …; N pending)`; `warn`
when the unit names another checkout, `service.env` names a root the caller
lacks, its `PATH` lacks a harness the shape names, the newest save is older
than the server's boot, or this boot's pending record has unlaunched or failed
panes; and `resuming/` over 60 s. Then implement.

**Check:** `bash tests/test-upgrade.sh` and `bash tests/test-doctor.sh` exit 0.
**Commit:** `upgrade rewrites the login unit; doctor reports the login restore (#192)`

### Task 5.8 — Docs and changelog

**Files:** `site/content/docs/persistent-sessions.md`, `site/content/docs/getting-started.md` (a pointer only), `bin/roost` (help: `persist`), `docs/known-gaps.md`, `CHANGELOG.md`, `site/content/docs/changelog.md`
**Depends on:** 5.1–5.7

**Do:** The persist section: `on`/`off`/`status`, what runs at login and at
first attach, linger on Linux, `off` never stops an agent, the Keychain note,
what `service.env` holds and never holds. known-gaps: Tasks 5.1 and 5.2.
Changelog (Added: `roost persist`).

**Check:** `cd site && node scripts/build-llms-txt.mjs --check` exits 0; changelog synced.
**Commit:** `docs: roost persist and the login restore (#192)`

### Task 5.9 — Verify

**Files:** none
**Depends on:** 5.8

**Do:** `bash -n`; mutants: load the unit in a test; `--now` on `off`;
delete `client-attached[98]`; break `resuming/` by age; place a shell instead
of a placeholder at login; start the placeholder through `default-command`'s
value. Suite, contrast, container.

**Check:** suite exit 0; container exit 0; every mutant red.
**Commit:** none

**Deferred (Part 5) — one pass, on a spare machine or VM, never the live server:**
1. §8.2 item 1 — a real macOS reboot with `persist on`: placement at login,
   waiting lines, agents 2 s apart after `roost`, a key keeps a shell, each
   Claude at its prompt with its conversation, `login.log` names the save and
   why, `restore --list` shows the pending record empty; count dialogs by
   harness; repeat with `roost` typed before the service ran.
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
   prompt. **(j)** two panes in one second → one summary, the other `waiting
   for the restore offer in another terminal`; `n` in the first → the second
   attaches with no summary; `kill -9` the first instead → the second takes
   `offer/` over and asks.
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
| 1 base (placement, first cwd, layout ids stripped, zoom, 200x50) | 1.8 |
| 1 body compare (save twice, one file) | 1.4 |
| 1 wide layout | 1.8 |
| 1 wired | 1.8 |
| 1 started at all, and a user's own `default-command` | 5.4 |
| 2 base (existing skipped; stopped server's bootstrap used) | 1.7 |
| 2 (a) (b) (c) (d) (e) (f) (g) (h) | 1.7 |
| 2 (i) unkeyed half | 1.8 |
| 2 (i) keyed half | 3.3 |
| 2 (j) | 1.8 |
| 3a a gone `cwd` → shell at `$HOME`, stderr line | 1.9 |
| 3b exit 13 when it had a key | 3.5 |
| 4 resume, pacing, `--no-resume`, `--recent` launch count, `--only` | 3.5 |
| 4 `--recent` holds at the next attach (worker-only) | 3.5 |
| 4 directory rule (all cases) | 3.5 |
| 4 exited and nested — the saver classifies | 1.4 |
| 4 exited and nested — restore launches neither | 3.5 |
| 4 siblings, duplicate, stale, store miss, mid-turn line | 3.5 |
| 5 parse refusals, unknown block, whitespace | 1.5 |
| 5 deleted block, renamed session, linked window | 1.8 |
| 5 "create nothing" on a refusal | 1.9 |
| 6 live pane, own key, exited, nested, other (revive), release only one's own | 2.6 |
| 6 `other` — saved with `stale_reason other` | 1.4 |
| 6 gone pane, no transcript in the record, two revives, `--new-window` own key | 2.7 |
| 6 against a waiting pane, overlapping the worker, taken pane in use / idle / `--force`, interrupted revive, no origin line, inherited origin, `--new-window` from a pending file | 3.8 |
| 7 addressing (all) | 3.9 |
| 8 per-verb new `shape`, 50 `state working` none, triggers | 4.7 |
| 8 `window-layout-changed` none; what no hook covers; hooks load | 4.6 |
| 8 owner rule (live `restoring/`, dead pid, reused pid), owner held past 10 s, ring | 4.5 |
| 8 coalescing on cue | 4.6 |
| 8 ten `spawn`s in parallel | 4.7 |
| 8 (a) (c) (d) (f) reading rule | 4.9 |
| 8 (b) planted race, same second, (g) in flight, the belt | 4.8 |
| 8 (e) the last session (per R1) | 5.4 |
| 8 (b2) overlap rewritten, death in the gap, (h) boot change, (i) kills by every route | 4.6 |
| 9 persist (all but the next row) | 5.3 |
| 9 `on` with the server stopped | 5.4 |
| 10a `save` with empty/relative/read-only dir | 1.4 |
| 10b `save --auto` degrade; reader loop | 4.5 |
| 10b every hook exits 0 within 5 s with saving off | 4.6 |
| 11 `--at-login` placement, structural save in the gap, second reboot | 5.4 |
| 11 a real attach; hook deleted; two clients; worker held; (d) must still launch | 5.5 |
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
| 11 dialog keys survive — `--at-login` half | 5.4 |
| 11 `kill-pane` before attach; taken then `exit`ed | 4.10 |
| 11 a `.failed` listed and retried only with `--retry` | 3.6 |
| 11 `ensure_session` with persist on, with and without the marker | 5.6 |
| 11 other host | 1.9 |
| 11 two sockets | 3.9 |
| 12 (a) (b) markers and switches (c) (d) (e) (j) | 7.3 |
| 12 (b) no answer, (f) (h) (i), Ctrl-C | 7.4 |
| 12 (g) (h3) (k) (k2) (k3) | 7.5 |
| 12 (h2) | 7.2 |
| guard: `status --json` byte-identical but `was` | 3.9 |
| guard: record tests pass with shapes on | 4.10 |
| guard: canary empty | every test file (Global constraints) |
| guard: 0700 directory | 1.3 |
| guard: 0600 files | 1.4 |
| mutations | each part's verify task (1.11, 2.11, 3.14, 4.13, 5.9, 6.6, 7.7) |
| live: `revive-smoke.sh` | 2.8 |
| live: codex, copilot, pi resume cases | 2.9 |

Split items: where one §8.1 item spans two parts (test 1, 2 (i), 3, 4, 6, 10,
11), it is cut into the halves named above, each half in exactly one task. The
split follows §6's step for the mechanism each half asserts.
