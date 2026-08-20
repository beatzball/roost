# Rename `amux` → `roost` — Plan

Design:     `docs/airig/specs/2026-08-16-rename-to-roost-design.md`
Repository: `/Users/<home>/w/beatzball/amux/.claude/worktrees/rename-to-roost`
Branch:     `worktree-rename-to-roost`
Base:       `7bd1ed4`
Oracle:     automated (with a deferred human-eye batch)
Unattended: no

> **Repository path:** the literal path is the `rename-to-roost` worktree, not
> the primary checkout. Resolve it as
> `$(git -C <primary> worktree list | grep rename-to-roost | awk '{print $1}')`
> and `cd` there. Never commit from the primary checkout.

## Global constraints

- **Test command:** `bash tests/run.sh` from the repository root. It runs every
  `tests/test-*.sh` and sums PASS/FAIL. A non-zero exit means a test file died
  mid-run, which the counts alone do not reveal — treat it as failure.
- **Extra CI step:** `python3 tests/test-contrast.py`.
- **Suite stability — what to do about a failure.**
  The original `tests/test-switcher.sh` flake (`an unnamed pane's switcher row
  falls back to the command`, ~1 run in 30) has been **fixed** on this branch.
  Its cause was `tests/lib.sh` starting test panes on the developer's login
  shell, so `pane_current_command` changed under the test; panes are now pinned.

  **However**, the Tasks 9–10 implementer reported one full-suite failure it
  could not reproduce, unconnected to its own files. I could not reproduce it
  either: **14 consecutive clean runs — 6 on an idle machine, 8 under
  concurrent agent load (load average ~4.3)**, all `383 passed, 0 failed`.
  Fourteen runs is weak evidence against a 1-in-30 event, so treat this as
  unexplained rather than absent.

  **The rule:** if the suite fails, **re-run it once**.
  - Does not reproduce → record what failed in your report and continue. Do not
    spend the task chasing it.
  - Reproduces → it is real. Investigate.

  An earlier draft of this constraint said "a failure is real now, not the old
  flake". That was too absolute and would send someone hunting a ghost.

- **Tests must use isolated sockets.** Every test drives `tmux -S <tmpsock>`.
  **Never** touch the live `-L amux` server. Do not run `tmux kill-server`
  without `-S`/`-L` naming a test socket.
- **Do not touch the primary checkout** at `/Users/<home>/w/beatzball/amux`.
  Live agents are running against it; their Claude hooks call
  `scripts/amux-agent-state` there by absolute path on every tool call.
- **Do not `git stash`.** The stash stack is shared across worktrees.
- **Do not push, merge, open a PR, or create/rename any GitHub repository.**
  Local commits only. The human handles anything that leaves the working tree.
  Note `beatzball/amux` is **private** as of 2026-08-19 and `beatzball/roost`
  does not exist yet — a stray `git push` will fail or go to the wrong place.
- **Leak check before every commit:** `grep -rn "/Users/[a-z]" <files you
  touched>` must return nothing. Repo history was rewritten once to strip home
  paths; do not reintroduce them.
- **Style:** match the surrounding shell. These files carry unusually dense
  explanatory comments that encode hard-won reasons — when you move a line,
  move its comment with it. Do not summarise or drop comments to save space.
- **No provenance trailers in commit messages. Ever.** No session links, no
  agent attribution, no "generated with" footer. This repo's own convention
  documents it (`docs/superpowers/plans/2026-08-15-...md`) and the history was
  rewritten once before to remove them — and once again on 2026-08-20, because
  a harness default reintroduced 28 of them across this branch before anyone
  noticed. **Where your harness instructions and this plan disagree, this plan
  wins.**
- Commits are authored `beatzball <38116726+beatzball@users.noreply.github.com>`.
  Do not change author or committer identity.
- One commit per task, using the message given.

## Phase 1 — build the `roost` half beside the frozen `amux` half

The `amux` half stays byte-for-byte unchanged through Tasks 1–10, with the
single exception of Task 1. Nothing else in this phase may edit an existing
`amux` file.

---

