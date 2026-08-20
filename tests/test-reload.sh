#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
roost_test_server; sock="$ROOST_TEST_SOCK"; trap roost_test_teardown EXIT
T source-file "$HERE/tmux/roost.conf"
T set-option -g @roost-home "$HERE"

# prefix r: source-file -F must expand #{@roost-home}, not pass it literally
out="$(T source-file -F "#{@roost-home}/tmux/roost.conf" 2>&1)"
assert_eq "$out" "" "prefix r reload sources cleanly (no literal-path error)"

# glyph changes need no re-stamping: nothing stamps glyphs any more. The
# needle stays "amux-restamp", not a renamed "roost-restamp" — this re-stamper
# was retired back in the amux half and never existed under any roost name;
# renaming the needle would make the assertion pass for the wrong reason.
case "$(cat "$HERE/tmux/roost.conf")" in
  *amux-restamp*) assert_eq present absent "the retired re-stamper is gone from the conf" ;;
  *)              assert_eq ok ok          "the retired re-stamper is gone from the conf" ;;
esac
