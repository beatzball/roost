# amux settings — live settings TUI

**Status:** design
**Date:** 2026-07-21

## Problem

Changing a single amux setting (theme, glyph set, separator, notifications)
currently means re-running the whole `amux init` wizard, which regenerates the
entire config from a linear series of prompts. That is a poor interaction for
"I just want to flip the theme." We want a `amux settings` TUI that reads the
current settings, lets you change one on the fly, and applies it live to the
running server with no restart.

A related papercut, fixed here too: after a config reload the color changes are
instant but window state glyphs lag until each agent next changes state, because
the status bar draws each window's stamped `@agent_glyph` (set by the hook), not
the `@amux-glyph-<state>` *definition*. Reload should re-stamp existing windows
so a glyph/theme switch is fully live in one keypress.

## Scope

In scope — the same knobs `amux init` exposes:

- **theme** (the 5 named themes in `amux-themes.sh` → 6 `@amux-color-*` values)
- **glyph set** (`emoji` / `orbs` / `ascii` / `nerd` → 4 `@amux-glyph-*`)
- **separator** (`triangle` / `none` → `@amux-sep-left` / `@amux-sep-right`)
- **notifications** (`on` / `off` → `@amux-notify-backend` `auto` / `tmux`)

Out of scope (deferred): per-color hex editing, `@amux-notify-cmd`, arbitrary
custom separators, any option the TUI doesn't name. These remain hand-editable.

## Design decisions

- **Apply model:** live on each toggle. Picking a value writes the config,
  reloads the running server, and re-stamps glyphs immediately, then returns to
  the menu. "Save," "apply," and "reload" are one action. No staging/discard.
- **Interface:** fzf, reusing the `amux-switch` pattern (two-level menu in a
  loop). If fzf is absent, print `install fzf to use amux settings` and exit 0,
  exactly like the switcher. No plain-menu fallback in v1.
- **File writeback:** surgical per-key. Replace just the one
  `set -g @amux-KEY "..."` line in place (append if missing), leaving every
  other line — including hand-added custom keybinds/options — untouched.
- **Launch surface:** both `amux settings` (subcommand) and a `prefix S`
  keybind that opens it in a `display-popup -E`.

## Architecture & decomposition

The fzf UI is thin glue; all real logic lives in primitives that are testable
without a tty.

| Piece | Responsibility | Depends on |
|---|---|---|
| `scripts/amux-settings` | fzf glue: render main menu with current values → submenu → call a primitive → loop. No business logic. | fzf, libs below |
| `scripts/lib/amux-config.sh` (sourced) | `amux_cfg_set KEY VAL` (surgical, atomic write); `amux_glyphset NAME` (4 glyphs); `amux_sep NAME` (wedge/none); `amux_current_theme` / `amux_current_glyphset` (reverse-lookup running values → name or `custom`); `amux_apply_live` | amux-themes.sh |
| `scripts/amux-restamp` | Re-stamp every window's `@agent_glyph` from the current `@amux-glyph-<state>` set. Standalone + called by reload. | tmux |
| wiring | `bin/amux settings` subcommand; `bind S` popup; `bind r` gains a restamp step. | — |

The glyph-set and separator maps currently **inline in `amux-init`** move into
`amux-config.sh` (`amux_glyphset`, `amux_sep`) so init and settings can't drift
— identical bytes, one source. `amux-init` starts sourcing `amux-config.sh` and
calls those helpers; its generated output stays byte-identical.

`lib/` is a new subdir under `scripts/` for sourced (non-executable) helpers.
`amux-themes.sh` may stay where it is (already sourced from `scripts/`); the new
lib sources it by relative path.

## Interaction flow

Launch: `amux settings` or `Ctrl-s S` (`display-popup -E amux-settings`). If fzf
absent → print install hint, exit 0.

Main menu (fzf, re-rendered each loop with live current values):

```
theme          tokyonight-storm >
glyphs         nerd             >
separator      triangle         >
notifications  on               >
quit
```

Current values are read from the running server when one exists
(`tmux -L amux show-options -gqv`), else parsed from the user config file so the
menu works with no server running (a fresh config with no key → the base
default, surfaced as its named value or `custom`). Reverse-lookup:

