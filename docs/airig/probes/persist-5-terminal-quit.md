# Probe 5.3 (R5) — does quitting the terminal app kill a tmux server started from it? (#192)

Plan: docs/airig/plans/2026-10-26-persistent-sessions-plan.md, Task 5.3
(coordinator ruling R5).
Date: 2026-11-03. Run count: once per case.

```
ProductName:    macOS
ProductVersion: 26.3
BuildVersion:   25D125
```

Darwin 25.3.0, Terminal.app 2.15 (the system terminal app), tmux 3.6
(Homebrew). Terminal.app was not running before the probe; each case
launched it with `osascript -e 'tell application "Terminal" to do script
"…"'` and quit it with `osascript -e 'tell application "Terminal" to quit'`
(the scripted form of Cmd-Q). Before each quit, Terminal's windows were
listed: two each time, the window Terminal opens when it launches (a login
shell, nothing else) and the `do script` window. No other window existed.

Every server used a temp `HOME` and a temp `TMUX_TMPDIR` under
`/tmp/amx.XXXX` and the name `-L probe`, and was killed only with `tmux -L
probe kill-server` under that `TMUX_TMPDIR`. Each read: 5 s after the quit,
`pgrep -x Terminal` (gone each time), then `ps -o pid,ppid,args -p PID`.

## Results

| case | how the server started | server pid | after the quit + 5 s |
|---|---|---|---|
| plain | `tmux -L probe new-session -d 'sleep 600'` typed in the Terminal shell | 93250 (ppid 1) | **alive**, ppid 1; `tmux ls` lists its session |
| plain, attached | `tmux -L probe new-session -s att 'sleep 600'` in the Terminal shell, its client attached (`session_attached` 1) | 98711 | **alive**; `session_attached` 0 (the client went with the window) |
| candidate (i) | a LaunchAgent plist in the temp folder, label `dev.roosting.roost.probe`, `RunAtLoad`, `AbandonProcessGroup`, job = the same `tmux new-session -d`; `launchctl bootstrap gui/$(id -u) PLIST` typed in the Terminal shell | 2649 (ppid 1) | **alive**; also alive after `launchctl bootout` of the job |
| candidate (ii) | `nohup tmux -L probe new-session -d 'sleep 600'` in the Terminal shell (`setsid` is not on this macOS) | 6845 (ppid 1) | **alive** |

After candidate (i): `launchctl bootout gui/$(id -u)/dev.roosting.roost.probe`
returned 0, and `launchctl print gui/$(id -u)/dev.roosting.roost.probe`
failed afterwards (the probe job is gone). The plist lived only in the temp
folder, never in `~/Library/LaunchAgents`.

## Outcome

**The server survives the quit: R5 is not confirmed on macOS 26.3.** tmux
daemonizes its server (ppid 1, its own session) before the terminal's shell
gets control back, and quitting Terminal.app did not reach it, with or
without an attached client. Per Task 5.3's table: **Task 5.10 is skipped**;
§8.2 item 1's terminal-quit check (the deferred list) is what will see it on
a newer macOS.

One fact for `persist off` (§4.4): with `AbandonProcessGroup` set, a
`launchctl bootout` of the job that started the server left the server
running.

Not covered: Ghostty, iTerm2 or any other terminal app (only the system
one was quit), and a forced quit (`kill -9` of the app).
