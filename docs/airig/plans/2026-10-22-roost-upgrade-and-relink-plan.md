# `roost upgrade`, and a link that names another copy of roost — Plan

Design:     docs/airig/specs/2026-10-22-roost-upgrade-and-relink-design.md
Repository: `<roost>/.claude/worktrees/upgrade-design`, where `<roost>` is
            the primary checkout; the coordinator writes the absolute path
            into the task brief, never into this file
Branch:     worktree-upgrade-design — the branch PR #172 is open from; the
            spec, this plan and the build ship in that one pull request
Base:       d9c5484 (`main`, one commit after 0.7.0); the design and plan
            are the first commits on the branch
Oracle:     automated (one human-eye check, deferred to the end)
Unattended: no — the human merges the pull request; every task's Check is
            automated, so no task waits on a person

## Global constraints

- **Run everything from the Repository path above.** Before every commit:
  `git branch --show-current` must print `worktree-upgrade`. A subagent's
  shell may start in the primary checkout; `cd` to the Repository first.
- **One writer at a time.** Tasks run in series. Commit and stop. Never push,
  merge, open a pull request, or tag.
- **Test command:** `bash tests/<file>.sh` prints `PASS:`/`FAIL:` lines; the
  Check says which file. `bash tests/run.sh` runs them all (slow; Task 11
  only).
- **Every new test exports, before anything else, to a fresh temp directory:**
  `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `COPILOT_HOME`, `CODEX_HOME`,
  `ZDOTDIR`. Copy the canary block from the top of `tests/test-install.sh`
  (lines 9–45: `CANARY`, the exports, `canary_leaks`) and assert
  `canary_leaks` is empty at the end. A throwaway tmux socket is NOT
  isolation on its own.
- **Never run `tmux kill-server` without `-L`/`-S` naming the throwaway
  socket you started.** The author's live agents are on the default roost
  socket.
- **Never run `roost install` without the test's redirected homes**, from any
  checkout, in any task. It is the exact action Task 3 guards against.
- **Scripts are bash** (`#!/usr/bin/env bash`, `set -euo pipefail` where the
  siblings have it). CI runs on Ubuntu with dash as `sh` and tmux 3.4: nothing
  in a `#!/bin/sh` stub may use bashisms.
- **No competitor product names anywhere.** No provenance trailers, session
  links or agent attribution in commit messages (a hook blocks them; rewrite,
  never `--no-verify`).
- **Measured claims only** in comments and docs. Write "measured on X" only
  for something you ran.
- **Message texts are given verbatim in each task.** Use them as written, so
  the tests in the same task match.

## Task 1 — `other-checkout` state and the worktree test, in the shared library

**Files:** `scripts/lib/roost-adapters.sh`, new `tests/test-adapter-state.sh`
**Depends on:** nothing

**Do:**
1. In `scripts/lib/roost-adapters.sh`, add after `roost_adapter_target`:
   ```bash
   # roost_adapter_tail HARNESS -> the path tail every roost checkout's adapter
   # for that harness ends in. The one list roost_adapter_target prints from,
   # written once more here so a link's TEXT can be matched without resolving
   # it (a target under a moved home still names the adapter).
   roost_adapter_tail() {
     case "$1" in
       opencode)  printf '/adapters/opencode/roost.js' ;;
       opencode2) printf '/adapters/opencode/v2' ;;
       pi)        printf '/adapters/pi/roost.ts' ;;
       copilot)   printf '/adapters/copilot/extension.mjs' ;;
     esac
   }
   ```
2. Extend `roost_adapter_state` with a fifth value, **`other-checkout`**:
   the path is a symlink (`-L`), its target exists (`-e`), it is not `-ef`
   this checkout's target, and `readlink "$path"` ends in
   `$(roost_adapter_tail "$h")` (strip a trailing `/` from the readlink text
   first; a directory link may carry one). Keep `foreign` for everything else.
   Order the branches: missing, dangling, ok, other-checkout, foreign. Update
   the function's comment table with the new row:
   `other-checkout  a live symlink whose text names a roost adapter in a DIFFERENT checkout — roost's own link, from a second copy of roost`.
