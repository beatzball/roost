# roost

```
░░                                        ░░
░░░                                      ░░░
░░░░░░           ░░░░░░░░░░           ░░░░░░
░░░░░░░░░   ░░░░░░░░░░░░░░░░░░░░   ░░░░░░░░░
 ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    ▒░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒
   ▒▒▒▒▒▒░░░░░░░░░░░░▒▒░░░░░░░░░░░░▒▒▒▒▒▒
  ▒▒▒▒▒▒   ▒▒▒▒░░░░░░░░░░░░░░▒▒▒▒   ▒▒▒▒▒▒
  ▒▒▒▒▒   ▒▒▒▓▒▒▒▒░░░░░░░░▒▒▒▒▓▒▒▒   ▒▒▒▒▒
  ▒▒▒▒▒   ▒▒▒▒▒▓▓▓▒▒░░▒░▒▒▓▓▓▒▒▒▒▒   ▒▒▒▒▒
  ▒▒▒▒▒    ▒▒▒▒▒▒▓▓▓▒▒▒▒▓▓▓▒▒▒▒▒▒    ▒▒▒▒▒
  ▒▒▓▒▒▒     ▒▒▒▒▒  ▓▒▒▓  ▒▒▒▒▒     ▒▒▒▓▒▒
   ▒▒▓▓▓▒            ▒▒            ▒▓▓▓▒▒
   ▒▒▒▒▒▓▓                        ▓▓▒▒▒▒▒
     ▒▒▒▒▒▒▒▒       ░░▒▒       ▒▒▒▒▒▒▒▒
       ▒▒▒░░░▒▒░░ ░░░░▒▒▒░ ░░▒▒░░░▒▒▒
         ░░░░░░░░░░░░░░░▒▒░░░░░░░░░
              ░░░░░▒░░░░▒░░░░░
                   ░▒░░▒░
                     ░░
```

An on-demand tmux **agent view** for wrangling multiple AI coding agents —
without giving up your normal tmux setup or switching to a different terminal.

`roost` runs on its **own isolated tmux server** with its own config, so your
everyday `tmux` (config, sessions, plugins, muscle memory) is **never touched**.
Launch it with one command, run your agents as panes or windows inside it,
and each is badged with what its agent is doing:

> 💥 error / needs you · 🛑 blocked / needs you · ⏳ working · ✅ done · 💤 idle

State comes from **Claude Code's own lifecycle hooks** — not from scraping
process names or terminal output — so it's accurate rather than guessed. No
external plugins, no compiled binary, nothing that reaches into `~/.tmux.conf`.

![roost in a real session — the badged agent status bar up top, editor and agent panes below, and the live `roost settings` popup open in the middle](assets/roost-overview.png)

## 📖 Full documentation: [roosting.dev](https://roosting.dev)

Setup, key bindings, driving a fleet of agents, wiring the state badges, and
troubleshooting all live there. What follows is the short version plus what you
need to hack on roost itself.

## Requirements

- `tmux` ≥ 3.2 (needs pane options, `#{P:}` pane loops, and `display-popup`)
- `git`
- A powerline/Nerd Font for the tab separators — or run `roost init` and pick
  the plain-separator fallback
- Claude Code (for the state badges; the view itself works without it)
- Optional: `fzf` (for the `prefix a` agent switcher)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/beatzball/roost/main/install.sh | sh
```

That clones roost to `~/.local/share/roost` and adds its `bin/` to your `PATH`.
It works out which startup file your shell actually reads — `.zshrc` for zsh
(honouring `ZDOTDIR`), `.bash_profile` or `.bashrc` for bash depending on your
platform, `config.fish` for fish — and refuses to add the same line twice.

Options:

```sh
./install.sh --dir ~/tools/roost   # clone somewhere else
./install.sh --symlink             # symlink bin/roost into a PATH dir instead
./install.sh --dry-run             # print what it would do, change nothing
```

Prefer to do it by hand? roost is just a script:

```sh
git clone https://github.com/beatzball/roost.git roost
export PATH="$PWD/roost/bin:$PATH"   # add to your shell's startup file
```

The launcher resolves its own location (following symlinks), so it finds its
config and scripts no matter where you run it from.

## Quick start

```sh
roost doctor   # check tmux version, truecolor, fzf, notifier, hooks
roost init     # pick theme, glyph set, separator style; print the Claude hooks
roost          # start/attach the default session ("main")
```

The prefix is `Ctrl-s`. Detach with `prefix d`, like any tmux.

Badges need a one-time hook setup — run `roost hooks` and merge the output into
`~/.claude/settings.json`. Full walkthrough:
[roosting.dev/docs/state-badges](https://roosting.dev/docs/state-badges).

For LLM agents, install the portable skill so they know the coordination loop:

```sh
npx skills add beatzball/roost --skill roost
```

## Prior art & credit

Watching agent state from inside tmux is a well-trodden idea; `roost` is a
deliberately minimal, isolation-first take on it. If you want a richer,
sidebar-style experience, these projects pioneered the approach and are worth
your time:

- [hiroppy/tmux-agent-sidebar](https://github.com/hiroppy/tmux-agent-sidebar) — a live sidebar with prompts, tool calls, worktrees, subagent trees
- [accessd/tmux-agent-indicator](https://github.com/accessd/tmux-agent-indicator) — pane-border / title / status-icon signals
- [samleeney/tmux-agent-status](https://github.com/samleeney/tmux-agent-status) — sidebar + fzf target switcher
- [craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager) — a popup picker across running Claude sessions
- [flavio87/tap-to-tmux](https://github.com/flavio87/tap-to-tmux) — phone push when an agent needs you

`roost` trades their richness for staying completely out of your primary tmux and
owning nothing but a few small shell files you can read end to end.

---

# Contributing

Everything below is for people working **on** roost.

## Repo layout

```
bin/roost                   # launcher / CLI (up, new, ssh, send, read, wait-done,
                            #   hooks, doctor, init, settings, status, kill)
