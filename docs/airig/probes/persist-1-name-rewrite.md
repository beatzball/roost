# Probe (ruling R8.3) — can restore undo tmux's rewrite of session and window names?

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, ruling R8 item
3, measured inside Task 1.12. Date: 2026-10-28. Run count: once per build.

## Method

On each build (tmux 3.2a `ubuntu:22.04`, 3.4 `ubuntu:24.04`, 3.6 this Mac), a
throwaway `-S` server, `-f /dev/null`, temp `HOME`; containers ran `apt-get
install -y -qq tmux procps` and a script copied in from a temp directory.
For each name — `a\b`, `a$b`, `a\$b`, `a"b`, ``a`b``, `a<ESC>b`, `a<TAB>b`,
the four characters `a\033b`, and `plain` — the stored name was read back
(`list-sessions` / `list-windows -F`, R6-corrected), then the object made
again from it and read back, twice (two save-and-restore cycles), comparing
each with the first stored name. Sessions: `new-session -s X`. Windows:
created by `rename-window` (how a person names one), then made again with
`new-window -n X`. Two candidate X were tried: the stored name with tmux's
escaping undone (`\\` `\$` `\t` `\n` `\NNN`), and the stored name as it is.

## Result

| object | X | tmux 3.2a | tmux 3.4 | tmux 3.6 |
|---|---|---|---|---|
| session | escaping undone | same after both cycles, every name | same | same |
| window | escaping undone | **drifts** for `a\b`, `a$b`, `a\$b`, ESC, tab, `a\033b` | drifts (all but ESC) | drifts |
| window | stored name as it is | same after both cycles, every name | same | same |

What tmux stores (hex): `a\b` → `a\\b` on all three; `a$b` → `a\$b` on 3.2a
and 3.4 and `a$b` on 3.6; ESC → the text `\033`; tab → the text `\t`.
`new-window -n` stores what it is given (3.4 escapes only a raw control
byte), while `rename-window` and `new-session -s` escape it.

## Outcome

Restore **can** undo the rewrite exactly on every build, so nothing is
dropped: a **session** name is passed to `new-session -s` with tmux's own
escaping undone; a **window** name is passed to `new-window -n` (and
`new-session -n`) exactly as saved. `tests/test-shape-place.sh` pins the
session half over two cycles (Task 1.12) and the window half (Task 1.13).
