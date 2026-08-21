# Known gaps and follow-ups

Risks carried by what has shipped, and why each was left rather than fixed.
Not a wish list — the spec's "Out of scope" sections cover future work. This
file covers things that are already live and could surprise you.

The section headings carry the severity, so read them first. **Behaviour
changes** are things to know about, not defects. **Live risks** are the ones
that can actually bite. Each entry says plainly which it is — an entry that
reads like an alarm when it is merely a note is a bug in this file.

Keep it short. When an entry is fixed, delete it.

## Behaviour changes

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

Failing loudly is the safe direction. The unsafe direction is the subagent gap
below, which can return success *early*.

## Live risks

### An opencode subagent may briefly badge the pane `done`

`adapters/opencode/roost.js` does not filter events by `sessionID`. opencode's
event bus is process-global and every session event carries one; sessions have
a `parentID`, so child sessions exist (the task/subagent path). A child session
going idle mid-turn would stamp `done` on the pane while the parent is still
working, and reset the retry counter with it.

A false `done` is the worst wrong badge — it is the one that says "finished, go
look".

**Not fixed because it is unverified and the obvious guard fails in the wrong
direction.** The guard would be a set of active session IDs, reporting `done`
only when it empties. If `busy` does not fire per-session as assumed, the set
never empties, `done` never fires, and the pane sits on `working` forever —
which is exactly the failure this adapter already shipped once and had to fix.

**To close it:** drive an opencode turn that spawns a subagent, log every
event with its `sessionID`, and confirm the interleaving before writing the
guard. `tests/live/opencode-smoke.sh` drives a single-session turn only.

### opencode already has a retry counter we are duplicating

`adapters/opencode/roost.js` hand-rolls a consecutive-`retry` counter with
explicit reset rules. opencode 1.18.15's `SessionStatus` includes
`{type: "retry", attempt, message, next}` — `attempt` is upstream's own
per-session count, which upstream resets.

Reading `status.attempt >= RETRY_THRESHOLD` would delete the counter and every
reset rule with it, and would be immune to the whole class of bug that produced
those rules.

**Not done because it is an unverified change to the exact code path that
produced this adapter's one real bug.** Confirm `attempt` increments as
expected on a live dead-provider run first — that is case 2 of the live test.

## Upgrade wart

### A pre-existing config inherits the emoji error glyph

A user who picked `ascii` or `nerd` before the `error` state existed has four
glyph lines and no `@roost-glyph-error`, so they inherit the default 💥 — an
emoji in a bar they chose not to have emoji in, or a 2-cell glyph among 1-cell
ones. This now applies to `~/.config/roost/roost.conf` too, not just the old
`~/.config/amux/amux.conf`: `roost init`'s legacy migration
(`scripts/roost-init:37-53`) carries a pre-existing `amux.conf` over by
renaming `@amux-*` keys to `@roost-*` verbatim, so a config that predates the
error state still predates it after migration.

`roost doctor` warns and tells them to re-pick their glyph set in
`roost settings`, which writes all five.

**Deliberately not auto-backfilled, and the old reasoning for that no longer
applies.** It used to be that the natural place to backfill was
`scripts/amux-migrate-state`, which ran async via `run-shell -b` while
`bin/amux` sourced the user config afterwards, so a backfill there could
clobber a deliberate custom glyph depending on ordering. That whole mechanism
is gone — the script was deleted, its `if-shell` removed from the conf, and
`bin/roost` is now a small `exec` stub that sources nothing.

The current reason is simpler: nothing in the live code writes this value on
the user's behalf. `roost init`'s migration block is a pure key rename over
the old file's existing lines, not a value decision, so it never has the
information to invent a glyph the old config didn't have. And `roost doctor`
itself never writes config — its check is read-only and advisory, same as
every other check in the file — so filling the gap silently isn't its job
either; it only names the fix (`roost settings`) and leaves the choice to the
user.

The same four-glyph match means `roost doctor` will also warn at someone who
deliberately set a custom error glyph on an otherwise-standard set. The message
names a cause that may be false for them. It is a warning, not a failure.

## Small deferred items

- `scripts/roost-doctor`'s glyph-mismatch warning asserts a cause that can be
  wrong (see above).
- `tests/test-agent-state.sh` sizes its window with zero headroom: splits
  repeatedly halve the same pane, so `-y 2000` fits exactly the splits the file
  makes today and the next one added will fail. Asserting each split's pane id
  is non-empty is the durable fix — a failed split yields an empty id, and
  `show-options -t ""` then resolves to the *active* pane, so an assertion can
  pass for the wrong reason. That exact masking has already been found twice in
  this suite.
- `tests/test-error-state.sh` uses `case "$out" in E*)` to assert a prefix,
  which compares `ok` to `ok` on the pass path. An `assert_prefix` helper would
  read more directly.
- `tests/test-doctor.sh` and `tests/test-next-blocked.sh` are mode 644 while
  other test files are 755. Cosmetic — `tests/run.sh` invokes `bash "$t"`.
- `tests/test-doctor.sh` assigns `marker="$(mktemp)"` and never uses or removes
  it.

## Process lesson

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
