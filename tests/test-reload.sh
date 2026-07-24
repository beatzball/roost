#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
amux_test_server; sock="$AMUX_TEST_SOCK"; trap amux_test_teardown EXIT
T source-file "$HERE/tmux/amux.conf"
T set-option -g @amux-home "$HERE"

# prefix r: source-file -F must expand #{@amux-home}, not pass it literally
out="$(T source-file -F "#{@amux-home}/tmux/amux.conf" 2>&1)"
assert_eq "$out" "" "prefix r reload sources cleanly (no literal-path error)"

# prefix r also re-stamps existing window glyphs (glyph/theme change is live)
assert_contains "$(cat "$HERE/tmux/amux.conf")" "amux-restamp" "prefix r reload re-stamps glyphs"
