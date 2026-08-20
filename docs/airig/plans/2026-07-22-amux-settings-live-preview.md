# amux settings — live-preview picker + theme roster — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `amux settings` theme/glyph/separator pickers preview live on the running bar (Enter commits, Esc reverts), show glyph icons inline with a saved-value checkmark, and add three visually-distinct validated themes.

**Architecture:** New testable primitives in `scripts/lib/amux-config.sh` (server-only preview apply, snapshot/restore, checkmark row builder); a hidden `--apply-preview` mode in `scripts/amux-settings` that fzf's `focus` binding re-invokes on cursor-move; the submenus become a `preview_pick` that snapshots → previews-on-focus → commits on Enter / restores on Esc. Three new palettes added to `scripts/amux-themes.sh`, gated by the existing contrast validator.

**Tech Stack:** POSIX-ish bash (must run under bash 3.2), tmux (`-L amux`), fzf (`focus` event, ≥~0.30), python3 (validator only).

## Global Constraints

- **tmux floor 3.1; bash 3.2** (macOS `/bin/bash`) — no `printf '\uXXXX'`, only `\xHH` byte escapes. No literal `\u` in any shipped output.
- **Preview writes to the running server ONLY** (`set-option -g`, `refresh-client`, `amux-restamp`) — never to the config file. Config is written only on commit (`amux_cfg_set`).
- **Esc always restores** the pre-preview server state; only Enter-committed values persist.
- **Never break a running agent / never abort:** `set -u`, guard every tmux call (`2>/dev/null || true`), preview/restore/`--apply-preview` always exit 0.
- **Socket seams:** production `-L amux`; tests use `AMUX_CONFIG_SOCK` (lib) and `AMUX_RESTAMP_SOCK` (restamp). `amux_cfg_tmux` already encapsulates this.
- **noglob discipline:** every `set -- $(amux_theme …)` / `$(amux_glyphset …)` word-split is wrapped in `set -f` / `set +f` (ascii glyphs `[!] [~] [+]` are globs).
- **Theme palettes are gated by `tests/test-contrast.py`:** WCAG 4.5 (bar-fg/bar-bg, idle-fg/bar-bg, active-fg/active-bg), 3.0 (active-bg/bar-bg, active-fg/logo-bg bold), CIE76 ΔE ≥ 20 (logo-bg vs active-bg). No palette ships until it passes.
- Tests pass under bash 5 AND bash 3.2; `tests/run.sh` auto-discovers `test-*.sh`.

---

## File Structure

- Modify `scripts/amux-themes.sh` — add gruvbox / nord / rose-pine to `amux_theme_names` + `amux_theme`.
- Modify `scripts/lib/amux-config.sh` — add `amux_menu_row`, `amux_preview_keys`, `amux_preview_apply`, `amux_snapshot`, `amux_restore` (+ a one-time `_AMUX_LIB_DIR` at source).
- Modify `scripts/amux-settings` — add the `--apply-preview` seam, a `focus`-support probe, `preview_rows` + `preview_pick`, and wire them into the main loop.
- Create `tests/test-themes.sh` — roster + validator guard.
- Modify `tests/test-settings.sh` — lib preview primitives + the `--apply-preview` seam.
- Modify `README.md` — live-preview note + expanded roster.

---

### Task 1: Three validated themes

**Files:**
- Modify: `scripts/amux-themes.sh`
- Test: `tests/test-themes.sh` (new)

**Interfaces:**
- Produces: `amux_theme_names` now emits 8 names; `amux_theme gruvbox|nord|rose-pine` each echo 6 space-separated hex values in role order `bar-bg bar-fg logo-bg active-bg active-fg idle-fg`.

- [ ] **Step 1: Write the failing test** — `tests/test-themes.sh`

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/amux-themes.sh"

# the three new themes exist and return 6 values each
for t in gruvbox nord rose-pine; do
  n=$(amux_theme "$t" | wc -w | tr -d ' ')
  assert_eq "$n" "6" "theme $t returns 6 colour values"
done
# roster now lists 8 themes and includes the new ones
assert_eq "$(amux_theme_names | wc -l | tr -d ' ')" "8" "roster lists 8 themes"
assert_contains "$(amux_theme_names)" "gruvbox" "roster includes gruvbox"
assert_contains "$(amux_theme_names)" "nord" "roster includes nord"
assert_contains "$(amux_theme_names)" "rose-pine" "roster includes rose-pine"
# unknown theme still fails
amux_theme not-a-theme >/dev/null 2>&1 && assert_eq ok fail "unknown theme returns non-zero" \
  || assert_eq ok ok "unknown theme returns non-zero"

