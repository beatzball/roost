# Probe 1.1 — a zoomed window's `#{window_layout}`

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 1.1.
Date: 2026-10-27. Run count: once per build.

## Method

On each build, a throwaway server (`-S` socket in a temp directory, temp
`HOME`, `-f /dev/null`): `new-session -d -x 200 -y 50`, then one window split
`-h` and then `-v` (three panes running `sleep 600`). Read
`#{window_layout}`, `#{window_visible_layout}` and `#{window_zoomed_flag}`;
`resize-pane -Z` on the second pane; read again; `resize-pane -Z` again
(unzoom); read again. The containers ran `apt-get install -y -qq tmux procps`
and a probe script copied in from a temp directory (no mount of the
worktree). The probe only reads: nothing unzooms in order to save.

## Result

| read | tmux 3.2a (`ubuntu:22.04`) | tmux 3.4 (`ubuntu:24.04`) | tmux 3.6 (this Mac) |
|---|---|---|---|
| `window_layout` before | `21be,200x50,0,0{100x50,0,0,0,99x50,101,0[99x25,101,0,1,99x24,101,26,2]}` | same | same |
| `window_layout` zoomed | same as before | same as before | same as before |
| `window_visible_layout` zoomed | `ac9e,200x50,0,0,1` (one-pane view) | `ac9e,200x50,0,0,1` | `ac9e,200x50,0,0,1` |
| `window_zoomed_flag` zoomed | `1` | `1` | `1` |
| `window_layout` after unzoom | same as before | same as before | same as before |
| `window_visible_layout` after unzoom | equals `window_layout` | same | same |

Raw excerpt (3.4; 3.2a and 3.6 print the identical lines):

```
[before] layout=21be,200x50,0,0{100x50,0,0,0,99x50,101,0[99x25,101,0,1,99x24,101,26,2]} visible=21be,...same... zoomed=0
[zoomed] layout=21be,200x50,0,0{100x50,0,0,0,99x50,101,0[99x25,101,0,1,99x24,101,26,2]} visible=ac9e,200x50,0,0,1 zoomed=1
[unzoomed] layout=21be,...same... visible=21be,...same... zoomed=0
```

## Outcome

**Row 1 of the task's table:** `#{window_layout}` while zoomed equals the
unzoomed string on all three builds; only `#{window_visible_layout}` changes.
So Task 1.9 saves `#{window_layout}` as read and `zoomed 1` from
`#{window_zoomed_flag}` (§2.7, §3.2), and Task 1.13's test unzooms after
restore and compares the string.
