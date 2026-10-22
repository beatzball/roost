# `roost upgrade`, and a link that points at another copy of roost

Date: 2026-10-22
Size: Build — one new verb, and a change to a rule that `install` and `doctor`
share.
Oracle: automated, with one human-eye check at the end (§5).
Decided in chat on 2026-10-22, the day 0.7.0 was cut (#170). Nothing here is
built.

## 0. The short answer

`roost upgrade` fetches new roost code and wires every agent to it: the thing
`roost update` has always sounded like and never was. It runs
`git pull --ff-only` in this checkout and then this checkout's own installer,
the same two steps `install.sh` takes on a machine that already has roost. It
refuses — and prints the `curl | sh` line instead — when this checkout is not
a plain `main` with no local work, because the checkout may be somebody's dev
tree, and that rule does not move. `roost update` becomes an alias of
`upgrade`. `roost install` stays what it is: wire, never fetch.

The second half is about one message. A user with roost at `~/w/roost` ran
`roost doctor` and read:

```
! opencode 2 plugin at ~/.config/opencode/plugins/roost is not this install — relink it to ~/w/roost/adapters/opencode/v2
```

No command, and `roost install` refuses the same link as `foreign`. The link
almost certainly points at a *second* copy of roost — the clone `install.sh`
makes at `~/.local/share/roost` beside the one the user cloned by hand, the
two-copies trap the Getting Started page already warns about. That is roost's
own link, not a stranger's plugin, and roost can tell: its target path ends in
a roost adapter path. `install` and `doctor` learn to say so. `doctor` prints
the exact command. `install` relinks it — except when `install` is itself
running from a git worktree, which is how this machine's test panes run, and
where stealing the live links would leave them dangling the moment the
worktree is removed.

## 1. What was settled before this document

- **`roost install` never fetches.** The comment above `upstream_note` in
  `scripts/roost-install` gives the two reasons: the checkout may be a dev tree
  with local work, and an installer must not make a surprise network call —
  on a metered link, behind a proxy, or in a CI step with no credentials.
  `upgrade` is asked for by name, so the network call is not a surprise. The
  dev-tree rule stays, as a refusal.
- **`install.sh` on an existing clone** does three things: `git pull
  --ff-only` in the clone, skip the `PATH` line it added the first time, and
  run `roost install --yes` by absolute path. `upgrade` is those steps minus
  the `PATH` one, run from inside roost.
- **A link to a checkout that still exists belongs to someone who meant it.**
  That is the rule `install` applies to every symlink adapter (opencode,
  opencode 2, copilot, pi) and to the Claude and codex hooks. For the hooks
  the installer already tells `other-checkout` apart from `ours`, and for
  Claude it already repairs a hook whose checkout is *gone*. The symlink
  adapters collapse every other target into `foreign`, and `dangling` is the
  only case they repair. `roost_adapter_names_1x` in
  `scripts/lib/roost-adapters.sh` is the one place that already reads a link's
  own text to decide whose it was.
- **Codex is never rewritten.** It hashes each hook handler and silently skips
  one whose hash changed, so a rewrite un-badges a machine that had granted
  trust. Unchanged here.
- **Tests never touch the real config.** Every test that installs redirects
  `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `COPILOT_HOME` and `CODEX_HOME`
  to a temp directory (`tests/test-install.sh` is the pattern). A throwaway
  roost socket alone is not isolation; that was measured once and is in
  memory.
- **Chat decisions, 2026-10-22.** Option 1 three times: `update` becomes an
  alias of `upgrade`; `install` relinks a link that names another roost
  checkout; and that relink is refused when `install` runs from a worktree.

## 2. `roost upgrade`

### 2.1 What it does

```
roost upgrade [-y|--yes] [--dry-run] [--only H[,H...]]
roost update  ...            # the same command; one dispatch arm, as today
```

1. **Gate.** Every refusal in §2.2 is checked before anything touches the
   network. A refusal exits 1, prints one line saying which rule, and prints
   the `curl` line from the README as the thing to run instead — or, for the
   two rules where `curl | sh` would hit the same wall (a dev tree; cannot
   fast-forward), says to sort the checkout out by hand.
2. **Pull.** `git -C "$ROOST_HOME" pull --ff-only --quiet`. A pull that fails
   (no network, a fast-forward git refuses because an untracked file would be
   overwritten) exits 1 with git's own last line, and nothing is wired:
   wiring the old code after a failed pull would print "upgraded" over a
   machine that was not.
3. **Wire.** `exec "$ROOST_HOME/scripts/roost-install" "$@"` — the installer
   *the pull just fetched*, not the one that started the command, so a release
   that adds an adapter wires it in the same run. The flags pass straight
   through: `--yes` for an unattended run, `--dry-run`, `--only`. The exit
   status is the installer's.
4. **Re-apply wiring on a running server.** Before the `exec`, if a roost
   server is running on the default socket, `scripts/roost-wiring apply`
   runs against it, as `ensure_session` does at server start. It is
   idempotent. This is what makes the opencode 2 story one command: a server
   started before the upgrade still exports `OPENCODE_CONFIG_DIR` to every new
   pane, and `apply` is the step that unsets roost's own value when the
   opencode on `PATH` is 2.x (#154). Without it the changelog's "run `roost
   wiring on` once" stays a second step. A server that is not running is
   skipped silently; it applies wiring when it starts. What no command can do
   is reach a shell that is already open: it keeps the environment it was
   given, so an opencode pane opened before the upgrade still needs `unset
   OPENCODE_CONFIG_DIR`, or a new pane. `doctor` already says so, per pane.

Before the pull, one line says what will happen, with the two commits:

```
roost: upgrading /home/u/.local/share/roost from 785442c (0.7.0) — 3 commits behind origin/main
```

Already current is not a refusal: the line says so, and the installer still
runs, because the user asked to be wired to current code and may be. The
`upstream_note` that `install` prints when it can see the checkout is behind
changes its last line from `git -C ... pull` to `roost upgrade`.

### 2.2 The refusals

Checked in this order; the first that holds is the one named.

| rule | how it is read | why |
|---|---|---|
| not a git checkout | `git rev-parse --is-inside-work-tree` fails | a tarball install has nothing to pull; the curl line reinstalls it |
| no git on `PATH` | `command -v git` | same |
| a worktree | `git rev-parse --git-common-dir` and `--git-dir`, made absolute, differ | a worktree is on a branch by construction, and is somebody's working tree; see §3.3 |
| not on `main` | `git symbolic-ref --short HEAD` is not `main` (detached HEAD counts) | a branch is a dev tree |
| no upstream | `git rev-parse --abbrev-ref @{upstream}` fails | nothing to pull from |
| local commits | `git rev-list --count @{upstream}..HEAD` is not 0 | a dev tree, even on `main`; `--ff-only` would refuse anyway, but this says *why* before the network is touched |
| tracked changes | `git status --porcelain --untracked-files=no` is not empty | work that a pull could collide with |

Untracked files are not a refusal. `pull --ff-only` tolerates them, and the
primary checkout on the author's machine has one (`roost-validation-*.md`)
that must not make `upgrade` refuse. If git refuses the pull because an
untracked file would be overwritten, that is step 2's failure path, named by
git.

`main` is literal, not read from `origin/HEAD`. roost's default branch is
`main` on the one remote it is published from, and reading `origin/HEAD` adds
a network-free but not failure-free lookup for no case that exists.

### 2.3 Where it lives

A new `upgrade|update` arm in `bin/roost` beside `install`, which shrinks to
`install` alone. The gate and the pull go in `scripts/roost-upgrade`, so
`tests/test-upgrade.sh` can run them against a throwaway clone, and so
`bin/roost` keeps its arm to a `shift` and an `exec`. The worktree test (§3.3)
is one function in `scripts/lib/roost-adapters.sh`, because `install` needs
the same answer.

`roost help`, the usage line in `bin/roost`, README `Upgrading`,
`site/content/docs/getting-started.md` `Upgrading`, and the `update` help line
("it does not pull new code") all change. The README and Getting Started keep
the curl line as the first thing shown — it is still the only line that works
on a machine with no roost — and add `roost upgrade` as the line for a machine
that has one.

## 3. A link that names another copy of roost

### 3.1 A fifth state

`roost_adapter_state` reports `ok`, `missing`, `dangling`, `foreign`, `none`.
It gains **`other-checkout`**: the path is a symlink, its target exists, the
target is not this checkout's adapter, and the link's own text ends in a roost
adapter path for that harness — `*/adapters/opencode/roost.js`,
`*/adapters/opencode/v2`, `*/adapters/copilot/extension.mjs`,
`*/adapters/pi/roost.ts`, the same tails `roost_adapter_target` prints. The
test is on the link's text, as `roost_adapter_names_1x` already does, not on
the resolved path: a target under a moved or symlinked home still names the
adapter. `foreign` keeps its meaning — something else entirely — and stays
refused everywhere.

The name is the hook probe's, so `install`'s report uses one word for one
situation across the symlink adapters and the Claude hook.

### 3.2 What each command does with it

| command | `other-checkout` | `foreign` (unchanged) |
|---|---|---|
| `doctor` | `! opencode 2 plugin at P points at another copy of roost, OLD — run: roost install, or: rm "P" && ln -s "WANT" "P"` | `! ... is not this install — relink it to WANT` keeps its text, and gains the same `rm && ln -s` tail, because "relink it to" with no command is the line that started this |
| `install`, from a plain checkout | listed under the writes as `relink opencode2 P (was OLD)`, asked for with the rest in a terminal, done under `--yes`; `record_outcome relink` with the old target as the undo | refused, as today |
| `install`, from a worktree (§3.3) | refused: `a link there points at another copy of roost, OLD, and this is a worktree — run roost install from that copy, or from the primary checkout` | refused, as today |
| `validate` | its offer predicts what `install` will do, through the same state, so it says `will relink` from a plain checkout and `will leave` from a worktree | unchanged |

Where `install` relinks, the summary's last lines say what the old target
was and what it implies:

```
relinked opencode2: ~/.config/opencode/plugins/roost
  was ~/.local/share/roost/adapters/opencode/v2 — a second copy of roost.
  If you did not mean to keep two, remove that directory and the PATH line
  install.sh added for it.
```

That is the whole of "say when two checkouts exist": roost does not scan the
disk for copies of itself, it names the one it was just pointed at.

**The Claude hook** gets the same extension of the rule it already has:
`other-checkout` whose checkout is *gone* is repaired today; `other-checkout`
whose checkout *exists* is repaired too, from a plain checkout, and refused
from a worktree with the same reason. The refusal text for a worktree is one
line, because the record is newline-separated. **Codex** keeps every refusal
it has, and its `other-checkout` reason gains nothing new.

### 3.3 The worktree rule

`roost_checkout_is_worktree` — true when `git rev-parse --git-common-dir` and
`git rev-parse --git-dir`, each made absolute against the checkout, name
different directories. In the primary checkout both are `.git`; in a worktree
`--git-dir` is `<primary>/.git/worktrees/<name>`. A checkout that is not a git
repository at all is not a worktree. The answer is read once per run.

Why this is the rule and not, say, "never relink a link whose target still
exists": the machine this is developed on runs its live `-L roost` server from
the primary checkout, and every build and test pane runs from a worktree
under `.claude/worktrees/`. Those panes run `roost install --yes` — sometimes
on purpose, sometimes because a subagent read the docs. Today the `foreign`
refusal is what keeps the live links on the primary; with §3.2 and no worktree
rule, the first such run would steal them, and the worktree is removed after
its merge. Earlier on 2026-10-22, `doctor` from the release worktree reported
both the opencode 2 plugin and the Claude hook as "not this install": that is
the refusal doing its job, and this rule keeps it doing it.

`upgrade` from a worktree is refused by §2.2 before this matters.

## 4. Not changed, on purpose

- `install.sh` keeps its own `git pull --ff-only`: it has to work on a machine
  with no `roost` on `PATH`, and it must not depend on the verb it is about to
  install. After this change its "already cloned" branch could call `roost
  upgrade`; it does not, because the checkout it found may be older than this
  design.
- No bound on the pull. `install.sh` has none either. A fetch that hangs on a
  dead network hangs `upgrade`; the user sees git's own output. Recorded in
  `docs/known-gaps.md`.
- No fetch in `doctor`. `doctor` says "behind" only from what git knew at the
  last fetch, as `install` does, and now names `roost upgrade` as the fix.
- `foreign` is still never touched.

## 5. Tests — the oracle

All automated except the last line. Every test exports the five home
variables to a temp directory before it does anything, and asserts at the end
that the real `~/.config` was not written (a canary file's mtime).

**`tests/test-upgrade.sh`**, against a bare repository in the temp directory
and a clone of it, with a fake `scripts/roost-install` in the clone that
records its argv:

- behind by one planted commit → exit 0, `HEAD` moved to it, the installer ran
  with the flags given, and it was the installer *from the new commit* (the
  planted commit changes the fake's output)
- already current → exit 0, the installer ran, the line says current
- each §2.2 rule, one planted case each: worktree of the clone; a branch;
  detached HEAD; no upstream; one local commit on `main`; one tracked
  modification → exit 1, the rule named, no fetch happened (the bare repo's
  reflog or a `pre-receive`-free check: the clone's `FETCH_HEAD` mtime is
  unchanged), the installer did not run
- an untracked file in the clone → not a refusal
- `pull` failure: the planted commit adds a file that exists untracked in the
  clone → exit 1, git's line, installer did not run
- `roost update` and `roost upgrade` reach the same script (argv recorded)
- wiring: with a throwaway server on its own socket and its own
  `XDG_CONFIG_HOME`, started with a fake `opencode` that prints `1.18.30`
  (so the server exports roost's `OPENCODE_CONFIG_DIR`), swap the fake to
  print `opencode v2.0.25`, run `upgrade` against that socket → the server's
  global `OPENCODE_CONFIG_DIR` is unset after; the control, with no server
  running, exits 0 and prints no wiring line
- `--dry-run` passes through and nothing is pulled? **No**: `--dry-run` is
  the installer's flag; the pull still happens. The test asserts that, so the
  help text cannot promise otherwise.

**`tests/test-adapter-install.sh`** gains, for each of the four symlink
adapters, a planted pair under one temp home:

- a link to a second temp checkout's adapter (made by copying this checkout's
  `adapters/` directory) → `other-checkout`; `install --yes` from the plain
  checkout relinks it, the record's undo field holds the old target, and the
  summary names the old checkout
- a link to a stranger's file (the control) → still `foreign`, still refused,
  and the file is byte-identical after the run

**`tests/test-doctor.sh`** gains the `other-checkout` line for opencode 2 and
asserts the `rm "..." && ln -s "..." "..."` tail is present and quotes both
paths; and that the `foreign` line now carries the same tail.

**The worktree rule**, in `tests/test-adapter-install.sh`: the same planted
pair, with `install --yes` run from a `git worktree add` of the temp checkout
→ the `other-checkout` link is refused with the worktree reason and is
byte-identical after; the control is unchanged too. Then the same from the
temp checkout's primary → relinked. This is the control that proves the rule,
not the message.

**`tests/test-validate-install.sh`**: the offer says `will relink` and `will
leave` for the two placements above.

**CI** runs on Ubuntu with dash as `sh` and tmux 3.4; `scripts/roost-upgrade`
is bash like its siblings, and nothing here touches tmux. Run
`tests/run.sh` in the Ubuntu container before the pull request, and diff its
FAIL lines against a `main` control, because the container baseline fails 56
tests of its own.

**Human-eye, once, at the end:** on the author's machine, from a terminal
that is not a roost pane, `roost upgrade` on the primary checkout after a
real commit lands on `main`; then `roost doctor` reads the new version and
every link `ok`.

## 6. Changelog

Under Unreleased, Added: `roost upgrade`, with `update` now meaning it, and
the one thing to know — a dev tree is refused, and the curl line still works
everywhere. Under Changed: `install` and `doctor` and a link that names
another copy of roost, with the worktree exception. Under Fixed: the opencode
2 doctor line that gave no command.