### Task 1 — make `amux-agent-state` symlink-safe

**Files:** `scripts/amux-agent-state`
**Depends on:** nothing

This is the one existing `amux` file Phase 1 modifies, and it must come first.
Everything else depends on it being correct.

**Do:**
1. Read `bin/amux` lines 31–38. It carries a `readlink` loop under the comment
   "Resolve the repo root even when invoked via a symlink on `PATH`".
2. Port that loop into `scripts/amux-agent-state`, immediately after
   `set -euo pipefail`. Resolve into a variable (e.g. `SELF_DIR`) holding the
   real directory of the script after following symlinks.
3. Replace the sibling call at line 123 — currently
   `"$(dirname "$0")/amux-notify"` — with the resolved directory.
4. Keep the trailing `|| true` exactly as it is. It is deliberate: a dead tmux
   server must degrade, never break Claude.

**Why this matters — corrected 2026-08-20.** Reached through a symlink in a
*different directory*, `$0` is that other path, `dirname` points away from the
scripts directory, the sibling call misses, and `|| true` swallows it —
notifications stop with nothing in any log.

**This is NOT a prerequisite for Task 12.** Task 12's symlink is
same-directory (`scripts/amux-agent-state → roost-agent-state`), so `dirname`
resolves correctly with or without this fix; the old code would have survived
by accident. Verified by direct test. The task is still worth doing first — it
is cheap, adds no tmux round trip, and closes the different-directory case that
the install instructions invite — but do not treat the ordering as load-bearing
or claim a Task 12 outage if it slips.

**Check:** write the test first and see it fail.
Add to `tests/test-agent-state.sh`: create a temp dir, symlink
`agent-state-alias` → `scripts/amux-agent-state`, invoke the alias inside a
test pane on an isolated `-S` socket, and assert the notify sibling is resolved
against the *real* script directory rather than the symlink's directory. Then
`bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Resolve symlinks in amux-agent-state before sibling calls`

---

### Task 2 — the core state-path scripts

**Files:** create `scripts/lib/roost-config.sh`, `scripts/roost-agent-state`,
`scripts/roost-notify`, `scripts/roost-status`
**Depends on:** Task 1

These four are the badge pipeline: shared config helpers, the hook that stamps
state, the notifier it calls, and the status-bar roll-up. Get them right before
touching the rest — a mistake here is a mistake in everything downstream.

**The rename rules below apply to Tasks 2 and 3 identically.**

**Do:**
1. Copy each `amux` original to its `roost-` counterpart.
2. In the copies only, rename: `amux` → `roost` in identifiers, paths, and
   prose; `AMUX_*` → `ROOST_*`; `amux_*` shell functions → `roost_*`;
   `@amux-*` tmux options → `@roost-*`.
3. Change the socket guard in `roost-agent-state` from `*/amux)` to `*/roost)`.
4. Change the `-L amux` fallback in each `tmx()` helper to `-L roost`.
5. **Do not rename** `@agent_state` or `@agent_since`. They are unbranded on
   purpose, and that is what lets both servers share one hook mechanism.
6. Preserve every comment. Where a comment names a file, update the name.
7. `chmod +x` each new script to match its source.

**Check:** `bash -n` on each of the four → no syntax errors.
`grep -rn "amux\|AMUX_\|@amux-" scripts/roost-agent-state scripts/roost-notify scripts/roost-status scripts/lib/roost-config.sh`
→ returns nothing.
`grep -c "@agent_state" scripts/roost-agent-state` → non-zero (must survive).
Then `bash tests/run.sh` → all PASS, exit 0 (the `amux` half is untouched, so
the suite must be unaffected).

**Commit:** `Add the core roost state-path scripts`

---

### Task 3 — the remaining `roost` scripts

**Files:** create `scripts/roost-doctor`, `scripts/roost-init`,
`scripts/roost-next-blocked`, `scripts/roost-settings`, `scripts/roost-switch`,
`scripts/roost-themes.sh`
**Depends on:** Task 2

