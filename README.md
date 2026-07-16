# amux

An on-demand tmux **agent view** for wrangling multiple AI coding agents —
without giving up your normal tmux setup or switching to a different terminal.

`amux` runs on its **own isolated tmux server** with its own config, so your
everyday `tmux` (config, sessions, plugins, muscle memory) is **never touched**.
Launch it with one command, run your agents as windows inside it, and each
window is coloured by what its agent is doing:

> 🔴 blocked / needs you · 🟡 working · 🔵 done · 🟢 idle

State comes from **Claude Code's own lifecycle hooks** — not from scraping
process names or terminal output — so it's accurate rather than guessed. No
external plugins, no compiled binary, nothing that reaches into `~/.tmux.conf`.

## Prior art & credit

Watching agent state from inside tmux is a well-trodden idea; `amux` is a
deliberately minimal, isolation-first take on it. If you want a richer,
sidebar-style experience, these projects pioneered the approach and are worth
your time:

- [hiroppy/tmux-agent-sidebar](https://github.com/hiroppy/tmux-agent-sidebar) — a live sidebar with prompts, tool calls, worktrees, subagent trees
- [accessd/tmux-agent-indicator](https://github.com/accessd/tmux-agent-indicator) — pane-border / title / status-icon signals
- [samleeney/tmux-agent-status](https://github.com/samleeney/tmux-agent-status) — sidebar + fzf target switcher
- [craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager) — a popup picker across running Claude sessions
- [flavio87/tap-to-tmux](https://github.com/flavio87/tap-to-tmux) — phone push when an agent needs you

`amux` trades their richness for staying completely out of your primary tmux and
owning nothing but a few small shell files you can read end to end.

## Requirements

- `tmux` ≥ 3.0
- `git`
- Claude Code (for the state colours; the view itself works without it)

## Install

`amux` is just a script — put `bin/` on your `PATH`. Clone it wherever you keep
tools, then either add its `bin/` to `PATH` or symlink the launcher:

```sh
git clone <this-repo> amux

# option A — add bin/ to PATH (in ~/.zshrc):
echo 'export PATH="$HOME/path/to/amux/bin:$PATH"' >> ~/.zshrc && exec zsh

# option B — symlink onto an existing PATH dir:
ln -s "$PWD/amux/bin/amux" /usr/local/bin/amux
```

The launcher resolves its own location (following symlinks), so it finds its
config and scripts no matter where you run it from.

## Use

```sh
amux             # start/attach the default session ("main")
amux session a   # start/attach a named session — as many as you like
amux session b   # a second workspace, sharing the same server
amux new api     # open a new agent window named "api" and attach
amux status      # list running sessions + agents and their states
amux kill a      # kill session "a" (omit the name to stop the whole server)
```

Detach with the prefix then `d`, like any tmux. Inside `amux`, run your agents
as windows (`claude`, `codex`, `aider`, …) and the status bar shows one coloured
tab per agent — so you can see who's blocked at a glance.

**Sessions** all share one server, so the status counts and the `prefix a`
switcher roll up across every session — `amux session a` and `amux session b`
give you separate workspaces you attach/reattach independently, while still
seeing the whole herd in one place.

**Window names** auto-follow each agent's project (the basename of its working
directory), so an agent in `~/work/api` shows up as `api`. Give a window an
explicit name with `amux new NAME` or the rename key and it sticks.

### Keys

The prefix is **`Ctrl-s`** and the bindings mirror a typical GNU-Screen-style
tmux config, so there's nothing new to learn:

| key | action |
|-----|--------|
| `prefix c` | new agent window |
| `prefix -` / `prefix _` | split stacked / side-by-side |
| `prefix h j k l` | move between panes |
| `prefix H J K L` | resize pane (repeatable) |
| `prefix > / <` | swap pane forward / back |
| `prefix C-c` | new session |
| `prefix a` | **agent switcher** — fzf popup of all agents + state + elapsed time |
| `prefix b` | **jump to the next blocked agent** (needs your input) |
| `prefix r` | reload amux config |

### At-a-glance signals

- **Status bar counts** — the top-right shows the whole herd rolled up, e.g.
  `●4 ●1 ●3` (blocked / working / done), so you see the picture even when the
  window tabs scroll off.
- **Desktop notification** — when an agent you're *not* looking at becomes
  blocked (needs input), amux pings you with a native macOS notification. Only
  `blocked` notifies — `done` fires every turn and would be noise.
- **Elapsed time** — the `prefix a` switcher shows how long each agent has been
  in its current state, so a stuck agent stands out. It's computed only when you
  open the switcher — nothing extra runs on the status tick.

## Driving a fleet

amux exposes tmux's scripting as small agent-shaped commands, so you (or a
script, or one agent) can drive the others:

```sh
amux send api "run the tests"   # type a prompt + Enter into the "api" agent
amux read api 20                # print that agent's last 20 non-blank lines
amux wait-done api              # block until "api" is done/idle
amux wait-done api 300          # ...with a 5-minute timeout
```

Targets are `[SESSION:]WINDOW` — a bare name (`api`) resolves against the
default `main` session; qualify it (`amux send b:api …`, or by index `b:2`) to
reach an agent in another session.

Combine them to orchestrate parallel work:

```sh
for w in api web worker; do amux send "$w" "update the changelog"; done
for w in api web worker; do amux wait-done "$w"; done
echo "all three agents finished"
```

### Remote agents

Remote agents in one line of tmux — run agents on another machine and drive
them from here (amux must be installed on the remote):

```sh
amux ssh devbox         # ssh -t devbox amux  → attach the remote agent view
amux ssh devbox new api # forward any subcommand to the remote amux
```

## Enable the state colours (one-time)

The colours are driven by three Claude Code hooks. Print the snippet:

```sh
amux hooks
```

Merge it into your `~/.claude/settings.json` (under `"hooks"`). It wires:

| Claude hook | state |
|-------------|-------|
| `UserPromptSubmit` | 🟡 working |
| `Notification` (permission / waiting) | 🔴 blocked |
| `Stop` | 🔵 done |

`scripts/amux-agent-state` is a **no-op unless it runs inside an amux pane**, so
it's safe in your global Claude settings — running `claude` elsewhere does
nothing.

## How it works

- `bin/amux` starts `tmux -L amux -f tmux/amux.conf` — a second tmux server,
  fully separate from your default one (different socket, different config).
- `tmux/amux.conf` renders each window's background from a per-window option,
  `@agent_color`, defaulting to a dim idle colour.
- Claude hooks call `scripts/amux-agent-state <state>`, which stamps the window
  owning `$TMUX_PANE` with the state + colour, then repaints.

## Layout

```
bin/amux                 # launcher / CLI (up, new, ssh, send, read, wait-done, hooks, status, kill)
tmux/amux.conf           # the isolated agent-view config
scripts/amux-agent-state # hook target that records agent state (+ elapsed-time stamp, block notify)
scripts/amux-status      # status-bar roll-up of agent-state counts
scripts/amux-switch      # fzf agent switcher (prefix a)
```

Requires `fzf` for the `prefix a` switcher (it degrades to a hint if missing);
everything else is plain tmux + bash.
