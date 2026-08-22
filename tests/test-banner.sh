#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BANNER="$HERE/scripts/roost-banner"

# every named variant renders something
for v in braille blocks outline; do
  out="$("$BANNER" "$v")"
  assert_eq "$([ -n "$out" ] && echo yes)" "yes" "variant $v renders"
done

# an unknown variant fails rather than printing nothing and claiming success
"$BANNER" nonsense >/dev/null 2>&1
assert_eq "$?" "1" "unknown variant exits non-zero"

# braille is offered on a UTF-8 terminal and withheld otherwise. A missing
# braille font renders as a row of boxes, so this is the difference between
# charming and broken.
got="$(LC_ALL=en_US.UTF-8 TERM=xterm-256color; . "$BANNER"; roost_banner_variants)"
assert_contains "$got" "braille" "braille offered on a UTF-8 terminal"

got="$(LC_ALL=C TERM=xterm-256color; . "$BANNER"; roost_banner_variants)"
case "$got" in
  *braille*) assert_eq "offered" "withheld" "braille withheld without a UTF-8 locale" ;;
  *)         assert_eq "withheld" "withheld" "braille withheld without a UTF-8 locale" ;;
esac

# the Linux virtual console has no braille glyphs whatever the locale claims
got="$(LC_ALL=en_US.UTF-8 TERM=linux; . "$BANNER"; roost_banner_variants)"
case "$got" in
  *braille*) assert_eq "offered" "withheld" "braille withheld on TERM=linux" ;;
  *)         assert_eq "withheld" "withheld" "braille withheld on TERM=linux" ;;
esac

# the fallback set is never empty -- something must always print
n="$(LC_ALL=C TERM=linux; . "$BANNER"; roost_banner_variants | wc -l | tr -d ' ')"
assert_eq "$n" "2" "two variants remain when braille is unavailable"

# ROOST_BANNER pins the choice, which is what makes the random draw testable
out="$(ROOST_BANNER=outline "$BANNER" | head -1)"
assert_contains "$out" "#" "ROOST_BANNER pins the variant"

# roost help prints the banner AND the command list, and lists itself
help_out="$(ROOST_BANNER=blocks "$HERE/bin/roost" help)"
assert_contains "$help_out" "roost session NAME" "help lists commands"
assert_contains "$help_out" "roost help" "help lists itself"
assert_contains "$help_out" "░" "help includes the banner"
"$HERE/bin/roost" help >/dev/null 2>&1
assert_eq "$?" "0" "roost help exits 0"

# help text is read from bin/roost's own header, so it cannot drift from it
for cmd in spawn split whoami hooks doctor init settings status kill; do
  assert_contains "$help_out" "roost $cmd" "help mentions $cmd"
done
