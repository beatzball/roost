# Probe 1.2 — how a session group lists

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.2.
Date: 2026-10-27. Run count: once per build.

## Method

On each build, a throwaway server (`-S` socket in a temp directory, temp
`HOME`, `-f /dev/null`): session `main` with two windows, the second split
(three panes, `sleep 600`); then `new-session -d -t main -s view` (a grouped
session). Read:

- `list-sessions -F '#{session_name} #{session_group} #{session_grouped} #{session_group_list} #{session_id}'`
- `list-windows -a -F '#{session_name} #{window_index} #{window_id} #{window_linked} #{window_linked_sessions}'`
- `list-panes -a -F '#{session_name} #{window_index}.#{pane_index} #{pane_id}'`

Then two more steps, same reads: a `new-window` made in `view` (does the
group share it?), and a third member `third` plus a window made in `main` at
index 5. The containers ran `apt-get install -y -qq tmux procps` and a probe
script copied in from a temp directory (no mount of the worktree).

## Result

| read | tmux 3.2a (`ubuntu:22.04`) | tmux 3.4 (`ubuntu:24.04`) | tmux 3.6 (this Mac) |
|---|---|---|---|
| `list-sessions` | `main main 1 main,view $0` / `view main 1 main,view $1` | same | same |
| windows listed | each window under `main` **and** under `view`, same index, same `@N` | same | same |
| `#{window_linked}` of a group's window | **`0`** | **`0`** | `1` |
| `#{window_linked_sessions}` | `2` (3 with three members) | `2` (3) | `1` (1) |
| panes listed | each pane under `main` and `view`, same `W.P`, same `%N` | same | same |
| a repeated address (`SESSION:W` or `SESSION:W.P`) | none | none | none |
| a window made in `view` | appears in `main` too, same index and id | same | same |
| three members | every window and pane listed three times, once per member | same | same |

Raw excerpt (3.4, two members):

```
--- list-sessions
main main 1 main,view $0
view main 1 main,view $1
--- list-windows -a
main 0 @0 0 2
main 1 @1 0 2
view 0 @0 0 2
view 1 @1 0 2
--- list-panes -a
main 0.0 %0
main 1.0 %1
main 1.1 %2
view 0.0 %0
view 1.0 %1
view 1.1 %2
```

3.6 prints the same lines except `window_linked`/`window_linked_sessions`,
which read `1 1` for every window.

**`#{window_linked}` is not a usable signal for a group.** On 3.2a and 3.4 a
window shared by a group reads `window_linked 0`; on 3.6 it reads `1`. Only
`#{session_group}` / `#{session_grouped}` mark a group the same way on all
three. Nothing in the spec's rules reads `#{window_linked}` (§3.2 saves a
linked window under each session by listing alone), so no rule breaks; a
group-aware rule, if chosen, must key on `#{session_group}`.

roost itself never makes a grouped session (no `new-session -t` in
`bin/roost` or `scripts/`); a group exists only when a user makes one by hand.

## Outcome

**Row 1 of the task's table:** each member is listed under its own name with
the same window and pane ids (the linked-window shape), and no address
repeats. Task 1.9 writes both members as §3.2 writes a linked window: the
second member comes back as its own windows, and its agents meet §5.1a's
duplicate refusal (safe, doubled shells). The group-aware block is a spec
question for the coordinator; the plan stays on the spec until it is decided.
