# `amux send` false negative on silent commands

## Summary

`amux send TARGET TEXT` types text into a pane, presses Enter, then verifies
the text left the input line before reporting success. It was reporting exit
1 ("text typed into '%N' but never submitted") for messages that submitted
and ran fine — deterministically, not as a rare flake, whenever the command
stayed silent for about a second (`retries × delay`, ~0.9s by default).

Fix: add cursor position as a third conjunct to the existing "still pending"
check in `pending()` inside the `send)` branch, now `bin/roost:223`.

## Reproduction before the fix

On an isolated `-S` socket, sending four kinds of commands with default
`retries=3` / `delay=0.3` (≈0.9s verification window):

```
$ AMUX_SOCKET=.../sock ./bin/amux send %1 "true"
rc=0                                              # instant command: fine

$ AMUX_SOCKET=.../sock ./bin/amux send %1 "sleep 3"
amux send: text typed into '%1' but never submitted (tried 3 extra Enter(s))
rc=1                                              # FALSE NEGATIVE

$ tmux set-option -g @amux-send-enter-delay 2
$ AMUX_SOCKET=.../sock ./bin/amux send %1 "sleep 3"
rc=0                                              # window widened past 3s: fine

$ AMUX_SOCKET=.../sock ./bin/amux send %1 "echo starting; sleep 3"
rc=0                                              # early output keeps window "fresh": fine
```

Confirming the command still executed despite the reported failure — capturing
the pane after the `sleep 3` finished showed exactly one `took 3s` timing
marker in the prompt (proving single execution) but also three extra blank
prompts below it, one per spurious retry Enter fired while `pending()`
mistakenly believed the message was still stuck:

```
╰─ sleep 3
                                                    <- blank prompt (retry 1)
                                                    <- blank prompt (retry 2)
... took 3s ...
```

This matches the two harms described in the bug report exactly: a delivered
message reported as failed (inviting a caller to re-send and double-execute),
and spurious Enters fired into the pane during the retry loop.

## Root cause, verified

`pending()` (originally around `bin/amux:291`) decided "still pending" from
two signals: the pane's captured text byte-identical to a snapshot taken
after typing and before Enter (`$before`), and the last non-blank line still
containing the whole message. Neither signal can distinguish "the Enter was
never accepted" from "the Enter was accepted and the command hasn't printed
anything yet" — both look like an unchanged screen. The real discriminator
in the old code was accidental: whether the command emitted visible output
within `retries × delay`, which has nothing to do with whether the Enter was
accepted.

Measured directly (see reproduction above): the false negative is
deterministic once the command's silence exceeds the verification window,
regardless of load — widening the window (`delay=2`) or having the command
print something early both avoid it, confirming the window/silence
relationship is the actual mechanism, not scheduling noise.

## The fix

Cursor position is a reliable discriminator: the tty echoes the newline
through the line discipline the moment Enter is *accepted*, independent of
when (or whether) the command produces output. So a genuine submit moves the
cursor immediately even in dead silence, while a swallowed Enter (the pane's
program never reads/renders it) leaves the cursor exactly where it was.

Changes in `bin/amux` (`send)` branch):

1. Capture `#{cursor_x} #{cursor_y}` into `$cursor_before` via
   `display-message`, at the same point `$before` (the pane text snapshot)
   is captured — right before the first Enter is sent. Same call shape as
   the existing `#{window_id} #{pane_dead}` fetch a few lines above (a
   single `display-message -p` call, space-separated fields); the file's
   comment there explains why the separator must be a plain space and not a
   tab (a tab defeats the `${x%% *}` / `${x#* }` split downstream and lets a
   bad value through silently). This new value is never split — it's only
   ever compared for byte equality against a later snapshot taken the same
   way — so a wrong separator has nothing to silently break here, but the
   space is kept for consistency and readability.
2. In `pending()`, fetch `cursor_now` the same way and require
   `cursor_now = cursor_before` as a third conjunct alongside the existing
   text-unchanged and last-line-contains-message checks. Any of the three
   failing means "not pending" (i.e., treat as submitted).

This is an *additional* conjunct, not a replacement, by design: requiring
one more condition to hold only makes a false "not submitted" harder to
reach, never easier. The pending-in-comment tradeoff (a continuously
animating TUI never looks byte-identical, so the retry never fires for it,
even on a genuine swallow) is preserved and accepted for the same reason it
was accepted before: a false "submitted" degrades to old (still-safe)
behavior; a false "not submitted" is the one that causes damage (re-sends,
spurious Enters).

Verification after the fix, same four scenarios:

```
$ AMUX_SOCKET=.../sock ./bin/amux send %1 "true"        -> rc=0
$ AMUX_SOCKET=.../sock ./bin/amux send %1 "sleep 3"      -> rc=0   (was rc=1)
$ AMUX_SOCKET=.../sock ./bin/amux send %1 "sleep 3" (delay=2)  -> rc=0
$ AMUX_SOCKET=.../sock ./bin/amux send %1 "echo starting; sleep 3" -> rc=0
```