**Do:**
1. Apply the same seven rename rules listed in Task 2 to these six files.
2. **Do not create `roost-migrate-state`** — see Task 6. Its absence is
   deliberate, not an oversight.

**Check:** `bash -n` on each of the six → no syntax errors.
`grep -rn "amux\|AMUX_\|@amux-" scripts/roost-doctor scripts/roost-init scripts/roost-next-blocked scripts/roost-settings scripts/roost-switch scripts/roost-themes.sh`
→ returns nothing.
`ls scripts/roost-migrate-state` → "No such file".
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Add the remaining roost scripts`

---

### Task 4 — create `bin/roost` and `tmux/roost.conf`

**Files:** create `bin/roost`, `tmux/roost.conf`
**Depends on:** Task 3

**Do:**
1. Copy `bin/amux` → `bin/roost` and `tmux/amux.conf` → `tmux/roost.conf`.
2. Apply the same renames as Task 2 to both copies.
3. In `bin/roost`: the socket default becomes `roost` (`tmux -L roost`), and
   `AMUX_HOME` becomes `ROOST_HOME`. Point `CONF` at `tmux/roost.conf`.
4. In `roost.conf`: every `scripts/amux-*` path becomes `scripts/roost-*`.
5. `chmod +x bin/roost`.

**Check:** `bash -n bin/roost` → clean.
`tmux -S /tmp/roost-t.sock new-session -d && tmux -S /tmp/roost-t.sock source-file tmux/roost.conf && echo OK` → prints `OK` with no errors, then
`tmux -S /tmp/roost-t.sock kill-server`.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Add bin/roost and tmux/roost.conf`

---

### Task 5 — keep `set -gu @agent_state`, drop `set -gu @agent_glyph`

**Files:** `tmux/roost.conf`
**Depends on:** Task 4

**Do:**
1. In `tmux/roost.conf` only, delete the `set -gu @agent_glyph` line (conf:42
   in the `amux` original).
2. **Keep `set -gu @agent_state`** (conf:41). Update the adjacent comment so it
   no longer describes `@agent_glyph`, but keep the sentence explaining that
   re-sourcing only adds and overwrites, so the unset is the only way to clear
   a stray global on a live server.
3. **Do not add a `set -gu @agent_since`.** Every read of `@agent_since` is
   nested inside an `@agent_state` guard (see `roost.conf`'s pane-border
   format), so a stray global `@agent_since` alone cannot badge anything. The
   asymmetry is deliberate.

**Why:** the two lines look alike and do different jobs. `@agent_state` clears
a global from *any* source including future ones — a live self-heal, and the
only recovery short of killing the server. `@agent_glyph` clears only what a
known past version wrote, so it goes with the tombstone.

**Check:** `grep -c "@agent_glyph" tmux/roost.conf` → `0`.
`grep -c "set -gu @agent_state" tmux/roost.conf` → `1`.
`grep -c "@agent_since" tmux/roost.conf` → non-zero (reads remain).
`grep -c "set -gu @agent_since" tmux/roost.conf` → `0`.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `roost.conf: keep the @agent_state unset, drop the @agent_glyph one`

---

### Task 6 — drop the migrate path from the `roost` half

**Files:** `tmux/roost.conf`, `scripts/roost-doctor`,
`scripts/lib/roost-config.sh`
**Depends on:** Task 5

**Do:**
1. Confirm `scripts/roost-migrate-state` does not exist. Do not create it.
2. In `tmux/roost.conf`, remove the `if-shell` that runs the migration on every
   source (conf:58 in the `amux` original), and the comment block above it
   describing the window-scoped migration.
3. In `scripts/roost-doctor` and `scripts/lib/roost-config.sh`, remove comment
   references to `migrate-state`.
4. Leave `scripts/amux-migrate-state` and `tests/test-migrate-state.sh`
   completely untouched — the frozen `amux` half still needs them.

**Why:** the migrate script exists only to clear window-scoped
`@agent_state` / `@agent_glyph` / `@agent_since` written by pre-per-pane
versions. `roost` runs on its own socket, so it can never inherit a live
pre-per-pane `amux` server, and no `roost` version ever wrote those values.