3. Add `roost_checkout_is_worktree [DIR]` (default: `_roost_adapter_root`):
   returns 0 when `git -C DIR rev-parse --git-common-dir` and
   `git -C DIR rev-parse --git-dir`, each made absolute with
   `cd -P ... && pwd` against DIR, differ. Returns 1 when they match, when
   `git` is not on `PATH`, or when DIR is not inside a work tree. Comment:
   in the primary checkout both are `.git`; in a worktree `--git-dir` is
   `<primary>/.git/worktrees/<name>`.
4. Write `tests/test-adapter-state.sh` (source `tests/lib.sh`; canary block
   per Global constraints). Make `co2="$TMP/second-checkout"` by copying this
   checkout's `adapters/` directory into it (`cp -R "$HERE/adapters" "$co2/"`).
   For each of `opencode opencode2 pi copilot`, plant at
   `roost_adapter_path H` (under the redirected homes):
   - a link to `$co2$(roost_adapter_tail H)` → `other-checkout`
   - a link to a regular file `$TMP/stranger.js` → `foreign` (the control)
   - a link to `$co2/elsewhere/roost.js` (exists, wrong tail) → `foreign`
   - a link to `$co2/adapters/opencode/v2` when H is `opencode` (right
     checkout shape, wrong harness) → `foreign`
   - a link to `$TMP/gone$(roost_adapter_tail H)` (nothing there) →
     `dangling` (unchanged)
   - a link to this checkout's own target → `ok` (unchanged)
   Then `roost_checkout_is_worktree`: a `git init -q` temp repo with one
   commit → 1; `git worktree add` of it → 0; a plain directory → 1; with
   `PATH` holding no `git` (use `make_harness_shim` from
   `tests/test-adapter-install.sh`, copied, without `git`) → 1.

**Check:** `bash tests/test-adapter-state.sh` → every line `PASS:`, no
`FAIL:`, canary empty. `bash tests/test-adapter-install.sh` and
`bash tests/test-doctor.sh` still pass (no caller sees the new state yet
except through `foreign`'s old branch, which now reads it as `*`; both tests
plant only strangers today).
**Commit:** `adapters: a link that names another copy of roost is other-checkout, not foreign, and a worktree knows it is one`

## Task 2 — `doctor` names the other copy and prints the command

**Files:** `scripts/roost-doctor`, `tests/test-doctor.sh`
**Depends on:** Task 1

**Do:**
1. In `scripts/roost-doctor`, the four symlink branches (opencode 2 at
   ~line 494, opencode 1.x ~550, copilot ~568, pi ~616) each end in a `*)`
   or `foreign)` arm that prints `... is not this install — relink it to
   $WANT`. Replace each with two arms, texts verbatim (substitute the branch's
   own variables; `LABEL` is the words already used there — `opencode 2
   plugin`, `opencode plugin`, `copilot extension`, `pi extension`):
   - `other-checkout)`:
     `warn "LABEL at $P points at another copy of roost, $(readlink "$P") — run: roost install, or: rm \"$P\" && ln -s \"$WANT\" \"$P\""`
   - `*)` (foreign):
     `warn "LABEL at $P is not this install — look at it first, then relink it: rm \"$P\" && ln -s \"$WANT\" \"$P\""`
2. In `tests/test-doctor.sh`, next to the existing opencode 2 cases (~line
   318 onward, which already build the 2.x `opencode` shim), add under the
   redirected homes: a second checkout made as in Task 1, a link at
   `plugins/roost` to its `adapters/opencode/v2` → the doctor output contains
   `points at another copy of roost`, the second checkout's path, and the
   exact string `rm "<P>" && ln -s "<WANT>" "<P>"` with P and WANT expanded.
   Then the control: the link to a stranger's directory → contains
   `is not this install` and the same `rm ... && ln -s ...` tail. Repeat the
   pair for one file-shaped adapter (pi).

