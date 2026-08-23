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

## Small deferred items

- A `roost.conf` produced by the legacy migration **before** it learned to
  backfill `@roost-glyph-error` still predates the error state, and migration
  cannot re-fire on it (it only runs while `roost.conf` is absent — an
  existing one always wins, because a running amux server may still be reading
  the old file). Nothing writes that value on their behalf. `roost doctor` now
  names the missing line, the glyph being inherited, and the exact fix
  (`roost settings`, re-pick the set), which is as far as a read-only check
  goes.
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