# the contrast validator is the gate: every shipped theme (incl. the 3 new) passes
if command -v python3 >/dev/null 2>&1; then
  python3 "$HERE/tests/test-contrast.py" >/dev/null 2>&1 \
    && assert_eq ok ok "all themes pass the contrast validator" \
    || assert_eq fail ok "all themes pass the contrast validator"
else
  assert_eq ok ok "contrast validator skipped (no python3)"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-themes.sh`
Expected: FAIL — `theme gruvbox returns 6 colour values` gets `0` (theme not defined yet).

- [ ] **Step 3: Add the three themes** — `scripts/amux-themes.sh`

Change the names line to:

```bash
amux_theme_names() { printf '%s\n' amux catppuccin-mocha catppuccin-latte tokyonight-storm tokyonight-day gruvbox nord rose-pine; }
```

And add these three cases inside `amux_theme`, before the `*) return 1 ;;` line (values are validator-verified: gruvbox ΔE 60.7, nord 35.8, rose-pine 35.4; all WCAG checks pass):

```bash
    gruvbox)          echo "#282828 #ebdbb2 #fe8019 #b8bb26 #1d2021 #a89984" ;;
    nord)             echo "#2e3440 #eceff4 #88c0d0 #b48ead #242830 #a7b0c0" ;;
    rose-pine)        echo "#191724 #e0def4 #9ccfd8 #ebbcba #191724 #908caa" ;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-themes.sh` and `python3 tests/test-contrast.py`
Expected: test-themes all PASS; validator prints `PASS` for all 8 themes and exits 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/amux-themes.sh tests/test-themes.sh
git commit -m "feat(themes): add validated gruvbox, nord, rose-pine"
```

---

### Task 2: Live-preview lib primitives

**Files:**
- Modify: `scripts/lib/amux-config.sh`
- Test: `tests/test-settings.sh` (append)

**Interfaces:**
- Consumes: `amux_theme`, `amux_glyphset`, `amux_sep`, `amux_cfg_tmux` (existing); `scripts/amux-restamp` (Task 3 of the prior plan, already shipped).
- Produces:
  - `amux_menu_row SAVED VALUE SUFFIX` → prints `VALUE<TAB>` + a fixed 2-col mark (`✓ ` if `SAVED`==`VALUE`, else two spaces) + `VALUE` + `SUFFIX`. The leading `VALUE<TAB>` is a hidden key column for the caller.
  - `amux_preview_keys TYPE` → the space-separated `@`-options a preview of TYPE (`theme|glyphs|separator`) touches.
  - `amux_preview_apply TYPE VALUE` → apply TYPE=VALUE to the **running server only** (set-option + refresh; glyphs also restamp). No config write. Always returns 0.
  - `amux_snapshot TYPE FILE` → write current server values of TYPE's options to FILE (`key<TAB>value` lines).
  - `amux_restore TYPE FILE` → re-apply a snapshot to the server (+ restamp for glyphs).

- [ ] **Step 1: Write the failing tests** — append to `tests/test-settings.sh`

