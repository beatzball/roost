#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/amux-themes.sh"
. "$HERE/scripts/lib/amux-config.sh"

cfgdir="$(mktemp -d /tmp/amx.XXXX)"; export XDG_CONFIG_HOME="$cfgdir"
trap 'rm -rf "$cfgdir"' EXIT
conf="$cfgdir/amux/amux.conf"

# writer creates the file and writes the key
amux_cfg_set @amux-color-bar-bg "#111111"
assert_contains "$(cat "$conf")" 'set -g @amux-color-bar-bg "#111111"' "cfg_set writes the key"

# replace-in-place, no dup, custom lines preserved
printf 'bind X kill-window\n' >> "$conf"
amux_cfg_set @amux-color-bar-bg "#222222"
assert_contains "$(cat "$conf")" 'set -g @amux-color-bar-bg "#222222"' "cfg_set replaces existing key"
assert_eq "$(grep -c '@amux-color-bar-bg' "$conf")" "1" "cfg_set does not duplicate the key"
assert_contains "$(cat "$conf")" 'bind X kill-window' "cfg_set preserves custom lines"

# append when key absent
amux_cfg_set @amux-notify-backend "tmux"
assert_contains "$(cat "$conf")" 'set -g @amux-notify-backend "tmux"' "cfg_set appends a missing key"

# glyphset parity + real bytes (bash 3.2: no \u)
gs="$(amux_glyphset nerd)"
case "$gs" in *'\u'*) assert_eq escape bytes "glyphset writes real bytes, not \\u" ;; *) assert_eq ok ok "glyphset writes real bytes, not \\u" ;; esac
assert_contains "$gs" "$(printf '\xef\x81\xb1')" "glyphset nerd contains U+F071 (blocked)"
assert_eq "$(amux_glyphset emoji)" "🛑 ⏳ ✅ 💤" "glyphset emoji matches the four state emoji"

# sep map
assert_eq "$(amux_sep none)" "" "sep none is empty"
assert_eq "$(amux_sep triangle)" "$(printf '\xee\x82\xb0')" "sep triangle is the U+E0B0 wedge"

# permissions preserved on update
chmod 0644 "$conf"
original_mode="$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null)"
amux_cfg_set @amux-color-bar-bg "#333333"
updated_mode="$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null)"
assert_eq "$updated_mode" "$original_mode" "cfg_set preserves existing file permissions"

# reverse-lookup against a running server
amux_test_server; export AMUX_CONFIG_SOCK="$AMUX_TEST_SOCK"
tmux -S "$AMUX_TEST_SOCK" source-file "$HERE/tmux/amux.conf" >/dev/null 2>&1
set -f; set -- $(amux_theme tokyonight-storm); set +f
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-bg    "$1"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-fg    "$2"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-logo-bg   "$3"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-active-bg "$4"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-active-fg "$5"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-idle-fg   "$6"
assert_eq "$(amux_current_theme)" "tokyonight-storm" "current_theme reverse-lookup matches"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-color-bar-bg "#abcdef"
assert_eq "$(amux_current_theme)" "custom" "current_theme returns custom when off-tuple"

# apply_live makes a config change live: it re-sources base THEN user conf, then
# re-stamps. A distinctive working glyph must be routed through the USER config
# (not a bare set-option), because re-sourcing the base conf resets @amux-glyph-*
# to its defaults first — the user conf is what overrides, exactly as in production.
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-home "$HERE"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-user-conf "$(amux_cfg_path)"
export AMUX_RESTAMP_SOCK="$AMUX_TEST_SOCK"
amux_cfg_set @amux-glyph-working "WW"
w="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{window_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -w -t "$w" @agent_state working
tmux -S "$AMUX_TEST_SOCK" set-option -w -t "$w" @agent_glyph "OLD"
amux_apply_live "$HERE"
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -wqv -t "$w" @agent_glyph)" "WW" "apply_live re-sources user conf + re-stamps (OLD->WW)"
tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null

# fzf-missing: prints an install hint, exits 0 (no crash)
out="$(AMUX_FZF=definitely-not-fzf "$HERE/scripts/amux-settings" </dev/null 2>&1)"; rc=$?
assert_contains "$out" "install fzf" "amux-settings prints install hint when fzf is absent"
assert_eq "$rc" "0" "amux-settings exits 0 when fzf is absent"

# wiring: bin/amux dispatches 'settings'; amux.conf binds S to the TUI
assert_contains "$(cat "$HERE/bin/amux")" "amux-settings" "bin/amux dispatches settings"
assert_contains "$(cat "$HERE/tmux/amux.conf")" "bind S" "amux.conf binds prefix S to settings"

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

# separator round-trip: triangle -> preview none ("" value) -> restore must return
# the wedge, NOT stay empty. (Guards amux_restore against skipping empty values.)
wedge="$(printf '\xee\x82\xb0')"
amux_preview_apply separator triangle
sepsnap="$(mktemp /tmp/amx.XXXX)"
amux_snapshot separator "$sepsnap"
amux_preview_apply separator none
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-sep-left)" "" "preview separator none empties the wedge"
amux_restore separator "$sepsnap"
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-sep-left)" "$wedge" "restore returns the wedge (empty value not skipped)"
rm -f "$sepsnap"

tmux -S "$AMUX_TEST_SOCK" kill-server 2>/dev/null
rm -rf "$pvcfg"; if [ -n "$PV_XDG_SAVE" ]; then export XDG_CONFIG_HOME="$PV_XDG_SAVE"; else unset XDG_CONFIG_HOME; fi

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