`sleep 3` now returns immediately (~0.5s, one send-keys round trip) instead
of waiting out the full retry loop and still failing; capturing the pane
afterward shows a single `took 3s` marker and no spurious blank-prompt
retries.

## The failing test and its negative control

Added to `tests/test-coordination.sh`, right before the existing
swallowed-Enter test:

```sh
T set-option -g @amux-send-enter-delay "0.1"
silent="$(T new-window -P -F '#{pane_id}' -n silent sh)"
sleep 0.3   # let the freshly-spawned sh settle to its prompt before typing
"$AMUX" send "$silent" "sh -c 'sleep 1.5; printf \"SILENT-MARK-%s\n\" DONE'"; rc=$?
assert_eq "$rc" "0" "send does not report false failure for a command silent past the retry window"
wait_for "$silent" 'SILENT-MARK-DONE' \
  && assert_eq ok ok "send: the silent command actually executed" \
  || assert_eq no-exec executed "send: the silent command actually executed"
sleep 0.5
out="$(T capture-pane -p -t "$silent")"
markcount="$(printf '%s\n' "$out" | grep -o 'SILENT-MARK-DONE' | wc -l | tr -d ' ')"
assert_eq "$markcount" "1" "send: the silent command executed exactly once (no double-run from a caller re-send)"
```

With `@amux-send-enter-delay=0.1` and the default `retries=3`, the
verification window is `0.3s`; the command stays silent for `1.5s` (5x the
window) before printing its marker, so the negative control has a
comfortable margin rather than sitting on a race.

Two things had to be gotten right to make this deterministic, both
discovered empirically while validating the test (not by inspection):

- **A margin of only ~2x the window (0.6s silence vs. a 0.3s window) is not
  reliable** — pre-fix, it reproduced the bug most but not all of the time
  (measured 4/5 to 7/8 across repeated runs). 5x margin (1.5s vs 0.3s)
  reproduced 100% across dozens of runs.
- **The receiving pane must run a plain `sh`, not the tester's own
  `$SHELL`.** A decorated interactive login shell (git status segment, a
  live clock, timers) can redraw its prompt on its own during the silence
  window — for reasons that have nothing to do with the command — which
  masks the bug by making the "screen changed" check trip early for the
  wrong reason. This was caught by contrasting an isolated repro (fails
  reliably) against a copy embedded in the full suite context (passed even
  pre-fix, using the ambient interactive shell) — the discrepancy traced
  back to the shell, not to load or ordering. Explicitly spawning the window
  with the fixed command `sh` (mirroring how `count-enters.sh` and
  `swallow-first-enter.py` are spawned as explicit fixture commands
  elsewhere in the same file) fixed it.

**Negative control confirmed:** with this test in place and `bin/amux`
temporarily reverted to pre-fix (`git stash` on just that file), the first
assertion fails reliably (3/3 runs):
```
FAIL: send does not report false failure for a command silent past the retry window
```
With the fix restored, all three assertions pass.

## Swallowed-Enter retry path still fires

`tests/fixtures/swallow-first-enter.py` deliberately swallows the first
Enter it receives and only prints its `SUBMITTED-OK` marker after a second
one — so the existing test asserting `rc=0` and the marker's presence is
already logically proof that a retry Enter fired (the fixture cannot reach
that marker any other way).

Additionally verified directly: temporarily added a
`echo "DEBUG-RETRY-FIRED" >&2` right before the retry's `t send-keys -t
"$tgt" Enter` inside the loop, ran `tests/test-coordination.sh`, and
confirmed:
- Exactly **one** `DEBUG-RETRY-FIRED` line, immediately preceding the
  swallowed-Enter test's assertions — proving the retry loop fired for that
  case.
- **Zero** `DEBUG-RETRY-FIRED` lines around the new silent-command test —
  proving the cursor discriminator correctly avoids retrying there (the fix
  works as intended, not by accidentally degrading to "always retry").

The debug line was removed after confirming this; it is not part of the
committed diff.

## Test results

- `bash tests/run.sh`: `256 passed, 0 failed` (baseline 253 + 3 new
  assertions from the added test).
- Ran under `bash` and separately under `/bin/bash`, 10 times each (20 full
  suite runs total): all 20 report `256 passed, 0 failed`. No flakiness
  observed.
- Pre-fix (`bin/amux` reverted via `git stash`), the new negative-control
  assertion fails reliably (checked 3/3 runs); the rest of the suite still
  passes, isolating the failure to exactly the intended assertion.

## Files changed

- `bin/amux`
  — added `cursor_before`/`cursor_now` capture and the third conjunct in
  `pending()`, plus updated comments explaining the reasoning (`send)`
  branch, roughly lines 273–334).
- `tests/test-coordination.sh`
  — added the silent-command regression test (negative control) ahead of the
  existing swallowed-Enter test.
- `docs/debug-report-send-false-negative.md`
  — this report.