```bash
# ---- live-preview primitives (Task 2) ----
# menu_row: fixed-width mark, saved row gets the check, others two spaces
row_saved="$(amux_menu_row nord nord '')"
row_other="$(amux_menu_row nord amux '')"
assert_eq "$row_saved" "$(printf 'nord\t\xe2\x9c\x93 nord')" "menu_row marks the saved value with a check"
assert_eq "$row_other" "$(printf 'amux\t  amux')" "menu_row pads unsaved rows with two spaces (no reflow)"

# preview primitives against a running server; assert NO config write
amux_test_server; export AMUX_CONFIG_SOCK="$AMUX_TEST_SOCK"; export AMUX_RESTAMP_SOCK="$AMUX_TEST_SOCK"
tmux -S "$AMUX_TEST_SOCK" source-file "$HERE/tmux/amux.conf" >/dev/null 2>&1
pvcfg="$(mktemp -d /tmp/amx.XXXX)"; PV_XDG_SAVE="${XDG_CONFIG_HOME:-}"; export XDG_CONFIG_HOME="$pvcfg"

amux_preview_apply theme nord
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-color-bar-bg)" "#2e3440" "preview_apply theme sets server colours"
[ -f "$pvcfg/amux/amux.conf" ] && assert_eq wrote no-write "preview_apply writes NO config file" \
  || assert_eq ok ok "preview_apply writes NO config file"

# snapshot/restore round-trip: A -> preview B -> restore -> back to A
set -f; set -- $(amux_theme gruvbox); set +f
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-bg "$1"
snap="$(mktemp /tmp/amx.XXXX)"
amux_snapshot theme "$snap"
amux_preview_apply theme rose-pine
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-color-bar-bg)" "#191724" "preview moved the server to rose-pine"
amux_restore theme "$snap"
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-color-bar-bg)" "#282828" "restore returns the server to the snapshot"
rm -f "$snap"

# glyphs preview re-stamps a window
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-home "$HERE"
w="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{window_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -w -t "$w" @agent_state working
amux_preview_apply glyphs ascii
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -wqv -t "$w" @agent_glyph)" "[~]" "preview_apply glyphs re-stamps windows"

tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null
rm -rf "$pvcfg"; if [ -n "$PV_XDG_SAVE" ]; then export XDG_CONFIG_HOME="$PV_XDG_SAVE"; else unset XDG_CONFIG_HOME; fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `amux_menu_row: command not found`.

- [ ] **Step 3: Add the primitives** — append to `scripts/lib/amux-config.sh`

```bash
# Directory of this lib (scripts/lib), used to locate sibling scripts (amux-restamp).
_AMUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# amux_menu_row SAVED VALUE SUFFIX -> "VALUE<TAB><mark>VALUE<SUFFIX>".
# <mark> is a fixed 2-col "✓ " (saved) or "  " (not), so the highlight moving
# during preview never repositions the text. Field 1 (VALUE) is a hidden key.
amux_menu_row() {
  local saved="$1" value="$2" suffix="${3:-}" mark
  if [ "$saved" = "$value" ]; then mark="✓ "; else mark="  "; fi
  printf '%s\t%s%s%s\n' "$value" "$mark" "$value" "$suffix"
}

# amux_preview_keys TYPE -> the @-options a preview of TYPE touches.
amux_preview_keys() {
  case "$1" in
    theme)     echo "@amux-color-bar-bg @amux-color-bar-fg @amux-color-logo-bg @amux-color-active-bg @amux-color-active-fg @amux-color-idle-fg" ;;
    glyphs)    echo "@amux-glyph-blocked @amux-glyph-working @amux-glyph-done @amux-glyph-idle" ;;
    separator) echo "@amux-sep-left @amux-sep-right" ;;
  esac
}

# _amux_restamp -> run the sibling amux-restamp against the current (test or prod)
# server. AMUX_CONFIG_SOCK empty in prod -> amux-restamp falls back to -L amux.
_amux_restamp() { AMUX_RESTAMP_SOCK="${AMUX_CONFIG_SOCK:-}" "$_AMUX_LIB_DIR/../amux-restamp" 2>/dev/null || true; }

# amux_preview_apply TYPE VALUE -> apply to the RUNNING server only (no config write).
amux_preview_apply() {
  local type="$1" value="$2" s
  case "$type" in
    theme)
      set -f; set -- $(amux_theme "$value"); set +f
      [ "$#" -eq 6 ] || return 0
      amux_cfg_tmux set-option -g @amux-color-bar-bg    "$1" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-color-bar-fg    "$2" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-color-logo-bg   "$3" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-color-active-bg "$4" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-color-active-fg "$5" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-color-idle-fg   "$6" 2>/dev/null || true
      ;;
    glyphs)
      set -f; set -- $(amux_glyphset "$value"); set +f
      [ "$#" -eq 4 ] || return 0
      amux_cfg_tmux set-option -g @amux-glyph-blocked "$1" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-working "$2" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-done    "$3" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-glyph-idle    "$4" 2>/dev/null || true
      _amux_restamp
      ;;
    separator)
      s="$(amux_sep "$value")"
      amux_cfg_tmux set-option -g @amux-sep-left  "$s" 2>/dev/null || true
      amux_cfg_tmux set-option -g @amux-sep-right "$s" 2>/dev/null || true
      ;;
  esac
  amux_cfg_tmux refresh-client -S 2>/dev/null || true
}

# amux_snapshot TYPE FILE -> capture current server values of TYPE's options.
amux_snapshot() {
  local type="$1" file="$2" k v
  : > "$file"
  for k in $(amux_preview_keys "$type"); do
    v="$(amux_cfg_tmux show-options -gqv "$k" 2>/dev/null)"
    printf '%s\t%s\n' "$k" "$v" >> "$file"
  done
}