**Check:** `bash tests/test-doctor.sh` → all `PASS:`.
**Commit:** `doctor: a link to another copy of roost is named as one, and every relink line carries the command`

## Task 3 — `install` relinks the other copy's link from a plain checkout, refuses it from a worktree

**Files:** `scripts/roost-install`, `tests/test-adapter-install.sh`
**Depends on:** Task 1

**Do:**
1. Read the header comment of `scripts/roost-install` and the symlink loop
   (lines ~612–683). Near the top, after the libraries are sourced, compute
   once: `IN_WORKTREE=0; roost_checkout_is_worktree "$HERE" && IN_WORKTREE=1`.
2. In the loop's `case "$(roost_adapter_state "$k")"`, add before `foreign)`:
   ```bash
   other-checkout)
     if [ "$IN_WORKTREE" -eq 0 ]; then
       LINK_STEPS="${LINK_STEPS}relink$TAB$h$TAB$(roost_adapter_path "$k")$TAB$(roost_adapter_target "$k")$TAB$k
   "
     else
       REFUSED="$REFUSED$h$TAB$(roost_adapter_path "$k")$TAB$(roost_adapter_target "$k")${TAB}worktree
   "
       record_outcome refused "$h" "$(roost_adapter_path "$k")"
     fi ;;
   ```
   `worktree` is a new ACTION word in REFUSED; document it in the REFUSED
   comment (~line 592).
3. The plan printout: where a `relink` step is listed before the prompt, a
   relink of an `other-checkout` link must say what it replaces. Find where
   LINK_STEPS rows are printed as `relink ...` and, when `readlink "$path"`
   exists as a target (i.e. not dangling), append ` (was <readlink>)`.
4. Write-time re-check (~line 1080): the accepted pairs gain
   `relink:other-checkout`. The `rm -f` under `if [ "$action" = relink ]`
   already runs for relink; keep it a symlink-only removal: add
   `[ -L "$path" ] ||` → treat as "changed underneath" (same refusal arm the
   unlink branch uses for "not a symlink").
5. Record the undo: for `relink` of an `other-checkout` link, the undo is
   `rm "<path>" && ln -s "<old target>" "<path>"`; pass it as
   `record_outcome wrote "$h" "$path" "<that>"` and append the same to `UNDO`.
6. After the writes, where `relinked` is printed (`printf '  %-8s %s\n'
   "${action}ed" "$path"`), print for an other-checkout relink the three
   extra lines, verbatim:
   ```
     was <old target> — a second copy of roost.
     If you did not mean to keep two, remove that copy's directory and the PATH
     line install.sh added for it.
   ```
   where `<old target>` is the readlink captured in step 3, carried on the
   LINK_STEPS row as a sixth field (append `$TAB<old>`; it is empty for
   `link` and `dangling`).
7. The refusal summary (~line 980) and manual notes (~line 1277): a row with
   ACTION `worktree` prints under a third heading,
   `Will NOT touch — a link to another copy of roost, and this is a git worktree:`,
   and its manual note is, verbatim:
   ```
   <h>: <path>
     points at another copy of roost, <old target>.
     This checkout is a git worktree, so roost install leaves the link alone:
     run roost install from that copy, or from this repository's primary
     checkout.
   ```
