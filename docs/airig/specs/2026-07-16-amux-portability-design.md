# amux portability & first-run setup — design

**Date:** 2026-07-16
**Status:** approved, pending implementation plan

## Goal

Make amux usable by the public, on arbitrary machines. Today it assumes macOS, a
powerline-patched font, a truecolour terminal, and hand-merged Claude hooks —
none of which it checks, and none of which it lets you change. Every visual
choice is hardcoded across 580 lines in four files; there is no config layer at
all (`@amux_home` is internal plumbing, not user config).

**Audience: public release.** People on unknown terminals and OSes, who have no
idea what a powerline font is, may be on Linux or WSL, and don't run dracula.

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
| Themes | amux default, catppuccin (mocha + latte), tokyo night (storm + day) |
| Light mode | Asked in `amux init`, pre-filled from `$COLORFGBG`. No runtime detection. |
| Notifications | Opt-in asked up front; declining goes straight to the in-bar fallback |
| Install | `curl \| sh` installer, published at `beatzball/amux` |

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
| 2 | Config layer (incl. themes + contrast validator) | nothing |
| 3 | `amux doctor` | 2 |
| 4 | `amux init` | 2, 3 |
| 5 | `install.sh` (`curl \| sh`) | 4, **and the repo being published** |

Unit 5 is last because it is the only one blocked on an external fact: the repo
must exist at `github.com/beatzball/amux` before an installer can fetch from it.
Units 1-4 need no URL and can land first.

---

## Unit 1 — `scripts/amux-notify`

