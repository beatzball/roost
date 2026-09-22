---
title: Notifications
description: How roost tells you an agent is blocked — on this machine, and over SSH when the fleet runs somewhere else.
sidebar:
  order: 11
---

## What gets a notification, and when

When an agent you are *not* looking at becomes **blocked** (it needs input),
roost pings you. `error` pings you too: an agent that has stopped making
progress deserves your attention as much as one waiting for an answer.

Nothing else notifies. `done` fires every turn and would be noise, so it is
deliberately silent. A pane on the window you are already watching never
notifies either — you can see it.

## The delivery chain

Delivery is cross-platform, tried in this order:

1. Your own command, `@roost-notify-cmd` (below)
2. macOS (`osascript`)
3. WSL (`BurntToast` via `powershell.exe`)
4. Linux (`notify-send`, when a display is present)
5. Fallback: an in-tmux `display-message`, which always works

Set `@roost-notify-backend` to `tmux` to always use the in-tmux message, or
`none` to switch notifications off entirely. The default is `auto`.

Every step fails silently and falls through to the next. The notifier's
contract is that it never fails and never breaks the agent that called it.

### Your own notifier

For full control, set `@roost-notify-cmd` to your own command. `%t` is replaced
with the title and `%s` with the message:

```sh
set -g @roost-notify-cmd 'notify-send "%t" "%s"'
```

Reference the placeholders double-quoted (`"%s"`) or bare — **never
single-quoted**, since `%t` / `%s` are wired to shell positional parameters
(`$1` / `$2`) before your command runs, and single quotes would suppress that
substitution.

Because the swap is textual, avoid combining the placeholders with a command
that needs a *literal* `%t` or `%s` of its own (for example `date +%s`) — the
two would collide.

## When the fleet runs on another machine

Every backend above delivers to the desktop of the machine roost is running
on. Run the fleet on a bigger box and that is the wrong desktop: nobody is
looking at it.

So roost can notify **your terminal** instead of a desktop. Terminals accept a
short escape sequence that asks them to raise a notification, and that sequence
travels down a plain SSH connection like any other output. No daemon, no port,
no account, nothing to install on either machine.

It is on by itself only when it is needed:

| `@roost-notify-osc` | What happens |
|---|---|
| unset (default) | On for a **remote** client, off for a local one |
| `on` | Always on, local or remote |
| `off` | Never |

"Remote" means the attached client has `SSH_CONNECTION` — or `SSH_TTY` — set.
tmux copies `SSH_CONNECTION` from the client into the session when it attaches,
and removes it again when a local client attaches, so the answer follows you:
attach from your laptop and the notification comes to your laptop's terminal.
`SSH_TTY` is checked as well, for anyone who has added it to tmux's
`update-environment`; it is not in tmux's default list, so nothing rests on it
alone.

The question is asked **per client**, and only tmux's own view of that client
counts. If you have two clients attached — one over SSH, one at the machine —
the remote one is notified and the local one is not. Whether *roost itself* is
running under SSH is deliberately ignored: a pane keeps `SSH_CONNECTION` for
its whole life once the server was started over SSH, long after you have walked
back to the machine.

A local client is left alone by default because your desktop notifier already
works there, and two banners for one blocked agent is worse than one.

A client attached in control mode (`tmux -CC`, how some terminals integrate
with tmux) is never written to. Its connection carries tmux's own protocol
rather than a screen, and escape sequences pushed into it are read as protocol.

roost writes to the tty of the attached **client**, which is the far end of the
SSH connection, not to the agent's pane. Writing to the pane would mean asking
tmux to pass the sequence through, and tmux only passes a sequence through
while that pane is **visible** — which is never the case here, because roost
notifies only when the pane is off-screen. So there is nothing to configure:
`allow-passthrough` is not involved.

### Which sequence your terminal reads

There is more than one of these sequences and no terminal reads all of them.
`@roost-notify-osc-codes` picks which to send, space-separated. The default is
`9`.

| Code | Read by | Notes |
|---|---|---|
| `9` | Ghostty, iTerm2, WezTerm, kitty, Windows Terminal | The default: one field, title and message joined |
| `777` | Ghostty, foot, urxvt, kitty | Title and message in separate fields |
| `99` | kitty | kitty's own protocol; Ghostty 1.3.1 does not read it |

Send more than one only if you know your terminal reads exactly one of them —
a terminal that reads two will raise two notifications for one blocked agent:

```sh
set -g @roost-notify-osc-codes "9 777"
```

A terminal that does not understand a sequence prints nothing: it swallows the
whole string. Some terminals need their own setting turned on first — Ghostty
calls it `desktop-notifications` and has it on by default.

If client discovery cannot see the right terminal, name the tty yourself. It
says *where* to write, not *whether* to: on its own it still waits for a remote
client, so pair it with `on` if you want it unconditional.

```sh
set -g @roost-notify-osc     on
set -g @roost-notify-osc-tty /dev/ttys004
```

A terminal that has stopped reading — a sleeping laptop, a dropped link —
cannot hold anything up: each write is given one second and then abandoned.

Select it as the only backend with `set -g @roost-notify-backend osc`. That
sends the escape sequence and stops — no desktop notifier, no in-tmux message.

## Notifications on your phone, with nothing in the middle

The pieces above are enough to reach a phone without signing up for anything
roost knows about. Three parts, each one you already control:

1. **A push service you choose.** Point `@roost-notify-cmd` at its command or
   its HTTP endpoint. Self-hosted (ntfy, Gotify) or not (Pushover) — roost does
   not care, and never sees an account:

   ```sh
   set -g @roost-notify-cmd 'curl -fsS -d "%s" https://ntfy.example.com/my-fleet >/dev/null'
   ```

   Send the title too if your service takes one; the placeholder rules above
   apply.

2. **A private network back to the fleet.** A mesh VPN (Tailscale, Netbird,
   plain WireGuard) gives the machine a stable address without opening a port
   to the internet. Then SSH is all you need to get back in.

3. **An SSH client on the phone.** Attach to the fleet, read the pane, answer
   the agent. The escape-sequence path above works here too, so a phone
   terminal that supports notifications will raise them while you are attached.

That is "check my fleet from my phone" with nothing between you and your own
machines.

## When nothing fires

See [Troubleshooting](/docs/troubleshooting).