8. Tests, in `tests/test-adapter-install.sh`, after the existing foreign
   case (#3, ~line 274) and using its box/shim pattern. Make
   `co2` as in Task 1. For `opencode2` (2.x shim, `make_versioned_shim
   'opencode v2.0.20' opencode`) and for `pi`:
   - **plain checkout, other-checkout link** → `install --yes` exits 0, the
     link now `-ef` this checkout's target, output contains `relinked`,
     `was <co2 path>` and `a second copy of roost`; `--records` file holds
     `wrote` with an undo of `rm "<P>" && ln -s "<co2 target>" "<P>"`.
   - **plain checkout, stranger link (control)** → still refused, the
     stranger file byte-identical (`cksum`), path named.
   - **worktree**: `git init -q` a temp repo, commit, `cp -R` this checkout's
     `scripts`, `bin`, `adapters`, `tmux`, `VERSION` into it, commit, then
     `git worktree add "$TMP/wt" -b wt`; run **that worktree's**
     `scripts/roost-install --yes` with a planted other-checkout link →
     exit 0, link unchanged (`readlink` equal before and after), output
     contains `this is a git worktree`; the stranger control unchanged too.
   - **the same temp repo's primary** `scripts/roost-install --yes` → relinks.
     This is the control that proves the rule.
   - `--dry-run` from the plain checkout lists `relink ... (was ...)` and
     writes nothing.

**Check:** `bash tests/test-adapter-install.sh` → all `PASS:`; the existing
alias assertions (#17) still pass (Task 8 changes them, not this task).
**Commit:** `install: relink a link that names another copy of roost, and refuse to from a git worktree`

## Task 4 — the Claude hook gets the same rule; codex does not

**Files:** `scripts/roost-install`, `tests/test-adapter-install.sh`
**Depends on:** Task 3

**Do:**
1. In the JSON loop (~line 795–830): today `json_gone=1` only when the
   other checkout's hook path does not exist, and only then is the probe
   re-run with that directory as `also` so the entry becomes `replaced`.
   Add `json_other=0`; set `json_other=1` whenever `json_state` is
   `other-checkout` and `json_detail` names the marker (the existing `case`),
   whether or not the path exists. Re-run the probe (the existing block) when
   `h = claude` and (`json_gone = 1` or (`json_other = 1` and
   `IN_WORKTREE = 0`)).
2. In the `other-checkout)` arm of the refusal case (~line 857): three
   reasons now, one line each:
   - codex, gone: unchanged text.
   - codex, exists: unchanged text.
   - claude, exists, worktree: `a roost hook there points at another copy of roost, <detail>, and this checkout is a git worktree — run roost install from that copy, or from the primary checkout`.
3. The write report for Claude: where KEPT/REPLACED are printed, when
   `json_other = 1` and the path exists, add one line after it, verbatim:
   `  replaced a hook from another copy of roost, <dir> — if you did not mean to keep two, remove that copy and its PATH line.`
4. Tests, beside the existing Claude `other-checkout` cases in
   `tests/test-adapter-install.sh` (search `other-checkout` there; there is a
   gone-checkout repair case to copy):
   - plain checkout, Claude `settings.json` holding a roost hook that names an
     existing second checkout's `scripts/roost-agent-state` → `install --yes`
     rewrites it to this checkout's path; output has `replaced a hook from
     another copy of roost`.
   - same from the temp worktree of Task 3 → refused with `this checkout is a
     git worktree`; file byte-identical.
   - codex `hooks.json` naming an existing second checkout → still refused,
     byte-identical, the existing reason text (control).

**Check:** `bash tests/test-adapter-install.sh` → all `PASS:`.
**Commit:** `install: a Claude hook from another live copy of roost is replaced from a plain checkout, refused from a worktree`

## Task 5 — `validate`'s offer predicts the relink

**Files:** `scripts/roost-validate`, `tests/test-validate-install.sh`
**Depends on:** Task 3

**Do:**
1. In `offer_adapter_install` (~line 1101), the `case` on
   `roost_adapter_state` files `foreign|dangling` under `BLOCKED_LINKS`. Add
   `other-checkout)`: when `roost_checkout_is_worktree` is false, treat it
   as the offerable case (the same branch `missing` takes, so the offer says
   it will link it); when true, file under `BLOCKED_LINKS`. Keep the comment
   style: say why in two lines, pointing at Task 3's rule in
   `scripts/roost-install`.
2. In `h_adapter_fix` (~line 1012), an `other-checkout` path prints the same
   `rm "<P>" && ln -s "<WANT>" "<P>"` line doctor prints (Task 2).
3. Tests in `tests/test-validate-install.sh`: plant an other-checkout link
   (second checkout as in Task 1) → the offer text lists it as a link the
   run will make; from a temp worktree → listed under the blocked links with
   the `rm && ln -s` fix. Stranger control: blocked, unchanged.

**Check:** `bash tests/test-validate-install.sh` → all `PASS:`.
**Commit:** `validate: the offer predicts what install now does with a link to another copy of roost`

## Task 6 — `scripts/roost-upgrade`: the gate, the pull, the exec

**Files:** new `scripts/roost-upgrade`, new `tests/test-upgrade.sh`
**Depends on:** Task 1

**Do:**
1. Write `scripts/roost-upgrade` (bash, `set -euo pipefail`). `HERE` is the
   checkout root, resolved from `BASH_SOURCE` the way `scripts/roost-install`
   does. Source `scripts/lib/roost-adapters.sh` for
   `roost_checkout_is_worktree`. Flags: everything is passed through to the
   installer untouched; the script itself reads none, except `-h|--help`,
   which prints:
   ```
   usage: roost upgrade [-y|--yes] [--dry-run] [--only H[,H...]]
     Pull new roost code into this checkout (git pull --ff-only), re-apply
     wiring on a running server, then run roost install with the flags given.
     Refused when this checkout is not a plain `main` with no local work.
   ```
2. The gate, in this order, each a function returning the reason text or
   nothing. The first reason stops the run: print
   `roost upgrade: refused — <reason>` on stderr, then the fallback, then
   `exit 1`. Reasons, verbatim:
   | reason | test |
   |---|---|
   | `git is not on PATH` | `command -v git` |
   | `<HERE> is not a git checkout` | `git -C "$HERE" rev-parse --is-inside-work-tree` |
   | `<HERE> is a git worktree` | `roost_checkout_is_worktree "$HERE"` |
   | `<HERE> is on branch <b>, not main` (or `is on a detached HEAD`) | `git -C "$HERE" symbolic-ref --short -q HEAD` |
   | `main has no upstream to pull from` | `git -C "$HERE" rev-parse --abbrev-ref '@{upstream}'` |
   | `<HERE> has <n> local commit(s) on main that are not on <upstream>` | `git -C "$HERE" rev-list --count '@{upstream}..HEAD'` ≠ 0 |
   | `<HERE> has uncommitted changes to tracked files` | `git -C "$HERE" status --porcelain --untracked-files=no` non-empty |
   The fallback is two lines on stderr: for the worktree, branch, local
   commits and uncommitted reasons,
   `  This looks like a working copy. Sort it out by hand, or install a plain copy with:`;
   for the others, `  To install or reinstall roost:`; then always
   `  curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh`.
3. Before the pull, print one line to stdout:
   `roost: upgrading <HERE> from <short sha> (<VERSION>) — <n> commit(s) behind <upstream>`
   where n is `git rev-list --count 'HEAD..@{upstream}'` and VERSION is the
   `VERSION` file's content; when n is 0 the tail is `— already current with
   <upstream>`. No fetch happens before this line: it reads what git knew.
4. Pull: `git -C "$HERE" pull --ff-only --quiet`. On failure print
   `roost upgrade: git pull --ff-only failed — nothing was wired` on stderr
   after git's own output and `exit 1`.
5. Wiring: a stub for Task 7 — a function `reapply_wiring` that does nothing
   yet, called here, with a one-line comment naming Task 7.
6. `exec "$HERE/scripts/roost-install" "$@"` — the installer the pull just
   fetched. Comment why it is an exec of the path, not of a function.
7. `tests/test-upgrade.sh` (canary block). Build in `$TMP`: a bare repo
   `origin.git`; a `seed` clone with `bin/`, `scripts/`, `tmux/roost.conf`,
   `VERSION`, and a **fake** `scripts/roost-install` that appends its argv
   and the string `installer-v1` to `$TMP/installer.log`; commit, push to
   `origin.git` as `main`. Then `clone` = `git clone origin.git clone`. Copy
   the real `scripts/roost-upgrade` and `scripts/lib/` into `clone` and
   commit+push so they are "the code". Each case runs
   `bash "$clone/scripts/roost-upgrade" --yes` and asserts stdout/stderr/rc,
   `git -C clone rev-parse HEAD`, and `installer.log`:
   - **behind by one**: push a commit to `origin.git` from `seed` whose fake
     installer prints `installer-v2` → rc 0, HEAD = that commit, log ends
     with `installer-v2 --yes` (the NEW installer ran, with the flag).
   - **current** → rc 0, line says `already current`, log gained a line.
   - **each refusal**, one planted case: a `git worktree add` of clone; a
     branch checked out; detached HEAD; `git branch --unset-upstream`; one
     local commit; `echo x >> VERSION` → rc 1, the verbatim reason on stderr,
     the curl line on stderr, `installer.log` unchanged, and
     `FETCH_HEAD`'s mtime (stat) unchanged (no network). Reset the clone
     between cases.
   - **untracked file** in clone → not refused.
   - **pull fails**: push a commit adding `newfile`, create untracked
     `clone/newfile` → rc 1, `nothing was wired`, log unchanged.
   - `--dry-run` passes through: with a behind-by-one remote, rc 0, HEAD
     moved, log has `--dry-run` (the pull is not dry; assert that so the help
     text cannot promise otherwise).
   Use `git -c user.name=t -c user.email=t@t` for every commit in the test,
   and `GIT_CONFIG_GLOBAL=/dev/null` so the author's config is never read.

**Check:** `bash tests/test-upgrade.sh` → all `PASS:`, canary empty.
**Commit:** `roost upgrade: pull with --ff-only and run the installer the pull fetched, or refuse and say why`

## Task 7 — `upgrade` re-applies wiring on a running server

**Files:** `scripts/roost-upgrade`, `tests/test-upgrade.sh`
**Depends on:** Task 6

**Do:**
1. Fill `reapply_wiring`: the socket is `${ROOST_SOCKET:-roost}` as
   `bin/roost` resolves it (read how `SOCKET` is computed there and reuse the
   same default; if `ROOST_SOCKET` names a path, pass it through unchanged).
   If `tmux -L "$sock" list-sessions >/dev/null 2>&1` (or `-S` for a path)
   succeeds, run `ROOST_SOCKET="$sock" "$HERE/scripts/roost-wiring" apply`
   and print `roost: wiring re-applied on the running server` on success, or
   `roost: wiring could not be re-applied (roost doctor says more)` on
   failure, never fatal. No server → print nothing. This runs AFTER the pull,
   so it is the new checkout's `roost-wiring`.
2. Test, in `tests/test-upgrade.sh`, with the clone of Task 6 plus a
   throwaway server: `XDG_CONFIG_HOME` is already redirected; start
   `tmux -L "upg-test-$$" -f /dev/null new-session -d` and, so the server
   looks like roost's, run the clone's `scripts/roost-wiring apply` once with
   a 1.x `opencode` shim on PATH (`make_versioned_shim '1.18.30' opencode`,
   copied from `tests/test-adapter-install.sh`) → assert
   `tmux -L ... show-environment -g OPENCODE_CONFIG_DIR` names roost's
   wiring folder. Then swap PATH to a 2.x shim (`opencode v2.0.20`), run
   `ROOST_SOCKET="upg-test-$$" bash "$clone/scripts/roost-upgrade" --yes`
   (behind by one, as before) → stdout has `wiring re-applied`, and
   `show-environment -g OPENCODE_CONFIG_DIR` now reports it unset
   (`-OPENCODE_CONFIG_DIR`). Control: with no server on that socket (kill it
   with `tmux -L "upg-test-$$" kill-server`), the same run exits 0 and prints
   no `wiring` line. `trap` the kill on EXIT as well.

**Check:** `bash tests/test-upgrade.sh` → all `PASS:`; `tmux -L upg-test-*`
servers gone after.
**Commit:** `roost upgrade: re-apply wiring on a running server, so opencode 2 needs no second step`

## Task 8 — `bin/roost upgrade`, `update` as its alias, and the help line

**Files:** `bin/roost`, `tests/test-adapter-install.sh`, `tests/test-upgrade.sh`
**Depends on:** Task 6

**Do:**
1. In `bin/roost`: the `install|update)` arm (~line 632) becomes `install)`.
   Add `upgrade|update)` beside it: `shift; exec "$ROOST_HOME/scripts/roost-upgrade" "$@"`.
   Rewrite the arm's comment: `update` is an alias of `upgrade` now, and why
   (it always sounded like it pulled). Help lines (~43–44):
   ```
   #   roost install            wire every installed agent (opencode, pi, copilot, claude, codex) to this checkout; never fetches code
   #   roost upgrade            pull new roost code into this checkout (fast-forward only), then wire every agent to it; refused on a dev tree
   #   roost update             the same as `upgrade`
   ```
   Add `upgrade` to the usage string (~line 3612) and to `roost help`'s
   output wherever `update` appears.
2. `tests/test-adapter-install.sh` #17 (~line 1731–1790) pins `install` and
   `update --dry-run` byte-for-byte. Change it: `update --dry-run` and
   `upgrade --dry-run` are compared instead, run from a box that is NOT a
   git checkout, so both are refused identically (rc 1, same stderr), which
   pins the alias without a network. Keep the identity assertion's comment
   style (it explains why identity, not `contains`).
3. `tests/test-upgrade.sh`: one case through `bin/roost upgrade --help` and
   `bin/roost update --help` → identical stdout, rc 0.

**Check:** `bash tests/test-adapter-install.sh` and `bash tests/test-upgrade.sh`
→ all `PASS:`. `bin/roost help | grep -c upgrade` ≥ 1.
**Commit:** `roost update means roost upgrade now; install stays the command that never fetches`

## Task 9 — the installer's "behind" note, README, Getting Started

**Files:** `scripts/roost-install`, `README.md`, `site/content/docs/getting-started.md`
**Depends on:** Task 8

**Do:**
1. `upstream_note` in `scripts/roost-install` (~line 576–600): the last two
   lines become
   `  roost install wires harnesses to this checkout; it does not update roost`
   `  itself, and it has not fetched — this is what git already knew locally.`
   `  To update the code:  roost upgrade`
   and its comment paragraph names `roost upgrade` as the command that does
   pull, with the gate as the reason it is safe.
2. `README.md` `## Upgrading` (line 148 on) and the two lines that say
   `roost update` is an alias of `install` (111, 196, 281): the curl line
   stays first ("works on a machine with or without roost"); then a new
   paragraph: on a machine that has roost, `roost upgrade` does the same in
   one command, and lists the four refusals in one sentence each with the
   curl line as the fallback. `roost update` is described as the same as
   `upgrade`. Line 196's bullet becomes "**`roost install` does not fetch.**
   `roost upgrade` does."
