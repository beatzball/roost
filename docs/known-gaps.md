# Known gaps and follow-ups

Risks carried by what has shipped, and why each was left rather than fixed.
Not a wish list — the spec's "Out of scope" sections cover future work. This
file covers things that are already live and could surprise you.

The section headings carry the severity, so read them first. **Behaviour
changes** are things to know about, not defects. **Live risks** are the ones
that can actually bite. Each entry says plainly which it is — an entry that
reads like an alarm when it is merely a note is a bug in this file.

Keep it short. When an entry is fixed, delete it.

## Live risks

### A copilot pane can be badge-less, and nothing says so

`adapters/copilot/extension.mjs` only runs once **two** gates are past, and
neither one announces itself when it is not:

1. Copilot's extension system is behind a feature flag that is off by default.
   Without `copilot --experimental` or `{"enabledFeatureFlags":
   {"EXTENSIONS": true}}` in `~/.copilot/settings.json`, copilot does not read
   the first line of the adapter.
2. In interactive mode copilot asks the human, **once per directory**, to
   approve the extension — *"wants to: handle permission requests"*. Denying it
   prevents the extension loading. There is no global pre-approval, so every new
   worktree asks again.

In both cases the turn runs normally and copilot prints nothing about having
skipped anything. The pane simply stays unstamped, which roost renders exactly
like a shell.

**What that costs, precisely.** It is not only a missing badge. `roost send`
refuses a `blocked` target with exit 3 so that one agent cannot type into
another's permission dialog — and an unbadged pane is not blocked, so the
refusal never fires. A copilot pane whose extension never loaded, sitting at a
permission prompt, will take a `roost send` straight into that dialog and press
Enter on whatever is highlighted.

**Why it shipped anyway.** Both gates are copilot's, not roost's, and neither
can be worked around from this side: the feature flag is a preview switch in the
user's own config, and the consent is a TUI answer that persists nothing unless
the human picks "always allow in this directory". `roost doctor` does what can
be done — it reads `settings.json` for the flag and prints the exact fix, and it
states the consent gate rather than inferring an answer to it (`AGENTS.md` §9,
and the same discipline the adapter contract's T6 sets out). The install stanza
in `site/content/docs/state-badges.md` names both before a user trusts the badge.

## Behaviour changes

### `bin/roost` now addresses the roost server you are inside

With `ROOST_SOCKET` unset, every `roost` subcommand used to address the shared
`-L roost` server no matter which server the caller's own pane was on. It now
resolves in three steps — `ROOST_SOCKET`, then the server it is running inside,
then `-L roost` — the same order `roost-status`, `roost-switch` and
`roost-notify` already used, via `scripts/lib/roost-socket.sh`.

**This is the fix for a live risk, not a new one.** It is what makes `roost
reply` land on a non-default server, where the badge already did.

Only a socket path ending in `/roost` counts as "inside roost", so `roost
spawn` typed from a user's everyday tmux still means the roost server. Nothing
changes for the default single-server install: `-L roost` resolves to a path
ending in `/roost`, so both steps name the same server.

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

## Process lessons

### Blast radius enumerated from memory misses consumers

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

### A fixture that stops where the feature does proves nothing (#12, #14)

`#12` shipped the opencode reply channel, and it published nothing on **any**
turn — not an edge case, every agent, straight back to `roost read` scraping the
screen. It sat on `main` through `#13` before anyone noticed.

The suite did not merely miss it. It could not see it:

```
tests/opencode-plugin-harness.mjs against the BROKEN adapter -> 44 passed, 0 failed
tests/opencode-plugin-harness.mjs against the FIXED  adapter -> 44 passed, 0 failed
```

Identical. 529 assertions green across the repo, feature dead.

The fixtures were built from a real recorded opencode turn, which is the right
instinct — and they were trimmed to the events the feature reads: the assistant
`message.updated`, its text parts, then `session.idle`. The live stream does not
stop there. opencode **re-announces** the assistant message twice *after* the
text parts, and the handler cleared the collected reply on every announcement,
so it was wiped a moment before the line that would have published it. The two
events that broke it were the two the fixture left out, because at fixture-writing
time they looked like noise after the interesting part.

Only the live two-pane check found it, and only after the merge.

**Two rules, both cheap:**

- A fixture derived from a recording replays the **whole recorded turn**, in
  order, trailing events included. Trimming a recording to the events you
  believe matter encodes the belief you are trying to test. Keep the recorded
  log line numbers in a comment so the next reader can check the fixture against
  the capture rather than against the code.
- A regression test is **run against the unfixed code first**, and its failure
  output goes in the pull request. A test written after the fix, that has never
  been seen red, is an assertion that the code does what it does. `#14` does
  this: five fixtures, 5 failed before the one-line change, 0 after.

The wider point is the one the entry above already makes in a different key:
green is evidence about the tests, not about the feature. When a mechanism has
never been exercised end to end outside its own harness, say so plainly at
review time rather than reading the count as coverage.
