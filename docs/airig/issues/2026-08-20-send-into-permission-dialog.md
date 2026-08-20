# `amux send` can type into a permission dialog and answer it

Found 2026-08-20 by the `switcher-flake` session, while trying to report to
another agent. Confirmed by reading `bin/amux`. **Not fixed. Out of scope for
the rename — recorded so it is not lost.**

## What happens

`amux send` delivers in two steps: type the literal text, pause, then press
Enter.

```sh
t send-keys -t "$tgt" -l -- "$*"     # type the text
sleep "$delay"                        # a beat
t send-keys -t "$tgt" Enter           # submit
```

Nothing checks **what the target pane is currently showing.** If a permission
dialog is open at that moment:

1. The text is typed into the dialog rather than into a prompt.
2. The Enter can activate whatever option is highlighted.

So one agent driving another can approve a permission prompt in the target
agent, without either the sender or the human intending it.

## Why the existing verification does not cover this

`amux send` already verifies its own submit — that is what PR #6 added, and it
is good. But it verifies **that the text left the input line**, not **that the
target was in a state where sending was safe.** Those are different questions,
and only the first is currently asked.

A send into a dialog may even *look* successful to the verifier: the text left
the input line, because the dialog consumed it.

## Why it matters more than a lost message

The reporter's own case was benign — a status report that may or may not have
arrived. The same mechanism with a destructive command in the highlighted
option is materially worse, and the failure is silent from the sender's side.

This sits directly against the project's stated purpose. `amux` exists so a
human can see which agent needs them; a send that answers the dialog removes
the human from a decision the dialog existed to ask.

## What was ruled out in the observed case

The reporter checked `.claude/settings.local.json`: no `python3` entry, nothing
modified in the surrounding window, so no "don't ask again" was selected. The
dialog was still open and unanswered when they looked. So in that instance
nothing was approved — but only by luck of timing, not by design.

## Directions, not decisions

- Have `send` refuse, or warn, when the target pane's state suggests a dialog
  rather than a prompt. Detection is the hard part and may not be reliable.
- Give `send` an explicit opt-in for "send even if the target looks busy",
  defaulting to refuse.
- Expose the target's agent state to the sender — `amux` already tracks
  `blocked`, and `blocked` is precisely "a dialog is open". A send to a
  `blocked` pane could refuse by default. This is likely the cheapest route,
  since the state is already stamped and already accurate.

The third option is the one worth costing first: it reuses a signal the project
already computes correctly rather than adding new screen-scraping.

## Note for the rename

This is a bug in behaviour, not in naming. Whatever `send` becomes in `roost`
inherits it unchanged. Fixing it is a separate piece of work and should not be
folded into the rename, which is meant to change no behaviour at all.
