#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/amux-themes.sh"
. "$HERE/scripts/lib/amux-config.sh"

cfgdir="$(mktemp -d /tmp/amx.XXXX)"; export XDG_CONFIG_HOME="$cfgdir"
# amux_test_teardown is a no-op until the first amux_test_server call below
# sets AMUX_TEST_SOCK/AMUX_TEST_SOCKDIR; it's the safety net for whichever
# server is still live at exit. Each of the 3 amux_test_server calls in this
# file OVERWRITES those vars, so the earlier two sockdirs are torn down
# explicitly (below) rather than relying on this trap alone.
trap 'rm -rf "$cfgdir"; amux_test_teardown' EXIT
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
assert_eq "$(amux_glyphset emoji)" "💥 🛑 ⏳ ✅ 💤" "glyphset emoji matches the five state emoji"

# --- the error state's glyph ---
# Canonical order is urgency order (error blocked working done idle), the same
# order the tab badge and the status rollup use, so there is one order to
# remember across the codebase.
for gs in emoji orbs ascii nerd; do
  set -f; set -- $(amux_glyphset "$gs"); set +f
  assert_eq "$#" "5" "glyph set '$gs' has five glyphs"
done

# Every set's error glyph must differ from its other four, or two states render
# identically and the badge stops carrying information.
for gs in emoji orbs ascii nerd; do
  set -f; set -- $(amux_glyphset "$gs"); set +f
  dupes=0
  for g in "$2" "$3" "$4" "$5"; do [ "$g" = "$1" ] && dupes=$((dupes+1)); done
  assert_eq "$dupes" "0" "glyph set '$gs' error glyph is distinct from the other four"
done

assert_contains "$(amux_glyphset nerd)" "$(printf '\xef\x83\xa7')" \
  "glyphset nerd contains U+F0E7 (error)"

# A preview must snapshot and restore the error glyph too, or cancelling out of
# the glyph menu leaves the previewed set's error glyph behind.
assert_contains "$(amux_preview_keys glyphs)" "@amux-glyph-error" \
  "the glyphs preview covers @amux-glyph-error"

# The COMMIT path (picking a glyph set in the menu, not just previewing it)
# must also write @amux-glyph-error to the config file. amux-settings'
# apply_glyphs has no CLI seam of its own (unlike amux_preview_apply, which
# is a testable library function) — the preview path above is covered, the
# commit path was not, the same shape of gap Commit 1's amux-init bug lived
# in. Extract the real function body from the source file (not a
# hand-copied re-implementation, so a future edit to the function is what
# gets tested) and call it directly against a scratch config.
apply_glyphs_src="$(sed -n '/^apply_glyphs() {/,/^}/p' "$HERE/scripts/amux-settings")"
[ -n "$apply_glyphs_src" ] || { echo "FATAL: could not extract apply_glyphs from amux-settings" >&2; exit 1; }
eval "$apply_glyphs_src"
agcfg="$(mktemp -d /tmp/amx.XXXX)"
(
  export XDG_CONFIG_HOME="$agcfg"
  apply_glyphs nerd
)
agconf="$agcfg/amux/amux.conf"
set -f; set -- $(amux_glyphset nerd); set +f
assert_contains "$(cat "$agconf" 2>/dev/null)" "set -g @amux-glyph-error \"$1\"" \
  "apply_glyphs (commit path) writes @amux-glyph-error"
assert_contains "$(cat "$agconf" 2>/dev/null)" "set -g @amux-glyph-idle \"$5\"" \
  "apply_glyphs (commit path) writes the rest of the set too"
rm -rf "$agcfg"

# sep map
assert_eq "$(amux_sep none)" "" "sep none is empty"
assert_eq "$(amux_sep triangle)" "$(printf '\xee\x82\xb0')" "sep triangle is the U+E0B0 wedge"

# permissions preserved on update
chmod 0644 "$conf"
original_mode="$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null)"
amux_cfg_set @amux-color-bar-bg "#333333"
updated_mode="$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null)"
assert_eq "$updated_mode" "$original_mode" "cfg_set preserves existing file permissions"

