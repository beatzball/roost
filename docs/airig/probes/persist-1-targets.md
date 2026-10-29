# Probe 1.4 — dotted and numeric names, and the exact-match target

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.4.
Date: 2026-10-27. Run count: once per build, two scripts (the second added
after the first showed a name fallback; see below).

## Method

On each build, a throwaway server (`-S` socket in a temp directory, temp
`HOME`, `-f /dev/null`, a `keeper` session). The containers ran `apt-get
install -y -qq tmux procps` and a probe script copied in from a temp
directory (no mount of the worktree).

Script 1: sessions `v3.69-x` and `1`, each given windows at index 1 and 5 and
a window **named** `2` at index 3 (no index 2). For each of `v3.69-x`, the
name tmux actually stored, and `1`: `has-session -t NAME` and `-t =NAME`;
`display -p -t '=NAME:'`; `new-window -d -P -t '=NAME:7'`; `split-window -d -P
-t '=NAME:5.0'`; `select-layout -t '=NAME:5' tiled`; `display -p -t
'=NAME:2'` and `'=NAME:3'`.

Script 2, session `1` only: a window named `2` at index 3, then `new-window -t
'=1:2'` (index 2 free, name `2` taken); then, with index 2 and the window
named `2` both present, `display`, `split-window` and `select-layout` on
`'=1:2'`; a window named `7` at index 4, then `new-window -t '=1:7'`; a window
named `9` at index 5 and no index 9, then `split-window -t '=1:9.0'`; and
`display -p` / `has-session` on a session that does not exist.

## Result

| case | tmux 3.2a | tmux 3.4 | tmux 3.6 (Mac) |
|---|---|---|---|
| `new-session -s v3.69-x` stores | `v3_69-x` | `v3_69-x` | `v3_69-x` |
| `has-session -t v3.69-x` / `-t =v3.69-x` | rc 1, `can't find pane: 69-x` | same | same |
| every form on the stored name `=v3_69-x:`, `=v3_69-x:7`, `=v3_69-x:5.0`, `=v3_69-x:5` | resolves, rc 0 | same | same |
| every form on `=1:`, `=1:7`, `=1:5.0`, `=1:5` | resolves, rc 0 | same | same |
| `has-session -t 1` and `-t =1` (session `1` exists) | rc 0 | rc 0 | rc 0 |
| `new-window -t '=1:2'`, index 2 free, a window named `2` at 3 | made at index 2 | same | same |
| `new-window -t '=1:7'`, index 7 free, a window named `7` at 4 | made at index 7 | same | same |
| `'=1:2'` with index 2 **and** a window named `2` present | index 2 (index wins) | same | same |
| `'=1:2'` / `'=1:9.0'` with **no** such index, a window named `2` / `9` present | **the named window** (index 3 / 5) | same | same |
| `display -p -t '=nosuch:'` | **rc 0, empty output** | same | same |
| `has-session -t =nosuch` | rc 1 | rc 1 | rc 1 |

Raw excerpt (3.4; 3.2a and 3.6 print the same lines):

```
=== window named 9 at index 5; target =1:9 with no index 9 (split, layout)
split-window -d -P -F #{window_index}.#{pane_index} -t =1:9.0 sleep 600 rc=0 out=[5.1]
display -p -t =1:9 #{window_index} [#{window_name}] rc=0 out=[5 [9]]
=== display -p on a missing session: rc and output
display -p -t =nosuch: #{session_name}             rc=0 out=[]
has-session -t =nosuch                             rc=1 out=[can't find session: nosuch]
```

## What this means

- **A dotted session name never exists in tmux.** tmux stores `.` (and `:`,
  probe 1.3) as `_` at creation on all three builds, so a save reads
  `v3_69-x` and every target built from the saved name resolves. A
  hand-edited shape with a dot in a session name would come back under the
  `_` name; restore has to take the created session's name or id from
  `new-session -P -F`, not assume the one it asked for.
- **`=NAME:INDEX` is exact only while that index exists.** When it does
  not, tmux falls back to a window whose **name** is that number, on all
  three builds, and a `split-window` or `select-layout` lands in the wrong
  window with rc 0. Restore creates the window first, so in the normal path
  the index exists; but a creation that failed or landed elsewhere would send
  every later command to the wrong window silently.
- **`display -p` is not an existence test**: on a missing target it exits 0
  with empty output on all three.
- `has-session -t =NAME` is exact for a session that exists (`1`, `v3_69-x`).

## Outcome

**Row 2 of the task's table** ("some form fails on some version"): the
`=NAME:INDEX` and `=NAME:INDEX.PANE` forms fail the same way on all three
builds — they resolve to a window by name when the index is missing. So Tasks
1.12 and 1.13 build the session target as `=NAME:` and take every later
target from the id the creating command prints (`new-window -P -F
'#{window_id}'`, `split-window -P -F '#{pane_id}'`), and test the dotted and
numeric sessions. Row 3 does not apply (`has-session -t =NAME` finds a
session that exists); existence may still be read from `list-sessions -F
'#{q:session_name}'` with an exact compare, and never from `display -p`.