- `theme` — `amux_current_theme`: compare the 6 `@amux-color-*` values to each
  theme tuple → name, else `custom`.
- `glyphs` — `amux_current_glyphset`: compare the 4 `@amux-glyph-*` → name, else
  `custom`.
- `separator` — `@amux-sep-left`: wedge → `triangle`, empty → `none`.
- `notifications` — `@amux-notify-backend`: `tmux` → `off`, else → `on`.

Select a row → submenu fzf of that setting's choices (themes from
`amux_theme_names`; glyphs `emoji/orbs/ascii/nerd`; separator `triangle/none`;
notifications `on/off`). Pick → apply → loop back to the main menu showing the
new value. `quit` or `Esc` exits.

## Apply sequence (per pick)

1. **Write** relevant key(s) via `amux_cfg_set` — surgical, atomic (write temp
   in the target dir, `mv` over the file). Theme = 6 lines, glyph set = 4,
   separator = 2, notifications = 1.
2. **Apply live** via `amux_apply_live`: if the amux server is running
   (`tmux -L amux has-session`), `source-file` the base conf then `-qF` the user
   conf, run `amux-restamp`, then `refresh-client -S`. If no server, skip
   silently — the file is written and takes effect on next start.

## Reload + restamp coupling

`bind r` gains the restamp so a glyph/theme switch is fully live in one keypress:

```
bind r source-file -F "#{@amux-home}/tmux/amux.conf" \
   \; source-file -qF "#{@amux-user-conf}" \
   \; run-shell "#{@amux-home}/scripts/amux-restamp" \
   \; display "amux config reloaded"
```

`amux-restamp`: for each window across all sessions, read `@agent_state`, look
up `@amux-glyph-<state>` (fallback to the idle glyph), set `@agent_glyph`.
Idempotent, guarded, never changes a window's actual state. Because
`amux_apply_live` calls the same script, the settings TUI inherits the fix for
free.

## Edge cases

| Case | Behavior |
|---|---|
| fzf missing | Print `install fzf to use amux settings`, exit 0. |
| No amux server | Config written; live-apply skipped silently. |
| No user config yet | `amux_cfg_set` creates `$XDG_CONFIG_HOME/amux/` + file, writes the header once for a new file, appends the key. |
| Key absent in existing config | Appended (append-if-missing path). |
| Value with special chars / glyphs | Written double-quoted; glyphs/wedge as real UTF-8 bytes, never `\u` (bash 3.2 has no `printf \u`). |
| Values match no named theme/glyph set | Menu shows `custom`; picking a named value overwrites cleanly. |
| Partial/concurrent write | Atomic temp+`mv`; target never torn. |
| `Esc` at any menu | Clean exit; every prior pick already applied. |
| Popup vs shell | Same code path; `refresh-client -S` updates the bar behind the popup. |

## Testing

The fzf loop needs a tty and isn't scripted; all logic sits in primitives that
are. `amux-settings` is thin glue, covered only by a smoke check.

`tests/test-settings.sh` (new), against a throwaway `amux_test_server`:

- Surgical writer: replaces an existing `@amux-KEY` line; appends when missing;
  preserves unrelated/custom lines; value double-quoted.
- Atomic: target never left empty/partial.
- Glyph-set parity: `amux_glyphset nerd` bytes == bytes `amux-init` writes; no
  `\u` escapes.
- Theme reverse-lookup: known theme colors → its name; off-tuple → `custom`.
- Apply-live: on a running test server, applying a theme sets `@amux-color-*`
  live; applying a glyph set + restamp updates `@agent_glyph` on a window with a
  known `@agent_state`.
- No-server: writes the file, exits 0, no error.

`tests/test-restamp.sh` (new): `state=working` window → `amux-restamp` sets its
`@agent_glyph` to `@amux-glyph-working`; unknown/empty state → idle glyph;
multiple sessions covered.

Existing suites: `test-init.sh` still passes after the map extraction (output
byte-identical); `test-reload.sh` extended to assert `prefix r` re-stamps a
stale glyph. CI runs everything on ubuntu + macos under bash 5 and bash 3.2.

## Docs

README: document `amux settings` and the `prefix S` keybind under Setup/Usage;
note that changes apply live and persist to `~/.config/amux/amux.conf`. `bin/amux`
usage header gains a `settings` line.
