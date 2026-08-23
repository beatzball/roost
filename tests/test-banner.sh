#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BANNER="$HERE/scripts/roost-banner"

# every named variant renders something
for v in color braille blocks outline; do
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

# colour is offered only where 24-bit escapes actually render. Guessing wrong
# turns the logo into a smear of the eight nearest colours.
got="$(COLORTERM=truecolor; . "$BANNER"; roost_banner_variants)"
assert_contains "$got" "color" "colour offered when COLORTERM says truecolor"

for env_desc in "COLORTERM= :unset" "COLORTERM=256color:not truecolor"; do
  setting="${env_desc%%:*}"; desc="${env_desc##*:}"
  got="$(export ${setting}; . "$BANNER"; roost_banner_variants)"
  case "$got" in
    *color*) assert_eq "offered" "withheld" "colour withheld when COLORTERM is $desc" ;;
    *)       assert_eq "withheld" "withheld" "colour withheld when COLORTERM is $desc" ;;
  esac
done

# NO_COLOR is a request, not a hint -- honour it even on a capable terminal
got="$(COLORTERM=truecolor NO_COLOR=1; . "$BANNER"; roost_banner_variants)"
case "$got" in
  *color*) assert_eq "offered" "withheld" "colour withheld under NO_COLOR" ;;
  *)       assert_eq "withheld" "withheld" "colour withheld under NO_COLOR" ;;
esac

# the fallback set is never empty -- something must always print
n="$(LC_ALL=C TERM=linux COLORTERM=; . "$BANNER"; roost_banner_variants | wc -l | tr -d ' ')"
assert_eq "$n" "2" "two variants remain when braille and colour are unavailable"

# ROOST_BANNER pins the choice, which is what makes the random draw testable
out="$(ROOST_BANNER=outline "$BANNER" | head -1)"
assert_contains "$out" "#" "ROOST_BANNER pins the variant"

# the colour art lives in a separate file, so a lost file must fail loudly
# rather than print an empty banner and return success
out="$(ROOST_BANNER=color "$BANNER")"
assert_contains "$out" "38;2;" "colour art carries 24-bit escapes"

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