3. `site/content/docs/getting-started.md`: the same change to its
   `## Upgrading` (line 170 on), line 116 (`roost update # the same thing`
   → under `roost upgrade`), and the bullet at 232.
4. No new claims. Copy the refusal wording from Task 6's table.

**Check:** `grep -n "roost update" README.md site/content/docs/getting-started.md`
shows only lines that call it the same as `upgrade`;
`bash tests/test-adapter-install.sh` still passes (it greps `upstream_note`'s
text — search for `To update the code` there and update that assertion).
**Commit:** `docs: roost upgrade is how a machine that has roost gets the next release`

## Task 10 — changelog and known gaps

**Files:** `CHANGELOG.md`, `site/content/docs/changelog.md`, `docs/known-gaps.md`
**Depends on:** Tasks 2, 4, 5, 7, 9

**Do:**
1. `CHANGELOG.md` under `## [Unreleased]`:
   - `### Added` — **`roost upgrade`: pull new roost code and wire every agent
     to it, in one command.** What it does (pull `--ff-only`, re-apply wiring
     on a running server, run the installer it fetched), the refusals in one
     sentence, the curl line as the fallback, and `roost update` now meaning
     it. The one thing to know: a dev tree is refused by design.
   - `### Changed` — **A link to another copy of roost is roost's to fix.**
     The new state, what `install` does from a plain checkout and from a
     worktree, that `foreign` is still never touched and codex never rewritten,
     and the Claude hook extension.
   - `### Fixed` — **`roost doctor` prints the command when a plugin link is
     not this install.** Name the opencode 2 line that had no command.