# amux_restore TYPE FILE -> re-apply a snapshot to the server (+ restamp glyphs).
amux_restore() {
  local type="$1" file="$2" k v tab
  [ -f "$file" ] || return 0
  tab="$(printf '\t')"
  while IFS="$tab" read -r k v; do
    [ -n "$k" ] && amux_cfg_tmux set-option -g "$k" "$v" 2>/dev/null || true
  done < "$file"
  [ "$type" = glyphs ] && _amux_restamp
  amux_cfg_tmux refresh-client -S 2>/dev/null || true
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-settings.sh` and `/bin/bash tests/test-settings.sh`
Expected: PASS — all prior assertions plus the new menu_row / preview / snapshot-restore / glyph-restamp ones.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/amux-config.sh tests/test-settings.sh
git commit -m "feat(settings): live-preview lib primitives (apply/snapshot/restore/row)"
```

---

### Task 3: Wire live preview into amux-settings + docs

**Files:**
- Modify: `scripts/amux-settings`
- Modify: `tests/test-settings.sh` (append the `--apply-preview` seam test)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–2 plus existing `amux_current_theme`, `amux_current_glyphset`, `amux_cfg_set`, `apply_theme`, `apply_glyphs`.
- Produces: `amux-settings --apply-preview TYPE VALUE` (hidden CLI seam that fzf re-invokes); live-preview submenus for theme/glyphs/separator.

- [ ] **Step 1: Write the failing test** — append to `tests/test-settings.sh`

```bash
# ---- --apply-preview CLI seam (Task 3) ----
amux_test_server; export AMUX_CONFIG_SOCK="$AMUX_TEST_SOCK"; export AMUX_RESTAMP_SOCK="$AMUX_TEST_SOCK"
tmux -S "$AMUX_TEST_SOCK" source-file "$HERE/tmux/amux.conf" >/dev/null 2>&1
seamcfg="$(mktemp -d /tmp/amx.XXXX)"; SEAM_XDG_SAVE="${XDG_CONFIG_HOME:-}"; export XDG_CONFIG_HOME="$seamcfg"

"$HERE/scripts/amux-settings" --apply-preview theme gruvbox; rc=$?
assert_eq "$rc" "0" "--apply-preview exits 0"
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-color-logo-bg)" "#fe8019" "--apply-preview paints the server"
[ -f "$seamcfg/amux/amux.conf" ] && assert_eq wrote no-write "--apply-preview writes NO config" \
  || assert_eq ok ok "--apply-preview writes NO config"

tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null
rm -rf "$seamcfg"; if [ -n "$SEAM_XDG_SAVE" ]; then export XDG_CONFIG_HOME="$SEAM_XDG_SAVE"; else unset XDG_CONFIG_HOME; fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-settings.sh`
Expected: FAIL — `--apply-preview paints the server` gets empty/default (seam not implemented; the unknown arg falls through to the fzf menu path).

- [ ] **Step 3: Add the seam + probe** — `scripts/amux-settings`

Immediately after the two `. "$HERE/…"` source lines (currently lines 7–8) and BEFORE the `FZF=` / fzf-missing check, insert:

```bash
SELF="$HERE/amux-settings"

# Hidden mode: fzf's focus binding re-invokes us to paint a live preview onto the
# running server (server-only, no config write). Runs before the fzf check so it
# works headlessly.
if [ "${1:-}" = "--apply-preview" ]; then
  amux_preview_apply "${2:-}" "${3:-}"; exit 0
fi
```

Then, immediately after the existing fzf-missing check (after the `fi` that closes `if ! command -v "$FZF" …`), add the focus-support probe:

```bash
# fzf >= ~0.30 supports the 'focus' event (fires on cursor move). Probe once so
# older fzf silently degrades to a plain (non-preview) pick.
if printf 'x\n' | "$FZF" --sync --filter=x --bind 'focus:ignore' >/dev/null 2>&1; then
  AMUX_FOCUS=1; else AMUX_FOCUS=0; fi
```

- [ ] **Step 4: Add `preview_rows` + `preview_pick`** — `scripts/amux-settings`

After the existing `apply_glyphs() { … }` function (currently ends ~line 32), add:

```bash
# preview_rows TYPE SAVED -> fzf rows (hidden value col + checkmark + label[+icons]).
preview_rows() {
  local type="$1" saved="$2" n icons pad
  case "$type" in
    theme)     for n in $(amux_theme_names); do amux_menu_row "$saved" "$n" ""; done ;;
    glyphs)    for n in emoji orbs ascii nerd; do
                 icons="$(amux_glyphset "$n")"
                 pad="$(printf '%*s' "$((7 - ${#n}))" '')"   # align icons across rows
                 amux_menu_row "$saved" "$n" "$pad$icons"
               done ;;
    separator) for n in triangle none; do amux_menu_row "$saved" "$n" ""; done ;;
  esac
}

# preview_pick TYPE SAVED -> echo the chosen value on Enter, empty on Esc.
# With a live server + focus-capable fzf: snapshot, preview on cursor-move, and
# restore on Esc. Otherwise a plain pick (commit still writes config downstream).
preview_pick() {
  local type="$1" saved="$2" snap sel
  if [ "$AMUX_FOCUS" = 1 ] && amux_cfg_tmux has-session 2>/dev/null; then
    snap="$(mktemp "${TMPDIR:-/tmp}/amux-snap.XXXXXX")"
    amux_snapshot "$type" "$snap"
    sel="$(preview_rows "$type" "$saved" \
      | "$FZF" --reverse --no-info --delimiter='\t' --with-nth=2 \
               --bind "focus:execute-silent('$SELF' --apply-preview '$type' {1})" \
               --prompt="$type > " | cut -f1)"
    if [ -n "$sel" ]; then rm -f "$snap"
    else amux_restore "$type" "$snap"; rm -f "$snap"; fi
  else
    sel="$(preview_rows "$type" "$saved" \
      | "$FZF" --reverse --no-info --delimiter='\t' --with-nth=2 --prompt="$type > " | cut -f1)"
  fi
  printf '%s' "$sel"
}
```

- [ ] **Step 5: Wire the submenus into the main loop** — `scripts/amux-settings`

Replace the three case branches (`theme)`, `glyphs)`, `separator)`) with the preview versions (the `notifications)` and `quit|"")` branches stay as-is):

```bash
    theme)   v="$(preview_pick theme "$ct")"; [ -n "$v" ] && apply_theme "$v" ;;
    glyphs)  v="$(preview_pick glyphs "$cg")"; [ -n "$v" ] && apply_glyphs "$v" ;;
    separator) v="$(preview_pick separator "$cs")"
               [ -n "$v" ] && { s="$(amux_sep "$v")"; amux_cfg_set @amux-sep-left "$s"; amux_cfg_set @amux-sep-right "$s"; } ;;
```

(Note: `ct`/`cg`/`cs` are computed at the top of the loop, when the server and config agree — so the checkmark always marks the saved value. A submenu-Esc restores before returning here, so quitting the TUI from the main menu is always on a committed/restored state; no extra quit-time restore is needed.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/test-settings.sh` and `/bin/bash tests/test-settings.sh`
Expected: PASS — including the `--apply-preview` seam assertions. Then `bash -n scripts/amux-settings && /bin/bash -n scripts/amux-settings` (syntax OK both).

- [ ] **Step 7: Document in README**

In `README.md`, in the "Changing settings later" section added by the prior plan, add after the existing paragraph:

```markdown
The **theme** and **glyph** pickers preview live: as you move through the list
the bar updates on the running server, **Enter** commits the choice, and **Esc**
reverts to what you had. The currently-saved option is marked with a `✓`.
```

And update the theme list wherever the README enumerates themes to include `gruvbox`, `nord`, and `rose-pine` (search for `tokyonight` / `catppuccin`).

- [ ] **Step 8: Run the full suite**

Run: `bash tests/run.sh` then `/bin/bash tests/run.sh` then `python3 tests/test-contrast.py`
Expected: both suites `N passed, 0 failed` (with new `test-themes.sh` and the extended `test-settings.sh`); validator PASS for all 8 themes.

- [ ] **Step 9: Commit**

```bash
git add scripts/amux-settings tests/test-settings.sh README.md
git commit -m "feat(settings): live-preview theme/glyph/separator pickers + saved-value check"
```

---

## Self-Review notes (for the implementer)

- **Server-only preview:** `amux_preview_apply`, `--apply-preview`, `amux_snapshot`, `amux_restore` never call `amux_cfg_set` — verify no config file is written during a preview (the tests assert the file's absence). Only the main-loop commit path (`apply_theme`/`apply_glyphs`/`amux_cfg_set`) writes config.
- **Esc restore:** `preview_pick`'s abort branch (`sel` empty) calls `amux_restore` before returning. Confirm the snapshot temp file is always removed on both paths.
- **noglob:** every `set -- $(amux_theme …)` / `$(amux_glyphset …)` in the new lib code is `set -f`-wrapped.
- **Byte-safety:** the `✓` (U+2713) in `amux_menu_row` and the test's `\xe2\x9c\x93` must match. No `\u` escapes anywhere.
- **Fallback:** with `AMUX_FOCUS=0` or no server, `preview_pick` uses the plain branch and commit still writes config. `_amux_restamp` passes an empty `AMUX_RESTAMP_SOCK` in production so amux-restamp targets `-L amux`.
```
