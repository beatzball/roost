# Probe 5.1 — a oneshot systemd user unit and the tmux server it starts (#192)

**Question.** §4.4 starts the login restore from a systemd user unit with
`Type=oneshot`, `RemainAfterExit=yes`, `KillMode=process`. Does the tmux server
that `ExecStart` starts outlive the script's exit, a `disable` (no `--now`), and
a logout, with and without linger, and with `KillUserProcesses=yes`?

**Where.** A throwaway Lima VM, Ubuntu 24.04.5 LTS (aarch64), systemd 255
(255.4-1ubuntu8.17), tmux 3.4. Run once per case on 2026-11-03. The VM's user
is written `<user>` below; pids are the VM's.

**Method.** A unit `~/.config/systemd/user/roost-probe.service`:

```
[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=process
ExecStart=%h/p5probe/start.sh
[Install]
WantedBy=default.target
```

`start.sh` exports a `TMUX_TMPDIR` under the probe folder, runs
`tmux -L probe new-session -d 'sleep 100000' \; split-window … \; split-window …`
(three `sleep` panes), logs one line, and exits 0. Each read prints the pid
`tmux -L probe display -p '#{pid}'` answers with, its pane pids, its
`/proc/PID/cgroup`, the unit's `is-active`/`is-enabled`, `Linger`, and the
start log.

A logout is `loginctl terminate-session` of every session of the user (Lima
keeps one ssh master session open, so closing a shell is not a logout), then
a wait of 20–25 s (logind's `UserStopDelaySec` is 10 s), then a new
`limactl shell`. `KillUserProcesses=yes` is a drop-in
`/etc/systemd/logind.conf.d/probe.conf` and `systemctl restart
systemd-logind`. Everything was removed after; linger was put back to its
starting value (`yes`, Lima's default).

## Results

| case | what survived |
|---|---|
| `systemctl --user start`, script exited 0 | **the server**, pid 3137, three panes; cgroup `…/user@501.service/app.slice/roost-probe.service`; unit `active` |
| `systemctl --user disable` (no `--now`), unit was enabled | **the server**, same pid 3137; unit `active / disabled` |
| (info) `systemctl --user stop` with `KillMode=process` | **the server**, same pid 3137; journal: `Unit process 3422 (tmux: server) remains running after unit stopped` (a later run's line, same shape) |
| control A: `Type=oneshot`, no `RemainAfterExit`, default `KillMode` | **nothing**: `no server running on …/ctl` right after the start |
| control B: `RemainAfterExit=yes`, default `KillMode=control-group`, then `stop` | the server after start (pid 3254); **nothing** after `stop` |
| logout, **linger no**, `KillUserProcesses=no` (Ubuntu's default) | **not the server**: the user manager stopped 10 s after the last session (`Stopped roost-probe.service` at :15), pid 3422 was gone; at the next login the enabled unit ran again and started a new server (pid 3925) |
| logout, **linger yes**, `KillUserProcesses=no` | **the server**: pid 4962 before the logout and 20 s after it, same three panes |
| `loginctl terminate-user` (kills every process of the user), linger yes | **not the server**: pid 3282 gone; the lingering manager restarted and the enabled unit started a new server (pid 3422) |
| logout, `KillUserProcesses=yes`, **linger yes** | **the server**, same pid 3925 |
| logout, `KillUserProcesses=yes`, **linger no** | **not the server**; the next login's unit started a new one (pid 4482) |
| (info) a server started from the login shell (cgroup `session-13.scope`), `KillUserProcesses=yes`, linger yes, logout | **not that server** (`no server running on …/sess`); the unit's server pid 4482 still answered |

Raw excerpt (enable, start, disable):

```
--- enabled, after start (03:45:58)
server pid 3137 alive; panes: 3138 3140 3142
cgroup: 0::/user.slice/user-501.slice/user@501.service/app.slice/roost-probe.service
unit: active / enabled
--- after disable (no --now) (03:46:01)
server pid 3137 alive; panes: 3138 3140 3142
unit: active / disabled
```

## Reading

- **The server survives the oneshot's exit and `disable`.** Both controls
  show why each line of §4.4's unit is there: without `RemainAfterExit` the
  unit finishes at the script's exit and its cgroup — the server — is killed
  at once; without `KillMode=process` a `stop` kills it. Per the table in
  Task 5.1: **build §4.4 as written.**
- **Logout (for the page and §8.2 item 2).** The server lives in the user
  manager's cgroup, not the login session's, so `KillUserProcesses=yes` alone
  does not reach it. What ends it is the user manager stopping: without
  linger that happens 10 s after the last session ends, and the fleet goes
  with it (the unit starts a new server at the next login, which is what
  `--at-login` is for). With linger the manager stays and so does the fleet.
  `persist on` printing the `loginctl enable-linger` line is the right
  advice. A server started from a login shell instead (not the unit) dies at
  logout under `KillUserProcesses=yes`.