2. `cd site && node scripts/sync-changelog.mjs`.
3. `docs/known-gaps.md` under `## Small deferred items`: no bound on
   `upgrade`'s pull (same as `install.sh`); `upgrade` reads `main` literally,
   not `origin/HEAD`; a shell opened before the upgrade keeps
   `OPENCODE_CONFIG_DIR` and only `doctor` can say so.

**Check:** `diff <(sed -n '/^## \[Unreleased\]/,$p' CHANGELOG.md) <(sed -n '/^## \[Unreleased\]/,$p' site/content/docs/changelog.md)`
prints nothing; `bash scripts/roost-release-gate check .` exits 0.
**Commit:** `changelog: roost upgrade, and a link that names another copy of roost`

## Task 11 — the whole suite, here and in an Ubuntu container

**Files:** none (fixes found here become new commits on this branch)
**Depends on:** Task 10

**Do:**
1. `bash tests/run.sh` on this machine → record the FAIL lines (expect none).
2. Export the branch: `git archive --format=tar HEAD | (mkdir -p "$TMP/ex" && tar -x -C "$TMP/ex")`
   (a worktree mount fails 17 ext tests because `.git` is a pointer — export,
   do not mount). Do the same for `origin/main` into `$TMP/base`.
3. Run both in `ubuntu:24.04` with
   `apt-get install -y tmux git jq python3 bash locales` and
   `LANG=C.UTF-8`, as `bash tests/run.sh`, capturing FAIL lines from each.
