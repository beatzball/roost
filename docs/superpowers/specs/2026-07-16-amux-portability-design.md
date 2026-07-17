# amux portability & first-run setup — design

**Date:** 2026-07-16
**Status:** approved, pending implementation plan

## Goal

Make amux usable by strangers on arbitrary machines. Today it assumes macOS, a
powerline-patched font, a truecolour terminal, and hand-merged Claude hooks —
none of which it checks, and none of which it lets you change. Every visual
choice is hardcoded across 580 lines in four files; there is no config layer at
all (`@amux_home` is internal plumbing, not user config).

**Audience: public release.** Strangers on unknown terminals and OSes, who have
no idea what a powerline font is, may be on Linux or WSL, and don't run dracula.

## Decisions

| Question | Decision |
|---|---|
| Audience | Public release |
| `amux init` scope | Visual config + merge Claude hooks + doctor. **No font install.** |
| Notification | Per-OS backend chain + `@amux-notify-cmd` override |
| Glyph sets | All four: emoji-semantic (default), orbs, ascii, nerd-font |
| Config layer | tmux user options (`@amux-*`), dracula idiom |
| tmux minimum | Bump to 3.1; verify exact floor during implementation |
| Testing | Bash harness + GitHub Actions CI on macOS and Linux |

**Explicitly cut (YAGNI):** font installation, runtime preset resolution,
notifier detection caching, full-screen TUI, configurable notify-on-states.

## Why the wizard is last

A wizard is a front-end to configuration. amux has no configuration. The config
layer is the foundation; the wizard is only what writes to it. Building the
wizard first means building UI for something that doesn't exist.

## Shipping order

Four units, each independently shippable and testable:

| # | Unit | Depends on |
|---|---|---|
| 1 | `scripts/amux-notify` | nothing |
| 2 | Config layer | nothing |
| 3 | `amux doctor` | 2 |
| 4 | `amux init` | 2, 3 |

---

## Unit 1 — `scripts/amux-notify`

