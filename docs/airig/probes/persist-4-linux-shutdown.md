# Probe 4.1 — the shutdown record on Linux

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 4.1.
Spec: §3.6 ("On Linux the sources are `last -x shutdown` where wtmp exists
and `journalctl --list-boots` where it does not; *not measured*").

## Outcome

**`last -x shutdown` prints a shutdown time, with minute resolution in its
default form and second resolution with `-F` or `--time-format iso`.** So the
first row of the task's table applies: Task 4.9b reads it on Linux. The
window stays "that minute and the one before" when only the minute is read;
with `--time-format iso` the shutdown second and its zone offset are printed,
so no year has to be guessed and no zone has to be assumed.

## Method

A throwaway Lima VM, Ubuntu 24.04.5 LTS (kernel 6.8.0, aarch64), util-linux
`last`, systemd journal, machine zone America/Chicago (CST, UTC-6). Three
shutdowns, each once: one `sudo systemctl poweroff` followed by
`limactl start`, then two `sudo systemctl reboot`. After the last boot:
`last -x shutdown`, `last -x reboot`, `last -F -x shutdown reboot`,
`last --time-format iso -x shutdown reboot`, `journalctl --list-boots`,
`/proc/sys/kernel/random/boot_id`, `uptime -s`.

## Raw output (after the third boot)

```
$ last -x shutdown
shutdown system down  6.8.0-142-generi Mon Nov  2 01:47 - 01:47  (00:00)
shutdown system down  6.8.0-142-generi Mon Nov  2 01:46 - 01:47  (00:00)
shutdown system down  6.8.0-142-generi Mon Nov  2 01:46 - 01:46  (00:00)

wtmp begins Mon Nov  2 01:44:50 2026

$ last -F -x shutdown reboot
reboot   system boot  6.8.0-142-generi Mon Nov  2 01:47:20 2026   still running
shutdown system down  6.8.0-142-generi Mon Nov  2 01:47:18 2026 - Mon Nov  2 01:47:20 2026  (00:00)
reboot   system boot  6.8.0-142-generi Mon Nov  2 01:47:00 2026 - Mon Nov  2 01:47:18 2026  (00:00)
shutdown system down  6.8.0-142-generi Mon Nov  2 01:46:58 2026 - Mon Nov  2 01:47:00 2026  (00:00)
reboot   system boot  6.8.0-142-generi Mon Nov  2 01:46:35 2026 - Mon Nov  2 01:46:58 2026  (00:00)
shutdown system down  6.8.0-142-generi Mon Nov  2 01:46:13 2026 - Mon Nov  2 01:46:35 2026  (00:00)
reboot   system boot  6.8.0-142-generi Mon Nov  2 01:44:50 2026 - Mon Nov  2 01:46:13 2026  (00:01)

$ last --time-format iso -x shutdown reboot
reboot   system boot  6.8.0-142-generi 2026-11-02T01:47:20-06:00   still running
shutdown system down  6.8.0-142-generi 2026-11-02T01:47:18-06:00 - 2026-11-02T01:47:20-06:00  (00:00)
reboot   system boot  6.8.0-142-generi 2026-11-02T01:47:00-06:00 - 2026-11-02T01:47:18-06:00  (00:00)
...

$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 0a1b2c3d4e5f40718293a4b5c6d7e8f9 Mon 2026-11-02 01:44:51 CST Mon 2026-11-02 01:46:13 CST
 -2 1b2c3d4e5f60418293a4b5c6d7e8f90a Mon 2026-11-02 01:46:36 CST Mon 2026-11-02 01:46:58 CST
 -1 2c3d4e5f6071429384a5b6c7d8e9f0a1 Mon 2026-11-02 01:47:01 CST Mon 2026-11-02 01:47:18 CST
  0 3d4e5f607182439485b6c7d8e9f0a1b2 Mon 2026-11-02 01:47:21 CST Mon 2026-11-02 01:47:38 CST

$ cat /proc/sys/kernel/random/boot_id; uptime -s
3d4e5f60-7182-4394-85b6-c7d8e9f0a1b2
2026-11-02 01:47:19
```

The boot ids above are fake, of the same shape as the VM's; the VM is deleted after
this part.

## Each source: resolution and zone

| source | resolution | zone | year |
|---|---|---|---|
| `last -x shutdown` | minute | local time, no zone printed | not printed |
| `last -F -x shutdown` | second | local time, no zone printed | printed |
| `last --time-format iso -x shutdown` | second | offset printed (`-06:00`) | printed |
| `journalctl --list-boots`, previous boot's LAST ENTRY | second | zone abbreviation printed (`CST`) | printed |
| `/proc/sys/kernel/random/boot_id` | — (an id, no time) | — | — |
| `uptime -s` | second, this boot's start | local time | printed |

Notes:

- A fresh VM starts its wtmp at its first boot (`wtmp begins …`), so the
  first boot has no shutdown line before it: a machine whose wtmp was
  rotated or is new has no record for the boot before the rotation. That is
  the "no readable record" case (rule 3).
- The shutdown line's time agrees with the previous boot's last journal
  entry to the second in all three shutdowns (01:46:13, 01:46:58, 01:47:18),
  and with `systemd-shutdown[1]: Sending SIGTERM to remaining processes...`
  in `journalctl -b -1`.
- Both a `poweroff` and a `reboot` write a `shutdown` line.
- Run count: once each (three shutdowns in one sitting).
