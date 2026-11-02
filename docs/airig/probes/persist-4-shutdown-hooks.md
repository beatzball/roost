# Probe 4.2 — does tmux run `session-closed` during a Linux shutdown?

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 4.2.
Spec: §3.6 ("Whether tmux runs any hook during a macOS shutdown or a Linux
`systemctl poweroff` is **not measured**").

## Outcome

**No hook ran.** In a `systemctl poweroff` and in a `systemctl reboot`, a
server with three sessions and four panes wrote nothing from
`session-closed[97]`, `pane-exited[97]` or `window-unlinked[97]`. The disk
write was not lost: a marker line written and `sync`ed just before the
shutdown command is in the file after boot, and every hook also ran `sync`
after its line. Either result was allowed by the task; the 100-entry ring
and §3.6's reading rule stand as written. On this evidence a Linux shutdown
makes no teardown chain from the server's own hooks, which matches what
§2.7 measured for a `SIGTERM` to the server.

## Method

The Lima VM of Task 4.1 (Ubuntu 24.04.5, tmux 3.4), once per shutdown kind.

- `TMUX_TMPDIR` at `mktemp -d /tmp/amx.XXXX`, `HOME` and `XDG_CONFIG_HOME` at
  a temp directory; a `-L p4probe` server with `-f /dev/null`.
- Sessions `s1`, `s2`, `s3`; `s2` split, so four panes, each a login
  shell.
- For each of `session-closed`, `pane-exited`, `window-unlinked`:
  `set-hook -g NAME[97] "run-shell \"echo \$(date -u +%s.%N) NAME
  pane=#{hook_pane} s=#{hook_session_name} >> /var/tmp/p4probe/hooks.log;
  sync\""` — `/var/tmp` is on the root disk and survives a reboot.
- Two controls before each shutdown, to show the hooks fire and reach the
  file: `new-session -d -s ctl` then `kill-session -t ctl`; and (first run)
  `new-session -d -s ctl2 "sleep 1"`, left to exit.
- The server was checked alive (`pgrep -a tmux`, `tmux ls`) from a second
  shell before the shutdown, since the shell that started it had ended.
- Then `echo marker-before-… $(date -u +%s) >> hooks.log; sync; sudo
  systemctl poweroff` (run 1) or `… reboot` (run 2). After boot, read the
  file.

## Raw output

Run 1, `systemctl poweroff`, then `limactl start`:

```
1793605554.088409697 session-closed pane= s=ctl
1793605554.094438608 window-unlinked pane= s=ctl
1793605566.008551176 pane-exited pane=%5 s=
1793605566.013873563 window-unlinked pane= s=ctl2
1793605566.015772032 session-closed pane= s=ctl2
marker-before-poweroff 1793605573
```

Run 2, `systemctl reboot` (a fresh server, the same hooks; the file emptied
first):

```
1793605616.856215135 session-closed pane= s=ctl
1793605616.862370010 window-unlinked pane= s=ctl
marker-before-reboot 1793605617
```

Nothing after either marker.

## Side facts seen on tmux 3.4 (not asked, recorded)

- A `kill-session` of a session that is not the last fires
  `session-closed` then `window-unlinked`; a session whose only pane's
  process exits fires `pane-exited`, then `window-unlinked`, then
  `session-closed` — the same orders §2.7 measured on 3.6.
- `show-hooks -g` does **not** list `pane-exited` (or any pane or window
  hook) even after `set-hook -g pane-exited[97]` succeeded; `show-hooks -gw`
  lists it. Task 4.3 measures this for every name, since Task 4.6's check
  reads the hooks back.
- Run count: once each.