# An existing user's config file holds four glyphs and no error glyph. It must
# still identify as the set they picked, not fall back to "custom" the moment
# they upgrade.
#
# AMUX_CONFIG_SOCK points at a path with no server, so amux_opt falls through
# to the config file. Without it amux_cfg_tmux would address `-L amux` by name
# and this assertion would read the DEVELOPER'S LIVE SERVER.
(
  export AMUX_CONFIG_SOCK="/nonexistent/amx-no-server"
  set -f; set -- $(amux_glyphset nerd); set +f
  amux_cfg_set @amux-glyph-blocked "$2"
  amux_cfg_set @amux-glyph-working "$3"
  amux_cfg_set @amux-glyph-done    "$4"
  amux_cfg_set @amux-glyph-idle    "$5"
  printf '%s' "$(amux_current_glyphset)"
) > "$cfgdir/glyphset-out"
assert_eq "$(cat "$cfgdir/glyphset-out")" "nerd" \
  "a four-glyph config written before the error state still identifies as its set"

# ...and a genuinely mismatched config is still custom, so the assertion above
# is not just accepting everything.
(
  export AMUX_CONFIG_SOCK="/nonexistent/amx-no-server"
  amux_cfg_set @amux-glyph-blocked "Q"
  printf '%s' "$(amux_current_glyphset)"
) > "$cfgdir/glyphset-out2"
assert_eq "$(cat "$cfgdir/glyphset-out2")" "custom" \
  "a config matching no set still reports custom"

# leave the config file clean for the assertions further down this file
rm -f "$cfgdir/amux/amux.conf"

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

# apply_live makes a config change live: it re-sources base THEN user conf.
# A distinctive working glyph must be routed through the USER config
# (not a bare set-option), because re-sourcing the base conf resets @amux-glyph-*
# to its defaults first — the user conf is what overrides, exactly as in production.
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-home "$HERE"
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-user-conf "$(amux_cfg_path)"
amux_cfg_set @amux-glyph-working "WW"
w="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{window_id}')"
p="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{pane_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -p -t "$p" @agent_state working
amux_apply_live "$HERE"
# A glyph change is live with NO re-stamping: the bar derives the glyph from
# @amux-glyph-<state> at render time, so there is nothing left to go stale.
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-glyph-working)" "WW" \
  "apply_live re-sources the user conf (glyph override wins)"
assert_contains "$(tmux -S "$AMUX_TEST_SOCK" list-windows -a -F '#{E:@amux-tab-badge}')" "WW" \
  "the tab badge picks up the new glyph with no re-stamp"
amux_test_teardown

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
amux_test_server; export AMUX_CONFIG_SOCK="$AMUX_TEST_SOCK"
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

# glyphs preview is live for the tab badge, with nothing stamped
tmux -S "$AMUX_TEST_SOCK" set-option -g @amux-home "$HERE"
p="$(tmux -S "$AMUX_TEST_SOCK" display-message -p '#{pane_id}')"
tmux -S "$AMUX_TEST_SOCK" set-option -p -t "$p" @agent_state working
amux_preview_apply glyphs ascii
assert_contains "$(tmux -S "$AMUX_TEST_SOCK" list-windows -a -F '#{E:@amux-tab-badge}')" "[~]" \
  "preview_apply glyphs is live on the tab badge"

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

amux_test_teardown
rm -rf "$pvcfg"; if [ -n "$PV_XDG_SAVE" ]; then export XDG_CONFIG_HOME="$PV_XDG_SAVE"; else unset XDG_CONFIG_HOME; fi

# ---- --apply-preview CLI seam (Task 3) ----
amux_test_server; export AMUX_CONFIG_SOCK="$AMUX_TEST_SOCK"
tmux -S "$AMUX_TEST_SOCK" source-file "$HERE/tmux/amux.conf" >/dev/null 2>&1
seamcfg="$(mktemp -d /tmp/amx.XXXX)"; SEAM_XDG_SAVE="${XDG_CONFIG_HOME:-}"; export XDG_CONFIG_HOME="$seamcfg"

"$HERE/scripts/amux-settings" --apply-preview theme gruvbox; rc=$?
assert_eq "$rc" "0" "--apply-preview exits 0"
assert_eq "$(tmux -S "$AMUX_TEST_SOCK" show-options -gqv @amux-color-logo-bg)" "#fe8019" "--apply-preview paints the server"
[ -f "$seamcfg/amux/amux.conf" ] && assert_eq wrote no-write "--apply-preview writes NO config" \
  || assert_eq ok ok "--apply-preview writes NO config"

amux_test_teardown
rm -rf "$seamcfg"; if [ -n "$SEAM_XDG_SAVE" ]; then export XDG_CONFIG_HOME="$SEAM_XDG_SAVE"; else unset XDG_CONFIG_HOME; fi
