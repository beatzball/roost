# amux

An on-demand tmux **agent view** for wrangling multiple AI coding agents —
without giving up your normal tmux setup or switching to a different terminal.

`amux` runs on its **own isolated tmux server** with its own config, so your
everyday `tmux` (config, sessions, plugins, muscle memory) is **never touched**.
Launch it with one command, run your agents as panes or windows inside it,
and each is badged with what its agent is doing:

> 🛑 blocked / needs you · ⏳ working · ✅ done · 💤 idle

State comes from **Claude Code's own lifecycle hooks** — not from scraping
process names or terminal output — so it's accurate rather than guessed. No
external plugins, no compiled binary, nothing that reaches into `~/.tmux.conf`.

![amux in a real session — the badged agent status bar up top, editor and agent panes below, and the live `amux settings` popup open in the middle](assets/amux-overview.png)

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

- `tmux` ≥ 3.2  (needs pane options, `#{P:}` pane loops, and `display-popup`)
- `git`
- A powerline/Nerd Font for the tab separators — or run `amux init` and pick the
  plain-separator fallback
- Claude Code (for the state badges; the view itself works without it)
- Optional: `fzf` (for the `prefix a` agent switcher)

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

## Setup

```sh
amux doctor   # check tmux version, truecolor, fzf, notifier, hooks
amux init     # pick theme, glyph set, separator style; print the Claude hooks
```

`amux init` writes `~/.config/amux/amux.conf` and is safe to re-run (it backs up
the previous file). Reload a running amux with `prefix + r`.

**Upgrading a running server:** `prefix + r` also migrates any leftover
window-scoped agent state from before per-pane state existed, so a server you
started on an older amux upgrades in place — no restart needed. To do it
without touching a pane (e.g. from outside amux), run
`scripts/amux-migrate-state` once instead.

**Themes:** `amux`, `catppuccin-mocha`, `catppuccin-latte`, `tokyonight-storm`,
`tokyonight-day`, `gruvbox`, `nord`, `rose-pine`. Pick one in `amux init`, or
set `@amux-color-*` options by hand in `~/.config/amux/amux.conf`.

### Changing settings later

`amux settings` opens an fzf menu to change the **theme**, **glyph set**,
**separator**, and **notifications** — one at a time. Each pick applies live to
the running server (no restart) and is saved to `~/.config/amux/amux.conf`.
Inside amux, press **`prefix S`** (`Ctrl-s S`) to open it right where you are.

Unlike `amux init` (which regenerates the whole config), `amux settings` edits
just the one line it changes, leaving any hand-added config untouched.

The **theme**, **glyph**, and **separator** pickers preview live: as you move through the list
the bar updates on the running server, **Enter** commits the choice, and **Esc**
reverts to what you had. The currently-saved option is marked with a `✓`.

![The glyph-set picker drilled down — each set (emoji, orbs, ascii, nerd) shows its own icons, and `✓` marks the one currently saved](assets/amux-settings-glyphs.png)

## Use

```sh
amux             # start/attach the default session ("main")
amux session a   # start/attach a named session — as many as you like
amux session b   # a second workspace, sharing the same server
amux new api     # open a new agent window named "api" and attach
amux status      # list running sessions + agents and their states
amux kill a      # kill session "a" (omit the name to stop the whole server)
amux settings    # change theme/glyphs/separator/notifications, live
```

Detach with the prefix then `d`, like any tmux. Inside `amux`, run your agents
as windows (`claude`, `codex`, `aider`, …) and the status bar shows one badged
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
| `prefix S` | **settings** — fzf menu to change theme/glyphs/separator/notifications, live |

### At-a-glance signals

- **Status bar counts** — the top-right shows the whole herd rolled up, e.g.
  `🛑4 ⏳1 ✅3` (blocked / working / done), so you see the picture even when the
  window tabs scroll off. Counts are ordered by how much they want your
  attention, and the glyphs are read back off the windows, so they can never
  disagree with the tabs.
- **Desktop notification** — when an agent you're *not* looking at becomes
  blocked (needs input), amux pings you with a native desktop notification. Only
  `blocked` notifies — `done` fires every turn and would be noise. Delivery is
  cross-platform, tried in this order: macOS (`osascript`), WSL (`BurntToast` via
  `powershell.exe`), Linux (`notify-send`, when a display is
  present), falling back to an in-tmux
  `display-message` if nothing else is available (e.g. a headless remote
  session with no OS notifier reachable). Set `@amux-notify-backend` to `tmux`
  to always use the in-tmux message, or `none` to disable notifications
  entirely; the default is `auto`.

  For full control, set `@amux-notify-cmd` to your own command — `%t` is
  replaced with the title and `%s` with the message, e.g.:

  ```sh
  set -g @amux-notify-cmd 'notify-send "%t" "%s"'
  ```

  Reference the placeholders double-quoted (`"%s"`) or bare — never
  single-quoted, since `%t`/`%s` are wired to shell positional parameters
  (`$1`/`$2`) before your command runs, and single quotes would suppress that
  substitution. Because the swap is textual, avoid combining the placeholders
  with a command that needs a *literal* `%t` or `%s` of its own (e.g.
  `date +%s`) — the two would collide.
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

### Driving agents from inside amux

