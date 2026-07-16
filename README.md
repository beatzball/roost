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
amux            # start the agent view, or attach if it's already running
amux new api    # open a new agent window named "api" and attach
amux status     # list agent windows and their states
amux kill       # tear down the amux server
```

Detach with the prefix then `d`, like any tmux. Inside `amux`, run your agents
as windows (`claude`, `codex`, `aider`, …) and the status bar shows one coloured
tab per agent — so you can see who's blocked at a glance.

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
| `prefix b` | **jump to the next blocked agent** (needs your input) |
| `prefix r` | reload amux config |

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
bin/amux                 # launcher / CLI
tmux/amux.conf           # the isolated agent-view config
scripts/amux-agent-state # hook target that records agent state
```
