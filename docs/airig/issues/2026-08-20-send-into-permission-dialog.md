# `roost send` could type into a permission dialog and answer it

**FIXED.** `roost send` now refuses a target whose badge is `blocked` and exits
3; `--force` overrides. See "How it was fixed" at the bottom.

Found 2026-08-20 by the `switcher-flake` session, while trying to report to
another agent. Confirmed by reading `bin/amux` (as it was then named). Recorded
here rather than fixed at the time, because the rename it was found during was
meant to change no behaviour at all.

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

## How it was fixed

The third direction, as predicted — it reused a signal the project already
computed correctly instead of adding screen-scraping.

`roost send` reads `#{@agent_state}` in the SAME `display-message` call that
already fetches `#{window_id}` and `#{pane_dead}`, so all three checks describe
one snapshot of the target rather than racing separate lookups. When the state
is `blocked` it prints why and exits **3** — deliberately distinct from 2 (wrong
target: pick a different one) and 1 (submit failed: retry or inspect). Exit 3
means the target is right and retrying later, once a human has answered, is the
correct response.

`--force` overrides, and is accepted only in front of the target: anywhere later
it could not be told apart from a message that happens to begin with that word.

With a WINDOW target, `display-message` and `send-keys` both resolve to that
window's active pane, so the guard covers exactly the pane that would have
received the keys.

Verified against the pre-fix binary from `main`: sending into a `blocked` pane
exited **0**. It now exits 3, and the pane receives nothing. Tests in
`tests/test-coordination.sh` cover the refusal, the empty delivery, `--force`,
the distinct exit codes, every non-blocked state, and an agent that has never
reported a state at all.