Cross-platform notification. Separates the two concerns that are currently
tangled inline in `amux-agent-state`: **when** to notify (agent-state's job) vs
**how** (notify's job).

**Interface:** `amux-notify <title> <message>`

**Opt-in.** `@amux-notify-backend` gates the whole chain, because OS-level
notifications are not universally wanted:

| value | behaviour |
|---|---|
| `auto` (default) | full chain below |
| `tmux` | skip the OS entirely, go straight to the in-bar fallback |
| `none` | silent |

`amux init` asks this **first**, before any OS detection. Declining writes
`tmux`, so a user who doesn't want desktop popups never triggers one.

**Backend chain (when `auto`), first match wins:**

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
@amux-notify-backend          # auto | tmux | none
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

### Themes

Each theme is six `@amux-color-*` values. Shipping:

| theme | mode | notes |
|---|---|---|
| `amux` | dark | current default (`#211e38` bar, `#bd93f9` active) |
| `catppuccin-mocha` | dark | |
| `catppuccin-latte` | **light** | |
| `tokyonight-storm` | dark | |
| `tokyonight-day` | **light** | |

Catppuccin is a *family* (latte/frappé/macchiato/mocha), not a theme — shipping
mocha + latte covers one dark and one light without carrying all four.

**Light themes invert a design rule.** On amux's dark bar the wedge had to be
*lighter* than the bar (`#bd93f9`, 6.7:1; a darker `#5b4fc4` managed only 2.6:1
and faded out). On a light bar (`catppuccin-latte` `#eff1f5`) the opposite
holds — the wedge must be *darker* or it vanishes. The architecture already
handles this, since the formats read colours from config and never assume a
direction. But it means each theme is a design job, not a palette swap.

### Contrast validator (the load-bearing piece)

**Every colour bug in this project was caught only by running WCAG maths by
hand** — light-on-amber at 1.9:1, dark-on-idle at 2.1:1, the invisible dark
wedge at 2.6:1. Five themes across light and dark, checked by eye, will ship
something unreadable.

So the validator is a **test, not a script**: for every shipped theme, assert

| pair | minimum |
|---|---|
| bar-fg on bar-bg | 4.5:1 (AA) |
| idle-fg on bar-bg | 4.5:1 (AA) |
| active-fg on active-bg | 4.5:1 (AA) |
| active-bg on bar-bg (the wedge) | 3:1 — it must be *visible*, not readable |
| logo-bg vs active-bg | ΔE ≥ 20 (CIE76) — the complaint that started this |

The logo/active pair uses **perceptual distance (ΔE), not contrast** — two
purples can share a luminance and still look different, which contrast (a
luminance ratio) cannot see. ΔE ≥ 20 is calibrated from the amux default the
user accepted (logo/active measured 23.4). Implementation found all four
upstream palettes failed the naive luminance check; the corrected validator and
the tuned palettes live in the plan.

A theme with a failing ratio cannot merge. This runs in CI and is the single
highest-value item in this batch: it mechanically prevents the exact class of
bug that consumed most of this session.

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

**Five questions, in this order:**

1. **OS notifications?** — asked first, before any detection. No → writes
   `@amux-notify-backend tmux` and the OS chain is never consulted.
2. **Powerline check** — print the wedge, ask box-or-triangle → `@amux-sep-*`
3. **Light or dark terminal?** — pre-filled from `$COLORFGBG` when set, but
   always confirmed. Filters the theme list in (4) to matching variants.
4. **Theme + glyph set** — themes filtered by (3); glyph sets rendered inline,
   with nerd-font offered **only if** (2) answered triangle.
5. **Merge Claude hooks?** → back up `settings.json`, merge via `python3`,
   falling back to printing the JSON for manual merge

> **Shipped as print-only:** `amux init` prints the hook JSON for the user to
> paste into `settings.json`; it does not write that file. This matches the
> installer's "print, don't edit the user's config" stance. python3 is therefore
> not a runtime dependency (test-only).

**Behaviour:**

- Writes explicit values to `$XDG_CONFIG_HOME/amux/amux.conf`
  (default `~/.config/amux/amux.conf`)
- Idempotent; backs up any existing config before writing
- Refuses to run on a non-tty rather than hanging on `read`

**Font detection is not solvable.** A shell cannot query the terminal's font.
p10k doesn't try either — it draws the glyph and asks. Question (2) copies that,
deliberately.

**Light mode is asked, not detected.** `$COLORFGBG` is set by only some
terminals and lies on others; OSC 11 needs tmux passthrough, a read timeout, and
can hang on terminals that ignore it. So `$COLORFGBG` only *pre-fills* the
answer — the user always confirms. There is no runtime adaptation: a user who
switches their terminal to light mode re-runs `amux init`.

## Unit 5 — `install.sh` (`curl | sh`)

**Blocked on publishing.** The repo is currently local-only with no git remote.
The installer bakes in a canonical URL and cannot be tested end-to-end until
`github.com/beatzball/amux` exists. Units 1-4 are unblocked and land first.

```sh
curl -fsSL https://raw.githubusercontent.com/beatzball/amux/main/install.sh | sh
```

**What it does:**

1. Preflight — reuse `amux doctor`'s checks (tmux ≥ 3.1 etc.) and **fail before
   touching anything** if unmet
2. Fetch to `$XDG_DATA_HOME/amux` (default `~/.local/share/amux`) — `git clone`
   when git exists, else curl a tarball
3. Make `amux` reachable — symlink if possible, else print (see below)
4. Hand off to `amux init` if on a tty; otherwise print the command to run

**PATH: never edit the user's shell rc.** The installer does not touch
`.zshrc`, `.bashrc`, `.profile`, or fish config. Editing shell startup files
from a piped-curl script is the most invasive thing this design could do, and it
buys very little: it needs backups, idempotency, and per-shell syntax branching,
and it can leave a broken shell if it goes wrong. Homebrew's installer prints
next steps rather than editing; amux does the same.

Instead:

1. If a writable directory **already on `$PATH`** exists (prefer
   `~/.local/bin`), symlink `amux` into it → works immediately, nothing to print
2. Otherwise, **print** the exact line to add, and stop

Only symlink into a directory that is *already* on `PATH`. Creating
`~/.local/bin` when it isn't on `PATH` helps nobody — the user would still need
the export line, and now there's a stray directory too.

**Shell detection survives, but only to print the right snippet** — never to
apply it. `export PATH=...` is wrong for fish (`fish_add_path`), so `$SHELL`
still decides *what to print*. The failure mode degrades from "corrupted shell
rc" to "printed a line the user ignores".

Because `amux` may not be on `PATH` yet, the installer invokes `amux init` by
absolute path.

**Also needed:** `amux update` (git pull / re-fetch) and a documented uninstall.
Uninstall is now just: remove the data dir, the symlink, and the Claude hooks —
there is no rc line to hunt down, because we never wrote one.

**Security posture.** `curl | sh` asks for a lot of trust. Mitigations: serve
only over HTTPS from the canonical repo; keep the script short and readable;
document `curl -fsSL <url> | less` first; never require sudo.

**Synergy:** `amux ssh devbox` already requires amux installed on the remote.
The installer makes that a documented one-liner.

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
- **every shipped theme passes the contrast thresholds**, light and dark
- `install.sh` never writes to any shell rc file (asserted: rc files byte-identical after a run)
- `install.sh` symlinks when a PATH dir is available, and prints instructions when not
- `install.sh` preflight fails cleanly on tmux < 3.1 without mutating anything

## Open items to verify during implementation

1. Exact tmux floor — VERIFIED 3.1: gated only by source-file -F + display-popup; #{E:} (2.9), #{==:} (2.4), refresh-client -S (1.7) all predate it
2. `source-file -q` genuinely suppresses errors for a missing file
3. `$XDG_CONFIG_HOME` handling in `bin/amux`
4. Whether nerd-font glyph widths are stable (PUA codepoints have no fallback
   rendering; the same class of problem as the wedge)
5. PUA characters (wedge, nerd-font glyphs) do not survive normal file edits —
   they must be written as explicit bytes and verified by codepoint
6. Exact catppuccin and tokyo night hex values — take from the official palettes,
   then run every one through the contrast validator before shipping. Do not
   assume an upstream palette passes: these are designed for editor text, not for
   a 1-cell wedge against a bar.
7. `$COLORFGBG` reliability — which terminals set it, and whether its value can be
   trusted enough even to pre-fill the light/dark answer
8. Whether `~/.local/bin` is on `PATH` by default on the target platforms, since
   that decides how often the user gets a manual step instead of a working symlink