tmux/roost.conf             # the isolated agent-view config
scripts/roost-agent-state   # hook target that records agent state
                            #   (+ elapsed-time stamp, block notify)
scripts/roost-status        # status-bar roll-up of agent-pane counts
scripts/roost-switch        # fzf agent switcher, panes grouped by window (prefix a)
scripts/roost-notify        # cross-platform desktop notification delivery
scripts/roost-doctor        # preflight checks (tmux version, truecolor, hooks, notifier)
scripts/roost-init          # setup wizard (theme, glyphs, separator style, prints hooks)
scripts/roost-settings      # live settings TUI (prefix S)
scripts/roost-next-blocked  # select the pane that needs you: error, else blocked (prefix b)
scripts/roost-themes.sh     # built-in theme palettes
scripts/lib/roost-config.sh # shared config helpers
                            #   (surgical writer, glyph/sep maps, live-apply)
adapters/opencode/roost.js  # opencode plugin that reports state
skills/roost/SKILL.md       # the portable agent skill
site/                       # the roosting.dev documentation site (Litro, SSG)
tests/                      # the shell test suite
docs/known-gaps.md          # shipped risks and why each was left
```

Everything is plain tmux and bash. `fzf` is needed only for the `prefix a`
switcher (it degrades to a hint if missing).

## How it works

- `bin/roost` starts `tmux -L roost -f tmux/roost.conf` — a second tmux server,
  fully separate from your default one (different socket, different config).
- `tmux/roost.conf` badges each window from its **panes**: one glyph per distinct
  agent state present, urgency-ordered and deduplicated, computed live from
  `#{P:}` so a pane dying never leaves a stale badge. Glyphs are shape-distinct
  (not just colour-distinct), so the bar still reads correctly if you're
  colourblind. Backgrounds mark only which window is **active**, which keeps
  every tab's text high-contrast.
- Claude hooks call `scripts/roost-agent-state <state>`, which stamps the **pane**
  identified by `$TMUX_PANE`, then repaints. Pane scope is what lets two agents
  share one window — `roost split` puts a second agent beside the first without
  either clobbering the other's badge. A pane is an agent only if it has been
  stamped, so a plain shell or a `tail -f` never badges anything.

## Running the tests

```sh
bash tests/run.sh          # the whole suite
python3 tests/test-contrast.py   # theme contrast validator
bash tests/test-panes.sh   # a single file
```

Tests spin up a throwaway tmux server; they do not touch your real one. CI runs
the same two commands on `ubuntu-latest` and `macos-latest`
(`.github/workflows/ci.yml`).

`tests/live/opencode-smoke.sh` drives real opencode against a local model to
check the adapter end to end. It is **not** part of `tests/run.sh` — run it by
hand after an opencode upgrade.

## Working on the docs site

The site in `site/` builds to static HTML and deploys to
[roosting.dev](https://roosting.dev) on every push to `main`.

```sh
cd site
pnpm install
pnpm dev      # http://localhost:3000
pnpm build    # must exit 0
```

Pages are Markdown in `site/content/docs/`. Read
[`site/AGENTS.md`](site/AGENTS.md) before editing — it covers the frontmatter
format, the sidebar, and how to verify a change. Any coding agent should read
that file too.

## Known gaps

[`docs/known-gaps.md`](docs/known-gaps.md) records risks carried by what has
already shipped, and why each was left rather than fixed. Read it before
changing the state vocabulary, the glyph accessor, or the opencode adapter.