**Check:** `ls scripts/roost-migrate-state` → "No such file".
`grep -rn "migrate-state\|migrate_state" tmux/roost.conf scripts/roost-* scripts/lib/roost-config.sh`
→ returns nothing.

**Grep for `migrate-state`, not bare `migrate`.** Task 8 legitimately adds the
word "migrated" to `scripts/roost-init:22` — that is *config-file* migration
(carrying `~/.config/amux/amux.conf` across), a different concept from the
*window-scoped state* migration this task removes. A bare `migrate` grep
false-positives on it and would send someone deleting the wrong thing.
`ls scripts/amux-migrate-state tests/test-migrate-state.sh` → both still exist.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Drop the migrate-state path from the roost half`

---

### Task 7 — socket-guard tests for both halves

**Files:** create `tests/test-socket-guard.sh`
**Depends on:** Task 4

Write the test first and see it fail before wiring anything.

**Do:**
1. New test file following the shape of `tests/test-agent-state.sh` — source
   `lib.sh`, drive isolated `-S` sockets.
2. Assert: `scripts/roost-agent-state working` invoked in a pane on a socket
   whose path ends `/amux` exits 0 and stamps **nothing**.
3. Assert: `scripts/amux-agent-state working` invoked in a pane on a socket
   whose path ends `/roost` exits 0 and stamps **nothing**.
4. Assert the positive cases too: each stamps `@agent_state` on its own socket.

**Why:** this mutual no-op is what lets both hooks sit in `settings.json` at the
same time with no dispatcher. It is the load-bearing property of the whole
transition and nothing currently tests it.

**Check:** `bash tests/test-socket-guard.sh` → all PASS, exit 0. Then
`bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Test that each agent-state script no-ops on the other's socket`

---

### Task 8 — config migration and its test

**Files:** `scripts/roost-init`, create `tests/test-roost-config-migration.sh`
**Depends on:** Task 3

Write the test first and see it fail.

**Do:**
1. In `scripts/roost-init`: write `~/.config/roost/roost.conf`. If that file is
   absent but `~/.config/amux/amux.conf` exists, read the old file, translate
   `@amux-*` keys to `@roost-*`, and write the result to the new path.
2. **Never delete or modify the old file.** The running `amux` server is still
   reading it.
3. New test: point `HOME`/`XDG_CONFIG_HOME` at a temp dir, seed a legacy
   `amux.conf` with a couple of `@amux-*` settings, run the migration, assert
   the new file exists with `@roost-*` keys and the same values, and assert the
   old file is byte-identical afterwards.

**Check:** `bash tests/test-roost-config-migration.sh` → all PASS, exit 0. Then
`bash tests/run.sh` → all PASS, exit 0.

**Commit:** `roost init migrates a legacy amux config without touching it`

---

### Task 9 — `roost.js` OpenCode adapter

**Files:** create `adapters/opencode/roost.js`; `scripts/roost-doctor`
**Depends on:** Task 3

**Do:**
1. Copy `adapters/opencode/amux.js` → `roost.js`. Change `execFile("amux", …)`
   to `execFile("roost", …)`, `AMUX_AGENT_NAME` → `ROOST_AGENT_NAME`, and the
   install-instruction comment to the `roost` paths.
2. In `scripts/roost-doctor`, point the plugin check at
   `~/.config/opencode/plugin/roost.js` → `adapters/opencode/roost.js`.
3. **Keep the dangling-symlink branch** (`[ -L "$p" ] && [ ! -e "$p" ]`). It is
   not OpenCode-specific — it is exactly the tripwire a rename needs, because
   renaming a file that users have symlinked into another program's config
   directory breaks silently at the far end.

**Check:** `node --check adapters/opencode/roost.js` → clean.
`grep -c '"amux"' adapters/opencode/roost.js` → `0`.
Confirm the dangling-symlink branch survives:
`grep -c '\[ -L "\$ocplug" \] && \[ ! -e "\$ocplug" \]' scripts/roost-doctor` → `1`.