4. `diff` the branch's FAIL lines against the base's. The base fails some on
   its own; only NEW lines count. Fix any, one commit each, re-run.

**Check:** the diff of FAIL lines is empty; this machine's `tests/run.sh`
prints no `FAIL:`.
**Commit:** none unless a fix was needed (then: `tests: <what> on Ubuntu`).

## Deferred checks — one pass at the end

1. **Task 7 — human-eye, on the author's machine, after the pull request
   merges.** From a terminal that is not a roost pane, in the primary
   checkout on `main` with no local commits: `roost upgrade`. Expect the
   `upgrading ... from <sha>` line, `wiring re-applied on the running server`,
   the installer's summary, then `roost doctor` reading the new version with
   every link `ok` and no `OPENCODE_CONFIG_DIR` warning in a fresh pane.

## Self-review

- Each task names its files, its message texts, and a runnable Check.
- Tasks 2, 3, 4, 5 and 6 all depend on Task 1 and otherwise only on each
  other as listed; 2 and 6 may run in either order after 1, but one writer at
  a time still holds.
- Task 3 is the largest; it is one change (the relink rule) across the three
  places install already handles `relink`, so it stays one task. If an
  implementer finds the write-time re-check and the summary need more than
  the lines named, split the summary (steps 6–7) into its own commit.
- Nothing here runs `roost install` or `roost upgrade` against the real home.
