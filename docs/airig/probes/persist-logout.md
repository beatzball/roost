# Probe — what a pane-died hook can read during a logout without linger (#235)

**Question.** After a Linux logout without linger, every agent came back as a
shell (#235, finding F1 of the Linux check): stopping the user manager ends
each pane's `tmux-spawn-*.scope` about 5 s before it SIGKILLs the tmux server,
and the server's `pane-died` save demotes every key (`stale_reason other`).
At the moment an agent dies, what can that hook read that says "the user
manager is stopping", and does a normal death of one agent read differently?

**Where.** A throwaway Lima VM, Ubuntu 24.04.5 LTS (aarch64), systemd 255,
tmux 3.4, on 2026-11-07. roost at 0.10.0 with `persist on`; the tmux server
was started by the login unit, so it lives in
`user@<uid>.service/app.slice/roost-persist-roost.service`. Six stub agents
(four claude, two codex), keyed. `KillUserProcesses=no` (Ubuntu's default),
`UserStopDelaySec` at its default 10 s. The VM's user is written `<user>`,
its uid 501.

**Method.** A script, added as one more hook on the running server only (not
to roost's config):

```
tmux -L roost set-hook -g 'pane-died[97]' "run-shell -b \"$HOME/probe-logout.sh #{hook_pane} pane-died\""
```

Index 97 runs before roost's own `pane-died[98]` (the save). The script
appends to one log file:

```
systemctl --user is-system-running
$XDG_RUNTIME_DIR, whether it exists, what it holds, and whether
  $XDG_RUNTIME_DIR/systemd/private is a socket
systemctl show user@<uid>.service -p ActiveState / -p SubState   (system bus)
loginctl show-user <uid> -p State
systemctl --user is-active exit.target / default.target
systemctl --user show roost-persist-roost -p ActiveState
```

- **Control:** `kill -TERM` of one claude stub (pane `%12`), with linger yes
  and a session open. Then `roost revive %12` put it back (6 agents again).
- **Logout:** `loginctl disable-linger` (and the VM's marker that stops Lima
  turning linger back on at boot), then close Lima's ssh master
  (`ssh -F <lima ssh.config> -O exit lima-roost-verify`; ending `limactl
  shell` alone is not a logout, since the master stays open), wait 30 s, log
  in again.

## Results

**Control — one agent killed by hand** (10:46:47Z):

```
--- 10:46:47.744171888 pane=%12 hook=pane-died
systemctl --user is-system-running = running
XDG_RUNTIME_DIR = /run/user/501
runtime dir exists; entries: buildkit … bus … dbus-1 … systemd
systemd/private socket: present
user@501.service ActiveState (system bus) = active
user@501.service SubState (system bus) = running
loginctl user State = active
systemctl --user is-active exit.target = inactive
systemctl --user is-active default.target = active
roost-persist-roost ActiveState = active
```

The save it caused (gen 171, `trigger pane-died`) demotes that one pane:
`stale_reason other`, `stale_harness claude`, `command roost-pane-shell`.
This is the behaviour the fix must keep.

**Logout, linger no** (session removed 10:47:04Z; journal, local time −06:00):

```
04:47:04.562 systemd-logind: Removed session 3.
04:47:14.800 systemd[1]: Stopping user@501.service - User Manager for UID 501...
04:47:14.801 systemd[763]: Stopping tmux-spawn-….scope - tmux child pane … (13 scopes)
04:47:14.803 roost-persist-roost.service: Unit process 1187 (tmux: server) remains running after unit stopped.
04:47:14.804 systemd[763]: Stopped tmux-spawn-….scope …
```

Six hooks ran, one per agent, between 10:47:14.809 and 10:47:14.831Z —
9 to 31 ms after the user manager began to stop. They ran at once into one
file, so their lines interleave; every read gave the same value in all six:

| read | all six hooks | control |
|---|---|---|
| `systemctl --user is-system-running` | **`stopping`** | `running` |
| `$XDG_RUNTIME_DIR` | `/run/user/501`, exists | same |
| `$XDG_RUNTIME_DIR/systemd/private` | present (a socket) | same |
| `user@501.service` ActiveState / SubState (system bus) | `deactivating` / `stop-sigterm` | `active` / `running` |
| `loginctl show-user` State | `closing` | `active` |
| `systemctl --user is-active default.target` | `inactive` | `active` |
| `systemctl --user is-active exit.target` | `inactive` | `inactive` |
| `roost-persist-roost` ActiveState | `inactive` | `active` |

The runtime directory was still whole (five hooks saw `containerd-rootless`
already gone from it, a socket of a service the manager was stopping; every
other entry was there). Then roost's own save,
gen 174 `trigger pane-died`, held 6 `stale_reason` blocks and 0 keys. At the
next login (10:47:40Z) the unit's restore said `picked
20261107T104714Z-174 (the newest save)` and `placed 3 sessions, 10 windows,
13 panes (exit 0); 0 agents wait for the first attach` — F1, reproduced.

**Cost of the read.** `systemctl --user is-system-running`, 20 runs in a
loop: 0.089 s, about 4.5 ms each. With `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` unset it prints nothing on stdout, `Failed to
connect to bus: No medium found` on stderr, and exits 1.

## Reading

- **`systemctl --user is-system-running` says `stopping`** at the moment the
  agents die in a logout, and `running` at a normal death. It is the user
  manager's own answer about itself, over its private socket, which is still
  there. It needs no root, no system bus and no parsing, and the tmux server
  has `XDG_RUNTIME_DIR` in its environment (the user manager hands it to the
  unit; a server started from a login shell has it from the session).
- The other reads agree (`deactivating`, `closing`, `default.target`
  inactive) but each says the same thing at greater cost or with more to go
  wrong: the system bus for `user@`, logind's `closing`, which also holds
  while a session-scope server keeps a closed session open (the Linux check's
  case C, where nothing dies).
- The user manager reaches `stopping` before it signals any scope, so no
  agent of a logout can die before the read says so.
- A reboot stops the user manager the same way (the Linux check's item 3:
  one death save about 5 s before the shutdown record). There the reading
  rule already walks past that save; a saver that does not publish it makes
  the rule's job smaller, not different.
- macOS has no `systemctl`. A check that asks only when `systemctl` is on
  `PATH` leaves macOS exactly as it is.

**For the fix (Task 2 of the brief):** a save round that would publish while
`systemctl --user is-system-running` prints `stopping` publishes nothing.
The save before the logout — keys intact — stays the newest, and rule 1
picks it. Any other answer, including no answer, saves as today, so the
control's single death still demotes.

## Follow-up (#239): a server that outlives the user manager

**Question.** With `KillUserProcesses=no` (Ubuntu's default) and no linger,
can a roost server outlive the user manager, when the server was started
outside the login unit? If it can, what does the first save after that do
to the keys?

**Where.** The same VM and fleet (six stub agents, four claude, two codex;
13 panes in 10 windows), on 2026-11-07, roost at the #239 branch (the
stopping check moved before the arrows step). Linger off, as above. A
script, run outside the session that logged out, wrote one line every
0.5 s: `systemctl --user is-system-running`, `user@501.service`'s state
(system bus), logind's user state and sessions, the tmux server's pid, the
number of panes running an agent, and the newest save's gen, keys
(`session_id`) and `stale_reason` count.

Where tmux puts each pane matters here. tmux 3.4 moves every pane it
starts into its own `tmux-spawn-*.scope` under the USER MANAGER
(`user@501.service/app.slice/…`), whatever the server's own cgroup. So
stopping the manager ends every pane, wherever the server lives.

### The end of the window, for a server in the unit

`roost_shape__stopping`'s comment rests on this. In each of the three
logouts of a unit-started server on this VM (the Linux check's case A at
01:04, this probe's at 04:47, the #235 fix's check at 05:08, local time),
the user manager did not finish stopping by itself:

```
05:08:26.77     systemd[1]: Stopping user@501.service - User Manager for UID 501...
05:08:31.769682 systemd[1]: user@501.service: State 'stop-sigterm' timed out. Killing.
05:08:31.769753 systemd[1]: user@501.service: Killing process 1076 (systemd) with signal SIGKILL.
05:08:31.769928 systemd[1]: user@501.service: Killing process 1423 (tmux: server) with signal SIGKILL.
05:08:31.786800 systemd[1]: user@501.service: Main process exited, code=killed, status=9/KILL
05:08:31.789126 systemd[1]: Stopped user@501.service - User Manager for UID 501.
```

01:04:45.82 and 04:47:19.81 read the same. `systemctl show
user@501.service`: `KillMode=mixed`, `TimeoutStopUSec=5s`. PID 1 SIGKILLs
the manager and the server in one step, under a millisecond apart, and logs
`Stopped` 10 to 20 ms later. So for a server in the unit, every round from
the first agent's death to the server's own finds the manager there,
answering `stopping`. Not seen: a manager that exits by itself inside the
5 s; it would leave such a server to the timeout's SIGKILL, and a round in
that gap would read no answer.

### Case 1 — the server started from an ssh shell

`tmux -L roost kill-server`, then `roost restore --from <the newest save>`
typed in the ssh session: the server's cgroup is
`user-501.slice/session-4.scope`, its panes in `tmux-spawn` scopes under
`user@501.service`. Log out (close Lima's ssh master), wait 60 s:

```
23:23:13.9 isr=running user@=active/running logind=active  sessions=[4:active]  agents=6 gen=241 keys=6
23:23:19.3 isr=running user@=active/running logind=closing sessions=[4:closing] agents=6 gen=241 keys=6
   ... the same every 0.5 s ...
23:24:20.6 isr=running user@=active/running logind=closing sessions=[4:closing] agents=6 gen=241 keys=6
```

**Does not outlive it.** The server keeps session 4 in `closing`, and
logind does not stop the user manager while the user has a session, closing
or not. Nothing dies (the Linux check's case C, again).

### Case 2 — the server outside any session

The server started in a system scope, as a system service or a cron job
would start it: `sudo systemd-run --scope --uid=501 --gid=<gid>` of a
script that sources the unit's `service.env`, sets
`XDG_RUNTIME_DIR=/run/user/501` and runs `roost restore --from <the newest
save>`. Server cgroup `system.slice/roost-outside-239.scope`; panes in
`user@501.service/app.slice/app-tmux.slice/tmux-spawn-*.scope`. The only
session left was the ssh one. Log out:

```
17:25:48.89 systemd-logind: Removed session 93.
17:25:58.92 systemd[1]: Stopping user@501.service - User Manager for UID 501...
17:25:58.92 systemd[7449]: Stopping tmux-spawn-….scope - tmux child pane … launched by process 415349...
17:26:04.009807 systemd[1]: user@501.service: State 'stop-sigterm' timed out. Killing.
17:26:04.009831 systemd[1]: user@501.service: Killing process 7449 (systemd) with signal SIGKILL.
17:26:04.009999 systemd[1]: user@501.service: Killing process 417051 (bash) with signal SIGKILL.
   (six more `bash`: the shell panes; the tmux server is not in this unit)
```

The script's lines (UTC; the journal above is local, −06:00):

```
23:25:49.1 isr=running  user@=active/running              sessions=[] server=415349 agents=6 gen=254 keys=6 stale=0
23:25:59.2 isr=stopping user@=deactivating/stop-sigterm   sessions=[] server=415349 agents=0 gen=254 keys=6 stale=0
   ... the same for 5 s: the agents died, every death round read `stopping`, nothing written ...
23:26:04.0 isr=stopping user@=deactivating/stop-sigkill   sessions=[] server=415349 agents=0 gen=254 keys=6 stale=0
23:26:04.6 isr=(none)   user@=failed/failed  logind=none  sessions=[] server=415349 agents=0 gen=255 keys=0 stale=6
```

**It outlives it**, and the save written right after the manager went is
the damage. The SIGKILL that ended the manager also ended the seven shell
panes (no `remain-on-exit`), so their windows closed, and those hooks'
round ran with no manager to answer: gen 255, `trigger pane-exited
window-unlinked`, saved 23:26:04Z — 5 windows and 6 panes where gen 254
had 10 and 13, and every agent pane `command roost-pane-shell`,
`stale_reason other`, no `session_id`. It came before any new login, not
under the next manager.

At the next login (23:26:44Z) the new manager ran the unit, which found the
server alive and placed nothing (`placed 0 sessions, 0 windows, 0 panes
(exit 12); 0 agents wait`, each session "exists — skipped"). A save by hand
under the new manager listed the same thing (`3 sessions, 5 windows, 6
panes, 0 with a conversation, 6 stale`): the first save under the next
manager demotes every key too, and would have done so had gen 255 not
already.

**What was still there.** The six agent panes stayed, dead
(`remain-on-exit`), and each kept its pane options (`@roost-harness claude`,
`@roost-session 1111…`). `roost revive %1` launched `claude --resume 1111…`
in the pane's directory. So while that server lives, every agent comes
back by hand. The saved record does not: if that server then dies (a
reboot, a crash) before each agent is revived, the newest save names no
conversation and lost five windows, and a restore brings back shells.

### Reading

- Case 1, the common one (a server started from a shell), cannot outlive
  the manager: the server holds its session open.
- Case 2 needs a server outside both the login session and the user
  manager: a system service, a cron job, `systemd-run` as root. The stop
  check covers the deaths (every one read `stopping`); it cannot cover the
  rounds that run once the manager is gone, which read no answer — the same
  answer as a machine with no user manager at all, where a save must go on.
- Telling those two apart needs state (this server's boot has seen a
  manager answer, and now none does), and even then the first save under
  the next manager lists the dead panes. Keeping a key across that needs
  the save to know the pane died in a teardown. Recorded, not fixed here.