**An earlier draft of this check was `grep -c 'not.*-e'`, which returns 0** —
the words "not" and "-e" sit on two different comment lines, so no single line
matches. The implementer correctly reported the check as unsatisfiable rather
than contorting the code to satisfy it, and verified the requirement another
way. Match the code, not the prose about it.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Add the roost OpenCode adapter and point roost doctor at it`

---

### Task 10 — `doctor` check for a stale hook path

**Files:** `scripts/roost-doctor`, `tests/test-doctor.sh`
**Depends on:** Task 9

Write the assertion first and see it fail.

**Do:**
1. Add a check to `scripts/roost-doctor`: if `~/.claude/settings.json` exists
   and contains `amux-agent-state`, warn — naming the exact fix (replace those
   hook commands with the `roost-agent-state` path). Warning, never a hard
   failure.
2. Also warn if `~/.config/opencode/plugin/amux.js` still exists.
3. Extend `tests/test-doctor.sh` with a case that points `HOME` at a temp dir
   containing a `settings.json` referencing the old path, and asserts the
   warning fires; plus a clean case asserting it does not.

**Why:** this check is the **Phase 5 trigger**. The shims are deleted once
`roost doctor` reports clean on every machine the author uses. Without it, the
deletion is a guess and the shims live forever.

**Check:** `bash tests/test-doctor.sh` → all PASS, exit 0. Then
`bash tests/run.sh` → all PASS, exit 0.

**Commit:** `roost doctor warns when settings.json still points at amux`

---

## Phase 2 — docs, skill, and the human-eye batch

### Task 11 — move docs and the skill

**Files:** `docs/superpowers/**` → `docs/airig/**`; `skills/amux/SKILL.md` →
`skills/roost/SKILL.md`; `README.md`; **`tests/test-coordination.sh`**
**Depends on:** Task 10

**Do:**
1. `git mv docs/superpowers docs/airig` — merging into the existing
   `docs/airig/` rather than replacing it. `specs/` and `plans/` already exist
   there; move the historical files in beside them.
2. `git mv skills/amux skills/roost`, and rename inside `SKILL.md`.
3. Update `README.md` throughout: `amux` → `roost`, the install snippet, and
   the layout section listing `scripts/*`.
4. **Required, not cosmetic:** change `npx skills add beatzball/amux --skill
   amux` → `npx skills add beatzball/roost --skill roost`. There is no GitHub
   redirect — `beatzball/amux` is private and 404s anonymously **today**, so
   the old command is already broken for everyone. This README edit is the
   only mitigation that exists, and it only reaches people who re-read it.
5. Remove the "Upgrading a running server" paragraph — it documents
   `migrate-state`, which the `roost` half no longer has.
6. **Repoint `tests/test-coordination.sh`'s skill-integrity block.** It
   hardcodes `$HERE/skills/amux/SKILL.md` (line ~175) and greps
   `$HERE/bin/amux` (line ~178), across 4 assertions. Moving the skill without
   this makes those assertions fail, so **this task fails its own Check** until
   they are repointed to `skills/roost/SKILL.md` and `bin/roost`.

   Task 15 deliberately left them alone — at that point `skills/roost/` did not
   exist, so renaming early would have turned passing assertions into failures
   against a nonexistent file. This is the task where the move happens, so this
   is where they get repointed.

   `bin/roost` matters as much as the skill path: Task 12 turns `bin/amux` into
   a thin stub, and a stub does not contain the subcommand names this block
   greps for. Left pointed at `bin/amux`, these assertions break again one task
   later for a different reason.
7. Leave the historical spec and plan files' *content* alone. They are a record
   of what was true then; renaming inside them would falsify history. Only
   their location changes.

**Check:** `ls docs/superpowers` → "No such file".
`ls docs/airig/specs docs/airig/plans` → both populated.
`grep -rn "docs/superpowers" . --exclude-dir=.git` → returns nothing.
`grep -c "amux" README.md` → `0`.
`grep -c "beatzball/roost" README.md` → non-zero.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Move docs to docs/airig, rename the skill, update the README`

---

### Task 12 — the three shims

**Files:** replace `scripts/amux-agent-state` with a symlink; rewrite
`bin/amux` as a stub
**Depends on:** Task 11

**This task runs only after the human confirms the old `amux` session is
drained.** Do not start it unattended. Ask, and wait.

**Do:**
1. `rm scripts/amux-agent-state && ln -s roost-agent-state
   scripts/amux-agent-state` — a **relative** symlink so the repo stays
   portable.
2. Replace `bin/amux` with a small stub that prints a one-line deprecation to
   stderr ("amux has been renamed to roost; run `roost` instead") and then
   `exec`s `roost` with the same arguments, so it still works.
3. `rm adapters/opencode/amux.js && ln -s roost.js adapters/opencode/amux.js`
   — a **relative** symlink, the third shim. The author's
   `~/.config/opencode/plugin/amux.js` points at this file; deleting it would
   dangle that link and OpenCode agents would stop badging **silently**.
4. Both symlinks must print **nothing**. `PostToolUse` fires on every tool call
   and Claude Code hook stderr can surface into the agent transcript — a line
   per call is context noise injected into the very agent being badged. The
   `bin/amux` stub may print freely; it is interactive and not on a hot path.

**Check:** `readlink scripts/amux-agent-state` → `roost-agent-state`.
`readlink adapters/opencode/amux.js` → `roost.js`.
`node --check adapters/opencode/amux.js` → clean (resolves through the link).
`scripts/amux-agent-state working` run outside tmux → exits 0, prints nothing
to stdout or stderr (`out=$(scripts/amux-agent-state working 2>&1); [ -z "$out" ]`).
`bin/amux --help 2>/dev/null` → same output as `bin/roost --help`.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Add the three compatibility shims`

---

### Task 13 — delete the frozen `amux` half

**Files:** delete `scripts/amux-doctor`, `scripts/amux-init`,
`scripts/amux-migrate-state`, `scripts/amux-next-blocked`,
`scripts/amux-notify`, `scripts/amux-settings`, `scripts/amux-status`,
`scripts/amux-switch`, `scripts/amux-themes.sh`, `scripts/lib/amux-config.sh`,
`tmux/amux.conf`, `tests/test-migrate-state.sh`; edit `tests/test-reload.sh`
**Depends on:** Task 12

**Do:**
1. `git rm` each file listed. **Keep all three shims** — they survive to
   Phase 5: `scripts/amux-agent-state` (symlink), `bin/amux` (stub), and
   `adapters/opencode/amux.js` (symlink). Do **not** delete the adapter: the
   author's `~/.config/opencode/plugin/` links to it.
2. Remove the migration assertions from `tests/test-reload.sh` (lines 13–15 and
   22–68 in the pre-rename file) — they test a path that no longer exists.
3. Retarget any remaining test that sources `tmux/amux.conf` to
   `tmux/roost.conf`.

**Check:** the **shim-only grep gate**:
`grep -rl "amux" bin scripts tmux tests skills adapters` → lists **only** the
three shims: `bin/amux`, `scripts/amux-agent-state`,
`adapters/opencode/amux.js`. Nothing else.

This is only achievable because **Task 15** migrated `tests/` first. Before
that task, `tests/` alone holds 498 `amux` references and this gate cannot
pass. If it fails listing test files, Task 15 was skipped or incomplete —
fix that rather than loosening the gate. Strict mode does not
apply until Phase 5, because the shims contain the old name by design.
Then `bash tests/run.sh` → all PASS, exit 0, and
`python3 tests/test-contrast.py` → passes.

**Commit:** `Delete the frozen amux half, keeping the three shims`

---

### Task 14 — archive the PR history before cutover

**Files:** create `docs/airig/history/pull-requests.md`
**Depends on:** nothing — **run this first**

> **Ordering note:** this is numbered last but has no dependencies, and it is
> the only task guarding against *irreversible* loss. `beatzball/amux` is
> private and its deletion is an open decision; if it is deleted before this
> runs, `#1`–`#8` are gone permanently. Everything else in this plan is
> reproducible from the working tree. Run it whenever convenient, ideally
> first.

**Do:**
1. `gh pr list --state all --limit 100 --json number,title,body,mergedAt,author`
   against `beatzball/amux`.
2. Write one Markdown section per PR, newest first: number, title, merge date,
   then the body verbatim in a fenced block.
3. Head the file with a note that these PRs live only in the archived
   `beatzball/amux` repository and do not exist in `beatzball/roost`.
4. **Scrub before committing.** PR bodies were written before the history
   rewrite and may contain absolute home paths. Run the leak check over the new
   file specifically and replace any hit with `/absolute/path/to/amux`.

**Why:** `beatzball/roost` is a **new repository**, not a rename. Renaming
would have kept the same repo — same objects, same SHAs, same PRs — which is
precisely why it was rejected: pre-rewrite objects containing the maintainer's
home path were still being served after the force-push, and a redirect would
have kept them reachable. The cost of a fresh repo is that `#1`–`#8` (~28.7 KB
of bodies, 0 issues) vanish unless captured here first.

**Check:** `grep -c '^## PR #' docs/airig/history/pull-requests.md` → `8`.
`grep -n "/Users/[a-z]" docs/airig/history/pull-requests.md` → returns nothing.
Then `bash tests/run.sh` → all PASS, exit 0.

**Commit:** `Archive PR #1-#8 bodies before the new-repo cutover`

---

### Task 15 — migrate the test suite to the `roost` half

**Files:** **every file under `tests/` that contains `amux`, whatever its
extension**, except the three protected files below. Derive the list, do not
assume it: `grep -rl amux tests/`. At the time of writing that is 26 files.
**Depends on:** Task 4
**Runs before:** Task 5. Numbered last only because it was found after the loop
started — **execute it in dependency order, immediately after Task 4.**

> **This task was missing from the original plan.** Without it Task 13 is
> impossible, not merely wrong: it deletes `scripts/amux-*`, and 14 test files
> invoke those scripts by path. The suite would collapse and Task 13's own
> Check could never pass. Measured at `2362b00`: **21 files, 498 `amux`
> references** under `tests/`.

**Do:**
1. In every file from that list **except the three protected files**, repoint:
   `scripts/amux-<x>` → `scripts/roost-<x>`; `tmux/amux.conf` →
   `tmux/roost.conf`; `AMUX_*` → `ROOST_*`; `@amux-*` → `@roost-*`.
2. In `tests/lib.sh`, rename `AMUX_TEST_SOCK`, `AMUX_TEST_SOCKDIR`,
   `AMUX_TESTS_PASS`, `AMUX_TESTS_FAIL` to their `ROOST_*` forms, and update
   every test that reads them.
3. **The three protected files. Do not rename `amux` in any of them.**

   | file | why it must keep `amux` |
   |---|---|
   | `tests/test-migrate-state.sh` | tests `scripts/amux-migrate-state`, which the `roost` half deliberately does not have (Task 6). Task 13 deletes both together. |
   | `tests/test-reload.sh` | its migration assertions target the `amux` half, same reason. Only those assertions — the rest of the file repoints normally. |
   | `tests/test-roost-config-migration.sh` | **31 deliberate references.** It is a `roost` test whose *subject* is the `amux` config: it seeds a legacy `~/.config/amux/amux.conf` with `@amux-*` keys and asserts they translate to `@roost-*`. |

   **The third one is the dangerous case.** Renaming it does not break the
   suite — it makes the test seed `@roost-` keys and assert they become
   `@roost-` keys. Vacuous, and still green. Task 8's entire test would be
   destroyed with no failing signal.

   The general rule this illustrates: **a file containing `amux` is not
   automatically a file that needs renaming.** Some reference `amux` because
   `amux` is what they are about. Before renaming any occurrence, ask whether
   the string is naming *this project's own thing* (rename it) or *the old half
   that this test is deliberately exercising* (leave it).
5. **Do not rename** `@agent_state` or `@agent_since` anywhere.

**Why here:** after this task the suite exercises the `roost` half, which is
what every later task's "all PASS" should mean. The frozen `amux` half becomes
untested for the remainder of the plan — acceptable, because it is frozen and
scheduled for deletion, and the two shims are covered by Task 12's own checks.

**Scope by directory contents, not by extension or glob.** This task's scope
has been wrong twice, the same way both times:

- First draft: `tests/*.sh` — missed all of `tests/live/`, including
  `opencode-smoke.sh` (9 references, on `main` since PR #8).
- Second draft: `tests/**/*.sh` — reached `tests/live/` but missed every
  non-shell file.

Three non-shell files reference the `amux` half and all three break at Task 13:

| file | what breaks |
|---|---|
| `tests/test-contrast.py` | opens `scripts/amux-themes.sh` by hardcoded path (line 28) and calls the `amux_theme_names` / `amux_theme` shell functions (lines 29, 32). **It is a CI step** — `.github/workflows/ci.yml:22` |
| `tests/opencode-plugin-harness.mjs` | imports `adapters/opencode/amux.js`, names its recording shim `amux`, asserts on `AMUX_AGENT_NAME` |
| `tests/fixtures/swallow-all-enters.py` | comment referencing `@amux-send-retries` |

`test-contrast.py` is the dangerous one: it is green today, breaks only when the
`amux` half is deleted, and fails in CI rather than in the suite the tasks
gate on.

**Check:** `bash tests/run.sh` → all PASS, exit 0.
`python3 tests/test-contrast.py` → passes (this is the CI step, and the only
check that exercises the themes path).
`grep -rl "amux" tests/` → lists **only** `tests/test-migrate-state.sh` and
`tests/test-reload.sh`. This grep is extension-agnostic and recursive, so it
is the authority on scope — if it lists anything else, the task is incomplete
regardless of what the Files line says.
`grep -c "@agent_state" tests/test-agent-state.sh` → non-zero (must survive).

**Commit:** `Migrate the test suite to the roost half`

---

## Deferred checks — one pass at the end

Run these together, once, after Task 13. Do not block any task on them.

1. **Task 4 / 5 — status bar.** Start a `roost` server, open several windows
   with agents in different states. Confirm the badge glyphs render and the
   top-right roll-up counts match the tabs. Cycle **all 8 themes** (`amux`,
   `catppuccin-mocha`, `catppuccin-latte`, `tokyonight-storm`,
   `tokyonight-day`, `gruvbox`, `nord`, `rose-pine`) and confirm each is
   legible with no colour bleed.
2. **Task 3 — settings TUI.** `roost settings`, walk the theme, glyph, and
   separator pickers. Confirm live preview updates the bar, Enter commits, Esc
   reverts, and `✓` marks the saved option.
3. **Task 3 — switcher.** `prefix a`. Confirm the fzf popup lists panes grouped
   by window with state and elapsed time.
4. **Task 2 — notification.** Make an unfocused agent go blocked. Confirm a
   desktop notification arrives. **This is the check that catches a Task 1
   regression** — a broken symlink resolution shows up here and nowhere else.
5. **Task 12 — the shim.** With `settings.json` still pointing at the old
   `scripts/amux-agent-state` path, confirm a live agent still badges
   correctly through the symlink.
6. **Task 10 — doctor.** Run `roost doctor` and confirm the stale-hook warning
   fires while `settings.json` is unchanged, and stops once it is updated.

If a deferred check fails, that is a new task, not a rewind.

## Out of scope — the human does these

- Updating `~/.claude/settings.json` to the `roost` hook paths.
- Creating the `beatzball/roost` repository and pushing to it. Sequenced
  **after** Task 14, and after the clean history is ready — not "at any point".
- Repointing `origin` on both the primary checkout and this worktree. There is
  no redirect to fall back on. Preserve the SSH host alias:
  `git remote set-url origin git@github.com-beatzball:beatzball/roost.git`
- Deciding whether to delete the now-private `beatzball/amux`.
- Killing the old `-L amux` server.
- Registering `roosting.dev`.
- Phase 5: deleting the three shims and the `doctor` migration checks, once
  `roost doctor` reports clean on every machine the author uses.
