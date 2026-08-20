# amux settings — live-preview picker + theme roster

**Status:** design
**Date:** 2026-07-22
**Builds on:** 2026-07-21-amux-settings-design.md (the settings TUI this extends)

## Problem

Three refinements to the shipped `amux settings` TUI:

1. **No live feedback while choosing.** Picking a theme/glyph set commits blind —
   you only see the result after Enter. You want to scroll the options and watch
   the bar update live, with **Enter** to commit and **Esc** to revert to the
   prior state.
2. **Two themes are near-twins.** `tokyonight-storm` and `catppuccin-mocha` share
   the muted-purple-on-dark palette (bar `#24283b`/`#1e1e2e`, logo
   `#7aa2f7`/`#89b4fa`, active `#bb9af7`/`#cba6f7`) — indistinguishable in the
   menu. The roster needs genuinely different-hued options.
3. **Glyph sets are named, not shown.** The glyph submenu lists `emoji/orbs/
   ascii/nerd` by name; you can't see the icons you're choosing.

## Scope

In scope:
- A live-preview picker for the **visual** settings: theme, glyphs, separator.
- Glyph submenu renders each set's actual icons inline.
- A saved-value checkmark column in every picker.
- Three new contrast-validated themes: **gruvbox**, **nord**, **rose-pine**.

Out of scope: notifications stays a plain pick (no visual effect to preview);
per-color editing; changing the settings TUI's overall structure.

## Design decisions

- **Preview target:** whole bar. Scrolling a theme applies all 6 `@amux-color-*`
  to the running server live, so you see the complete look (bar, logo chip,
  active tab, idle tabs).
- **Preview writes to the server only** while scrolling — never to the config
  file. Config is written only on commit (Enter).
- **Esc always restores.** A snapshot of the affected options is taken before the
  submenu opens; Esc (submenu) or quitting the TUI mid-preview restores it to the
  server. The server only keeps values you pressed Enter on.
- **Saved-value checkmark:** each picker row has a fixed-width left column —
  `✓ ` on the row whose value is currently saved in the **config file**, two
  spaces otherwise. Fixed width so the moving highlight never repositions text.
  It marks the committed value (computed at submenu entry — when the server and
  config still agree, before any preview — so the existing reverse-lookup
  reflects the saved value), not the previewed one, so it updates only after a
  commit + return to the screen.
- **Graceful fallback:** if no amux server is running, or fzf lacks the `focus`
  event, the picker degrades to a plain selection (no live preview); commit still
  writes config. (Dev machine fzf is 0.67, which supports `focus`.)

## Mechanism

A reusable picker in `scripts/amux-settings`, `preview_pick TYPE` where
TYPE ∈ {theme, glyphs, separator}:

1. **Snapshot** the affected server options to a temp file:
   - theme → the 6 `@amux-color-*`
   - glyphs → the 4 `@amux-glyph-*` **and** each window's `@agent_glyph`
   - separator → `@amux-sep-left` / `@amux-sep-right`
2. **Build the list** (once, at entry): one row per choice, each prefixed with the
   fixed-width checkmark column (saved value marked). For glyphs, append the four
   rendered icons after the name.
3. **Run fzf** with `--bind 'focus:execute-silent($SELF --apply-preview TYPE {chosen-field})'`.
   `--apply-preview` is a hidden mode of `amux-settings` (guarded at the top of
   the script) that applies TYPE=VALUE to the **running server only**:
   `amux_cfg_tmux set-option` the relevant options, `amux-restamp` for glyphs,
   `refresh-client -S`. It never writes config. Socket passes through env.
4. **Enter** (fzf exit 0, non-empty): the server already shows the value → commit:
   `amux_cfg_set` the value(s) into the config file. Discard the snapshot.
5. **Esc / abort** (fzf exit 130, or empty): restore the snapshot to the server
   (re-set the options, `amux-restamp` for glyphs, `refresh-client -S`).

The tmux server is the shared canvas between the parent picker and the
`--apply-preview` subprocesses; the snapshot temp file is the parent's undo
buffer. Committed config and the live server stay in sync because commit writes
the same value the server already shows.

**TUI-quit safety:** the main loop tracks whether a preview is uncommitted and
restores the snapshot on quit, so Esc-ing out of the whole TUI mid-preview can
never leave the server on an uncommitted look.

## New themes

Added to `scripts/amux-themes.sh` (`amux_theme_names` + `amux_theme`), each a
6-value palette `bar-bg bar-fg logo-bg active-bg active-fg idle-fg` derived to
pass `tests/test-contrast.py`:

- **gruvbox** — warm dark: amber/orange logo, green-ish active, cream fg.
- **nord** — cool desaturated blue-grey: frost-blue logo, aurora active.
- **rose-pine** — muted mauve/rose on a deep base.

The validator is the gate: WCAG 4.5 (bar-fg on bar-bg; active-fg on active-bg)
and 3.0 bold (active-fg on logo-bg), plus CIE76 ΔE ≥ 20 for logo-vs-active
distinctness. No palette ships until it passes. These are dark themes; the
light-mode default logic in `amux-init` is unchanged.

## Edge cases

| Case | Behavior |
|---|---|
| No amux server running | Plain pick (no preview); commit writes config. |
| fzf lacks `focus` event | Plain pick; commit writes config. |
| Esc in submenu | Restore snapshot to server; nothing written. |
| Quit TUI mid-preview | Restore snapshot (uncommitted preview never persists). |
| Commit then re-enter submenu | Checkmark now on the new value (rebuilt from config at entry). |
| Glyph preview | `@amux-glyph-*` set + `amux-restamp` so existing windows show it; snapshot restores both option and each window's `@agent_glyph`. |
| Value with glob/space chars | Same `set -f`/quoting discipline as the base TUI; list fields tab-delimited. |

## Testing

The fzf `focus`/preview interaction needs a tty and isn't scripted — the glue is
thin and smoke-tested. All logic lives in testable primitives:

`tests/test-settings.sh` (extend):
- `--apply-preview theme NAME` sets the 6 `@amux-color-*` on the (test-socket)
  server and writes NO config file.
- `--apply-preview glyphs NAME` sets the 4 `@amux-glyph-*` and re-stamps a window.
- Snapshot/restore round-trip: capture → apply-preview a different value →
  restore → server options equal the original.
- Checkmark row-builder: given saved=X, exactly the X row gets `✓ ` and all
  other rows get an equal-width blank prefix (no reflow); assert column widths
  match.
- Glyph rows include the rendered icons for each set.

`tests/test-contrast.py` (extend): add gruvbox/nord/rose-pine to the validated
set; the suite fails if any new palette misses WCAG or ΔE.

Reverse-lookup: `amux_current_theme` returns the new theme names when their
colors are set; `amux_theme_names` includes them.

Full suite green on bash 5 AND bash 3.2; contrast validator green for all 8
themes.

## Docs

README: note that the theme/glyph pickers preview live (Enter commits, Esc
reverts) and list the expanded theme roster.
