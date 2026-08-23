# Known gaps and follow-ups

Risks carried by what has shipped, and why each was left rather than fixed.
Not a wish list — the spec's "Out of scope" sections cover future work. This
file covers things that are already live and could surprise you.

The section headings carry the severity, so read them first. **Behaviour
changes** are things to know about, not defects. **Live risks** are the ones
that can actually bite. Each entry says plainly which it is — an entry that
reads like an alarm when it is merely a note is a bug in this file.

Keep it short. When an entry is fixed, delete it.

There is no **Live risks** section right now, and that absence is the point of
saying so: the section is missing because the last entry in it was fixed, not
because nobody has looked. Add the heading back with the first entry that
earns it.

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

Failing loudly is the safe direction. The unsafe direction is a wrong success,
and `wait-done` can only refuse one if nothing upstream of it reports a failed
turn as `done` in the first place — which is why `adapters/opencode/roost.js`
swallows the `session.idle` that follows a `session.error`.

### opencode counts retries too, and we still count our own

`adapters/opencode/roost.js` hand-rolls a consecutive-`retry` counter.
opencode's `SessionStatus` carries `{type: "retry", attempt, message, next}`,
and `attempt` is upstream's own count. Measured on 1.18.20, two dead-provider
turns in one TUI session (`tests/live/opencode-smoke.sh` case 2 prints this):

```
    turn ended: attempts [1, 2, 3, 4, 5]
    turn ended: attempts [1, 2, 3, 4, 5]
```

So `attempt` is per session, increments once per retry, and restarts at 1 in
the next turn — the same rule our counter follows.

**Left as it is, and the entry it replaces overstated the prize.** Reading
`status.attempt` would not delete the counter: the `busy` branch is gated on
the count so the badge cannot flap during a retry loop, and `busy` events carry
no `attempt`, so a local number and its turn-boundary resets have to stay
either way. The change is one line (`retries += 1` becomes `retries = attempt`)
in exchange for a dependency on upstream's numbering, in the one code path that
has already produced a real bug here.

## Small deferred items

- A `roost.conf` produced by the legacy migration **before** it learned to
  backfill `@roost-glyph-error` still predates the error state, and migration
  cannot re-fire on it (it only runs while `roost.conf` is absent — an
  existing one always wins, because a running amux server may still be reading
  the old file). Nothing writes that value on their behalf. `roost doctor` now
  names the missing line, the glyph being inherited, and the exact fix
  (`roost settings`, re-pick the set), which is as far as a read-only check
  goes.
- The executable bit on `tests/test-*.sh` is split with nothing distinguishing
  the two groups: 9 files at mode 644 and 15 at 755, measured with
  `git ls-files -s tests/test-*.sh | grep -c '^100644'` (and `100755`) at the
  commit that fixed `test-doctor.sh` and `test-next-blocked.sh`. Cosmetic —
  `tests/run.sh` invokes `bash "$t"`, so no test has ever needed the bit.
  Left alone rather than swept, because a `chmod` across nine files that other
  branches are editing collides for no benefit.

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