An agent (or you) can coordinate the fleet from inside amux. Targets are
stable ids (e.g. `%12`) captured from `spawn`/`split`/`whoami` — capture them
in a variable and reuse them; friendly `session:index`/name forms still work
too.

- `amux whoami` — this agent's own target (its `%N`)
- `amux spawn NAME [cmd]` — open a co-agent **window** without attaching; prints its `%N`
- `amux split [-h|-v] [-t P] [-n NAME] [cmd]` — a helper **pane** in your current window (prints its `%N`); compose layouts by splitting a specific pane, `-n NAME` labels it (border, tab, switcher) instead of showing the raw process name
- `amux send TARGET "…"` — reliably type a prompt into an agent and submit it
- `amux wait-done TARGET` / `amux read TARGET` — wait for it to finish, then read the reply

`amux send` verifies its own submit rather than trusting a fire-and-forget
`send-keys`, and its exit code says what went wrong: **exit 2** means the
target is unusable — it doesn't exist, or its pane is dead — re-resolve the
target. **Exit 1** means delivery to a valid target failed — either the text
never reached the pane (typing itself failed) or it was typed but never left
the input line even after retrying extra Enters — retry the same target or
inspect the pane, don't re-resolve it. A missing argument also exits 1, but
as a `usage:` line rather than an `amux send:` one — that's a caller bug, not
a delivery failure.

`spawn` (window) is for a co-agent you `wait-done` on independently; `split`
(pane) is for a helper you `send`/`read` in-place — a pane's state is shared
with its window, so `wait-done` on it isn't per-pane.

For LLM agents, install the portable skill so they know the loop:

```sh
npx skills add beatzball/amux --skill amux    # or copy skills/amux/SKILL.md into your agent's instructions
```

### Remote agents

Run agents on another machine and drive them from here — tmux-native, no daemon
(amux must be installed on the remote):

```sh
amux ssh devbox         # ssh -t devbox amux  → attach the remote agent view
amux ssh devbox new api # forward any subcommand to the remote amux
```

## Enable the state badges (one-time)

The badges are driven by four Claude Code hooks. Print the snippet:

```sh
amux hooks
```

Merge it into your `~/.claude/settings.json` (under `"hooks"`). It wires:

| Claude hook | state |
|-------------|-------|
| `UserPromptSubmit` | ⏳ working |
| `Notification` (matcher: `permission_prompt`) | 🛑 blocked |
| `PostToolUse` | ⏳ working |
| `Stop` | ✅ done |

Two of those are subtler than they look:

- **`Notification` must be scoped to `permission_prompt`.** Unmatched, it also
  fires for `idle_prompt` and `auth_success` — so a *finished* agent would go red.
- **`PostToolUse` is what clears 🛑.** No hook fires when you answer a permission
  dialog, so it's the first observable event after you approve. Without it a
  window stays red from your approval until the whole turn ends.

`scripts/amux-agent-state` is a **no-op unless it runs inside an amux pane**, so
it's safe in your global Claude settings — running `claude` elsewhere does
nothing. It also returns early when the state is already correct, which keeps it
cheap on `PostToolUse` (that fires on every single tool call, and Claude waits
for the hook to exit).

## How it works

- `bin/amux` starts `tmux -L amux -f tmux/amux.conf` — a second tmux server,
  fully separate from your default one (different socket, different config).
- `tmux/amux.conf` badges each window from its **panes**: one glyph per distinct
  agent state present, urgency-ordered and deduplicated, computed live from
  `#{P:}` so a pane dying never leaves a stale badge. Glyphs are shape-distinct
  (not just colour-distinct), so the bar still reads correctly if you're
  colourblind. Backgrounds mark only which window is **active**, which keeps
  every tab's text high-contrast.
- Claude hooks call `scripts/amux-agent-state <state>`, which stamps the **pane**
  identified by `$TMUX_PANE`, then repaints. Pane scope is what lets two agents
  share one window — `amux split` puts a second agent beside the first without
  either clobbering the other's badge. A pane is an agent only if it has been
  stamped, so a plain shell or a `tail -f` never badges anything.

## Layout

```
bin/amux                 # launcher / CLI (up, new, ssh, send, read, wait-done, hooks, doctor, init, settings, status, kill)
tmux/amux.conf           # the isolated agent-view config
scripts/amux-agent-state # hook target that records agent state (+ elapsed-time stamp, block notify)
scripts/amux-status      # status-bar roll-up of agent-pane counts
scripts/amux-switch      # fzf agent switcher, panes grouped by window (prefix a)
scripts/amux-notify      # cross-platform desktop notification delivery
scripts/amux-doctor      # preflight checks (tmux version, truecolor, hooks, notifier)
scripts/amux-init        # setup wizard (theme, glyphs, separator style, prints hooks)
scripts/amux-settings    # live settings TUI (prefix S) — change theme/glyphs/separator/notifications
scripts/amux-migrate-state # clear pre-pane-state window options from a running server (used by reload)
scripts/amux-next-blocked  # select the next blocked agent pane (prefix b)
scripts/amux-themes.sh   # built-in theme palettes
scripts/lib/amux-config.sh # shared config helpers (surgical writer, glyph/sep maps, live-apply)
```

Requires `fzf` for the `prefix a` switcher (it degrades to a hint if missing);
everything else is plain tmux + bash.