Cross-platform notification. Separates the two concerns that are currently
tangled inline in `amux-agent-state`: **when** to notify (agent-state's job) vs
**how** (notify's job).

**Interface:** `amux-notify <title> <message>`

**Backend chain, first match wins:**

1. `@amux-notify-cmd` if set — `%t` → title, `%s` → message
2. macOS (`uname` = Darwin) → `osascript`
3. WSL (`/proc/version` contains `microsoft`) → `powershell.exe` toast
4. Linux **with** `$DISPLAY` or `$WAYLAND_DISPLAY` → `notify-send`
5. fallback → `tmux display-message`

The `$DISPLAY`/`$WAYLAND_DISPLAY` guard in (4) is what keeps a headless remote
(`amux ssh devbox`) from firing `notify-send` into the void; it falls through to
the in-bar message instead.

**Known limitation, to be documented:** a headless remote agent has no desktop to
notify. `@amux-notify-cmd` (ntfy/pushover/Slack) is the supported answer, and is
also the phone-push path that `tap-to-tmux` covers in the README's prior art.

**No detection caching.** It runs only on a `blocked` transition (a few times an
hour) and costs two `command -v` calls. A cached backend is a staleness bug for
no measurable gain.

**`@amux-notify-cmd` runs user-supplied shell.** It's the user's own config
file, so this is acceptable, but it must be documented as such.

## Unit 2 — Config layer

Defaults live in `tmux/amux.conf`. A user file is sourced afterwards, so it wins.

```
@amux-glyph-{blocked,working,done,idle}
@amux-sep-{left,right}        # "" = no powerline font → straight edge
@amux-color-{bar-bg,bar-fg,logo-bg,active-bg,active-fg,idle-fg}
@amux-notify-cmd
```

**Naming convention:**

- `@amux-*` (dash) — user-facing config, matching the `@dracula-*` idiom
- `@agent_*` (underscore) — per-window runtime state
- Rename internal `@amux_home` → `@amux-home` for namespace consistency

**Sourcing.** This is the bug class that already bit this repo twice (literal
`#{@amux_home}` paths in `source-file` and `display-popup`). `tmux/amux.conf` is
parsed by `new-session -f` **before** `bin/amux` sets any options, so it cannot
reference `@amux-home` at parse time.

Therefore `bin/amux` sources the user file itself after boot, and `bind r`
re-sources both, in order:

```
source-file -F "#{@amux-home}/tmux/amux.conf" \; source-file -qF "#{@amux-user-conf}"
```

This also sidesteps whether tmux expands `~` in `source-file`, and lets
`bin/amux` honour `$XDG_CONFIG_HOME`.

**Refactor this enables.** `amux-agent-state` stops hardcoding glyphs and reads
`@amux-glyph-$state` on a state change. The script then knows only *states*;
config owns *appearance*. Formats stay simple (`#{@agent_glyph}`) rather than
needing a nested conditional lookup table, and the existing early-return keeps
the common path at one IPC call.

**Presets are expanded, not resolved.** `amux init` writes explicit values
(`@amux-glyph-blocked "🛑"`), not `@amux-glyphs "emoji"`. Runtime preset lookup
would need a lookup table in tmux format syntax. p10k does the same. Cost:
changing sets later means re-running `amux init` or editing four lines.

## Unit 3 — `amux doctor`

Preflight checks, useful standalone:

- tmux ≥ **3.1** — the real minimum (`source-file -F` and `display-popup` both
  landed in 3.1; the README's ≥3.0 claim is wrong and ships broken `prefix r`
  and `prefix a` on 3.0)
- `$COLORTERM` truecolor — the entire palette is `#rrggbb`
- `fzf` present — `prefix a` switcher degrades without it
- which notify backend resolved on this machine
- `python3` present — required to merge Claude hooks
- whether the four Claude hooks are actually wired in `settings.json`
- prints the wedge: "box or triangle? → run `amux init`"

During implementation, audit **every** tmux feature used (format conditionals,
`#{E:}`, `#{?}`, `-q`, `-F`) to pin the true floor rather than assume 3.1.

## Unit 4 — `amux init`

Plain `read -r` prompts. Not a full-screen TUI — p10k's wizard is thousands of
lines; amux is 580 total, and the wizard must not dwarf the tool.

**Four questions:**

1. **Powerline check** — print the wedge, ask box-or-triangle → `@amux-sep-*`
2. **Glyph set** — emoji / orbs / ascii / nerd, each rendered inline.
   Nerd-font offered **only if** (1) answered triangle.
3. **Theme** — default / dracula / mono → `@amux-color-*`
4. **Merge Claude hooks?** → back up `settings.json`, merge via `python3`,
   falling back to printing the JSON for manual merge

**Behaviour:**

- Writes explicit values to `$XDG_CONFIG_HOME/amux/amux.conf`
  (default `~/.config/amux/amux.conf`)
- Idempotent; backs up any existing config before writing
- Refuses to run on a non-tty rather than hanging on `read`

**Font detection is not solvable.** A shell cannot query the terminal's font.
p10k doesn't try either — it draws the glyph and asks. Question (1) copies that,
deliberately.

## Data flow

```
Claude hook → amux-agent-state <state>
  ├─ early-return if state+glyph already correct   (the common path: 1 IPC call)
  ├─ read @amux-glyph-$state                        (config lookup, on change only)
  ├─ stamp @agent_state + @agent_glyph on the window
  ├─ if blocked AND window not active → amux-notify "amux · $wname" "needs your input"
  │                                       └─ backend chain
  └─ refresh-client -S

status tick   → amux-status  → reads @agent_state/@agent_glyph per window → counts
prefix a      → amux-switch  → reads @agent_glyph per window
```

`amux-agent-state` remains the single source of truth for state→glyph. The
switcher and the rollup read glyphs **back off the windows** rather than keeping
their own copies — they had each drifted into a private hardcoded map before.

## Error handling

**Governing rule: `amux-agent-state` runs inside every Claude tool call and must
never break Claude.** Keep `|| true` and `exit 0` throughout.

| Failure | Behaviour |
|---|---|
| user config file missing | `source-file -q`, silent |
| glyph option empty/unset | fall back to built-in default (a truncated config must not blank the bar) |
| notify backend missing | chain to next; final fallback `tmux display-message`; never fail the hook |
| `python3` missing at init | print the JSON, instruct manual merge |
| init on non-tty | refuse with a message; never hang on `read` |
| existing config / settings.json | back up before writing |

## Testing

The repo has **zero tests today**. Every bug this session shipped silently: the
wedge vanishing from edits, literal `#{}` paths in two keybindings, the stuck
`blocked` state, an unmatched `Notification` hook. All were mechanically
detectable.

**Harness:** small bash runner, no framework. Spins tmux on a temp socket, drives
the scripts, asserts options. **Socket paths must be short** — the ~104-char
unix socket limit produced a false PASS on empty strings earlier in this work.

**Backend matrix without cross-platform CI:** shim `osascript`, `notify-send`,
and `powershell.exe` onto `PATH` and assert which one got invoked. This tests
backend *selection* on any machine.

**CI:** GitHub Actions on macOS and Linux runners. This gives real OS coverage of
backend *selection* (macOS resolves osascript; a headless Linux runner has no
`$DISPLAY`, so it naturally exercises the tmux fallback), while the PATH shims
cover *delivery*. Runners need tmux + fzf installed.

**Coverage:**

- each glyph set renders
- user config overrides default
- backend selection per faked environment
- early-return skips writes when state is unchanged
- glyph repair when state is set but glyph is missing (upgrade path)
- `doctor` exit codes
- **`prefix r` and `prefix a` actually work** — both were broken, nothing caught it
- emitted hook JSON is valid and matches the README's documented hook count

## Open items to verify during implementation

1. Exact tmux floor — audit every feature used, don't assume 3.1
2. `source-file -q` genuinely suppresses errors for a missing file
3. `$XDG_CONFIG_HOME` handling in `bin/amux`
4. Whether nerd-font glyph widths are stable (PUA codepoints have no fallback
   rendering; the same class of problem as the wedge)
5. PUA characters (wedge, nerd-font glyphs) do not survive normal file edits —
   they must be written as explicit bytes and verified by codepoint
