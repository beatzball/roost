# Idea: live progress tracker for an airig plan

**Status: prototype, parked.** Built and used for real during the amux→roost
rename (2026-08-20). It worked well enough to earn a second life, and it has
specific known weaknesses that are worth fixing before it becomes a real tool.

Code preserved here as-is: `status-writer.py`, `status-view.sh`.

## What it does

Renders a Markdown doc showing a plan's task list, what is committed, what is
left, and the subtasks of whatever is currently in flight. A companion viewer
displays it in a tmux pane, redrawing only when the content actually changes.

```sh
python3 status-writer.py PLAN REPO OUT [TASKDIR] &   # writes OUT on a loop
./status-view.sh OUT                                  # renders it in a pane
```

`TASKDIR` is where agent transcripts live; it is scanned, not hand-listed.

## Why it was worth building

**Task state is derived from git, never asserted.** A task counts as done when
its plan-declared `**Commit:** \`subject\`` appears in `git log BASE..HEAD`.
Nothing the operator believes can influence the display.

That property paid for the whole thing within minutes of first render: it showed
Task 7 as ⬜ when everyone — including the session driving the work — believed
the plan was progressing normally. Task 7 had been deferred to avoid a collision
and then never dispatched. Six tasks and two status reports had gone by without
anyone noticing. A hand-maintained checklist would have inherited the same
mistaken belief; a git-derived one could not.

## What it does well

- **Cannot drift.** See above. This is the whole design.
- **Evidence-tiered subtasks.** A step is marked done only from a structural
  check (a git rename record, a `readlink` target, a file existing or absent).
  If no such check can be derived from the step's prose, it renders **unknown**
  — never done, never pending. A transcript mention can annotate a step but can
  never promote it. Each row shows which evidence backed it.
- **Quiet.** Two separate flicker fixes, both needed:
  - Volatile values are quantised into buckets. A liveness figure in seconds
    changed every tick, which changed the file every tick, which forced a redraw
    every tick.
  - The viewer homes the cursor and erases *after* drawing rather than calling
    `clear`. `clear` blanks the screen before the new frame, and that flash is
    the jarring part.

## What needs work before it is a real tool

1. **Most subtasks render unknown.** Steps phrased as prose ("Update the README
   throughout") have no derivable structural check. Honest, but a plan with many
   prose steps shows mostly `❓` and carries little information. Either plans
   need to declare machine-checkable artifacts per step, or the checker needs a
   richer vocabulary of patterns.
2. **Evidence from transcripts is dangerous and was nearly wrong.** An early
   version matched agent Bash-command text against paths named in a step. Common
   paths appear in nearly every task's commands, so it produced confident false
   hits. Narrowed to `Edit`/`Write` targets only. Anything looser silently
   fabricates progress — the exact failure this design exists to prevent.
3. **One plan at a time.** No support for a stack of branches or several plans
   in flight.
4. **Liveness is inferred from transcript mtime**, which is a proxy, not a fact.
   A long-running tool call looks identical to a stalled agent, because neither
   writes. It reported "possibly stalled" once while the agent was mid
   test-suite run. Any real version needs a signal from the runtime rather than
   a file timestamp.
5. **Requires plan discipline.** Every task must declare a `**Commit:**`
   subject, and implementers must use it verbatim. A reworded commit shows the
   task as incomplete forever.
6. **No history.** It shows now, not the shape of the run — no record of how
   long tasks took or where the run stalled.

## Where it might belong

It tracks *airig plans*, not anything about `roost`. Its natural home is
probably the airig plugin rather than this repository; it is parked here because
this is where it was built and where the plan it tracked lives.

## A note on how it was built

Written by a subagent, and one detail is worth keeping: it independently arrived
at the same auto-discovery design the operator was separately writing, and its
version was better. The operator had edited the file underneath it mid-task —
violating the concurrency rule that same operator had written into three briefs
— and the collision was resolved by keeping the subagent's design.
