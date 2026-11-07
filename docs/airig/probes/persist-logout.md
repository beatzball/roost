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
